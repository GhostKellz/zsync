//! zsync - Structured Concurrency Nursery
//! Safe task spawning with guaranteed cleanup (inspired by Trio/Tokio JoinSet)

const std = @import("std");
const io_interface = @import("io_interface.zig");
const runtime_mod = @import("runtime.zig");

const Future = io_interface.Future;
const Runtime = runtime_mod.Runtime;

/// Nursery for structured concurrency - ensures all tasks complete
pub const Nursery = struct {
    runtime: *Runtime,
    tasks: std.ArrayList(TaskEntry),
    mutex: std.Thread.Mutex,
    completed_count: std.atomic.Value(usize),
    total_count: usize,
    allocator: std.mem.Allocator,
    cancelled: std.atomic.Value(bool),

    const Self = @This();

    const TaskEntry = struct {
        future: Future,
        completed: std.atomic.Value(bool),
        result: ?anyerror,
    };

    /// Create a new nursery for managing tasks
    pub fn init(allocator: std.mem.Allocator, runtime: *Runtime) !*Self {
        const self = try allocator.create(Self);
        self.* = Self{
            .runtime = runtime,
            .tasks = .{},
            .mutex = .{},
            .completed_count = std.atomic.Value(usize).init(0),
            .total_count = 0,
            .allocator = allocator,
            .cancelled = std.atomic.Value(bool).init(false),
        };
        return self;
    }

    /// Spawn a task within this nursery
    pub fn spawn(self: *Self, comptime task_fn: anytype, args: anytype) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.cancelled.load(.acquire)) {
            return error.NurseryCancelled;
        }

        // Spawn task on the runtime
        const future = try self.runtime.spawn(task_fn, args);

        // Add to our task list
        try self.tasks.append(self.allocator, .{
            .future = future,
            .completed = std.atomic.Value(bool).init(false),
            .result = null,
        });
        self.total_count += 1;
    }

    /// Wait for all tasks in the nursery to complete
    pub fn wait(self: *Self) !void {
        // Poll all tasks until complete
        while (self.completed_count.load(.acquire) < self.total_count) {
            self.mutex.lock();
            const tasks_snapshot = self.tasks.items;
            self.mutex.unlock();

            for (tasks_snapshot, 0..) |*entry, i| {
                if (entry.completed.load(.acquire)) continue;

                // Poll the future
                switch (entry.future.poll()) {
                    .ready => {
                        entry.completed.store(true, .release);
                        _ = self.completed_count.fetchAdd(1, .release);
                    },
                    .err => |e| {
                        entry.completed.store(true, .release);
                        entry.result = e;
                        _ = self.completed_count.fetchAdd(1, .release);

                        // Cancel all other tasks on error
                        self.cancelAll();
                        return e;
                    },
                    .cancelled => {
                        entry.completed.store(true, .release);
                        _ = self.completed_count.fetchAdd(1, .release);
                    },
                    .pending => {},
                }
                _ = i;
            }

            // Small yield to avoid busy-waiting
            std.posix.nanosleep(0, 100_000); // 100μs
        }

        // Check if any task failed
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.tasks.items) |entry| {
            if (entry.result) |err| {
                return err;
            }
        }
    }

    /// Cancel all tasks in the nursery
    pub fn cancelAll(self: *Self) void {
        self.cancelled.store(true, .release);

        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.tasks.items) |*entry| {
            entry.future.cancel();
            entry.completed.store(true, .release);
        }
        self.completed_count.store(self.total_count, .release);
    }

    /// Clean up nursery resources
    pub fn deinit(self: *Self) void {
        // Cancel any remaining tasks
        if (self.completed_count.load(.acquire) < self.total_count) {
            self.cancelAll();
        }

        self.mutex.lock();

        // Destroy futures
        for (self.tasks.items) |*entry| {
            entry.future.vtable.destroy(entry.future.context, self.allocator);
        }

        self.tasks.deinit(self.allocator);

        // Unlock before destroying self to avoid use-after-free
        self.mutex.unlock();

        const allocator = self.allocator;
        allocator.destroy(self);
    }

    /// Get number of tasks still running
    pub fn pendingCount(self: *Self) usize {
        return self.total_count - self.completed_count.load(.acquire);
    }

    /// Check if all tasks are complete
    pub fn isComplete(self: *Self) bool {
        return self.completed_count.load(.acquire) >= self.total_count;
    }
};

/// Helper function to create a nursery and run code with it (RAII pattern)
pub fn withNursery(
    allocator: std.mem.Allocator,
    runtime: *Runtime,
    comptime func: anytype,
    args: anytype,
) !void {
    const nursery = try Nursery.init(allocator, runtime);
    defer nursery.deinit();

    // Call user function with nursery
    try @call(.auto, func, .{nursery} ++ args);

    // Automatically wait for all tasks
    try nursery.wait();
}

// Tests
test "nursery basic spawn and wait" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create runtime
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

    // Create nursery
    const nursery = try Nursery.init(allocator, rt);
    defer nursery.deinit();

    // Spawn some tasks
    const Task = struct {
        fn task1() !void {
            std.posix.nanosleep(0, 10_000_000); // 10ms
        }
        fn task2() !void {
            std.posix.nanosleep(0, 5_000_000); // 5ms
        }
    };

    try nursery.spawn(Task.task1, .{});
    try nursery.spawn(Task.task2, .{});

    // Wait for completion
    try nursery.wait();

    try testing.expect(nursery.isComplete());
}

test "nursery with RAII pattern" {
    const testing = std.testing;
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

    const TestFunc = struct {
        fn runTasks(n: *Nursery) !void {
            const Task = struct {
                fn task() !void {
                    std.posix.nanosleep(0, 1_000_000); // 1ms
                }
            };

            try n.spawn(Task.task, .{});
            try n.spawn(Task.task, .{});
            try n.spawn(Task.task, .{});
        }
    };

    // All tasks will complete before withNursery returns
    try withNursery(allocator, rt, TestFunc.runTasks, .{});
}
