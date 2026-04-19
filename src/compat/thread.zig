//! Compatibility layer for std.Thread.Mutex, std.Thread.Condition, and std.time.Instant
//! Maintains a stable blocking API across recent Zig dev stdlib churn.
//! This module provides blocking versions that don't require an Io parameter

const std = @import("std");
const builtin = @import("builtin");

extern "kernel32" fn QueryPerformanceCounter(lpPerformanceCount: *i64) callconv(.c) windows.BOOL;
extern "kernel32" fn QueryPerformanceFrequency(lpFrequency: *i64) callconv(.c) windows.BOOL;
const windows = std.os.windows;
const windows_infinite: u32 = 0xffff_ffff;

/// Compatibility shim for monotonic time access used across zsync.
pub const Instant = struct {
    timestamp: i128,

    pub fn now() error{}!Instant {
        return .{ .timestamp = getMonotonicNanos() };
    }

    pub fn since(self: Instant, earlier: Instant) u64 {
        const diff = self.timestamp - earlier.timestamp;
        return if (diff < 0) 0 else @intCast(diff);
    }

    pub fn order(self: Instant, other: Instant) std.math.Order {
        return std.math.order(self.timestamp, other.timestamp);
    }

    fn getMonotonicNanos() i128 {
        switch (builtin.os.tag) {
            .linux => {
                var ts: std.os.linux.timespec = undefined;
                _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
                return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
            },
            .macos, .ios, .tvos, .watchos, .visionos => {
                var ts: std.c.timespec = undefined;
                _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
                return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
            },
            .windows => {
                var counter: i64 = undefined;
                var freq: i64 = undefined;
                _ = QueryPerformanceCounter(&counter);
                _ = QueryPerformanceFrequency(&freq);
                return @divFloor(@as(i128, counter) * std.time.ns_per_s, freq);
            },
            else => {
                // Fallback - not ideal but works
                return 0;
            },
        }
    }
};

// Support subtraction for backward compatibility: instant - instant -> u64
pub fn instantDiff(a: Instant, b: Instant) u64 {
    return a.since(b);
}

/// Compatibility shim for clock constants used by zsync.
pub const CLOCK = struct {
    pub const REALTIME = std.os.linux.CLOCK.REALTIME;
    pub const MONOTONIC = std.os.linux.CLOCK.MONOTONIC;
};

/// Compatibility shim for timespec
pub const timespec = std.os.linux.timespec;

/// Compatibility shim for `clock_gettime` used by zsync internals.
pub fn clock_gettime(clock_id: std.os.linux.CLOCK) error{}!timespec {
    var ts: timespec = undefined;
    switch (builtin.os.tag) {
        .linux => {
            _ = std.os.linux.clock_gettime(clock_id, &ts);
        },
        else => {
            ts = .{ .sec = 0, .nsec = 0 };
        },
    }
    return ts;
}

/// Compatibility sleep helper for current Zig dev stdlib layouts.
pub fn sleepNanos(ns: u64) void {
    switch (builtin.os.tag) {
        .linux => {
            var ts = std.os.linux.timespec{
                .sec = @intCast(@divTrunc(ns, std.time.ns_per_s)),
                .nsec = @intCast(@rem(ns, std.time.ns_per_s)),
            };
            _ = std.os.linux.nanosleep(&ts, &ts);
        },
        .freestanding, .wasi => {
            // No blocking sleep primitive is available here.
            var i: u64 = 0;
            const spins = @max(1, @divTrunc(ns, 1_000));
            while (i < spins) : (i += 1) {
                std.atomic.spinLoopHint();
            }
        },
        else => {
            var i: u64 = 0;
            const spins = @max(1, @divTrunc(ns, 1_000));
            while (i < spins) : (i += 1) {
                std.atomic.spinLoopHint();
            }
        },
    }
}

pub fn sleepMillis(ms: u64) void {
    sleepNanos(ms * std.time.ns_per_ms);
}

/// A blocking mutex compatible with the old std.Thread.Mutex API
pub const Mutex = struct {
    state: std.atomic.Value(State) = .init(.unlocked),

    const State = enum(u32) {
        unlocked = 0,
        locked = 1,
        contended = 2,
    };

    pub fn lock(self: *Mutex) void {
        // Fast path: try to acquire immediately
        if (self.state.cmpxchgWeak(.unlocked, .locked, .acquire, .monotonic) == null) {
            return;
        }
        self.lockSlow();
    }

    fn lockSlow(self: *Mutex) void {
        // Spin a bit before going to kernel
        var spin: u8 = 0;
        while (spin < 100) : (spin += 1) {
            if (self.state.load(.monotonic) == .unlocked) {
                if (self.state.cmpxchgWeak(.unlocked, .locked, .acquire, .monotonic) == null) {
                    return;
                }
            }
            std.atomic.spinLoopHint();
        }

        // Go to kernel wait
        while (self.state.swap(.contended, .acquire) != .unlocked) {
            futexWait(@ptrCast(&self.state.raw), @intFromEnum(State.contended));
        }
    }

    pub fn unlock(self: *Mutex) void {
        const prev = self.state.swap(.unlocked, .release);
        std.debug.assert(prev != .unlocked);
        if (prev == .contended) {
            futexWake(@ptrCast(&self.state.raw), 1);
        }
    }

    pub fn tryLock(self: *Mutex) bool {
        return self.state.cmpxchgWeak(.unlocked, .locked, .acquire, .monotonic) == null;
    }
};

/// A blocking condition variable compatible with the old std.Thread.Condition API
pub const Condition = struct {
    state: std.atomic.Value(u32) = .init(0),

    pub fn wait(self: *Condition, mutex: *Mutex) void {
        const seq = self.state.load(.monotonic);
        mutex.unlock();
        futexWait(&self.state.raw, seq);
        mutex.lock();
    }

    pub fn signal(self: *Condition) void {
        _ = self.state.fetchAdd(1, .release);
        futexWake(&self.state.raw, 1);
    }

    pub fn broadcast(self: *Condition) void {
        _ = self.state.fetchAdd(1, .release);
        // Use maxInt(i32) - kernel expects signed int, u32 max becomes -1 causing EINVAL
        futexWake(&self.state.raw, @intCast(std.math.maxInt(i32)));
    }
};

// Platform-specific futex operations
fn futexWait(ptr: *const u32, expected: u32) void {
    switch (builtin.os.tag) {
        .linux => {
            _ = std.os.linux.futex_4arg(
                @ptrCast(ptr),
                .{ .cmd = .WAIT, .private = true },
                expected,
                null,
            );
        },
        .windows => {
            _ = windows_infinite;
            while (@atomicLoad(u32, ptr, .monotonic) == expected) {
                std.atomic.spinLoopHint();
            }
        },
        .macos, .ios, .tvos, .watchos, .visionos => {
            // Use ulock on Darwin
            _ = std.c.__ulock_wait(
                .{ .op = .COMPARE_AND_WAIT, .NO_ERRNO = true },
                @ptrCast(@constCast(ptr)),
                expected,
                0,
            );
        },
        else => {
            // Fallback: spin
            while (@atomicLoad(u32, ptr, .monotonic) == expected) {
                std.atomic.spinLoopHint();
            }
        },
    }
}

fn futexWake(ptr: *const u32, max_waiters: u32) void {
    switch (builtin.os.tag) {
        .linux => {
            _ = std.os.linux.futex_3arg(
                @ptrCast(ptr),
                .{ .cmd = .WAKE, .private = true },
                max_waiters,
            );
        },
        .windows => {
            // Spin-wait fallback only; waiters observe state changes cooperatively.
        },
        .macos, .ios, .tvos, .watchos, .visionos => {
            const flags: std.c.UL = .{
                .op = .COMPARE_AND_WAIT,
                .NO_ERRNO = true,
                .WAKE_ALL = max_waiters > 1,
            };
            _ = std.c.__ulock_wake(flags, @ptrCast(@constCast(ptr)), 0);
        },
        else => {
            // Fallback: nothing to do for spin-wait
        },
    }
}

test "Condition broadcast wakes all waiters" {
    var mutex = Mutex{};
    var cond = Condition{};
    var ready: u32 = 0;
    var done: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, struct {
            fn run(m: *Mutex, c: *Condition, r: *u32, d: *std.atomic.Value(u32)) void {
                m.lock();
                r.* += 1;
                while (r.* < 4) {
                    c.wait(m);
                }
                m.unlock();
                _ = d.fetchAdd(1, .release);
            }
        }.run, .{ &mutex, &cond, &ready, &done });
    }

    // Wait for all threads to be waiting
    while (true) {
        mutex.lock();
        const r = ready;
        mutex.unlock();
        if (r == 4) break;
        std.Thread.yield() catch {};
    }

    // Broadcast should wake all 4 threads
    cond.broadcast();

    for (threads) |t| t.join();

    // All 4 threads should have completed
    try std.testing.expectEqual(@as(u32, 4), done.load(.acquire));
}
