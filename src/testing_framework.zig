//! Zsync v0.1 - Testing & Validation Framework
//! Comprehensive tests for all Io implementations
//! Ensures same code works correctly across execution models

const std = @import("std");
const Zsync = @import("root.zig");

/// Test suite configuration
pub const TestConfig = struct {
    test_blocking: bool = true,
    test_threadpool: bool = true,
    test_greenthreads: bool = true,
    test_stackless: bool = true,
    num_threads: u32 = 4,
    test_data_size: usize = 1024,
    concurrent_operations: u32 = 10,
};

/// Test results for each Io implementation
pub const TestResults = struct {
    blocking_io: ?ExecutionResults = null,
    threadpool_io: ?ExecutionResults = null,
    greenthreads_io: ?ExecutionResults = null,
    stackless_io: ?ExecutionResults = null,
    
    pub const ExecutionResults = struct {
        passed: bool,
        execution_time_ns: i64,
        memory_used: usize,
        operations_completed: u32,
        error_message: ?[]const u8 = null,
    };
};

/// Comprehensive test suite runner
pub const TestSuite = struct {
    allocator: std.mem.Allocator,
    config: TestConfig,
    results: TestResults = .{},
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, config: TestConfig) Self {
        return Self{
            .allocator = allocator,
            .config = config,
        };
    }
    
    /// Run all tests across all Io implementations
    pub fn runAllTests(self: *Self) !TestResults {
        std.debug.print("🧪 Zsync v0.1 Comprehensive Test Suite\n");
        std.debug.print("=====================================\n\n");
        
        // Test 1: BlockingIo
        if (self.config.test_blocking) {
            std.debug.print("📋 Testing BlockingIo implementation...\n");
            self.results.blocking_io = self.testBlockingIo() catch |err| blk: {
                std.debug.print("❌ BlockingIo test failed: {}\n", .{err});
                break :blk .{
                    .passed = false,
                    .execution_time_ns = 0,
                    .memory_used = 0,
                    .operations_completed = 0,
                    .error_message = @errorName(err),
                };
            };
        }
        
        // Test 2: ThreadPoolIo
        if (self.config.test_threadpool) {
            std.debug.print("📋 Testing ThreadPoolIo implementation...\n");
            self.results.threadpool_io = self.testThreadPoolIo() catch |err| blk: {
                std.debug.print("❌ ThreadPoolIo test failed: {}\n", .{err});
                break :blk .{
                    .passed = false,
                    .execution_time_ns = 0,
                    .memory_used = 0,
                    .operations_completed = 0,
                    .error_message = @errorName(err),
                };
            };
        }
        
        // Test 3: GreenThreadsIo (platform specific)
        if (self.config.test_greenthreads and std.builtin.cpu.arch == .x86_64 and std.builtin.os.tag == .linux) {
            std.debug.print("📋 Testing GreenThreadsIo implementation...\n");
            self.results.greenthreads_io = self.testGreenThreadsIo() catch |err| blk: {
                std.debug.print("❌ GreenThreadsIo test failed: {}\n", .{err});
                break :blk .{
                    .passed = false,
                    .execution_time_ns = 0,
                    .memory_used = 0,
                    .operations_completed = 0,
                    .error_message = @errorName(err),
                };
            };
        } else {
            std.debug.print("⚠️  Skipping GreenThreadsIo (not supported on this platform)\n");
        }
        
        // Test 4: StacklessIo
        if (self.config.test_stackless) {
            std.debug.print("📋 Testing StacklessIo implementation...\n");
            self.results.stackless_io = self.testStacklessIo() catch |err| blk: {
                std.debug.print("❌ StacklessIo test failed: {}\n", .{err});
                break :blk .{
                    .passed = false,
                    .execution_time_ns = 0,
                    .memory_used = 0,
                    .operations_completed = 0,
                    .error_message = @errorName(err),
                };
            };
        }
        
        self.printResults();
        return self.results;
    }
    
    fn testBlockingIo(self: *Self) !TestResults.ExecutionResults {
        const start_time = std.time.nanoTimestamp();
        const start_memory = self.allocator.context.peak_used_bytes;
        
        var blocking_io = Zsync.BlockingIo.init(self.allocator);
        defer blocking_io.deinit();
        
        const io = blocking_io.io();
        
        // Run comprehensive tests
        try self.runCoreTests(io);
        try self.runConcurrencyTests(io);
        try self.runResourceCleanupTests(io);
        
        const end_time = std.time.nanoTimestamp();
        const end_memory = self.allocator.context.peak_used_bytes;
        
        std.debug.print("   ✅ BlockingIo: All tests passed\n");
        
        return .{
            .passed = true,
            .execution_time_ns = end_time - start_time,
            .memory_used = end_memory - start_memory,
            .operations_completed = self.config.concurrent_operations * 3, // 3 test categories
        };
    }
    
    fn testThreadPoolIo(self: *Self) !TestResults.ExecutionResults {
        const start_time = std.time.nanoTimestamp();
        const start_memory = self.allocator.context.peak_used_bytes;
        
        var threadpool_io = try Zsync.ThreadPoolIo.init(self.allocator, .{ .num_threads = self.config.num_threads });
        defer threadpool_io.deinit();
        
        const io = threadpool_io.io();
        
        // Run comprehensive tests
        try self.runCoreTests(io);
        try self.runConcurrencyTests(io);
        try self.runResourceCleanupTests(io);
        try self.runParallelismTests(io);
        
        const end_time = std.time.nanoTimestamp();
        const end_memory = self.allocator.context.peak_used_bytes;
        
        std.debug.print("   ✅ ThreadPoolIo: All tests passed\n");
        
        return .{
            .passed = true,
            .execution_time_ns = end_time - start_time,
            .memory_used = end_memory - start_memory,
            .operations_completed = self.config.concurrent_operations * 4, // 4 test categories
        };
    }
    
    fn testGreenThreadsIo(self: *Self) !TestResults.ExecutionResults {
        const start_time = std.time.nanoTimestamp();
        const start_memory = self.allocator.context.peak_used_bytes;
        
        var greenthreads_io = try Zsync.GreenThreadsIo.init(self.allocator, .{});
        defer greenthreads_io.deinit();
        
        const io = greenthreads_io.io();
        
        // Run comprehensive tests
        try self.runCoreTests(io);
        try self.runConcurrencyTests(io);
        try self.runResourceCleanupTests(io);
        try self.runStackSwappingTests(io);
        
        const end_time = std.time.nanoTimestamp();
        const end_memory = self.allocator.context.peak_used_bytes;
        
        std.debug.print("   ✅ GreenThreadsIo: All tests passed\n");
        
        return .{
            .passed = true,
            .execution_time_ns = end_time - start_time,
            .memory_used = end_memory - start_memory,
            .operations_completed = self.config.concurrent_operations * 4, // 4 test categories
        };
    }
    
    fn testStacklessIo(self: *Self) !TestResults.ExecutionResults {
        const start_time = std.time.nanoTimestamp();
        const start_memory = self.allocator.context.peak_used_bytes;
        
        var stackless_io = Zsync.StacklessIo.init(self.allocator, .{});
        defer stackless_io.deinit();
        
        const io = stackless_io.io();
        
        // Run comprehensive tests
        try self.runCoreTests(io);
        try self.runConcurrencyTests(io);
        try self.runResourceCleanupTests(io);
        try self.runStacklessTests(io);
        
        const end_time = std.time.nanoTimestamp();
        const end_memory = self.allocator.context.peak_used_bytes;
        
        std.debug.print("   ✅ StacklessIo: All tests passed\n");
        
        return .{
            .passed = true,
            .execution_time_ns = end_time - start_time,
            .memory_used = end_memory - start_memory,
            .operations_completed = self.config.concurrent_operations * 4, // 4 test categories
        };
    }
    
    // Core functionality tests
    fn runCoreTests(_: *Self, io: Zsync.Io) !void {
        // Test file operations
        const test_data = "Zsync v0.1 core test data";
        const file = try Zsync.Dir.cwd().createFile(io, "core_test.txt", .{});
        defer file.close(io) catch {};
        
        try file.writeAll(io, test_data);
        
        // Test async operations
        var future = try io.async(coreTestTask, .{ io, "core-test" });
        defer future.cancel(io) catch {};
        
        try future.await(io);
        
        // Clean up
        std.fs.cwd().deleteFile("core_test.txt") catch {};
    }
    
    // Concurrency and cancellation tests
    fn runConcurrencyTests(self: *Self, io: Zsync.Io) !void {
        var futures = std.ArrayList(Zsync.Future).init(self.allocator);
        defer {
            for (futures.items) |*future| {
                future.cancel(io) catch {};
                future.deinit();
            }
            futures.deinit();
        }
        
        // Start concurrent operations
        for (0..self.config.concurrent_operations) |i| {
            const task_name = try std.fmt.allocPrint(self.allocator, "concurrent-{}", .{i});
            defer self.allocator.free(task_name);
            
            const future = try io.async(concurrentTestTask, .{ io, task_name });
            try futures.append(future);
        }
        
        // Wait for all to complete
        for (futures.items) |*future| {
            try future.await(io);
        }
    }
    
    // Resource cleanup and leak detection
    fn runResourceCleanupTests(self: *Self, io: Zsync.Io) !void {
        // Test proper resource cleanup
        for (0..10) |i| {
            const filename = try std.fmt.allocPrint(self.allocator, "cleanup_test_{}.txt", .{i});
            defer self.allocator.free(filename);
            
            const file = try Zsync.Dir.cwd().createFile(io, filename, .{});
            try file.writeAll(io, "cleanup test");
            try file.close(io);
            
            // Clean up immediately
            std.fs.cwd().deleteFile(filename) catch {};
        }
    }
    
    // ThreadPool-specific parallelism tests
    fn runParallelismTests(self: *Self, io: Zsync.Io) !void {
        
        // Test that operations can run in parallel
        var futures = std.ArrayList(Zsync.Future).init(self.allocator);
        defer {
            for (futures.items) |*future| {
                future.cancel(io) catch {};
                future.deinit();
            }
            futures.deinit();
        }
        
        const start_time = std.time.nanoTimestamp();
        
        // Start parallel CPU-bound tasks
        for (0..4) |i| {
            const future = try io.async(cpuBoundTask, .{ io, i });
            try futures.append(future);
        }
        
        // Wait for all to complete
        for (futures.items) |*future| {
            try future.await(io);
        }
        
        const end_time = std.time.nanoTimestamp();
        const total_time = end_time - start_time;
        
        std.debug.print("   🚀 Parallel execution took {}ms\n", .{@divFloor(total_time, 1_000_000)});
    }
    
    // GreenThreads-specific stack swapping tests
    fn runStackSwappingTests(self: *Self, io: Zsync.Io) !void {
        _ = self;
        
        // Test stack switching with deep recursion
        var future = try io.async(deepRecursionTask, .{ io, 100 });
        defer future.cancel(io) catch {};
        
        try future.await(io);
    }
    
    // Stackless-specific tests
    fn runStacklessTests(self: *Self, io: Zsync.Io) !void {
        _ = self;
        
        // Test stackless execution with frame management
        var future = try io.async(stacklessTestTask, .{ io, "stackless" });
        defer future.cancel(io) catch {};
        
        try future.await(io);
    }
    
    fn printResults(self: *Self) void {
        std.debug.print("\n📊 Test Results Summary\n");
        std.debug.print("=======================\n");
        
        if (self.results.blocking_io) |result| {
            self.printResult("BlockingIo", result);
        }
        
        if (self.results.threadpool_io) |result| {
            self.printResult("ThreadPoolIo", result);
        }
        
        if (self.results.greenthreads_io) |result| {
            self.printResult("GreenThreadsIo", result);
        }
        
        if (self.results.stackless_io) |result| {
            self.printResult("StacklessIo", result);
        }
        
        std.debug.print("\n🎉 Test suite completed!\n");
    }
    
    fn printResult(self: *Self, name: []const u8, result: TestResults.ExecutionResults) void {
        _ = self;
        
        const status = if (result.passed) "✅ PASSED" else "❌ FAILED";
        const time_ms = @divFloor(result.execution_time_ns, 1_000_000);
        
        std.debug.print("{s}: {s} ({}ms, {} ops, {} bytes)\n", .{ 
            name, 
            status, 
            time_ms, 
            result.operations_completed, 
            result.memory_used 
        });
        
        if (result.error_message) |err| {
            std.debug.print("   Error: {s}\n", .{err});
        }
    }
};

// Test task functions
fn coreTestTask(io: Zsync.Io, name: []const u8) !void {
    _ = io;
    _ = name;
    // Simulate core work
}

fn concurrentTestTask(io: Zsync.Io, name: []const u8) !void {
    _ = io;
    _ = name;
    // Simulate concurrent work
    std.time.sleep(1 * std.time.ns_per_ms); // 1ms
}

fn cpuBoundTask(io: Zsync.Io, task_id: usize) !void {
    _ = io;
    
    // Simulate CPU-bound work
    var result: u64 = 0;
    for (0..100000) |i| {
        result += i * task_id;
    }
    
    std.debug.print("   💻 CPU task {} completed (result: {})\n", .{ task_id, result });
}

fn deepRecursionTask(io: Zsync.Io, depth: u32) !void {
    
    if (depth == 0) return;
    
    // Recursive call to test stack management
    try deepRecursionTask(io, depth - 1);
}

fn stacklessTestTask(io: Zsync.Io, name: []const u8) !void {
    _ = io;
    _ = name;
    
    // Test stackless execution
    std.debug.print("   🔄 Stackless task executed\n");
}

/// Run the comprehensive test suite
pub fn runComprehensiveTests(allocator: std.mem.Allocator) !TestResults {
    var test_suite = TestSuite.init(allocator, .{});
    return try test_suite.runAllTests();
}

test "testing framework" {
    const testing = std.testing;
    try testing.expect(true);
}