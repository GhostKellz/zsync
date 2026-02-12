//! Zsync v0.6.0 - LSP Server Abstractions
//! JSON-RPC based Language Server Protocol implementation for Grim/Grove

const std = @import("std");
const compat = @import("../compat/thread.zig");
const Runtime = @import("../runtime.zig").Runtime;
const channels = @import("../channels.zig");

/// LSP Protocol Version
pub const PROTOCOL_VERSION = "3.17.0";

/// JSON-RPC Message Types
pub const MessageType = enum {
    request,
    response,
    notification,
    error_response,
};

/// LSP Request ID (can be number or string)
pub const RequestId = union(enum) {
    number: i64,
    string: []const u8,

    pub fn eql(self: RequestId, other: RequestId) bool {
        return switch (self) {
            .number => |n| switch (other) {
                .number => |on| n == on,
                else => false,
            },
            .string => |s| switch (other) {
                .string => |os| std.mem.eql(u8, s, os),
                else => false,
            },
        };
    }
};

/// LSP Message
pub const Message = struct {
    jsonrpc: []const u8 = "2.0",
    id: ?RequestId = null,
    method: ?[]const u8 = null,
    params: ?std.json.Value = null,
    result: ?std.json.Value = null,
    @"error": ?ErrorObject = null,

    pub const ErrorObject = struct {
        code: i32,
        message: []const u8,
        data: ?std.json.Value = null,
    };
};

/// LSP Error Codes
pub const ErrorCode = enum(i32) {
    parse_error = -32700,
    invalid_request = -32600,
    method_not_found = -32601,
    invalid_params = -32602,
    internal_error = -32603,
    server_not_initialized = -32002,
    unknown_error_code = -32001,
    request_cancelled = -32800,
    content_modified = -32801,
};

/// LSP Handler Function
pub const Handler = *const fn (
    params: std.json.Value,
    allocator: std.mem.Allocator,
) anyerror!std.json.Value;

/// LSP Server Configuration
pub const ServerConfig = struct {
    name: []const u8,
    version: []const u8,
    capabilities: ServerCapabilities = ServerCapabilities{},
};

/// Server Capabilities
pub const ServerCapabilities = struct {
    text_document_sync: ?TextDocumentSyncKind = null,
    completion_provider: bool = false,
    hover_provider: bool = false,
    definition_provider: bool = false,
    references_provider: bool = false,
    document_highlight_provider: bool = false,
    document_symbol_provider: bool = false,
    workspace_symbol_provider: bool = false,
    code_action_provider: bool = false,
    code_lens_provider: bool = false,
    document_formatting_provider: bool = false,
    document_range_formatting_provider: bool = false,
    rename_provider: bool = false,
    document_link_provider: bool = false,
    execute_command_provider: bool = false,
    semantic_tokens_provider: bool = false,
    inlay_hint_provider: bool = false,
};

/// Text Document Sync Kind
pub const TextDocumentSyncKind = enum(u8) {
    none = 0,
    full = 1,
    incremental = 2,
};

/// LSP Server
pub const LspServer = struct {
    allocator: std.mem.Allocator,
    runtime: *Runtime,
    config: ServerConfig,
    handlers: std.StringHashMap(Handler),
    pending_requests: std.AutoHashMap(RequestId, std.json.Value),
    initialized: std.atomic.Value(bool),
    shutdown_requested: std.atomic.Value(bool),
    mutex: compat.Mutex,

    // Communication channels
    stdin: std.fs.File,
    stdout: std.fs.File,
    message_queue: channels.UnboundedChannel([]const u8),

    const Self = @This();

    /// Initialize LSP server
    pub fn init(
        allocator: std.mem.Allocator,
        runtime: *Runtime,
        config: ServerConfig,
    ) !Self {
        return Self{
            .allocator = allocator,
            .runtime = runtime,
            .config = config,
            .handlers = std.StringHashMap(Handler).init(allocator),
            .pending_requests = std.AutoHashMap(RequestId, std.json.Value).init(allocator),
            .initialized = std.atomic.Value(bool).init(false),
            .shutdown_requested = std.atomic.Value(bool).init(false),
            .mutex = .{},
            .stdin = std.io.getStdIn(),
            .stdout = std.io.getStdOut(),
            .message_queue = try channels.unbounded([]const u8, allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.handlers.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.handlers.deinit();
        self.pending_requests.deinit();
        self.message_queue.deinit();
    }

    /// Register a handler for an LSP method
    pub fn registerHandler(self: *Self, method: []const u8, handler: Handler) !void {
        const owned_method = try self.allocator.dupe(u8, method);
        try self.handlers.put(owned_method, handler);
    }

    /// Start LSP server
    pub fn run(self: *Self) !void {
        std.debug.print("[LSP] {} v{s} starting...\n", .{ self.config.name, self.config.version });

        // Read messages from stdin
        var reader = self.stdin.reader();
        var buf: [4096]u8 = undefined;

        while (!self.shutdown_requested.load(.acquire)) {
            // Read Content-Length header
            const header_line = reader.readUntilDelimiter(&buf, '\n') catch break;

            if (std.mem.startsWith(u8, header_line, "Content-Length: ")) {
                const length_str = header_line["Content-Length: ".len..];
                const content_length = try std.fmt.parseInt(usize, std.mem.trim(u8, length_str, "\r"), 10);

                // Skip empty line
                _ = try reader.readUntilDelimiter(&buf, '\n');

                // Read JSON content
                const content = try self.allocator.alloc(u8, content_length);
                defer self.allocator.free(content);
                try reader.readNoEof(content);

                // Handle message
                try self.handleMessage(content);
            }
        }

        std.debug.print("[LSP] Server shutting down\n", .{});
    }

    /// Handle incoming LSP message
    fn handleMessage(self: *Self, content: []const u8) !void {
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, content, .{});
        defer parsed.deinit();

        const root = parsed.value;
        const obj = root.object;

        // Get method
        const method = if (obj.get("method")) |m| m.string else null;
        const id = if (obj.get("id")) |i| switch (i) {
            .integer => |n| RequestId{ .number = n },
            .string => |s| RequestId{ .string = s },
            else => null,
        } else null;

        if (method) |m| {
            if (std.mem.eql(u8, m, "initialize")) {
                try self.handleInitialize(id.?, obj.get("params") orelse .null);
            } else if (std.mem.eql(u8, m, "initialized")) {
                self.initialized.store(true, .release);
            } else if (std.mem.eql(u8, m, "shutdown")) {
                try self.handleShutdown(id.?);
            } else if (std.mem.eql(u8, m, "exit")) {
                self.shutdown_requested.store(true, .release);
            } else {
                // Dispatch to registered handler
                if (self.handlers.get(m)) |handler| {
                    const params = obj.get("params") orelse .null;
                    const result = handler(params, self.allocator) catch |err| {
                        try self.sendError(id, ErrorCode.internal_error, @errorName(err));
                        return;
                    };

                    if (id) |request_id| {
                        try self.sendResponse(request_id, result);
                    }
                } else if (id) |request_id| {
                    try self.sendError(request_id, ErrorCode.method_not_found, "Method not found");
                }
            }
        }
    }

    /// Handle initialize request
    fn handleInitialize(self: *Self, id: RequestId, params: std.json.Value) !void {
        _ = params;

        var result = std.json.Value{
            .object = std.json.ObjectMap.init(self.allocator),
        };

        try result.object.put("capabilities", .{
            .object = std.json.ObjectMap.init(self.allocator),
        });

        try result.object.put("serverInfo", .{
            .object = std.json.ObjectMap.init(self.allocator),
        });

        try self.sendResponse(id, result);
    }

    /// Handle shutdown request
    fn handleShutdown(self: *Self, id: RequestId) !void {
        try self.sendResponse(id, .null);
    }

    /// Send response
    fn sendResponse(self: *Self, id: RequestId, result: std.json.Value) !void {
        var response = std.json.Value{
            .object = std.json.ObjectMap.init(self.allocator),
        };

        try response.object.put("jsonrpc", .{ .string = "2.0" });

        switch (id) {
            .number => |n| try response.object.put("id", .{ .integer = n }),
            .string => |s| try response.object.put("id", .{ .string = s }),
        }

        try response.object.put("result", result);

        try self.writeMessage(response);
    }

    /// Send error
    fn sendError(self: *Self, id: ?RequestId, code: ErrorCode, message: []const u8) !void {
        var response = std.json.Value{
            .object = std.json.ObjectMap.init(self.allocator),
        };

        try response.object.put("jsonrpc", .{ .string = "2.0" });

        if (id) |request_id| {
            switch (request_id) {
                .number => |n| try response.object.put("id", .{ .integer = n }),
                .string => |s| try response.object.put("id", .{ .string = s }),
            }
        } else {
            try response.object.put("id", .null);
        }

        var error_obj = std.json.ObjectMap.init(self.allocator);
        try error_obj.put("code", .{ .integer = @intFromEnum(code) });
        try error_obj.put("message", .{ .string = message });

        try response.object.put("error", .{ .object = error_obj });

        try self.writeMessage(response);
    }

    /// Write message to stdout
    fn writeMessage(self: *Self, message: std.json.Value) !void {
        var string = std.ArrayList(u8){ .allocator = self.allocator };
        defer string.deinit();

        try std.json.stringify(message, .{}, string.writer());

        const content = string.items;
        const header = try std.fmt.allocPrint(
            self.allocator,
            "Content-Length: {}\r\n\r\n",
            .{content.len},
        );
        defer self.allocator.free(header);

        self.mutex.lock();
        defer self.mutex.unlock();

        try self.stdout.writeAll(header);
        try self.stdout.writeAll(content);
    }

    /// Send notification (no response expected)
    pub fn sendNotification(self: *Self, method: []const u8, params: std.json.Value) !void {
        var notification = std.json.Value{
            .object = std.json.ObjectMap.init(self.allocator),
        };

        try notification.object.put("jsonrpc", .{ .string = "2.0" });
        try notification.object.put("method", .{ .string = method });
        try notification.object.put("params", params);

        try self.writeMessage(notification);
    }
};

// Common LSP Types
pub const Position = struct {
    line: u32,
    character: u32,
};

pub const Range = struct {
    start: Position,
    end: Position,
};

pub const Location = struct {
    uri: []const u8,
    range: Range,
};

pub const Diagnostic = struct {
    range: Range,
    severity: ?DiagnosticSeverity = null,
    code: ?[]const u8 = null,
    source: ?[]const u8 = null,
    message: []const u8,

    pub const DiagnosticSeverity = enum(u8) {
        @"error" = 1,
        warning = 2,
        information = 3,
        hint = 4,
    };
};

pub const TextEdit = struct {
    range: Range,
    new_text: []const u8,
};

// Tests
test "lsp position" {
    const pos = Position{ .line = 10, .character = 5 };
    const testing = std.testing;
    try testing.expectEqual(10, pos.line);
    try testing.expectEqual(5, pos.character);
}

test "lsp request id" {
    const testing = std.testing;

    const id1 = RequestId{ .number = 42 };
    const id2 = RequestId{ .number = 42 };
    const id3 = RequestId{ .number = 43 };

    try testing.expect(id1.eql(id2));
    try testing.expect(!id1.eql(id3));
}
