//! Performance benchmarks for Zsync
//! Comprehensive benchmarking suite for async runtime performance

const std = @import("std");
const runtime = @import("runtime.zig");
const scheduler = @import("scheduler.zig");
const channel = @import("channel.zig");
const timer = @import("timer.zig");
const multithread = @import("multithread.zig");

/// Benchmark configuration
pub const BenchmarkConfig = struct {
    iterations: u32 = 1000,
    warmup_iterations: u32 = 100,
    task_count: u32 = 1000,
    channel_buffer_size: u32 = 100,
    timeout_ms: u64 = 5000,
    thread_count: u32 = 4,
};

/// Benchmark results
pub const BenchmarkResult = struct {
    name: []const u8,
    iterations: u32,
    total_time_ns: u64,
    avg_time_ns: u64,
    min_time_ns: u64,
    max_time_ns: u64,
    ops_per_sec: u64,
    memory_used_bytes: usize,

    pub fn print(self: *const BenchmarkResult) void {
        std.log.info("Benchmark: {s}", .{self.name});
        std.log.info("  Iterations: {}", .{self.iterations});
        std.log.info("  Average time: {} ns", .{self.avg_time_ns});
        std.log.info("  Min time: {} ns", .{self.min_time_ns});
        std.log.info("  Max time: {} ns", .{self.max_time_ns});
        std.log.info("  Ops/sec: {}", .{self.ops_per_sec});
        std.log.info("  Memory used: {} bytes", .{self.memory_used_bytes});
    }
};

/// Benchmark timer for precise measurements
pub const BenchmarkTimer = struct {
    start_time: u64,
    
    const Self = @This();

    pub fn start() Self {
        return Self{ .start_time = std.time.Instant.now() catch unreachable };
    }

    pub fn elapsed(self: *const Self) u64 {
        return @intCast(std.time.Instant.now() catch unreachable - @as(i128, @intCast(self.start_time)));
    }
};

/// Memory tracking for benchmarks
pub const MemoryTracker = struct {
    backing_allocator: std.mem.Allocator,
    bytes_allocated: std.atomic.Value(usize),
    peak_allocation: std.atomic.Value(usize),
    allocation_count: std.atomic.Value(usize),

    const Self = @This();

    pub fn init(backing_allocator: std.mem.Allocator) Self {
        return Self{
            .backing_allocator = backing_allocator,
            .bytes_allocated = std.atomic.Value(usize).init(0),
            .peak_allocation = std.atomic.Value(usize).init(0),
            .allocation_count = std.atomic.Value(usize).init(0),
        };
    }

    pub fn allocator(self: *Self) std.mem.Allocator {
        return std.mem.Allocator{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, log2_align: u8, ret_addr: usize) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const result = self.backing_allocator.rawAlloc(len, log2_align, ret_addr);
        if (result) |_| {
            const current = self.bytes_allocated.fetchAdd(len, .monotonic);
            const new_total = current + len;
            _ = self.peak_allocation.fetchMax(new_total, .monotonic);
            _ = self.allocation_count.fetchAdd(1, .monotonic);
        }
        return result;
    }

    fn resize(ctx: *anyopaque, buf: []u8, log2_align: u8, new_len: usize, ret_addr: usize) bool {
        const self: *Self = @ptrCast(@alignCast(ctx));
        if (self.backing_allocator.rawResize(buf, log2_align, new_len, ret_addr)) {
            if (new_len > buf.len) {
                const diff = new_len - buf.len;
                const current = self.bytes_allocated.fetchAdd(diff, .monotonic);
                _ = self.peak_allocation.fetchMax(current + diff, .monotonic);
            } else {
                const diff = buf.len - new_len;
                _ = self.bytes_allocated.fetchSub(diff, .monotonic);
            }
            return true;
        }
        return false;
    }

    fn free(ctx: *anyopaque, buf: []u8, log2_align: u8, ret_addr: usize) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.backing_allocator.rawFree(buf, log2_align, ret_addr);
        _ = self.bytes_allocated.fetchSub(buf.len, .monotonic);
    }

    pub fn getCurrentUsage(self: *const Self) usize {
        return self.bytes_allocated.load(.monotonic);
    }

    pub fn getPeakUsage(self: *const Self) usize {
        return self.peak_allocation.load(.monotonic);
    }

    pub fn getAllocationCount(self: *const Self) usize {
        return self.allocation_count.load(.monotonic);
    }

    pub fn reset(self: *Self) void {
        self.bytes_allocated.store(0, .monotonic);
        self.peak_allocation.store(0, .monotonic);
        self.allocation_count.store(0, .monotonic);
    }
};

/// Benchmark suite
pub const BenchmarkSuite = struct {
    allocator: std.mem.Allocator,
    memory_tracker: MemoryTracker,
    results: std.ArrayList(BenchmarkResult),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .memory_tracker = MemoryTracker.init(allocator),
            .results = std.ArrayList(BenchmarkResult){ .allocator = allocator },
        };
    }

    pub fn deinit(self: *Self) void {
        self.results.deinit(self.allocator);
    }

    /// Run all benchmarks
    pub fn runAll(self: *Self, config: BenchmarkConfig) !void {
        std.log.info("Starting Zsync benchmark suite...");
        
        try self.benchmarkTaskSpawning(config);
        try self.benchmarkChannelThroughput(config);
        try self.benchmarkTimerAccuracy(config);
        try self.benchmarkSchedulerPerformance(config);
        try self.benchmarkMemoryUsage(config);
        try self.benchmarkMultithreadPerformance(config);
        
        self.printSummary();
    }

    /// Benchmark task spawning performance
    fn benchmarkTaskSpawning(self: *Self, config: BenchmarkConfig) !void {
        std.log.info("Benchmarking task spawning...");
        
        var times = try self.allocator.alloc(u64, config.iterations);
        defer self.allocator.free(times);
        
        self.memory_tracker.reset();
        
        for (0..config.iterations) |i| {
            const bench_timer = BenchmarkTimer.start();
            
            const rt = try runtime.Runtime.init(self.memory_tracker.allocator(), .{});
            defer rt.deinit();
            
            for (0..config.task_count) |_| {
                _ = try rt.spawn(simpleTask, .{});
            }
            
            times[i] = bench_timer.elapsed();
        }
        
        const result = self.calculateResult("Task Spawning", times, self.memory_tracker.getPeakUsage());
        try self.results.append(self.allocator, result);
    }

    /// Benchmark channel throughput
    fn benchmarkChannelThroughput(self: *Self, config: BenchmarkConfig) !void {
        std.log.info("Benchmarking channel throughput...");
        
        var times = try self.allocator.alloc(u64, config.iterations);
        defer self.allocator.free(times);
        
        self.memory_tracker.reset();
        
        for (0..config.iterations) |i| {
            const bench_timer = BenchmarkTimer.start();
            
            const ch = try channel.bounded(u32, self.memory_tracker.allocator(), config.channel_buffer_size);
            defer ch.deinit();
            
            // Send messages
            for (0..config.task_count) |j| {
                try ch.send(@intCast(j));
            }
            
            // Receive messages
            for (0..config.task_count) |_| {
                _ = try ch.recv();
            }
            
            times[i] = bench_timer.elapsed();
        }
        
        const result = self.calculateResult("Channel Throughput", times, self.memory_tracker.getPeakUsage());
        try self.results.append(self.allocator, result);
    }

    /// Benchmark timer accuracy
    fn benchmarkTimerAccuracy(self: *Self, config: BenchmarkConfig) !void {
        std.log.info("Benchmarking timer accuracy...");
        
        var times = try self.allocator.alloc(u64, config.iterations);
        defer self.allocator.free(times);
        
        self.memory_tracker.reset();
        
        for (0..config.iterations) |i| {
            const bench_timer = BenchmarkTimer.start();
            
            var timer_wheel = try timer.TimerWheel.init(self.memory_tracker.allocator());
            defer timer_wheel.deinit();
            
            // Add timers
            for (0..100) |j| {
                const timeout = @as(u64, @intCast(j)) * 10; // 0ms, 10ms, 20ms, ...
                const handle = try timer_wheel.addTimer(timeout, @intCast(j));
                _ = handle;
            }
            
            // Process expired timers
            var expired_count: u32 = 0;
            while (expired_count < 100) {
                if (timer_wheel.popExpired()) |_| {
                    expired_count += 1;
                }
                std.time.sleep(1 * std.time.ns_per_ms);
            }
            
            times[i] = bench_timer.elapsed();
        }
        
        const result = self.calculateResult("Timer Accuracy", times, self.memory_tracker.getPeakUsage());
        try self.results.append(self.allocator, result);
    }

    /// Benchmark scheduler performance
    fn benchmarkSchedulerPerformance(self: *Self, config: BenchmarkConfig) !void {
        std.log.info("Benchmarking scheduler performance...");
        
        var times = try self.allocator.alloc(u64, config.iterations);
        defer self.allocator.free(times);
        
        self.memory_tracker.reset();
        
        for (0..config.iterations) |i| {
            const bench_timer = BenchmarkTimer.start();
            
            var sched = try scheduler.AsyncScheduler.init(self.memory_tracker.allocator());
            defer sched.deinit();
            
            // Spawn tasks
            for (0..config.task_count) |_| {
                _ = try sched.spawn(simpleTask, .{}, .normal);
            }
            
            // Run scheduler
            var processed: u32 = 0;
            while (processed < config.task_count) {
                processed += try sched.tick();
                if (processed == 0) break;
            }
            
            times[i] = bench_timer.elapsed();
        }
        
        const result = self.calculateResult("Scheduler Performance", times, self.memory_tracker.getPeakUsage());
        try self.results.append(self.allocator, result);
    }

    /// Benchmark memory usage
    fn benchmarkMemoryUsage(self: *Self, config: BenchmarkConfig) !void {
        std.log.info("Benchmarking memory usage...");
        
        var times = try self.allocator.alloc(u64, config.iterations);
        defer self.allocator.free(times);
        
        self.memory_tracker.reset();
        
        for (0..config.iterations) |i| {
            const bench_timer = BenchmarkTimer.start();
            
            const rt = try runtime.Runtime.init(self.memory_tracker.allocator(), .{});
            defer rt.deinit();
            
            // Create many runtime components
            for (0..100) |_| {
                _ = try rt.spawn(memoryIntensiveTask, .{});
            }
            
            times[i] = bench_timer.elapsed();
        }
        
        const result = self.calculateResult("Memory Usage", times, self.memory_tracker.getPeakUsage());
        try self.results.append(self.allocator, result);
    }

    /// Benchmark multi-thread performance
    fn benchmarkMultithreadPerformance(self: *Self, config: BenchmarkConfig) !void {
        std.log.info("Benchmarking multi-thread performance...");
        
        var times = try self.allocator.alloc(u64, config.iterations);
        defer self.allocator.free(times);
        
        self.memory_tracker.reset();
        
        for (0..config.iterations) |i| {
            const bench_timer = BenchmarkTimer.start();
            
            const mt_config = multithread.WorkerConfig{
                .thread_count = config.thread_count,
                .queue_capacity = 256,
            };
            
            var mt_runtime = try multithread.MultiThreadRuntime.init(self.memory_tracker.allocator(), mt_config);
            defer mt_runtime.deinit();
            
            try mt_runtime.start();
            defer mt_runtime.stop();
            
            // Simulate work
            std.time.sleep(1 * std.time.ns_per_ms);
            
            times[i] = bench_timer.elapsed();
        }
        
        const result = self.calculateResult("Multi-thread Performance", times, self.memory_tracker.getPeakUsage());
        try self.results.append(self.allocator, result);
    }

    /// Calculate benchmark result statistics
    fn calculateResult(self: *Self, name: []const u8, times: []const u64, memory_used: usize) BenchmarkResult {
        _ = self;
        
        var min_time = times[0];
        var max_time = times[0];
        var total_time: u64 = 0;
        
        for (times) |time| {
            total_time += time;
            min_time = @min(min_time, time);
            max_time = @max(max_time, time);
        }
        
        const avg_time = total_time / times.len;
        const ops_per_sec = if (avg_time > 0) (1_000_000_000 / avg_time) else 0;
        
        return BenchmarkResult{
            .name = name,
            .iterations = @intCast(times.len),
            .total_time_ns = total_time,
            .avg_time_ns = avg_time,
            .min_time_ns = min_time,
            .max_time_ns = max_time,
            .ops_per_sec = ops_per_sec,
            .memory_used_bytes = memory_used,
        };
    }

    /// Print benchmark summary
    fn printSummary(self: *const Self) void {
        std.log.info("\n=== Zsync Benchmark Results ===");
        for (self.results.items) |*result| {
            result.print();
            std.log.info("");
        }
        
        // Calculate overall performance score
        var total_ops: u64 = 0;
        for (self.results.items) |result| {
            total_ops += result.ops_per_sec;
        }
        
        std.log.info("Overall Performance Score: {} ops/sec", .{total_ops});
    }
};

/// Simple task for benchmarking
fn simpleTask() void {
    // Minimal work
    var sum: u32 = 0;
    for (0..100) |i| {
        sum += @intCast(i);
    }
    std.debug.assert(sum > 0); // Use the sum
}

/// Memory-intensive task for benchmarking
fn memoryIntensiveTask() void {
    var list = std.ArrayList(u32){ .allocator = std.heap.page_allocator };
    defer list.deinit(std.heap.page_allocator);
    
    for (0..1000) |i| {
        list.append(std.heap.page_allocator, @intCast(i)) catch break;
    }
}

/// Run comprehensive benchmarks
pub fn runBenchmarks(allocator: std.mem.Allocator) !void {
    var suite = BenchmarkSuite.init(allocator);
    defer suite.deinit();
    
    const config = BenchmarkConfig{
        .iterations = 100,
        .task_count = 1000,
        .channel_buffer_size = 256,
        .thread_count = 4,
    };
    
    try suite.runAll(config);
}

// Tests
test "benchmark timer" {
    const testing = std.testing;
    
    const bench_timer = BenchmarkTimer.start();
    std.time.sleep(1 * std.time.ns_per_ms);
    const elapsed = bench_timer.elapsed();
    
    try testing.expect(elapsed >= 1_000_000); // At least 1ms
}

test "memory tracker" {
    const testing = std.testing;
    
    var tracker = MemoryTracker.init(testing.allocator);
    const tracked_allocator = tracker.allocator();
    
    const ptr = try tracked_allocator.alloc(u8, 100);
    try testing.expect(tracker.getCurrentUsage() == 100);
    
    tracked_allocator.free(ptr);
    try testing.expect(tracker.getCurrentUsage() == 0);
}

test "benchmark result calculation" {
    const testing = std.testing;
    
    var suite = BenchmarkSuite.init(testing.allocator);
    defer suite.deinit();
    
    const times = [_]u64{ 100, 200, 300, 400, 500 };
    const result = suite.calculateResult("Test", &times, 1000);
    
    try testing.expect(result.avg_time_ns == 300);
    try testing.expect(result.min_time_ns == 100);
    try testing.expect(result.max_time_ns == 500);
}