//! zsync WASM Async Helpers
//! Bridge between Zig async/await and JavaScript Promises

const std = @import("std");
const builtin = @import("builtin");
const compat = @import("../compat/thread.zig");
const microtask_mod = @import("microtask.zig");

const is_wasm = builtin.target.cpu.arch == .wasm32;

/// JavaScript host bindings. These are imported from the embedding JS runtime
/// when zsync is compiled to WebAssembly. The host is expected to provide an
/// `env` import object implementing this synchronous protocol.
///
/// They are only referenced on wasm32 targets; on every other target the calls
/// are excluded at comptime so the symbols are never emitted or linked.
const js = struct {
    /// Block the current turn for `ms` milliseconds. A browser host typically
    /// implements this on top of `Atomics.wait` against a shared timer.
    extern "env" fn zsync_sleep_ms(ms: u64) void;

    /// Perform a synchronous HTTP request. The host stores the response and
    /// returns a non-negative handle, writing the status code and body length
    /// through the out pointers. A negative return signals a transport error.
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

    /// Copy `len` bytes of the response body for `handle` into `dest`.
    extern "env" fn zsync_fetch_read(handle: i32, dest: [*]u8, len: usize) void;

    /// Release host-side resources associated with `handle`.
    extern "env" fn zsync_fetch_free(handle: i32) void;
};

/// Promise state
pub const PromiseState = enum(u8) {
    pending,
    fulfilled,
    rejected,
};

/// Promise-like Future for WASM
pub fn Promise(comptime T: type) type {
    return struct {
        allocator: std.mem.Allocator,
        state: std.atomic.Value(PromiseState),
        result: ?T,
        error_value: ?anyerror,
        mutex: compat.Mutex,
        condition: compat.Condition,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{
                .allocator = allocator,
                .state = std.atomic.Value(PromiseState).init(.pending),
                .result = null,
                .error_value = null,
                .mutex = .{},
                .condition = .{},
            };
        }

        /// Resolve the promise with a value
        pub fn resolve(self: *Self, value: T) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.state.load(.acquire) != .pending) return;

            self.result = value;
            self.state.store(.fulfilled, .release);
            self.condition.broadcast();
        }

        /// Reject the promise with an error
        pub fn reject(self: *Self, err: anyerror) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.state.load(.acquire) != .pending) return;

            self.error_value = err;
            self.state.store(.rejected, .release);
            self.condition.broadcast();
        }

        /// Wait for the promise to settle
        pub fn await_(self: *Self) !T {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.state.load(.acquire) == .pending) {
                self.condition.wait(&self.mutex);
            }

            return switch (self.state.load(.acquire)) {
                .fulfilled => self.result.?,
                .rejected => self.error_value.?,
                .pending => unreachable,
            };
        }

        /// Chain with another promise (then)
        pub fn then(
            self: *Self,
            comptime R: type,
            callback: *const fn (T) anyerror!R,
        ) !Promise(R) {
            const value = try self.await_();
            const next_value = try callback(value);

            var next_promise = Promise(R).init(self.allocator);
            next_promise.resolve(next_value);
            return next_promise;
        }

        /// Catch errors
        pub fn catch_(
            self: *Self,
            callback: *const fn (anyerror) anyerror!T,
        ) !T {
            return self.await_() catch |err| {
                return try callback(err);
            };
        }

        /// Get promise state
        pub fn getState(self: *const Self) PromiseState {
            return self.state.load(.acquire);
        }

        /// Check if promise is settled
        pub fn isSettled(self: *const Self) bool {
            return self.getState() != .pending;
        }
    };
}

/// Defer execution of `func(args)` to the next microtask drain.
///
/// The captured arguments are heap-allocated with `allocator` and freed after
/// the deferred call runs. Requires the global microtask queue to be
/// initialized (`microtask.initGlobalQueue`); otherwise the call is rejected
/// with `error.QueueNotInitialized`.
pub fn defer_(allocator: std.mem.Allocator, comptime func: anytype, args: anytype) !void {
    const Args = @TypeOf(args);

    const Trampoline = struct {
        allocator: std.mem.Allocator,
        args: Args,

        fn run(ptr: *anyopaque) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            defer self.allocator.destroy(self);

            const Ret = @TypeOf(@call(.auto, func, @as(Args, undefined)));
            if (comptime @typeInfo(Ret) == .error_union) {
                try @call(.auto, func, self.args);
            } else {
                _ = @call(.auto, func, self.args);
            }
        }
    };

    const ctx = try allocator.create(Trampoline);
    errdefer allocator.destroy(ctx);
    ctx.* = .{ .allocator = allocator, .args = args };

    try microtask_mod.queueMicrotask(Trampoline.run, @ptrCast(ctx));
}

/// Async/await helper for WASM
pub const AsyncContext = struct {
    allocator: std.mem.Allocator,
    queue: *microtask_mod.MicrotaskQueue,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        const queue = try allocator.create(microtask_mod.MicrotaskQueue);
        queue.* = microtask_mod.MicrotaskQueue.init(allocator);

        return Self{
            .allocator = allocator,
            .queue = queue,
        };
    }

    pub fn deinit(self: *Self) void {
        self.queue.deinit();
        self.allocator.destroy(self.queue);
    }

    /// Yield to event loop
    pub fn yield_(self: *Self) !void {
        try self.queue.flush();
    }

    /// Suspend the current turn for `ms` milliseconds.
    ///
    /// On wasm32 this delegates to the host's `zsync_sleep_ms` binding so the
    /// embedding JS runtime controls timing; on every other target it performs a
    /// real monotonic sleep via the compat layer.
    pub fn sleep(self: *Self, ms: u64) !void {
        // Drain any queued microtasks before yielding the turn.
        try self.queue.flush();

        if (comptime is_wasm) {
            js.zsync_sleep_ms(ms);
        } else {
            compat.sleepMillis(ms);
        }
    }
};

/// Fetch-like HTTP request for WASM
pub const FetchOptions = struct {
    method: []const u8 = "GET",
    headers: ?std.StringHashMap([]const u8) = null,
    body: ?[]const u8 = null,
};

pub const FetchResponse = struct {
    status: u16,
    headers: std.StringHashMap([]const u8),
    body: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *FetchResponse) void {
        var it = self.headers.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.headers.deinit();
        self.allocator.free(self.body);
    }

    /// Parse the response body as JSON into `T`.
    ///
    /// Parsing is leaky: any allocations (e.g. for slices/strings inside `T`)
    /// are made with the response's allocator and live until it is freed. Pass a
    /// response backed by an arena allocator when individual cleanup matters.
    pub fn json(self: *FetchResponse, comptime T: type) !T {
        return std.json.parseFromSliceLeaky(T, self.allocator, self.body, .{
            .ignore_unknown_fields = true,
        });
    }

    pub fn text(self: *const FetchResponse) []const u8 {
        return self.body;
    }
};

/// Perform an HTTP request through the JavaScript host and return a Promise that
/// settles with the response.
///
/// On wasm32 this drives the synchronous `zsync_fetch` host protocol: the host
/// runs the request, hands back a status, a body length, and a handle that is
/// used to copy the body into wasm linear memory. On non-wasm targets there is
/// no JS host, so the returned promise rejects with `error.FetchUnsupportedHost`
/// rather than fabricating a response.
pub fn fetch(
    allocator: std.mem.Allocator,
    url: []const u8,
    options: FetchOptions,
) !Promise(FetchResponse) {
    var promise = Promise(FetchResponse).init(allocator);

    if (comptime !is_wasm) {
        promise.reject(error.FetchUnsupportedHost);
        return promise;
    }

    const body: []const u8 = options.body orelse "";

    var status: u16 = 0;
    var body_len: usize = 0;
    const handle = js.zsync_fetch(
        options.method.ptr,
        options.method.len,
        url.ptr,
        url.len,
        body.ptr,
        body.len,
        &status,
        &body_len,
    );

    if (handle < 0) {
        promise.reject(error.FetchFailed);
        return promise;
    }
    defer js.zsync_fetch_free(handle);

    const body_buf = try allocator.alloc(u8, body_len);
    errdefer allocator.free(body_buf);
    if (body_len != 0) {
        js.zsync_fetch_read(handle, body_buf.ptr, body_len);
    }

    promise.resolve(.{
        .status = status,
        .headers = std.StringHashMap([]const u8).init(allocator),
        .body = body_buf,
        .allocator = allocator,
    });
    return promise;
}

/// Event emitter for WASM DOM events
pub fn EventEmitter(comptime T: type) type {
    return struct {
        allocator: std.mem.Allocator,
        listeners: std.ArrayList(*const fn (T) anyerror!void),
        mutex: compat.Mutex,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{
                .allocator = allocator,
                .listeners = .empty,
                .mutex = .{},
            };
        }

        pub fn deinit(self: *Self) void {
            self.listeners.deinit(self.allocator);
        }

        /// Add event listener
        pub fn on(self: *Self, listener: *const fn (T) anyerror!void) !void {
            self.mutex.lock();
            defer self.mutex.unlock();
            try self.listeners.append(self.allocator, listener);
        }

        /// Remove event listener
        pub fn off(self: *Self, listener: *const fn (T) anyerror!void) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            for (self.listeners.items, 0..) |l, i| {
                if (l == listener) {
                    _ = self.listeners.orderedRemove(i);
                    return;
                }
            }
        }

        /// Emit event to all listeners
        pub fn emit(self: *Self, event: T) void {
            self.mutex.lock();
            const listeners = self.allocator.dupe(*const fn (T) anyerror!void, self.listeners.items) catch return;
            self.mutex.unlock();
            defer self.allocator.free(listeners);

            for (listeners) |listener| {
                listener(event) catch |err| {
                    std.debug.print("[EventEmitter] Error: {}\n", .{err});
                };
            }
        }

        /// Get listener count
        pub fn listenerCount(self: *Self) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.listeners.items.len;
        }
    };
}

/// AbortController for canceling async operations
pub const AbortController = struct {
    aborted: std.atomic.Value(bool),
    reason: ?anyerror,
    mutex: compat.Mutex,

    const Self = @This();

    pub fn init() Self {
        return Self{
            .aborted = std.atomic.Value(bool).init(false),
            .reason = null,
            .mutex = .{},
        };
    }

    /// Abort the operation
    pub fn abort(self: *Self, reason: anyerror) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (!self.aborted.load(.acquire)) {
            self.reason = reason;
            self.aborted.store(true, .release);
        }
    }

    /// Check if aborted
    pub fn isAborted(self: *const Self) bool {
        return self.aborted.load(.acquire);
    }

    /// Get abort reason
    pub fn getReason(self: *Self) ?anyerror {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.reason;
    }

    /// Throw if aborted
    pub fn throwIfAborted(self: *Self) !void {
        if (self.isAborted()) {
            if (self.getReason()) |reason| {
                return reason;
            }
            return error.Aborted;
        }
    }
};

// Tests
test "promise resolve" {
    const testing = std.testing;

    var promise = Promise(u32).init(testing.allocator);
    promise.resolve(42);

    const value = try promise.await_();
    try testing.expectEqual(42, value);
}

test "promise reject" {
    const testing = std.testing;

    var promise = Promise(u32).init(testing.allocator);
    promise.reject(error.TestError);

    const result = promise.await_();
    try testing.expectError(error.TestError, result);
}

test "event emitter" {
    const testing = std.testing;

    var emitter = EventEmitter(u32).init(testing.allocator);
    defer emitter.deinit();

    const Context = struct {
        var received: u32 = 0;

        fn handler(value: u32) !void {
            received = value;
        }
    };

    try emitter.on(Context.handler);
    try testing.expectEqual(1, emitter.listenerCount());

    emitter.emit(42);
    try testing.expectEqual(42, Context.received);
}

test "abort controller" {
    const testing = std.testing;

    var controller = AbortController.init();
    try testing.expect(!controller.isAborted());

    controller.abort(error.Cancelled);
    try testing.expect(controller.isAborted());
    try testing.expectError(error.Cancelled, controller.throwIfAborted());
}

test "defer_ runs on microtask drain" {
    const testing = std.testing;

    try microtask_mod.initGlobalQueue(testing.allocator);
    defer microtask_mod.deinitGlobalQueue(testing.allocator);

    const Context = struct {
        var sum: u32 = 0;
        fn add(a: u32, b: u32) void {
            sum = a + b;
        }
    };
    Context.sum = 0;

    try defer_(testing.allocator, Context.add, .{ @as(u32, 40), @as(u32, 2) });
    // Not executed until the queue is drained.
    try testing.expectEqual(@as(u32, 0), Context.sum);

    try microtask_mod.flushMicrotasks();
    try testing.expectEqual(@as(u32, 42), Context.sum);
}

test "fetch response json" {
    const testing = std.testing;

    const Payload = struct {
        id: u32,
        name: []const u8,
    };

    var response = FetchResponse{
        .status = 200,
        .headers = std.StringHashMap([]const u8).init(testing.allocator),
        .body = try testing.allocator.dupe(u8, "{\"id\":7,\"name\":\"zsync\"}"),
        .allocator = testing.allocator,
    };
    defer response.deinit();

    const parsed = try response.json(Payload);
    try testing.expectEqual(@as(u32, 7), parsed.id);
    try testing.expectEqualStrings("zsync", parsed.name);
}

test "fetch rejects without a js host" {
    const testing = std.testing;
    if (is_wasm) return error.SkipZigTest;

    var promise = try fetch(testing.allocator, "https://example.com", .{});
    try testing.expectError(error.FetchUnsupportedHost, promise.await_());
}
