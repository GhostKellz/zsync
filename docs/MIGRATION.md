# zsync Migration Guide

## Overview

This guide helps users migrate to the current zsync API and understand the colorblind async paradigm.

## Key Concepts

### Colorblind Async
zsync uses a "colorblind async" approach - the same code works across all execution models:
- **BlockingIo** - Single-threaded, synchronous execution
- **ThreadPoolIo** - Thread pool for parallel I/O
- **GreenThreadsIo** - Lightweight cooperative threads (Linux io_uring)
- **StacklessIo** - For WASM or memory-constrained environments

### Io Interface
All async operations go through the `Io` interface, enabling dependency injection and execution model independence.

## Migration Examples

### Basic Runtime Usage

```zig
// Create an I/O backend
var blocking_io = zsync.BlockingIo.init(allocator);
defer blocking_io.deinit();

const io = blocking_io.io();
try myApp(io);

// Or use different backends
var threadpool_io = try zsync.ThreadPoolIo.init(allocator, .{});
var greenthreads_io = try zsync.GreenThreadsIo.init(allocator, .{});
```

### Async Patterns

```zig
// Colorblind async - works with any backend
pub fn myTask(io: zsync.Io) !void {
    var future = try io.write(data);
    defer future.destroy(allocator);
    try future.await();
}

// Concurrent operations
var future1 = try io.async(task1, .{args1});
var future2 = try io.async(task2, .{args2});
try future1.await();
try future2.await();
```

### Tokio-style APIs (v0.7.3+)

```zig
// Spawn blocking work on dedicated thread
const thread = try zsync.spawnBlocking(cpuIntensiveWork, .{data});

// Manage task groups
var join_set = zsync.JoinSet(u32).init(allocator);
defer join_set.deinit();
_ = try join_set.spawn(task1, .{});
_ = try join_set.spawn(task2, .{});
join_set.joinAll();

// Graceful shutdown
var token = zsync.CancellationToken.init(allocator);
defer token.deinit();
// ... spawn tasks that check token.isCancelled() ...
token.cancel(); // Cancels all children

// Fluent runtime configuration
var builder = zsync.runtimeBuilder(allocator);
const rt = try builder.multiThread().workerThreads(4).enableAll().build();
defer rt.deinit();
```

## Performance Tips

| Scenario | Recommended Backend |
|----------|-------------------|
| CPU-bound, single-threaded | `BlockingIo` |
| I/O-bound with parallelism | `ThreadPoolIo` |
| High-concurrency servers | `GreenThreadsIo` |
| WASM / embedded | `StacklessIo` |

## Best Practices

1. **Always defer cleanup**: `defer future.destroy(allocator);`
2. **Use cancellation tokens** for graceful shutdown
3. **Pass `Io` as first parameter** to async functions
4. **Same code works optimally** across all execution models
