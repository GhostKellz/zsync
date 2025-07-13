const std = @import("std");
const builtin = @import("builtin");

// JavaScript FFI Bridge for WASM
// Provides interface between Zig async runtime and browser APIs

/// JavaScript external function declarations
extern "env" fn js_setTimeout(callback_id: u32, delay_ms: u32) void;
extern "env" fn js_clearTimeout(timer_id: u32) void;
extern "env" fn js_fetch(url_ptr: [*]const u8, url_len: usize, callback_id: u32) void;
extern "env" fn js_websocket_connect(url_ptr: [*]const u8, url_len: usize, callback_id: u32) u32;
extern "env" fn js_websocket_send(ws_id: u32, data_ptr: [*]const u8, data_len: usize) void;
extern "env" fn js_websocket_close(ws_id: u32) void;
extern "env" fn js_file_read(file_id: u32, callback_id: u32) void;
extern "env" fn js_file_write(data_ptr: [*]const u8, data_len: usize, callback_id: u32) void;
extern "env" fn js_console_log(msg_ptr: [*]const u8, msg_len: usize) void;

/// Export callback handlers for JavaScript to call back into WASM
export fn wasm_timer_callback(callback_id: u32) void {
    TimerManager.handleCallback(callback_id);
}

export fn wasm_fetch_callback(callback_id: u32, status: u32, data_ptr: [*]const u8, data_len: usize) void {
    HttpManager.handleCallback(callback_id, status, data_ptr[0..data_len]);
}

export fn wasm_websocket_callback(callback_id: u32, event_type: u32, data_ptr: [*]const u8, data_len: usize) void {
    WebSocketManager.handleCallback(callback_id, event_type, data_ptr[0..data_len]);
}

export fn wasm_file_callback(callback_id: u32, success: u32, data_ptr: [*]const u8, data_len: usize) void {
    FileManager.handleCallback(callback_id, success != 0, data_ptr[0..data_len]);
}

/// Timer management for async delays and timeouts
pub const TimerManager = struct {
    const CallbackMap = std.HashMap(u32, TimerCallback, std.hash_map.DefaultContext(u32), std.heap.page_allocator);
    
    const TimerCallback = struct {
        completion: *std.atomic.Value(bool),
        result: *?TimerError,
    };
    
    const TimerError = error{
        TimerFailed,
    };
    
    var callbacks: CallbackMap = CallbackMap.init(std.heap.page_allocator);
    var next_callback_id: std.atomic.Value(u32) = std.atomic.Value(u32).init(1);
    
    pub fn setTimeout(delay_ms: u32) !void {
        const callback_id = next_callback_id.fetchAdd(1, .Monotonic);
        
        var completion = std.atomic.Value(bool).init(false);
        var result: ?TimerError = null;
        
        try callbacks.put(callback_id, TimerCallback{
            .completion = &completion,
            .result = &result,
        });
        
        js_setTimeout(callback_id, delay_ms);
        
        // Busy wait for completion (could be improved with event loop integration)
        while (!completion.load(.Acquire)) {
            // Yield to browser event loop
            if (comptime builtin.target.cpu.arch.isWasm()) {
                std.atomic.spinLoopHint();
            }
        }
        
        _ = callbacks.remove(callback_id);
        
        if (result) |err| {
            return err;
        }
    }
    
    pub fn handleCallback(callback_id: u32) void {
        if (callbacks.get(callback_id)) |callback| {
            callback.completion.store(true, .Release);
        }
    }
};

/// HTTP client using browser fetch API
pub const HttpManager = struct {
    const CallbackMap = std.HashMap(u32, HttpCallback, std.hash_map.DefaultContext(u32), std.heap.page_allocator);
    
    const HttpCallback = struct {
        completion: *std.atomic.Value(bool),
        result: *HttpResult,
        allocator: std.mem.Allocator,
    };
    
    const HttpResult = struct {
        status: u32,
        body: []u8,
        err: ?HttpError,
        
        pub fn deinit(self: *HttpResult, allocator: std.mem.Allocator) void {
            if (self.body.len > 0) {
                allocator.free(self.body);
            }
        }
    };
    
    const HttpError = error{
        NetworkError,
        InvalidUrl,
        RequestFailed,
    };
    
    var callbacks: CallbackMap = CallbackMap.init(std.heap.page_allocator);
    var next_callback_id: std.atomic.Value(u32) = std.atomic.Value(u32).init(1);
    
    pub fn fetch(allocator: std.mem.Allocator, url: []const u8) !HttpResult {
        const callback_id = next_callback_id.fetchAdd(1, .Monotonic);
        
        var completion = std.atomic.Value(bool).init(false);
        var result = HttpResult{
            .status = 0,
            .body = &[_]u8{},
            .err = null,
        };
        
        try callbacks.put(callback_id, HttpCallback{
            .completion = &completion,
            .result = &result,
            .allocator = allocator,
        });
        
        js_fetch(url.ptr, url.len, callback_id);
        
        // Wait for completion
        while (!completion.load(.Acquire)) {
            if (comptime builtin.target.cpu.arch.isWasm()) {
                std.atomic.spinLoopHint();
            }
        }
        
        _ = callbacks.remove(callback_id);
        
        if (result.err) |err| {
            return err;
        }
        
        return result;
    }
    
    pub fn handleCallback(callback_id: u32, status: u32, data: []const u8) void {
        if (callbacks.get(callback_id)) |callback| {
            callback.result.status = status;
            
            if (data.len > 0) {
                callback.result.body = callback.allocator.dupe(u8, data) catch {
                    callback.result.err = HttpError.RequestFailed;
                    callback.completion.store(true, .Release);
                    return;
                };
            }
            
            if (status >= 400) {
                callback.result.err = HttpError.RequestFailed;
            }
            
            callback.completion.store(true, .Release);
        }
    }
};

/// WebSocket implementation using browser WebSocket API
pub const WebSocketManager = struct {
    const CallbackMap = std.HashMap(u32, *WebSocket, std.hash_map.DefaultContext(u32), std.heap.page_allocator);
    
    pub const WebSocket = struct {
        id: u32,
        url: []const u8,
        state: std.atomic.Value(State),
        message_queue: std.fifo.LinearFifo([]u8, .Dynamic),
        allocator: std.mem.Allocator,
        
        const State = enum {
            connecting,
            open,
            closed,
            err,
        };
        
        pub fn init(allocator: std.mem.Allocator, url: []const u8) !*WebSocket {
            const ws = try allocator.create(WebSocket);
            ws.* = WebSocket{
                .id = 0,
                .url = try allocator.dupe(u8, url),
                .state = std.atomic.Value(State).init(.connecting),
                .message_queue = std.fifo.LinearFifo([]u8, .Dynamic).init(allocator),
                .allocator = allocator,
            };
            
            const callback_id = next_callback_id.fetchAdd(1, .Monotonic);
            ws.id = js_websocket_connect(url.ptr, url.len, callback_id);
            
            try callbacks.put(callback_id, ws);
            
            return ws;
        }
        
        pub fn deinit(self: *WebSocket) void {
            self.allocator.free(self.url);
            
            // Clear message queue
            while (self.message_queue.readItem()) |msg| {
                self.allocator.free(msg);
            }
            self.message_queue.deinit();
            
            js_websocket_close(self.id);
            self.allocator.destroy(self);
        }
        
        pub fn send(self: *WebSocket, data: []const u8) void {
            if (self.state.load(.Acquire) == .open) {
                js_websocket_send(self.id, data.ptr, data.len);
            }
        }
        
        pub fn receive(self: *WebSocket) ?[]u8 {
            return self.message_queue.readItem();
        }
        
        pub fn waitForOpen(self: *WebSocket) !void {
            while (self.state.load(.Acquire) == .connecting) {
                if (comptime builtin.target.cpu.arch.isWasm()) {
                    std.atomic.spinLoopHint();
                }
            }
            
            switch (self.state.load(.Acquire)) {
                .open => {},
                .err => return error.ConnectionFailed,
                .closed => return error.ConnectionClosed,
                else => return error.UnexpectedState,
            }
        }
    };
    
    var callbacks: CallbackMap = CallbackMap.init(std.heap.page_allocator);
    var next_callback_id: std.atomic.Value(u32) = std.atomic.Value(u32).init(1);
    
    pub fn handleCallback(callback_id: u32, event_type: u32, data: []const u8) void {
        if (callbacks.get(callback_id)) |ws| {
            switch (event_type) {
                0 => { // onopen
                    ws.state.store(.open, .Release);
                },
                1 => { // onmessage
                    const msg = ws.allocator.dupe(u8, data) catch return;
                    ws.message_queue.writeItem(msg) catch {
                        ws.allocator.free(msg);
                    };
                },
                2 => { // onclose
                    ws.state.store(.closed, .Release);
                },
                3 => { // onerror
                    ws.state.store(.err, .Release);
                },
                else => {},
            }
        }
    }
};

/// File operations using browser File API
pub const FileManager = struct {
    const CallbackMap = std.HashMap(u32, FileCallback, std.hash_map.DefaultContext(u32), std.heap.page_allocator);
    
    const FileCallback = struct {
        completion: *std.atomic.Value(bool),
        result: *FileResult,
        allocator: std.mem.Allocator,
    };
    
    const FileResult = struct {
        success: bool,
        data: []u8,
        err: ?FileError,
        
        pub fn deinit(self: *FileResult, allocator: std.mem.Allocator) void {
            if (self.data.len > 0) {
                allocator.free(self.data);
            }
        }
    };
    
    const FileError = error{
        FileNotFound,
        PermissionDenied,
        ReadFailed,
        WriteFailed,
    };
    
    var callbacks: CallbackMap = CallbackMap.init(std.heap.page_allocator);
    var next_callback_id: std.atomic.Value(u32) = std.atomic.Value(u32).init(1);
    
    pub fn readFile(allocator: std.mem.Allocator, file_id: u32) !FileResult {
        const callback_id = next_callback_id.fetchAdd(1, .Monotonic);
        
        var completion = std.atomic.Value(bool).init(false);
        var result = FileResult{
            .success = false,
            .data = &[_]u8{},
            .err = null,
        };
        
        try callbacks.put(callback_id, FileCallback{
            .completion = &completion,
            .result = &result,
            .allocator = allocator,
        });
        
        js_file_read(file_id, callback_id);
        
        // Wait for completion
        while (!completion.load(.Acquire)) {
            if (comptime builtin.target.cpu.arch.isWasm()) {
                std.atomic.spinLoopHint();
            }
        }
        
        _ = callbacks.remove(callback_id);
        
        if (result.err) |err| {
            return err;
        }
        
        return result;
    }
    
    pub fn writeFile(allocator: std.mem.Allocator, data: []const u8) !void {
        const callback_id = next_callback_id.fetchAdd(1, .Monotonic);
        
        var completion = std.atomic.Value(bool).init(false);
        var result = FileResult{
            .success = false,
            .data = &[_]u8{},
            .err = null,
        };
        
        try callbacks.put(callback_id, FileCallback{
            .completion = &completion,
            .result = &result,
            .allocator = allocator,
        });
        
        js_file_write(data.ptr, data.len, callback_id);
        
        // Wait for completion
        while (!completion.load(.Acquire)) {
            if (comptime builtin.target.cpu.arch.isWasm()) {
                std.atomic.spinLoopHint();
            }
        }
        
        _ = callbacks.remove(callback_id);
        
        if (result.err) |err| {
            return err;
        }
    }
    
    pub fn handleCallback(callback_id: u32, success: bool, data: []const u8) void {
        if (callbacks.get(callback_id)) |callback| {
            callback.result.success = success;
            
            if (success and data.len > 0) {
                callback.result.data = callback.allocator.dupe(u8, data) catch {
                    callback.result.err = FileError.ReadFailed;
                    callback.completion.store(true, .Release);
                    return;
                };
            }
            
            if (!success) {
                callback.result.err = FileError.ReadFailed;
            }
            
            callback.completion.store(true, .Release);
        }
    }
};

/// Console logging for debugging
pub fn consoleLog(msg: []const u8) void {
    if (comptime builtin.target.cpu.arch.isWasm()) {
        js_console_log(msg.ptr, msg.len);
    } else {
        std.debug.print("{s}\n", .{msg});
    }
}

/// Browser event loop integration
pub fn yieldToBrowser() void {
    if (comptime builtin.target.cpu.arch.isWasm()) {
        // Use setTimeout(0) to yield to browser event loop
        TimerManager.setTimeout(0) catch {};
    }
}

/// WASM Event Loop implementation
pub const EventLoop = struct {
    running: std.atomic.Value(bool),
    
    pub fn init() EventLoop {
        return EventLoop{
            .running = std.atomic.Value(bool).init(false),
        };
    }
    
    pub fn run(self: *EventLoop) !void {
        self.running.store(true, .Release);
        
        // WASM event loop runs forever, controlled by browser
        while (self.running.load(.Acquire)) {
            // Yield to browser event loop
            yieldToBrowser();
        }
    }
    
    pub fn stop(self: *EventLoop) void {
        self.running.store(false, .Release);
    }
};

/// WASM Event Source (placeholder)
pub const EventSource = struct {
    fd: i32,
    
    pub fn init(fd: i32) EventSource {
        return EventSource{ .fd = fd };
    }
};

/// WASM Timer implementation
pub const Timer = struct {
    delay_ms: u32,
    active: std.atomic.Value(bool),
    
    pub fn init(delay_ms: u32) Timer {
        return Timer{
            .delay_ms = delay_ms,
            .active = std.atomic.Value(bool).init(false),
        };
    }
    
    pub fn start(self: *Timer) !void {
        self.active.store(true, .Release);
        try TimerManager.setTimeout(self.delay_ms);
        self.active.store(false, .Release);
    }
    
    pub fn stop(self: *Timer) void {
        self.active.store(false, .Release);
    }
    
    pub fn isActive(self: *Timer) bool {
        return self.active.load(.Acquire);
    }
};

/// Platform-specific functions required by main platform.zig
pub fn getNumCpus() u32 {
    // WASM is single-threaded
    return 1;
}

pub fn setThreadAffinity(cpu: u32) !void {
    // No-op for WASM
    _ = cpu;
}

pub inline fn memoryBarrier() void {
    // Memory barrier for WASM
    std.atomic.fence(.seq_cst);
}

pub inline fn loadAcquire(comptime T: type, ptr: *const T) T {
    return @atomicLoad(T, ptr, .acquire);
}

pub inline fn storeRelease(comptime T: type, ptr: *T, value: T) void {
    @atomicStore(T, ptr, value, .release);
}