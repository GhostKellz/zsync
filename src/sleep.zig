//! zsync Sleep and Yield Primitives
//! Async sleep and cooperative yielding

const std = @import("std");
const builtin = @import("builtin");
const compat = @import("compat/thread.zig");

/// Cooperatively yield control to other tasks
pub fn yieldNow() !void {
    // For now, just yield the thread
    try std.Thread.yield();
}

/// Sleep for the specified number of milliseconds
pub fn sleep(ms: u64) void {
    compat.sleepMillis(ms);
}

/// Sleep for the specified number of microseconds
pub fn sleepMicros(us: u64) void {
    compat.sleepNanos(us * std.time.ns_per_us);
}

/// Sleep for the specified number of nanoseconds
pub fn sleepNanos(ns: u64) void {
    compat.sleepNanos(ns);
}

// Tests
test "yieldNow basic" {
    try yieldNow();
    try yieldNow();
    try yieldNow();
}

test "sleep milliseconds" {
    // Use cross-platform compat.Instant for timing
    const start = compat.Instant.now() catch unreachable;
    sleep(10);
    const end = compat.Instant.now() catch unreachable;
    const elapsed_ns = end.since(start);
    const elapsed_ms = elapsed_ns / std.time.ns_per_ms;

    // Should sleep at least 10ms (allow some tolerance)
    try std.testing.expect(elapsed_ms >= 9);
}
