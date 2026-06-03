//! Example: Basic Task Spawning
//! Shows how to spawn and await tasks with zsync on top of std.Io

const std = @import("std");
const zsync = @import("zsync");

fn compute(label: []const u8, x: u32) u32 {
    std.debug.print("  {s}: computing...\n", .{label});
    return x * x;
}

fn task() void {
    const io = zsync.getGlobalIo() orelse return;

    // spawnOn spawns on an explicit Io and returns a std.Io.Future.
    var f1 = zsync.spawnOn(io, compute, .{ "task 1", @as(u32, 6) });
    var f2 = zsync.spawnOn(io, compute, .{ "task 2", @as(u32, 7) });

    std.debug.print("Waiting for tasks to complete...\n", .{});
    const r1 = f1.await(io);
    const r2 = f2.await(io);
    std.debug.print("Results: {d}, {d}\n", .{ r1, r2 });
}

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();

    std.debug.print("\nZsync v{s} - Task Spawning Example\n\n", .{zsync.VERSION});

    zsync.run(debug_allocator.allocator(), task, .{});

    std.debug.print("\nDone!\n", .{});
}
