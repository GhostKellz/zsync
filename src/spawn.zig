//! zsync- Task Spawning API
//! Spawn and manage async tasks on the runtime

const std = @import("std");
const runtime_mod = @import("runtime.zig");
const io_interface = @import("io_interface.zig");

const Runtime = runtime_mod.Runtime;
const Io = io_interface.Io;

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

/// Task context passed to spawned tasks
const TaskContext = struct {
    handle: *TaskHandle,
    io: Io,
    allocator: std.mem.Allocator,
};

/// Spawn a task on the global runtime
pub fn spawn(comptime task_fn: anytype, args: anytype) !*TaskHandle {
    const runtime = Runtime.global() orelse return error.RuntimeNotInitialized;
    return spawnOn(runtime, task_fn, args);
}

/// Spawn a task on a specific runtime
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

    // For now, execute synchronously on the calling thread
    // TODO: Implement true async spawning with thread pool integration
    const io = runtime.getIo();

    // Execute task and capture result
    const result = executeTaskWrapper(task_fn, args, io) catch |err| {
        handle.result = .{ .err = err };
        handle.completed.store(true, .release);
        return handle;
    };

    _ = result;
    handle.result = .{ .ok = {} };
    handle.completed.store(true, .release);

    return handle;
}

/// Execute task with proper argument handling
fn executeTaskWrapper(comptime task_fn: anytype, args: anytype, io: Io) !void {
    const TaskType = @TypeOf(task_fn);
    const task_info = @typeInfo(TaskType);

    if (task_info != .@"fn") {
        @compileError("Task must be a function");
    }

    // Call task with appropriate arguments
    return switch (@typeInfo(@TypeOf(args))) {
        .@"struct" => |struct_info| blk: {
            if (struct_info.fields.len == 0) {
                // No args, just pass io
                break :blk task_fn(io);
            } else {
                // Pass io + args
                break :blk @call(.auto, task_fn, .{io} ++ args);
            }
        },
        .void => task_fn(io),
        else => task_fn(io, args),
    };
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
        fn task(_: Io) !void {
            // Simple task that completes immediately
        }
    };

    const handle = try spawn(TestTask.task, .{});
    defer handle.deinit();

    try handle.await();
    try testing.expect(handle.poll());
}
