//! ZQUIC Integration Example
//! Demonstrates how zquic can use Zsync for async I/O, timers, and task management

const std = @import("std");
const zsync = @import("root.zig");

/// QUIC Connection simulation for integration testing
pub const QuicConnection = struct {
    fd: std.posix.fd_t,
    local_addr: std.net.Address,
    peer_addr: std.net.Address,
    connection_id: [4]u8,
    state: ConnectionState,
    waker: ?*zsync.scheduler.Waker = null,

    const ConnectionState = enum {
        initial,
        handshaking,
        established,
        closing,
        closed,
    };

    const Self = @This();

    /// Initialize a new QUIC connection
    pub fn init(local_addr: std.net.Address, peer_addr: std.net.Address, connection_id: [4]u8) !Self {
        // Create UDP socket for QUIC
        const fd = try std.posix.socket(local_addr.any.family, std.posix.SOCK.DGRAM, std.posix.IPPROTO.UDP);
        
        // Set non-blocking
        const flags = try std.posix.fcntl(fd, std.posix.F.GETFL, 0);
        _ = try std.posix.fcntl(fd, std.posix.F.SETFL, flags | 0o4000);

        return Self{
            .fd = fd,
            .local_addr = local_addr,
            .peer_addr = peer_addr,
            .connection_id = connection_id,
            .state = .initial,
        };
    }

    /// Close the connection
    pub fn deinit(self: *Self) void {
        std.posix.close(self.fd);
    }

    /// Start QUIC handshake (async)
    pub fn startHandshake(self: *Self) !void {
        std.debug.print("🤝 Starting QUIC handshake for connection {any}\n", .{self.connection_id});
        
        self.state = .handshaking;
        
        // Create waker for this connection
        const runtime = zsync.Runtime.global() orelse return error.NoRuntime;
        const frame_id = try runtime.spawnTask(struct {
            fn handshakeTask() void {}
        }.handshakeTask, .{});
        
        var waker = runtime.event_loop_instance.scheduler_instance.createWaker(frame_id);
        self.waker = &waker;

        // Register for write readiness to send initial packet
        try runtime.registerIo(self.fd, .{ .writable = true }, &waker);

        // Simulate handshake with timer
        _ = try runtime.scheduleTimeout(100, &waker); // 100ms handshake timeout

        // In real implementation, this would send the initial QUIC packet
        const initial_packet = "QUIC Initial Packet";
        _ = std.posix.sendto(self.fd, initial_packet, 0, &self.peer_addr.any, self.peer_addr.getOsSockLen()) catch {};
        
        std.debug.print("📤 Sent QUIC initial packet\n", .{});
    }

    /// Complete handshake (called when waker fires)
    pub fn completeHandshake(self: *Self) !void {
        if (self.state == .handshaking) {
            self.state = .established;
            std.debug.print("✅ QUIC handshake completed for connection {any}\n", .{self.connection_id});
            
            // Register for read events to handle incoming data
            if (self.waker) |waker| {
                const runtime = zsync.Runtime.global() orelse return error.NoRuntime;
                try runtime.modifyIo(self.fd, .{ .readable = true }, waker);
            }
        }
    }

    /// Send QUIC data (async)
    pub fn sendData(self: *Self, data: []const u8) !usize {
        if (self.state != .established) {
            return error.ConnectionNotEstablished;
        }

        // Async send - would block until writable
        const bytes_sent = std.posix.sendto(self.fd, data, 0, &self.peer_addr.any, self.peer_addr.getOsSockLen()) catch |err| switch (err) {
            error.WouldBlock => {
                // Register for write readiness and suspend
                if (self.waker) |waker| {
                    const runtime = zsync.Runtime.global() orelse return error.NoRuntime;
                    try runtime.modifyIo(self.fd, .{ .writable = true }, waker);
                }
                zsync.scheduler.yield();
                return 0; // Would retry in real implementation
            },
            else => return err,
        };

        std.debug.print("📤 Sent {} bytes via QUIC\n", .{bytes_sent});
        return bytes_sent;
    }

    /// Receive QUIC data (async)
    pub fn recvData(self: *Self, buffer: []u8) !usize {
        if (self.state != .established) {
            return error.ConnectionNotEstablished;
        }

        var src_addr: std.posix.sockaddr = undefined;
        var src_addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);

        const bytes_received = std.posix.recvfrom(self.fd, buffer, 0, &src_addr, &src_addr_len) catch |err| switch (err) {
            error.WouldBlock => {
                // Register for read readiness and suspend
                if (self.waker) |waker| {
                    const runtime = zsync.Runtime.global() orelse return error.NoRuntime;
                    try runtime.modifyIo(self.fd, .{ .readable = true }, waker);
                }
                zsync.scheduler.yield();
                return 0; // Would retry in real implementation
            },
            else => return err,
        };

        std.debug.print("📥 Received {} bytes via QUIC\n", .{bytes_received});
        return bytes_received;
    }
};

/// QUIC Server simulation
pub const QuicServer = struct {
    fd: std.posix.fd_t,
    local_addr: std.net.Address,
    connections: std.ArrayList(*QuicConnection),
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, bind_addr: std.net.Address) !Self {
        const fd = try std.posix.socket(bind_addr.any.family, std.posix.SOCK.DGRAM, std.posix.IPPROTO.UDP);
        
        // Set non-blocking and bind
        const flags = try std.posix.fcntl(fd, std.posix.F.GETFL, 0);
        _ = try std.posix.fcntl(fd, std.posix.F.SETFL, flags | 0o4000);
        
        try std.posix.bind(fd, &bind_addr.any, bind_addr.getOsSockLen());

        return Self{
            .fd = fd,
            .local_addr = bind_addr,
            .connections = std.ArrayList(*QuicConnection){},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.connections.items) |conn| {
            conn.deinit();
            self.allocator.destroy(conn);
        }
        self.connections.deinit(self.allocator);
        std.posix.close(self.fd);
    }

    /// Accept new QUIC connections (async)
    pub fn accept(self: *Self) !*QuicConnection {
        var buffer: [1024]u8 = undefined;
        var src_addr: std.posix.sockaddr = undefined;
        var src_addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);

        // Wait for incoming QUIC initial packet
        const bytes_received = std.posix.recvfrom(self.fd, &buffer, 0, &src_addr, &src_addr_len) catch |err| switch (err) {
            error.WouldBlock => {
                // Register for read readiness and suspend
                const runtime = zsync.Runtime.global() orelse return error.NoRuntime;
                const frame_id = try runtime.spawnTask(struct {
                    fn acceptTask() void {}
                }.acceptTask, .{});
                var waker = runtime.event_loop_instance.scheduler_instance.createWaker(frame_id);
                
                try runtime.registerIo(self.fd, .{ .readable = true }, &waker);
                zsync.scheduler.yield();
                return error.WouldBlock; // Would retry in real implementation
            },
            else => return err,
        };

        std.debug.print("📥 Received QUIC initial packet ({} bytes)\n", .{bytes_received});

        // Create new connection
        const peer_addr = std.net.Address.initPosix(@alignCast(@ptrCast(&src_addr)));
        const connection_id = [4]u8{ 1, 2, 3, 4 }; // Would be extracted from packet
        
        const conn = try self.allocator.create(QuicConnection);
        conn.* = try QuicConnection.init(self.local_addr, peer_addr, connection_id);
        
        try self.connections.append(self.allocator, conn);
        return conn;
    }
};

/// Example: QUIC echo server using Zsync
pub fn quicEchoServer(port: u16) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const bind_addr = std.net.Address.parseIp4("127.0.0.1", port) catch unreachable;
    var server = try QuicServer.init(allocator, bind_addr);
    defer server.deinit();

    std.debug.print("🚀 QUIC echo server listening on port {}\n", .{port});

    while (true) {
        // Accept new connection
        const conn = server.accept() catch |err| switch (err) {
            error.WouldBlock => {
                zsync.scheduler.yield();
                continue;
            },
            else => return err,
        };

        // Spawn task to handle connection
        _ = try zsync.spawnUrgent(handleQuicConnection, .{conn});
    }
}

/// Handle individual QUIC connection
fn handleQuicConnection(conn: *QuicConnection) !void {
    defer {
        conn.deinit();
        // Would destroy connection in real implementation
    }

    // Complete handshake
    try conn.completeHandshake();

    var buffer: [1024]u8 = undefined;

    // Echo loop
    while (true) {
        const bytes_received = conn.recvData(&buffer) catch |err| switch (err) {
            error.WouldBlock => {
                zsync.scheduler.yield();
                continue;
            },
            error.ConnectionNotEstablished => break,
            else => return err,
        };

        if (bytes_received == 0) break;

        // Echo back the data
        _ = try conn.sendData(buffer[0..bytes_received]);
    }

    std.debug.print("🔌 QUIC connection closed\n", .{});
}

/// Example: QUIC client using Zsync
pub fn quicClient(server_addr: std.net.Address) !void {
    const local_addr = std.net.Address.parseIp4("127.0.0.1", 0) catch unreachable;
    const connection_id = [4]u8{ 5, 6, 7, 8 };

    var conn = try QuicConnection.init(local_addr, server_addr, connection_id);
    defer conn.deinit();

    // Start handshake
    try conn.startHandshake();

    // Wait for handshake completion
    try zsync.sleep(200);

    // Send test messages
    const messages = [_][]const u8{ "Hello", "QUIC", "World!", "via", "Zsync" };

    for (messages) |msg| {
        _ = try conn.sendData(msg);
        
        var buffer: [1024]u8 = undefined;
        const bytes_received = try conn.recvData(&buffer);
        
        std.debug.print("🔄 Echo: {s} -> {s}\n", .{ msg, buffer[0..bytes_received] });
        
        try zsync.sleep(100); // Small delay between messages
    }
}

/// Comprehensive QUIC + Zsync integration test
pub fn quicIntegrationTest() !void {
    std.debug.print("\n🔥 QUIC + Zsync Integration Test\n", .{});
    std.debug.print("==================================\n", .{});

    // Start QUIC server in background
    _ = try zsync.spawnUrgent(quicEchoServer, .{@as(u16, 9001)});

    // Give server time to start
    try zsync.sleep(100);

    // Start QUIC client
    const server_addr = std.net.Address.parseIp4("127.0.0.1", 9001) catch unreachable;
    _ = try zsync.spawn(quicClient, .{server_addr});

    // Let them run for a bit
    try zsync.sleep(2000);

    std.debug.print("\n✅ QUIC integration test completed!\n", .{});
}

// Tests
test "quic connection creation" {
    const testing = std.testing;
    
    const local_addr = std.net.Address.parseIp4("127.0.0.1", 0) catch unreachable;
    const peer_addr = std.net.Address.parseIp4("127.0.0.1", 443) catch unreachable;
    const connection_id = [4]u8{ 1, 2, 3, 4 };

    var conn = try QuicConnection.init(local_addr, peer_addr, connection_id);
    defer conn.deinit();

    try testing.expect(conn.state == .initial);
    try testing.expect(std.mem.eql(u8, &conn.connection_id, &connection_id));
}

test "quic server creation" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    const bind_addr = std.net.Address.parseIp4("127.0.0.1", 0) catch unreachable;
    var server = try QuicServer.init(allocator, bind_addr);
    defer server.deinit();

    try testing.expect(server.connections.items.len == 0);
}
