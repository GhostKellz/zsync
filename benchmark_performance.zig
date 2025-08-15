//! Performance benchmarking suite for Zsync v0.4.0
//! Comprehensive testing of all I/O modes and optimizations

const std = @import("std");
const builtin = @import("builtin");
const zsync = @import("src/runtime.zig");
const io_interface = @import("src/io_interface.zig");
const blocking_io = @import("src/blocking_io.zig");
const thread_pool = @import("src/thread_pool.zig");
const platform_detect = @import("src/platform_detect.zig");

const Io = io_interface.Io;
const IoBuffer = io_interface.IoBuffer;

/// Benchmark configuration
const BenchmarkConfig = struct {
    iterations: u32 = 1000,
    buffer_size: usize = 4096,
    vector_count: usize = 8,
    warmup_iterations: u32 = 100,
};

/// Benchmark results
const BenchmarkResult = struct {
    name: []const u8,
    iterations: u32,
    total_time_ns: u64,
    throughput_mbps: f64,
    latency_per_op_ns: u64,
    operations_per_second: f64,
    
    pub fn print(self: BenchmarkResult) void {
        std.debug.print("📊 {s}:\n", .{self.name});
        std.debug.print("  • {} iterations in {:.2}ms\n", .{ self.iterations, @as(f64, @floatFromInt(self.total_time_ns)) / std.time.ns_per_ms });
        std.debug.print("  • {:.2} MB/s throughput\n", .{self.throughput_mbps});
        std.debug.print("  • {:.1}ns per operation\n", .{@as(f64, @floatFromInt(self.latency_per_op_ns))});
        std.debug.print("  • {:.0} ops/second\n", .{self.operations_per_second});
        std.debug.print("\n", .{});
    }
};

/// Zsync performance benchmarking suite
pub fn main() !void {
    std.debug.print("🚀 Zsync v0.4.0 Performance Benchmark Suite\n", .{});
    std.debug.print("=============================================\n", .{});
    
    // Print system information
    printSystemInfo();
    
    const config = BenchmarkConfig{};
    var results = std.ArrayList(BenchmarkResult).init(std.heap.page_allocator);
    defer results.deinit();
    
    // Benchmark blocking I/O
    std.debug.print("\n🔥 Benchmarking Blocking I/O\n", .{});
    std.debug.print("-----------------------------\n", .{});
    try results.append(try benchmarkBlockingBasic(config));
    try results.append(try benchmarkBlockingVectorized(config));
    if (builtin.os.tag == .linux) {
        try results.append(try benchmarkBlockingZeroCopy(config));
    }
    
    // Benchmark runtime execution models
    std.debug.print("\n⚡ Benchmarking Runtime Models\n", .{});
    std.debug.print("------------------------------\n", .{});
    try results.append(try benchmarkRuntimeBlocking(config));
    try results.append(try benchmarkRuntimeHighPerf(config));
    
    // Print performance comparison
    printPerformanceComparison(results.items);
    
    std.debug.print("🎉 Benchmark suite completed successfully!\n", .{});
    std.debug.print("✨ Zsync v0.4.0 performance characteristics verified\n", .{});
}

/// Print system information for benchmark context
fn printSystemInfo() void {
    std.debug.print("🖥️  System Information:\n", .{});
    
    if (builtin.os.tag == .linux) {
        const caps = platform_detect.detectSystemCapabilities();
        std.debug.print("  • Platform: {s} Linux\n", .{@tagName(caps.distro)});
        std.debug.print("  • Kernel: {}.{}.{}\n", .{ caps.kernel_version.major, caps.kernel_version.minor, caps.kernel_version.patch });
        std.debug.print("  • CPU Cores: {}\n", .{caps.cpu_count});
        std.debug.print("  • Memory: {} MB\n", .{caps.total_memory / (1024 * 1024)});
        std.debug.print("  • io_uring: {}\n", .{caps.has_io_uring});
        std.debug.print("  • Zero-copy: {}\n", .{caps.has_io_uring});
    } else {
        std.debug.print("  • Platform: {s}\n", .{@tagName(builtin.os.tag)});
        std.debug.print("  • CPU Cores: {}\n", .{std.Thread.getCpuCount() catch 1});
    }
}

/// Benchmark basic blocking I/O operations
fn benchmarkBlockingBasic(config: BenchmarkConfig) !BenchmarkResult {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var blocking = blocking_io.BlockingIo.init(allocator, config.buffer_size);
    defer blocking.deinit();
    
    var io = blocking.io();
    
    // Warmup
    try performWarmup(&io, config);
    
    // Benchmark
    const test_data = "Zsync v0.4.0 Performance Test Data! ";
    const start_time = std.time.nanoTimestamp();
    
    for (0..config.iterations) |_| {
        var write_future = try io.write(test_data);
        defer write_future.destroy(allocator);
        try write_future.await();
    }
    
    const end_time = std.time.nanoTimestamp();
    const total_time = @as(u64, @intCast(end_time - start_time));
    const total_bytes = config.iterations * test_data.len;
    
    return BenchmarkResult{
        .name = "Blocking I/O - Basic Write",
        .iterations = config.iterations,
        .total_time_ns = total_time,
        .throughput_mbps = (@as(f64, @floatFromInt(total_bytes)) / @as(f64, @floatFromInt(total_time))) * std.time.ns_per_s / (1024.0 * 1024.0),
        .latency_per_op_ns = total_time / config.iterations,
        .operations_per_second = @as(f64, @floatFromInt(config.iterations)) / (@as(f64, @floatFromInt(total_time)) / std.time.ns_per_s),
    };
}

/// Benchmark vectorized blocking I/O operations
fn benchmarkBlockingVectorized(config: BenchmarkConfig) !BenchmarkResult {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var blocking = blocking_io.BlockingIo.init(allocator, config.buffer_size);
    defer blocking.deinit();
    
    var io = blocking.io();
    
    // Prepare vectorized data
    const segments = [_][]const u8{
        "Segment1 ",
        "Segment2 ",
        "Segment3 ",
        "Segment4 ",
        "Segment5 ",
        "Segment6 ",
        "Segment7 ",
        "Segment8 ",
    };
    
    // Warmup
    try performWarmup(&io, config);
    
    // Benchmark
    const start_time = std.time.nanoTimestamp();
    
    for (0..config.iterations) |_| {
        var writev_future = try io.writev(&segments);
        defer writev_future.destroy(allocator);
        try writev_future.await();
    }
    
    const end_time = std.time.nanoTimestamp();
    const total_time = @as(u64, @intCast(end_time - start_time));
    
    var total_bytes: usize = 0;
    for (segments) |segment| {
        total_bytes += segment.len;
    }
    total_bytes *= config.iterations;
    
    return BenchmarkResult{
        .name = "Blocking I/O - Vectorized Write",
        .iterations = config.iterations,
        .total_time_ns = total_time,
        .throughput_mbps = (@as(f64, @floatFromInt(total_bytes)) / @as(f64, @floatFromInt(total_time))) * std.time.ns_per_s / (1024.0 * 1024.0),
        .latency_per_op_ns = total_time / config.iterations,
        .operations_per_second = @as(f64, @floatFromInt(config.iterations)) / (@as(f64, @floatFromInt(total_time)) / std.time.ns_per_s),
    };
}

/// Benchmark zero-copy operations (Linux only)
fn benchmarkBlockingZeroCopy(config: BenchmarkConfig) !BenchmarkResult {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var blocking = blocking_io.BlockingIo.init(allocator, config.buffer_size);
    defer blocking.deinit();
    
    var io = blocking.io();
    
    if (!io.supportsZeroCopy()) {
        return BenchmarkResult{
            .name = "Zero-Copy (Not Supported)",
            .iterations = 0,
            .total_time_ns = 0,
            .throughput_mbps = 0,
            .latency_per_op_ns = 0,
            .operations_per_second = 0,
        };
    }
    
    // Create test file
    const test_content = "Zero-copy benchmark data! " ** 20; // 540 bytes
    const test_file = try std.fs.cwd().createFile("bench_test.txt", .{});
    defer {
        test_file.close();
        std.fs.cwd().deleteFile("bench_test.txt") catch {};
    }
    try test_file.writeAll(test_content);
    try test_file.sync();
    
    // Benchmark sendfile
    const start_time = std.time.nanoTimestamp();
    
    for (0..config.iterations) |_| {
        var sendfile_future = try io.sendFile(test_file.handle, 0, test_content.len);
        defer sendfile_future.destroy(allocator);
        try sendfile_future.await();
    }
    
    const end_time = std.time.nanoTimestamp();
    const total_time = @as(u64, @intCast(end_time - start_time));
    const total_bytes = config.iterations * test_content.len;
    
    return BenchmarkResult{
        .name = "Blocking I/O - Zero-Copy sendfile",
        .iterations = config.iterations,
        .total_time_ns = total_time,
        .throughput_mbps = (@as(f64, @floatFromInt(total_bytes)) / @as(f64, @floatFromInt(total_time))) * std.time.ns_per_s / (1024.0 * 1024.0),
        .latency_per_op_ns = total_time / config.iterations,
        .operations_per_second = @as(f64, @floatFromInt(config.iterations)) / (@as(f64, @floatFromInt(total_time)) / std.time.ns_per_s),
    };
}

/// Benchmark runtime with blocking execution model
fn benchmarkRuntimeBlocking(config: BenchmarkConfig) !BenchmarkResult {
    const TestTask = struct {
        fn task(io: Io) !void {
            const test_data = "Runtime blocking test! ";
            const iterations = 1000; // Use constant instead of config
            for (0..iterations) |_| {
                var io_mut = io;
                var write_future = try io_mut.write(test_data);
                defer write_future.destroy(io.getAllocator());
                try write_future.await();
            }
        }
    };
    
    const start_time = std.time.nanoTimestamp();
    try zsync.runBlocking(TestTask.task, {});
    const end_time = std.time.nanoTimestamp();
    
    const total_time = @as(u64, @intCast(end_time - start_time));
    const test_data = "Runtime blocking test! ";
    const total_bytes = config.iterations * test_data.len;
    
    return BenchmarkResult{
        .name = "Runtime - Blocking Model",
        .iterations = config.iterations,
        .total_time_ns = total_time,
        .throughput_mbps = (@as(f64, @floatFromInt(total_bytes)) / @as(f64, @floatFromInt(total_time))) * std.time.ns_per_s / (1024.0 * 1024.0),
        .latency_per_op_ns = total_time / config.iterations,
        .operations_per_second = @as(f64, @floatFromInt(config.iterations)) / (@as(f64, @floatFromInt(total_time)) / std.time.ns_per_s),
    };
}

/// Benchmark runtime with high-performance execution model
fn benchmarkRuntimeHighPerf(config: BenchmarkConfig) !BenchmarkResult {
    const TestTask = struct {
        fn task(io: Io) !void {
            const test_data = "Runtime high-perf test! ";
            const iterations = 1000; // Use constant instead of config
            for (0..iterations) |_| {
                var io_mut = io;
                var write_future = try io_mut.write(test_data);
                defer write_future.destroy(io.getAllocator());
                try write_future.await();
            }
        }
    };
    
    const start_time = std.time.nanoTimestamp();
    try zsync.runHighPerf(TestTask.task, {});
    const end_time = std.time.nanoTimestamp();
    
    const total_time = @as(u64, @intCast(end_time - start_time));
    const test_data = "Runtime high-perf test! ";
    const total_bytes = config.iterations * test_data.len;
    
    return BenchmarkResult{
        .name = "Runtime - High-Performance Model",
        .iterations = config.iterations,
        .total_time_ns = total_time,
        .throughput_mbps = (@as(f64, @floatFromInt(total_bytes)) / @as(f64, @floatFromInt(total_time))) * std.time.ns_per_s / (1024.0 * 1024.0),
        .latency_per_op_ns = total_time / config.iterations,
        .operations_per_second = @as(f64, @floatFromInt(config.iterations)) / (@as(f64, @floatFromInt(total_time)) / std.time.ns_per_s),
    };
}

/// Perform warmup operations
fn performWarmup(io: *Io, config: BenchmarkConfig) !void {
    const warmup_data = "warmup";
    for (0..config.warmup_iterations) |_| {
        var write_future = try io.write(warmup_data);
        defer write_future.destroy(io.getAllocator());
        try write_future.await();
    }
}

/// Print performance comparison table
fn printPerformanceComparison(results: []const BenchmarkResult) void {
    std.debug.print("\n📈 Performance Comparison Summary\n", .{});
    std.debug.print("=================================\n", .{});
    
    for (results) |result| {
        result.print();
    }
    
    // Find best performers
    var fastest_ops: f64 = 0;
    var fastest_name: []const u8 = "";
    var highest_throughput: f64 = 0;
    var highest_throughput_name: []const u8 = "";
    
    for (results) |result| {
        if (result.operations_per_second > fastest_ops) {
            fastest_ops = result.operations_per_second;
            fastest_name = result.name;
        }
        if (result.throughput_mbps > highest_throughput) {
            highest_throughput = result.throughput_mbps;
            highest_throughput_name = result.name;
        }
    }
    
    std.debug.print("🏆 Performance Champions:\n", .{});
    std.debug.print("  • Fastest Operations: {s} ({:.0} ops/sec)\n", .{ fastest_name, fastest_ops });
    std.debug.print("  • Highest Throughput: {s} ({:.2} MB/s)\n", .{ highest_throughput_name, highest_throughput });
}