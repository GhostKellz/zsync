//! zsync- Generic Future Type
//! Future for async operations with any result type

const std = @import("std");
const compat = @import("compat/thread.zig");

/// Generic future for async results
pub fn Future(comptime T: type) type {
    return struct {
        state: std.atomic.Value(State),
        result: ?Result,
        mutex: compat.Mutex,
        condition: compat.Condition,
        allocator: std.mem.Allocator,
        /// Background worker that resolves this future, when created via `compute`.
        /// Joined on `deinit` so the worker can never outlive the future.
        worker: ?std.Thread = null,

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
                .worker = null,
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

        /// Clean up the future. If a background `compute` worker is still
        /// running, wait for it to finish first so it can never write into
        /// freed memory.
        pub fn deinit(self: *Self) void {
            if (self.worker) |thread| {
                thread.join();
                self.worker = null;
            }
            self.allocator.destroy(self);
        }

        pub const PollResult = enum {
            pending,
            ready,
            cancelled,
        };
    };
}

/// Helper to create a future whose value is produced by `func` running on a
/// background worker thread. The future is returned immediately in the pending
/// state; the caller observes completion via `await`/`poll`. `func` must return
/// an error union (`!T`); a returned error rejects the future.
///
/// The worker is owned by the future and joined in `deinit`, so the spawned
/// thread can never outlive the future it writes into. If the OS cannot spawn a
/// thread, the computation falls back to running synchronously.
pub fn compute(comptime T: type, allocator: std.mem.Allocator, comptime func: anytype, args: anytype) !*Future(T) {
    const future = try Future(T).init(allocator);
    errdefer future.deinit();

    const Args = @TypeOf(args);
    const Context = struct {
        future: *Future(T),
        args: Args,
        allocator: std.mem.Allocator,

        fn run(ctx: *@This()) void {
            const fut = ctx.future;
            const call_args = ctx.args;
            const a = ctx.allocator;
            a.destroy(ctx);

            const result = @call(.auto, func, call_args) catch |err| {
                fut.reject(err);
                return;
            };
            fut.resolve(result);
        }
    };

    const ctx = try allocator.create(Context);
    ctx.* = .{ .future = future, .args = args, .allocator = allocator };

    future.worker = std.Thread.spawn(.{}, Context.run, .{ctx}) catch {
        // No threads available: run synchronously and clean up the context.
        allocator.destroy(ctx);
        const result = @call(.auto, func, args) catch |err| {
            future.reject(err);
            return future;
        };
        future.resolve(result);
        return future;
    };

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

test "future compute runs in background and resolves" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const Work = struct {
        fn square(n: i32) !i32 {
            return n * n;
        }
    };

    const future = try compute(i32, allocator, Work.square, .{@as(i32, 9)});
    defer future.deinit();

    try testing.expectEqual(@as(i32, 81), try future.await());
}

test "future compute propagates errors" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const Work = struct {
        fn boom(_: i32) !i32 {
            return error.Boom;
        }
    };

    const future = try compute(i32, allocator, Work.boom, .{@as(i32, 1)});
    defer future.deinit();

    try testing.expectError(error.Boom, future.await());
}
