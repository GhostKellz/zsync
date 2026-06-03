//! zsync - Structured Concurrency Nursery
//! Safe task spawning with guaranteed cleanup, built on `std.Io.Group`.
//! All tasks spawned in a nursery are awaited (or cancelled) before the
//! nursery scope exits.

const std = @import("std");

/// Nursery for structured concurrency - ensures all tasks complete.
///
/// Backed by `std.Io.Group`. Must not be copied after `init` (the group holds
/// internal state referenced by the backing `Io`).
pub const Nursery = struct {
    io: std.Io,
    group: std.Io.Group,

    const Self = @This();

    /// Create a new nursery bound to an `Io` instance.
    pub fn init(io: std.Io) Self {
        return .{ .io = io, .group = .init };
    }

    /// Spawn a task within this nursery. Task errors are isolated to the task;
    /// use a shared result slot if you need to observe them.
    pub fn spawn(self: *Self, comptime task_fn: anytype, args: anytype) !void {
        const Wrapper = struct {
            fn run(call_args: @TypeOf(args)) void {
                _ = @call(.auto, task_fn, call_args) catch {};
            }
        };
        self.group.async(self.io, Wrapper.run, .{args});
    }

    /// Wait for all tasks in the nursery to complete.
    pub fn wait(self: *Self) !void {
        try self.group.await(self.io);
    }

    /// Request cancellation of all tasks and wait for them to unwind.
    pub fn cancelAll(self: *Self) void {
        self.group.cancel(self.io);
    }

    /// Clean up the nursery, cancelling any tasks that were not awaited.
    pub fn deinit(self: *Self) void {
        self.group.cancel(self.io);
    }
};

/// Helper that creates a nursery, runs `func` with it, then awaits all tasks
/// (RAII pattern). `func` receives `*Nursery` as its first argument.
pub fn withNursery(io: std.Io, comptime func: anytype, args: anytype) !void {
    var nursery = Nursery.init(io);
    defer nursery.deinit();

    try @call(.auto, func, .{&nursery} ++ args);

    try nursery.wait();
}

// Tests
test "nursery basic spawn and wait" {
    const std_runtime = @import("std_runtime.zig");
    const Shared = struct {
        var ran: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
        fn task() !void {
            _ = ran.fetchAdd(1, .release);
        }
        fn mainTask() void {
            const io = std_runtime.getGlobalIo().?;
            var nursery = Nursery.init(io);
            defer nursery.deinit();
            nursery.spawn(task, .{}) catch unreachable;
            nursery.spawn(task, .{}) catch unreachable;
            nursery.wait() catch unreachable;
        }
    };
    Shared.ran.store(0, .release);
    std_runtime.run(std.testing.allocator, Shared.mainTask, .{});
    try std.testing.expectEqual(@as(u32, 2), Shared.ran.load(.acquire));
}

test "nursery with RAII pattern" {
    const std_runtime = @import("std_runtime.zig");
    const Shared = struct {
        var ran: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
        fn task() !void {
            _ = ran.fetchAdd(1, .release);
        }
        fn runTasks(n: *Nursery) !void {
            try n.spawn(task, .{});
            try n.spawn(task, .{});
            try n.spawn(task, .{});
        }
        fn mainTask() void {
            const io = std_runtime.getGlobalIo().?;
            withNursery(io, runTasks, .{}) catch unreachable;
        }
    };
    Shared.ran.store(0, .release);
    std_runtime.run(std.testing.allocator, Shared.mainTask, .{});
    try std.testing.expectEqual(@as(u32, 3), Shared.ran.load(.acquire));
}
