//! Zsync v0.4.0 - The Tokio of Zig
//! Colorblind Async Runtime with True Function Color Elimination
//! Following Zig's latest async paradigm for maximum performance and ergonomics

const std = @import("std");

// Core v0.4.0 APIs - Colorblind Async Interface
pub const io_interface = @import("io_interface_v4.zig");
pub const runtime = @import("runtime_v4.zig");
pub const blocking_io = @import("blocking_io_v4.zig");

// Re-export core types for convenience
pub const Io = io_interface.Io;
pub const IoMode = io_interface.IoMode;
pub const IoError = io_interface.IoError;
pub const IoBuffer = io_interface.IoBuffer;
pub const Future = io_interface.Future;
pub const CancelToken = io_interface.CancelToken;
pub const Combinators = io_interface.Combinators;

// Runtime types
pub const Runtime = runtime.Runtime;
pub const Config = runtime.Config;
pub const ExecutionModel = runtime.ExecutionModel;
pub const RuntimeError = runtime.RuntimeError;
pub const RuntimeMetrics = runtime.RuntimeMetrics;

// I/O Implementations
pub const BlockingIo = blocking_io.BlockingIo;

// Convenience runtime functions
pub const run = runtime.run;
pub const runBlocking = runtime.runBlocking;
pub const runHighPerf = runtime.runHighPerf;
pub const getGlobalIo = runtime.getGlobalIo;

// Set global execution mode for colorblind async
pub const setIoMode = setGlobalIoMode;
pub fn setGlobalIoMode(mode: IoMode) void {
    io_interface.io_mode = mode;
}

/// Convenience function to create a simple blocking I/O instance
pub fn createBlockingIo(allocator: std.mem.Allocator) BlockingIo {
    return BlockingIo.init(allocator, 4096);
}

/// Example colorblind async function that works with ANY Io implementation
pub fn saveData(allocator: std.mem.Allocator, io: Io, data: []const u8) !void {
    // This function is truly colorblind - works in sync or async context
    var future = try io.write(data);
    defer future.destroy(allocator);
    
    // Colorblind await - adapts to execution context
    try future.await();
}

/// Advanced example with timeout and error handling
pub fn saveDataWithTimeout(allocator: std.mem.Allocator, io: Io, data: []const u8, timeout_ms: u64) !void {
    const write_future = try io.write(data);
    var timeout_future = try Combinators.timeout(allocator, write_future, timeout_ms);
    defer timeout_future.destroy(allocator);
    
    try timeout_future.await();
}

/// Example of concurrent operations using Future combinators
pub fn concurrentSave(allocator: std.mem.Allocator, io: Io, data1: []const u8, data2: []const u8) !void {
    var future1 = try io.write(data1);
    var future2 = try io.write(data2);
    
    var futures = [_]Future{ future1, future2 };
    var all_future = try Combinators.all(allocator, &futures);
    defer all_future.destroy(allocator);
    
    try all_future.await();
    
    // Clean up individual futures
    future1.destroy(allocator);
    future2.destroy(allocator);
}

/// Example of racing operations
pub fn raceOperations(allocator: std.mem.Allocator, io: Io, data1: []const u8, data2: []const u8) !void {
    var future1 = try io.write(data1);
    var future2 = try io.write(data2);
    
    var futures = [_]Future{ future1, future2 };
    var race_future = try Combinators.race(allocator, &futures);
    defer race_future.destroy(allocator);
    
    try race_future.await();
    
    // Clean up
    future1.destroy(allocator);
    future2.destroy(allocator);
}

/// Utility function to detect optimal execution model
pub fn detectOptimalModel() ExecutionModel {
    return ExecutionModel.detect();
}

/// Create runtime with optimal configuration for current platform
pub fn createOptimalRuntime(allocator: std.mem.Allocator) !*Runtime {
    const model = detectOptimalModel();
    
    const config = switch (model) {
        .blocking => Config{
            .execution_model = .blocking,
            .buffer_size = 4096,
            .enable_debugging = false,
        },
        .thread_pool => Config{
            .execution_model = .thread_pool,
            .thread_pool_threads = @max(1, std.Thread.getCpuCount() catch 4),
            .enable_zero_copy = true,
            .enable_vectorized_io = true,
        },
        .green_threads => Config{
            .execution_model = .green_threads,
            .green_thread_stack_size = 64 * 1024,
            .max_green_threads = 1024,
            .enable_zero_copy = true,
        },
        .stackless => Config{
            .execution_model = .stackless,
            .buffer_size = 2048, // Smaller for WASM
        },
        .auto => Config{}, // Default configuration
    };
    
    return Runtime.init(allocator, config);
}

/// High-level async task spawning (for future implementation)
pub fn spawn(comptime task_fn: anytype, args: anytype) !Future {
    const runtime_instance = Runtime.global() orelse return RuntimeError.RuntimeShutdown;
    return runtime_instance.spawn(task_fn, args);
}

/// High-level timeout wrapper
pub fn timeout(future: Future, timeout_ms: u64) !Future {
    const runtime_instance = Runtime.global() orelse return RuntimeError.RuntimeShutdown;
    return runtime_instance.timeout(future, timeout_ms);
}

/// High-level race wrapper
pub fn race(futures: []Future) !Future {
    const runtime_instance = Runtime.global() orelse return RuntimeError.RuntimeShutdown;
    return runtime_instance.race(futures);
}

/// High-level all wrapper
pub fn all(futures: []Future) !Future {
    const runtime_instance = Runtime.global() orelse return RuntimeError.RuntimeShutdown;
    return runtime_instance.all(futures);
}

// Version information
pub const VERSION = "0.4.0";
pub const VERSION_MAJOR = 0;
pub const VERSION_MINOR = 4;
pub const VERSION_PATCH = 0;

/// Print Zsync version and capabilities
pub fn printVersion() void {
    std.debug.print("🚀 Zsync v{s} - The Tokio of Zig\n", .{VERSION});
    std.debug.print("Features:\n", .{});
    std.debug.print("  ✅ Colorblind Async/Await\n", .{});
    std.debug.print("  ✅ Multiple Execution Models\n", .{});
    std.debug.print("  ✅ Future Combinators\n", .{});
    std.debug.print("  ✅ Cooperative Cancellation\n", .{});
    std.debug.print("  ✅ Zero-Cost Abstractions\n", .{});
    std.debug.print("  ✅ Cross-Platform Support\n", .{});
    
    const optimal_model = detectOptimalModel();
    std.debug.print("Optimal execution model for this platform: {}\n", .{optimal_model});
}

/// Simple hello world example showcasing colorblind async
pub fn helloWorld(_: std.mem.Allocator) !void {
    const HelloTask = struct {
        fn task(io: Io) !void {
            const messages = [_][]const u8{
                "🚀 Zsync v0.4.0 - The Tokio of Zig\n",
                "✨ Colorblind async in action!\n", 
                "🔥 Same code, any execution model!\n",
                "⚡ Zero-cost abstractions!\n",
            };
            
            // Demonstrate vectorized write
            var io_mut = io;
            var future = try io_mut.writev(&messages);
            defer future.destroy(std.heap.page_allocator);
            try future.await();
            
            std.debug.print("Execution mode: {}\n", .{io.getMode()});
            std.debug.print("Supports vectorized I/O: {}\n", .{io.supportsVectorized()});
            std.debug.print("Supports zero-copy: {}\n", .{io.supportsZeroCopy()});
        }
    };
    
    try runBlocking(HelloTask.task, {});
}

// Backward compatibility exports (deprecated but functional)
pub const examples = struct {
    pub const saveData = @This().saveData;
    pub const helloWorld = @This().helloWorld;
};

// Tests
test "Zsync v0.4.0 basic functionality" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    // Test runtime creation
    var blocking_io_impl = createBlockingIo(allocator);
    defer blocking_io_impl.deinit();
    
    const io = blocking_io_impl.io();
    
    // Test colorblind async
    try saveData(allocator, io, "Hello, Zsync v0.4.0!");
    
    // Test execution model detection
    const model = detectOptimalModel();
    try testing.expect(model != .auto);
}

test "Future combinators" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var blocking_io_impl = createBlockingIo(allocator);
    defer blocking_io_impl.deinit();
    
    const io = blocking_io_impl.io();
    
    // Test concurrent operations
    try concurrentSave(allocator, io, "Data 1", "Data 2");
    
    // Test timeout functionality
    try saveDataWithTimeout(allocator, io, "Timeout test", 1000);
}

test "Runtime with optimal configuration" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    const runtime_instance = try createOptimalRuntime(allocator);
    defer runtime_instance.deinit();
    
    try testing.expect(runtime_instance.getExecutionModel() != .auto);
    
    const io = runtime_instance.getIo();
    try testing.expect(io.getMode() != .auto);
}

test "Version information" {
    const testing = std.testing;
    
    try testing.expect(VERSION_MAJOR == 0);
    try testing.expect(VERSION_MINOR == 4);
    try testing.expect(VERSION_PATCH == 0);
    try testing.expect(std.mem.eql(u8, VERSION, "0.4.0"));
}

/// Legacy compatibility function
pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "legacy compatibility" {
    const testing = std.testing;
    try testing.expect(add(3, 7) == 10);
}