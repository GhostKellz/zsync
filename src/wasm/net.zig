//! zsync WASM Networking
//! Real networking for `wasm32-freestanding` backed by synchronous JavaScript
//! host bindings. WebAssembly has no sockets of its own, so every operation is
//! delegated to the embedding host through the `env` import object. The host is
//! free to fulfil these with `fetch`, `WebSocket`, WebRTC data channels, a WASI
//! preview implementation, or a native bridge — zsync only defines the protocol.
//!
//! The public surface mirrors `networking.zig` so that code targeting zsync sees
//! the same types regardless of platform. Where the native API takes an already
//! connected `std.Io.net.Stream` (which cannot exist on a sandboxed wasm host),
//! the wasm type instead exposes a `connect`-style constructor that establishes
//! the connection through the host.

const std = @import("std");
const net = std.Io.net;

/// JavaScript host bindings. Only referenced on wasm32; the calls are never
/// emitted on other targets, so importing this module elsewhere stays link-safe.
const js = struct {
    // --- UDP datagram sockets ---------------------------------------------
    /// Bind a datagram socket to `ip`/`port`. Returns a non-negative handle or a
    /// negative error code.
    extern "env" fn zsync_udp_bind(ip_ptr: [*]const u8, ip_len: usize, port: u16) i32;
    /// Send `data` to `ip`/`port`. Returns bytes sent or a negative error code.
    extern "env" fn zsync_udp_send(
        handle: i32,
        data_ptr: [*]const u8,
        data_len: usize,
        ip_ptr: [*]const u8,
        ip_len: usize,
        port: u16,
    ) i32;
    /// Receive a datagram. The source address is written into `ip_out` (its byte
    /// length into `ip_len_out`, 4 for IPv4 or 16 for IPv6) and `port_out`.
    /// Returns the payload length or a negative error code.
    extern "env" fn zsync_udp_recv(
        handle: i32,
        buf_ptr: [*]u8,
        buf_len: usize,
        ip_out: [*]u8,
        ip_out_cap: usize,
        ip_len_out: *usize,
        port_out: *u16,
    ) i32;
    extern "env" fn zsync_udp_close(handle: i32) void;

    // --- DNS ---------------------------------------------------------------
    /// Resolve `host` to a list of addresses. Each record is written into `out`
    /// as one length byte (4 or 16) followed by that many address bytes. The
    /// number of records is written to `count_out`. Returns 0 or a negative
    /// error code.
    extern "env" fn zsync_dns_resolve(
        host_ptr: [*]const u8,
        host_len: usize,
        out_ptr: [*]u8,
        out_cap: usize,
        count_out: *usize,
    ) i32;

    // --- TCP / TLS streams -------------------------------------------------
    /// Open a stream connection. `tls` selects TLS (1) or plaintext (0). Returns
    /// a non-negative handle or a negative error code.
    extern "env" fn zsync_tcp_connect(host_ptr: [*]const u8, host_len: usize, port: u16, tls: i32) i32;
    extern "env" fn zsync_tcp_send(handle: i32, data_ptr: [*]const u8, data_len: usize) i32;
    extern "env" fn zsync_tcp_recv(handle: i32, buf_ptr: [*]u8, buf_len: usize) i32;
    extern "env" fn zsync_tcp_close(handle: i32) void;

    // --- WebSocket ---------------------------------------------------------
    extern "env" fn zsync_ws_open(url_ptr: [*]const u8, url_len: usize) i32;
    extern "env" fn zsync_ws_send(handle: i32, data_ptr: [*]const u8, data_len: usize, is_binary: i32) i32;
    extern "env" fn zsync_ws_recv(handle: i32, buf_ptr: [*]u8, buf_len: usize) i32;
    extern "env" fn zsync_ws_close(handle: i32) void;

    // --- HTTP (shared with wasm/async.zig fetch protocol) ------------------
    extern "env" fn zsync_fetch(
        method_ptr: [*]const u8,
        method_len: usize,
        url_ptr: [*]const u8,
        url_len: usize,
        body_ptr: [*]const u8,
        body_len: usize,
        status_out: *u16,
        body_len_out: *usize,
    ) i32;
    extern "env" fn zsync_fetch_read(handle: i32, dest: [*]u8, len: usize) void;
    extern "env" fn zsync_fetch_free(handle: i32) void;
};

/// Errors surfaced by the wasm networking layer.
pub const NetworkingError = error{
    NetworkingNotAvailable,
    HostCallFailed,
    ConnectionFailed,
    ConnectionClosed,
    InvalidUrl,
    InvalidAddress,
    BufferTooSmall,
    DnsLookupFailed,
    NoAddressReturned,
};

/// Copy an `IpAddress` into wire form (raw big-endian bytes + port).
fn addrToWire(addr: net.IpAddress, buf: *[16]u8) struct { len: usize, port: u16 } {
    return switch (addr) {
        .ip4 => |a| blk: {
            buf[0..4].* = a.bytes;
            break :blk .{ .len = 4, .port = a.port };
        },
        .ip6 => |a| blk: {
            buf[0..16].* = a.bytes;
            break :blk .{ .len = 16, .port = a.port };
        },
    };
}

/// Reconstruct an `IpAddress` from wire bytes and a port.
fn wireToAddr(bytes: []const u8, port: u16) NetworkingError!net.IpAddress {
    return switch (bytes.len) {
        4 => .{ .ip4 = .{ .bytes = bytes[0..4].*, .port = port } },
        16 => .{ .ip6 = .{ .bytes = bytes[0..16].*, .port = port } },
        else => error.InvalidAddress,
    };
}

/// UDP datagram socket over the host bridge. Signatures match the native
/// `UdpSocket` in `root.zig`; the `io` parameter is accepted for source
/// compatibility but unused because host calls are synchronous.
pub const UdpSocket = struct {
    handle: i32,

    const Self = @This();

    /// Bind a datagram socket to `address` via the host.
    pub fn bind(io: std.Io, address: net.IpAddress) !Self {
        _ = io;
        var wire: [16]u8 = undefined;
        const info = addrToWire(address, &wire);
        const handle = js.zsync_udp_bind(&wire, info.len, info.port);
        if (handle < 0) return error.NetworkingNotAvailable;
        return Self{ .handle = handle };
    }

    /// Send a datagram to `address`.
    pub fn sendTo(self: *Self, data: []const u8, address: net.IpAddress) !void {
        var wire: [16]u8 = undefined;
        const info = addrToWire(address, &wire);
        const n = js.zsync_udp_send(self.handle, data.ptr, data.len, &wire, info.len, info.port);
        if (n < 0) return error.HostCallFailed;
    }

    /// Receive a datagram, reporting the source address.
    pub fn recvFrom(self: *Self, buffer: []u8) !struct { bytes_received: usize, address: net.IpAddress } {
        var ip_out: [16]u8 = undefined;
        var ip_len: usize = 0;
        var port: u16 = 0;
        const n = js.zsync_udp_recv(self.handle, buffer.ptr, buffer.len, &ip_out, ip_out.len, &ip_len, &port);
        if (n < 0) return error.HostCallFailed;
        const address = try wireToAddr(ip_out[0..ip_len], port);
        return .{ .bytes_received = @intCast(n), .address = address };
    }

    /// Close the UDP socket.
    pub fn close(self: *Self) void {
        js.zsync_udp_close(self.handle);
    }
};

/// DNS resolver backed by the host resolver.
pub const DnsResolver = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Maximum addresses returned from a single lookup.
    const max_records = 16;
    /// Per-record wire size: 1 length byte + up to 16 address bytes.
    const record_size = 17;

    pub fn init(allocator: std.mem.Allocator) !Self {
        return Self{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    /// Resolve `hostname` to its IP addresses through the host. The `io`
    /// parameter mirrors the native signature and is unused here. Caller owns
    /// the returned slice and frees it with `self.allocator`.
    pub fn resolve(self: *Self, io: std.Io, hostname: []const u8) ![]net.IpAddress {
        _ = io;
        var wire: [max_records * record_size]u8 = undefined;
        var count: usize = 0;
        const rc = js.zsync_dns_resolve(hostname.ptr, hostname.len, &wire, wire.len, &count);
        if (rc < 0) return error.DnsLookupFailed;
        if (count == 0) return error.NoAddressReturned;
        if (count > max_records) count = max_records;

        const addresses = try self.allocator.alloc(net.IpAddress, count);
        errdefer self.allocator.free(addresses);

        var offset: usize = 0;
        for (addresses) |*slot| {
            if (offset >= wire.len) return error.DnsLookupFailed;
            const len = wire[offset];
            offset += 1;
            if (len != 4 and len != 16) return error.InvalidAddress;
            if (offset + len > wire.len) return error.DnsLookupFailed;
            slot.* = try wireToAddr(wire[offset .. offset + len], 0);
            offset += len;
        }
        return addresses;
    }
};

/// TLS configuration (mirrors `networking.TlsConfig`).
pub const TlsBackend = enum {
    /// WASM guests delegate TLS to the embedding host through `zsync_tcp_connect`.
    host_bridge,
};

pub const default_tls_backend: TlsBackend = .host_bridge;

pub const TlsConfig = struct {
    backend: TlsBackend = default_tls_backend,
    verify_certificates: bool = true,
    ca_bundle_path: ?[]const u8 = null,
    client_cert_path: ?[]const u8 = null,
    client_key_path: ?[]const u8 = null,
    cipher_suites: []const CipherSuite = &.{},
    protocols: []const TlsVersion = &.{ .tls_1_2, .tls_1_3 },
};

pub const TlsVersion = enum {
    tls_1_2,
    tls_1_3,
};

pub const CipherSuite = enum {
    aes_128_gcm,
    aes_256_gcm,
    chacha20_poly1305,
};

/// TLS (or plaintext) stream over the host TCP bridge.
///
/// Unlike the native `TlsStream`, which wraps an already-connected
/// `std.Io.net.Stream`, the wasm host has no such stream to wrap. Encryption is
/// terminated by the host, so this type establishes the connection itself with
/// `connect` and the host performs the TLS handshake when requested.
pub const TlsStream = struct {
    handle: i32,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Connect to `host`/`port`, performing a TLS handshake via the host.
    pub fn connect(allocator: std.mem.Allocator, host: []const u8, port: u16, config: TlsConfig) !Self {
        _ = config;
        const handle = js.zsync_tcp_connect(host.ptr, host.len, port, 1);
        if (handle < 0) return error.ConnectionFailed;
        return Self{ .handle = handle, .allocator = allocator };
    }

    /// Connect without TLS (plaintext TCP) via the host.
    pub fn connectPlain(allocator: std.mem.Allocator, host: []const u8, port: u16) !Self {
        const handle = js.zsync_tcp_connect(host.ptr, host.len, port, 0);
        if (handle < 0) return error.ConnectionFailed;
        return Self{ .handle = handle, .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        js.zsync_tcp_close(self.handle);
    }

    pub fn read(self: *Self, buffer: []u8) !usize {
        const n = js.zsync_tcp_recv(self.handle, buffer.ptr, buffer.len);
        if (n < 0) return error.ConnectionClosed;
        return @intCast(n);
    }

    pub fn write(self: *Self, data: []const u8) !usize {
        const n = js.zsync_tcp_send(self.handle, data.ptr, data.len);
        if (n < 0) return error.ConnectionClosed;
        return @intCast(n);
    }

    pub fn close(self: *Self) void {
        js.zsync_tcp_close(self.handle);
    }
};

/// HTTP methods (mirrors `networking.HttpMethod`).
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

/// HTTP versions (mirrors `networking.HttpVersion`).
pub const HttpVersion = enum {
    http_1_0,
    http_1_1,
    http_2_0,
};

/// HTTP/1.1 request (mirrors `networking.HttpRequest`).
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
};

/// HTTP/1.1 response (mirrors `networking.HttpResponse`).
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
        if (self.body) |body| self.allocator.free(body);
    }

    pub fn setHeader(self: *Self, name: []const u8, value: []const u8) !void {
        try self.headers.put(name, value);
    }
};

/// HTTP client backed by the host `fetch` implementation.
///
/// The `io` parameter mirrors the native `HttpClient.init` signature so that
/// `root.zig`'s `createHttpClient` works unchanged across targets. Requests are
/// dispatched synchronously through the host; `req.uri` must be an absolute URL.
pub const HttpClient = struct {
    allocator: std.mem.Allocator,
    tls_config: TlsConfig,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, io: std.Io, tls_config: TlsConfig) Self {
        _ = io;
        return Self{ .allocator = allocator, .tls_config = tls_config };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    /// Dispatch `req` through the host and return the response. The caller owns
    /// the returned `HttpResponse` and must `deinit` it.
    pub fn request(self: *Self, req: *HttpRequest) !HttpResponse {
        const method = @tagName(req.method);
        const body = req.body orelse "";

        var status: u16 = 0;
        var body_len: usize = 0;
        const handle = js.zsync_fetch(
            method.ptr,
            method.len,
            req.uri.ptr,
            req.uri.len,
            body.ptr,
            body.len,
            &status,
            &body_len,
        );
        if (handle < 0) return error.ConnectionFailed;
        defer js.zsync_fetch_free(handle);

        var response = HttpResponse.init(self.allocator);
        errdefer response.deinit();
        response.status_code = status;

        if (body_len > 0) {
            const buf = try self.allocator.alloc(u8, body_len);
            errdefer self.allocator.free(buf);
            js.zsync_fetch_read(handle, buf.ptr, buf.len);
            response.body = buf;
        }
        return response;
    }
};

/// WebSocket connection over the host bridge.
///
/// The native `WebSocketConnection.init` takes a pre-connected stream; on a wasm
/// host the connection must be opened through the host, so this type exposes a
/// `connect` constructor instead.
pub const WebSocketConnection = struct {
    handle: i32,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Open a WebSocket connection to `url` (ws:// or wss://) via the host.
    pub fn connect(allocator: std.mem.Allocator, url: []const u8) !Self {
        const handle = js.zsync_ws_open(url.ptr, url.len);
        if (handle < 0) return error.ConnectionFailed;
        return Self{ .handle = handle, .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        js.zsync_ws_close(self.handle);
    }

    /// Send a binary message.
    pub fn send(self: *Self, data: []const u8) !void {
        const n = js.zsync_ws_send(self.handle, data.ptr, data.len, 1);
        if (n < 0) return error.ConnectionClosed;
    }

    /// Send a text message.
    pub fn sendText(self: *Self, data: []const u8) !void {
        const n = js.zsync_ws_send(self.handle, data.ptr, data.len, 0);
        if (n < 0) return error.ConnectionClosed;
    }

    /// Receive the next message into `buffer`, returning its length.
    pub fn receive(self: *Self, buffer: []u8) !usize {
        const n = js.zsync_ws_recv(self.handle, buffer.ptr, buffer.len);
        if (n < 0) return error.ConnectionClosed;
        return @intCast(n);
    }

    pub fn close(self: *Self) void {
        js.zsync_ws_close(self.handle);
    }
};

test "wasm net wire address round trip ipv4" {
    const addr = net.IpAddress.parse("127.0.0.1", 8080) catch unreachable;
    var wire: [16]u8 = undefined;
    const info = addrToWire(addr, &wire);

    try std.testing.expectEqual(@as(usize, 4), info.len);
    try std.testing.expectEqual(@as(u16, 8080), info.port);

    const decoded = try wireToAddr(wire[0..info.len], info.port);
    try std.testing.expectEqualDeep(addr, decoded);
}

test "wasm net wire address rejects invalid length" {
    const bad = [_]u8{ 1, 2, 3 };
    try std.testing.expectError(error.InvalidAddress, wireToAddr(&bad, 0));
}
