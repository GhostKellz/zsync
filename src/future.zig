//! zsync- Generic Future Type
//! Future for async operations with any result type

const std = @import("std");

/// Generic future for async results
pub fn Future(comptime T: type) type {
    return struct {
        state: std.atomic.Value(State),
        result: ?Result,
        mutex: std.Thread.Mutex,
        condition: std.Thread.Condition,
        allocator: std.mem.Allocator,

        const Self = @This();

        const State = enum(u8) {
            pending,
            ready,
            cancelled,
        };

        const Result = union(enum) {
            ok: T,
            err: anyerror,
        };

        /// Create a new pending future
        pub fn init(allocator: std.mem.Allocator) !*Self {
            const self = try allocator.create(Self);
            self.* = Self{
                .state = std.atomic.Value(State).init(.pending),
                .result = null,
                .mutex = .{},
                .condition = .{},
                .allocator = allocator,
            };
            return self;
        }

        /// Create a future that is already resolved with a value
        pub fn resolved(allocator: std.mem.Allocator, value: T) !*Self {
            const self = try Self.init(allocator);
            self.result = .{ .ok = value };
            self.state.store(.ready, .release);
            return self;
        }

        /// Create a future that is already rejected with an error
        pub fn rejected(allocator: std.mem.Allocator, err: anyerror) !*Self {
            const self = try Self.init(allocator);
            self.result = .{ .err = err };
            self.state.store(.ready, .release);
            return self;
        }

        /// Wait for the future to complete and return the result
        pub fn await(self: *Self) !T {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.state.load(.acquire) == .pending) {
                self.condition.wait(&self.mutex);
            }

            const current_state = self.state.load(.acquire);

            if (current_state == .cancelled) {
                return error.FutureCancelled;
            }

            if (self.result) |result| {
                return switch (result) {
                    .ok => |val| val,
                    .err => |e| e,
                };
            }

            return error.FutureNotResolved;
        }

        /// Non-blocking check if future is ready
        pub fn poll(self: *Self) PollResult {
            return switch (self.state.load(.acquire)) {
                .pending => .pending,
                .ready => .ready,
                .cancelled => .cancelled,
            };
        }

        /// Resolve the future with a value
        pub fn resolve(self: *Self, value: T) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.state.load(.acquire) != .pending) {
                return; // Already resolved or cancelled
            }

            self.result = .{ .ok = value };
            self.state.store(.ready, .release);
            self.condition.broadcast();
        }

        /// Reject the future with an error
        pub fn reject(self: *Self, err: anyerror) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.state.load(.acquire) != .pending) {
                return; // Already resolved or cancelled
            }

            self.result = .{ .err = err };
            self.state.store(.ready, .release);
            self.condition.broadcast();
        }

        /// Cancel the future
        pub fn cancel(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.state.load(.acquire) != .pending) {
                return; // Already resolved or cancelled
            }

            self.state.store(.cancelled, .release);
            self.condition.broadcast();
        }

        /// Clean up the future
        pub fn deinit(self: *Self) void {
            self.allocator.destroy(self);
        }

        pub const PollResult = enum {
            pending,
            ready,
            cancelled,
        };
    };
}

/// Helper to create a future from a function that computes a value
pub fn compute(comptime T: type, allocator: std.mem.Allocator, comptime func: anytype, args: anytype) !*Future(T) {
    const future = try Future(T).init(allocator);

    // For now, execute synchronously
    // TODO: Execute on thread pool in background
    const result = @call(.auto, func, args) catch |err| {
        future.reject(err);
        return future;
    };

    future.resolve(result);
    return future;
}

// Tests
test "future resolve and await" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var future = try Future(i32).init(allocator);
    defer future.deinit();

    try testing.expect(future.poll() == .pending);

    future.resolve(42);

    try testing.expect(future.poll() == .ready);

    const result = try future.await();
    try testing.expectEqual(42, result);
}

test "future reject and await" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var future = try Future(i32).init(allocator);
    defer future.deinit();

    future.reject(error.TestError);

    try testing.expectError(error.TestError, future.await());
}

test "future cancel" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var future = try Future(i32).init(allocator);
    defer future.deinit();

    future.cancel();

    try testing.expect(future.poll() == .cancelled);
    try testing.expectError(error.FutureCancelled, future.await());
}

test "future already resolved" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var future = try Future(i32).resolved(allocator, 100);
    defer future.deinit();

    try testing.expect(future.poll() == .ready);

    const result = try future.await();
    try testing.expectEqual(100, result);
}
