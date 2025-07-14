//! Connection pool for managing multiple network connections
//! Provides connection pooling for TCP, UDP, and QUIC connections

const std = @import("std");
const io = @import("io.zig");
const io_v2 = @import("io_v2.zig");

/// Connection pool configuration
pub const PoolConfig = struct {
    max_connections: u32 = 100,
    connection_timeout_ms: u64 = 30000,
    idle_timeout_ms: u64 = 300000,
    health_check_interval_ms: u64 = 60000,
};

/// Connection state for tracking
pub const ConnectionState = enum {
    idle,
    active,
    unhealthy,
    closing,
};

/// Connection wrapper for pool management
pub const PooledConnection = struct {
    id: u32,
    stream: io.TcpStream,
    state: ConnectionState,
    created_at: u64,
    last_used: u64,
    use_count: u32,

    const Self = @This();

    pub fn init(id: u32, stream: io.TcpStream) Self {
        const now = @as(u64, @intCast(std.time.milliTimestamp()));
        return Self{
            .id = id,
            .stream = stream,
            .state = .idle,
            .created_at = now,
            .last_used = now,
            .use_count = 0,
        };
    }

    pub fn markUsed(self: *Self) void {
        self.last_used = @as(u64, @intCast(std.time.milliTimestamp()));
        self.use_count += 1;
        self.state = .active;
    }

    pub fn markIdle(self: *Self) void {
        self.state = .idle;
    }

    pub fn isExpired(self: *Self, timeout_ms: u64) bool {
        const now = @as(u64, @intCast(std.time.milliTimestamp()));
        return (now - self.last_used) > timeout_ms;
    }

    pub fn close(self: *Self) void {
        self.state = .closing;
        self.stream.close();
    }
};

/// Connection pool for managing TCP connections
pub const ConnectionPool = struct {
    allocator: std.mem.Allocator,
    config: PoolConfig,
    connections: std.ArrayList(*PooledConnection),
    idle_connections: std.ArrayList(*PooledConnection),
    connection_map: std.HashMap(u32, *PooledConnection, std.hash_map.AutoContext(u32), std.hash_map.default_max_load_percentage),
    next_connection_id: std.atomic.Value(u32),
    mutex: std.Thread.Mutex,
    active_count: std.atomic.Value(u32),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: PoolConfig) !Self {
        return Self{
            .allocator = allocator,
            .config = config,
            .connections = std.ArrayList(*PooledConnection).init(allocator),
            .idle_connections = std.ArrayList(*PooledConnection).init(allocator),
            .connection_map = std.HashMap(u32, *PooledConnection, std.hash_map.AutoContext(u32), std.hash_map.default_max_load_percentage).init(allocator),
            .next_connection_id = std.atomic.Value(u32).init(1),
            .mutex = std.Thread.Mutex{},
            .active_count = std.atomic.Value(u32).init(0),
        };
    }

    pub fn deinit(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Close all connections
        for (self.connections.items) |conn| {
            conn.close();
            self.allocator.destroy(conn);
        }

        self.connections.deinit();
        self.idle_connections.deinit();
        self.connection_map.deinit();
    }

    /// Get a connection from the pool
    pub fn getConnection(self: *Self, address: std.net.Address) !*PooledConnection {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Try to reuse an idle connection
        if (self.idle_connections.items.len > 0) {
            const conn = self.idle_connections.pop();
            conn.markUsed();
            _ = self.active_count.fetchAdd(1, .monotonic);
            return conn;
        }

        // Check if we can create a new connection
        if (self.connections.items.len >= self.config.max_connections) {
            return error.PoolExhausted;
        }

        // Create new connection
        const stream = try io.TcpStream.connect(address);
        const conn = try self.allocator.create(PooledConnection);
        conn.* = PooledConnection.init(self.next_connection_id.fetchAdd(1, .monotonic), stream);
        
        try self.connections.append(conn);
        try self.connection_map.put(conn.id, conn);
        
        conn.markUsed();
        _ = self.active_count.fetchAdd(1, .monotonic);
        
        return conn;
    }

    /// Return a connection to the pool
    pub fn returnConnection(self: *Self, conn: *PooledConnection) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        conn.markIdle();
        try self.idle_connections.append(conn);
        _ = self.active_count.fetchSub(1, .monotonic);
    }

    /// Remove expired connections
    pub fn cleanup(self: *Self) u32 {
        self.mutex.lock();
        defer self.mutex.unlock();

        var removed: u32 = 0;
        var i: usize = 0;
        
        while (i < self.idle_connections.items.len) {
            const conn = self.idle_connections.items[i];
            
            if (conn.isExpired(self.config.idle_timeout_ms)) {
                // Remove from idle list
                _ = self.idle_connections.swapRemove(i);
                
                // Remove from main list
                for (self.connections.items, 0..) |c, idx| {
                    if (c.id == conn.id) {
                        _ = self.connections.swapRemove(idx);
                        break;
                    }
                }
                
                // Remove from map and close
                _ = self.connection_map.remove(conn.id);
                conn.close();
                self.allocator.destroy(conn);
                removed += 1;
            } else {
                i += 1;
            }
        }

        return removed;
    }

    /// Get pool statistics
    pub fn getStats(self: *Self) PoolStats {
        self.mutex.lock();
        defer self.mutex.unlock();

        return PoolStats{
            .total_connections = @intCast(self.connections.items.len),
            .idle_connections = @intCast(self.idle_connections.items.len),
            .active_connections = self.active_count.load(.monotonic),
            .max_connections = self.config.max_connections,
        };
    }
};

/// Pool statistics
pub const PoolStats = struct {
    total_connections: u32,
    idle_connections: u32,
    active_connections: u32,
    max_connections: u32,
};

/// UDP multicast and broadcast support
pub const UdpMulticast = struct {
    socket: io_v2.UdpSocket,
    multicast_groups: std.ArrayList(std.net.Address),
    broadcast_enabled: bool,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, socket: io_v2.UdpSocket) Self {
        return Self{
            .socket = socket,
            .multicast_groups = std.ArrayList(std.net.Address).init(allocator),
            .broadcast_enabled = false,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.multicast_groups.deinit();
    }
    
    /// Join a multicast group
    pub fn joinMulticastGroup(self: *Self, group_address: std.net.Address) !void {
        // In a real implementation, this would call setsockopt with IP_ADD_MEMBERSHIP
        try self.multicast_groups.append(group_address);
    }
    
    /// Leave a multicast group
    pub fn leaveMulticastGroup(self: *Self, group_address: std.net.Address) !void {
        // In a real implementation, this would call setsockopt with IP_DROP_MEMBERSHIP
        for (self.multicast_groups.items, 0..) |addr, i| {
            if (std.mem.eql(u8, &addr.any.data, &group_address.any.data)) {
                _ = self.multicast_groups.swapRemove(i);
                break;
            }
        }
    }
    
    /// Enable broadcast
    pub fn enableBroadcast(self: *Self) !void {
        // In a real implementation, this would call setsockopt with SO_BROADCAST
        self.broadcast_enabled = true;
    }
    
    /// Disable broadcast
    pub fn disableBroadcast(self: *Self) !void {
        self.broadcast_enabled = false;
    }
    
    /// Send to multicast group
    pub fn sendToMulticastGroup(self: *Self, io_instance: io_v2.Io, data: []const u8, group_address: std.net.Address) !usize {
        if (!self.isInMulticastGroup(group_address)) {
            return error.NotInMulticastGroup;
        }
        return self.socket.sendTo(io_instance, data, group_address);
    }
    
    /// Send broadcast
    pub fn sendBroadcast(self: *Self, io_instance: io_v2.Io, data: []const u8, port: u16) !usize {
        if (!self.broadcast_enabled) {
            return error.BroadcastNotEnabled;
        }
        const broadcast_addr = std.net.Address.initIp4(.{255, 255, 255, 255}, port);
        return self.socket.sendTo(io_instance, data, broadcast_addr);
    }
    
    /// Check if address is in multicast group
    fn isInMulticastGroup(self: *Self, address: std.net.Address) bool {
        for (self.multicast_groups.items) |addr| {
            if (std.mem.eql(u8, &addr.any.data, &address.any.data)) {
                return true;
            }
        }
        return false;
    }
};

/// Zero-copy networking utilities
pub const ZeroCopyNet = struct {
    /// Send file contents using zero-copy (sendfile on Linux)
    pub fn sendFile(io_instance: io_v2.Io, socket: io_v2.TcpStream, file: io_v2.File) !u64 {
        // In a real implementation, this would use platform-specific zero-copy mechanisms
        // Linux: sendfile(), FreeBSD: sendfile(), Windows: TransmitFile()
        
        var buffer: [8192]u8 = undefined;
        var total_sent: u64 = 0;
        
        while (true) {
            const bytes_read = try file.readAll(io_instance, &buffer);
            if (bytes_read == 0) break;
            
            const bytes_sent = try socket.write(io_instance, buffer[0..bytes_read]);
            total_sent += bytes_sent;
        }
        
        return total_sent;
    }
    
    /// Splice between two sockets (Linux specific)
    pub fn splice(io_instance: io_v2.Io, input: io_v2.TcpStream, output: io_v2.TcpStream, count: usize) !u64 {
        // In a real implementation, this would use Linux splice() syscall
        _ = io_instance;
        _ = input;
        _ = output;
        _ = count;
        return error.NotImplemented;
    }
    
    /// Memory-mapped file I/O
    pub fn mmapFile(file_path: []const u8) ![]u8 {
        // In a real implementation, this would use mmap() on Unix or MapViewOfFile() on Windows
        _ = file_path;
        return error.NotImplemented;
    }
};

/// Advanced socket options and tuning
pub const SocketOptions = struct {
    /// Set TCP_NODELAY option
    pub fn setTcpNoDelay(socket: io_v2.TcpStream, enabled: bool) !void {
        _ = socket;
        _ = enabled;
        // In a real implementation, this would call setsockopt(TCP_NODELAY)
    }
    
    /// Set SO_KEEPALIVE option
    pub fn setKeepAlive(socket: io_v2.TcpStream, enabled: bool) !void {
        _ = socket;
        _ = enabled;
        // In a real implementation, this would call setsockopt(SO_KEEPALIVE)
    }
    
    /// Set socket buffer sizes
    pub fn setBufferSizes(socket: io_v2.TcpStream, send_buffer: u32, recv_buffer: u32) !void {
        _ = socket;
        _ = send_buffer;
        _ = recv_buffer;
        // In a real implementation, this would call setsockopt(SO_SNDBUF/SO_RCVBUF)
    }
    
    /// Set socket timeout
    pub fn setTimeout(socket: io_v2.TcpStream, timeout_ms: u32) !void {
        _ = socket;
        _ = timeout_ms;
        // In a real implementation, this would call setsockopt(SO_SNDTIMEO/SO_RCVTIMEO)
    }
    
    /// Set socket priority
    pub fn setPriority(socket: io_v2.TcpStream, priority: u32) !void {
        _ = socket;
        _ = priority;
        // In a real implementation, this would call setsockopt(SO_PRIORITY)
    }
    
    /// Enable/disable socket reuse
    pub fn setReuseAddress(socket: io_v2.TcpStream, enabled: bool) !void {
        _ = socket;
        _ = enabled;
        // In a real implementation, this would call setsockopt(SO_REUSEADDR)
    }
    
    /// Set socket linger options
    pub fn setLinger(socket: io_v2.TcpStream, enabled: bool, timeout_s: u16) !void {
        _ = socket;
        _ = enabled;
        _ = timeout_s;
        // In a real implementation, this would call setsockopt(SO_LINGER)
    }
};

// Tests
test "connection pool creation" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var pool = try ConnectionPool.init(allocator, .{});
    defer pool.deinit();
    
    const stats = pool.getStats();
    try testing.expect(stats.total_connections == 0);
    try testing.expect(stats.idle_connections == 0);
    try testing.expect(stats.active_connections == 0);
}

test "connection pool stats" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var pool = try ConnectionPool.init(allocator, .{ .max_connections = 5 });
    defer pool.deinit();
    
    const stats = pool.getStats();
    try testing.expect(stats.max_connections == 5);
}

test "udp multicast group management" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    // Create a mock UDP socket
    const socket = io_v2.UdpSocket{
        .ptr = undefined,
        .vtable = undefined,
    };
    
    var multicast = UdpMulticast.init(allocator, socket);
    defer multicast.deinit();
    
    const group_addr = std.net.Address.initIp4(.{224, 0, 0, 1}, 8080);
    try multicast.joinMulticastGroup(group_addr);
    
    try testing.expect(multicast.multicast_groups.items.len == 1);
    try testing.expect(multicast.isInMulticastGroup(group_addr));
    
    try multicast.leaveMulticastGroup(group_addr);
    try testing.expect(multicast.multicast_groups.items.len == 0);
}