//! zsync Simple Demo
//! Showcasing the core functionality on top of std.Io

const std = @import("std");
const Zsync = @import("zsync");

pub fn main() !void {
    std.debug.print("zsync v{s} - async runtime for Zig\n\n", .{Zsync.VERSION});

    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();

    const DemoTask = struct {
        fn add(a: u32, b: u32) u32 {
            return a + b;
        }
        fn task() void {
            std.debug.print("colorblind async in action\n", .{});

            // Acquire Io explicitly - no magic injection.
            const io = Zsync.getGlobalIo() orelse return;

            // Spawn a task and await its result.
            var future = io.async(add, .{ @as(u32, 40), @as(u32, 2) });
            const sum = future.await(io);
            std.debug.print("spawned task result: {d}\n", .{sum});
        }
    };

    Zsync.run(gpa.allocator(), DemoTask.task, .{});

    std.debug.print("\nDemo completed successfully!\n", .{});
}

test "simple zsync test" {
    const TestTask = struct {
        fn answer() u32 {
            return 42;
        }
        fn task() void {
            const io = Zsync.getGlobalIo().?;
            var future = io.async(answer, .{});
            std.testing.expectEqual(@as(u32, 42), future.await(io)) catch unreachable;
        }
    };

    Zsync.run(std.testing.allocator, TestTask.task, .{});
}
