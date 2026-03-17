# zsync Migration Guide

Guide for migrating to zsync v0.7.7 and Zig 0.16.0-dev compatibility.

## Zig 0.16 Breaking Changes

Zig 0.16.0-dev removed several standard library APIs. Zsync provides compatibility shims.

### std.posix.close → std.Io.Threaded.closeFd

```zig
// Before (Zig 0.15)
std.posix.close(fd);

// After (Zig 0.16)
std.Io.Threaded.closeFd(fd);
```

### std.Thread.Mutex → zsync.compat.Mutex

```zig
// Before
var mutex = std.Thread.Mutex{};

// After - use zsync's compat layer
const compat = @import("zsync").compat;
var mutex = compat.Mutex{};
```

### std.Thread.Condition → zsync.compat.Condition

```zig
// Before
var cond = std.Thread.Condition{};
cond.wait(&mutex);

// After
const compat = @import("zsync").compat;
var cond = compat.Condition{};
cond.wait(&mutex);
```

### std.time.Instant → zsync.time.Instant

```zig
// Before
const start = std.time.Instant.now() catch unreachable;

// After
const zsync = @import("zsync");
const start = zsync.time.Instant.now();
```

### std.posix.clock_gettime → compat.clock_gettime

```zig
// Before
const ts = try std.posix.clock_gettime(std.posix.CLOCK.REALTIME);

// After - internal use, zsync handles this
const compat = @import("zsync").compat;
const ts = try compat.clock_gettime(std.os.linux.CLOCK.REALTIME);
```

## Colorblind Async Pattern

Zsync uses dependency injection for I/O operations. The same code works across all execution models.

### Before: Direct I/O calls

```zig
// Old pattern - tied to specific implementation
fn processFile(path: []const u8) !void {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const data = try file.readAll(allocator);
    // process data
}
```

### After: Io injection

```zig
// New pattern - works with any backend
fn processFile(io: zsync.Io, path: []const u8) !void {
    var future = try io.read(buffer);
    defer future.destroy(io.getAllocator());
    try future.await();
    // process data
}

// Usage with different backends:
try zsync.run(processFile, .{"data.txt"});           // Auto-detect
try zsync.runBlocking(processFile, .{"data.txt"});   // Blocking
try zsync.runHighPerf(processFile, .{"data.txt"});   // Thread pool
```

## Runtime Configuration

### Before: Manual backend selection

```zig
// Old pattern
var blocking_io = zsync.BlockingIo.init(allocator);
defer blocking_io.deinit();
const io = blocking_io.io();
try myTask(io);
```

### After: Runtime with Config

```zig
// New pattern - recommended
const runtime = try zsync.Runtime.init(allocator, .{
    .execution_model = .auto,  // or .blocking, .thread_pool, .green_threads
});
defer runtime.deinit();
try runtime.run(myTask, .{});
```

### After: RuntimeBuilder (Tokio-style)

```zig
// Fluent API
var runtime = try zsync.runtimeBuilder(allocator)
    .multiThread()
    .workerThreads(4)
    .enableAll()
    .build();
defer runtime.deinit();
```

## Structured Concurrency

### Before: Manual task management

```zig
// Old pattern - error-prone
var futures: [3]*Future = undefined;
futures[0] = try spawn(task1, .{});
futures[1] = try spawn(task2, .{});
futures[2] = try spawn(task3, .{});

for (futures) |f| {
    try f.await();
    f.destroy(allocator);
}
```

### After: Nursery (recommended)

```zig
// New pattern - automatic cleanup, error propagation
const nursery = try zsync.Nursery.init(allocator, runtime);
defer nursery.deinit();

try nursery.spawn(task1, .{});
try nursery.spawn(task2, .{});
try nursery.spawn(task3, .{});

try nursery.wait(); // All tasks complete or first error
```

## Channel API

### Before: Direct channel creation

```zig
var channel = try Channel(i32).init(allocator, 100);
```

### After: Factory functions

```zig
// Bounded channel
var ch = try zsync.channels.bounded(i32, allocator, 100);
defer ch.deinit();

// Unbounded channel
var uch = try zsync.channels.unbounded(i32, allocator);
defer uch.deinit();
```

## Cancellation

### Before: Manual cancellation

```zig
var cancelled = false;

fn myTask() !void {
    while (!cancelled) {
        // work
    }
}

// Somewhere else:
cancelled = true;
```

### After: CancellationToken

```zig
var token = zsync.CancellationToken.init(allocator);
defer token.deinit();

fn myTask(cancel: *zsync.CancellationToken) !void {
    while (!cancel.isCancelled()) {
        // work
    }
}

// Graceful shutdown:
token.cancel(); // Cancels token and all children
```

## Config Field Names

Field names have changed for clarity:

| Old | New |
|-----|-----|
| `num_workers` | `thread_pool_threads` |

```zig
// Before
.num_workers = 4,

// After
.thread_pool_threads = 4,
```

## Execution Model Selection

| Workload | Recommended Model |
|----------|-------------------|
| Simple programs | `.blocking` |
| CPU-bound parallel | `.thread_pool` |
| I/O-bound, high concurrency | `.green_threads` (Linux) |
| Cross-platform | `.auto` |

## Compatibility Notes

### zquic/zcrypto users

Zsync exports are stable:
- `zsync.Io` - I/O interface
- `zsync.Future` - Async future
- `zsync.BlockingIo` - Blocking backend

These remain unchanged from v0.7.6.

### Minimum Zig Version

v0.7.7 requires Zig `0.16.0-dev.2736+3b515fbed` or later.

## See Also

- [API Reference](API_REFERENCE.md)
- [Tokio Primitives](TOKIO_PRIMITIVES.md)
- [std.Io Gap Analysis](STD_IO_GAP.md)
