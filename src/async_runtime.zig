//! Advanced async runtime with proper Zig async/await integration
//! This provides the foundation for true async task execution using @asyncCall

const std = @import("std");
const builtin = @import("builtin");
const scheduler = @import("scheduler.zig");
const reactor = @import("reactor.zig");
const compat = @import("compat/thread.zig");

/// Async runtime error types
pub const AsyncError = error{
    FrameNotFound,
    InvalidFrameState,
    AsyncCallFailed,
    SuspendFailed,
    ResumeFailed,
};

/// Async task handle for managing spawned tasks (compatibility version)
pub const TaskHandle = struct {
    id: u32,
    frame_id: u32, // Scheduler frame ID for tracking completion
    completed: std.atomic.Value(bool),
    runtime: *AsyncRuntime,

    const Self = @This();

    /// Wait for the task to complete (simulated for compatibility)
    /// After join() returns, the handle is invalidated and should not be used.
    pub fn join(self: *Self) !void {
        const handle_id = self.id;
        const runtime = self.runtime;

        // Poll until task completes
        while (!self.completed.load(.acquire)) {
            _ = try runtime.tick();
            // Check if frame is still in scheduler (if not, task completed)
            runtime.checkTaskCompletion(self.frame_id, handle_id);
            compat.sleepNanos(1 * std.time.ns_per_ms);
        }

        // Clean up the handle from runtime tracking
        // After this call, self is invalid - do not access it
        runtime.removeCompletedTask(handle_id);
    }

    /// Cancel the task and mark it complete.
    pub fn cancel(self: *Self) void {
        self.runtime.cancelTask(self.id);
    }
};

/// Sleep future for async delay using monotonic time
pub const Sleep = struct {
    duration_ns: u64,
    start: compat.Instant,
    completed: bool = false,

    const Self = @This();

    pub fn init(duration_ms: u64) Self {
        return Self{
            .duration_ns = duration_ms * std.time.ns_per_ms,
            .start = compat.Instant.now() catch .{ .timestamp = 0 },
        };
    }

    pub fn poll(self: *Self) bool {
        if (self.completed) return true;

        const now_instant = compat.Instant.now() catch return false;
        const elapsed = now_instant.since(self.start);
        if (elapsed >= self.duration_ns) {
            self.completed = true;
            return true;
        }
        return false;
    }
};

/// Async runtime with cooperative task management
pub const AsyncRuntime = struct {
    allocator: std.mem.Allocator,
    scheduler_instance: scheduler.AsyncScheduler,
    task_handles: std.HashMap(u32, *TaskHandle, std.hash_map.AutoContext(u32), std.hash_map.default_max_load_percentage),
    next_handle_id: std.atomic.Value(u32),
    running: std.atomic.Value(bool),

    const Self = @This();

    /// Initialize the async runtime
    pub fn init(allocator: std.mem.Allocator) !Self {
        return Self{
            .allocator = allocator,
            .scheduler_instance = try scheduler.AsyncScheduler.init(allocator),
            .task_handles = std.HashMap(u32, *TaskHandle, std.hash_map.AutoContext(u32), std.hash_map.default_max_load_percentage).init(allocator),
            .next_handle_id = std.atomic.Value(u32).init(1),
            .running = std.atomic.Value(bool).init(false),
        };
    }

    /// Deinitialize the runtime
    pub fn deinit(self: *Self) void {
        self.scheduler_instance.deinit();

        // Clean up task handles
        var iterator = self.task_handles.iterator();
        while (iterator.next()) |entry| {
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.task_handles.deinit();
    }

    /// Spawn a task (compatibility version using scheduler)
    pub fn spawn(self: *Self, comptime func: anytype, args: anytype) !*TaskHandle {
        const handle_id = self.next_handle_id.fetchAdd(1, .monotonic);

        // Spawn task via scheduler and get frame_id
        const frame_id = try self.scheduler_instance.spawn(func, args, .normal);

        // Create task handle with frame_id for tracking
        const handle = try self.allocator.create(TaskHandle);
        handle.* = TaskHandle{
            .id = handle_id,
            .frame_id = frame_id,
            .completed = std.atomic.Value(bool).init(false),
            .runtime = self,
        };

        // Store handle
        try self.task_handles.put(handle_id, handle);

        return handle;
    }

    /// Check if a task's scheduler frame completed and mark handle accordingly
    fn checkTaskCompletion(self: *Self, frame_id: u32, handle_id: u32) void {
        // Check if frame is still in scheduler's frame pool
        self.scheduler_instance.mutex.lock();
        var found = false;
        for (self.scheduler_instance.frame_pool.items) |frame| {
            if (frame.id == frame_id) {
                found = true;
                break;
            }
        }
        self.scheduler_instance.mutex.unlock();

        // If frame not found, task completed - mark handle
        if (!found) {
            if (self.task_handles.get(handle_id)) |handle| {
                handle.completed.store(true, .release);
            }
        }
    }

    /// Async sleep function
    pub fn sleep(duration_ms: u64) !void {
        var sleep_future = Sleep.init(duration_ms);

        // Cooperative yielding until sleep completes
        while (!sleep_future.poll()) {
            suspend {
                // Would integrate with waker system here
                compat.sleepNanos(1 * std.time.ns_per_ms); // Small yield
            }
        }
    }

    /// Block on an async function - spawns task and waits for completion
    pub fn block_on(self: *Self, comptime func: anytype, args: anytype) !void {
        var handle = try self.spawn(func, args);
        try handle.join();
        // Task already executed by spawn/scheduler - don't re-execute
    }

    /// Yield the current task (compatibility stub)
    pub fn yield_now() void {
        // In full implementation would suspend current frame
        compat.sleepNanos(1000); // 1μs yield
    }

    /// Clean up a completed task (marks completed but does not remove)
    fn cleanupTask(self: *Self, id: u32) void {
        if (self.task_handles.get(id)) |handle| {
            handle.completed.store(true, .release);
        }
    }

    /// Remove a completed task from tracking and free its memory
    /// Called by TaskHandle.join() after completion is observed
    fn removeCompletedTask(self: *Self, id: u32) void {
        if (self.task_handles.fetchRemove(id)) |kv| {
            self.allocator.destroy(kv.value);
        }
    }

    /// Cancel a task without destroying the handle in-place.
    /// The handle remains owned by runtime tracking until join/deinit cleanup.
    fn cancelTask(self: *Self, id: u32) void {
        if (self.task_handles.get(id)) |handle| {
            handle.completed.store(true, .release);
        }
    }

    /// Process async runtime events
    pub fn tick(self: *Self) !u32 {
        return self.scheduler_instance.tick();
    }

    /// Check if runtime has pending work
    pub fn hasPendingWork(self: *Self) bool {
        return self.scheduler_instance.hasPendingWork() or self.task_handles.count() > 0;
    }
};

/// Global async runtime functions
pub var global_async_runtime: ?*AsyncRuntime = null;

/// Set the global async runtime
pub fn setGlobalAsyncRuntime(runtime: *AsyncRuntime) void {
    global_async_runtime = runtime;
}

/// Get the global async runtime
pub fn getGlobalAsyncRuntime() ?*AsyncRuntime {
    return global_async_runtime;
}

/// Spawn a task on the global runtime
pub fn spawn(comptime func: anytype, args: anytype) !*TaskHandle {
    if (global_async_runtime) |runtime| {
        return runtime.spawn(func, args);
    }
    return AsyncError.FrameNotFound;
}

/// Sleep on the global runtime
pub fn sleep(duration_ms: u64) !void {
    var sleep_future = Sleep.init(duration_ms);

    while (!sleep_future.poll()) {
        if (global_async_runtime) |runtime| {
            _ = try runtime.tick();
        }
        compat.sleepNanos(1 * std.time.ns_per_ms);
    }
}

/// Yield the current task (compatibility stub)
pub fn yield_now() void {
    compat.sleepNanos(1000); // 1μs yield
}

// Tests
test "async runtime creation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var runtime = try AsyncRuntime.init(allocator);
    defer runtime.deinit();

    try testing.expect(!runtime.hasPendingWork());
}

test "async sleep" {
    const testing = std.testing;

    var sleep_future = Sleep.init(10);
    try testing.expect(!sleep_future.poll()); // Should not be complete immediately

    compat.sleepNanos(15 * std.time.ns_per_ms);
    try testing.expect(sleep_future.poll()); // Should be complete after delay
}
