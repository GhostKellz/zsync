//! zsync- Task Executor
//! Executor for managing and coordinating multiple async tasks

const std = @import("std");
const runtime_mod = @import("runtime.zig");
const spawn_mod = @import("spawn.zig");
const future_mod = @import("future.zig");

const Runtime = runtime_mod.Runtime;
const TaskHandle = spawn_mod.TaskHandle;
const Future = future_mod.Future;

/// Task executor for managing multiple tasks
pub const Executor = struct {
    runtime: *Runtime,
    tasks: std.ArrayList(*TaskHandle),
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Initialize a new executor
    pub fn init(allocator: std.mem.Allocator) !Self {
        const config = runtime_mod.Config{
            .execution_model = .auto,
            .enable_metrics = false,
        };

        const runtime = try Runtime.init(allocator, config);

        return Self{
            .runtime = runtime,
            .tasks = std.ArrayList(*TaskHandle){},
            .allocator = allocator,
        };
    }

    /// Initialize executor with custom configuration
    pub fn initWithConfig(allocator: std.mem.Allocator, config: runtime_mod.Config) !Self {
        const runtime = try Runtime.init(allocator, config);

        return Self{
            .runtime = runtime,
            .tasks = std.ArrayList(*TaskHandle){},
            .allocator = allocator,
        };
    }

    /// Clean up executor and all tasks
    pub fn deinit(self: *Self) void {
        // Clean up all task handles
        for (self.tasks.items) |task| {
            task.deinit();
        }
        self.tasks.deinit(self.allocator);

        // Clean up runtime
        self.runtime.deinit();
    }

    /// Spawn a task on this executor
    pub fn spawn(self: *Self, comptime task_fn: anytype, args: anytype) !*TaskHandle {
        const handle = try spawn_mod.spawnOn(self.runtime, task_fn, args);
        try self.tasks.append(self.allocator, handle);
        return handle;
    }

    /// Wait for all spawned tasks to complete
    pub fn joinAll(self: *Self) !void {
        for (self.tasks.items) |task| {
            try task.await();
        }
    }

    /// Get number of tasks managed by this executor
    pub fn taskCount(self: *Self) usize {
        return self.tasks.items.len;
    }

    /// Check if all tasks are complete
    pub fn allComplete(self: *Self) bool {
        for (self.tasks.items) |task| {
            if (!task.poll()) {
                return false;
            }
        }
        return true;
    }

    /// Get the runtime used by this executor
    pub fn getRuntime(self: *Self) *Runtime {
        return self.runtime;
    }
};

// Tests
test "executor spawn single task" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var executor = try Executor.init(allocator);
    defer executor.deinit();

    executor.runtime.setGlobal();
    defer {
        runtime_mod.global_runtime_mutex.lock();
        runtime_mod.global_runtime = null;
        runtime_mod.global_runtime_mutex.unlock();
    }

    const TestTask = struct {
        fn task(_: runtime_mod.Io) !void {
            // Simple task
        }
    };

    _ = try executor.spawn(TestTask.task, .{});

    try testing.expectEqual(1, executor.taskCount());

    try executor.joinAll();

    try testing.expect(executor.allComplete());
}

test "executor spawn multiple tasks" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var executor = try Executor.init(allocator);
    defer executor.deinit();

    executor.runtime.setGlobal();
    defer {
        runtime_mod.global_runtime_mutex.lock();
        runtime_mod.global_runtime = null;
        runtime_mod.global_runtime_mutex.unlock();
    }

    const TestTask = struct {
        fn task(_: runtime_mod.Io) !void {
            // Simple task
        }
    };

    _ = try executor.spawn(TestTask.task, .{});
    _ = try executor.spawn(TestTask.task, .{});
    _ = try executor.spawn(TestTask.task, .{});

    try testing.expectEqual(3, executor.taskCount());

    try executor.joinAll();

    try testing.expect(executor.allComplete());
}
