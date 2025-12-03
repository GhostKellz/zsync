//! zsync- Simple Demo
//! Showcasing the core functionality without complex features

const std = @import("std");
const Zsync = @import("zsync");

pub fn main() !void {
    std.debug.print("🚀 zsync - The Tokio of Zig\n\n", .{});
    
    // Simple demo task
    const DemoTask = struct {
        fn task(io: Zsync.Io) !void {
            std.debug.print("✨ Colorblind async in action!\n", .{});
            
            // This code works in ANY execution model!
            var io_mut = io;
            var future = try io_mut.write("Hello from zsync!\n");
            defer future.destroy(std.heap.page_allocator);
            
            try future.await();
            
            std.debug.print("Execution mode: {}\n", .{io.getMode()});
            std.debug.print("Supports vectorized I/O: {}\n", .{io.supportsVectorized()});
            std.debug.print("Supports zero-copy: {}\n", .{io.supportsZeroCopy()});
        }
    };
    
    // Run with blocking I/O
    try Zsync.runBlocking(DemoTask.task, {});
    
    std.debug.print("\n🎉 Demo completed successfully!\n");
    std.debug.print("The future of Zig async programming is here! 🚀\n");
}

test "simple zsync test" {
    const testing = std.testing;
    
    const TestTask = struct {
        fn task(io: Zsync.Io) !void {
            var io_mut = io;
            var future = try io_mut.write("Test passed!");
            defer future.destroy(testing.allocator);
            try future.await();
        }
    };
    
    try Zsync.runBlocking(TestTask.task, {});
}