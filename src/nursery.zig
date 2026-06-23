//! zsync - Structured Concurrency Nursery
//! Safe task spawning with guaranteed cleanup, built on `std.Io.Group`.
//! All tasks spawned in a nursery are awaited (or cancelled) before the
//! nursery scope exits.

const std = @import("std");
const compat = @import("compat/thread.zig");

/// Nursery for structured concurrency - ensures all tasks complete.
///
/// Backed by `std.Io.Group`. Must not be copied after `init` (the group holds
/// internal state referenced by the backing `Io`).
pub const Nursery = struct {
    io: std.Io,
    group: std.Io.Group,
    error_mutex: compat.Mutex = .{},
    first_error: ?anyerror = null,

    const Self = @This();

    /// Create a new nursery bound to an `Io` instance.
    pub fn init(io: std.Io) Self {
        return .{ .io = io, .group = .init };
    }

    fn recordError(self: *Self, err: anyerror) void {
        self.error_mutex.lock();
        defer self.error_mutex.unlock();
        if (self.first_error == null) self.first_error = err;
    }

    fn takeError(self: *Self) ?anyerror {
        self.error_mutex.lock();
        defer self.error_mutex.unlock();
        const err = self.first_error;
        self.first_error = null;
        return err;
    }

    /// Spawn a task within this nursery. The first task error is reported by
    /// `wait()`, so errors only disappear if the caller intentionally skips
    /// observation.
    pub fn spawn(self: *Self, comptime task_fn: anytype, args: anytype) !void {
        const Return = @typeInfo(@TypeOf(task_fn)).@"fn".return_type.?;
        const Wrapper = struct {
            fn run(nursery: *Self, call_args: @TypeOf(args)) void {
                switch (@typeInfo(Return)) {
                    .error_union => {
                        _ = @call(.auto, task_fn, call_args) catch |err| {
                            nursery.recordError(err);
                            return;
                        };
                    },
                    else => _ = @call(.auto, task_fn, call_args),
                }
            }
        };
        self.group.async(self.io, Wrapper.run, .{ self, args });
    }

    /// Wait for all tasks in the nursery to complete.
    pub fn wait(self: *Self) !void {
        try self.group.await(self.io);
        if (self.takeError()) |err| return err;
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

test "nursery wait observes task error" {
    const std_runtime = @import("std_runtime.zig");
    const Shared = struct {
        var observed: bool = false;
        fn failTask() !void {
            return error.NurseryTaskFailed;
        }
        fn mainTask() void {
            const io = std_runtime.getGlobalIo().?;
            var nursery = Nursery.init(io);
            defer nursery.deinit();
            nursery.spawn(failTask, .{}) catch unreachable;
            std.testing.expectError(error.NurseryTaskFailed, nursery.wait()) catch unreachable;
            observed = true;
        }
    };
    Shared.observed = false;
    std_runtime.run(std.testing.allocator, Shared.mainTask, .{});
    try std.testing.expect(Shared.observed);
}
