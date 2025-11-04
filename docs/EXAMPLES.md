# Zsync v0.7.0 Examples

Real-world examples demonstrating zsync capabilities.

## Table of Contents

- [HTTP Server](#http-server)
- [File Processing Pipeline](#file-processing-pipeline)
- [Worker Pool Pattern](#worker-pool-pattern)
- [Producer-Consumer with Channels](#producer-consumer-with-channels)
- [Parallel Data Processing](#parallel-data-processing)
- [Zero-Copy File Operations](#zero-copy-file-operations)

---

## HTTP Server

Simple concurrent HTTP server using zsync:

```zig
const std = @import("std");
const zsync = @import("zsync");

fn handleClient(conn_fd: std.posix.fd_t, pool: *zsync.BufferPool) !void {
    defer std.posix.close(conn_fd);

    // Acquire buffer from pool
    const buffer = try pool.acquire();
    defer buffer.release();

    // Read HTTP request
    const bytes_read = try std.posix.read(conn_fd, buffer.data);
    if (bytes_read == 0) return;

    // Simple HTTP response
    const response =
        \\HTTP/1.1 200 OK
        \\Content-Type: text/plain
        \\Content-Length: 13
        \\
        \\Hello, Zsync!
    ;

    _ = try std.posix.write(conn_fd, response);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create runtime with green threads for I/O performance
    const runtime = try zsync.Runtime.init(allocator, .{
        .execution_model = .auto, // Uses green_threads on Linux
    });
    defer runtime.deinit();

    runtime.setGlobal();
    defer {
        zsync.runtime.global_runtime_mutex.lock();
        zsync.runtime.global_runtime = null;
        zsync.runtime.global_runtime_mutex.unlock();
    }

    // Create buffer pool for connections
    const pool = try zsync.BufferPool.init(allocator, .{
        .initial_capacity = 32,
        .buffer_size = 8192,
        .max_cached = 128,
    });
    defer pool.deinit();

    // Create listening socket
    const addr = try std.net.Address.parseIp("127.0.0.1", 8080);
    const listen_fd = try std.posix.socket(
        addr.any.family,
        std.posix.SOCK.STREAM,
        std.posix.IPPROTO.TCP,
    );
    defer std.posix.close(listen_fd);

    try std.posix.setsockopt(
        listen_fd,
        std.posix.SOL.SOCKET,
        std.posix.SO.REUSEADDR,
        &std.mem.toBytes(@as(c_int, 1)),
    );

    try std.posix.bind(listen_fd, &addr.any, addr.getOsSockLen());
    try std.posix.listen(listen_fd, 128);

    std.debug.print("Server listening on http://127.0.0.1:8080\n", .{});

    // Accept connections
    const nursery = try zsync.Nursery.init(allocator, runtime);
    defer nursery.deinit();

    var count: usize = 0;
    while (count < 100) : (count += 1) { // Limit for demo
        var client_addr: std.net.Address = undefined;
        var addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);

        const conn_fd = std.posix.accept(
            listen_fd,
            @ptrCast(&client_addr.any),
            &addr_len,
            0,
        ) catch |err| {
            std.debug.print("Accept error: {}\n", .{err});
            continue;
        };

        // Spawn handler for each connection
        try nursery.spawn(handleClient, .{ conn_fd, pool });
    }

    try nursery.wait();
    std.debug.print("Handled {d} connections\n", .{count});
}
```

---

## File Processing Pipeline

Process files in parallel with structured concurrency:

```zig
const std = @import("std");
const zsync = @import("zsync");

const FileJob = struct {
    path: []const u8,
    size: usize,
};

fn processFile(job: FileJob, allocator: std.mem.Allocator) !void {
    std.debug.print("Processing: {s} ({d} bytes)\n", .{ job.path, job.size });

    const file = try std.fs.cwd().openFile(job.path, .{});
    defer file.close();

    // Simulate processing
    std.posix.nanosleep(0, 100 * std.time.ns_per_ms);

    std.debug.print("Completed: {s}\n", .{job.path});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const runtime = try zsync.Runtime.init(allocator, .{
        .execution_model = .thread_pool,
        .num_workers = 4,
    });
    defer runtime.deinit();

    runtime.setGlobal();
    defer {
        zsync.runtime.global_runtime_mutex.lock();
        zsync.runtime.global_runtime = null;
        zsync.runtime.global_runtime_mutex.unlock();
    }

    // Discover files to process
    const files = [_]FileJob{
        .{ .path = "file1.txt", .size = 1024 },
        .{ .path = "file2.txt", .size = 2048 },
        .{ .path = "file3.txt", .size = 512 },
        .{ .path = "file4.txt", .size = 4096 },
    };

    // Process all files concurrently
    const nursery = try zsync.Nursery.init(allocator, runtime);
    defer nursery.deinit();

    for (files) |job| {
        try nursery.spawn(processFile, .{ job, allocator });
    }

    try nursery.wait();
    std.debug.print("All files processed!\n", .{});
}
```

---

## Worker Pool Pattern

Fixed-size worker pool processing jobs from a channel:

```zig
const std = @import("std");
const zsync = @import("zsync");

const Job = struct {
    id: u32,
    data: []const u8,
};

fn worker(
    id: u32,
    jobs: *zsync.Channel(Job),
    results: *zsync.Channel(u32),
) !void {
    while (true) {
        const job = jobs.tryRecv() orelse break;

        std.debug.print("Worker {d} processing job {d}\n", .{ id, job.id });

        // Simulate work
        std.posix.nanosleep(0, 50 * std.time.ns_per_ms);

        try results.send(job.id);
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const runtime = try zsync.Runtime.init(allocator, .{
        .execution_model = .thread_pool,
        .num_workers = 4,
    });
    defer runtime.deinit();

    runtime.setGlobal();
    defer {
        zsync.runtime.global_runtime_mutex.lock();
        zsync.runtime.global_runtime = null;
        zsync.runtime.global_runtime_mutex.unlock();
    }

    // Create channels
    var jobs = try zsync.channels.bounded(Job, allocator, 100);
    defer jobs.deinit();

    var results = try zsync.channels.bounded(u32, allocator, 100);
    defer results.deinit();

    // Spawn workers
    const nursery = try zsync.Nursery.init(allocator, runtime);
    defer nursery.deinit();

    const num_workers = 4;
    var i: u32 = 0;
    while (i < num_workers) : (i += 1) {
        try nursery.spawn(worker, .{ i, &jobs, &results });
    }

    // Send jobs
    const num_jobs = 20;
    var job_id: u32 = 0;
    while (job_id < num_jobs) : (job_id += 1) {
        try jobs.send(.{ .id = job_id, .data = "sample data" });
    }

    // Close jobs channel to signal workers
    jobs.close();

    // Wait for all workers
    try nursery.wait();

    // Collect results
    var completed: u32 = 0;
    while (results.tryRecv()) |result_id| {
        std.debug.print("Job {d} completed\n", .{result_id});
        completed += 1;
    }

    std.debug.print("Processed {d}/{d} jobs\n", .{ completed, num_jobs });
}
```

---

## Producer-Consumer with Channels

Classic producer-consumer pattern:

```zig
const std = @import("std");
const zsync = @import("zsync");

fn producer(channel: *zsync.Channel(i32), count: u32) !void {
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        try channel.send(@intCast(i));
        std.posix.nanosleep(0, 10 * std.time.ns_per_ms);
    }
    channel.close();
    std.debug.print("Producer finished\n", .{});
}

fn consumer(id: u32, channel: *zsync.Channel(i32)) !void {
    while (true) {
        const value = channel.tryRecv() orelse {
            if (channel.isClosed()) break;
            std.posix.nanosleep(0, 5 * std.time.ns_per_ms);
            continue;
        };

        std.debug.print("Consumer {d} got: {d}\n", .{ id, value });
        std.posix.nanosleep(0, 20 * std.time.ns_per_ms);
    }
    std.debug.print("Consumer {d} finished\n", .{id});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const runtime = try zsync.Runtime.init(allocator, .{
        .execution_model = .thread_pool,
        .num_workers = 4,
    });
    defer runtime.deinit();

    runtime.setGlobal();
    defer {
        zsync.runtime.global_runtime_mutex.lock();
        zsync.runtime.global_runtime = null;
        zsync.runtime.global_runtime_mutex.unlock();
    }

    var channel = try zsync.channels.bounded(i32, allocator, 10);
    defer channel.deinit();

    const nursery = try zsync.Nursery.init(allocator, runtime);
    defer nursery.deinit();

    // Spawn 1 producer
    try nursery.spawn(producer, .{ &channel, 50 });

    // Spawn 3 consumers
    try nursery.spawn(consumer, .{ 1, &channel });
    try nursery.spawn(consumer, .{ 2, &channel });
    try nursery.spawn(consumer, .{ 3, &channel });

    try nursery.wait();
    std.debug.print("All done!\n", .{});
}
```

---

## Parallel Data Processing

Process data arrays in parallel chunks:

```zig
const std = @import("std");
const zsync = @import("zsync");

fn processChunk(data: []const i32, result: *std.atomic.Value(i64)) !void {
    var sum: i64 = 0;
    for (data) |value| {
        sum += value;
    }
    _ = result.fetchAdd(sum, .release);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const runtime = try zsync.Runtime.init(allocator, .{
        .execution_model = .thread_pool,
        .num_workers = 4,
    });
    defer runtime.deinit();

    runtime.setGlobal();
    defer {
        zsync.runtime.global_runtime_mutex.lock();
        zsync.runtime.global_runtime = null;
        zsync.runtime.global_runtime_mutex.unlock();
    }

    // Create large dataset
    const data_size = 1_000_000;
    const data = try allocator.alloc(i32, data_size);
    defer allocator.free(data);

    for (data, 0..) |*val, i| {
        val.* = @intCast(i % 100);
    }

    // Split into chunks for parallel processing
    const chunk_size = 250_000;
    const num_chunks = data_size / chunk_size;

    var total_sum = std.atomic.Value(i64).init(0);

    const nursery = try zsync.Nursery.init(allocator, runtime);
    defer nursery.deinit();

    var i: usize = 0;
    while (i < num_chunks) : (i += 1) {
        const start = i * chunk_size;
        const end = @min((i + 1) * chunk_size, data_size);
        const chunk = data[start..end];

        try nursery.spawn(processChunk, .{ chunk, &total_sum });
    }

    try nursery.wait();

    const result = total_sum.load(.acquire);
    std.debug.print("Total sum: {d}\n", .{result});
}
```

---

## Zero-Copy File Operations

Efficiently copy files using zero-copy techniques:

```zig
const std = @import("std");
const zsync = @import("zsync");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Method 1: High-level zero-copy
    {
        const bytes = try zsync.copyFileZeroCopy(
            allocator,
            "large_file.bin",
            "copy1.bin",
        );
        std.debug.print("Copied {d} bytes using copyFileZeroCopy\n", .{bytes});
    }

    // Method 2: Manual sendfile (more control)
    {
        const source = try std.fs.cwd().openFile("large_file.bin", .{});
        defer source.close();

        const dest = try std.fs.cwd().createFile("copy2.bin", .{});
        defer dest.close();

        const stat = try source.stat();
        var offset: i64 = 0;
        const bytes = try zsync.sendfile(
            dest.handle,
            source.handle,
            &offset,
            stat.size,
        );

        std.debug.print("Copied {d} bytes using sendfile\n", .{bytes});
    }

    // Method 3: Buffer pool for custom processing
    {
        const pool = try zsync.BufferPool.init(allocator, .{
            .buffer_size = 1024 * 1024, // 1MB buffers
            .initial_capacity = 4,
        });
        defer pool.deinit();

        const source = try std.fs.cwd().openFile("large_file.bin", .{});
        defer source.close();

        const dest = try std.fs.cwd().createFile("copy3.bin", .{});
        defer dest.close();

        var total: usize = 0;
        while (true) {
            const buffer = try pool.acquire();
            defer buffer.release();

            const bytes_read = try source.read(buffer.data);
            if (bytes_read == 0) break;

            try dest.writeAll(buffer.data[0..bytes_read]);
            total += bytes_read;
        }

        std.debug.print("Copied {d} bytes using buffer pool\n", .{total});
    }
}
```

---

## Best Practices

1. **Always use nurseries for multiple tasks** - Prevents task leaks
2. **Release buffers promptly** - Keeps pool available
3. **Use channels for task communication** - Thread-safe messaging
4. **Set worker count based on workload**:
   - CPU-bound: `num_workers = CPU cores`
   - I/O-bound: `num_workers = CPU cores * 2-4`
5. **Use `.auto` execution model** - Platform-optimal selection
6. **Handle errors properly** - Tasks can fail
7. **Close channels when done** - Signals consumers to exit

---

For more information:
- [Getting Started](GETTING_STARTED.md)
- [API Reference](API_REFERENCE.md)
- [Performance Guide](PERFORMANCE.md)
