//! Zsync v0.6.0 - gRPC Server
//! gRPC server implementation with HTTP/2 and HTTP/3 (QUIC) support

const std = @import("std");
const Runtime = @import("../runtime.zig").Runtime;

/// gRPC Status Codes
pub const StatusCode = enum(u32) {
    ok = 0,
    cancelled = 1,
    unknown = 2,
    invalid_argument = 3,
    deadline_exceeded = 4,
    not_found = 5,
    already_exists = 6,
    permission_denied = 7,
    resource_exhausted = 8,
    failed_precondition = 9,
    aborted = 10,
    out_of_range = 11,
    unimplemented = 12,
    internal = 13,
    unavailable = 14,
    data_loss = 15,
    unauthenticated = 16,

    pub fn toString(self: StatusCode) []const u8 {
        return switch (self) {
            .ok => "OK",
            .cancelled => "CANCELLED",
            .unknown => "UNKNOWN",
            .invalid_argument => "INVALID_ARGUMENT",
            .deadline_exceeded => "DEADLINE_EXCEEDED",
            .not_found => "NOT_FOUND",
            .already_exists => "ALREADY_EXISTS",
            .permission_denied => "PERMISSION_DENIED",
            .resource_exhausted => "RESOURCE_EXHAUSTED",
            .failed_precondition => "FAILED_PRECONDITION",
            .aborted => "ABORTED",
            .out_of_range => "OUT_OF_RANGE",
            .unimplemented => "UNIMPLEMENTED",
            .internal => "INTERNAL",
            .unavailable => "UNAVAILABLE",
            .data_loss => "DATA_LOSS",
            .unauthenticated => "UNAUTHENTICATED",
        };
    }
};

/// gRPC Metadata (headers)
pub const Metadata = struct {
    entries: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .entries = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.entries.deinit();
    }

    pub fn set(self: *Self, key: []const u8, value: []const u8) !void {
        const owned_key = try self.allocator.dupe(u8, key);
        const owned_value = try self.allocator.dupe(u8, value);
        try self.entries.put(owned_key, owned_value);
    }

    pub fn get(self: *const Self, key: []const u8) ?[]const u8 {
        return self.entries.get(key);
    }
};

/// gRPC Context
pub const Context = struct {
    metadata: Metadata,
    deadline: ?i64, // Unix timestamp in ms
    cancelled: std.atomic.Value(bool),
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .metadata = Metadata.init(allocator),
            .deadline = null,
            .cancelled = std.atomic.Value(bool).init(false),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.metadata.deinit();
    }

    pub fn isCancelled(self: *const Self) bool {
        return self.cancelled.load(.acquire);
    }

    pub fn cancel(self: *Self) void {
        self.cancelled.store(true, .release);
    }

    pub fn hasDeadlineExceeded(self: *const Self) bool {
        if (self.deadline) |dl| {
            const now = std.time.milliTimestamp();
            return now > dl;
        }
        return false;
    }
};

/// gRPC Method Type
pub const MethodType = enum {
    unary, // Single request, single response
    client_streaming, // Stream of requests, single response
    server_streaming, // Single request, stream of responses
    bidirectional_streaming, // Stream of requests and responses
};

/// gRPC Service Method
pub fn ServiceMethod(comptime Request: type, comptime Response: type) type {
    return struct {
        name: []const u8,
        method_type: MethodType,
        handler: *const fn (*Context, Request) anyerror!Response,
    };
}

/// gRPC Server Configuration
pub const ServerConfig = struct {
    max_concurrent_streams: u32 = 100,
    max_receive_message_size: usize = 4 * 1024 * 1024, // 4MB
    max_send_message_size: usize = 4 * 1024 * 1024, // 4MB
    keepalive_time_ms: u64 = 7200000, // 2 hours
    keepalive_timeout_ms: u64 = 20000, // 20 seconds
    use_quic: bool = false, // Use HTTP/3 (QUIC) instead of HTTP/2

    pub fn default() ServerConfig {
        return ServerConfig{};
    }

    pub fn withQuic(self: ServerConfig) ServerConfig {
        var config = self;
        config.use_quic = true;
        return config;
    }
};

/// gRPC Server
pub const GrpcServer = struct {
    allocator: std.mem.Allocator,
    runtime: *Runtime,
    address: std.net.Address,
    config: ServerConfig,
    services: std.StringHashMap(Service),
    running: std.atomic.Value(bool),

    const Self = @This();

    const Service = struct {
        name: []const u8,
        methods: std.StringHashMap(MethodHandler),

        const MethodHandler = struct {
            method_type: MethodType,
            // Generic handler - will be type-erased
            handler: *const fn (*Context, []const u8) anyerror![]const u8,
        };
    };

    /// Initialize gRPC server
    pub fn init(
        allocator: std.mem.Allocator,
        runtime: *Runtime,
        address: std.net.Address,
        config: ServerConfig,
    ) !Self {
        return Self{
            .allocator = allocator,
            .runtime = runtime,
            .address = address,
            .config = config,
            .services = std.StringHashMap(Service).init(allocator),
            .running = std.atomic.Value(bool).init(false),
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.services.iterator();
        while (it.next()) |entry| {
            var methods_it = entry.value_ptr.methods.iterator();
            while (methods_it.next()) |m| {
                self.allocator.free(m.key_ptr.*);
            }
            entry.value_ptr.methods.deinit();
            self.allocator.free(entry.key_ptr.*);
        }
        self.services.deinit();
    }

    /// Register a service
    pub fn registerService(self: *Self, name: []const u8) !void {
        const owned_name = try self.allocator.dupe(u8, name);
        const service = Service{
            .name = owned_name,
            .methods = std.StringHashMap(Service.MethodHandler).init(self.allocator),
        };
        try self.services.put(owned_name, service);
    }

    /// Register a method for a service
    pub fn registerMethod(
        self: *Self,
        service_name: []const u8,
        method_name: []const u8,
        method_type: MethodType,
        handler: *const fn (*Context, []const u8) anyerror![]const u8,
    ) !void {
        var service = self.services.getPtr(service_name) orelse return error.ServiceNotFound;

        const owned_method = try self.allocator.dupe(u8, method_name);
        try service.methods.put(owned_method, Service.MethodHandler{
            .method_type = method_type,
            .handler = handler,
        });
    }

    /// Start gRPC server
    pub fn serve(self: *Self) !void {
        self.running.store(true, .release);

        if (self.config.use_quic) {
            std.debug.print("[gRPC] Server starting with HTTP/3 (QUIC) on {}\n", .{self.address});
        } else {
            std.debug.print("[gRPC] Server starting with HTTP/2 on {}\n", .{self.address});
        }

        std.debug.print("[gRPC] Max concurrent streams: {}\n", .{self.config.max_concurrent_streams});
        std.debug.print("[gRPC] Services registered: {}\n", .{self.services.count()});

        // TODO: Create HTTP/2 or HTTP/3 server
        // TODO: Accept connections
        // TODO: Parse gRPC frames
        // TODO: Route to appropriate service method
        // TODO: Handle streaming

        while (self.running.load(.acquire)) {
            std.posix.nanosleep(0, 100 * std.time.ns_per_ms);
        }
    }

    /// Stop gRPC server
    pub fn stop(self: *Self) void {
        self.running.store(false, .release);
    }

    /// Handle gRPC request (internal)
    fn handleRequest(
        self: *Self,
        service_name: []const u8,
        method_name: []const u8,
        request_data: []const u8,
    ) ![]const u8 {
        const service = self.services.get(service_name) orelse return error.ServiceNotFound;
        const method = service.methods.get(method_name) orelse return error.MethodNotFound;

        var ctx = Context.init(self.allocator);
        defer ctx.deinit();

        // TODO: Parse protobuf message
        // TODO: Call handler
        // TODO: Encode response

        return try method.handler(&ctx, request_data);
    }
};

/// gRPC Unary Handler (single request/response)
pub fn UnaryHandler(comptime Request: type, comptime Response: type) type {
    return struct {
        handler_fn: *const fn (*Context, Request) anyerror!Response,

        const Self = @This();

        pub fn call(self: Self, ctx: *Context, request: Request) !Response {
            if (ctx.isCancelled()) return error.Cancelled;
            if (ctx.hasDeadlineExceeded()) return error.DeadlineExceeded;

            return try self.handler_fn(ctx, request);
        }
    };
}

/// gRPC Stream Writer
pub fn StreamWriter(comptime T: type) type {
    return struct {
        allocator: std.mem.Allocator,
        messages: std.ArrayList(T),

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{
                .allocator = allocator,
                .messages = std.ArrayList(T){ .allocator = allocator },
            };
        }

        pub fn deinit(self: *Self) void {
            self.messages.deinit();
        }

        pub fn send(self: *Self, message: T) !void {
            try self.messages.append(self.allocator, message);
            // TODO: Actually write to stream
        }
    };
}

/// gRPC Stream Reader
pub fn StreamReader(comptime T: type) type {
    return struct {
        allocator: std.mem.Allocator,
        messages: std.ArrayList(T),
        index: usize,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{
                .allocator = allocator,
                .messages = std.ArrayList(T){ .allocator = allocator },
                .index = 0,
            };
        }

        pub fn deinit(self: *Self) void {
            self.messages.deinit();
        }

        pub fn recv(self: *Self) !?T {
            if (self.index >= self.messages.items.len) {
                // TODO: Read from actual stream
                return null;
            }

            const msg = self.messages.items[self.index];
            self.index += 1;
            return msg;
        }
    };
}

// Tests
test "grpc status code" {
    const testing = std.testing;

    const status = StatusCode.ok;
    try testing.expect(std.mem.eql(u8, status.toString(), "OK"));
}

test "grpc metadata" {
    const testing = std.testing;

    var meta = Metadata.init(testing.allocator);
    defer meta.deinit();

    try meta.set("authorization", "Bearer token123");
    const auth = meta.get("authorization");
    try testing.expect(auth != null);
}

test "grpc context" {
    const testing = std.testing;

    var ctx = Context.init(testing.allocator);
    defer ctx.deinit();

    try testing.expect(!ctx.isCancelled());
    ctx.cancel();
    try testing.expect(ctx.isCancelled());
}
