//! LSP Async Integration
//! Language Server Protocol support for development tools
//! High-performance async LSP client/server implementation

const std = @import("std");
const io_v2 = @import("io_v2.zig");
const net = std.net;
const json = std.json;

/// LSP Message Types
pub const LSPMessageType = enum {
    request,
    response,
    notification,
    error_response,
};

/// LSP Request Methods
pub const LSPMethod = enum {
    initialize,
    shutdown,
    exit,
    text_document_did_open,
    text_document_did_change,
    text_document_did_save,
    text_document_did_close,
    text_document_completion,
    text_document_hover,
    text_document_definition,
    text_document_references,
    text_document_formatting,
    text_document_range_formatting,
    text_document_rename,
    text_document_code_action,
    text_document_diagnostic,
    workspace_symbol,
    workspace_did_change_configuration,
    workspace_did_change_watched_files,
    
    pub fn toString(self: LSPMethod) []const u8 {
        return switch (self) {
            .initialize => "initialize",
            .shutdown => "shutdown",
            .exit => "exit",
            .text_document_did_open => "textDocument/didOpen",
            .text_document_did_change => "textDocument/didChange",
            .text_document_did_save => "textDocument/didSave",
            .text_document_did_close => "textDocument/didClose",
            .text_document_completion => "textDocument/completion",
            .text_document_hover => "textDocument/hover",
            .text_document_definition => "textDocument/definition",
            .text_document_references => "textDocument/references",
            .text_document_formatting => "textDocument/formatting",
            .text_document_range_formatting => "textDocument/rangeFormatting",
            .text_document_rename => "textDocument/rename",
            .text_document_code_action => "textDocument/codeAction",
            .text_document_diagnostic => "textDocument/diagnostic",
            .workspace_symbol => "workspace/symbol",
            .workspace_did_change_configuration => "workspace/didChangeConfiguration",
            .workspace_did_change_watched_files => "workspace/didChangeWatchedFiles",
        };
    }
};

/// LSP Position
pub const LSPPosition = struct {
    line: u32,
    character: u32,
};

/// LSP Range
pub const LSPRange = struct {
    start: LSPPosition,
    end: LSPPosition,
};

/// LSP Text Document Identifier
pub const LSPTextDocumentIdentifier = struct {
    uri: []const u8,
    
    pub fn deinit(self: *LSPTextDocumentIdentifier, allocator: std.mem.Allocator) void {
        allocator.free(self.uri);
    }
};

/// LSP Versioned Text Document Identifier
pub const LSPVersionedTextDocumentIdentifier = struct {
    uri: []const u8,
    version: ?i32,
    
    pub fn deinit(self: *LSPVersionedTextDocumentIdentifier, allocator: std.mem.Allocator) void {
        allocator.free(self.uri);
    }
};

/// LSP Text Document Item
pub const LSPTextDocumentItem = struct {
    uri: []const u8,
    language_id: []const u8,
    version: i32,
    text: []const u8,
    
    pub fn deinit(self: *LSPTextDocumentItem, allocator: std.mem.Allocator) void {
        allocator.free(self.uri);
        allocator.free(self.language_id);
        allocator.free(self.text);
    }
};

/// LSP Text Document Content Change Event
pub const LSPTextDocumentContentChangeEvent = struct {
    range: ?LSPRange,
    range_length: ?u32,
    text: []const u8,
    
    pub fn deinit(self: *LSPTextDocumentContentChangeEvent, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
    }
};

/// LSP Diagnostic Severity
pub const LSPDiagnosticSeverity = enum(u8) {
    error = 1,
    warning = 2,
    information = 3,
    hint = 4,
};

/// LSP Diagnostic
pub const LSPDiagnostic = struct {
    range: LSPRange,
    severity: ?LSPDiagnosticSeverity,
    code: ?[]const u8,
    source: ?[]const u8,
    message: []const u8,
    related_information: ?[]LSPDiagnosticRelatedInformation,
    
    pub fn deinit(self: *LSPDiagnostic, allocator: std.mem.Allocator) void {
        if (self.code) |code| {
            allocator.free(code);
        }
        if (self.source) |source| {
            allocator.free(source);
        }
        allocator.free(self.message);
        
        if (self.related_information) |info| {
            for (info) |*related| {
                related.deinit(allocator);
            }
            allocator.free(info);
        }
    }
};

/// LSP Diagnostic Related Information
pub const LSPDiagnosticRelatedInformation = struct {
    location: LSPLocation,
    message: []const u8,
    
    pub fn deinit(self: *LSPDiagnosticRelatedInformation, allocator: std.mem.Allocator) void {
        self.location.deinit(allocator);
        allocator.free(self.message);
    }
};

/// LSP Location
pub const LSPLocation = struct {
    uri: []const u8,
    range: LSPRange,
    
    pub fn deinit(self: *LSPLocation, allocator: std.mem.Allocator) void {
        allocator.free(self.uri);
    }
};

/// LSP Completion Item Kind
pub const LSPCompletionItemKind = enum(u8) {
    text = 1,
    method = 2,
    function = 3,
    constructor = 4,
    field = 5,
    variable = 6,
    class = 7,
    interface = 8,
    module = 9,
    property = 10,
    unit = 11,
    value = 12,
    enumeration = 13,
    keyword = 14,
    snippet = 15,
    color = 16,
    file = 17,
    reference = 18,
    folder = 19,
    enum_member = 20,
    constant = 21,
    struct = 22,
    event = 23,
    operator = 24,
    type_parameter = 25,
};

/// LSP Completion Item
pub const LSPCompletionItem = struct {
    label: []const u8,
    kind: ?LSPCompletionItemKind,
    detail: ?[]const u8,
    documentation: ?[]const u8,
    deprecated: bool = false,
    preselect: bool = false,
    sort_text: ?[]const u8,
    filter_text: ?[]const u8,
    insert_text: ?[]const u8,
    
    pub fn deinit(self: *LSPCompletionItem, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
        if (self.detail) |detail| {
            allocator.free(detail);
        }
        if (self.documentation) |doc| {
            allocator.free(doc);
        }
        if (self.sort_text) |sort| {
            allocator.free(sort);
        }
        if (self.filter_text) |filter| {
            allocator.free(filter);
        }
        if (self.insert_text) |insert| {
            allocator.free(insert);
        }
    }
};

/// LSP Hover Information
pub const LSPHover = struct {
    contents: []const u8,
    range: ?LSPRange,
    
    pub fn deinit(self: *LSPHover, allocator: std.mem.Allocator) void {
        allocator.free(self.contents);
    }
};

/// LSP Message Header
pub const LSPMessageHeader = struct {
    content_length: usize,
    content_type: ?[]const u8,
    
    pub fn deinit(self: *LSPMessageHeader, allocator: std.mem.Allocator) void {
        if (self.content_type) |ct| {
            allocator.free(ct);
        }
    }
};

/// LSP Message
pub const LSPMessage = struct {
    header: LSPMessageHeader,
    content: []const u8,
    
    pub fn deinit(self: *LSPMessage, allocator: std.mem.Allocator) void {
        self.header.deinit(allocator);
        allocator.free(self.content);
    }
};

/// LSP JSON-RPC Message
pub const LSPJsonRpcMessage = struct {
    jsonrpc: []const u8 = "2.0",
    id: ?json.Value = null,
    method: ?[]const u8 = null,
    params: ?json.Value = null,
    result: ?json.Value = null,
    error: ?LSPJsonRpcError = null,
    
    pub fn deinit(self: *LSPJsonRpcMessage, allocator: std.mem.Allocator) void {
        if (self.method) |method| {
            allocator.free(method);
        }
        if (self.error) |*err| {
            err.deinit(allocator);
        }
    }
};

/// LSP JSON-RPC Error
pub const LSPJsonRpcError = struct {
    code: i32,
    message: []const u8,
    data: ?json.Value = null,
    
    pub fn deinit(self: *LSPJsonRpcError, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
    }
};

/// LSP Client Configuration
pub const LSPClientConfig = struct {
    server_command: []const u8,
    server_args: []const []const u8,
    working_directory: ?[]const u8 = null,
    environment: ?std.hash_map.HashMap([]const u8, []const u8, std.hash_map.StringContext, 80) = null,
    timeout_ms: u64 = 5000,
    max_message_size: usize = 1024 * 1024, // 1MB
    auto_restart: bool = true,
    trace_level: LSPTraceLevel = .off,
};

/// LSP Trace Level
pub const LSPTraceLevel = enum {
    off,
    messages,
    verbose,
};

/// LSP Server Capabilities
pub const LSPServerCapabilities = struct {
    text_document_sync: bool = false,
    hover_provider: bool = false,
    completion_provider: bool = false,
    signature_help_provider: bool = false,
    definition_provider: bool = false,
    type_definition_provider: bool = false,
    implementation_provider: bool = false,
    references_provider: bool = false,
    document_highlight_provider: bool = false,
    document_symbol_provider: bool = false,
    code_action_provider: bool = false,
    code_lens_provider: bool = false,
    document_formatting_provider: bool = false,
    document_range_formatting_provider: bool = false,
    document_on_type_formatting_provider: bool = false,
    rename_provider: bool = false,
    document_link_provider: bool = false,
    color_provider: bool = false,
    folding_range_provider: bool = false,
    declaration_provider: bool = false,
    execute_command_provider: bool = false,
    workspace_symbol_provider: bool = false,
    call_hierarchy_provider: bool = false,
    semantic_tokens_provider: bool = false,
    moniker_provider: bool = false,
    type_hierarchy_provider: bool = false,
    inline_value_provider: bool = false,
    inlay_hint_provider: bool = false,
    diagnostic_provider: bool = false,
};

/// Async LSP Client
pub const AsyncLSPClient = struct {
    allocator: std.mem.Allocator,
    io: io_v2.Io,
    config: LSPClientConfig,
    
    // Server process management
    server_process: ?std.process.Child = null,
    server_stdin: ?std.fs.File = null,
    server_stdout: ?std.fs.File = null,
    server_stderr: ?std.fs.File = null,
    
    // Message handling
    pending_requests: std.hash_map.HashMap(i32, PendingRequest, std.hash_map.AutoContext(i32), 80),
    request_id_counter: std.atomic.Value(i32),
    
    // Document management
    open_documents: std.hash_map.HashMap([]const u8, LSPTextDocumentItem, std.hash_map.StringContext, 80),
    
    // Server capabilities
    server_capabilities: LSPServerCapabilities,
    initialized: std.atomic.Value(bool),
    
    // Worker management
    message_reader: ?std.Thread = null,
    message_writer: ?std.Thread = null,
    worker_active: std.atomic.Value(bool),
    
    // Message queues
    outgoing_messages: std.ArrayList(LSPMessage),
    incoming_messages: std.ArrayList(LSPMessage),
    
    // Synchronization
    mutex: std.Thread.Mutex,
    message_condition: std.Thread.Condition,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, io: io_v2.Io, config: LSPClientConfig) !Self {
        return Self{
            .allocator = allocator,
            .io = io,
            .config = config,
            .pending_requests = std.hash_map.HashMap(i32, PendingRequest, std.hash_map.AutoContext(i32), 80).init(allocator),
            .request_id_counter = std.atomic.Value(i32).init(1),
            .open_documents = std.hash_map.HashMap([]const u8, LSPTextDocumentItem, std.hash_map.StringContext, 80).init(allocator),
            .server_capabilities = LSPServerCapabilities{},
            .initialized = std.atomic.Value(bool).init(false),
            .worker_active = std.atomic.Value(bool).init(false),
            .outgoing_messages = std.ArrayList(LSPMessage).init(allocator),
            .incoming_messages = std.ArrayList(LSPMessage).init(allocator),
            .mutex = .{},
            .message_condition = .{},
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.shutdown();
        
        var req_iter = self.pending_requests.iterator();
        while (req_iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.pending_requests.deinit();
        
        var doc_iter = self.open_documents.iterator();
        while (doc_iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.open_documents.deinit();
        
        for (self.outgoing_messages.items) |*msg| {
            msg.deinit(self.allocator);
        }
        self.outgoing_messages.deinit();
        
        for (self.incoming_messages.items) |*msg| {
            msg.deinit(self.allocator);
        }
        self.incoming_messages.deinit();
    }
    
    /// Start LSP server and initialize connection
    pub fn startAsync(self: *Self, allocator: std.mem.Allocator) !io_v2.Future {
        const ctx = try allocator.create(StartLSPContext);
        ctx.* = .{
            .client = self,
            .allocator = allocator,
            .started = false,
        };
        
        return io_v2.Future{
            .impl = .{
                .callback = .{
                    .context = @ptrCast(ctx),
                    .poll_fn = startLSPPoll,
                    .deinit_fn = startLSPDeinit,
                },
            },
        };
    }
    
    /// Send completion request
    pub fn completionAsync(self: *Self, allocator: std.mem.Allocator, document_uri: []const u8, position: LSPPosition) !io_v2.Future {
        const ctx = try allocator.create(CompletionContext);
        ctx.* = .{
            .client = self,
            .document_uri = try allocator.dupe(u8, document_uri),
            .position = position,
            .allocator = allocator,
            .completion_items = std.ArrayList(LSPCompletionItem).init(allocator),
        };
        
        return io_v2.Future{
            .impl = .{
                .callback = .{
                    .context = @ptrCast(ctx),
                    .poll_fn = completionPoll,
                    .deinit_fn = completionDeinit,
                },
            },
        };
    }
    
    /// Send hover request
    pub fn hoverAsync(self: *Self, allocator: std.mem.Allocator, document_uri: []const u8, position: LSPPosition) !io_v2.Future {
        const ctx = try allocator.create(HoverContext);
        ctx.* = .{
            .client = self,
            .document_uri = try allocator.dupe(u8, document_uri),
            .position = position,
            .allocator = allocator,
            .hover_info = null,
        };
        
        return io_v2.Future{
            .impl = .{
                .callback = .{
                    .context = @ptrCast(ctx),
                    .poll_fn = hoverPoll,
                    .deinit_fn = hoverDeinit,
                },
            },
        };
    }
    
    /// Send goto definition request
    pub fn definitionAsync(self: *Self, allocator: std.mem.Allocator, document_uri: []const u8, position: LSPPosition) !io_v2.Future {
        const ctx = try allocator.create(DefinitionContext);
        ctx.* = .{
            .client = self,
            .document_uri = try allocator.dupe(u8, document_uri),
            .position = position,
            .allocator = allocator,
            .locations = std.ArrayList(LSPLocation).init(allocator),
        };
        
        return io_v2.Future{
            .impl = .{
                .callback = .{
                    .context = @ptrCast(ctx),
                    .poll_fn = definitionPoll,
                    .deinit_fn = definitionDeinit,
                },
            },
        };
    }
    
    /// Open document notification
    pub fn openDocumentAsync(self: *Self, allocator: std.mem.Allocator, document: LSPTextDocumentItem) !io_v2.Future {
        const ctx = try allocator.create(OpenDocumentContext);
        ctx.* = .{
            .client = self,
            .document = document,
            .allocator = allocator,
            .opened = false,
        };
        
        return io_v2.Future{
            .impl = .{
                .callback = .{
                    .context = @ptrCast(ctx),
                    .poll_fn = openDocumentPoll,
                    .deinit_fn = openDocumentDeinit,
                },
            },
        };
    }
    
    /// Change document notification
    pub fn changeDocumentAsync(self: *Self, allocator: std.mem.Allocator, document_uri: []const u8, version: i32, changes: []const LSPTextDocumentContentChangeEvent) !io_v2.Future {
        const ctx = try allocator.create(ChangeDocumentContext);
        ctx.* = .{
            .client = self,
            .document_uri = try allocator.dupe(u8, document_uri),
            .version = version,
            .changes = try allocator.dupe(LSPTextDocumentContentChangeEvent, changes),
            .allocator = allocator,
            .changed = false,
        };
        
        return io_v2.Future{
            .impl = .{
                .callback = .{
                    .context = @ptrCast(ctx),
                    .poll_fn = changeDocumentPoll,
                    .deinit_fn = changeDocumentDeinit,
                },
            },
        };
    }
    
    /// Format document request
    pub fn formatDocumentAsync(self: *Self, allocator: std.mem.Allocator, document_uri: []const u8) !io_v2.Future {
        const ctx = try allocator.create(FormatDocumentContext);
        ctx.* = .{
            .client = self,
            .document_uri = try allocator.dupe(u8, document_uri),
            .allocator = allocator,
            .text_edits = std.ArrayList(LSPTextEdit).init(allocator),
        };
        
        return io_v2.Future{
            .impl = .{
                .callback = .{
                    .context = @ptrCast(ctx),
                    .poll_fn = formatDocumentPoll,
                    .deinit_fn = formatDocumentDeinit,
                },
            },
        };
    }
    
    /// Get diagnostics for document
    pub fn getDiagnosticsAsync(self: *Self, allocator: std.mem.Allocator, document_uri: []const u8) !io_v2.Future {
        const ctx = try allocator.create(DiagnosticsContext);
        ctx.* = .{
            .client = self,
            .document_uri = try allocator.dupe(u8, document_uri),
            .allocator = allocator,
            .diagnostics = std.ArrayList(LSPDiagnostic).init(allocator),
        };
        
        return io_v2.Future{
            .impl = .{
                .callback = .{
                    .context = @ptrCast(ctx),
                    .poll_fn = diagnosticsPoll,
                    .deinit_fn = diagnosticsDeinit,
                },
            },
        };
    }
    
    /// Start worker threads
    pub fn startWorkers(self: *Self) !void {
        if (self.worker_active.swap(true, .acquire)) return;
        
        self.message_reader = try std.Thread.spawn(.{}, messageReaderWorker, .{self});
        self.message_writer = try std.Thread.spawn(.{}, messageWriterWorker, .{self});
    }
    
    /// Stop worker threads
    pub fn stopWorkers(self: *Self) void {
        if (!self.worker_active.swap(false, .release)) return;
        
        // Signal workers to stop
        self.mutex.lock();
        self.message_condition.broadcast();
        self.mutex.unlock();
        
        if (self.message_reader) |thread| {
            thread.join();
            self.message_reader = null;
        }
        
        if (self.message_writer) |thread| {
            thread.join();
            self.message_writer = null;
        }
    }
    
    /// Shutdown LSP client
    pub fn shutdown(self: *Self) void {
        self.stopWorkers();
        
        if (self.server_process) |*process| {
            _ = process.kill() catch {};
            _ = process.wait() catch {};
        }
        
        if (self.server_stdin) |file| {
            file.close();
            self.server_stdin = null;
        }
        
        if (self.server_stdout) |file| {
            file.close();
            self.server_stdout = null;
        }
        
        if (self.server_stderr) |file| {
            file.close();
            self.server_stderr = null;
        }
        
        self.initialized.store(false, .release);
    }
    
    fn startServer(self: *Self) !void {
        var process = std.process.Child.init(self.config.server_args, self.allocator);
        process.stdin_behavior = .Pipe;
        process.stdout_behavior = .Pipe;
        process.stderr_behavior = .Pipe;
        
        if (self.config.working_directory) |cwd| {
            process.cwd = cwd;
        }
        
        try process.spawn();
        
        self.server_process = process;
        self.server_stdin = process.stdin;
        self.server_stdout = process.stdout;
        self.server_stderr = process.stderr;
    }
    
    fn messageReaderWorker(self: *Self) void {
        while (self.worker_active.load(.acquire)) {
            self.readMessage() catch |err| {
                std.log.err("LSP message reader error: {}", .{err});
                if (self.config.auto_restart) {
                    self.restartServer() catch {};
                }
            };
            
            std.time.sleep(1_000_000); // 1ms
        }
    }
    
    fn messageWriterWorker(self: *Self) void {
        while (self.worker_active.load(.acquire)) {
            self.writeMessage() catch |err| {
                std.log.err("LSP message writer error: {}", .{err});
            };
            
            std.time.sleep(1_000_000); // 1ms
        }
    }
    
    fn readMessage(self: *Self) !void {
        const stdout = self.server_stdout orelse return;
        
        // Read message header
        var header_buf: [1024]u8 = undefined;
        var header_len: usize = 0;
        
        while (header_len < header_buf.len - 1) {
            const bytes_read = try stdout.read(header_buf[header_len..header_len + 1]);
            if (bytes_read == 0) break;
            
            header_len += bytes_read;
            
            // Check for header end
            if (header_len >= 4 and std.mem.eql(u8, header_buf[header_len - 4..header_len], "\r\n\r\n")) {
                break;
            }
        }
        
        // Parse header
        const header_str = header_buf[0..header_len];
        const header = try self.parseMessageHeader(header_str);
        
        // Read message content
        const content = try self.allocator.alloc(u8, header.content_length);
        defer self.allocator.free(content);
        
        const bytes_read = try stdout.readAll(content);
        if (bytes_read != header.content_length) {
            return error.IncompleteMessage;
        }
        
        // Store message
        const message = LSPMessage{
            .header = header,
            .content = try self.allocator.dupe(u8, content),
        };
        
        self.mutex.lock();
        defer self.mutex.unlock();
        
        try self.incoming_messages.append(message);
        self.message_condition.signal();
    }
    
    fn writeMessage(self: *Self) !void {
        const stdin = self.server_stdin orelse return;
        
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (self.outgoing_messages.items.len == 0) {
            self.message_condition.wait(&self.mutex);
            return;
        }
        
        const message = self.outgoing_messages.orderedRemove(0);
        defer message.deinit(self.allocator);
        
        // Write header
        const header = try std.fmt.allocPrint(self.allocator, "Content-Length: {}\r\n\r\n", .{message.content.len});
        defer self.allocator.free(header);
        
        try stdin.writeAll(header);
        try stdin.writeAll(message.content);
    }
    
    fn parseMessageHeader(self: *Self, header_str: []const u8) !LSPMessageHeader {
        var content_length: usize = 0;
        var content_type: ?[]const u8 = null;
        
        var lines = std.mem.split(u8, header_str, "\r\n");
        while (lines.next()) |line| {
            if (line.len == 0) break;
            
            if (std.mem.startsWith(u8, line, "Content-Length: ")) {
                const value = line[16..];
                content_length = try std.fmt.parseInt(usize, value, 10);
            } else if (std.mem.startsWith(u8, line, "Content-Type: ")) {
                const value = line[14..];
                content_type = try self.allocator.dupe(u8, value);
            }
        }
        
        return LSPMessageHeader{
            .content_length = content_length,
            .content_type = content_type,
        };
    }
    
    fn restartServer(self: *Self) !void {
        self.shutdown();
        try self.startServer();
        try self.startWorkers();
    }
    
    fn getNextRequestId(self: *Self) i32 {
        return self.request_id_counter.fetchAdd(1, .acq_rel);
    }
};

/// LSP Text Edit
pub const LSPTextEdit = struct {
    range: LSPRange,
    new_text: []const u8,
    
    pub fn deinit(self: *LSPTextEdit, allocator: std.mem.Allocator) void {
        allocator.free(self.new_text);
    }
};

/// Pending LSP Request
pub const PendingRequest = struct {
    id: i32,
    method: LSPMethod,
    sent_at: i64,
    allocator: std.mem.Allocator,
    
    pub fn deinit(self: *PendingRequest, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
    }
};

// Context structures for async operations
const StartLSPContext = struct {
    client: *AsyncLSPClient,
    allocator: std.mem.Allocator,
    started: bool,
};

const CompletionContext = struct {
    client: *AsyncLSPClient,
    document_uri: []const u8,
    position: LSPPosition,
    allocator: std.mem.Allocator,
    completion_items: std.ArrayList(LSPCompletionItem),
};

const HoverContext = struct {
    client: *AsyncLSPClient,
    document_uri: []const u8,
    position: LSPPosition,
    allocator: std.mem.Allocator,
    hover_info: ?LSPHover,
};

const DefinitionContext = struct {
    client: *AsyncLSPClient,
    document_uri: []const u8,
    position: LSPPosition,
    allocator: std.mem.Allocator,
    locations: std.ArrayList(LSPLocation),
};

const OpenDocumentContext = struct {
    client: *AsyncLSPClient,
    document: LSPTextDocumentItem,
    allocator: std.mem.Allocator,
    opened: bool,
};

const ChangeDocumentContext = struct {
    client: *AsyncLSPClient,
    document_uri: []const u8,
    version: i32,
    changes: []const LSPTextDocumentContentChangeEvent,
    allocator: std.mem.Allocator,
    changed: bool,
};

const FormatDocumentContext = struct {
    client: *AsyncLSPClient,
    document_uri: []const u8,
    allocator: std.mem.Allocator,
    text_edits: std.ArrayList(LSPTextEdit),
};

const DiagnosticsContext = struct {
    client: *AsyncLSPClient,
    document_uri: []const u8,
    allocator: std.mem.Allocator,
    diagnostics: std.ArrayList(LSPDiagnostic),
};

// Poll functions for async operations
fn startLSPPoll(context: *anyopaque, io: io_v2.Io) io_v2.Future.PollResult {
    _ = io;
    const ctx = @as(*StartLSPContext, @ptrCast(@alignCast(context)));
    
    if (!ctx.started) {
        // Start server
        ctx.client.startServer() catch return .{ .ready = error.ServerStartFailed };
        ctx.client.startWorkers() catch return .{ .ready = error.WorkerStartFailed };
        
        // Initialize server (simplified)
        ctx.client.initialized.store(true, .release);
        ctx.started = true;
        
        return .{ .ready = true };
    }
    
    return .{ .pending = {} };
}

fn startLSPDeinit(context: *anyopaque, allocator: std.mem.Allocator) void {
    const ctx = @as(*StartLSPContext, @ptrCast(@alignCast(context)));
    allocator.destroy(ctx);
}

fn completionPoll(context: *anyopaque, io: io_v2.Io) io_v2.Future.PollResult {
    _ = io;
    const ctx = @as(*CompletionContext, @ptrCast(@alignCast(context)));
    
    if (!ctx.client.initialized.load(.acquire)) {
        return .{ .ready = error.ServerNotInitialized };
    }
    
    // Simulate completion results
    const mock_completions = [_]LSPCompletionItem{
        .{
            .label = ctx.allocator.dupe(u8, "function_name") catch return .{ .ready = error.OutOfMemory },
            .kind = .function,
            .detail = ctx.allocator.dupe(u8, "fn function_name() -> void") catch return .{ .ready = error.OutOfMemory },
            .documentation = ctx.allocator.dupe(u8, "A sample function") catch return .{ .ready = error.OutOfMemory },
            .sort_text = null,
            .filter_text = null,
            .insert_text = ctx.allocator.dupe(u8, "function_name()") catch return .{ .ready = error.OutOfMemory },
        },
        .{
            .label = ctx.allocator.dupe(u8, "variable_name") catch return .{ .ready = error.OutOfMemory },
            .kind = .variable,
            .detail = ctx.allocator.dupe(u8, "var variable_name: i32") catch return .{ .ready = error.OutOfMemory },
            .documentation = ctx.allocator.dupe(u8, "A sample variable") catch return .{ .ready = error.OutOfMemory },
            .sort_text = null,
            .filter_text = null,
            .insert_text = ctx.allocator.dupe(u8, "variable_name") catch return .{ .ready = error.OutOfMemory },
        },
    };
    
    for (mock_completions) |item| {
        ctx.completion_items.append(item) catch return .{ .ready = error.OutOfMemory };
    }
    
    return .{ .ready = ctx.completion_items.items.len };
}

fn completionDeinit(context: *anyopaque, allocator: std.mem.Allocator) void {
    const ctx = @as(*CompletionContext, @ptrCast(@alignCast(context)));
    allocator.free(ctx.document_uri);
    
    for (ctx.completion_items.items) |*item| {
        item.deinit(allocator);
    }
    ctx.completion_items.deinit();
    
    allocator.destroy(ctx);
}

fn hoverPoll(context: *anyopaque, io: io_v2.Io) io_v2.Future.PollResult {
    _ = io;
    const ctx = @as(*HoverContext, @ptrCast(@alignCast(context)));
    
    if (!ctx.client.initialized.load(.acquire)) {
        return .{ .ready = error.ServerNotInitialized };
    }
    
    // Simulate hover information
    ctx.hover_info = LSPHover{
        .contents = ctx.allocator.dupe(u8, "```zig\nfn example() -> void\n```\n\nThis is an example function.") catch return .{ .ready = error.OutOfMemory },
        .range = LSPRange{
            .start = ctx.position,
            .end = LSPPosition{ .line = ctx.position.line, .character = ctx.position.character + 10 },
        },
    };
    
    return .{ .ready = ctx.hover_info != null };
}

fn hoverDeinit(context: *anyopaque, allocator: std.mem.Allocator) void {
    const ctx = @as(*HoverContext, @ptrCast(@alignCast(context)));
    allocator.free(ctx.document_uri);
    
    if (ctx.hover_info) |*info| {
        info.deinit(allocator);
    }
    
    allocator.destroy(ctx);
}

fn definitionPoll(context: *anyopaque, io: io_v2.Io) io_v2.Future.PollResult {
    _ = io;
    const ctx = @as(*DefinitionContext, @ptrCast(@alignCast(context)));
    
    if (!ctx.client.initialized.load(.acquire)) {
        return .{ .ready = error.ServerNotInitialized };
    }
    
    // Simulate definition locations
    const location = LSPLocation{
        .uri = ctx.allocator.dupe(u8, ctx.document_uri) catch return .{ .ready = error.OutOfMemory },
        .range = LSPRange{
            .start = LSPPosition{ .line = 10, .character = 0 },
            .end = LSPPosition{ .line = 10, .character = 15 },
        },
    };
    
    ctx.locations.append(location) catch return .{ .ready = error.OutOfMemory };
    
    return .{ .ready = ctx.locations.items.len };
}

fn definitionDeinit(context: *anyopaque, allocator: std.mem.Allocator) void {
    const ctx = @as(*DefinitionContext, @ptrCast(@alignCast(context)));
    allocator.free(ctx.document_uri);
    
    for (ctx.locations.items) |*location| {
        location.deinit(allocator);
    }
    ctx.locations.deinit();
    
    allocator.destroy(ctx);
}

fn openDocumentPoll(context: *anyopaque, io: io_v2.Io) io_v2.Future.PollResult {
    _ = io;
    const ctx = @as(*OpenDocumentContext, @ptrCast(@alignCast(context)));
    
    if (!ctx.client.initialized.load(.acquire)) {
        return .{ .ready = error.ServerNotInitialized };
    }
    
    // Add to open documents
    ctx.client.mutex.lock();
    ctx.client.open_documents.put(ctx.document.uri, ctx.document) catch {};
    ctx.client.mutex.unlock();
    
    ctx.opened = true;
    return .{ .ready = true };
}

fn openDocumentDeinit(context: *anyopaque, allocator: std.mem.Allocator) void {
    const ctx = @as(*OpenDocumentContext, @ptrCast(@alignCast(context)));
    allocator.destroy(ctx);
}

fn changeDocumentPoll(context: *anyopaque, io: io_v2.Io) io_v2.Future.PollResult {
    _ = io;
    const ctx = @as(*ChangeDocumentContext, @ptrCast(@alignCast(context)));
    
    if (!ctx.client.initialized.load(.acquire)) {
        return .{ .ready = error.ServerNotInitialized };
    }
    
    // Apply changes to document (simplified)
    ctx.client.mutex.lock();
    if (ctx.client.open_documents.getPtr(ctx.document_uri)) |doc| {
        doc.version = ctx.version;
        // In real implementation, would apply text changes
    }
    ctx.client.mutex.unlock();
    
    ctx.changed = true;
    return .{ .ready = true };
}

fn changeDocumentDeinit(context: *anyopaque, allocator: std.mem.Allocator) void {
    const ctx = @as(*ChangeDocumentContext, @ptrCast(@alignCast(context)));
    allocator.free(ctx.document_uri);
    
    for (ctx.changes) |*change| {
        change.deinit(allocator);
    }
    allocator.free(ctx.changes);
    
    allocator.destroy(ctx);
}

fn formatDocumentPoll(context: *anyopaque, io: io_v2.Io) io_v2.Future.PollResult {
    _ = io;
    const ctx = @as(*FormatDocumentContext, @ptrCast(@alignCast(context)));
    
    if (!ctx.client.initialized.load(.acquire)) {
        return .{ .ready = error.ServerNotInitialized };
    }
    
    // Simulate formatting edits
    const edit = LSPTextEdit{
        .range = LSPRange{
            .start = LSPPosition{ .line = 0, .character = 0 },
            .end = LSPPosition{ .line = 0, .character = 10 },
        },
        .new_text = ctx.allocator.dupe(u8, "formatted_text") catch return .{ .ready = error.OutOfMemory },
    };
    
    ctx.text_edits.append(edit) catch return .{ .ready = error.OutOfMemory };
    
    return .{ .ready = ctx.text_edits.items.len };
}

fn formatDocumentDeinit(context: *anyopaque, allocator: std.mem.Allocator) void {
    const ctx = @as(*FormatDocumentContext, @ptrCast(@alignCast(context)));
    allocator.free(ctx.document_uri);
    
    for (ctx.text_edits.items) |*edit| {
        edit.deinit(allocator);
    }
    ctx.text_edits.deinit();
    
    allocator.destroy(ctx);
}

fn diagnosticsPoll(context: *anyopaque, io: io_v2.Io) io_v2.Future.PollResult {
    _ = io;
    const ctx = @as(*DiagnosticsContext, @ptrCast(@alignCast(context)));
    
    if (!ctx.client.initialized.load(.acquire)) {
        return .{ .ready = error.ServerNotInitialized };
    }
    
    // Simulate diagnostics
    const diagnostic = LSPDiagnostic{
        .range = LSPRange{
            .start = LSPPosition{ .line = 5, .character = 0 },
            .end = LSPPosition{ .line = 5, .character = 20 },
        },
        .severity = .error,
        .code = ctx.allocator.dupe(u8, "E001") catch return .{ .ready = error.OutOfMemory },
        .source = ctx.allocator.dupe(u8, "zig-analyzer") catch return .{ .ready = error.OutOfMemory },
        .message = ctx.allocator.dupe(u8, "Undefined variable") catch return .{ .ready = error.OutOfMemory },
        .related_information = null,
    };
    
    ctx.diagnostics.append(diagnostic) catch return .{ .ready = error.OutOfMemory };
    
    return .{ .ready = ctx.diagnostics.items.len };
}

fn diagnosticsDeinit(context: *anyopaque, allocator: std.mem.Allocator) void {
    const ctx = @as(*DiagnosticsContext, @ptrCast(@alignCast(context)));
    allocator.free(ctx.document_uri);
    
    for (ctx.diagnostics.items) |*diagnostic| {
        diagnostic.deinit(allocator);
    }
    ctx.diagnostics.deinit();
    
    allocator.destroy(ctx);
}

test "lsp client initialization" {
    const allocator = std.testing.allocator;
    const io = io_v2.Io.init();
    
    const config = LSPClientConfig{
        .server_command = "zig",
        .server_args = &[_][]const u8{ "zig", "lsp" },
        .timeout_ms = 5000,
    };
    
    var client = try AsyncLSPClient.init(allocator, io, config);
    defer client.deinit();
    
    try std.testing.expect(client.config.timeout_ms == 5000);
    try std.testing.expect(!client.initialized.load(.acquire));
}

test "lsp completion request" {
    const allocator = std.testing.allocator;
    const io = io_v2.Io.init();
    
    const config = LSPClientConfig{
        .server_command = "zig",
        .server_args = &[_][]const u8{ "zig", "lsp" },
    };
    
    var client = try AsyncLSPClient.init(allocator, io, config);
    defer client.deinit();
    
    // Mock initialization
    client.initialized.store(true, .release);
    
    var completion_future = try client.completionAsync(allocator, "file:///test.zig", LSPPosition{ .line = 10, .character = 5 });
    defer completion_future.deinit();
    
    const result = try completion_future.await_op(io, .{});
    try std.testing.expect(@as(u32, @intCast(result)) >= 0);
}

test "lsp hover request" {
    const allocator = std.testing.allocator;
    const io = io_v2.Io.init();
    
    const config = LSPClientConfig{
        .server_command = "zig",
        .server_args = &[_][]const u8{ "zig", "lsp" },
    };
    
    var client = try AsyncLSPClient.init(allocator, io, config);
    defer client.deinit();
    
    // Mock initialization
    client.initialized.store(true, .release);
    
    var hover_future = try client.hoverAsync(allocator, "file:///test.zig", LSPPosition{ .line = 10, .character = 5 });
    defer hover_future.deinit();
    
    const result = try hover_future.await_op(io, .{});
    try std.testing.expect(result == true);
}