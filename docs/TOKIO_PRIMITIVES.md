# Tokio-style Primitives in Zsync

Zsync provides primitives inspired by Rust's Tokio runtime. This document describes their implementation status and behavior differences.

## Primitive Status

| Primitive | Status | Notes |
|-----------|--------|-------|
| `JoinSet` | Partial | Synchronous execution, no true parallelism |
| `BroadcastChannel` | Working | Basic pub/sub, not optimized |
| `WatchChannel` | Working | Single-value observer |
| `Notify` | Working | Uses condition variables |
| `OnceCell` | Working | Thread-safe lazy init |
| `CancellationToken` | Working | Hierarchical cancellation |
| `RuntimeBuilder` | Working | Fluent configuration API |
| `Interval` | Working | Repeating timer |
| `spawnBlocking` | Working | Delegates to std.Thread |

## JoinSet

Manages multiple concurrent tasks.

```zig
var set = zsync.JoinSet(i32).init(allocator);
defer set.deinit();

_ = try set.spawn(computeValue, .{1});
_ = try set.spawn(computeValue, .{2});
set.joinAll();
```

**Limitations:**
- Tasks execute synchronously in current implementation
- No true parallelism (use thread pool with Nursery for parallel execution)
- Results stored but not returned via joinAll

**Tokio parity:** Partial - Tokio's JoinSet spawns tasks on async runtime.

## BroadcastChannel

Multiple producers, multiple consumers. Each message delivered to all subscribers.

```zig
var bc = zsync.BroadcastChannel([]const u8).init(allocator);
defer bc.deinit();

const sub1 = try bc.subscribe();
const sub2 = try bc.subscribe();

try bc.send("hello");

const msg1 = zsync.BroadcastChannel([]const u8).recv(sub1); // "hello"
const msg2 = zsync.BroadcastChannel([]const u8).recv(sub2); // "hello"
```

**Limitations:**
- No capacity limit (unbounded)
- No lagged subscriber handling
- Blocking send (no async)

**Tokio parity:** Partial - Tokio has capacity, lag handling, async recv.

## WatchChannel

Single value that can be watched for changes.

```zig
var watch = zsync.WatchChannel(u32).init(0);

watch.send(42);
const value = watch.borrow(); // 42
const version = watch.getVersion(); // 1
```

**Limitations:**
- No async wait for changes
- Manual version checking required

**Tokio parity:** Partial - Tokio has async `changed()` method.

## Notify

Simple notification primitive for coordinating tasks.

```zig
var notify = zsync.Notify.init();

// In one task:
notify.wait(); // Blocks until notified

// In another task:
notify.notifyOne(); // Wake one waiter
notify.notifyAll(); // Wake all waiters
```

**Tokio parity:** Full - Behavior matches tokio::sync::Notify.

## OnceCell

Thread-safe lazy initialization.

```zig
var cell = zsync.OnceCell(ExpensiveValue).init();

// First call initializes
const value = cell.getOrInit(computeExpensiveValue);

// Subsequent calls return cached value
const same = cell.get().?;
```

**Methods:**
- `getOrInit(fn)` - Initialize with infallible function
- `getOrTryInit(fn)` - Initialize with fallible function
- `get()` - Get if initialized
- `set(value)` - Set if not initialized
- `isInitialized()` - Check status

**Tokio parity:** Full - Matches tokio::sync::OnceCell API.

## CancellationToken

Coordinated graceful shutdown with hierarchical cancellation.

```zig
var token = zsync.CancellationToken.init(allocator);
defer token.deinit();

// Create child token
const child = try token.child();

// In shutdown handler:
token.cancel(); // Cancels token and all children

// In tasks:
if (token.isCancelled()) return;

// Or wait for cancellation:
token.waitForCancellation();
```

**Tokio parity:** Full - Matches tokio_util::sync::CancellationToken.

## RuntimeBuilder

Fluent API for runtime configuration.

```zig
var runtime = try zsync.runtimeBuilder(allocator)
    .multiThread()
    .workerThreads(4)
    .enableAll()
    .build();
defer runtime.deinit();
```

**Methods:**
- `multiThread()` - Use thread pool
- `currentThread()` - Use blocking (single-threaded)
- `workerThreads(n)` - Set worker count
- `enableAll()` - Enable all features
- `enableTime()` - Enable timers (always on)
- `enableIo()` - Enable I/O optimizations
- `threadStackSize(n)` - Set stack size
- `build()` - Create runtime

**Tokio parity:** Full - API matches tokio::runtime::Builder.

## Interval

Repeating timer for periodic operations.

```zig
var interval = zsync.Interval.init(100); // 100ms period

while (running) {
    interval.tick(); // Waits until next tick
    doPeriodicWork();
}
```

**Tokio parity:** Full - Matches tokio::time::interval behavior.

## spawnBlocking

Run CPU-intensive work on dedicated thread.

```zig
const thread = try zsync.spawnBlocking(heavyComputation, .{data});
thread.join();
```

**Tokio parity:** Partial - Tokio returns JoinHandle with async await.

## Recommendations

### For true parallelism, use Nursery:

```zig
const nursery = try zsync.Nursery.init(allocator, runtime);
defer nursery.deinit();

try nursery.spawn(task1, .{});
try nursery.spawn(task2, .{});
try nursery.spawn(task3, .{});

try nursery.wait(); // All complete in parallel
```

### For async I/O, use the Io interface:

```zig
fn myTask(io: zsync.Io) !void {
    var future = try io.write(data);
    defer future.destroy(io.getAllocator());
    try future.await();
}
```

## Future Improvements

- JoinSet: True async spawning with thread pool
- BroadcastChannel: Capacity limits, lag handling
- WatchChannel: Async `changed()` method
- spawnBlocking: Return Future instead of Thread
