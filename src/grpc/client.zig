//! Zsync v0.6.0 - gRPC Client
//! gRPC client implementation with HTTP/2 and HTTP/3 (QUIC) support

const std = @import("std");
const Runtime = @import("../runtime.zig").Runtime;
const server_mod = @import("server.zig");

pub const StatusCode = server_mod.StatusCode;
pub const Metadata = server_mod.Metadata;
pub const Context = server_mod.Context;
pub const MethodType = server_mod.MethodType;

/// gRPC Client Configuration
pub const ClientConfig = struct {
    max_receive_message_size: usize = 4 * 1024 * 1024, // 4MB
    max_send_message_size: usize = 4 * 1024 * 1024, // 4MB
    timeout_ms: u64 = 30000, // 30 seconds
    use_quic: bool = false, // Use HTTP/3 (QUIC) instead of HTTP/2
    keepalive: bool = true,
    keepalive_time_ms: u64 = 30000, // 30 seconds

    pub fn default() ClientConfig {
        return ClientConfig{};
    }

    pub fn withQuic(self: ClientConfig) ClientConfig {
        var config = self;
        config.use_quic = true;
        return config;
    }

    pub fn withTimeout(self: ClientConfig, timeout_ms: u64) ClientConfig {
        var config = self;
        config.timeout_ms = timeout_ms;
        return config;
    }
};

/// gRPC Call Options
pub const CallOptions = struct {
    timeout_ms: ?u64 = null,
    metadata: ?Metadata = null,
    compression: bool = false,

    pub fn default() CallOptions {
        return CallOptions{};
    }
};

/// gRPC Client
pub const GrpcClient = struct {
    allocator: std.mem.Allocator,
    runtime: *Runtime,
    target: []const u8, // host:port
    config: ClientConfig,
    connected: std.atomic.Value(bool),

    const Self = @This();

    /// Initialize gRPC client
    pub fn init(
        allocator: std.mem.Allocator,
        runtime: *Runtime,
        target: []const u8,
        config: ClientConfig,
    ) !Self {
        const owned_target = try allocator.dupe(u8, target);

        return Self{
            .allocator = allocator,
            .runtime = runtime,
            .target = owned_target,
            .config = config,
            .connected = std.atomic.Value(bool).init(false),
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.target);
    }

    /// Connect to gRPC server
    pub fn connect(self: *Self) !void {
        if (self.config.use_quic) {
            std.debug.print("[gRPC] Connecting to {} via HTTP/3 (QUIC)\n", .{self.target});
            // TODO: Establish QUIC connection
        } else {
            std.debug.print("[gRPC] Connecting to {} via HTTP/2\n", .{self.target});
            // TODO: Establish HTTP/2 connection
        }

        self.connected.store(true, .release);
    }

    /// Close connection
    pub fn close(self: *Self) void {
        if (self.connected.load(.acquire)) {
            // TODO: Close connection gracefully
            self.connected.store(false, .release);
        }
    }

    /// Make unary RPC call
    pub fn unaryCall(
        self: *Self,
        comptime Request: type,
        comptime Response: type,
        service: []const u8,
        method: []const u8,
        request: Request,
        options: CallOptions,
    ) !Response {
        _ = request;
        _ = options;

        if (!self.connected.load(.acquire)) {
            try self.connect();
        }

        const path = try std.fmt.allocPrint(
            self.allocator,
            "/{s}/{s}",
            .{ service, method },
        );
        defer self.allocator.free(path);

        std.debug.print("[gRPC] Calling {s}\n", .{path});

        // TODO: Serialize request (protobuf)
        // TODO: Send gRPC request
        // TODO: Receive gRPC response
        // TODO: Deserialize response

        // Mock response for now
        return @as(Response, undefined);
    }

    /// Make client streaming RPC call
    pub fn clientStreamingCall(
        self: *Self,
        comptime Request: type,
        comptime Response: type,
        service: []const u8,
        method: []const u8,
        options: CallOptions,
    ) !ClientStreamingCall(Request, Response) {
        _ = options;

        if (!self.connected.load(.acquire)) {
            try self.connect();
        }

        const path = try std.fmt.allocPrint(
            self.allocator,
            "/{s}/{s}",
            .{ service, method },
        );
        defer self.allocator.free(path);

        return ClientStreamingCall(Request, Response).init(self.allocator);
    }

    /// Make server streaming RPC call
    pub fn serverStreamingCall(
        self: *Self,
        comptime Request: type,
        comptime Response: type,
        service: []const u8,
        method: []const u8,
        request: Request,
        options: CallOptions,
    ) !ServerStreamingCall(Response) {
        _ = request;
        _ = options;

        if (!self.connected.load(.acquire)) {
            try self.connect();
        }

        const path = try std.fmt.allocPrint(
            self.allocator,
            "/{s}/{s}",
            .{ service, method },
        );
        defer self.allocator.free(path);

        return ServerStreamingCall(Response).init(self.allocator);
    }

    /// Make bidirectional streaming RPC call
    pub fn bidiStreamingCall(
        self: *Self,
        comptime Request: type,
        comptime Response: type,
        service: []const u8,
        method: []const u8,
        options: CallOptions,
    ) !BidiStreamingCall(Request, Response) {
        _ = options;

        if (!self.connected.load(.acquire)) {
            try self.connect();
        }

        const path = try std.fmt.allocPrint(
            self.allocator,
            "/{s}/{s}",
            .{ service, method },
        );
        defer self.allocator.free(path);

        return BidiStreamingCall(Request, Response).init(self.allocator);
    }
};

/// Client streaming call
pub fn ClientStreamingCall(comptime Request: type, comptime Response: type) type {
    return struct {
        allocator: std.mem.Allocator,
        requests: std.ArrayList(Request),
        closed: bool,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{
                .allocator = allocator,
                .requests = std.ArrayList(Request){ .allocator = allocator },
                .closed = false,
            };
        }

        pub fn deinit(self: *Self) void {
            self.requests.deinit();
        }

        /// Send a request
        pub fn send(self: *Self, request: Request) !void {
            if (self.closed) return error.StreamClosed;
            try self.requests.append(self.allocator, request);
            // TODO: Actually send to server
        }

        /// Close send and receive response
        pub fn closeAndRecv(self: *Self) !Response {
            self.closed = true;
            // TODO: Signal end of stream
            // TODO: Receive response
            return @as(Response, undefined);
        }
    };
}

/// Server streaming call
pub fn ServerStreamingCall(comptime Response: type) type {
    return struct {
        allocator: std.mem.Allocator,
        responses: std.ArrayList(Response),
        index: usize,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{
                .allocator = allocator,
                .responses = std.ArrayList(Response){ .allocator = allocator },
                .index = 0,
            };
        }

        pub fn deinit(self: *Self) void {
            self.responses.deinit();
        }

        /// Receive next response
        pub fn recv(self: *Self) !?Response {
            if (self.index >= self.responses.items.len) {
                // TODO: Read from stream
                return null;
            }

            const resp = self.responses.items[self.index];
            self.index += 1;
            return resp;
        }
    };
}

/// Bidirectional streaming call
pub fn BidiStreamingCall(comptime Request: type, comptime Response: type) type {
    return struct {
        allocator: std.mem.Allocator,
        requests: std.ArrayList(Request),
        responses: std.ArrayList(Response),
        resp_index: usize,
        closed: bool,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{
                .allocator = allocator,
                .requests = std.ArrayList(Request){ .allocator = allocator },
                .responses = std.ArrayList(Response){ .allocator = allocator },
                .resp_index = 0,
                .closed = false,
            };
        }

        pub fn deinit(self: *Self) void {
            self.requests.deinit();
            self.responses.deinit();
        }

        /// Send a request
        pub fn send(self: *Self, request: Request) !void {
            if (self.closed) return error.StreamClosed;
            try self.requests.append(self.allocator, request);
            // TODO: Actually send to server
        }

        /// Receive a response
        pub fn recv(self: *Self) !?Response {
            if (self.resp_index >= self.responses.items.len) {
                // TODO: Read from stream
                return null;
            }

            const resp = self.responses.items[self.resp_index];
            self.resp_index += 1;
            return resp;
        }

        /// Close send side of stream
        pub fn closeSend(self: *Self) void {
            self.closed = true;
            // TODO: Signal end of send stream
        }
    };
}

/// gRPC Channel (connection pool)
pub const Channel = struct {
    allocator: std.mem.Allocator,
    runtime: *Runtime,
    target: []const u8,
    config: ClientConfig,
    clients: std.ArrayList(*GrpcClient),
    mutex: std.Thread.Mutex,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        runtime: *Runtime,
        target: []const u8,
        config: ClientConfig,
    ) !Self {
        const owned_target = try allocator.dupe(u8, target);

        return Self{
            .allocator = allocator,
            .runtime = runtime,
            .target = owned_target,
            .config = config,
            .clients = std.ArrayList(*GrpcClient){ .allocator = allocator },
            .mutex = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.clients.items) |client| {
            client.deinit();
            self.allocator.destroy(client);
        }
        self.clients.deinit();
        self.allocator.free(self.target);
    }

    /// Get or create a client
    pub fn getClient(self: *Self) !*GrpcClient {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Try to find an available client
        for (self.clients.items) |client| {
            if (client.connected.load(.acquire)) {
                return client;
            }
        }

        // Create new client
        const client = try self.allocator.create(GrpcClient);
        client.* = try GrpcClient.init(
            self.allocator,
            self.runtime,
            self.target,
            self.config,
        );
        try self.clients.append(self.allocator, client);

        return client;
    }
};

// Tests
test "grpc client init" {
    const testing = std.testing;

    var config = Runtime.Config.optimal();
    var runtime = try Runtime.init(testing.allocator, &config);
    defer runtime.deinit();

    var client = try GrpcClient.init(
        testing.allocator,
        runtime,
        "localhost:50051",
        ClientConfig.default(),
    );
    defer client.deinit();

    try testing.expect(!client.connected.load(.acquire));
}

test "grpc client config" {
    const config = ClientConfig.default().withQuic().withTimeout(5000);
    const testing = std.testing;

    try testing.expect(config.use_quic);
    try testing.expectEqual(5000, config.timeout_ms);
}
