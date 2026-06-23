//! zsync- Select Combinator
//! Race multiple futures and return the first to complete

const std = @import("std");
const compat = @import("compat/thread.zig");
const future_mod = @import("future.zig");

fn cancelAllExcept(comptime T: type, futures: []*future_mod.Future(T), winner: ?*future_mod.Future(T)) void {
    for (futures) |fut| {
        if (winner == null or fut != winner.?) fut.cancel();
    }
}

fn pollReady(comptime T: type, futures: []*future_mod.Future(T)) !?T {
    for (futures) |fut| {
        const poll_result = fut.poll();
        if (poll_result == .ready) {
            const result = try fut.await();
            cancelAllExcept(T, futures, fut);
            return result;
        }
    }
    return null;
}

/// Race multiple futures of the same type and return the first to complete
pub fn select(comptime T: type, allocator: std.mem.Allocator, futures: []*future_mod.Future(T)) !T {
    _ = allocator; // Reserved for future use

    if (futures.len == 0) {
        return error.NoFutures;
    }

    while (true) {
        if (try pollReady(T, futures)) |result| return result;
        compat.sleepNanos(1 * std.time.ns_per_ms);
    }
}

/// Race multiple futures until one completes or a cancellation token is cancelled.
/// `token` may be any pointer-like value with an `isCancelled() bool` method.
pub fn selectCancellable(
    comptime T: type,
    allocator: std.mem.Allocator,
    futures: []*future_mod.Future(T),
    token: anytype,
) !?T {
    _ = allocator;

    if (futures.len == 0) {
        return error.NoFutures;
    }

    while (true) {
        if (token.isCancelled()) {
            cancelAllExcept(T, futures, null);
            return error.Cancelled;
        }
        if (try pollReady(T, futures)) |result| return result;
        compat.sleepNanos(1 * std.time.ns_per_ms);
    }
}

/// Select with a timeout - returns the first future to complete or times out
pub fn selectTimeout(
    comptime T: type,
    allocator: std.mem.Allocator,
    futures: []*future_mod.Future(T),
    timeout_ms: u64,
) !?T {
    _ = allocator;

    if (futures.len == 0) {
        return error.NoFutures;
    }

    // Use cross-platform compat.Instant for timing
    const start = compat.Instant.now() catch return error.ClockUnavailable;
    const timeout_ns: u64 = timeout_ms * std.time.ns_per_ms;

    while (true) {
        const now = compat.Instant.now() catch return error.ClockUnavailable;
        if (now.since(start) >= timeout_ns) break;

        if (try pollReady(T, futures)) |result| return result;

        compat.sleepNanos(1 * std.time.ns_per_ms);
    }

    cancelAllExcept(T, futures, null);

    return null;
}

/// Wait for all futures to complete and return an array of results
pub fn all(
    comptime T: type,
    allocator: std.mem.Allocator,
    futures: []*future_mod.Future(T),
) ![]T {
    if (futures.len == 0) {
        return &[_]T{};
    }

    var results = try allocator.alloc(T, futures.len);
    errdefer allocator.free(results);

    for (futures, 0..) |fut, i| {
        results[i] = try fut.await();
    }

    return results;
}

/// Wait for any future to complete and return its result
pub fn any(
    comptime T: type,
    allocator: std.mem.Allocator,
    futures: []*future_mod.Future(T),
) !T {
    return select(T, allocator, futures);
}

// Tests
test "select first completed" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var f1 = try future_mod.Future(i32).init(allocator);
    defer f1.deinit();

    var f2 = try future_mod.Future(i32).init(allocator);
    defer f2.deinit();

    var f3 = try future_mod.Future(i32).init(allocator);
    defer f3.deinit();

    // Resolve second future immediately
    f2.resolve(42);

    var futures = [_]*future_mod.Future(i32){ f1, f2, f3 };

    const result = try select(i32, allocator, &futures);
    try testing.expectEqual(42, result);

    // Others should be cancelled
    try testing.expect(f1.poll() == .cancelled);
    try testing.expect(f3.poll() == .cancelled);
}

test "all futures" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var f1 = try future_mod.Future(i32).resolved(allocator, 10);
    defer f1.deinit();

    var f2 = try future_mod.Future(i32).resolved(allocator, 20);
    defer f2.deinit();

    var f3 = try future_mod.Future(i32).resolved(allocator, 30);
    defer f3.deinit();

    var futures = [_]*future_mod.Future(i32){ f1, f2, f3 };

    const results = try all(i32, allocator, &futures);
    defer allocator.free(results);

    try testing.expectEqual(3, results.len);
    try testing.expectEqual(10, results[0]);
    try testing.expectEqual(20, results[1]);
    try testing.expectEqual(30, results[2]);
}

test "select cancellable cancels pending futures" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var f1 = try future_mod.Future(i32).init(allocator);
    defer f1.deinit();

    var f2 = try future_mod.Future(i32).init(allocator);
    defer f2.deinit();

    const Token = struct {
        cancelled: bool = true,
        pub fn isCancelled(self: *const @This()) bool {
            return self.cancelled;
        }
    };
    const token = Token{};

    var futures = [_]*future_mod.Future(i32){ f1, f2 };
    try testing.expectError(error.Cancelled, selectCancellable(i32, allocator, &futures, &token));
    try testing.expect(f1.poll() == .cancelled);
    try testing.expect(f2.poll() == .cancelled);
}
