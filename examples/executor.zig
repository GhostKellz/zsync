//! Example: Executor for Managing Multiple Tasks
//! Shows how to use the Executor to spawn and coordinate tasks

const std = @import("std");
const zsync = @import("zsync");

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    std.debug.print("\nZsync v{s} - Executor Example\n\n", .{zsync.VERSION});

    // Create executor (owns its own std.Io.Threaded-backed runtime)
    var executor = try zsync.Executor.init(allocator);
    defer executor.deinit();

    // Define tasks
    const Task1 = struct {
        fn task() !void {
            std.debug.print("  Task 1: Starting...\n", .{});
            std.debug.print("  Task 1: Complete!\n", .{});
        }
    };

    const Task2 = struct {
        fn task() !void {
            std.debug.print("  Task 2: Starting...\n", .{});
            std.debug.print("  Task 2: Complete!\n", .{});
        }
    };

    const Task3 = struct {
        fn task() !void {
            std.debug.print("  Task 3: Starting...\n", .{});
            std.debug.print("  Task 3: Complete!\n", .{});
        }
    };

    // Spawn multiple tasks
    std.debug.print("Spawning 3 tasks...\n", .{});
    _ = try executor.spawn(Task1.task, .{});
    _ = try executor.spawn(Task2.task, .{});
    _ = try executor.spawn(Task3.task, .{});

    std.debug.print("Total tasks: {}\n\n", .{executor.taskCount()});

    // Wait for all to complete
    std.debug.print("Waiting for all tasks to complete...\n", .{});
    try executor.joinAll();

    std.debug.print("\nAll {} tasks completed!\n\n", .{executor.taskCount()});
}
