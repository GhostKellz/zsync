//! Connection pool for managing multiple network connections
//! Provides connection pooling for TCP, UDP, and QUIC connections

const std = @import("std");
const io = @import("io.zig");

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