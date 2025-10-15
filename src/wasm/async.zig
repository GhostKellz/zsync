//! Zsync v0.6.0 - WASM Async Helpers
//! Bridge between Zig async/await and JavaScript Promises

const std = @import("std");
const builtin = @import("builtin");
const microtask_mod = @import("microtask.zig");

/// Promise state
pub const PromiseState = enum {
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
        mutex: std.Thread.Mutex,
        condition: std.Thread.Condition,

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

/// Defer execution to next microtask
pub fn defer_(allocator: std.mem.Allocator, comptime func: anytype, args: anytype) !void {
    _ = allocator;
    _ = args;

    // TODO: Queue microtask
    _ = func;
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

    /// Sleep for milliseconds (async)
    pub fn sleep(self: *Self, ms: u64) !void {
        _ = self;
        // In WASM, this would integrate with setTimeout
        std.Thread.sleep(ms * std.time.ns_per_ms);
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

    pub fn json(self: *FetchResponse, comptime T: type) !T {
        _ = self;
        // TODO: Parse JSON using std.json
        return @as(T, undefined);
    }

    pub fn text(self: *const FetchResponse) []const u8 {
        return self.body;
    }
};

/// Fetch API for WASM (calls into JavaScript)
pub fn fetch(
    allocator: std.mem.Allocator,
    url: []const u8,
    options: FetchOptions,
) !Promise(FetchResponse) {
    _ = url;
    _ = options;

    // In WASM environment, this would call JavaScript fetch() API
    var promise = Promise(FetchResponse).init(allocator);

    // For now, return a mock response
    const response = FetchResponse{
        .status = 200,
        .headers = std.StringHashMap([]const u8).init(allocator),
        .body = try allocator.dupe(u8, "Mock response"),
        .allocator = allocator,
    };

    promise.resolve(response);
    return promise;
}

/// Event emitter for WASM DOM events
pub fn EventEmitter(comptime T: type) type {
    return struct {
        allocator: std.mem.Allocator,
        listeners: std.ArrayList(*const fn (T) anyerror!void),
        mutex: std.Thread.Mutex,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{
                .allocator = allocator,
                .listeners = std.ArrayList(*const fn (T) anyerror!void){ .allocator = allocator },
                .mutex = .{},
            };
        }

        pub fn deinit(self: *Self) void {
            self.listeners.deinit();
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
    mutex: std.Thread.Mutex,

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
