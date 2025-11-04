//! Zsync v0.7.0 Feature Tests
//! Comprehensive test suite for new v0.7.0 features

const std = @import("std");
const zsync = @import("zsync");
const testing = std.testing;

test "v0.7.0: Task spawning basic" {
    const allocator = testing.allocator;

    const config = zsync.Config{
        .execution_model = .blocking,
    };

    const rt = try zsync.Runtime.init(allocator, config);
    defer rt.deinit();

    rt.setGlobal();
    defer {
        zsync.runtime.global_runtime_mutex.lock();
        zsync.runtime.global_runtime = null;
        zsync.runtime.global_runtime_mutex.unlock();
    }

    const TestTask = struct {
        fn task() !void {
            std.posix.nanosleep(0, 1_000_000); // 1ms
        }
    };

    // Spawn a task
    const future = try zsync.spawn(TestTask.task, .{});
    try future.await();
}

test "v0.7.0: Task spawning with thread pool" {
    const allocator = testing.allocator;

    const config = zsync.Config{
        .execution_model = .thread_pool,
        .num_workers = 2,
    };

    const rt = try zsync.Runtime.init(allocator, config);
    defer rt.deinit();

    rt.setGlobal();
    defer {
        zsync.runtime.global_runtime_mutex.lock();
        zsync.runtime.global_runtime = null;
        zsync.runtime.global_runtime_mutex.unlock();
    }

    var counter = std.atomic.Value(u32).init(0);

    const TestTask = struct {
        fn task(c: *std.atomic.Value(u32)) !void {
            _ = c.fetchAdd(1, .release);
            std.posix.nanosleep(0, 5_000_000); // 5ms
        }
    };

    // Spawn multiple tasks
    const f1 = try zsync.spawn(TestTask.task, .{&counter});
    const f2 = try zsync.spawn(TestTask.task, .{&counter});
    const f3 = try zsync.spawn(TestTask.task, .{&counter});

    try f1.await();
    try f2.await();
    try f3.await();

    try testing.expectEqual(@as(u32, 3), counter.load(.acquire));
}

test "v0.7.0: Nursery basic functionality" {
    const allocator = testing.allocator;

    const config = zsync.Config{
        .execution_model = .blocking,
    };

    const rt = try zsync.Runtime.init(allocator, config);
    defer rt.deinit();

    rt.setGlobal();
    defer {
        zsync.runtime.global_runtime_mutex.lock();
        zsync.runtime.global_runtime = null;
        zsync.runtime.global_runtime_mutex.unlock();
    }

    const nursery = try zsync.Nursery.init(allocator, rt);
    defer nursery.deinit();

    var counter = std.atomic.Value(u32).init(0);

    const Task = struct {
        fn work(c: *std.atomic.Value(u32)) !void {
            _ = c.fetchAdd(1, .release);
        }
    };

    try nursery.spawn(Task.work, .{&counter});
    try nursery.spawn(Task.work, .{&counter});
    try nursery.spawn(Task.work, .{&counter});

    try nursery.wait();

    try testing.expectEqual(@as(u32, 3), counter.load(.acquire));
    try testing.expect(nursery.isComplete());
}

test "v0.7.0: Nursery with RAII pattern" {
    const allocator = testing.allocator;

    const config = zsync.Config{
        .execution_model = .blocking,
    };

    const rt = try zsync.Runtime.init(allocator, config);
    defer rt.deinit();

    rt.setGlobal();
    defer {
        zsync.runtime.global_runtime_mutex.lock();
        zsync.runtime.global_runtime = null;
        zsync.runtime.global_runtime_mutex.unlock();
    }

    var result = std.atomic.Value(u32).init(0);

    const TestFunc = struct {
        fn runTasks(n: *zsync.Nursery, r: *std.atomic.Value(u32)) !void {
            const Task = struct {
                fn task(res: *std.atomic.Value(u32)) !void {
                    _ = res.fetchAdd(1, .release);
                }
            };

            try n.spawn(Task.task, .{r});
            try n.spawn(Task.task, .{r});
        }
    };

    try zsync.withNursery(allocator, rt, TestFunc.runTasks, .{&result});

    try testing.expectEqual(@as(u32, 2), result.load(.acquire));
}

test "v0.7.0: Buffer pool operations" {
    const allocator = testing.allocator;

    const config = zsync.BufferPoolConfig{
        .initial_capacity = 4,
        .buffer_size = 1024,
        .max_cached = 8,
    };

    const pool = try zsync.BufferPool.init(allocator, config);
    defer pool.deinit();

    // Acquire buffers
    const buf1 = try pool.acquire();
    const buf2 = try pool.acquire();

    try testing.expect(buf1.in_use);
    try testing.expect(buf2.in_use);
    try testing.expectEqual(@as(usize, 1024), buf1.data.len);

    // Write to buffer
    @memcpy(buf1.data[0..5], "Hello");

    // Check stats
    const stats = pool.stats();
    try testing.expectEqual(@as(usize, 2), stats.total_in_use);

    // Release buffers
    buf1.release();
    buf2.release();

    const final_stats = pool.stats();
    try testing.expectEqual(@as(usize, 0), final_stats.total_in_use);
}

test "v0.7.0: Buffer pool reuse" {
    const allocator = testing.allocator;

    const config = zsync.BufferPoolConfig{
        .initial_capacity = 2,
        .buffer_size = 512,
        .max_cached = 4,
    };

    const pool = try zsync.BufferPool.init(allocator, config);
    defer pool.deinit();

    // First use
    {
        const buffer = try pool.acquire();
        defer buffer.release();
        @memcpy(buffer.data[0..4], "Test");
    }

    // Second use - buffer should be reused
    {
        const buffer = try pool.acquire();
        defer buffer.release();
        // Data from previous use is still there
        try testing.expectEqual(@as(u8, 'T'), buffer.data[0]);
    }
}

test "v0.7.0: Channels basic send/recv" {
    const allocator = testing.allocator;

    var ch = try zsync.channels.bounded(i32, allocator, 10);
    defer ch.deinit();

    try ch.send(42);
    try ch.send(100);

    const val1 = try ch.recv();
    const val2 = try ch.recv();

    try testing.expectEqual(@as(i32, 42), val1);
    try testing.expectEqual(@as(i32, 100), val2);
}

test "v0.7.0: Unbounded channel" {
    const allocator = testing.allocator;

    var ch = try zsync.channels.unbounded(i32, allocator);
    defer ch.deinit();

    try ch.send(1);
    try ch.send(2);
    try ch.send(3);

    try testing.expectEqual(@as(usize, 3), ch.len());

    const val1 = try ch.recv();
    const val2 = try ch.recv();
    const val3 = try ch.recv();

    try testing.expectEqual(@as(i32, 1), val1);
    try testing.expectEqual(@as(i32, 2), val2);
    try testing.expectEqual(@as(i32, 3), val3);
}

test "v0.7.0: Channel close behavior" {
    const allocator = testing.allocator;

    var ch = try zsync.channels.bounded(i32, allocator, 5);
    defer ch.deinit();

    ch.close();

    try testing.expect(ch.isClosed());
    try testing.expectError(error.ChannelClosed, ch.send(42));
    try testing.expectError(error.ChannelClosed, ch.recv());
}

test "v0.7.0: Runtime metrics" {
    const allocator = testing.allocator;

    const config = zsync.Config{
        .execution_model = .blocking,
    };

    const rt = try zsync.Runtime.init(allocator, config);
    defer rt.deinit();

    const metrics = rt.getMetrics();

    // Should start with 0 futures
    try testing.expectEqual(@as(u64, 0), metrics.futures_created);
}

test "v0.7.0: Multiple runtimes isolation" {
    const allocator = testing.allocator;

    const config = zsync.Config{
        .execution_model = .blocking,
    };

    const rt1 = try zsync.Runtime.init(allocator, config);
    defer rt1.deinit();

    const rt2 = try zsync.Runtime.init(allocator, config);
    defer rt2.deinit();

    // Each runtime should be independent
    try testing.expect(rt1 != rt2);
}

test "v0.7.0: Execution model detection" {
    // Test that auto detection works
    const model = zsync.ExecutionModel.detect();

    // Should return a valid model
    try testing.expect(model != .auto);
}
