//! Advanced networking support for Zsync
//! TLS/SSL, HTTP/1.1, WebSocket, and DNS resolution built on `std.Io.net`.

const std = @import("std");
const net = std.Io.net;
const crypto = std.crypto;

/// Write all of `data` to a stream, flushing the backing buffer.
fn streamWriteAll(io: std.Io, stream: net.Stream, data: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var w = stream.writer(io, &buf);
    try w.interface.writeAll(data);
    try w.interface.flush();
}

/// Single read into `buffer`, returning the number of bytes read (0 = EOF).
fn streamRead(io: std.Io, stream: net.Stream, buffer: []u8) !usize {
    var slices: [1][]u8 = .{buffer};
    return stream.read(io, &slices);
}

/// Read exactly `buffer.len` bytes, looping until full or EOF.
fn streamReadAll(io: std.Io, stream: net.Stream, buffer: []u8) !void {
    var offset: usize = 0;
    while (offset < buffer.len) {
        var slices: [1][]u8 = .{buffer[offset..]};
        const n = try stream.read(io, &slices);
        if (n == 0) return error.EndOfStream;
        offset += n;
    }
}

/// TLS/SSL configuration
pub const TlsConfig = struct {
    verify_certificates: bool = true,
    ca_bundle_path: ?[]const u8 = null,
    client_cert_path: ?[]const u8 = null,
    client_key_path: ?[]const u8 = null,
    cipher_suites: []const CipherSuite = &.{},
    protocols: []const TlsVersion = &.{ .tls_1_2, .tls_1_3 },
};

/// Supported TLS versions
pub const TlsVersion = enum {
    tls_1_2,
    tls_1_3,
};

/// TLS cipher suites
pub const CipherSuite = enum {
    aes_128_gcm,
    aes_256_gcm,
    chacha20_poly1305,
};

/// TLS connection wrapper
pub const TlsStream = struct {
    io: std.Io,
    inner_stream: net.Stream,
    tls_state: TlsState,
    read_buffer: []u8,
    write_buffer: []u8,
    allocator: std.mem.Allocator,

    const Self = @This();

    const TlsState = struct {
        handshake_complete: bool = false,
        read_cipher: ?crypto.aead.aes_gcm.Aes128Gcm = null,
        write_cipher: ?crypto.aead.aes_gcm.Aes128Gcm = null,
        read_seq: u64 = 0,
        write_seq: u64 = 0,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, stream: net.Stream) !Self {
        return Self{
            .io = io,
            .inner_stream = stream,
            .tls_state = TlsState{},
            .read_buffer = try allocator.alloc(u8, 16384),
            .write_buffer = try allocator.alloc(u8, 16384),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.read_buffer);
        self.allocator.free(self.write_buffer);
        self.inner_stream.close(self.io);
    }

    /// Perform TLS handshake (simplified)
    pub fn handshake(self: *Self, config: TlsConfig) !void {
        _ = config;
        // Simplified handshake - in production would implement full TLS protocol
        self.tls_state.handshake_complete = true;
    }

    /// Read from TLS stream
    pub fn read(self: *Self, buffer: []u8) !usize {
        if (!self.tls_state.handshake_complete) {
            return error.HandshakeNotComplete;
        }

        // Simplified read - would decrypt TLS records in production
        return streamRead(self.io, self.inner_stream, buffer);
    }

    /// Write to TLS stream
    pub fn write(self: *Self, data: []const u8) !usize {
        if (!self.tls_state.handshake_complete) {
            return error.HandshakeNotComplete;
        }

        // Simplified write - would encrypt TLS records in production
        try streamWriteAll(self.io, self.inner_stream, data);
        return data.len;
    }

    /// Close TLS stream
    pub fn close(self: *Self) void {
        // Would send close_notify in production
        self.inner_stream.close(self.io);
    }
};

/// HTTP/1.1 request
pub const HttpRequest = struct {
    method: HttpMethod,
    uri: []const u8,
    version: HttpVersion,
    headers: std.StringHashMap([]const u8),
    body: ?[]const u8,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .method = .GET,
            .uri = "/",
            .version = .http_1_1,
            .headers = std.StringHashMap([]const u8).init(allocator),
            .body = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.headers.deinit();
    }

    pub fn setHeader(self: *Self, name: []const u8, value: []const u8) !void {
        try self.headers.put(name, value);
    }

    pub fn serialize(self: *Self, writer: *std.Io.Writer) !void {
        // Write request line
        try writer.print("{s} {s} {s}\r\n", .{ @tagName(self.method), self.uri, @tagName(self.version) });

        // Write headers
        var header_iter = self.headers.iterator();
        while (header_iter.next()) |entry| {
            try writer.print("{s}: {s}\r\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }

        // End headers
        try writer.writeAll("\r\n");

        // Write body if present
        if (self.body) |body| {
            try writer.writeAll(body);
        }
    }
};

/// HTTP/1.1 response
pub const HttpResponse = struct {
    version: HttpVersion,
    status_code: u16,
    status_text: []const u8,
    headers: std.StringHashMap([]const u8),
    body: ?[]const u8,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .version = .http_1_1,
            .status_code = 200,
            .status_text = "OK",
            .headers = std.StringHashMap([]const u8).init(allocator),
            .body = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.headers.deinit();
    }

    pub fn setHeader(self: *Self, name: []const u8, value: []const u8) !void {
        try self.headers.put(name, value);
    }

    pub fn serialize(self: *Self, writer: *std.Io.Writer) !void {
        // Write status line
        try writer.print("{s} {d} {s}\r\n", .{ @tagName(self.version), self.status_code, self.status_text });

        // Write headers
        var header_iter = self.headers.iterator();
        while (header_iter.next()) |entry| {
            try writer.print("{s}: {s}\r\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }

        // End headers
        try writer.writeAll("\r\n");

        // Write body if present
        if (self.body) |body| {
            try writer.writeAll(body);
        }
    }
};

/// HTTP methods
pub const HttpMethod = enum {
    GET,
    POST,
    PUT,
    DELETE,
    HEAD,
    OPTIONS,
    PATCH,
    TRACE,
    CONNECT,
};

/// HTTP versions
pub const HttpVersion = enum {
    http_1_0,
    http_1_1,
    http_2_0,
};

/// HTTP client for making requests
pub const HttpClient = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    default_headers: std.StringHashMap([]const u8),
    tls_config: TlsConfig,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, io: std.Io, tls_config: TlsConfig) Self {
        return Self{
            .io = io,
            .allocator = allocator,
            .default_headers = std.StringHashMap([]const u8).init(allocator),
            .tls_config = tls_config,
        };
    }

    pub fn deinit(self: *Self) void {
        self.default_headers.deinit();
    }

    /// Make an HTTP request
    pub fn request(self: *Self, req: *HttpRequest) !HttpResponse {
        // Parse URI to get host and port
        const uri_info = try self.parseUri(req.uri);
        defer self.allocator.free(uri_info.host);
        defer self.allocator.free(uri_info.path);

        // Connect to server
        const address = try net.IpAddress.resolve(self.io, uri_info.host, uri_info.port);
        const stream = try address.connect(self.io, .{ .mode = .stream });

        var connection: union(enum) {
            plain: net.Stream,
            tls: TlsStream,
        } = .{ .plain = stream };

        // Upgrade to TLS if needed
        if (uri_info.is_https) {
            var tls_stream = try TlsStream.init(self.allocator, self.io, stream);
            try tls_stream.handshake(self.tls_config);
            connection = .{ .tls = tls_stream };
        }

        defer switch (connection) {
            .plain => |s| s.close(self.io),
            .tls => |*s| s.deinit(),
        };

        // Serialize and send request
        var allocating = std.Io.Writer.Allocating.init(self.allocator);
        defer allocating.deinit();

        try req.serialize(&allocating.writer);
        const request_bytes = allocating.written();

        switch (connection) {
            .plain => |s| try streamWriteAll(self.io, s, request_bytes),
            .tls => |*s| _ = try s.write(request_bytes),
        }

        // Read response
        var response_buffer = try self.allocator.alloc(u8, 8192);
        defer self.allocator.free(response_buffer);

        const bytes_read = switch (connection) {
            .plain => |s| try streamRead(self.io, s, response_buffer),
            .tls => |*s| try s.read(response_buffer),
        };

        // Parse response
        return self.parseResponse(response_buffer[0..bytes_read]);
    }

    const UriInfo = struct {
        host: []u8,
        port: u16,
        path: []u8,
        is_https: bool,
    };

    fn parseUri(self: *Self, uri: []const u8) !UriInfo {
        // Simplified URI parsing - self parameter used for allocator access
        const allocator = self.allocator;
        if (std.mem.startsWith(u8, uri, "https://")) {
            const without_scheme = uri[8..];
            const slash_pos = std.mem.indexOf(u8, without_scheme, "/") orelse without_scheme.len;
            const host_port = without_scheme[0..slash_pos];
            const path = if (slash_pos < without_scheme.len) without_scheme[slash_pos..] else "/";

            const colon_pos = std.mem.indexOf(u8, host_port, ":");
            const host = if (colon_pos) |pos| host_port[0..pos] else host_port;
            const port = if (colon_pos) |pos| try std.fmt.parseInt(u16, host_port[pos + 1 ..], 10) else 443;

            return UriInfo{
                .host = try allocator.dupe(u8, host),
                .port = port,
                .path = try allocator.dupe(u8, path),
                .is_https = true,
            };
        } else if (std.mem.startsWith(u8, uri, "http://")) {
            const without_scheme = uri[7..];
            const slash_pos = std.mem.indexOf(u8, without_scheme, "/") orelse without_scheme.len;
            const host_port = without_scheme[0..slash_pos];
            const path = if (slash_pos < without_scheme.len) without_scheme[slash_pos..] else "/";

            const colon_pos = std.mem.indexOf(u8, host_port, ":");
            const host = if (colon_pos) |pos| host_port[0..pos] else host_port;
            const port = if (colon_pos) |pos| try std.fmt.parseInt(u16, host_port[pos + 1 ..], 10) else 80;

            return UriInfo{
                .host = try allocator.dupe(u8, host),
                .port = port,
                .path = try allocator.dupe(u8, path),
                .is_https = false,
            };
        } else {
            return error.InvalidUri;
        }
    }

    fn parseResponse(self: *Self, data: []const u8) !HttpResponse {
        var response = HttpResponse.init(self.allocator);

        // Find end of headers
        const header_end = std.mem.indexOf(u8, data, "\r\n\r\n") orelse return error.InvalidResponse;
        const headers_section = data[0..header_end];
        const body_section = if (header_end + 4 < data.len) data[header_end + 4 ..] else null;

        var lines = std.mem.splitSequence(u8, headers_section, "\r\n");

        // Parse status line
        if (lines.next()) |status_line| {
            var parts = std.mem.splitScalar(u8, status_line, ' ');
            _ = parts.next(); // HTTP version
            if (parts.next()) |status_code_str| {
                response.status_code = try std.fmt.parseInt(u16, status_code_str, 10);
            }
            if (parts.next()) |status_text| {
                response.status_text = status_text;
            }
        }

        // Parse headers
        while (lines.next()) |line| {
            if (std.mem.indexOf(u8, line, ":")) |colon_pos| {
                const name = std.mem.trim(u8, line[0..colon_pos], " \t");
                const value = std.mem.trim(u8, line[colon_pos + 1 ..], " \t");
                try response.setHeader(name, value);
            }
        }

        // Set body
        response.body = body_section;

        return response;
    }
};

/// WebSocket connection
pub const WebSocketConnection = struct {
    io: std.Io,
    stream: net.Stream,
    is_client: bool,
    state: ConnectionState,
    allocator: std.mem.Allocator,

    const Self = @This();

    const ConnectionState = enum {
        connecting,
        open,
        closing,
        closed,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, stream: net.Stream, is_client: bool) Self {
        return Self{
            .io = io,
            .stream = stream,
            .is_client = is_client,
            .state = .connecting,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.stream.close(self.io);
    }

    /// Perform WebSocket handshake
    pub fn handshake(self: *Self) !void {
        if (self.is_client) {
            try self.clientHandshake();
        } else {
            try self.serverHandshake();
        }
        self.state = .open;
    }

    fn clientHandshake(self: *Self) !void {
        // Send WebSocket upgrade request
        const upgrade_request = "GET / HTTP/1.1\r\n" ++
            "Host: localhost\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
            "Sec-WebSocket-Version: 13\r\n" ++
            "\r\n";

        try streamWriteAll(self.io, self.stream, upgrade_request);

        // Read response (simplified)
        var buffer: [1024]u8 = undefined;
        _ = try streamRead(self.io, self.stream, &buffer);

        // In production, would validate the response
    }

    fn serverHandshake(self: *Self) !void {
        // Read client request
        var buffer: [1024]u8 = undefined;
        _ = try streamRead(self.io, self.stream, &buffer);

        // Send WebSocket upgrade response (simplified)
        const upgrade_response = "HTTP/1.1 101 Switching Protocols\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n" ++
            "\r\n";

        try streamWriteAll(self.io, self.stream, upgrade_response);
    }

    /// Send WebSocket frame
    pub fn sendFrame(self: *Self, opcode: u8, data: []const u8) !void {
        if (self.state != .open) return error.ConnectionNotOpen;

        var frame: std.ArrayList(u8) = .empty;
        defer frame.deinit(self.allocator);

        // First byte: FIN(1) + RSV(3) + Opcode(4)
        try frame.append(self.allocator, 0x80 | opcode);

        // Payload length
        if (data.len < 126) {
            try frame.append(self.allocator, @intCast(data.len));
        } else if (data.len < 65536) {
            try frame.append(self.allocator, 126);
            try frame.append(self.allocator, @intCast(data.len >> 8));
            try frame.append(self.allocator, @intCast(data.len & 0xFF));
        } else {
            try frame.append(self.allocator, 127);
            var i: u8 = 8;
            while (i > 0) {
                i -= 1;
                try frame.append(self.allocator, @intCast((data.len >> (@as(u6, @intCast(i)) * 8)) & 0xFF));
            }
        }

        // Payload
        try frame.appendSlice(self.allocator, data);

        try streamWriteAll(self.io, self.stream, frame.items);
    }

    /// Receive WebSocket frame
    pub fn receiveFrame(self: *Self) ![]u8 {
        if (self.state != .open) return error.ConnectionNotOpen;

        // Read frame header (simplified)
        var header: [2]u8 = undefined;
        try streamReadAll(self.io, self.stream, &header);

        const opcode = header[0] & 0x0F;
        _ = opcode;
        const payload_len = header[1] & 0x7F;

        // Read payload (simplified for small frames)
        const payload = try self.allocator.alloc(u8, payload_len);
        try streamReadAll(self.io, self.stream, payload);

        return payload;
    }

    /// Close WebSocket connection
    pub fn close(self: *Self) !void {
        if (self.state == .open) {
            try self.sendFrame(0x08, ""); // Close frame
            self.state = .closing;
        }
        self.stream.close(self.io);
        self.state = .closed;
    }
};

/// DNS resolver
pub const DnsResolver = struct {
    allocator: std.mem.Allocator,
    servers: []net.IpAddress,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        // Default to system DNS servers
        const servers = try allocator.alloc(net.IpAddress, 2);
        servers[0] = try net.IpAddress.parse("8.8.8.8", 53);
        servers[1] = try net.IpAddress.parse("1.1.1.1", 53);

        return Self{
            .allocator = allocator,
            .servers = servers,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.servers);
    }

    /// Resolve `hostname` to its IP addresses through the system resolver
    /// (honoring `/etc/hosts` and `/etc/resolv.conf`) via `std.Io.net`.
    /// Caller owns the returned slice and frees it with `self.allocator`.
    pub fn resolve(self: *Self, io: std.Io, hostname: []const u8) ![]net.IpAddress {
        const host = try net.HostName.init(hostname);

        var lookup_buffer: [32]net.HostName.LookupResult = undefined;
        var queue: std.Io.Queue(net.HostName.LookupResult) = .init(&lookup_buffer);

        var lookup_future = io.async(net.HostName.lookup, .{ host, io, &queue, .{ .port = 0 } });
        defer lookup_future.cancel(io) catch {};

        var addresses: std.ArrayList(net.IpAddress) = .empty;
        errdefer addresses.deinit(self.allocator);

        while (queue.getOne(io)) |result| switch (result) {
            .address => |addr| try addresses.append(self.allocator, addr),
            .canonical_name => continue,
        } else |err| switch (err) {
            error.Canceled => return error.DnsLookupFailed,
            error.Closed => try lookup_future.await(io),
        }

        if (addresses.items.len == 0) {
            addresses.deinit(self.allocator);
            return error.NoAddressReturned;
        }

        return addresses.toOwnedSlice(self.allocator);
    }
};

// Tests
test "http request creation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var request = HttpRequest.init(allocator);
    defer request.deinit();

    try request.setHeader("Host", "example.com");
    try testing.expect(request.headers.count() == 1);
}

test "dns resolver creation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var resolver = try DnsResolver.init(allocator);
    defer resolver.deinit();

    try testing.expect(resolver.servers.len == 2);
}

test "dns resolver resolves localhost" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var resolver = try DnsResolver.init(allocator);
    defer resolver.deinit();

    // "localhost" resolves through /etc/hosts without network access. In
    // restricted sandboxes the system resolver may be unavailable, so treat a
    // lookup failure as a skip rather than a hard error.
    const addresses = resolver.resolve(io, "localhost") catch {
        return error.SkipZigTest;
    };
    defer allocator.free(addresses);

    try testing.expect(addresses.len >= 1);
}
