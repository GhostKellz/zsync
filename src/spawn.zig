//! zsync- Task Spawning API
//! Spawn and manage async tasks on the runtime

const std = @import("std");
const runtime_mod = @import("runtime.zig");

const Runtime = runtime_mod.Runtime;

/// Handle to a spawned task
pub const TaskHandle = struct {
    id: u64,
    runtime: *Runtime,
    completed: std.atomic.Value(bool),
    result: ?TaskResult,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub const TaskResult = union(enum) {
        ok: void,
        err: anyerror,
    };

    /// Wait for the task to complete
    pub fn await(self: *Self) !void {
        // Poll until task completes
        while (!self.completed.load(.acquire)) {
            std.Thread.yield() catch {};
        }

        if (self.result) |result| {
            switch (result) {
                .ok => return,
                .err => |e| return e,
            }
        }
    }

    /// Check if task is complete without blocking
    pub fn poll(self: *Self) bool {
        return self.completed.load(.acquire);
    }

    /// Clean up task handle
    pub fn deinit(self: *Self) void {
        self.allocator.destroy(self);
    }
};

/// Spawn a task on the global runtime
pub fn spawn(comptime task_fn: anytype, args: anytype) !*TaskHandle {
    const runtime = Runtime.global() orelse return error.RuntimeNotInitialized;
    return spawnOn(runtime, task_fn, args);
}

/// Spawn a task on a specific runtime
/// Task receives args directly as passed - no automatic Io injection.
/// Aligns with Zig 0.17.0-dev std.Io async/concurrent pattern.
pub fn spawnOn(runtime: *Runtime, comptime task_fn: anytype, args: anytype) !*TaskHandle {
    const allocator = runtime.allocator;

    const handle = try allocator.create(TaskHandle);
    handle.* = TaskHandle{
        .id = generateTaskId(),
        .runtime = runtime,
        .completed = std.atomic.Value(bool).init(false),
        .result = null,
        .allocator = allocator,
    };

    // Check if we can use thread pool for async execution
    if (runtime.isThreadPoolMode()) {
        // Create task context that captures everything needed for async execution
        // This wrapper is self-owned: it frees itself after the task completes
        const TaskWrapper = struct {
            task_handle: *TaskHandle,
            task_args: @TypeOf(args),
            wrapper_allocator: std.mem.Allocator,

            fn execute(ctx: *anyopaque) void {
                const wrapper: *@This() = @ptrCast(@alignCast(ctx));
                const alloc = wrapper.wrapper_allocator;

                // Execute task and capture result
                executeTaskWrapper(task_fn, wrapper.task_args) catch |err| {
                    wrapper.task_handle.result = .{ .err = err };
                    wrapper.task_handle.completed.store(true, .release);
                    alloc.destroy(wrapper);
                    return;
                };

                wrapper.task_handle.result = .{ .ok = {} };
                wrapper.task_handle.completed.store(true, .release);
                alloc.destroy(wrapper);
            }
        };

        const wrapper = try allocator.create(TaskWrapper);
        wrapper.* = TaskWrapper{
            .task_handle = handle,
            .task_args = args,
            .wrapper_allocator = allocator,
        };

        // Submit self-owned task to thread pool
        // - The TaskWrapper frees itself after execution
        // - The thread pool frees the internal WorkItem after execution
        try runtime.submitSelfOwnedTask(&TaskWrapper.execute, wrapper);

        return handle;
    }

    // Fallback: execute synchronously on the calling thread
    // (for blocking mode or when thread pool isn't available)
    executeTaskWrapper(task_fn, args) catch |err| {
        handle.result = .{ .err = err };
        handle.completed.store(true, .release);
        return handle;
    };

    handle.result = .{ .ok = {} };
    handle.completed.store(true, .release);

    return handle;
}

/// Execute task with proper argument handling
/// Task receives args directly - no automatic Io injection.
/// Aligns with Zig 0.17.0-dev std.Io async/concurrent pattern.
fn executeTaskWrapper(comptime task_fn: anytype, args: anytype) !void {
    const TaskType = @TypeOf(task_fn);
    const task_info = @typeInfo(TaskType);

    if (task_info != .@"fn") {
        @compileError("Task must be a function");
    }

    // Call task directly with provided arguments
    return @call(.auto, task_fn, args);
}

/// Generate unique task ID
var task_id_counter = std.atomic.Value(u64).init(1);

fn generateTaskId() u64 {
    return task_id_counter.fetchAdd(1, .monotonic);
}

// Tests
test "spawn basic task" {
    const testing = std.testing;

    // Create runtime for testing
    const allocator = testing.allocator;
    const config = runtime_mod.Config{
        .execution_model = .blocking,
    };

    const rt = try Runtime.init(allocator, config);
    defer rt.deinit();

    rt.setGlobal();
    defer {
        runtime_mod.global_runtime_mutex.lock();
        runtime_mod.global_runtime = null;
        runtime_mod.global_runtime_mutex.unlock();
    }

    const TestTask = struct {
        fn task() !void {
            // Simple task that completes immediately
        }
    };

    const handle = try spawn(TestTask.task, .{});
    defer handle.deinit();

    try handle.await();
    try testing.expect(handle.poll());
}

test "spawn with thread pool" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Use thread pool execution model
    const config = runtime_mod.Config{
        .execution_model = .thread_pool,
        .thread_pool_threads = 2,
    };

    const rt = try Runtime.init(allocator, config);
    defer rt.deinit();

    rt.setGlobal();
    defer {
        runtime_mod.global_runtime_mutex.lock();
        runtime_mod.global_runtime = null;
        runtime_mod.global_runtime_mutex.unlock();
    }

    // Shared state to verify task ran
    var task_ran = std.atomic.Value(bool).init(false);

    const TestTask = struct {
        fn task(ran_flag: *std.atomic.Value(bool)) !void {
            ran_flag.store(true, .release);
        }
    };

    const handle = try spawnOn(rt, TestTask.task, .{&task_ran});
    defer handle.deinit();

    // Wait for completion
    try handle.await();

    // Verify task actually executed
    try testing.expect(task_ran.load(.acquire));
    try testing.expect(handle.poll());
}
