//! Tokio-style task facade over `std.Io`.

const std = @import("std");

pub const runtime = @import("std_runtime.zig");
pub const spawn_mod = @import("spawn.zig");
pub const nursery_mod = @import("nursery.zig");
pub const join_set_mod = @import("join_set.zig");

pub const Io = std.Io;
pub const Future = std.Io.Future;
pub const Group = std.Io.Group;
pub const Runtime = runtime.Runtime;
pub const RuntimeOptions = runtime.RuntimeOptions;
pub const Nursery = nursery_mod.Nursery;
pub const JoinSet = join_set_mod.JoinSet;

pub const run = runtime.run;
pub const getGlobalIo = runtime.getGlobalIo;
pub const setGlobalIo = runtime.setGlobalIo;
pub const clearGlobalIo = runtime.clearGlobalIo;
pub const spawn = spawn_mod.spawn;
pub const spawnOn = spawn_mod.spawnOn;
pub const withNursery = nursery_mod.withNursery;

/// Spawn blocking work on an OS thread. This is intentionally separate from
/// `std.Io` task spawning so callers do not accidentally block runtime workers.
pub fn spawnBlocking(comptime func: anytype, args: anytype) !std.Thread {
    return std.Thread.spawn(.{}, func, args);
}

/// Abort helper for a `std.Io.Future`. Kept as a tiny facade so downstream code
/// can use a Tokio-like name while std owns the future implementation.
pub fn abort(io: Io, future: anytype) !void {
    try future.cancel(io);
}

test "task facade spawnOn awaits result" {
    const Work = struct {
        fn add(a: u32, b: u32) u32 {
            return a + b;
        }
        fn mainTask() void {
            const io = getGlobalIo().?;
            var fut = spawnOn(io, add, .{ @as(u32, 8), @as(u32, 13) });
            std.testing.expect(fut.await(io) == 21) catch unreachable;
        }
    };
    run(std.testing.allocator, Work.mainTask, .{});
}
