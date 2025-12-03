//! zsync- Select Combinator
//! Race multiple futures and return the first to complete

const std = @import("std");
const future_mod = @import("future.zig");

/// Race multiple futures of the same type and return the first to complete
pub fn select(comptime T: type, allocator: std.mem.Allocator, futures: []*future_mod.Future(T)) !T {
    _ = allocator; // Reserved for future use

    if (futures.len == 0) {
        return error.NoFutures;
    }

    // Poll all futures in a loop until one completes
    while (true) {
        for (futures) |fut| {
            const poll_result = fut.poll();
            if (poll_result == .ready) {
                // This future is ready, await it to get the result
                const result = try fut.await();

                // Cancel remaining futures
                for (futures) |other_fut| {
                    if (other_fut != fut) {
                        other_fut.cancel();
                    }
                }

                return result;
            } else if (poll_result == .cancelled) {
                // Skip cancelled futures
                continue;
            }
        }

        // None ready yet, yield and try again
        std.Thread.yield() catch {};
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

    const ts_start = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch unreachable;
    const start: i64 = @intCast(@divTrunc((@as(i128, ts_start.sec) * std.time.ns_per_s + ts_start.nsec), std.time.ns_per_ms));
    const deadline = start + @as(i64, @intCast(timeout_ms));

    while (true) {
        const ts_now = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch unreachable;
        const now: i64 = @intCast(@divTrunc((@as(i128, ts_now.sec) * std.time.ns_per_s + ts_now.nsec), std.time.ns_per_ms));
        if (now >= deadline) break;
        for (futures) |fut| {
            const poll_result = fut.poll();
            if (poll_result == .ready) {
                const result = try fut.await();

                // Cancel remaining futures
                for (futures) |other_fut| {
                    if (other_fut != fut) {
                        other_fut.cancel();
                    }
                }

                return result;
            }
        }

        // Small sleep to avoid busy-waiting
        std.posix.nanosleep(0, 1 * std.time.ns_per_ms);
    }

    // Timeout - cancel all futures
    for (futures) |fut| {
        fut.cancel();
    }

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
