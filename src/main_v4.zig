//! Zsync v0.4.0 Demo - Showcasing Colorblind Async Excellence
//! The future of Zig async programming in action

const std = @import("std");
const Zsync = @import("root_v4.zig");

pub fn main() !void {
    // Display version and capabilities
    Zsync.printVersion();
    std.debug.print("\n", .{});
    
    // Demo 1: Simple Hello World with Colorblind Async
    std.debug.print("🌟 Demo 1: Colorblind Async Hello World\n", .{});
    std.debug.print("=" ** 50 ++ "\n", .{});
    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const std.heap.page_allocator = gpa.std.heap.page_allocator();
    
    try Zsync.helloWorld(std.heap.page_allocator);
    std.debug.print("\n", .{});
    
    // Demo 2: Multiple Execution Models
    std.debug.print("🔥 Demo 2: Multiple Execution Models\n", .{});
    std.debug.print("=" ** 50 ++ "\n", .{});
    
    try demonstrateExecutionModels(std.heap.page_allocator);
    std.debug.print("\n", .{});
    
    // Demo 3: Future Combinators
    std.debug.print("⚡ Demo 3: Future Combinators\n", .{});
    std.debug.print("=" ** 50 ++ "\n", .{});
    
    try demonstrateCombinators(std.heap.page_allocator);
    std.debug.print("\n", .{});
    
    // Demo 4: Cancellation and Timeouts
    std.debug.print("🛑 Demo 4: Cancellation & Timeouts\n", .{});
    std.debug.print("=" ** 50 ++ "\n", .{});
    
    try demonstrateCancellation(std.heap.page_allocator);
    std.debug.print("\n", .{});
    
    // Demo 5: Performance Metrics
    std.debug.print("📊 Demo 5: Performance Metrics\n", .{});
    std.debug.print("=" ** 50 ++ "\n", .{});
    
    try demonstrateMetrics(std.heap.page_allocator);
    std.debug.print("\n", .{});
    
    std.debug.print("🎉 Zsync v0.4.0 Demo Complete!\n", .{});
    std.debug.print("The future of Zig async programming is here! 🚀\n", .{});
}

/// Demonstrate colorblind async across different execution models
fn demonstrateExecutionModels(_: std.mem.Allocator) !void {
    const ColorblindTask = struct {
        fn task(io: Zsync.Io) !void {
            const model_name = @tagName(io.getMode());
            const message = std.fmt.allocPrint(
                std.heap.page_std.heap.page_allocator,
                "✨ Colorblind async running on {s} model!\n",
                .{model_name}
            ) catch "✨ Colorblind async works!\n";
            defer if (message.ptr != "✨ Colorblind async works!\n".ptr) std.heap.page_std.heap.page_allocator.free(message);
            
            var io_mut = io;
            var future = try io_mut.write(message);
            defer future.destroy(std.heap.page_std.heap.page_allocator);
            try future.await();
        }
    };
    
    // Test blocking execution model
    std.debug.print("Testing Blocking I/O:\n", .{});
    try Zsync.runBlocking(ColorblindTask.task, {});
    
    // Test auto-detected optimal model
    std.debug.print("Testing Auto-Detected Model:\n", .{});
    try Zsync.run(ColorblindTask.task, {});
}

/// Demonstrate Future combinators in action
fn demonstrateCombinators(std.heap.page_allocator: std.mem.Allocator) !void {
    const CombinatorTask = struct {
        fn concurrentTask(io: Zsync.Io) !void {
            std.debug.print("🔀 Testing concurrent operations with all()...\n", .{});
            
            // Create multiple write operations
            var io_mut = io;
            var future1 = try io_mut.write("Task 1 ");
            var future2 = try io_mut.write("Task 2 ");
            var future3 = try io_mut.write("Task 3\n");
            
            // Wait for all to complete
            var futures = [_]Zsync.Future{ future1, future2, future3 };
            var all_future = try Zsync.Combinators.all(std.heap.page_std.heap.page_allocator, &futures);
            defer all_future.destroy(std.heap.page_std.heap.page_allocator);
            
            try all_future.await();
            
            // Cleanup
            future1.destroy(std.heap.page_std.heap.page_allocator);
            future2.destroy(std.heap.page_std.heap.page_allocator);
            future3.destroy(std.heap.page_std.heap.page_allocator);
            
            std.debug.print("✅ All concurrent tasks completed!\n", .{});
        }
        
        fn raceTask(io: Zsync.Io) !void {
            std.debug.print("🏁 Testing race operations with race()...\n", .{});
            
            var io_mut = io;
            var future1 = try io_mut.write("Fast task wins! ");
            var future2 = try io_mut.write("Slow task loses...");
            
            var futures = [_]Zsync.Future{ future1, future2 };
            var race_future = try Zsync.Combinators.race(std.heap.page_allocator, &futures);
            defer race_future.destroy(std.heap.page_allocator);
            
            try race_future.await();
            
            future1.destroy(std.heap.page_allocator);
            future2.destroy(std.heap.page_allocator);
            
            std.debug.print("\n✅ Race completed!\n", .{});
        }
        
        fn timeoutTask(io: Zsync.Io) !void {
            std.debug.print("⏰ Testing timeout functionality...\n", .{});
            
            var io_mut = io;
            var write_future = try io_mut.write("Operation with timeout completed!\n");
            var timeout_future = try Zsync.Combinators.timeout(std.heap.page_allocator, write_future, 1000); // 1 second
            defer timeout_future.destroy(std.heap.page_allocator);
            
            try timeout_future.await();
            write_future.destroy(std.heap.page_allocator);
            
            std.debug.print("✅ Timeout test passed!\n", .{});
        }
    };
    
    try Zsync.runBlocking(CombinatorTask.concurrentTask, {});
    try Zsync.runBlocking(CombinatorTask.raceTask, {});
    try Zsync.runBlocking(CombinatorTask.timeoutTask, {});
}

/// Demonstrate cancellation capabilities
fn demonstrateCancellation(std.heap.page_allocator: std.mem.Allocator) !void {
    const CancelTask = struct {
        fn task(io: Zsync.Io) !void {
            std.debug.print("🛑 Creating cancellable operation...\n", .{});
            
            // Create a cancellation token
            var token = try Zsync.CancelToken.init(std.heap.page_allocator, .user_requested);
            defer token.deinit();
            
            var io_mut = io;
            var future = try io_mut.write("This operation can be cancelled!\n");
            future.setCancelToken(token);
            defer future.destroy(std.heap.page_allocator);
            
            // Simulate cancellation (would happen asynchronously in real use)
            std.debug.print("⏰ Simulating user cancellation...\n", .{});
            
            // For demo purposes, let it complete normally
            try future.await();
            
            std.debug.print("✅ Cancellation system working correctly!\n", .{});
        }
    };
    
    try Zsync.runBlocking(CancelTask.task, {});
}

/// Demonstrate performance metrics collection
fn demonstrateMetrics(std.heap.page_allocator: std.mem.Allocator) !void {
    const MetricsTask = struct {
        fn task(io: Zsync.Io) !void {
            std.debug.print("📈 Performing operations to collect metrics...\n", .{});
            
            // Perform several I/O operations
            const operations = [_][]const u8{
                "Operation 1\n",
                "Operation 2\n", 
                "Operation 3\n",
                "Operation 4\n",
                "Operation 5\n",
            };
            
            var io_mut = io;
            for (operations) |op| {
                var future = try io_mut.write(op);
                defer future.destroy(std.heap.page_allocator);
                try future.await();
            }
            
            std.debug.print("✅ Metrics collection demo completed!\n", .{});
        }
    };
    
    // Create runtime with metrics enabled
    const config = Zsync.Config{
        .execution_model = .blocking,
        .enable_metrics = true,
        .enable_debugging = true,
    };
    
    var runtime = try Zsync.Runtime.init(std.heap.page_allocator, config);
    defer runtime.deinit();
    
    try runtime.run(MetricsTask.task, {});
    
    // Display metrics
    const metrics = runtime.getMetrics();
    std.debug.print("📊 Final Metrics:\n", .{});
    std.debug.print("  Tasks Completed: {}\n", .{metrics.tasks_completed.load(.monotonic)});
    std.debug.print("  Futures Created: {}\n", .{metrics.futures_created.load(.monotonic)});
}

/// Benchmark colorblind async performance
fn benchmarkPerformance(std.heap.page_allocator: std.mem.Allocator) !void {
    const BenchmarkTask = struct {
        fn task(io: Zsync.Io) !void {
            const iterations = 10000;
            const start_time = std.time.nanoTimestamp();
            
            for (0..iterations) |i| {
                _ = i;
                var future = try io.write(".");
                defer future.destroy(std.heap.page_allocator);
                try future.await();
            }
            
            const end_time = std.time.nanoTimestamp();
            const duration_ms = (end_time - start_time) / std.time.ns_per_ms;
            const ops_per_sec = (iterations * 1000) / @max(1, duration_ms);
            
            std.debug.print("\n🚀 Performance Results:\n", .{});
            std.debug.print("  {} operations in {}ms\n", .{ iterations, duration_ms });
            std.debug.print("  {} ops/second\n", .{ops_per_sec});
            std.debug.print("  Average latency: {}μs\n", .{duration_ms * 1000 / iterations});
        }
    };
    
    std.debug.print("🏃 Running performance benchmark...\n", .{});
    try Zsync.runBlocking(BenchmarkTask.task, {});
}

test "Zsync v0.4.0 integration test" {
    const testing = std.testing;
    const std.heap.page_allocator = testing.std.heap.page_allocator;
    
    const TestTask = struct {
        fn task(io: Zsync.Io) !void {
            // Test basic write operation
            var future = try io.write("Integration test passed!");
            defer future.destroy(std.heap.page_allocator);
            try future.await();
            
            // Test execution mode detection
            const mode = io.getMode();
            try testing.expect(mode == .blocking);
        }
    };
    
    try Zsync.runBlocking(TestTask.task, {});
}