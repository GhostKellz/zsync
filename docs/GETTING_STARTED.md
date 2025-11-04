# Getting Started with Zsync v0.7.0

**Zsync** is a production-ready async runtime for Zig - "The Tokio of Zig". It provides colorblind async programming where the same code works across multiple execution models.

## Installation

### Option 1: Using Zig Package Manager (Recommended)

Add zsync to your `build.zig.zon`:

```zig
.{
    .name = "my-project",
    .version = "0.1.0",
    .dependencies = .{
        .zsync = .{
            .url = "https://github.com/ghostkellz/zsync/archive/v0.7.0.tar.gz",
            // Hash will be provided by `zig fetch`
        },
    },
}
```

Then in your `build.zig`:

```zig
const zsync = b.dependency("zsync", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("zsync", zsync.module("zsync"));
```

### Option 2: Manual Installation

Clone the repository:

```bash
git clone https://github.com/ghostkellz/zsync.git
cd zsync
zig build
```

## Quick Start

### 1. Hello World - Blocking Execution

The simplest way to use zsync:

```zig
const std = @import("std");
const zsync = @import("zsync");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create runtime with blocking execution
    const config = zsync.Config{
        .execution_model = .blocking,
    };

    const runtime = try zsync.Runtime.init(allocator, config);
    defer runtime.deinit();

    std.debug.print("Zsync v{s} initialized!\n", .{zsync.VERSION});
}
```

### 2. Spawning Tasks

Run concurrent tasks:

```zig
const std = @import("std");
const zsync = @import("zsync");

fn fetchData(id: u32) !void {
    std.debug.print("Fetching data {d}...\n", .{id});
    std.posix.nanosleep(0, 100 * std.time.ns_per_ms); // Simulate work
    std.debug.print("Data {d} complete!\n", .{id});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = zsync.Config{
        .execution_model = .thread_pool,
        .num_workers = 4,
    };

    const runtime = try zsync.Runtime.init(allocator, config);
    defer runtime.deinit();

    runtime.setGlobal();
    defer {
        zsync.runtime.global_runtime_mutex.lock();
        zsync.runtime.global_runtime = null;
        zsync.runtime.global_runtime_mutex.unlock();
    }

    // Spawn multiple tasks
    const future1 = try zsync.spawn(fetchData, .{1});
    const future2 = try zsync.spawn(fetchData, .{2});
    const future3 = try zsync.spawn(fetchData, .{3});

    // Wait for all tasks to complete
    try future1.await();
    try future2.await();
    try future3.await();
}
```

### 3. Structured Concurrency with Nursery

Safe task management with automatic cleanup:

```zig
const std = @import("std");
const zsync = @import("zsync");

fn processItem(id: u32) !void {
    std.debug.print("Processing item {d}\n", .{id});
    std.posix.nanosleep(0, 50 * std.time.ns_per_ms);
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

    // All tasks in nursery will complete before exit
    const nursery = try zsync.Nursery.init(allocator, runtime);
    defer nursery.deinit();

    try nursery.spawn(processItem, .{1});
    try nursery.spawn(processItem, .{2});
    try nursery.spawn(processItem, .{3});

    try nursery.wait(); // Blocks until all tasks complete
    std.debug.print("All items processed!\n", .{});
}
```

### 4. Channels for Communication

Send data between tasks:

```zig
const std = @import("std");
const zsync = @import("zsync");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create a bounded channel
    var channel = try zsync.channels.bounded(i32, allocator, 10);
    defer channel.deinit();

    // Send some values
    try channel.send(42);
    try channel.send(100);
    try channel.send(256);

    // Receive values
    const val1 = try channel.recv();
    const val2 = try channel.recv();
    const val3 = try channel.recv();

    std.debug.print("Received: {d}, {d}, {d}\n", .{val1, val2, val3});
}
```

### 5. Buffer Pool for Performance

Reuse buffers to reduce allocations:

```zig
const std = @import("std");
const zsync = @import("zsync");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create buffer pool
    const pool = try zsync.BufferPool.init(allocator, .{
        .initial_capacity = 16,
        .buffer_size = 4096,
        .max_cached = 64,
    });
    defer pool.deinit();

    // Acquire a buffer
    const buffer = try pool.acquire();
    defer buffer.release();

    // Use the buffer
    @memcpy(buffer.data[0..11], "Hello Zsync");
    std.debug.print("{s}\n", .{buffer.data[0..11]});

    // Check pool stats
    const stats = pool.stats();
    std.debug.print("Pool: {d} allocated, {d} in use\n", .{
        stats.total_allocated,
        stats.total_in_use,
    });
}
```

## Execution Models

Zsync supports multiple execution models:

### 1. **Blocking** - Direct syscalls
- Best for: Simple programs, testing
- Pros: Zero overhead, predictable
- Cons: No parallelism

```zig
const config = zsync.Config{ .execution_model = .blocking };
```

### 2. **Thread Pool** - OS threads
- Best for: CPU-bound work, true parallelism
- Pros: Leverages multiple cores
- Cons: Higher memory usage

```zig
const config = zsync.Config{
    .execution_model = .thread_pool,
    .num_workers = 4,
};
```

### 3. **Green Threads** - Cooperative multitasking (Linux 5.1+)
- Best for: I/O-bound servers, high concurrency
- Pros: Minimal overhead, high scalability
- Cons: Linux-only, requires io_uring

```zig
const config = zsync.Config{ .execution_model = .green_threads };
```

### 4. **Auto** - Platform detection (Recommended)
- Best for: Cross-platform applications
- Automatically selects the best model for your platform

```zig
const config = zsync.Config{ .execution_model = .auto };
```

## Platform Support

| Platform | Blocking | Thread Pool | Green Threads |
|----------|----------|-------------|---------------|
| Linux 5.1+ | ✅ | ✅ | ✅ (io_uring) |
| Linux < 5.1 | ✅ | ✅ | ❌ |
| macOS | ✅ | ✅ | ❌ |
| Windows | ✅ | ✅ | ❌ |
| FreeBSD/OpenBSD | ✅ | ✅ | ❌ |
| WASM | ✅ | ❌ | ❌ |

## Configuration Options

```zig
pub const Config = struct {
    /// Execution model to use
    execution_model: ExecutionModel = .auto,

    /// Number of worker threads (thread_pool only)
    num_workers: ?u32 = null,

    /// Enable runtime debugging
    enable_debugging: bool = false,

    /// Stack size for green threads (bytes)
    green_thread_stack_size: usize = 65536, // 64KB

    /// Maximum number of green threads
    max_green_threads: u32 = 1024,

    /// io_uring queue depth (Linux only)
    queue_depth: ?u32 = null,
};
```

## Next Steps

- Read the [API Reference](API_REFERENCE.md) for detailed API documentation
- Check out [Examples](EXAMPLES.md) for real-world use cases
- Learn about [Performance Tuning](PERFORMANCE.md)
- Understand the [Architecture](ARCHITECTURE.md)

## Common Patterns

### Error Handling

All zsync functions return errors that should be handled:

```zig
const future = zsync.spawn(myTask, .{}) catch |err| {
    std.debug.print("Failed to spawn: {}\n", .{err});
    return err;
};
```

### Timeouts

Currently manual, but coming in v0.8:

```zig
const start = std.time.Instant.now() catch unreachable;
while (future.poll() == .pending) {
    const now = std.time.Instant.now() catch unreachable;
    if (now.since(start) > 5 * std.time.ns_per_s) {
        future.cancel();
        return error.Timeout;
    }
    std.posix.nanosleep(0, 1 * std.time.ns_per_ms);
}
```

## Troubleshooting

### "RuntimeNotInitialized" error
Make sure to call `runtime.setGlobal()` after creating the runtime.

### "BufferPoolExhausted" error
Increase `max_cached` in BufferPoolConfig or release buffers sooner.

### "GreenThreadsNotSupported" error
Green threads require Linux 5.1+. Use `.auto` to fall back to thread_pool.

## Contributing

Zsync is part of the Ghostkellz ecosystem. Contributions welcome!

- GitHub: https://github.com/ghostkellz/zsync
- Issues: https://github.com/ghostkellz/zsync/issues

## License

See LICENSE file in repository.
