//! Example: Basic Task Spawning
//! Shows how to spawn and await tasks with zsync v0.6.0

const std = @import("std");
const zsync = @import("zsync");

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    std.debug.print("\n🚀 Zsync v0.6.0 - Task Spawning Example\n\n", .{});

    // Initialize global runtime
    const config = zsync.Config.optimal();
    try zsync.initGlobalRuntime(allocator, config);
    defer zsync.deinitGlobalRuntime();

    // Spawn a simple task
    const TestTask = struct {
        fn task(_: zsync.Io) !void {
            std.debug.print("✓ Task 1 executing...\n", .{});
        }
    };

    const handle = try zsync.spawnTask(TestTask.task, .{});
    defer handle.deinit();

    std.debug.print("⏳ Waiting for task to complete...\n", .{});
    try handle.await();
    std.debug.print("✅ Task completed!\n\n", .{});
}
