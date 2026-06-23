//! Advanced networking support for Zsync
//! TLS/SSL, HTTP/1.1, WebSocket, and DNS resolution built on `std.Io.net`.

const std = @import("std");
const net = std.Io.net;
const tls = std.crypto.tls;

const MAX_HEADER_BYTES: usize = 64 * 1024;
const MAX_BODY_BYTES: usize = 16 * 1024 * 1024;

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
pub const TlsBackend = enum {
    /// Native TLS should use Zig std's TLS client implementation.
    std_crypto_tls,
};

pub const default_tls_backend: TlsBackend = .std_crypto_tls;

pub const TlsVerification = enum {
    /// Use the operating system/default certificate roots.
    system_roots,
    /// Use a PEM CA bundle file from `TlsConfig.ca_bundle_path`.
    custom_ca_bundle,
    /// Accept a valid self-signed server certificate.
    self_signed,
    /// Disable certificate and host verification.
    disabled,
};

pub const TlsConfig = struct {
    backend: TlsBackend = default_tls_backend,
    verification: TlsVerification = .system_roots,
    verify_certificates: bool = true,
    server_name: ?[]const u8 = null,
    ca_bundle_path: ?[]const u8 = null,
    client_cert_path: ?[]const u8 = null,
    client_key_path: ?[]const u8 = null,
    cipher_suites: []const CipherSuite = &.{},
    protocols: []const TlsVersion = &.{ .tls_1_2, .tls_1_3 },
    allow_truncation_attacks: bool = false,
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
    net_reader: net.Stream.Reader,
    net_writer: net.Stream.Writer,
    client: ?tls.Client = null,
    net_read_buffer: []u8,
    net_write_buffer: []u8,
    tls_read_buffer: []u8,
    tls_write_buffer: []u8,
    ca_bundle: std.crypto.Certificate.Bundle = .empty,
    ca_bundle_lock: std.Io.RwLock = .init,
    last_alert: ?tls.Alert = null,
    allocator: std.mem.Allocator,
    closed: bool = false,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, io: std.Io, stream: net.Stream) !Self {
        const net_read_buffer = try allocator.alloc(u8, tls.Client.min_buffer_len);
        errdefer allocator.free(net_read_buffer);
        const net_write_buffer = try allocator.alloc(u8, tls.Client.min_buffer_len);
        errdefer allocator.free(net_write_buffer);
        const tls_read_buffer = try allocator.alloc(u8, tls.Client.min_buffer_len);
        errdefer allocator.free(tls_read_buffer);
        const tls_write_buffer = try allocator.alloc(u8, tls.Client.min_buffer_len);
        errdefer allocator.free(tls_write_buffer);

        return Self{
            .io = io,
            .inner_stream = stream,
            .net_read_buffer = net_read_buffer,
            .net_write_buffer = net_write_buffer,
            .tls_read_buffer = tls_read_buffer,
            .tls_write_buffer = tls_write_buffer,
            .net_reader = undefined,
            .net_writer = undefined,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.close();
        self.ca_bundle.deinit(self.allocator);
        self.allocator.free(self.net_read_buffer);
        self.allocator.free(self.net_write_buffer);
        self.allocator.free(self.tls_read_buffer);
        self.allocator.free(self.tls_write_buffer);
    }

    /// Perform TLS handshake.
    ///
    pub fn handshake(self: *Self, config: TlsConfig) !void {
        const host = config.server_name orelse if (config.verify_certificates)
            return error.TlsMissingServerName
        else
            "";
        try self.handshakeHost(config, host);
    }

    pub fn handshakeHost(self: *Self, config: TlsConfig, host: []const u8) !void {
        if (config.backend != .std_crypto_tls) return error.TlsUnsupported;
        if (config.client_cert_path != null) return error.TlsUnsupported;
        if (config.client_key_path != null) return error.TlsUnsupported;
        if (config.cipher_suites.len != 0) return error.TlsUnsupported;
        if (self.client != null) return;

        const verification = effectiveTlsVerification(config);
        const verify_host = verification != .disabled;
        if (verify_host and host.len == 0) return error.TlsMissingServerName;
        if (verification == .custom_ca_bundle and config.ca_bundle_path == null) {
            return error.TlsMissingCaBundlePath;
        }
        if (verification != .custom_ca_bundle and config.ca_bundle_path != null) {
            return error.TlsUnsupported;
        }

        self.net_reader = self.inner_stream.reader(self.io, self.net_read_buffer);
        self.net_writer = self.inner_stream.writer(self.io, self.net_write_buffer);

        var entropy: [tls.Client.Options.entropy_len]u8 = undefined;
        try self.io.randomSecure(&entropy);

        try self.prepareCaBundle(config, verification);

        var alert: tls.Alert = undefined;
        self.last_alert = null;
        self.client = tls.Client.init(&self.net_reader.interface, &self.net_writer.interface, .{
            .host = if (verify_host) .{ .explicit = host } else .no_verification,
            .ca = switch (verification) {
                .disabled => .no_verification,
                .self_signed => .self_signed,
                .system_roots, .custom_ca_bundle => .{ .bundle = .{
                    .gpa = self.allocator,
                    .io = self.io,
                    .lock = &self.ca_bundle_lock,
                    .bundle = &self.ca_bundle,
                } },
            },
            .write_buffer = self.tls_write_buffer,
            .read_buffer = self.tls_read_buffer,
            .entropy = &entropy,
            .realtime_now = std.Io.Clock.real.now(self.io),
            .allow_truncation_attacks = config.allow_truncation_attacks,
            .alert = &alert,
        }) catch |err| {
            if (err == error.TlsAlert) self.last_alert = alert;
            return err;
        };
    }

    fn prepareCaBundle(self: *Self, config: TlsConfig, verification: TlsVerification) !void {
        switch (verification) {
            .disabled, .self_signed => return,
            .system_roots => {
                if (self.ca_bundle.bytes.items.len == 0) {
                    try self.ca_bundle.rescan(self.allocator, self.io, std.Io.Clock.real.now(self.io));
                }
                return;
            },
            .custom_ca_bundle => {},
        }

        self.ca_bundle.deinit(self.allocator);
        self.ca_bundle = .empty;

        const path = config.ca_bundle_path orelse return error.TlsMissingCaBundlePath;
        const now = std.Io.Clock.real.now(self.io);
        if (std.fs.path.isAbsolute(path)) {
            try self.ca_bundle.addCertsFromFilePathAbsolute(self.allocator, self.io, now, path);
        } else {
            try self.ca_bundle.addCertsFromFilePath(self.allocator, self.io, now, std.Io.Dir.cwd(), path);
        }
    }

    pub fn getLastAlert(self: *const Self) ?tls.Alert {
        return self.last_alert;
    }

    /// Read from TLS stream
    pub fn read(self: *Self, buffer: []u8) !usize {
        if (self.client) |*client| {
            return client.reader.readSliceShort(buffer);
        }
        return error.HandshakeNotComplete;
    }

    /// Write to TLS stream
    pub fn write(self: *Self, data: []const u8) !usize {
        try self.writeAll(data);
        return data.len;
    }

    pub fn writeAll(self: *Self, data: []const u8) !void {
        if (self.client) |*client| {
            try client.writer.writeAll(data);
            try client.writer.flush();
            return;
        }
        return error.HandshakeNotComplete;
    }

    /// Close TLS stream
    pub fn close(self: *Self) void {
        if (self.closed) return;
        if (self.client) |*client| {
            client.end() catch {};
            self.client = null;
        }
        self.inner_stream.close(self.io);
        self.closed = true;
    }
};

fn effectiveTlsVerification(config: TlsConfig) TlsVerification {
    if (!config.verify_certificates) return .disabled;
    if (config.ca_bundle_path != null and config.verification == .system_roots) return .custom_ca_bundle;
    return config.verification;
}

fn httpVersionText(version: HttpVersion) []const u8 {
    return switch (version) {
        .http_1_0 => "HTTP/1.0",
        .http_1_1 => "HTTP/1.1",
        .http_2_0 => "HTTP/2",
    };
}

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
        try writer.print("{s} {s} {s}\r\n", .{ @tagName(self.method), self.uri, httpVersionText(self.version) });

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
    owns_status_text: bool = false,
    owns_body: bool = false,

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
        if (self.owns_status_text) self.allocator.free(self.status_text);
        var header_iter = self.headers.iterator();
        while (header_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.headers.deinit();
        if (self.owns_body) {
            if (self.body) |body| self.allocator.free(body);
        }
    }

    pub fn setHeader(self: *Self, name: []const u8, value: []const u8) !void {
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const owned_value = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned_value);

        if (self.headers.fetchRemove(name)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value);
        }

        try self.headers.put(owned_name, owned_value);
    }

    pub fn serialize(self: *Self, writer: *std.Io.Writer) !void {
        // Write status line
        try writer.print("{s} {d} {s}\r\n", .{ httpVersionText(self.version), self.status_code, self.status_text });

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

    pub fn setDefaultHeader(self: *Self, name: []const u8, value: []const u8) !void {
        try self.default_headers.put(name, value);
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

        var allocating = std.Io.Writer.Allocating.init(self.allocator);
        defer allocating.deinit();

        try self.serializeRequest(req, &uri_info, &allocating.writer);
        const request_bytes = allocating.written();

        const response_bytes = if (uri_info.is_https) https: {
            var tls_stream = try TlsStream.init(self.allocator, self.io, stream);
            defer tls_stream.deinit();

            var tls_config = self.tls_config;
            if (tls_config.server_name == null) tls_config.server_name = uri_info.host;
            try tls_stream.handshakeHost(tls_config, uri_info.host);
            try tls_stream.writeAll(request_bytes);
            break :https try self.readResponse(.{ .tls = &tls_stream });
        } else plain: {
            defer stream.close(self.io);
            try streamWriteAll(self.io, stream, request_bytes);
            break :plain try self.readResponse(.{ .plain = stream });
        };
        defer self.allocator.free(response_bytes);
        return self.parseResponse(response_bytes);
    }

    const ResponseSource = union(enum) {
        plain: net.Stream,
        tls: *TlsStream,

        fn read(self: ResponseSource, io: std.Io, buffer: []u8) !usize {
            return switch (self) {
                .plain => |stream| streamRead(io, stream, buffer),
                .tls => |tls_stream| tls_stream.read(buffer),
            };
        }
    };

    const UriInfo = struct {
        host: []u8,
        port: u16,
        path: []u8,
        is_https: bool,
    };

    fn parseUri(self: *Self, uri: []const u8) !UriInfo {
        const allocator = self.allocator;
        if (std.mem.startsWith(u8, uri, "https://")) {
            const without_scheme = uri[8..];
            const slash_pos = std.mem.indexOf(u8, without_scheme, "/") orelse without_scheme.len;
            const host_port = without_scheme[0..slash_pos];
            const path = if (slash_pos < without_scheme.len) without_scheme[slash_pos..] else "/";

            const colon_pos = std.mem.indexOf(u8, host_port, ":");
            const host = if (colon_pos) |pos| host_port[0..pos] else host_port;
            if (host.len == 0) return error.InvalidUri;
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
            if (host.len == 0) return error.InvalidUri;
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

    fn serializeRequest(self: *Self, req: *HttpRequest, uri_info: *const UriInfo, writer: *std.Io.Writer) !void {
        try writer.print("{s} {s} {s}\r\n", .{ @tagName(req.method), uri_info.path, httpVersionText(req.version) });

        const default_port: u16 = if (uri_info.is_https) 443 else 80;
        const needs_port = uri_info.port != default_port;
        var host_buffer: [256 + 8]u8 = undefined;
        const host_value = if (needs_port)
            try std.fmt.bufPrint(&host_buffer, "{s}:{d}", .{ uri_info.host, uri_info.port })
        else
            uri_info.host;

        if (!headerMapContains(req.headers, "Host") and !headerMapContains(self.default_headers, "Host")) {
            try writer.print("Host: {s}\r\n", .{host_value});
        }
        if (!headerMapContains(req.headers, "Connection") and !headerMapContains(self.default_headers, "Connection")) {
            try writer.writeAll("Connection: close\r\n");
        }
        if (req.body) |body| {
            if (!headerMapContains(req.headers, "Content-Length") and !headerMapContains(self.default_headers, "Content-Length")) {
                try writer.print("Content-Length: {d}\r\n", .{body.len});
            }
        }

        var default_iter = self.default_headers.iterator();
        while (default_iter.next()) |entry| {
            if (!headerMapContains(req.headers, entry.key_ptr.*)) {
                try writer.print("{s}: {s}\r\n", .{ entry.key_ptr.*, entry.value_ptr.* });
            }
        }

        var header_iter = req.headers.iterator();
        while (header_iter.next()) |entry| {
            try writer.print("{s}: {s}\r\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }

        try writer.writeAll("\r\n");
        if (req.body) |body| try writer.writeAll(body);
    }

    fn headerMapContains(headers: std.StringHashMap([]const u8), name: []const u8) bool {
        var iter = headers.iterator();
        while (iter.next()) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, name)) return true;
        }
        return false;
    }

    fn readResponse(self: *Self, source: ResponseSource) ![]u8 {
        var bytes: std.ArrayList(u8) = .empty;
        errdefer bytes.deinit(self.allocator);

        var chunk: [4096]u8 = undefined;
        var header_end: ?usize = null;

        while (header_end == null) {
            const n = try source.read(self.io, &chunk);
            if (n == 0) return error.InvalidResponse;
            try bytes.appendSlice(self.allocator, chunk[0..n]);
            if (bytes.items.len > MAX_HEADER_BYTES) return error.HttpHeadersTooLarge;
            header_end = std.mem.indexOf(u8, bytes.items, "\r\n\r\n");
        }

        const body_start = header_end.? + 4;
        const content_length = try parseContentLength(bytes.items[0..header_end.?]);
        if (content_length) |len| {
            if (len > MAX_BODY_BYTES) return error.HttpBodyTooLarge;
            while (bytes.items.len - body_start < len) {
                const n = try source.read(self.io, &chunk);
                if (n == 0) return error.EndOfStream;
                try bytes.appendSlice(self.allocator, chunk[0..n]);
            }
            const total_len = body_start + len;
            if (bytes.items.len > total_len) bytes.shrinkRetainingCapacity(total_len);
        } else {
            while (true) {
                if (bytes.items.len - body_start > MAX_BODY_BYTES) return error.HttpBodyTooLarge;
                const n = try source.read(self.io, &chunk);
                if (n == 0) break;
                try bytes.appendSlice(self.allocator, chunk[0..n]);
            }
        }

        return bytes.toOwnedSlice(self.allocator);
    }

    fn parseContentLength(headers_section: []const u8) !?usize {
        var lines = std.mem.splitSequence(u8, headers_section, "\r\n");
        _ = lines.next();
        while (lines.next()) |line| {
            const colon_pos = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const name = std.mem.trim(u8, line[0..colon_pos], " \t");
            if (!std.ascii.eqlIgnoreCase(name, "Content-Length")) continue;
            const value = std.mem.trim(u8, line[colon_pos + 1 ..], " \t");
            return std.fmt.parseInt(usize, value, 10) catch return error.InvalidResponse;
        }
        return null;
    }

    fn parseResponse(self: *Self, data: []const u8) !HttpResponse {
        var response = HttpResponse.init(self.allocator);
        errdefer response.deinit();

        // Find end of headers
        const header_end = std.mem.indexOf(u8, data, "\r\n\r\n") orelse return error.InvalidResponse;
        const headers_section = data[0..header_end];
        const body_section = if (header_end + 4 < data.len) data[header_end + 4 ..] else null;

        var lines = std.mem.splitSequence(u8, headers_section, "\r\n");

        // Parse status line
        const status_line = lines.next() orelse return error.InvalidResponse;
        var parts = std.mem.splitScalar(u8, status_line, ' ');
        const version_text = parts.next() orelse return error.InvalidResponse;
        response.version = parseHttpVersion(version_text) orelse return error.InvalidResponse;
        const status_code_str = parts.next() orelse return error.InvalidResponse;
        response.status_code = try std.fmt.parseInt(u16, status_code_str, 10);
        const status_text_start = version_text.len + 1 + status_code_str.len;
        const status_text = if (status_line.len > status_text_start + 1) status_line[status_text_start + 1 ..] else "";
        response.status_text = try self.allocator.dupe(u8, status_text);
        response.owns_status_text = true;

        // Parse headers
        while (lines.next()) |line| {
            if (std.mem.indexOf(u8, line, ":")) |colon_pos| {
                const name = std.mem.trim(u8, line[0..colon_pos], " \t");
                const value = std.mem.trim(u8, line[colon_pos + 1 ..], " \t");
                try response.setHeader(name, value);
            }
        }

        // Set body
        if (body_section) |body| {
            response.body = try self.allocator.dupe(u8, body);
            response.owns_body = true;
        }

        return response;
    }

    fn parseHttpVersion(text: []const u8) ?HttpVersion {
        if (std.mem.eql(u8, text, "HTTP/1.0")) return .http_1_0;
        if (std.mem.eql(u8, text, "HTTP/1.1")) return .http_1_1;
        if (std.mem.eql(u8, text, "HTTP/2")) return .http_2_0;
        return null;
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

test "tls config derives verification mode from compatibility fields" {
    const testing = std.testing;

    try testing.expectEqual(TlsVerification.system_roots, effectiveTlsVerification(.{}));
    try testing.expectEqual(TlsVerification.disabled, effectiveTlsVerification(.{ .verify_certificates = false }));
    try testing.expectEqual(TlsVerification.custom_ca_bundle, effectiveTlsVerification(.{ .ca_bundle_path = "ca.pem" }));
    try testing.expectEqual(TlsVerification.self_signed, effectiveTlsVerification(.{ .verification = .self_signed }));
}

fn readHttpRequestForTest(io: std.Io, stream: net.Stream, allocator: std.mem.Allocator) ![]u8 {
    var request: std.ArrayList(u8) = .empty;
    errdefer request.deinit(allocator);

    var chunk: [1024]u8 = undefined;
    while (std.mem.indexOf(u8, request.items, "\r\n\r\n") == null) {
        const n = try streamRead(io, stream, &chunk);
        if (n == 0) return error.EndOfStream;
        try request.appendSlice(allocator, chunk[0..n]);
        if (request.items.len > MAX_HEADER_BYTES) return error.HttpHeadersTooLarge;
    }

    return request.toOwnedSlice(allocator);
}

fn httpRequestServerForTest(
    io: std.Io,
    allocator: std.mem.Allocator,
    server: *net.Server,
    captured_request: *[]u8,
) !void {
    const stream = try server.accept(io);
    defer stream.close(io);

    captured_request.* = try readHttpRequestForTest(io, stream, allocator);
    try streamWriteAll(io, stream, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK");
}

test "http client sends origin-form path host and default headers" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const port: u16 = 39_128;
    const addr = net.IpAddress.parse("127.0.0.1", port) catch unreachable;
    var server = addr.listen(io, .{ .reuse_address = true }) catch |err| switch (err) {
        error.AddressInUse => return error.SkipZigTest,
        else => return err,
    };
    defer server.deinit(io);

    var captured_request: []u8 = &.{};
    defer allocator.free(captured_request);
    var server_future = try io.concurrent(httpRequestServerForTest, .{ io, allocator, &server, &captured_request });

    var client = HttpClient.init(allocator, io, .{});
    defer client.deinit();
    try client.setDefaultHeader("User-Agent", "zsync-test");

    var uri_buf: [96]u8 = undefined;
    const uri = try std.fmt.bufPrint(&uri_buf, "http://127.0.0.1:{d}/hello?name=zsync", .{port});
    var request = HttpRequest.init(allocator);
    defer request.deinit();
    request.uri = uri;

    var response = try client.request(&request);
    defer response.deinit();
    try server_future.await(io);

    try testing.expectEqual(@as(u16, 200), response.status_code);
    try testing.expectEqualStrings("OK", response.body.?);
    try testing.expect(std.mem.startsWith(u8, captured_request, "GET /hello?name=zsync HTTP/1.1\r\n"));
    try testing.expect(std.mem.indexOf(u8, captured_request, "\r\nHost: 127.0.0.1:39128\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, captured_request, "\r\nUser-Agent: zsync-test\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, captured_request, "GET http://") == null);
}

fn httpLargeBodyServerForTest(io: std.Io, allocator: std.mem.Allocator, server: *net.Server) !void {
    const stream = try server.accept(io);
    defer stream.close(io);

    const request = try readHttpRequestForTest(io, stream, allocator);
    defer allocator.free(request);

    const body_len: usize = 9 * 1024;
    var header: [128]u8 = undefined;
    const header_bytes = try std.fmt.bufPrint(&header, "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{body_len});
    try streamWriteAll(io, stream, header_bytes);

    const body = try allocator.alloc(u8, body_len);
    defer allocator.free(body);
    @memset(body, 'x');
    try streamWriteAll(io, stream, body);
}

test "http client reads content-length body larger than 8KiB" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const port: u16 = 39_129;
    const addr = net.IpAddress.parse("127.0.0.1", port) catch unreachable;
    var server = addr.listen(io, .{ .reuse_address = true }) catch |err| switch (err) {
        error.AddressInUse => return error.SkipZigTest,
        else => return err,
    };
    defer server.deinit(io);

    var server_future = try io.concurrent(httpLargeBodyServerForTest, .{ io, allocator, &server });

    var client = HttpClient.init(allocator, io, .{});
    defer client.deinit();

    var uri_buf: [64]u8 = undefined;
    const uri = try std.fmt.bufPrint(&uri_buf, "http://127.0.0.1:{d}/large", .{port});
    var request = HttpRequest.init(allocator);
    defer request.deinit();
    request.uri = uri;

    var response = try client.request(&request);
    defer response.deinit();
    try server_future.await(io);

    try testing.expectEqual(@as(usize, 9 * 1024), response.body.?.len);
    try testing.expectEqual(@as(u8, 'x'), response.body.?[0]);
    try testing.expectEqual(@as(u8, 'x'), response.body.?[response.body.?.len - 1]);
}

test "http response parser rejects malformed status line" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var client = HttpClient.init(allocator, io, .{});
    defer client.deinit();

    try testing.expectError(error.InvalidResponse, client.parseResponse("not-http\r\nContent-Length: 0\r\n\r\n"));
}

test "http client rejects invalid URI" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var client = HttpClient.init(allocator, io, .{});
    defer client.deinit();

    var invalid = HttpRequest.init(allocator);
    defer invalid.deinit();
    invalid.uri = "/relative";
    try testing.expectError(error.InvalidUri, client.request(&invalid));
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
