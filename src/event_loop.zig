//! Integrated event loop that combines reactor polling with task scheduling
//! This is the heart of the Zsync runtime

const std = @import("std");
const reactor = @import("reactor.zig");
const scheduler = @import("scheduler.zig");
const timer = @import("timer.zig");
const async_runtime = @import("async_runtime.zig");

/// Event loop configuration
pub const EventLoopConfig = struct {
    max_events_per_poll: u32 = 1024,
    poll_timeout_ms: i32 = 10,
    max_tasks_per_tick: u32 = 32,
    enable_timers: bool = true,
    enable_io: bool = true,
};

/// I/O readiness notification
pub const IoReadiness = struct {
    fd: std.posix.fd_t,
    events: reactor.IoEvent,
    user_data: usize,
    waker: ?*scheduler.Waker = null,
};

/// Event loop statistics for monitoring
pub const EventLoopStats = struct {
    total_ticks: u64 = 0,
    tasks_processed: u64 = 0,
    io_events_processed: u64 = 0,
    timer_events_processed: u64 = 0,
    total_runtime_ms: u64 = 0,
    average_tick_time_us: u64 = 0,

    pub fn updateTickTime(self: *EventLoopStats, tick_time_us: u64) void {
        self.total_ticks += 1;
        if (self.total_ticks == 1) {
            self.average_tick_time_us = tick_time_us;
        } else {
            // Rolling average
            self.average_tick_time_us = (self.average_tick_time_us * 7 + tick_time_us) / 8;
        }
    }
};

/// Integrated event loop combining reactor, scheduler, and timers
pub const EventLoop = struct {
    allocator: std.mem.Allocator,
    config: EventLoopConfig,
    reactor_instance: reactor.Reactor,
    scheduler_instance: scheduler.AsyncScheduler,
    timer_wheel: timer.TimerWheel,
    async_runtime: async_runtime.AsyncRuntime,
    io_readiness_map: std.HashMap(std.posix.fd_t, IoReadiness, std.hash_map.AutoContext(std.posix.fd_t), std.hash_map.default_max_load_percentage),
    running: std.atomic.Value(bool),
    should_stop: std.atomic.Value(bool),
    stats: EventLoopStats,
    start_time: u64,

    const Self = @This();

    /// Initialize the event loop
    pub fn init(allocator: std.mem.Allocator, config: EventLoopConfig) !Self {
        return Self{
            .allocator = allocator,
            .config = config,
            .reactor_instance = try reactor.Reactor.init(allocator),
            .scheduler_instance = try scheduler.AsyncScheduler.init(allocator),
            .timer_wheel = try timer.TimerWheel.init(allocator),
            .async_runtime = try async_runtime.AsyncRuntime.init(allocator),
            .io_readiness_map = std.HashMap(std.posix.fd_t, IoReadiness, std.hash_map.AutoContext(std.posix.fd_t), std.hash_map.default_max_load_percentage).init(allocator),
            .running = std.atomic.Value(bool).init(false),
            .should_stop = std.atomic.Value(bool).init(false),
            .stats = EventLoopStats{},
            .start_time = @intCast(std.time.microTimestamp()),
        };
    }

    /// Deinitialize the event loop
    pub fn deinit(self: *Self) void {
        self.stop();
        self.reactor_instance.deinit();
        self.scheduler_instance.deinit();
        self.timer_wheel.deinit();
        self.async_runtime.deinit();
        self.io_readiness_map.deinit();
    }

    /// Register I/O interest with associated waker
    pub fn registerIo(self: *Self, fd: std.posix.fd_t, events: reactor.IoEvent, waker: *scheduler.Waker) !void {
        // Register with reactor
        try self.reactor_instance.register(.{
            .fd = fd,
            .events = events,
            .user_data = @intFromPtr(waker),
        });

        // Store readiness info
        try self.io_readiness_map.put(fd, IoReadiness{
            .fd = fd,
            .events = events,
            .user_data = @intFromPtr(waker),
            .waker = waker,
        });
    }

    /// Modify I/O interest
    pub fn modifyIo(self: *Self, fd: std.posix.fd_t, events: reactor.IoEvent, waker: *scheduler.Waker) !void {
        try self.reactor_instance.modify(.{
            .fd = fd,
            .events = events,
            .user_data = @intFromPtr(waker),
        });

        // Update readiness info
        if (self.io_readiness_map.getPtr(fd)) |readiness| {
            readiness.events = events;
            readiness.waker = waker;
        }
    }

    /// Unregister I/O interest
    pub fn unregisterIo(self: *Self, fd: std.posix.fd_t) !void {
        try self.reactor_instance.unregister(fd);
        _ = self.io_readiness_map.remove(fd);
    }

    /// Spawn a new task
    pub fn spawn(self: *Self, comptime func: anytype, args: anytype, priority: scheduler.TaskPriority) !u32 {
        return self.scheduler_instance.spawn(func, args, priority);
    }

    /// Spawn an async task using the async runtime
    pub fn spawnAsync(self: *Self, comptime func: anytype, args: anytype) !async_runtime.TaskHandle {
        return self.async_runtime.spawn(func, args);
    }

    /// Async sleep integrated with event loop
    pub fn asyncSleep(self: *Self, duration_ms: u64) !void {
        return self.async_runtime.sleep(duration_ms);
    }

    /// Schedule a timer with waker
    pub fn scheduleTimer(self: *Self, delay_ms: u64, waker: *scheduler.Waker) !timer.TimerHandle {
        const WakerCallback = struct {
            fn callback() void {
                // In a full implementation, we'd get the waker from user_data and call wake
                // For now, this is a placeholder
            }
        };

        return self.timer_wheel.scheduleTimeoutWithData(delay_ms, &WakerCallback.callback, @ptrCast(waker));
    }

    /// Main event loop - this is where everything comes together
    pub fn run(self: *Self) !void {
        if (self.running.swap(true, .acq_rel)) {
            return error.AlreadyRunning;
        }
        defer self.running.store(false, .release);

        self.start_time = @intCast(std.time.microTimestamp());
        std.debug.print("🚀 Zsync Event Loop started\n", .{});

        // Main event loop - runs until explicitly stopped
        var iterations: u32 = 0;

        while (!self.should_stop.load(.acquire)) {
            const tick_start = std.time.microTimestamp();
            iterations += 1;
            
            // Step 1: Process ready tasks
            const tasks_processed = try self.processTasks();
            self.stats.tasks_processed += tasks_processed;

            // Step 2: Process expired timers
            const timers_processed = if (self.config.enable_timers) 
                self.processTimers() 
            else 
                0;
            self.stats.timer_events_processed += timers_processed;

            // Step 3: Poll for I/O events
            const io_events = if (self.config.enable_io)
                try self.processIoEvents()
            else
                0;
            self.stats.io_events_processed += io_events;

            // Step 4: Check if we should continue
            if (!self.hasWork()) {
                // No work remaining, can exit gracefully
                std.debug.print("✅ No more work, shutting down gracefully\n", .{});
                break;
            }

            // Update statistics
            const tick_end = std.time.microTimestamp();
            const tick_time = @as(u64, @intCast(tick_end - tick_start));
            self.stats.updateTickTime(tick_time);
            self.stats.total_runtime_ms = @intCast(@divTrunc(tick_end - @as(i64, @intCast(self.start_time)), 1000));

            // Yield if no work was done to prevent busy loop
            if (tasks_processed == 0 and timers_processed == 0 and io_events == 0) {
                std.time.sleep(10000); // Sleep for 10μs
            }
        }

        // Event loop completed normally

        std.debug.print("✅ Zsync Event Loop stopped after {} iterations\n", .{iterations});
        self.printStats();
    }

    /// Run event loop until completion flag is set or no more work
    pub fn runUntilComplete(self: *Self, completion_flag: *std.atomic.Value(bool)) !void {
        if (self.running.swap(true, .acq_rel)) {
            return error.AlreadyRunning;
        }
        defer self.running.store(false, .release);

        self.start_time = @intCast(std.time.microTimestamp());
        std.debug.print("🚀 Zsync Event Loop started\n", .{});

        while (!self.should_stop.load(.acquire) and !completion_flag.load(.acquire)) {
            const tick_start = std.time.microTimestamp();
            
            // Step 1: Process ready tasks
            const tasks_processed = try self.processTasks();
            self.stats.tasks_processed += tasks_processed;

            // Step 2: Process expired timers
            const timers_processed = if (self.config.enable_timers) 
                self.processTimers() 
            else 
                0;
            self.stats.timer_events_processed += timers_processed;

            // Step 3: Poll for I/O events
            const io_events = if (self.config.enable_io)
                try self.processIoEvents()
            else
                0;
            self.stats.io_events_processed += io_events;

            // Step 4: Check if we should continue
            const has_work = self.hasWork();
            const main_completed = completion_flag.load(.acquire);
            
            if (main_completed and !has_work) {
                // Main task completed and no more work, can exit
                std.debug.print("✅ Main task completed, shutting down gracefully\n", .{});
                break;
            }

            // Update statistics
            const tick_end = std.time.microTimestamp();
            const tick_time = @as(u64, @intCast(tick_end - tick_start));
            self.stats.updateTickTime(tick_time);
            self.stats.total_runtime_ms = @intCast(@divTrunc(tick_end - @as(i64, @intCast(self.start_time)), 1000));

            // Yield if no work was done to prevent busy loop
            if (tasks_processed == 0 and timers_processed == 0 and io_events == 0) {
                std.time.sleep(1000); // Sleep for 1μs
            }
        }

        std.debug.print("✅ Zsync Event Loop stopped\n", .{});
        self.printStats();
    }

    /// Process ready tasks from scheduler
    fn processTasks(self: *Self) !u32 {
        // Process regular scheduler tasks
        const scheduler_tasks = try self.scheduler_instance.tick();
        
        // Process async runtime tasks
        const async_tasks = try self.async_runtime.tick();
        
        return scheduler_tasks + async_tasks;
    }

    /// Process expired timers
    fn processTimers(self: *Self) u32 {
        return self.timer_wheel.processExpired();
    }

    /// Process I/O events and wake corresponding tasks
    fn processIoEvents(self: *Self) !u32 {
        _ = try self.reactor_instance.poll(self.config.poll_timeout_ms);
        var processed: u32 = 0;

        while (self.reactor_instance.nextEvent()) |event| {
            // Wake the task associated with this I/O event
            if (self.io_readiness_map.get(event.fd)) |readiness| {
                if (readiness.waker) |waker| {
                    waker.wake();
                    processed += 1;
                }
            }
        }

        return processed;
    }

    /// Calculate optimal poll timeout based on current state
    fn calculatePollTimeout(self: *Self, tasks_processed: u32, timers_processed: u32, io_events: u32) i32 {
        // If we have pending work, don't block
        if (self.scheduler_instance.hasPendingWork()) {
            return 0;
        }

        // Check next timer expiry
        if (self.timer_wheel.nextExpiry()) |next_expiry_ms| {
            return @intCast(@min(next_expiry_ms, self.config.poll_timeout_ms));
        }

        // If we processed a lot of events, use shorter timeout
        const total_events = tasks_processed + timers_processed + io_events;
        if (total_events > self.config.max_tasks_per_tick / 2) {
            return 1; // Very short timeout
        }

        return self.config.poll_timeout_ms;
    }

    /// Check if the event loop has pending work
    fn hasWork(self: *Self) bool {
        return self.scheduler_instance.hasPendingWork() or
               self.async_runtime.hasPendingWork() or
               !self.timer_wheel.isEmpty() or
               self.io_readiness_map.count() > 0;
    }

    /// Request event loop to stop
    pub fn stop(self: *Self) void {
        self.should_stop.store(true, .release);
    }

    /// Check if event loop is running
    pub fn isRunning(self: *Self) bool {
        return self.running.load(.acquire);
    }

    /// Get current statistics
    pub fn getStats(self: *Self) EventLoopStats {
        return self.stats;
    }

    /// Print performance statistics
    fn printStats(self: *Self) void {
        std.debug.print("\n📊 Zsync Event Loop Statistics:\n", .{});
        std.debug.print("  Total ticks: {}\n", .{self.stats.total_ticks});
        std.debug.print("  Tasks processed: {}\n", .{self.stats.tasks_processed});
        std.debug.print("  I/O events: {}\n", .{self.stats.io_events_processed});
        std.debug.print("  Timer events: {}\n", .{self.stats.timer_events_processed});
        std.debug.print("  Runtime: {}ms\n", .{self.stats.total_runtime_ms});
        std.debug.print("  Avg tick time: {}μs\n", .{self.stats.average_tick_time_us});
        
        if (self.stats.total_ticks > 0) {
            const tasks_per_tick = self.stats.tasks_processed / self.stats.total_ticks;
            const events_per_tick = self.stats.io_events_processed / self.stats.total_ticks;
            std.debug.print("  Tasks/tick: {}\n", .{tasks_per_tick});
            std.debug.print("  I/O events/tick: {}\n", .{events_per_tick});
        }
    }
};

/// Create a default event loop
pub fn createDefault(allocator: std.mem.Allocator) !EventLoop {
    return EventLoop.init(allocator, EventLoopConfig{});
}

/// Create a high-performance event loop
pub fn createHighPerf(allocator: std.mem.Allocator) !EventLoop {
    return EventLoop.init(allocator, EventLoopConfig{
        .max_events_per_poll = 2048,
        .poll_timeout_ms = 1,
        .max_tasks_per_tick = 64,
    });
}

/// Create an I/O focused event loop
pub fn createIoFocused(allocator: std.mem.Allocator) !EventLoop {
    return EventLoop.init(allocator, EventLoopConfig{
        .max_events_per_poll = 4096,
        .poll_timeout_ms = 5,
        .max_tasks_per_tick = 16,
    });
}

// Tests
test "event loop creation" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var loop = try createDefault(allocator);
    defer loop.deinit();
    
    try testing.expect(!loop.isRunning());
    try testing.expect(!loop.hasWork());
}

test "event loop configuration" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    const config = EventLoopConfig{
        .max_events_per_poll = 512,
        .poll_timeout_ms = 20,
        .max_tasks_per_tick = 16,
    };
    
    var loop = try EventLoop.init(allocator, config);
    defer loop.deinit();
    
    try testing.expect(loop.config.max_events_per_poll == 512);
    try testing.expect(loop.config.poll_timeout_ms == 20);
}

test "event loop statistics" {
    const testing = std.testing;
    
    var stats = EventLoopStats{};
    stats.updateTickTime(100);
    stats.updateTickTime(200);
    
    try testing.expect(stats.total_ticks == 2);
    try testing.expect(stats.average_tick_time_us > 0);
}
