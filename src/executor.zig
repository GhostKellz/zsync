//! zsync - Task Executor
//! Manages a group of concurrent tasks on a `std.Io.Threaded` runtime using
//! `std.Io.Group` for structured spawn-many / join-all semantics.

const std = @import("std");
const std_runtime = @import("std_runtime.zig");

const Runtime = std_runtime.Runtime;

/// Task executor for managing multiple concurrent tasks.
///
/// Owns its own `std.Io.Threaded` runtime. Must not be copied after `init`
/// (callers hold it by stable address; `Io` userdata points into `runtime`).
pub const Executor = struct {
    runtime: Runtime,
    group: std.Io.Group,
    count: usize,
    joined: bool,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Initialize a new executor with a default runtime.
    pub fn init(allocator: std.mem.Allocator) !Self {
        return Self{
            .runtime = Runtime.init(allocator, .{}),
            .group = .init,
            .count = 0,
            .joined = false,
            .allocator = allocator,
        };
    }

    /// Initialize an executor with explicit runtime options.
    pub fn initWithOptions(allocator: std.mem.Allocator, options: std_runtime.RuntimeOptions) !Self {
        return Self{
            .runtime = Runtime.init(allocator, options),
            .group = .init,
            .count = 0,
            .joined = false,
            .allocator = allocator,
        };
    }

    /// Clean up the executor and its runtime. Cancels any un-joined tasks.
    pub fn deinit(self: *Self) void {
        if (!self.joined) self.group.cancel(self.runtime.io());
        self.runtime.deinit();
    }

    /// Spawn a task on this executor. Task errors are isolated to the task.
    pub fn spawn(self: *Self, comptime task_fn: anytype, args: anytype) !void {
        const Wrapper = struct {
            fn run(call_args: @TypeOf(args)) void {
                _ = @call(.auto, task_fn, call_args) catch {};
            }
        };
        self.group.async(self.runtime.io(), Wrapper.run, .{args});
        self.count += 1;
    }

    /// Wait for all spawned tasks to complete.
    pub fn joinAll(self: *Self) !void {
        try self.group.await(self.runtime.io());
        self.joined = true;
    }

    /// Number of tasks spawned on this executor.
    pub fn taskCount(self: *const Self) usize {
        return self.count;
    }

    /// Whether all tasks have been joined.
    pub fn allComplete(self: *const Self) bool {
        return self.joined;
    }

    /// Acquire the `Io` interface for this executor's runtime.
    pub fn io(self: *Self) std.Io {
        return self.runtime.io();
    }

    /// Borrow the underlying runtime.
    pub fn getRuntime(self: *Self) *Runtime {
        return &self.runtime;
    }
};

// Tests
test "executor spawn single task" {
    const testing = std.testing;

    var executor = try Executor.init(testing.allocator);
    defer executor.deinit();

    const TestTask = struct {
        fn task() !void {}
    };

    try executor.spawn(TestTask.task, .{});
    try testing.expectEqual(@as(usize, 1), executor.taskCount());

    try executor.joinAll();
    try testing.expect(executor.allComplete());
}

test "executor spawn multiple tasks" {
    const testing = std.testing;

    var executor = try Executor.init(testing.allocator);
    defer executor.deinit();

    const Shared = struct {
        var counter: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
        fn task() !void {
            _ = counter.fetchAdd(1, .release);
        }
    };
    Shared.counter.store(0, .release);

    try executor.spawn(Shared.task, .{});
    try executor.spawn(Shared.task, .{});
    try executor.spawn(Shared.task, .{});

    try testing.expectEqual(@as(usize, 3), executor.taskCount());

    try executor.joinAll();

    try testing.expect(executor.allComplete());
    try testing.expectEqual(@as(u32, 3), Shared.counter.load(.acquire));
}
