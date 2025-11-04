//! Zsync v0.6.0 - Sleep and Yield Primitives
//! Async sleep and cooperative yielding

const std = @import("std");

/// Cooperatively yield control to other tasks
pub fn yieldNow() !void {
    // For now, just yield the thread
    // TODO: Integrate with runtime scheduler for true cooperative yielding
    try std.Thread.yield();
}

/// Sleep for the specified number of milliseconds
pub fn sleep(ms: u64) void {
    const ns = ms * std.time.ns_per_ms;
    std.posix.nanosleep(0, ns);
}

/// Sleep for the specified number of microseconds
pub fn sleepMicros(us: u64) void {
    const ns = us * std.time.ns_per_us;
    std.posix.nanosleep(0, ns);
}

/// Sleep for the specified number of nanoseconds
pub fn sleepNanos(ns: u64) void {
    std.posix.nanosleep(0, ns);
}

// Tests
test "yieldNow basic" {
    try yieldNow();
    try yieldNow();
    try yieldNow();
}

test "sleep milliseconds" {
    const ts_start = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch unreachable;
    const start: i64 = @intCast(@divTrunc((@as(i128, ts_start.sec) * std.time.ns_per_s + ts_start.nsec), std.time.ns_per_ms));
    sleep(10);
    const ts_end = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch unreachable;
    const end: i64 = @intCast(@divTrunc((@as(i128, ts_end.sec) * std.time.ns_per_s + ts_end.nsec), std.time.ns_per_ms));
    const elapsed = end - start;

    // Should sleep at least 10ms (allow some tolerance)
    try std.testing.expect(elapsed >= 9);
}
