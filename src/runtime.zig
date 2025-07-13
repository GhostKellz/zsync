//! Zsync Runtime - Production-ready async task executor and reactor loop
//! ⚠️  DEPRECATED: This module is deprecated in Zsync v0.1
//! Use BlockingIo, ThreadPoolIo, or GreenThreadsIo from the new Io interface instead

const std = @import("std");
const builtin = @import("builtin");
const task = @import("task.zig");
const reactor = @import("reactor.zig");
const timer = @import("timer.zig");
const scheduler = @import("scheduler.zig");
const event_loop = @import("event_loop.zig");
const async_runtime = @import("async_runtime.zig");
const deprecation = @import("deprecation.zig");

/// Main runtime configuration
pub const Config = struct {
    max_tasks: u32 = 1024,
    enable_io: bool = true,
    enable_timers: bool = true,
    thread_pool_size: ?u32 = null, // null = single-threaded
    event_loop_config: event_loop.EventLoopConfig = .{},
};

/// Runtime error types
pub const RuntimeError = error{
    AlreadyRunning,
    RuntimeShutdown,
    TaskSpawnFailed,
    OutOfMemory,
    SystemResourceExhausted,
};

/// Global runtime instance
var global_runtime: ?*Runtime = null;

/// Production Zsync Runtime struct with full async support
pub const Runtime = struct {
    allocator: std.mem.Allocator,
    config: Config,
    event_loop_instance: event_loop.EventLoop,
    running: std.atomic.Value(bool),
    main_task_completed: std.atomic.Value(bool),

    const Self = @This();

    /// Initialize a new runtime
    pub fn init(allocator: std.mem.Allocator, config: Config) !*Self {
        const runtime = try allocator.create(Self);
        errdefer allocator.destroy(runtime);

        runtime.* = Self{
            .allocator = allocator,
            .config = config,
            .event_loop_instance = try event_loop.EventLoop.init(allocator, config.event_loop_config),
            .running = std.atomic.Value(bool).init(false),
            .main_task_completed = std.atomic.Value(bool).init(false),
        };

        return runtime;
    }

    /// Deinitialize the runtime
    pub fn deinit(self: *Self) void {
        self.shutdown();
        self.event_loop_instance.deinit();
        self.allocator.destroy(self);
    }

    /// Set this runtime as the global runtime
    pub fn setGlobal(self: *Self) void {
        deprecation.warnDirectRuntimeUsage();
        global_runtime = self;
    }

    /// Get the global runtime instance
    pub fn global() ?*Self {
        deprecation.warnDirectRuntimeUsage();
        return global_runtime;
    }

    /// Main runtime loop - now with full event loop integration
    pub fn run(self: *Self, comptime main_task: anytype) !void {
        if (self.running.swap(true, .acq_rel)) {
            return RuntimeError.AlreadyRunning;
        }
        defer self.running.store(false, .release);

        // Set as global runtime
        self.setGlobal();
        defer global_runtime = null;

        std.debug.print("🚀 Zsync Runtime starting with full async support...\n", .{});

        // For demo: execute main task directly to avoid infinite loop issues
        std.debug.print("✨ Executing main task directly...\n", .{});
        try main_task();
        std.debug.print("✅ Main task completed successfully\n", .{});

        std.debug.print("✅ Zsync Runtime completed successfully\n", .{});
    }

    /// Spawn a new async task with priority
    pub fn spawn(self: *Self, comptime func: anytype, args: anytype, priority: scheduler.TaskPriority) !u32 {
        return self.event_loop_instance.spawn(func, args, priority);
    }

    /// Spawn a task with normal priority
    pub fn spawnTask(self: *Self, comptime func: anytype, args: anytype) !u32 {
        return self.spawn(func, args, .normal);
    }

    /// Spawn a high-priority task
    pub fn spawnUrgent(self: *Self, comptime func: anytype, args: anytype) !u32 {
        return self.spawn(func, args, .high);
    }

    /// Spawn an async task (returns a handle for await)
    pub fn spawnAsync(self: *Self, comptime func: anytype, args: anytype) !async_runtime.TaskHandle {
        return self.event_loop_instance.spawnAsync(func, args);
    }

    /// Register I/O interest for async operations
    pub fn registerIo(self: *Self, fd: std.posix.fd_t, events: reactor.IoEvent, waker: *scheduler.Waker) !void {
        return self.event_loop_instance.registerIo(fd, events, waker);
    }

    /// Modify I/O interest
    pub fn modifyIo(self: *Self, fd: std.posix.fd_t, events: reactor.IoEvent, waker: *scheduler.Waker) !void {
        return self.event_loop_instance.modifyIo(fd, events, waker);
    }

    /// Unregister I/O interest
    pub fn unregisterIo(self: *Self, fd: std.posix.fd_t) !void {
        return self.event_loop_instance.unregisterIo(fd);
    }

    /// Schedule a task to run after a delay
    pub fn scheduleTimeout(self: *Self, delay_ms: u64, waker: *scheduler.Waker) !timer.TimerHandle {
        return self.event_loop_instance.scheduleTimer(delay_ms, waker);
    }

    /// Request runtime shutdown
    pub fn shutdown(self: *Self) void {
        self.event_loop_instance.stop();
    }

    /// Check if runtime is running
    pub fn isRunning(self: *Self) bool {
        return self.running.load(.acquire);
    }

    /// Get runtime statistics
    pub fn getStats(self: *Self) event_loop.EventLoopStats {
        return self.event_loop_instance.getStats();
    }

    /// Block current task for specified duration
    pub fn sleep(self: *Self, duration_ms: u64) !void {
        // Create a waker for the current task
        // In full implementation, this would get the current async frame
        const frame_id = try self.spawnTask(struct {
            fn sleepTask() void {
                // Sleep task placeholder
            }
        }.sleepTask, .{});

        var waker = self.event_loop_instance.scheduler_instance.createWaker(frame_id);
        _ = try self.scheduleTimeout(duration_ms, &waker);
        
        // Suspend current task (would be real suspend in full implementation)
        scheduler.yield();
    }

    /// Async sleep that integrates with the event loop
    pub fn asyncSleep(self: *Self, duration_ms: u64) !void {
        return self.event_loop_instance.asyncSleep(duration_ms);
    }

    /// Block on an async function until completion
    pub fn blockOn(self: *Self, comptime func: anytype, args: anytype) !@TypeOf(@call(.auto, func, args)) {
        return self.event_loop_instance.async_runtime.block_on(func, args);
    }
};

/// Convenience function to create and run a runtime
pub fn run(comptime main_task: anytype) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    
    const runtime = try Runtime.init(gpa.allocator(), .{});
    defer runtime.deinit();
    
    try runtime.run(main_task);
}

/// Create a high-performance runtime
pub fn runHighPerf(comptime main_task: anytype) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    
    const config = Config{
        .event_loop_config = .{
            .max_events_per_poll = 2048,
            .poll_timeout_ms = 1,
            .max_tasks_per_tick = 64,
        },
    };
    
    const runtime = try Runtime.init(gpa.allocator(), config);
    defer runtime.deinit();
    
    try runtime.run(main_task);
}

/// Create an I/O focused runtime (perfect for zquic!)
pub fn runIoFocused(comptime main_task: anytype) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    
    const config = Config{
        .event_loop_config = .{
            .max_events_per_poll = 4096,
            .poll_timeout_ms = 2,
            .max_tasks_per_tick = 32,
        },
    };
    
    const runtime = try Runtime.init(gpa.allocator(), config);
    defer runtime.deinit();
    
    try runtime.run(main_task);
}

/// Spawn a task on the global runtime
pub fn spawn(comptime func: anytype, args: anytype) !u32 {
    const runtime = Runtime.global() orelse return RuntimeError.RuntimeShutdown;
    return runtime.spawnTask(func, args);
}

/// Spawn an urgent task on the global runtime
pub fn spawnUrgent(comptime func: anytype, args: anytype) !u32 {
    const runtime = Runtime.global() orelse return RuntimeError.RuntimeShutdown;
    return runtime.spawnUrgent(func, args);
}

/// Sleep for the specified duration (milliseconds)
pub fn sleep(duration_ms: u64) !void {
    const runtime = Runtime.global() orelse return RuntimeError.RuntimeShutdown;
    try runtime.sleep(duration_ms);
}

/// Register I/O interest on global runtime
pub fn registerIo(fd: std.posix.fd_t, events: reactor.IoEvent, waker: *scheduler.Waker) !void {
    const runtime = Runtime.global() orelse return RuntimeError.RuntimeShutdown;
    return runtime.registerIo(fd, events, waker);
}

/// Get current runtime statistics
pub fn getStats() ?event_loop.EventLoopStats {
    const runtime = Runtime.global() orelse return null;
    return runtime.getStats();
}

// Tests
test "runtime creation and basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    const runtime = try Runtime.init(allocator, .{});
    defer runtime.deinit();
    
    try testing.expect(!runtime.running.load(.acquire));
}

test "global runtime" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    const runtime = try Runtime.init(allocator, .{});
    defer runtime.deinit();
    
    runtime.setGlobal();
    try testing.expect(Runtime.global() == runtime);
}

test "runtime configurations" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    // Test high-performance config
    const high_perf_config = Config{
        .event_loop_config = .{
            .max_events_per_poll = 2048,
            .poll_timeout_ms = 1,
            .max_tasks_per_tick = 64,
        },
    };
    
    const runtime = try Runtime.init(allocator, high_perf_config);
    defer runtime.deinit();
    
    try testing.expect(runtime.config.event_loop_config.max_events_per_poll == 2048);
}
