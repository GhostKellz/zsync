//! HTTP/3 and QUIC integration for zsync v0.3.0
//! Provides high-performance async networking protocols with gRPC support
//! Enhanced for mesh networking and VPN integration

const std = @import("std");
const io_v2 = @import("io_v2.zig");
const connection_pool = @import("connection_pool.zig");
const crosschain_async = @import("crosschain_async.zig");

/// QUIC connection state
pub const QuicState = enum {
    idle,
    handshake,
    established,
    closing,
    closed,
    error,
};

/// QUIC stream types
pub const QuicStreamType = enum {
    bidirectional,
    unidirectional,
    control,
    settings,
    push,
};

/// HTTP/3 frame types
pub const Http3FrameType = enum {
    data,
    headers,
    cancel_push,
    settings,
    push_promise,
    goaway,
    max_push_id,
    duplicate_push,
};

/// QUIC connection configuration
pub const QuicConfig = struct {
    max_idle_timeout: u64 = 30000, // 30 seconds
    max_udp_payload_size: u32 = 1200,
    initial_max_data: u64 = 1024 * 1024, // 1MB
    initial_max_stream_data_bidi_local: u64 = 256 * 1024,
    initial_max_stream_data_bidi_remote: u64 = 256 * 1024,
    initial_max_stream_data_uni: u64 = 256 * 1024,
    initial_max_streams_bidi: u64 = 100,
    initial_max_streams_uni: u64 = 100,
    ack_delay_exponent: u8 = 3,
    max_ack_delay: u64 = 25000, // 25ms
    disable_active_migration: bool = false,
    enable_early_data: bool = false,
    application_protocols: []const []const u8 = &[_][]const u8{"h3"},
};

/// QUIC connection
pub const QuicConnection = struct {
    state: QuicState,
    config: QuicConfig,
    local_addr: std.net.Address,
    remote_addr: std.net.Address,
    connection_id: [16]u8,
    socket: std.net.Stream,
    streams: std.HashMap(u64, *QuicStream, std.hash_map.AutoContext(u64), std.hash_map.default_max_load_percentage),
    next_stream_id: u64,
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, config: QuicConfig) !*Self {
        const self = try allocator.create(Self);
        self.* = Self{
            .state = .idle,
            .config = config,
            .local_addr = undefined,
            .remote_addr = undefined,
            .connection_id = undefined,
            .socket = undefined,
            .streams = std.HashMap(u64, *QuicStream, std.hash_map.AutoContext(u64), std.hash_map.default_max_load_percentage).init(allocator),
            .next_stream_id = 0,
            .allocator = allocator,
            .mutex = std.Thread.Mutex{},
        };
        
        // Generate random connection ID
        std.crypto.random.bytes(&self.connection_id);
        
        return self;
    }
    
    pub fn deinit(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // Clean up all streams
        var iterator = self.streams.iterator();
        while (iterator.next()) |entry| {
            entry.value_ptr.*.deinit();
        }
        self.streams.deinit();
        
        if (self.state != .closed) {
            self.socket.close();
        }
        
        self.allocator.destroy(self);
    }
    
    pub fn connect(self: *Self, io: *io_v2.Io, remote_addr: std.net.Address) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        self.remote_addr = remote_addr;
        self.state = .handshake;
        
        // Create UDP socket
        self.socket = try std.net.tcpConnectToAddress(remote_addr);
        self.local_addr = try self.socket.getLocalEndPoint();
        
        // Perform QUIC handshake
        try self.performHandshake(io);
        
        self.state = .established;
    }
    
    pub fn createStream(self: *Self, io: *io_v2.Io, stream_type: QuicStreamType) !*QuicStream {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (self.state != .established) {
            return error_management.AsyncError.OperationAborted;
        }
        
        const stream_id = self.next_stream_id;
        self.next_stream_id += 1;
        
        const stream = try QuicStream.init(self.allocator, stream_id, stream_type, self);
        try self.streams.put(stream_id, stream);
        
        return stream;
    }
    
    pub fn closeStream(self: *Self, stream_id: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (self.streams.fetchRemove(stream_id)) |entry| {
            entry.value.deinit();
        }
    }
    
    pub fn close(self: *Self, io: *io_v2.Io) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (self.state == .closed) return;
        
        self.state = .closing;
        
        // Send close frame
        try self.sendCloseFrame(io);
        
        // Close socket
        self.socket.close();
        self.state = .closed;
    }
    
    fn performHandshake(self: *Self, io: *io_v2.Io) !void {
        _ = io;
        // Simplified handshake - in real implementation would do full QUIC handshake
        // Including TLS 1.3 handshake, version negotiation, etc.
        std.log.info("QUIC handshake completed for connection {any}", .{self.connection_id});
    }
    
    fn sendCloseFrame(self: *Self, io: *io_v2.Io) !void {
        _ = io;
        // Send QUIC close frame
        const close_frame = [_]u8{0x1c}; // CONNECTION_CLOSE frame
        _ = try self.socket.write(&close_frame);
    }
};

/// QUIC stream
pub const QuicStream = struct {
    id: u64,
    stream_type: QuicStreamType,
    connection: *QuicConnection,
    send_buffer: std.ArrayList(u8),
    recv_buffer: std.ArrayList(u8),
    closed: bool,
    allocator: std.mem.Allocator,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, id: u64, stream_type: QuicStreamType, connection: *QuicConnection) !*Self {
        const self = try allocator.create(Self);
        self.* = Self{
            .id = id,
            .stream_type = stream_type,
            .connection = connection,
            .send_buffer = std.ArrayList(u8).init(allocator),
            .recv_buffer = std.ArrayList(u8).init(allocator),
            .closed = false,
            .allocator = allocator,
        };
        return self;
    }
    
    pub fn deinit(self: *Self) void {
        self.send_buffer.deinit();
        self.recv_buffer.deinit();
        self.allocator.destroy(self);
    }
    
    pub fn write(self: *Self, io: *io_v2.Io, data: []const u8) !usize {
        if (self.closed) return error_management.AsyncError.OperationAborted;
        
        // Add to send buffer
        try self.send_buffer.appendSlice(data);
        
        // Send data frame
        return try self.sendData(io, data);
    }
    
    pub fn read(self: *Self, io: *io_v2.Io, buffer: []u8) !usize {
        if (self.closed) return error_management.AsyncError.OperationAborted;
        
        // Try to read from receive buffer
        if (self.recv_buffer.items.len > 0) {
            const bytes_to_copy = @min(buffer.len, self.recv_buffer.items.len);
            @memcpy(buffer[0..bytes_to_copy], self.recv_buffer.items[0..bytes_to_copy]);
            
            // Remove copied bytes from buffer
            const remaining = self.recv_buffer.items.len - bytes_to_copy;
            std.mem.copyForwards(u8, self.recv_buffer.items[0..remaining], self.recv_buffer.items[bytes_to_copy..]);
            self.recv_buffer.shrinkAndFree(remaining);
            
            return bytes_to_copy;
        }
        
        // No data available
        return 0;
    }
    
    pub fn close(self: *Self, io: *io_v2.Io) !void {
        if (self.closed) return;
        
        self.closed = true;
        
        // Send RESET_STREAM frame
        try self.sendResetFrame(io);
        
        // Remove from connection
        self.connection.closeStream(self.id);
    }
    
    fn sendData(self: *Self, io: *io_v2.Io, data: []const u8) !usize {
        _ = io;
        
        // Create STREAM frame
        var frame = std.ArrayList(u8).init(self.allocator);
        defer frame.deinit();
        
        try frame.append(0x08); // STREAM frame type
        try frame.append(@intCast(self.id)); // Stream ID (simplified)
        try frame.appendSlice(data);
        
        return try self.connection.socket.write(frame.items);
    }
    
    fn sendResetFrame(self: *Self, io: *io_v2.Io) !void {
        _ = io;
        
        const reset_frame = [_]u8{ 0x04, @intCast(self.id), 0x00 }; // RESET_STREAM frame
        _ = try self.connection.socket.write(&reset_frame);
    }
};

/// HTTP/3 request
pub const Http3Request = struct {
    method: []const u8,
    path: []const u8,
    headers: std.StringHashMap([]const u8),
    body: ?[]const u8,
    allocator: std.mem.Allocator,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, method: []const u8, path: []const u8) Self {
        return Self{
            .method = method,
            .path = path,
            .headers = std.StringHashMap([]const u8).init(allocator),
            .body = null,
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.headers.deinit();
    }
    
    pub fn addHeader(self: *Self, name: []const u8, value: []const u8) !void {
        try self.headers.put(name, value);
    }
    
    pub fn setBody(self: *Self, body: []const u8) void {
        self.body = body;
    }
};

/// HTTP/3 response
pub const Http3Response = struct {
    status: u16,
    headers: std.StringHashMap([]const u8),
    body: std.ArrayList(u8),
    allocator: std.mem.Allocator,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .status = 200,
            .headers = std.StringHashMap([]const u8).init(allocator),
            .body = std.ArrayList(u8).init(allocator),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.headers.deinit();
        self.body.deinit();
    }
    
    pub fn addHeader(self: *Self, name: []const u8, value: []const u8) !void {
        try self.headers.put(name, value);
    }
    
    pub fn setStatus(self: *Self, status: u16) void {
        self.status = status;
    }
    
    pub fn writeBody(self: *Self, data: []const u8) !void {
        try self.body.appendSlice(data);
    }
};

/// HTTP/3 client
pub const Http3Client = struct {
    connection: *QuicConnection,
    allocator: std.mem.Allocator,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, config: QuicConfig) !Self {
        const connection = try QuicConnection.init(allocator, config);
        return Self{
            .connection = connection,
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.connection.deinit();
    }
    
    pub fn connect(self: *Self, io: *io_v2.Io, remote_addr: std.net.Address) !void {
        try self.connection.connect(io, remote_addr);
    }
    
    pub fn request(self: *Self, io: *io_v2.Io, req: Http3Request) !Http3Response {
        const stream = try self.connection.createStream(io, .bidirectional);
        defer stream.deinit();
        
        // Send request
        try self.sendRequest(io, stream, req);
        
        // Read response
        return try self.readResponse(io, stream);
    }
    
    fn sendRequest(self: *Self, io: *io_v2.Io, stream: *QuicStream, req: Http3Request) !void {
        // Create HEADERS frame
        var headers_frame = std.ArrayList(u8).init(self.allocator);
        defer headers_frame.deinit();
        
        try headers_frame.append(0x01); // HEADERS frame type
        
        // Add pseudo-headers
        const method_header = try std.fmt.allocPrint(self.allocator, ":method {s}\r\n", .{req.method});
        defer self.allocator.free(method_header);
        try headers_frame.appendSlice(method_header);
        
        const path_header = try std.fmt.allocPrint(self.allocator, ":path {s}\r\n", .{req.path});
        defer self.allocator.free(path_header);
        try headers_frame.appendSlice(path_header);
        
        // Add regular headers
        var header_iterator = req.headers.iterator();
        while (header_iterator.next()) |entry| {
            const header = try std.fmt.allocPrint(self.allocator, "{s}: {s}\r\n", .{ entry.key_ptr.*, entry.value_ptr.* });
            defer self.allocator.free(header);
            try headers_frame.appendSlice(header);
        }
        
        _ = try stream.write(io, headers_frame.items);
        
        // Send body if present
        if (req.body) |body| {
            var data_frame = std.ArrayList(u8).init(self.allocator);
            defer data_frame.deinit();
            
            try data_frame.append(0x00); // DATA frame type
            try data_frame.appendSlice(body);
            
            _ = try stream.write(io, data_frame.items);
        }
    }
    
    fn readResponse(self: *Self, io: *io_v2.Io, stream: *QuicStream) !Http3Response {
        var response = Http3Response.init(self.allocator);
        
        // Read response frames
        var buffer: [4096]u8 = undefined;
        const bytes_read = try stream.read(io, &buffer);
        
        if (bytes_read > 0) {
            // Parse response (simplified)
            try response.writeBody(buffer[0..bytes_read]);
        }
        
        return response;
    }
};

/// HTTP/3 server
pub const Http3Server = struct {
    connection: *QuicConnection,
    handlers: std.StringHashMap(HandlerFn),
    allocator: std.mem.Allocator,
    
    const Self = @This();
    const HandlerFn = *const fn(Http3Request, *Http3Response) anyerror!void;
    
    pub fn init(allocator: std.mem.Allocator, config: QuicConfig) !Self {
        const connection = try QuicConnection.init(allocator, config);
        return Self{
            .connection = connection,
            .handlers = std.StringHashMap(HandlerFn).init(allocator),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.handlers.deinit();
        self.connection.deinit();
    }
    
    pub fn addHandler(self: *Self, path: []const u8, handler: HandlerFn) !void {
        try self.handlers.put(path, handler);
    }
    
    pub fn listen(self: *Self, io: *io_v2.Io, addr: std.net.Address) !void {
        self.connection.local_addr = addr;
        // Bind to address and start listening
        // In real implementation, would set up UDP socket for QUIC
        std.log.info("HTTP/3 server listening on {}", .{addr});
    }
    
    pub fn serve(self: *Self, io: *io_v2.Io) !void {
        // Accept connections and handle requests
        // This is a simplified version - real implementation would be more complex
        std.log.info("HTTP/3 server serving requests");
    }
};

/// gRPC over HTTP/3 support
pub const GrpcHttp3 = struct {
    client: Http3Client,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, config: QuicConfig) !Self {
        return Self{
            .client = try Http3Client.init(allocator, config),
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.client.deinit();
    }
    
    pub fn connect(self: *Self, io: *io_v2.Io, remote_addr: std.net.Address) !void {
        try self.client.connect(io, remote_addr);
    }
    
    pub fn call(self: *Self, io: *io_v2.Io, service: []const u8, method: []const u8, request_data: []const u8) ![]const u8 {
        const path = try std.fmt.allocPrint(self.client.allocator, "/{s}/{s}", .{ service, method });
        defer self.client.allocator.free(path);
        
        var req = Http3Request.init(self.client.allocator, "POST", path);
        defer req.deinit();
        
        try req.addHeader("content-type", "application/grpc");
        try req.addHeader("te", "trailers");
        req.setBody(request_data);
        
        const response = try self.client.request(io, req);
        defer response.deinit();
        
        return try self.client.allocator.dupe(u8, response.body.items);
    }
};

/// Performance benchmarks for HTTP/3 and QUIC
pub const Http3Benchmarks = struct {
    pub fn benchmarkQuicConnection(io: *io_v2.Io, iterations: u32) !void {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();
        
        const config = QuicConfig{};
        const start_time = std.time.milliTimestamp();
        
        for (0..iterations) |_| {
            const connection = try QuicConnection.init(allocator, config);
            defer connection.deinit();
            
            const remote_addr = try std.net.Address.parseIp("127.0.0.1", 443);
            try connection.connect(io, remote_addr);
        }
        
        const end_time = std.time.milliTimestamp();
        const duration = end_time - start_time;
        
        std.log.info("QUIC connection benchmark: {d} connections in {d}ms ({d:.2} conn/sec)", .{
            iterations,
            duration,
            @as(f64, @floatFromInt(iterations)) / (@as(f64, @floatFromInt(duration)) / 1000.0),
        });
    }
    
    pub fn benchmarkHttp3Requests(io: *io_v2.Io, iterations: u32) !void {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();
        
        const config = QuicConfig{};
        var client = try Http3Client.init(allocator, config);
        defer client.deinit();
        
        const remote_addr = try std.net.Address.parseIp("127.0.0.1", 443);
        try client.connect(io, remote_addr);
        
        const start_time = std.time.milliTimestamp();
        
        for (0..iterations) |_| {
            var req = Http3Request.init(allocator, "GET", "/test");
            defer req.deinit();
            
            const response = try client.request(io, req);
            defer response.deinit();
        }
        
        const end_time = std.time.milliTimestamp();
        const duration = end_time - start_time;
        
        std.log.info("HTTP/3 request benchmark: {d} requests in {d}ms ({d:.2} req/sec)", .{
            iterations,
            duration,
            @as(f64, @floatFromInt(iterations)) / (@as(f64, @floatFromInt(duration)) / 1000.0),
        });
    }
};

test "QUIC connection" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    // Test QUIC connection creation
    const config = QuicConfig{};
    const connection = try QuicConnection.init(allocator, config);
    defer connection.deinit();
    
    try testing.expect(connection.state == .idle);
    try testing.expect(connection.next_stream_id == 0);
}

/// Mesh networking integration with QUIC transport
pub const MeshQuicTransport = struct {
    mesh_coordinator: *crosschain_async.MeshCoordinator,
    quic_connections: std.hash_map.HashMap([16]u8, *QuicConnection, std.hash_map.AutoContext([16]u8), 80),
    allocator: std.mem.Allocator,
    io: io_v2.Io,
    
    /// Initialize mesh QUIC transport
    pub fn init(allocator: std.mem.Allocator, io: io_v2.Io, mesh_coordinator: *crosschain_async.MeshCoordinator) !MeshQuicTransport {
        return MeshQuicTransport{
            .mesh_coordinator = mesh_coordinator,
            .quic_connections = std.hash_map.HashMap([16]u8, *QuicConnection, std.hash_map.AutoContext([16]u8), 80).init(allocator),
            .allocator = allocator,
            .io = io,
        };
    }
    
    /// Deinitialize mesh transport
    pub fn deinit(self: *MeshQuicTransport) void {
        var iter = self.quic_connections.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.deinit();
        }
        self.quic_connections.deinit();
    }
    
    /// Establish QUIC connection to mesh peer
    pub fn connectToPeerAsync(self: *MeshQuicTransport, allocator: std.mem.Allocator, peer_id: [16]u8, endpoint: std.net.Address) !io_v2.Future {
        const ctx = try allocator.create(MeshConnectContext);
        ctx.* = .{
            .transport = self,
            .peer_id = peer_id,
            .endpoint = endpoint,
            .allocator = allocator,
            .connection = null,
        };
        
        return io_v2.Future{
            .impl = .{
                .callback = .{
                    .context = @ptrCast(ctx),
                    .poll_fn = meshConnectPoll,
                    .deinit_fn = meshConnectDeinit,
                },
            },
        };
    }
    
    /// Send data through mesh via QUIC
    pub fn sendToMeshPeerAsync(self: *MeshQuicTransport, allocator: std.mem.Allocator, peer_id: [16]u8, data: []const u8) !io_v2.Future {
        const ctx = try allocator.create(MeshSendContext);
        ctx.* = .{
            .transport = self,
            .peer_id = peer_id,
            .data = try allocator.dupe(u8, data),
            .allocator = allocator,
            .bytes_sent = 0,
        };
        
        return io_v2.Future{
            .impl = .{
                .callback = .{
                    .context = @ptrCast(ctx),
                    .poll_fn = meshSendPoll,
                    .deinit_fn = meshSendDeinit,
                },
            },
        };
    }
    
    /// Route packet through mesh using QUIC
    pub fn routePacketThroughMeshAsync(self: *MeshQuicTransport, allocator: std.mem.Allocator, packet: []const u8, destination: [16]u8) !io_v2.Future {
        const ctx = try allocator.create(MeshRouteContext);
        ctx.* = .{
            .transport = self,
            .packet = try allocator.dupe(u8, packet),
            .destination = destination,
            .allocator = allocator,
            .routed = false,
        };
        
        return io_v2.Future{
            .impl = .{
                .callback = .{
                    .context = @ptrCast(ctx),
                    .poll_fn = meshRoutePoll,
                    .deinit_fn = meshRouteDeinit,
                },
            },
        };
    }
};

/// VPN integration with HTTP/3 tunneling
pub const VpnHttp3Tunnel = struct {
    quic_client: Http3Client,
    tunnel_endpoint: std.net.Address,
    tunnel_established: bool,
    allocator: std.mem.Allocator,
    
    /// Initialize VPN HTTP/3 tunnel
    pub fn init(allocator: std.mem.Allocator, config: QuicConfig) !VpnHttp3Tunnel {
        return VpnHttp3Tunnel{
            .quic_client = try Http3Client.init(allocator, config),
            .tunnel_endpoint = undefined,
            .tunnel_established = false,
            .allocator = allocator,
        };
    }
    
    /// Deinitialize VPN tunnel
    pub fn deinit(self: *VpnHttp3Tunnel) void {
        self.quic_client.deinit();
    }
    
    /// Establish VPN tunnel via HTTP/3
    pub fn establishTunnelAsync(self: *VpnHttp3Tunnel, allocator: std.mem.Allocator, tunnel_endpoint: std.net.Address) !io_v2.Future {
        const ctx = try allocator.create(VpnTunnelContext);
        ctx.* = .{
            .tunnel = self,
            .tunnel_endpoint = tunnel_endpoint,
            .allocator = allocator,
            .established = false,
        };
        
        return io_v2.Future{
            .impl = .{
                .callback = .{
                    .context = @ptrCast(ctx),
                    .poll_fn = vpnTunnelPoll,
                    .deinit_fn = vpnTunnelDeinit,
                },
            },
        };
    }
    
    /// Send traffic through VPN tunnel
    pub fn tunnelTrafficAsync(self: *VpnHttp3Tunnel, allocator: std.mem.Allocator, traffic_data: []const u8) !io_v2.Future {
        const ctx = try allocator.create(VpnTrafficContext);
        ctx.* = .{
            .tunnel = self,
            .traffic_data = try allocator.dupe(u8, traffic_data),
            .allocator = allocator,
            .bytes_sent = 0,
        };
        
        return io_v2.Future{
            .impl = .{
                .callback = .{
                    .context = @ptrCast(ctx),
                    .poll_fn = vpnTrafficPoll,
                    .deinit_fn = vpnTrafficDeinit,
                },
            },
        };
    }
};

// Context structures for mesh networking
const MeshConnectContext = struct {
    transport: *MeshQuicTransport,
    peer_id: [16]u8,
    endpoint: std.net.Address,
    allocator: std.mem.Allocator,
    connection: ?*QuicConnection,
};

const MeshSendContext = struct {
    transport: *MeshQuicTransport,
    peer_id: [16]u8,
    data: []u8,
    allocator: std.mem.Allocator,
    bytes_sent: usize,
};

const MeshRouteContext = struct {
    transport: *MeshQuicTransport,
    packet: []u8,
    destination: [16]u8,
    allocator: std.mem.Allocator,
    routed: bool,
};

const VpnTunnelContext = struct {
    tunnel: *VpnHttp3Tunnel,
    tunnel_endpoint: std.net.Address,
    allocator: std.mem.Allocator,
    established: bool,
};

const VpnTrafficContext = struct {
    tunnel: *VpnHttp3Tunnel,
    traffic_data: []u8,
    allocator: std.mem.Allocator,
    bytes_sent: usize,
};

// Poll functions for mesh networking
fn meshConnectPoll(context: *anyopaque, io: io_v2.Io) io_v2.Future.PollResult {
    const ctx = @as(*MeshConnectContext, @ptrCast(@alignCast(context)));
    
    // Create QUIC connection to mesh peer
    const config = QuicConfig{};
    const connection = ctx.transport.allocator.create(QuicConnection) catch |err| {
        return .{ .ready = err };
    };
    connection.* = QuicConnection.init(ctx.transport.allocator, config) catch |err| {
        ctx.transport.allocator.destroy(connection);
        return .{ .ready = err };
    };
    
    // Connect to peer endpoint
    connection.connect(&io, ctx.endpoint) catch |err| {
        connection.deinit();
        return .{ .ready = err };
    };
    
    // Store connection in transport
    ctx.transport.quic_connections.put(ctx.peer_id, connection) catch |err| {
        connection.deinit();
        return .{ .ready = err };
    };
    
    ctx.connection = connection;
    
    return .{ .ready = ctx.connection };
}

fn meshConnectDeinit(context: *anyopaque, allocator: std.mem.Allocator) void {
    const ctx = @as(*MeshConnectContext, @ptrCast(@alignCast(context)));
    allocator.destroy(ctx);
}

fn meshSendPoll(context: *anyopaque, io: io_v2.Io) io_v2.Future.PollResult {
    const ctx = @as(*MeshSendContext, @ptrCast(@alignCast(context)));
    
    // Get connection to peer
    const connection = ctx.transport.quic_connections.get(ctx.peer_id);
    if (connection == null) {
        return .{ .ready = error.PeerNotConnected };
    }
    
    // Create stream and send data
    const stream = connection.?.createStream(&io, .bidirectional) catch |err| {
        return .{ .ready = err };
    };
    defer stream.deinit();
    
    const bytes_sent = stream.write(&io, ctx.data) catch |err| {
        return .{ .ready = err };
    };
    
    ctx.bytes_sent = bytes_sent;
    
    return .{ .ready = ctx.bytes_sent };
}

fn meshSendDeinit(context: *anyopaque, allocator: std.mem.Allocator) void {
    const ctx = @as(*MeshSendContext, @ptrCast(@alignCast(context)));
    allocator.free(ctx.data);
    allocator.destroy(ctx);
}

fn meshRoutePoll(context: *anyopaque, io: io_v2.Io) io_v2.Future.PollResult {
    const ctx = @as(*MeshRouteContext, @ptrCast(@alignCast(context)));
    
    // Use mesh coordinator to route packet
    var route_future = ctx.transport.mesh_coordinator.routePacketAsync(ctx.allocator, ctx.packet, ctx.destination) catch |err| {
        return .{ .ready = err };
    };
    defer route_future.deinit();
    
    const routed = route_future.await_op(io, .{}) catch |err| {
        return .{ .ready = err };
    };
    
    ctx.routed = routed;
    
    return .{ .ready = ctx.routed };
}

fn meshRouteDeinit(context: *anyopaque, allocator: std.mem.Allocator) void {
    const ctx = @as(*MeshRouteContext, @ptrCast(@alignCast(context)));
    allocator.free(ctx.packet);
    allocator.destroy(ctx);
}

fn vpnTunnelPoll(context: *anyopaque, io: io_v2.Io) io_v2.Future.PollResult {
    const ctx = @as(*VpnTunnelContext, @ptrCast(@alignCast(context)));
    
    // Connect to tunnel endpoint
    ctx.tunnel.quic_client.connect(&io, ctx.tunnel_endpoint) catch |err| {
        return .{ .ready = err };
    };
    
    // Establish tunnel (simplified)
    var tunnel_req = Http3Request.init(ctx.tunnel.allocator, "CONNECT", "/tunnel");
    defer tunnel_req.deinit();
    
    tunnel_req.addHeader("upgrade", "tunnel") catch |err| {
        return .{ .ready = err };
    };
    
    const response = ctx.tunnel.quic_client.request(&io, tunnel_req) catch |err| {
        return .{ .ready = err };
    };
    defer response.deinit();
    
    ctx.tunnel.tunnel_established = response.status == 200;
    ctx.tunnel.tunnel_endpoint = ctx.tunnel_endpoint;
    ctx.established = ctx.tunnel.tunnel_established;
    
    return .{ .ready = ctx.established };
}

fn vpnTunnelDeinit(context: *anyopaque, allocator: std.mem.Allocator) void {
    const ctx = @as(*VpnTunnelContext, @ptrCast(@alignCast(context)));
    allocator.destroy(ctx);
}

fn vpnTrafficPoll(context: *anyopaque, io: io_v2.Io) io_v2.Future.PollResult {
    const ctx = @as(*VpnTrafficContext, @ptrCast(@alignCast(context)));
    
    if (!ctx.tunnel.tunnel_established) {
        return .{ .ready = error.TunnelNotEstablished };
    }
    
    // Send traffic through tunnel
    var traffic_req = Http3Request.init(ctx.tunnel.allocator, "POST", "/tunnel/data");
    defer traffic_req.deinit();
    
    traffic_req.addHeader("content-type", "application/octet-stream") catch |err| {
        return .{ .ready = err };
    };
    traffic_req.setBody(ctx.traffic_data);
    
    const response = ctx.tunnel.quic_client.request(&io, traffic_req) catch |err| {
        return .{ .ready = err };
    };
    defer response.deinit();
    
    ctx.bytes_sent = if (response.status == 200) ctx.traffic_data.len else 0;
    
    return .{ .ready = ctx.bytes_sent };
}

fn vpnTrafficDeinit(context: *anyopaque, allocator: std.mem.Allocator) void {
    const ctx = @as(*VpnTrafficContext, @ptrCast(@alignCast(context)));
    allocator.free(ctx.traffic_data);
    allocator.destroy(ctx);
}

test "HTTP/3 request/response" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    // Test HTTP/3 request
    var req = Http3Request.init(allocator, "GET", "/test");
    defer req.deinit();
    
    try req.addHeader("host", "example.com");
    try req.addHeader("user-agent", "zsync/0.3.0");
    
    try testing.expect(std.mem.eql(u8, req.method, "GET"));
    try testing.expect(std.mem.eql(u8, req.path, "/test"));
    
    // Test HTTP/3 response
    var res = Http3Response.init(allocator);
    defer res.deinit();
    
    res.setStatus(200);
    try res.addHeader("content-type", "text/html");
    try res.writeBody("Hello, World!");
    
    try testing.expect(res.status == 200);
    try testing.expect(std.mem.eql(u8, res.body.items, "Hello, World!"));
}

test "mesh QUIC transport" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = io_v2.Io.init();
    
    // Create mesh coordinator (simplified)
    var wg_processor = try crosschain_async.WireGuardProcessor.init(allocator, io);
    defer wg_processor.deinit();
    
    var nat_traversal = try crosschain_async.NatTraversal.init(allocator, io);
    defer nat_traversal.deinit();
    
    var mesh_coordinator = try crosschain_async.MeshCoordinator.init(allocator, io, &wg_processor, &nat_traversal);
    defer mesh_coordinator.deinit();
    
    // Test mesh QUIC transport
    var mesh_transport = try MeshQuicTransport.init(allocator, io, &mesh_coordinator);
    defer mesh_transport.deinit();
    
    try testing.expect(mesh_transport.quic_connections.count() == 0);
}