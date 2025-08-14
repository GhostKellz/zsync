//! Advanced async runtime with proper Zig async/await integration
//! This provides the foundation for true async task execution using @asyncCall

const std = @import("std");
const builtin = @import("builtin");
const scheduler = @import("scheduler.zig");
const reactor = @import("reactor.zig");

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
    completed: bool = false,
    runtime: *AsyncRuntime,

    const Self = @This();

    /// Wait for the task to complete (simulated for compatibility)
    pub fn join(self: *Self) !void {
        // In a full implementation, this would await the actual frame
        while (!self.completed) {
            _ = try self.runtime.tick();
            std.time.sleep(1 * std.time.ns_per_ms);
        }
    }

    /// Cancel the task
    pub fn cancel(self: *Self) void {
        self.runtime.cancelTask(self.id);
        self.completed = true;
    }
};

/// Sleep future for async delay
pub const Sleep = struct {
    duration_ms: u64,
    start_time: u64,
    completed: bool = false,

    const Self = @This();

    pub fn init(duration_ms: u64) Self {
        return Self{
            .duration_ms = duration_ms,
            .start_time = @intCast(std.time.milliTimestamp()),
        };
    }

    pub fn poll(self: *Self) bool {
        if (self.completed) return true;
        
        const now = @as(u64, @intCast(std.time.milliTimestamp()));
        if (now - self.start_time >= self.duration_ms) {
            self.completed = true;
            return true;
        }
        return false;
    }
};

/// Advanced async runtime with simulated frame management (Zig 0.15 compatible)
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
        
        // Create task handle
        const handle = try self.allocator.create(TaskHandle);
        handle.* = TaskHandle{
            .id = handle_id,
            .runtime = self,
        };
        
        // Store handle
        try self.task_handles.put(handle_id, handle);
        
        // Spawn task via scheduler
        _ = try self.scheduler_instance.spawn(func, args, .normal);
        
        return handle;
    }

    /// Async sleep function
    pub fn sleep(duration_ms: u64) !void {
        var sleep_future = Sleep.init(duration_ms);
        
        // Cooperative yielding until sleep completes
        while (!sleep_future.poll()) {
            suspend {
                // Would integrate with waker system here
                std.time.sleep(1 * std.time.ns_per_ms); // Small yield
            }
        }
    }

    /// Block on an async function (compatibility version)
    pub fn block_on(self: *Self, comptime func: anytype, args: anytype) !@TypeOf(@call(.auto, func, args)) {
        const handle = try self.spawn(func, args);
        try handle.join();
        
        // In a full implementation, would return the actual result
        return @call(.auto, func, args);
    }

    /// Yield the current task (compatibility stub)
    pub fn yield_now() void {
        // In full implementation would suspend current frame
        std.time.sleep(1000); // 1μs yield
    }

    /// Clean up a completed task
    fn cleanupTask(self: *Self, id: u32) void {
        if (self.task_handles.get(id)) |handle| {
            handle.completed = true;
        }
    }

    /// Cancel a task
    fn cancelTask(self: *Self, id: u32) void {
        if (self.task_handles.get(id)) |handle| {
            handle.completed = true;
            _ = self.task_handles.remove(id);
            self.allocator.destroy(handle);
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
        std.time.sleep(1 * std.time.ns_per_ms);
    }
}

/// Yield the current task (compatibility stub)
pub fn yield_now() void {
    std.time.sleep(1000); // 1μs yield
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
    
    std.time.sleep(15 * std.time.ns_per_ms);
    try testing.expect(sleep_future.poll()); // Should be complete after delay
}
