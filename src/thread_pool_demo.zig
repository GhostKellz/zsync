//! Demo of thread pool execution model
const std = @import("std");
const zsync = @import("root.zig");

pub fn main() !void {
    std.debug.print("🚀 Zsync v0.4.0 - Thread Pool Demo\n\n", .{});
    
    // Create task that uses thread pool
    const ThreadPoolTask = struct {
        fn task(io: zsync.Io) !void {
            std.debug.print("✨ Thread pool async in action!\n", .{});
            std.debug.print("Execution mode: {}\n", .{io.getMode()});
            
            // Test concurrent writes
            var io_mut = io;
            
            std.debug.print("Submitting parallel tasks...\n", .{});
            
            var future1 = try io_mut.write("[Task 1] ");
            defer future1.destroy(io.getAllocator());
            
            var future2 = try io_mut.write("[Task 2] ");
            defer future2.destroy(io.getAllocator());
            
            var future3 = try io_mut.write("[Task 3] ");
            defer future3.destroy(io.getAllocator());
            
            // Wait for all to complete
            try future1.await();
            try future2.await();
            try future3.await();
            
            std.debug.print("\nAll tasks completed!\n", .{});
        }
    };
    
    // Run with automatic model detection (should use thread pool)
    const config = zsync.Config{
        .execution_model = .thread_pool,
        .thread_pool_threads = 4,
        .enable_debugging = true,
    };
    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    
    const runtime = try zsync.Runtime.init(gpa.allocator(), config);
    defer runtime.deinit();
    
    try runtime.run(ThreadPoolTask.task, {});
    
    std.debug.print("\n🎉 Thread pool demo completed!\n", .{});
}