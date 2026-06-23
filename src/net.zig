//! Tokio-style networking facade over `std.Io.net` plus zsync higher-level
//! networking helpers.

const std = @import("std");
const builtin = @import("builtin");

const native_networking = @import("networking.zig");
const wasm_networking = @import("wasm/net.zig");
const websocket_mod = @import("net/websocket.zig");

const backend = if (builtin.target.cpu.arch == .wasm32) wasm_networking else native_networking;

pub const IpAddress = std.Io.net.IpAddress;
pub const Socket = std.Io.net.Socket;
pub const Stream = std.Io.net.Stream;
pub const Server = std.Io.net.Server;

pub const TlsConfig = backend.TlsConfig;
pub const TlsVersion = backend.TlsVersion;
pub const CipherSuite = backend.CipherSuite;
pub const TlsStream = backend.TlsStream;
pub const HttpClient = backend.HttpClient;
pub const HttpRequest = backend.HttpRequest;
pub const HttpResponse = backend.HttpResponse;
pub const HttpMethod = backend.HttpMethod;
pub const HttpVersion = backend.HttpVersion;
pub const DnsResolver = backend.DnsResolver;

pub const WebSocketConnection = websocket_mod.WebSocketConnection;
pub const WebSocketServer = websocket_mod.WebSocketServer;
pub const WebSocketClient = websocket_mod.WebSocketClient;
pub const WebSocketMessage = websocket_mod.Message;
pub const WebSocketOpCode = websocket_mod.OpCode;
pub const WebSocketCloseCode = websocket_mod.CloseCode;

/// TCP stream wrapper with explicit `std.Io` ownership.
pub const TcpStream = if (builtin.target.cpu.arch == .wasm32) backend.TlsStream else struct {
    io: std.Io,
    stream: std.Io.net.Stream,

    const Self = @This();

    pub fn connect(io: std.Io, host: []const u8, port: u16) !Self {
        const address = try IpAddress.resolve(io, host, port);
        return .{ .io = io, .stream = try address.connect(io, .{ .mode = .stream }) };
    }

    pub fn connectTimeout(io: std.Io, host: []const u8, port: u16, timeout: std.Io.Timeout) !Self {
        const address = try IpAddress.resolve(io, host, port);
        return .{ .io = io, .stream = try address.connect(io, .{ .mode = .stream, .timeout = timeout }) };
    }

    pub fn read(self: *Self, buffer: []u8) !usize {
        var slices: [1][]u8 = .{buffer};
        return self.stream.read(self.io, &slices);
    }

    pub fn readTimeout(self: *Self, buffer: []u8, timeout: std.Io.Timeout) !usize {
        var slices: [1][]u8 = .{buffer};
        return (try self.io.operateTimeout(.{ .net_read = .{
            .socket_handle = self.stream.socket.handle,
            .data = &slices,
        } }, timeout)).net_read;
    }

    pub fn writeAll(self: *Self, data: []const u8) !void {
        var buf: [4096]u8 = undefined;
        var writer = self.stream.writer(self.io, &buf);
        try writer.interface.writeAll(data);
        try writer.interface.flush();
    }

    pub fn shutdown(self: *Self, how: std.Io.net.ShutdownHow) !void {
        try self.stream.shutdown(self.io, how);
    }

    pub fn close(self: *Self) void {
        self.stream.close(self.io);
    }
};

/// TCP listener wrapper with explicit `std.Io` ownership.
pub const TcpListener = struct {
    io: std.Io,
    server: std.Io.net.Server,

    const Self = @This();

    pub fn bind(io: std.Io, address: IpAddress) !Self {
        return .{ .io = io, .server = try address.listen(io, .{ .reuse_address = true }) };
    }

    pub fn accept(self: *Self) !TcpStream {
        return .{ .io = self.io, .stream = try self.server.accept(self.io) };
    }

    pub fn close(self: *Self) void {
        self.server.deinit(self.io);
    }
};

pub const UdpSocket = if (builtin.target.cpu.arch == .wasm32) backend.UdpSocket else struct {
    io: std.Io,
    socket: std.Io.net.Socket,

    const Self = @This();

    pub fn bind(io: std.Io, address: IpAddress) !Self {
        return .{ .io = io, .socket = try address.bind(io, .{ .mode = .dgram }) };
    }

    pub fn sendTo(self: *Self, data: []const u8, address: IpAddress) !void {
        try self.socket.send(self.io, &address, data);
    }

    pub fn recvFrom(self: *Self, buffer: []u8) !struct { bytes_received: usize, address: IpAddress } {
        const msg = try self.socket.receive(self.io, buffer);
        return .{ .bytes_received = msg.data.len, .address = msg.from };
    }

    pub fn recvFromTimeout(self: *Self, buffer: []u8, timeout: std.Io.Timeout) !struct { bytes_received: usize, address: IpAddress } {
        const msg = try self.socket.receiveTimeout(self.io, buffer, timeout);
        return .{ .bytes_received = msg.data.len, .address = msg.from };
    }

    pub fn close(self: *Self) void {
        self.socket.close(self.io);
    }
};

test "net facade exposes native tcp types" {
    _ = TcpStream;
    _ = TcpListener;
    _ = UdpSocket;
    _ = HttpClient;
    _ = WebSocketClient;
}
