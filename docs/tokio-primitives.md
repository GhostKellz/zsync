# Tokio-style Primitives

`zsync` provides several higher-level primitives inspired by Tokio's async ecosystem.

## Primitive Status

### Complete

| Primitive | Description | Status |
|-----------|-------------|--------|
| `Notify` | Task notification (wait/notifyOne/notifyAll) | Full |
| `OnceCell` | Thread-safe lazy initialization | Full |
| `CancellationToken` | Hierarchical cancellation with child tokens | Full |
| `RuntimeBuilder` | Fluent runtime configuration | Full |
| `Interval` | Repeating timer | Full |

### Functional

| Primitive | Description | Status |
|-----------|-------------|--------|
| `JoinSet` | Concurrent task management | Thread-based concurrency with `joinNext()` |
| `BroadcastChannel` | Multi-producer multi-consumer pub/sub | Capacity limits, lag tracking, blocking recv |
| `WatchChannel` | Single-value observer pattern | Watcher with `changed()` blocking wait |
| `Nursery` | Structured concurrency | Full with error propagation |
| `Channel` | Bounded/unbounded channels | Ring buffer implementation |

### Blocking Thread Primitives

These exist and work correctly but use OS thread blocking, not async/runtime integration.

| Primitive | Description | Notes |
|-----------|-------------|-------|
| `Semaphore` | Counting semaphore with max bounds | Blocks calling thread |
| `Barrier` | Thread barrier synchronization | Blocks until all arrive |
| `AsyncRwLock` | Reader-writer lock | Blocks calling thread (name is misleading) |
| `AsyncMutex` | Mutual exclusion lock | Blocks calling thread |
| `WaitGroup` | Wait for group completion | Blocks calling thread |

### Planned

| Primitive | Description | Target |
|-----------|-------------|--------|
| `Select` | Multi-channel selection | v0.9.0 |
| Runtime-integrated async waits | Yield to runtime instead of blocking | v0.9.0+ |

## Usage Examples

### JoinSet - Concurrent Task Execution

```zig
const zsync = @import("zsync");

var set = zsync.JoinSet(u32).init(allocator);
defer set.deinit();

// Spawn concurrent tasks
_ = try set.spawn(computeTask, .{1});
_ = try set.spawn(computeTask, .{2});
_ = try set.spawn(computeTask, .{3});

// Wait for results as they complete
while (set.joinNext()) |result| {
    switch (result.value) {
        .ok => |val| std.debug.print("Task {} completed: {}\n", .{result.idx, val}),
        .err => |e| std.debug.print("Task {} failed: {}\n", .{result.idx, e}),
    }
}
```

### BroadcastChannel - Pub/Sub Pattern

```zig
var broadcast = zsync.BroadcastChannel(Event).initWithCapacity(allocator, 32);
defer broadcast.deinit();

const sub1 = try broadcast.subscribe();
const sub2 = try broadcast.subscribe();

// Send to all subscribers
try broadcast.send(.{ .kind = .update, .data = 42 });

// Receive (non-blocking)
if (zsync.BroadcastChannel(Event).recv(sub1)) |event| {
    handleEvent(event);
}

// Check for dropped messages
const lagged = sub1.lagCount();
if (lagged > 0) {
    std.log.warn("Dropped {} messages", .{lagged});
}
```

### WatchChannel - Value Observer

```zig
var watch = zsync.WatchChannel(Config).init(defaultConfig);

// Create watcher
var watcher = watch.subscribe();

// In another thread: wait for changes
const thread = try std.Thread.spawn(.{}, struct {
    fn run(w: *@TypeOf(watcher)) void {
        while (true) {
            const new_config = w.changed(); // Blocks until changed
            applyConfig(new_config);
        }
    }
}.run, .{&watcher});

// Update value (wakes watchers)
watch.send(newConfig);
```

### Nursery - Structured Concurrency

```zig
const nursery = try zsync.Nursery.init(allocator, runtime);
defer nursery.deinit();

try nursery.spawn(downloadFile, .{"file1.txt"});
try nursery.spawn(downloadFile, .{"file2.txt"});
try nursery.spawn(processData, .{});

// Wait for all - propagates first error
try nursery.wait();
```

## Design Notes

- **Thread-based**: JoinSet uses OS threads for true parallelism
- **Capacity-bounded**: BroadcastChannel drops oldest messages when full (lag tracking)
- **Blocking waits**: WatchChannel.changed() and BroadcastChannel.recvBlocking() block the calling thread
- **Error propagation**: JoinSet tracks errors per-task, Nursery propagates first error

## Future Work

- Async-aware primitives (await instead of thread blocking)
- Integration with io_uring/IOCP for kernel-level waiting
- Timeout variants for all blocking operations
- Metrics and tracing integration
