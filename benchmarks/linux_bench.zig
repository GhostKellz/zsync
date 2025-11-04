//! Zsync v0.7.0 - Linux Performance Benchmarks
//! Focused benchmarks for Linux-specific features

const std = @import("std");
const zsync = @import("zsync");

const BenchResult = struct {
    name: []const u8,
    iterations: u64,
    total_ns: u64,
    avg_ns: u64,
    ops_per_sec: u64,

    fn print(self: BenchResult) void {
        std.debug.print("\n{s}:\n", .{self.name});
        std.debug.print("  Iterations: {d}\n", .{self.iterations});
        std.debug.print("  Total time: {d}ms\n", .{self.total_ns / std.time.ns_per_ms});
        std.debug.print("  Average: {d}ns\n", .{self.avg_ns});
        std.debug.print("  Throughput: {d} ops/sec\n", .{self.ops_per_sec});
    }
};

fn benchmark(
    _: std.mem.Allocator,
    comptime name: []const u8,
    iterations: u64,
    comptime func: anytype,
    args: anytype,
) !BenchResult {
    std.debug.print("Running {s}...\n", .{name});

    const start = try std.time.Instant.now();

    var i: u64 = 0;
    while (i < iterations) : (i += 1) {
        try @call(.auto, func, args);
    }

    const end = try std.time.Instant.now();
    const total_ns = end.since(start);
    const avg_ns = total_ns / iterations;
    const ops_per_sec = (iterations * std.time.ns_per_s) / total_ns;

    return BenchResult{
        .name = name,
        .iterations = iterations,
        .total_ns = total_ns,
        .avg_ns = avg_ns,
        .ops_per_sec = ops_per_sec,
    };
}

// Task spawning benchmark
fn taskSpawnBench(runtime: *zsync.Runtime) !void {
    const Task = struct {
        fn run() !void {
            // Minimal task
        }
    };

    var future = try runtime.spawn(Task.run, .{});
    try future.await();
}

// Channel throughput benchmark
fn channelThroughputBench(ch: *zsync.Channel(i32)) !void {
    try ch.send(42);
    _ = try ch.recv();
}

// Buffer pool benchmark
fn bufferPoolBench(pool: *zsync.BufferPool) !void {
    const buf = try pool.acquire();
    buf.release();
}

// Nursery overhead benchmark
fn nurseryBench(allocator: std.mem.Allocator, runtime: *zsync.Runtime) !void {
    const nursery = try zsync.Nursery.init(allocator, runtime);
    defer nursery.deinit();

    const Task = struct {
        fn run() !void {}
    };

    try nursery.spawn(Task.run, .{});
    try nursery.wait();
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Zsync v{s} Linux Benchmarks ===\n", .{zsync.VERSION});
    std.debug.print("Platform: Linux\n", .{});
    std.debug.print("Architecture: {s}\n\n", .{@tagName(@import("builtin").target.cpu.arch)});

    // Benchmark 1: Task Spawning (Blocking)
    {
        const runtime = try zsync.Runtime.init(allocator, .{
            .execution_model = .blocking,
        });
        defer runtime.deinit();

        const result = try benchmark(
            allocator,
            "Task Spawn (Blocking)",
            10_000,
            taskSpawnBench,
            .{runtime},
        );
        result.print();
    }

    // Benchmark 2: Task Spawning (Thread Pool)
    {
        const runtime = try zsync.Runtime.init(allocator, .{
            .execution_model = .thread_pool,
            .thread_pool_threads = 4,
        });
        defer runtime.deinit();

        const result = try benchmark(
            allocator,
            "Task Spawn (Thread Pool)",
            1_000,
            taskSpawnBench,
            .{runtime},
        );
        result.print();
    }

    // Benchmark 3: Channel Throughput
    {
        var ch = try zsync.channels.bounded(i32, allocator, 1000);
        defer ch.deinit();

        const result = try benchmark(
            allocator,
            "Channel Send/Recv",
            100_000,
            channelThroughputBench,
            .{&ch},
        );
        result.print();
    }

    // Benchmark 4: Buffer Pool
    {
        const pool = try zsync.BufferPool.init(allocator, .{
            .initial_capacity = 16,
            .buffer_size = 4096,
            .max_cached = 64,
        });
        defer pool.deinit();

        const result = try benchmark(
            allocator,
            "Buffer Pool Acquire/Release",
            100_000,
            bufferPoolBench,
            .{pool},
        );
        result.print();
    }

    // Benchmark 5: Nursery Overhead
    {
        const runtime = try zsync.Runtime.init(allocator, .{
            .execution_model = .blocking,
        });
        defer runtime.deinit();

        const result = try benchmark(
            allocator,
            "Nursery Create/Spawn/Wait",
            1_000,
            nurseryBench,
            .{ allocator, runtime },
        );
        result.print();
    }

    // Benchmark 6: Stream Operations
    {
        const items = try allocator.alloc(i64, 10_000);
        defer allocator.free(items);

        for (items, 0..) |*item, i| {
            item.* = @intCast(i);
        }

        const StreamBench = struct {
            fn run(alloc: std.mem.Allocator, data: []const i64) !void {
                var stream = try zsync.fromSlice(i64, alloc, data);
                defer stream.deinit();

                const double = struct {
                    fn f(x: i64) i64 {
                        return x * 2;
                    }
                }.f;

                const isEven = struct {
                    fn f(x: i64) bool {
                        return @mod(x, 2) == 0;
                    }
                }.f;

                var mapped = try stream.map(double);
                defer mapped.deinit();

                var filtered = try mapped.filter(isEven);
                defer filtered.deinit();

                _ = filtered.count();
            }
        };

        const result = try benchmark(
            allocator,
            "Stream Map+Filter+Count (10K items)",
            100,
            StreamBench.run,
            .{ allocator, items },
        );
        result.print();
    }

    std.debug.print("\n=== Benchmark Complete ===\n", .{});
}
