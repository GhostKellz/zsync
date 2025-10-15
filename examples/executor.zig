//! Example: Executor for Managing Multiple Tasks
//! Shows how to use the Executor to spawn and coordinate tasks

const std = @import("std");
const zsync = @import("zsync");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n⚡ Zsync v0.6.0 - Executor Example\n\n", .{});

    // Create executor
    var executor = try zsync.Executor.init(allocator);
    defer executor.deinit();

    // Set as global runtime
    executor.runtime.setGlobal();
    defer {
        zsync.runtime.global_runtime_mutex.lock();
        zsync.runtime.global_runtime = null;
        zsync.runtime.global_runtime_mutex.unlock();
    }

    // Define tasks
    const Task1 = struct {
        fn task(_: zsync.Io) !void {
            std.debug.print("  Task 1: Starting...\n", .{});
            std.debug.print("  Task 1: Complete!\n", .{});
        }
    };

    const Task2 = struct {
        fn task(_: zsync.Io) !void {
            std.debug.print("  Task 2: Starting...\n", .{});
            std.debug.print("  Task 2: Complete!\n", .{});
        }
    };

    const Task3 = struct {
        fn task(_: zsync.Io) !void {
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

    std.debug.print("\n✅ All {} tasks completed!\n\n", .{executor.taskCount()});
}
