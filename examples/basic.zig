//! zsync Basic Example
//! Demonstrates basic runtime usage and colorblind async on top of std.Io

const std = @import("std");
const zsync = @import("zsync");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();

    std.debug.print("zsync v{s} - Basic Example\n", .{zsync.VERSION});
    std.debug.print("=============================\n\n", .{});

    const Demo = struct {
        fn greet(id: u32) u32 {
            std.debug.print("  task {d}: colorblind async in action\n", .{id});
            return id * id;
        }

        fn task() void {
            // Acquire the Io interface installed by zsync.run - no magic injection.
            const io = zsync.getGlobalIo() orelse return;

            std.debug.print("Spawning concurrent tasks...\n", .{});

            // Same code path works whether the backend runs sync or async.
            var f0 = io.async(greet, .{@as(u32, 1)});
            var f1 = io.async(greet, .{@as(u32, 2)});
            var f2 = io.async(greet, .{@as(u32, 3)});

            const r0 = f0.await(io);
            const r1 = f1.await(io);
            const r2 = f2.await(io);

            std.debug.print("\nResults: {d}, {d}, {d}\n", .{ r0, r1, r2 });
        }
    };

    zsync.run(gpa.allocator(), Demo.task, .{});

    std.debug.print("\nDone!\n", .{});
}
