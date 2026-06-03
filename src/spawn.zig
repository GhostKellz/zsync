//! zsync - Task Spawning API
//! Thin wrappers over `std.Io` async task spawning. Tasks are scheduled on a
//! `std.Io` instance (typically backed by `std.Io.Threaded`) and represented by
//! a `std.Io.Future`. Await a future with `future.await(io)`.

const std = @import("std");
const std_runtime = @import("std_runtime.zig");

pub const Io = std.Io;
pub const Future = std.Io.Future;

/// Spawn a task on the process-global runtime's `Io`.
/// Returns a `std.Io.Future(Result)`; await it with `future.await(io)`.
pub fn spawn(
    comptime task_fn: anytype,
    args: anytype,
) error{RuntimeNotInitialized}!@TypeOf((std_runtime.getGlobalIo().?).async(task_fn, args)) {
    const io = std_runtime.getGlobalIo() orelse return error.RuntimeNotInitialized;
    return io.async(task_fn, args);
}

/// Spawn a task on a specific `Io`. Aligns with `std.Io.async`'s explicit-Io
/// argument pattern.
pub fn spawnOn(io: Io, comptime task_fn: anytype, args: anytype) @TypeOf(io.async(task_fn, args)) {
    return io.async(task_fn, args);
}

test "spawn on explicit io awaits a result" {
    const Work = struct {
        fn add(a: u32, b: u32) u32 {
            return a + b;
        }
        fn mainTask() void {
            const io = std_runtime.getGlobalIo().?;
            var fut = spawnOn(io, add, .{ @as(u32, 4), @as(u32, 5) });
            std.testing.expect(fut.await(io) == 9) catch unreachable;
        }
    };
    std_runtime.run(std.testing.allocator, Work.mainTask, .{});
}

test "global spawn requires an installed runtime" {
    const Work = struct {
        fn answer() u32 {
            return 42;
        }
        fn mainTask() void {
            const io = std_runtime.getGlobalIo().?;
            var fut = (spawn(answer, .{}) catch unreachable);
            std.testing.expect(fut.await(io) == 42) catch unreachable;
        }
    };
    std_runtime.run(std.testing.allocator, Work.mainTask, .{});
}
