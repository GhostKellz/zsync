//! Timer system for Zsync runtime
//! Provides high-resolution timers and delay functionality

const std = @import("std");

/// Timer handle for managing scheduled timeouts
pub const TimerHandle = struct {
    id: u64,
    wheel: *TimerWheel,

    const Self = @This();

    /// Cancel the timer
    pub fn cancel(self: Self) void {
        self.wheel.cancelTimer(self.id);
    }

    /// Check if the timer is still active
    pub fn isActive(self: Self) bool {
        return self.wheel.isTimerActive(self.id);
    }
};

/// Timer entry in the wheel
const TimerEntry = struct {
    id: u64,
    expiry_time: u64, // Timestamp in milliseconds
    callback: *const fn () void,
    user_data: ?*anyopaque = null,
    cancelled: bool = false,
    is_interval: bool = false,
    interval_ms: u64 = 0,
};

/// Timer wheel implementation for efficient timer management
pub const TimerWheel = struct {
    allocator: std.mem.Allocator,
    timers: std.HashMap(u64, TimerEntry, std.hash_map.AutoContext(u64), std.hash_map.default_max_load_percentage),
    sorted_timers: std.ArrayList(u64), // Timer IDs sorted by expiry time
    next_timer_id: std.atomic.Value(u64),
    start_time: u64, // Runtime start time in milliseconds
    mutex: std.Thread.Mutex,

    const Self = @This();

    /// Initialize the timer wheel
    pub fn init(allocator: std.mem.Allocator) !Self {
        return Self{
            .allocator = allocator,
            .timers = std.HashMap(u64, TimerEntry, std.hash_map.AutoContext(u64), std.hash_map.default_max_load_percentage).init(allocator),
            .sorted_timers = .{},
            .next_timer_id = std.atomic.Value(u64).init(1),
            .start_time = getCurrentTimeMs(),
            .mutex = std.Thread.Mutex{},
        };
    }

    /// Deinitialize the timer wheel
    pub fn deinit(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.timers.deinit();
        self.sorted_timers.deinit(self.allocator);
    }

    /// Get current time in milliseconds since runtime start
    fn getCurrentTimeMs() u64 {
        const ts = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch unreachable;
        return @intCast(@divTrunc((@as(i128, ts.sec) * std.time.ns_per_s + ts.nsec), std.time.ns_per_ms));
    }

    /// Get runtime-relative time
    fn getRelativeTimeMs(self: *Self) u64 {
        return getCurrentTimeMs() - self.start_time;
    }

    /// Generate next timer ID
    fn nextTimerId(self: *Self) u64 {
        return self.next_timer_id.fetchAdd(1, .monotonic);
    }

    /// Schedule a timeout callback
    pub fn scheduleTimeout(self: *Self, delay_ms: u64, callback: *const fn () void) !TimerHandle {
        return self.scheduleTimeoutWithData(delay_ms, callback, null);
    }

    /// Schedule a timeout with user data
    pub fn scheduleTimeoutWithData(self: *Self, delay_ms: u64, callback: *const fn () void, user_data: ?*anyopaque) !TimerHandle {
        self.mutex.lock();
        defer self.mutex.unlock();

        const timer_id = self.nextTimerId();
        const expiry_time = getCurrentTimeMs() + delay_ms;

        const entry = TimerEntry{
            .id = timer_id,
            .expiry_time = expiry_time,
            .callback = callback,
            .user_data = user_data,
        };

        try self.timers.put(timer_id, entry);

        // Insert timer ID in sorted order
        const insert_pos = self.findInsertPosition(expiry_time);
        try self.sorted_timers.insert(self.allocator, insert_pos, timer_id);

        return TimerHandle{
            .id = timer_id,
            .wheel = self,
        };
    }

    /// Schedule a repeating interval timer
    pub fn scheduleInterval(self: *Self, period_ms: u64, callback: *const fn () void) !TimerHandle {
        return self.scheduleIntervalWithData(period_ms, callback, null);
    }

    /// Schedule a repeating interval timer with user data
    pub fn scheduleIntervalWithData(self: *Self, period_ms: u64, callback: *const fn () void, user_data: ?*anyopaque) !TimerHandle {
        self.mutex.lock();
        defer self.mutex.unlock();

        const timer_id = self.nextTimerId();
        const expiry_time = getCurrentTimeMs() + period_ms;

        const entry = TimerEntry{
            .id = timer_id,
            .expiry_time = expiry_time,
            .callback = callback,
            .user_data = user_data,
            .is_interval = true,
            .interval_ms = period_ms,
        };

        try self.timers.put(timer_id, entry);

        // Insert timer ID in sorted order
        const insert_pos = self.findInsertPosition(expiry_time);
        try self.sorted_timers.insert(self.allocator, insert_pos, timer_id);

        return TimerHandle{
            .id = timer_id,
            .wheel = self,
        };
    }

    /// Find position to insert timer in sorted list
    fn findInsertPosition(self: *Self, expiry_time: u64) usize {
        var low: usize = 0;
        var high: usize = self.sorted_timers.items.len;

        while (low < high) {
            const mid = low + (high - low) / 2;
            const mid_timer_id = self.sorted_timers.items[mid];
            
            if (self.timers.get(mid_timer_id)) |timer| {
                if (timer.expiry_time <= expiry_time) {
                    low = mid + 1;
                } else {
                    high = mid;
                }
            } else {
                // Timer no longer exists, remove it
                _ = self.sorted_timers.orderedRemove(mid);
                if (mid < high) high -= 1;
            }
        }

        return low;
    }

    /// Process expired timers and return count of processed timers
    pub fn processExpired(self: *Self) u32 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const current_time = getCurrentTimeMs();
        var processed: u32 = 0;

        // Process timers from the front of the sorted list
        while (self.sorted_timers.items.len > 0) {
            const timer_id = self.sorted_timers.items[0];

            if (self.timers.getPtr(timer_id)) |timer| {
                if (timer.expiry_time > current_time) {
                    // No more expired timers
                    break;
                }

                if (!timer.cancelled) {
                    // Execute the timer callback
                    timer.callback();
                    processed += 1;

                    // Reschedule if this is an interval timer
                    if (timer.is_interval) {
                        timer.expiry_time = current_time + timer.interval_ms;

                        // Remove from current position and reinsert in sorted order
                        _ = self.sorted_timers.orderedRemove(0);
                        const insert_pos = self.findInsertPosition(timer.expiry_time);
                        self.sorted_timers.insert(self.allocator, insert_pos, timer_id) catch {};
                        continue;
                    }
                }
            }

            // Remove the processed or cancelled timer
            _ = self.sorted_timers.orderedRemove(0);
            _ = self.timers.remove(timer_id);
        }

        return processed;
    }

    /// Cancel a timer by ID
    pub fn cancelTimer(self: *Self, timer_id: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.timers.getPtr(timer_id)) |timer| {
            timer.cancelled = true;
        }
    }

    /// Check if a timer is still active
    pub fn isTimerActive(self: *Self, timer_id: u64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.timers.get(timer_id)) |timer| {
            return !timer.cancelled;
        }
        return false;
    }

    /// Check if the timer wheel is empty
    pub fn isEmpty(self: *Self) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        return self.sorted_timers.items.len == 0;
    }

    /// Get the next timer expiry time (for optimizing poll timeouts)
    pub fn nextExpiry(self: *Self) ?u64 {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.sorted_timers.items.len == 0) {
            return null;
        }

        const timer_id = self.sorted_timers.items[0];
        if (self.timers.get(timer_id)) |timer| {
            const current_time = getCurrentTimeMs();
            if (timer.expiry_time > current_time) {
                return timer.expiry_time - current_time;
            }
        }

        return 0; // Timer is already expired
    }
};

/// Sleep for the specified duration
pub fn sleep(duration_ms: u64) void {
    // This would integrate with the runtime's timer wheel
    // For now, we'll implement a simple version using nanosleep
    std.posix.nanosleep(0, duration_ms * std.time.ns_per_ms);
}

/// Global timer wheel for standalone timer functions
var global_wheel: ?*TimerWheel = null;
var global_wheel_mutex: std.Thread.Mutex = .{};

/// Initialize global timer wheel (call once at startup)
pub fn initGlobalTimerWheel(allocator: std.mem.Allocator) !void {
    global_wheel_mutex.lock();
    defer global_wheel_mutex.unlock();

    if (global_wheel == null) {
        const wheel = try allocator.create(TimerWheel);
        wheel.* = try TimerWheel.init(allocator);
        global_wheel = wheel;
    }
}

/// Deinitialize global timer wheel
pub fn deinitGlobalTimerWheel(allocator: std.mem.Allocator) void {
    global_wheel_mutex.lock();
    defer global_wheel_mutex.unlock();

    if (global_wheel) |wheel| {
        wheel.deinit();
        allocator.destroy(wheel);
        global_wheel = null;
    }
}

/// Get the global timer wheel (creates one if needed with page allocator)
fn getGlobalWheel() !*TimerWheel {
    global_wheel_mutex.lock();
    defer global_wheel_mutex.unlock();

    if (global_wheel) |wheel| {
        return wheel;
    }

    // Auto-create with page allocator
    const wheel = try std.heap.page_allocator.create(TimerWheel);
    wheel.* = try TimerWheel.init(std.heap.page_allocator);
    global_wheel = wheel;
    return wheel;
}

/// Create an interval timer that fires repeatedly
pub fn interval(period_ms: u64, callback: *const fn () void) !TimerHandle {
    const wheel = try getGlobalWheel();
    return wheel.scheduleInterval(period_ms, callback);
}

/// Create a one-shot timeout timer
pub fn timeout(delay_ms: u64, callback: *const fn () void) !TimerHandle {
    const wheel = try getGlobalWheel();
    return wheel.scheduleTimeout(delay_ms, callback);
}

/// Process all expired global timers (call this in your event loop)
pub fn processGlobalTimers() u32 {
    global_wheel_mutex.lock();
    const wheel = global_wheel;
    global_wheel_mutex.unlock();

    if (wheel) |w| {
        return w.processExpired();
    }
    return 0;
}

/// Delay execution by yielding to the runtime
pub fn delay(duration_ms: u64) void {
    // This should suspend the current task and schedule a wakeup
    // For now, use regular sleep
    sleep(duration_ms);
}

// High-precision timing utilities

/// Get current time in nanoseconds (monotonic)
pub fn nanoTime() u64 {
    const ts = std.posix.clock_gettime(std.posix.CLOCK.MONOTONIC) catch unreachable;
    return @intCast(@as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec)));
}

/// Get current time in microseconds (monotonic)
pub fn microTime() u64 {
    const ts = std.posix.clock_gettime(std.posix.CLOCK.MONOTONIC) catch unreachable;
    return @intCast(@divTrunc(@as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec)), std.time.ns_per_us));
}

/// Get current time in milliseconds (wall clock)
pub fn milliTime() u64 {
    const ts = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch unreachable;
    return @intCast(@divTrunc(@as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec)), std.time.ns_per_ms));
}

/// Measure execution time of a function
pub fn measure(comptime func: anytype, args: anytype) struct { result: @TypeOf(@call(.auto, func, args)), duration_ns: u64 } {
    const start = nanoTime();
    const result = @call(.auto, func, args);
    const end = nanoTime();
    
    return .{
        .result = result,
        .duration_ns = end - start,
    };
}

// Tests
test "timer wheel creation" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var wheel = try TimerWheel.init(allocator);
    defer wheel.deinit();
    
    try testing.expect(wheel.isEmpty());
}

test "timer scheduling" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var wheel = try TimerWheel.init(allocator);
    defer wheel.deinit();
    
    const TestCallback = struct {
        fn callback() void {
            // This would set executed = true in a real test
        }
    };
    
    const handle = try wheel.scheduleTimeout(100, TestCallback.callback);
    try testing.expect(handle.isActive());
    try testing.expect(!wheel.isEmpty());
}

test "timer expiry calculation" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var wheel = try TimerWheel.init(allocator);
    defer wheel.deinit();
    
    const TestCallback = struct {
        fn callback() void {}
    };
    
    _ = try wheel.scheduleTimeout(100, TestCallback.callback);
    
    const next_expiry = wheel.nextExpiry();
    try testing.expect(next_expiry != null);
    try testing.expect(next_expiry.? <= 100);
}

test "timer cancellation" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var wheel = try TimerWheel.init(allocator);
    defer wheel.deinit();
    
    const TestCallback = struct {
        fn callback() void {}
    };
    
    const handle = try wheel.scheduleTimeout(100, TestCallback.callback);
    try testing.expect(handle.isActive());
    
    handle.cancel();
    try testing.expect(!handle.isActive());
}

test "time measurement" {
    const TestFunction = struct {
        fn slowFunction() u32 {
            std.posix.nanosleep(0, 1 * std.time.ns_per_ms); // Sleep for 1ms
            return 42;
        }
    };
    
    const result = measure(TestFunction.slowFunction, .{});
    
    const testing = std.testing;
    try testing.expect(result.result == 42);
    try testing.expect(result.duration_ns >= 1 * std.time.ns_per_ms);
}
