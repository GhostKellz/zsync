//! Zsync v0.6.0 - HTTP Server Abstractions
//! High-performance HTTP server built on zsync runtime

const std = @import("std");
const runtime_mod = @import("../runtime.zig");
const spawn_mod = @import("../spawn.zig");
const channels = @import("../channels.zig");

const Runtime = runtime_mod.Runtime;
const Io = @import("../io_interface.zig").Io;

/// HTTP Request
pub const Request = struct {
    method: Method,
    path: []const u8,
    headers: std.StringHashMap([]const u8),
    body: []const u8,
    allocator: std.mem.Allocator,

    pub const Method = enum {
        GET,
        POST,
        PUT,
        DELETE,
        PATCH,
        HEAD,
        OPTIONS,
    };

    pub fn init(allocator: std.mem.Allocator) Request {
        return Request{
            .method = .GET,
            .path = "/",
            .headers = std.StringHashMap([]const u8).init(allocator),
            .body = "",
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Request) void {
        self.headers.deinit();
    }

    /// Get header value
    pub fn getHeader(self: *Request, name: []const u8) ?[]const u8 {
        return self.headers.get(name);
    }
};

/// HTTP Response
pub const Response = struct {
    status_code: u16,
    headers: std.StringHashMap([]const u8),
    body: std.ArrayList(u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Response {
        return Response{
            .status_code = 200,
            .headers = std.StringHashMap([]const u8).init(allocator),
            .body = std.ArrayList(u8){ .allocator = allocator },
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Response) void {
        self.headers.deinit();
        self.body.deinit();
    }

    /// Set status code
    pub fn status(self: *Response, code: u16) !void {
        self.status_code = code;
    }

    /// Add header
    pub fn header(self: *Response, name: []const u8, value: []const u8) !void {
        try self.headers.put(name, value);
    }

    /// Write body content
    pub fn write(self: *Response, content: []const u8) !void {
        try self.body.appendSlice(content);
    }

    /// Write JSON response
    pub fn json(self: *Response, data: anytype) !void {
        try self.header("Content-Type", "application/json");
        // TODO: Implement JSON serialization
        _ = data;
    }

    /// Get status text
    pub fn getStatusText(code: u16) []const u8 {
        return switch (code) {
            200 => "OK",
            201 => "Created",
            204 => "No Content",
            301 => "Moved Permanently",
            302 => "Found",
            304 => "Not Modified",
            400 => "Bad Request",
            401 => "Unauthorized",
            403 => "Forbidden",
            404 => "Not Found",
            405 => "Method Not Allowed",
            500 => "Internal Server Error",
            502 => "Bad Gateway",
            503 => "Service Unavailable",
            else => "Unknown",
        };
    }
};

/// HTTP Request Handler function type
pub const HandlerFn = *const fn (*Request, *Response) anyerror!void;

/// HTTP Server
pub const HttpServer = struct {
    runtime: *Runtime,
    allocator: std.mem.Allocator,
    address: std.net.Address,
    handler: HandlerFn,
    listener: ?std.net.Server,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, address: std.net.Address, handler: HandlerFn) !Self {
        const config = runtime_mod.Config.forServer();
        const runtime = try Runtime.init(allocator, config);

        return Self{
            .runtime = runtime,
            .allocator = allocator,
            .address = address,
            .handler = handler,
            .listener = null,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.listener) |*listener| {
            listener.deinit();
        }
        self.runtime.deinit();
    }

    /// Start the HTTP server
    pub fn listen(self: *Self) !void {
        // Bind to address
        self.listener = try self.address.listen(.{
            .reuse_address = true,
        });

        std.debug.print("🚀 HTTP Server listening on {}:{}\n", .{
            self.address.in.sa.addr,
            self.address.getPort(),
        });

        // Set as global runtime
        self.runtime.setGlobal();

        // Run accept loop
        try self.runtime.run(acceptLoop, .{self});
    }

    /// Accept loop - spawns handler for each connection
    fn acceptLoop(io: Io, server: *Self) !void {
        _ = io;

        while (true) {
            // Accept connection
            const connection = server.listener.?.accept() catch |err| {
                std.debug.print("Accept error: {}\n", .{err});
                continue;
            };

            // Spawn handler for this connection
            // TODO: Use spawn() once it's working with runtime
            handleConnection(server, connection) catch |err| {
                std.debug.print("Handler error: {}\n", .{err});
            };
        }
    }

    /// Handle a single HTTP connection
    fn handleConnection(server: *Self, connection: std.net.Server.Connection) !void {
        defer connection.stream.close();

        // Read request (simplified - just read raw data)
        var buffer: [8192]u8 = undefined;
        const bytes_read = try connection.stream.read(&buffer);

        if (bytes_read == 0) return;

        // Parse request (simplified)
        var request = Request.init(server.allocator);
        defer request.deinit();

        // Basic parsing - find method and path
        const request_line_end = std.mem.indexOf(u8, buffer[0..bytes_read], "\r\n") orelse return;
        const request_line = buffer[0..request_line_end];

        var parts = std.mem.tokenize(u8, request_line, " ");
        const method_str = parts.next() orelse return;
        const path = parts.next() orelse return;

        request.method = parseMethod(method_str);
        request.path = path;

        // Create response
        var response = Response.init(server.allocator);
        defer response.deinit();

        // Call user handler
        server.handler(&request, &response) catch |err| {
            response.status_code = 500;
            try response.write("Internal Server Error");
            std.debug.print("Handler error: {}\n", .{err});
        };

        // Send response
        try sendResponse(connection.stream, &response);
    }

    /// Send HTTP response
    fn sendResponse(stream: std.net.Stream, response: *Response) !void {
        var writer = stream.writer();

        // Status line
        try writer.print("HTTP/1.1 {} {s}\r\n", .{
            response.status_code,
            Response.getStatusText(response.status_code),
        });

        // Headers
        var header_iter = response.headers.iterator();
        while (header_iter.next()) |entry| {
            try writer.print("{s}: {s}\r\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }

        // Content-Length
        try writer.print("Content-Length: {}\r\n", .{response.body.items.len});

        // End headers
        try writer.writeAll("\r\n");

        // Body
        try writer.writeAll(response.body.items);
    }

    /// Parse HTTP method from string
    fn parseMethod(str: []const u8) Request.Method {
        if (std.mem.eql(u8, str, "GET")) return .GET;
        if (std.mem.eql(u8, str, "POST")) return .POST;
        if (std.mem.eql(u8, str, "PUT")) return .PUT;
        if (std.mem.eql(u8, str, "DELETE")) return .DELETE;
        if (std.mem.eql(u8, str, "PATCH")) return .PATCH;
        if (std.mem.eql(u8, str, "HEAD")) return .HEAD;
        if (std.mem.eql(u8, str, "OPTIONS")) return .OPTIONS;
        return .GET;
    }
};

/// Quick start HTTP server
pub fn listen(
    allocator: std.mem.Allocator,
    address: std.net.Address,
    handler: HandlerFn,
) !void {
    var server = try HttpServer.init(allocator, address, handler);
    defer server.deinit();

    try server.listen();
}
