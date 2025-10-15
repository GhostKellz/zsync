//! Zsync v0.6.0 - WebSocket Client & Server
//! WebSocket implementation for real-time communication, HMR, and live reload

const std = @import("std");
const Runtime = @import("../runtime.zig").Runtime;

/// WebSocket OpCode (RFC 6455)
pub const OpCode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
};

/// WebSocket Frame
pub const Frame = struct {
    fin: bool,
    opcode: OpCode,
    masked: bool,
    payload: []const u8,

    pub fn init(opcode: OpCode, payload: []const u8) Frame {
        return Frame{
            .fin = true,
            .opcode = opcode,
            .masked = false,
            .payload = payload,
        };
    }
};

/// WebSocket Message Type
pub const MessageType = enum {
    text,
    binary,
    ping,
    pong,
    close,
};

/// WebSocket Message
pub const Message = struct {
    type: MessageType,
    data: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Message) void {
        self.allocator.free(self.data);
    }
};

/// WebSocket Close Code (RFC 6455)
pub const CloseCode = enum(u16) {
    normal = 1000,
    going_away = 1001,
    protocol_error = 1002,
    unsupported_data = 1003,
    no_status_received = 1005,
    abnormal_closure = 1006,
    invalid_payload = 1007,
    policy_violation = 1008,
    message_too_big = 1009,
    mandatory_extension = 1010,
    internal_error = 1011,
    service_restart = 1012,
    try_again_later = 1013,
};

/// WebSocket Connection State
pub const State = enum {
    connecting,
    open,
    closing,
    closed,
};

/// WebSocket Connection
pub const WebSocketConnection = struct {
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    state: std.atomic.Value(State),
    recv_buffer: []u8,
    mutex: std.Thread.Mutex,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, stream: std.net.Stream) !Self {
        const buffer = try allocator.alloc(u8, 4096);
        return Self{
            .allocator = allocator,
            .stream = stream,
            .state = std.atomic.Value(State).init(.open),
            .recv_buffer = buffer,
            .mutex = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.recv_buffer);
        self.stream.close();
    }

    /// Send text message
    pub fn sendText(self: *Self, text: []const u8) !void {
        try self.sendFrame(Frame.init(.text, text));
    }

    /// Send binary message
    pub fn sendBinary(self: *Self, data: []const u8) !void {
        try self.sendFrame(Frame.init(.binary, data));
    }

    /// Send ping
    pub fn ping(self: *Self, data: []const u8) !void {
        try self.sendFrame(Frame.init(.ping, data));
    }

    /// Send pong
    pub fn pong(self: *Self, data: []const u8) !void {
        try self.sendFrame(Frame.init(.pong, data));
    }

    /// Close connection
    pub fn close(self: *Self, code: CloseCode) !void {
        if (self.state.load(.acquire) != .open) return;

        self.state.store(.closing, .release);

        // Send close frame
        var close_data: [2]u8 = undefined;
        std.mem.writeInt(u16, &close_data, @intFromEnum(code), .big);
        try self.sendFrame(Frame.init(.close, &close_data));

        self.state.store(.closed, .release);
    }

    /// Receive next message
    pub fn recv(self: *Self) !?Message {
        // TODO: Implement WebSocket frame parsing
        // For now, return null
        _ = self;
        return null;
    }

    /// Send WebSocket frame
    fn sendFrame(self: *Self, frame: Frame) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var header: [14]u8 = undefined;
        var header_len: usize = 2;

        // Byte 0: FIN + OpCode
        header[0] = if (frame.fin) 0x80 else 0x00;
        header[0] |= @intFromEnum(frame.opcode);

        // Byte 1: MASK + Payload length
        header[1] = if (frame.masked) 0x80 else 0x00;

        if (frame.payload.len < 126) {
            header[1] |= @as(u8, @intCast(frame.payload.len));
        } else if (frame.payload.len < 65536) {
            header[1] |= 126;
            std.mem.writeInt(u16, header[2..4], @intCast(frame.payload.len), .big);
            header_len = 4;
        } else {
            header[1] |= 127;
            std.mem.writeInt(u64, header[2..10], @intCast(frame.payload.len), .big);
            header_len = 10;
        }

        // Send header
        _ = try self.stream.write(header[0..header_len]);

        // Send payload
        if (frame.payload.len > 0) {
            _ = try self.stream.write(frame.payload);
        }
    }

    /// Get connection state
    pub fn getState(self: *const Self) State {
        return self.state.load(.acquire);
    }

    /// Check if connection is open
    pub fn isOpen(self: *const Self) bool {
        return self.getState() == .open;
    }
};

/// WebSocket Server
pub const WebSocketServer = struct {
    allocator: std.mem.Allocator,
    runtime: *Runtime,
    address: std.net.Address,
    on_connect: *const fn (*WebSocketConnection) anyerror!void,
    running: std.atomic.Value(bool),

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        runtime: *Runtime,
        address: std.net.Address,
        on_connect: *const fn (*WebSocketConnection) anyerror!void,
    ) Self {
        return Self{
            .allocator = allocator,
            .runtime = runtime,
            .address = address,
            .on_connect = on_connect,
            .running = std.atomic.Value(bool).init(false),
        };
    }

    /// Start WebSocket server
    pub fn listen(self: *Self) !void {
        self.running.store(true, .release);

        const listener = try self.address.listen(.{});
        defer listener.deinit();

        std.debug.print("[WebSocket] Server listening on {}\n", .{self.address});

        while (self.running.load(.acquire)) {
            // TODO: Accept connection and perform WebSocket handshake
            // TODO: Create WebSocketConnection
            // TODO: Call on_connect handler

            std.Thread.sleep(100 * std.time.ns_per_ms);
        }
    }

    pub fn stop(self: *Self) void {
        self.running.store(false, .release);
    }
};

/// WebSocket Client
pub const WebSocketClient = struct {
    allocator: std.mem.Allocator,
    runtime: *Runtime,
    url: []const u8,
    connection: ?WebSocketConnection,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, runtime: *Runtime, url: []const u8) !Self {
        const owned_url = try allocator.dupe(u8, url);
        return Self{
            .allocator = allocator,
            .runtime = runtime,
            .url = owned_url,
            .connection = null,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.connection) |*conn| {
            conn.deinit();
        }
        self.allocator.free(self.url);
    }

    /// Connect to WebSocket server
    pub fn connect(self: *Self) !void {
        // TODO: Parse URL (ws:// or wss://)
        // TODO: Establish TCP connection
        // TODO: Perform WebSocket handshake
        // TODO: Create WebSocketConnection

        std.debug.print("[WebSocket] Connecting to {s}\n", .{self.url});
    }

    /// Get connection
    pub fn getConnection(self: *Self) ?*WebSocketConnection {
        if (self.connection) |*conn| {
            return conn;
        }
        return null;
    }
};

// Tests
test "websocket frame" {
    const testing = std.testing;

    const frame = Frame.init(.text, "Hello");
    try testing.expect(frame.fin);
    try testing.expectEqual(OpCode.text, frame.opcode);
}

test "websocket close code" {
    const testing = std.testing;

    try testing.expectEqual(1000, @intFromEnum(CloseCode.normal));
    try testing.expectEqual(1001, @intFromEnum(CloseCode.going_away));
}
