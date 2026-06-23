//! Tokio-style time facade.

const std = @import("std");
const compat = @import("compat/thread.zig");
const sleep_mod = @import("sleep.zig");
const timer_mod = @import("timer.zig");

pub const Instant = compat.Instant;
pub const TimerWheel = timer_mod.TimerWheel;
pub const TimerHandle = timer_mod.TimerHandle;
pub const MeasureResult = timer_mod.MeasureResult;

pub const sleep = sleep_mod.sleep;
pub const sleepMicros = sleep_mod.sleepMicros;
pub const sleepNanos = sleep_mod.sleepNanos;
pub const sleepCancellable = sleep_mod.sleepCancellable;
pub const yieldNow = sleep_mod.yieldNow;

pub const nanoTime = timer_mod.nanoTime;
pub const microTime = timer_mod.microTime;
pub const milliTime = timer_mod.milliTime;
pub const measure = timer_mod.measure;

pub const Interval = struct {
    period_ms: u64,
    last_tick: u64,

    const Self = @This();

    pub fn init(period_ms: u64) Self {
        return .{ .period_ms = period_ms, .last_tick = milliTime() };
    }

    pub fn tick(self: *Self) void {
        const now = milliTime();
        const next_tick = self.last_tick + self.period_ms;
        if (now < next_tick) sleep(next_tick - now);
        self.last_tick = milliTime();
    }

    pub fn reset(self: *Self) void {
        self.last_tick = milliTime();
    }

    pub fn period(self: *const Self) u64 {
        return self.period_ms;
    }
};

pub fn interval(period_ms: u64) Interval {
    return Interval.init(period_ms);
}

/// Blocking compatibility timeout. Prefer future-aware timeout combinators for
/// async work; this only reports whether a synchronous call exceeded a duration.
pub fn timeoutFn(comptime func: anytype, args: anytype, timeout_ms: u64) !@TypeOf(@call(.auto, func, args)) {
    const start = milliTime();
    const result = @call(.auto, func, args);
    if (milliTime() - start > timeout_ms) return error.Timeout;
    return result;
}

test "time facade interval" {
    var int = interval(1);
    try std.testing.expectEqual(@as(u64, 1), int.period());
    int.reset();
}
