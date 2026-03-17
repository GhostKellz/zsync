# Zsync Integration Guide

Async runtime for Zig with colorblind async/await - same code works across all execution models.

## Quick Start

```zig
const std = @import("std");
const zsync = @import("zsync");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create runtime (auto-detects optimal execution model)
    const runtime = try zsync.Runtime.init(allocator, .{});
    defer runtime.deinit();

    // Run your async task
    try runtime.run(myTask, .{});
}

fn myTask(io: zsync.Io) !void {
    // This code works identically in blocking, thread_pool, or green_threads mode
    var future = try io.write("Hello from zsync!\n");
    defer future.destroy(io.getAllocator());
    try future.await();
}
```

## Canonical I/O Pattern

Zsync provides a single, consistent I/O interface across all execution models:

```
┌─────────────────────────────────────────────────────┐
│                   Your Application                   │
├─────────────────────────────────────────────────────┤
│   zsync.Io interface (vtable dispatch)              │
├──────────┬──────────────┬──────────────┬────────────┤
│ blocking │ thread_pool  │ green_threads│ stackless  │
│   I/O    │    I/O       │     I/O      │   I/O      │
├──────────┴──────────────┴──────────────┴────────────┤
│              OS / Platform Layer                     │
└─────────────────────────────────────────────────────┘
```

### The Io Interface

All async operations go through `zsync.Io`:

```zig
fn myTask(io: zsync.Io) !void {
    // Read
    var read_future = try io.read(buffer);
    defer read_future.destroy(io.getAllocator());
    try read_future.await();

    // Write
    var write_future = try io.write(data);
    defer write_future.destroy(io.getAllocator());
    try write_future.await();

    // Vectorized I/O
    var readv_future = try io.readv(&buffers);
    defer readv_future.destroy(io.getAllocator());
    try readv_future.await();

    // Network
    var accept_future = try io.accept(listener_fd);
    defer accept_future.destroy(io.getAllocator());
    try accept_future.await();
}
```

### Dependency Injection

The `Io` parameter is passed to your task function. This makes testing easy:

```zig
// Production code
try runtime.run(myTask, .{});

// Test code - use blocking I/O directly
var blocking = try zsync.BlockingIo.init(allocator);
defer blocking.deinit();
try myTask(blocking.io());
```

## Build Integration

Add to `build.zig.zon`:

```bash
zig fetch --save https://github.com/ghostkellz/zsync/archive/refs/heads/main.tar.gz
```

Add to `build.zig`:

```zig
const zsync = b.dependency("zsync", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("zsync", zsync.module("zsync"));
```

## Execution Models

### Blocking (Direct syscalls)
```zig
const config = zsync.Config{ .execution_model = .blocking };
```
- Zero overhead
- No parallelism
- Best for: Simple programs, testing

### Thread Pool (OS threads)
```zig
const config = zsync.Config{
    .execution_model = .thread_pool,
    .thread_pool_threads = 4,
};
```
- True parallelism
- Best for: CPU-bound work

### Green Threads (Linux 5.1+ with io_uring)
```zig
const config = zsync.Config{
    .execution_model = .green_threads,
    .max_green_threads = 1024,
};
```
- High concurrency with low overhead
- Best for: I/O-bound servers

### Auto (Recommended)
```zig
const config = zsync.Config{ .execution_model = .auto };
```
- Detects optimal model for platform
- Uses green_threads on Linux 5.1+, thread_pool elsewhere

## Core Types

| Type | Description |
|------|-------------|
| `Runtime` | Main runtime instance |
| `Config` | Runtime configuration |
| `Io` | Unified I/O interface |
| `Future` | Pending async operation |
| `CancelToken` | Cooperative cancellation |

## Higher-Level Primitives

### Structured Concurrency (Nursery)

```zig
const nursery = try zsync.Nursery.init(allocator, runtime);
defer nursery.deinit();

try nursery.spawn(task1, .{});
try nursery.spawn(task2, .{});
try nursery.spawn(task3, .{});

try nursery.wait(); // All tasks complete or error
```

### Channels

```zig
var ch = try zsync.channels.bounded(i32, allocator, 100);
defer ch.deinit();

try ch.send(42);
const value = try ch.recv();
```

### Buffer Pool

```zig
const pool = try zsync.BufferPool.init(allocator, .{
    .buffer_size = 4096,
    .max_cached = 64,
});
defer pool.deinit();

const buf = try pool.acquire();
defer buf.release();
```

## Error Handling

```zig
fn myTask(io: zsync.Io) !void {
    var future = io.read(buffer) catch |err| switch (err) {
        zsync.IoError.WouldBlock => return,
        zsync.IoError.ConnectionClosed => return,
        else => return err,
    };
    defer future.destroy(io.getAllocator());

    future.await() catch |err| {
        std.log.err("I/O failed: {}", .{err});
        return err;
    };
}
```

## Platform Support

| Platform | Blocking | Thread Pool | Green Threads |
|----------|----------|-------------|---------------|
| Linux 5.1+ | Yes | Yes | Yes (io_uring) |
| Linux < 5.1 | Yes | Yes | No |
| macOS | Yes | Yes | No |
| Windows | Yes | Yes | No |
| FreeBSD | Yes | Yes | No |
| WASM | Yes | No | No |

## Testing

```zig
const testing = std.testing;
const zsync = @import("zsync");

test "zsync integration" {
    const TestTask = struct {
        fn run(io: zsync.Io) !void {
            var future = try io.write("test");
            defer future.destroy(testing.allocator);
            try future.await();
        }
    };

    // Use blocking for deterministic tests
    try zsync.runBlocking(TestTask.run);
}
```

## Convenience Functions

```zig
// Auto-detect execution model
try zsync.run(myTask, args);

// Force blocking mode
try zsync.runBlocking(myTask, args);

// High-performance (thread pool, 8 threads)
try zsync.runHighPerf(myTask, args);
```

## See Also

- [Getting Started](GETTING_STARTED.md)
- [API Reference](API_REFERENCE.md)
- [Examples](EXAMPLES.md)
- [Performance](PERFORMANCE.md)
