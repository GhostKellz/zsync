//! zsync - WebSocket Client & Server (RFC 6455)
//! Full WebSocket implementation with frame parsing, handshake, and masking

const std = @import("std");
const compat = @import("../compat/thread.zig");
const crypto = std.crypto;
const base64 = std.base64;

/// WebSocket OpCode (RFC 6455)
pub const OpCode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
    _,

    pub fn isControl(self: OpCode) bool {
        return @intFromEnum(self) >= 0x8;
    }
};

/// WebSocket Frame
pub const Frame = struct {
    fin: bool,
    opcode: OpCode,
    masked: bool,
    mask_key: [4]u8,
    payload: []const u8,

    pub fn init(opcode: OpCode, payload: []const u8) Frame {
        return Frame{
            .fin = true,
            .opcode = opcode,
            .masked = false,
            .mask_key = undefined,
            .payload = payload,
        };
    }

    pub fn initMasked(opcode: OpCode, payload: []const u8) Frame {
        var frame = init(opcode, payload);
        frame.masked = true;
        crypto.random.bytes(&frame.mask_key);
        return frame;
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
    data: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Message) void {
        self.allocator.free(self.data);
    }

    pub fn text(self: *const Message) []const u8 {
        return self.data;
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
    _,
};

/// WebSocket Connection State
pub const State = enum {
    connecting,
    open,
    closing,
    closed,
};

/// WebSocket Error
pub const Error = error{
    InvalidFrame,
    InvalidOpCode,
    InvalidUtf8,
    PayloadTooLarge,
    UnexpectedContinuation,
    ProtocolError,
    ConnectionClosed,
    HandshakeFailed,
    InvalidUrl,
};

/// Maximum payload size (16MB by default)
pub const MAX_PAYLOAD_SIZE: usize = 16 * 1024 * 1024;

/// WebSocket Connection
pub const WebSocketConnection = struct {
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    state: std.atomic.Value(State),
    recv_buffer: []u8,
    recv_pos: usize,
    recv_len: usize,
    fragment_buffer: std.ArrayList(u8),
    fragment_opcode: ?OpCode,
    is_client: bool,
    mutex: compat.Mutex,

    const Self = @This();
    const BUFFER_SIZE = 8192;

    pub fn init(allocator: std.mem.Allocator, stream: std.net.Stream, is_client: bool) !Self {
        const buffer = try allocator.alloc(u8, BUFFER_SIZE);
        return Self{
            .allocator = allocator,
            .stream = stream,
            .state = std.atomic.Value(State).init(.open),
            .recv_buffer = buffer,
            .recv_pos = 0,
            .recv_len = 0,
            .fragment_buffer = std.ArrayList(u8).init(allocator),
            .fragment_opcode = null,
            .is_client = is_client,
            .mutex = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        self.fragment_buffer.deinit();
        self.allocator.free(self.recv_buffer);
        self.stream.close();
    }

    /// Send text message
    pub fn sendText(self: *Self, text_data: []const u8) !void {
        if (self.is_client) {
            try self.sendFrame(Frame.initMasked(.text, text_data));
        } else {
            try self.sendFrame(Frame.init(.text, text_data));
        }
    }

    /// Send binary message
    pub fn sendBinary(self: *Self, data: []const u8) !void {
        if (self.is_client) {
            try self.sendFrame(Frame.initMasked(.binary, data));
        } else {
            try self.sendFrame(Frame.init(.binary, data));
        }
    }

    /// Send ping
    pub fn ping(self: *Self, data: []const u8) !void {
        if (self.is_client) {
            try self.sendFrame(Frame.initMasked(.ping, data));
        } else {
            try self.sendFrame(Frame.init(.ping, data));
        }
    }

    /// Send pong
    pub fn pong(self: *Self, data: []const u8) !void {
        if (self.is_client) {
            try self.sendFrame(Frame.initMasked(.pong, data));
        } else {
            try self.sendFrame(Frame.init(.pong, data));
        }
    }

    /// Close connection
    pub fn close(self: *Self, code: CloseCode) !void {
        if (self.state.load(.acquire) != .open) return;

        self.state.store(.closing, .release);

        // Send close frame with code
        var close_data: [2]u8 = undefined;
        std.mem.writeInt(u16, &close_data, @intFromEnum(code), .big);

        if (self.is_client) {
            try self.sendFrame(Frame.initMasked(.close, &close_data));
        } else {
            try self.sendFrame(Frame.init(.close, &close_data));
        }

        self.state.store(.closed, .release);
    }

    /// Receive next message (blocks until message available or error)
    pub fn recv(self: *Self) !?Message {
        while (true) {
            const frame = try self.readFrame() orelse return null;

            // Handle control frames immediately
            if (frame.opcode.isControl()) {
                switch (frame.opcode) {
                    .ping => {
                        // Respond with pong
                        try self.pong(frame.payload);
                        self.allocator.free(frame.payload);
                        continue;
                    },
                    .pong => {
                        // Pong received, ignore
                        self.allocator.free(frame.payload);
                        continue;
                    },
                    .close => {
                        // Close frame received
                        if (self.state.load(.acquire) == .open) {
                            self.state.store(.closing, .release);
                            // Echo close frame
                            if (self.is_client) {
                                try self.sendFrame(Frame.initMasked(.close, frame.payload));
                            } else {
                                try self.sendFrame(Frame.init(.close, frame.payload));
                            }
                        }
                        self.state.store(.closed, .release);
                        self.allocator.free(frame.payload);
                        return null;
                    },
                    else => {
                        self.allocator.free(frame.payload);
                        return Error.InvalidOpCode;
                    },
                }
            }

            // Handle data frames
            if (frame.opcode == .continuation) {
                // Continuation frame
                if (self.fragment_opcode == null) {
                    self.allocator.free(frame.payload);
                    return Error.UnexpectedContinuation;
                }
                try self.fragment_buffer.appendSlice(frame.payload);
                self.allocator.free(frame.payload);

                if (frame.fin) {
                    // Message complete
                    const opcode = self.fragment_opcode.?;
                    self.fragment_opcode = null;
                    const data = try self.fragment_buffer.toOwnedSlice();

                    return Message{
                        .type = if (opcode == .text) .text else .binary,
                        .data = data,
                        .allocator = self.allocator,
                    };
                }
            } else {
                // New message
                if (frame.fin) {
                    // Complete message in single frame
                    return Message{
                        .type = if (frame.opcode == .text) .text else .binary,
                        .data = @constCast(frame.payload),
                        .allocator = self.allocator,
                    };
                } else {
                    // Start of fragmented message
                    self.fragment_opcode = frame.opcode;
                    self.fragment_buffer.clearRetainingCapacity();
                    try self.fragment_buffer.appendSlice(frame.payload);
                    self.allocator.free(frame.payload);
                }
            }
        }
    }

    /// Read a single WebSocket frame
    fn readFrame(self: *Self) !?struct { fin: bool, opcode: OpCode, payload: []u8 } {
        // Read at least 2 bytes for header
        try self.ensureBytes(2);

        const byte0 = self.recv_buffer[self.recv_pos];
        const byte1 = self.recv_buffer[self.recv_pos + 1];
        self.recv_pos += 2;

        const fin = (byte0 & 0x80) != 0;
        const rsv = (byte0 >> 4) & 0x7;
        if (rsv != 0) return Error.ProtocolError; // RSV bits must be 0

        const opcode: OpCode = @enumFromInt(@as(u4, @truncate(byte0 & 0x0F)));
        const masked = (byte1 & 0x80) != 0;
        var payload_len: u64 = byte1 & 0x7F;

        // Extended payload length
        if (payload_len == 126) {
            try self.ensureBytes(2);
            payload_len = std.mem.readInt(u16, self.recv_buffer[self.recv_pos..][0..2], .big);
            self.recv_pos += 2;
        } else if (payload_len == 127) {
            try self.ensureBytes(8);
            payload_len = std.mem.readInt(u64, self.recv_buffer[self.recv_pos..][0..8], .big);
            self.recv_pos += 8;
        }

        if (payload_len > MAX_PAYLOAD_SIZE) return Error.PayloadTooLarge;

        // Read mask key if present
        var mask_key: [4]u8 = undefined;
        if (masked) {
            try self.ensureBytes(4);
            @memcpy(&mask_key, self.recv_buffer[self.recv_pos..][0..4]);
            self.recv_pos += 4;
        }

        // Read payload
        const payload = try self.allocator.alloc(u8, @intCast(payload_len));
        errdefer self.allocator.free(payload);

        var bytes_read: usize = 0;
        while (bytes_read < payload_len) {
            const available = self.recv_len - self.recv_pos;
            if (available > 0) {
                const to_copy = @min(available, payload.len - bytes_read);
                @memcpy(payload[bytes_read..][0..to_copy], self.recv_buffer[self.recv_pos..][0..to_copy]);
                self.recv_pos += to_copy;
                bytes_read += to_copy;
            } else {
                // Need more data from socket
                self.recv_pos = 0;
                self.recv_len = self.stream.read(self.recv_buffer) catch |err| switch (err) {
                    error.ConnectionResetByPeer, error.BrokenPipe => return null,
                    else => return err,
                };
                if (self.recv_len == 0) return null; // Connection closed
            }
        }

        // Unmask if needed
        if (masked) {
            for (payload, 0..) |*byte, i| {
                byte.* ^= mask_key[i % 4];
            }
        }

        return .{
            .fin = fin,
            .opcode = opcode,
            .payload = payload,
        };
    }

    /// Ensure at least n bytes are available in buffer
    fn ensureBytes(self: *Self, n: usize) !void {
        while (self.recv_len - self.recv_pos < n) {
            // Shift remaining data to start of buffer
            if (self.recv_pos > 0) {
                const remaining = self.recv_len - self.recv_pos;
                std.mem.copyForwards(u8, self.recv_buffer[0..remaining], self.recv_buffer[self.recv_pos..self.recv_len]);
                self.recv_len = remaining;
                self.recv_pos = 0;
            }

            // Read more data
            const bytes_read = self.stream.read(self.recv_buffer[self.recv_len..]) catch |err| switch (err) {
                error.ConnectionResetByPeer, error.BrokenPipe => return Error.ConnectionClosed,
                else => return err,
            };
            if (bytes_read == 0) return Error.ConnectionClosed;
            self.recv_len += bytes_read;
        }
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

        // Add mask key if masked
        if (frame.masked) {
            @memcpy(header[header_len..][0..4], &frame.mask_key);
            header_len += 4;
        }

        // Send header
        _ = try self.stream.write(header[0..header_len]);

        // Send payload (masked if needed)
        if (frame.payload.len > 0) {
            if (frame.masked) {
                // Send masked payload
                var masked_chunk: [4096]u8 = undefined;
                var offset: usize = 0;
                while (offset < frame.payload.len) {
                    const chunk_size = @min(masked_chunk.len, frame.payload.len - offset);
                    for (0..chunk_size) |i| {
                        masked_chunk[i] = frame.payload[offset + i] ^ frame.mask_key[(offset + i) % 4];
                    }
                    _ = try self.stream.write(masked_chunk[0..chunk_size]);
                    offset += chunk_size;
                }
            } else {
                _ = try self.stream.write(frame.payload);
            }
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

/// WebSocket handshake key GUID
const WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/// Generate WebSocket accept key from client key
fn generateAcceptKey(client_key: []const u8) [28]u8 {
    var hasher = crypto.hash.Sha1.init(.{});
    hasher.update(client_key);
    hasher.update(WS_GUID);
    const hash = hasher.finalResult();

    var encoded: [28]u8 = undefined;
    _ = base64.standard.Encoder.encode(&encoded, &hash);
    return encoded;
}

/// Parse HTTP headers from buffer
fn parseHttpHeaders(buffer: []const u8) !struct {
    upgrade: bool,
    connection_upgrade: bool,
    ws_key: ?[]const u8,
    ws_accept: ?[]const u8,
    status_code: ?u16,
} {
    var result = .{
        .upgrade = false,
        .connection_upgrade = false,
        .ws_key = null,
        .ws_accept = null,
        .status_code = null,
    };

    var lines = std.mem.splitSequence(u8, buffer, "\r\n");

    // Parse first line (request or status line)
    if (lines.next()) |first_line| {
        if (std.mem.startsWith(u8, first_line, "HTTP/")) {
            // Response line: HTTP/1.1 101 Switching Protocols
            var parts = std.mem.splitScalar(u8, first_line, ' ');
            _ = parts.next(); // HTTP/1.1
            if (parts.next()) |code_str| {
                result.status_code = std.fmt.parseInt(u16, code_str, 10) catch null;
            }
        }
    }

    // Parse headers
    while (lines.next()) |line| {
        if (line.len == 0) break;

        if (std.mem.indexOfScalar(u8, line, ':')) |colon_pos| {
            const name = std.mem.trim(u8, line[0..colon_pos], " ");
            const value = std.mem.trim(u8, line[colon_pos + 1 ..], " ");

            if (std.ascii.eqlIgnoreCase(name, "Upgrade")) {
                result.upgrade = std.ascii.eqlIgnoreCase(value, "websocket");
            } else if (std.ascii.eqlIgnoreCase(name, "Connection")) {
                result.connection_upgrade = std.mem.indexOf(u8, std.ascii.lowerString(
                    @constCast(value),
                    value,
                ), "upgrade") != null;
            } else if (std.ascii.eqlIgnoreCase(name, "Sec-WebSocket-Key")) {
                result.ws_key = value;
            } else if (std.ascii.eqlIgnoreCase(name, "Sec-WebSocket-Accept")) {
                result.ws_accept = value;
            }
        }
    }

    return result;
}

/// WebSocket Server
pub const WebSocketServer = struct {
    allocator: std.mem.Allocator,
    address: std.net.Address,
    on_connect: *const fn (*WebSocketConnection) anyerror!void,
    running: std.atomic.Value(bool),

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        address: std.net.Address,
        on_connect: *const fn (*WebSocketConnection) anyerror!void,
    ) Self {
        return Self{
            .allocator = allocator,
            .address = address,
            .on_connect = on_connect,
            .running = std.atomic.Value(bool).init(false),
        };
    }

    /// Start WebSocket server
    pub fn listen(self: *Self) !void {
        self.running.store(true, .release);

        const listener = try self.address.listen(.{ .reuse_address = true });
        defer listener.deinit();

        while (self.running.load(.acquire)) {
            const conn = listener.accept() catch |err| switch (err) {
                error.WouldBlock => {
                    std.time.sleep(10 * std.time.ns_per_ms);
                    continue;
                },
                else => return err,
            };

            // Perform WebSocket handshake
            const ws_conn = self.handleHandshake(conn.stream) catch |err| {
                conn.stream.close();
                std.debug.print("[WebSocket] Handshake failed: {}\n", .{err});
                continue;
            };

            // Call connection handler
            self.on_connect(ws_conn) catch |err| {
                std.debug.print("[WebSocket] Handler error: {}\n", .{err});
            };
        }
    }

    fn handleHandshake(self: *Self, stream: std.net.Stream) !*WebSocketConnection {
        var buffer: [4096]u8 = undefined;
        const bytes_read = try stream.read(&buffer);
        if (bytes_read == 0) return Error.HandshakeFailed;

        const headers = try parseHttpHeaders(buffer[0..bytes_read]);

        if (!headers.upgrade or !headers.connection_upgrade or headers.ws_key == null) {
            return Error.HandshakeFailed;
        }

        // Generate accept key
        const accept_key = generateAcceptKey(headers.ws_key.?);

        // Send handshake response
        const response = "HTTP/1.1 101 Switching Protocols\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Accept: " ++ "{s}" ++ "\r\n\r\n";

        var response_buf: [256]u8 = undefined;
        const response_len = std.fmt.bufPrint(&response_buf, response, .{accept_key}) catch
            return Error.HandshakeFailed;

        _ = try stream.write(response_len);

        // Create connection
        const conn = try self.allocator.create(WebSocketConnection);
        conn.* = try WebSocketConnection.init(self.allocator, stream, false);
        return conn;
    }

    pub fn stop(self: *Self) void {
        self.running.store(false, .release);
    }
};

/// WebSocket Client
pub const WebSocketClient = struct {
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,
    path: []const u8,
    connection: ?*WebSocketConnection,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, url: []const u8) !Self {
        // Parse URL: ws://host:port/path or wss://host:port/path
        var host: []const u8 = undefined;
        var port: u16 = 80;
        var path: []const u8 = "/";

        var remaining = url;

        // Strip protocol
        if (std.mem.startsWith(u8, remaining, "ws://")) {
            remaining = remaining[5..];
        } else if (std.mem.startsWith(u8, remaining, "wss://")) {
            remaining = remaining[6..];
            port = 443;
        } else {
            return Error.InvalidUrl;
        }

        // Find path
        if (std.mem.indexOfScalar(u8, remaining, '/')) |path_start| {
            path = remaining[path_start..];
            remaining = remaining[0..path_start];
        }

        // Find port
        if (std.mem.indexOfScalar(u8, remaining, ':')) |colon_pos| {
            host = remaining[0..colon_pos];
            port = std.fmt.parseInt(u16, remaining[colon_pos + 1 ..], 10) catch return Error.InvalidUrl;
        } else {
            host = remaining;
        }

        return Self{
            .allocator = allocator,
            .host = try allocator.dupe(u8, host),
            .port = port,
            .path = try allocator.dupe(u8, path),
            .connection = null,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.connection) |conn| {
            conn.deinit();
            self.allocator.destroy(conn);
        }
        self.allocator.free(self.host);
        self.allocator.free(self.path);
    }

    /// Connect to WebSocket server
    pub fn connect(self: *Self) !void {
        // Resolve address
        const address = try std.net.Address.resolveIp(self.host, self.port);

        // Connect TCP
        const stream = try std.net.tcpConnectToAddress(address);
        errdefer stream.close();

        // Generate random key
        var key_bytes: [16]u8 = undefined;
        crypto.random.bytes(&key_bytes);
        var key: [24]u8 = undefined;
        _ = base64.standard.Encoder.encode(&key, &key_bytes);

        // Send HTTP upgrade request
        var request_buf: [1024]u8 = undefined;
        const request = std.fmt.bufPrint(&request_buf,
            \\GET {s} HTTP/1.1
            \\Host: {s}:{d}
            \\Upgrade: websocket
            \\Connection: Upgrade
            \\Sec-WebSocket-Key: {s}
            \\Sec-WebSocket-Version: 13
            \\
            \\
        , .{ self.path, self.host, self.port, key }) catch return Error.HandshakeFailed;

        _ = try stream.write(request);

        // Read response
        var response_buf: [1024]u8 = undefined;
        const bytes_read = try stream.read(&response_buf);
        if (bytes_read == 0) return Error.HandshakeFailed;

        const headers = try parseHttpHeaders(response_buf[0..bytes_read]);

        // Verify response
        if (headers.status_code != 101 or !headers.upgrade or headers.ws_accept == null) {
            return Error.HandshakeFailed;
        }

        // Verify accept key
        const expected_accept = generateAcceptKey(&key);
        if (!std.mem.eql(u8, headers.ws_accept.?, &expected_accept)) {
            return Error.HandshakeFailed;
        }

        // Create connection
        const conn = try self.allocator.create(WebSocketConnection);
        conn.* = try WebSocketConnection.init(self.allocator, stream, true);
        self.connection = conn;
    }

    /// Get connection
    pub fn getConnection(self: *Self) ?*WebSocketConnection {
        return self.connection;
    }

    /// Send text message
    pub fn sendText(self: *Self, text_data: []const u8) !void {
        if (self.connection) |conn| {
            try conn.sendText(text_data);
        }
    }

    /// Receive message
    pub fn recv(self: *Self) !?Message {
        if (self.connection) |conn| {
            return conn.recv();
        }
        return null;
    }

    /// Close connection
    pub fn close(self: *Self) !void {
        if (self.connection) |conn| {
            try conn.close(.normal);
        }
    }
};

// Tests
test "websocket frame" {
    const testing = std.testing;

    const frame = Frame.init(.text, "Hello");
    try testing.expect(frame.fin);
    try testing.expectEqual(OpCode.text, frame.opcode);
    try testing.expect(!frame.masked);
}

test "websocket frame masked" {
    const testing = std.testing;

    const frame = Frame.initMasked(.binary, "Test");
    try testing.expect(frame.fin);
    try testing.expectEqual(OpCode.binary, frame.opcode);
    try testing.expect(frame.masked);
}

test "websocket close code" {
    const testing = std.testing;

    try testing.expectEqual(@as(u16, 1000), @intFromEnum(CloseCode.normal));
    try testing.expectEqual(@as(u16, 1001), @intFromEnum(CloseCode.going_away));
}

test "websocket accept key generation" {
    const testing = std.testing;

    // Test vector from RFC 6455
    const client_key = "dGhlIHNhbXBsZSBub25jZQ==";
    const accept = generateAcceptKey(client_key);
    try testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &accept);
}

test "url parsing" {
    const testing = std.testing;

    var client = try WebSocketClient.init(testing.allocator, "ws://localhost:8080/chat");
    defer client.deinit();

    try testing.expectEqualStrings("localhost", client.host);
    try testing.expectEqual(@as(u16, 8080), client.port);
    try testing.expectEqualStrings("/chat", client.path);
}

test "url parsing default port" {
    const testing = std.testing;

    var client = try WebSocketClient.init(testing.allocator, "ws://example.com/ws");
    defer client.deinit();

    try testing.expectEqualStrings("example.com", client.host);
    try testing.expectEqual(@as(u16, 80), client.port);
    try testing.expectEqualStrings("/ws", client.path);
}
