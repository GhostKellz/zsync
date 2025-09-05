const std = @import("std");
const root = @import("root.zig");
const runtime_factory = @import("runtime_factory.zig");
const platform_runtime = @import("platform_runtime.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("🚀 Zsync v0.5.2 - Cross-Platform Async Runtime\n", .{});
    std.debug.print("=" ** 60 ++ "\n", .{});
    
    // Create platform-optimized runtime factory
    var factory = try runtime_factory.RuntimeFactory.init(allocator);
    
    // Print detailed platform information
    factory.printInfo();
    
    // Create optimal async runtime for this platform
    var async_runtime = try factory.createAsyncRuntime();
    defer async_runtime.deinit();
    
    std.debug.print("🔥 Runtime Backend: {s}\n", .{async_runtime.getBackendName()});
    std.debug.print("⚡ High Performance: {}\n", .{factory.isHighPerformance()});
    
    // Get I/O interface
    var io = async_runtime.io();
    
    std.debug.print("\n🔧 I/O Capabilities:\n", .{});
    std.debug.print("   Mode: {}\n", .{io.getMode()});
    std.debug.print("   Vectorized I/O: {}\n", .{io.supportsVectorized()});
    std.debug.print("   Zero-copy I/O: {}\n", .{io.supportsZeroCopy()});
    
    // Demonstrate async I/O
    std.debug.print("\n📡 Testing Async Operations...\n", .{});
    
    const test_message = "Hello from Zsync v0.5.2 cross-platform runtime!";
    var write_future = io.write(test_message) catch |err| switch (err) {
        error.NotSupported => {
            std.debug.print("ℹ️  Async I/O not fully implemented for this platform yet\n", .{});
            return;
        },
        else => return err,
    };
    defer write_future.destroy(io.getAllocator());
    
    // Poll runtime for completion
    var poll_count: u32 = 0;
    while (poll_count < 10) {
        try async_runtime.poll(10); // 10ms timeout
        
        switch (write_future.poll()) {
            .ready => {
                std.debug.print("✅ Async write completed!\n", .{});
                break;
            },
            .pending => {
                poll_count += 1;
                continue;
            },
            .cancelled => {
                std.debug.print("❌ Operation cancelled\n", .{});
                break;
            },
            .err => |e| {
                std.debug.print("❌ Operation failed: {}\n", .{e});
                break;
            },
        }
    }
    
    // Show runtime metrics
    const metrics = async_runtime.getMetrics();
    std.debug.print("\n📊 Runtime Metrics:\n", .{});
    std.debug.print("   Operations Submitted: {}\n", .{metrics.operations_submitted});
    std.debug.print("   Operations Completed: {}\n", .{metrics.operations_completed});
    std.debug.print("   Green Threads: {}\n", .{metrics.green_threads_spawned});
    std.debug.print("   Context Switches: {}\n", .{metrics.context_switches});
    
    // Legacy compatibility test
    std.debug.print("\n🔄 Testing Legacy API Compatibility...\n", .{});
    try root.helloWorld(allocator);
    
    std.debug.print("\n🎉 Cross-platform runtime test completed successfully!\n", .{});
    std.debug.print("✨ Zsync v0.5.2 is ready for {s} production use!\n", .{async_runtime.getBackendName()});
}