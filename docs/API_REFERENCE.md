# Zsync v0.7.0 API Reference

Complete reference for all public APIs in zsync.

## Table of Contents

- [Runtime](#runtime)
- [Task Spawning](#task-spawning)
- [Structured Concurrency](#structured-concurrency)
- [Channels](#channels)
- [Buffer Pool](#buffer-pool)
- [Futures](#futures)
- [Synchronization](#synchronization)
- [Configuration](#configuration)

---

## Runtime

### `Runtime`

Core async runtime manager.

```zig
pub const Runtime = struct {
    pub fn init(allocator: std.mem.Allocator, config: Config) !*Runtime;
    pub fn deinit(self: *Runtime) void;
    pub fn setGlobal(self: *Runtime) void;
    pub fn getIo(self: *Runtime) Io;
    pub fn getMetrics(self: *Runtime) RuntimeMetrics;
    pub fn spawn(self: *Runtime, comptime task_fn: anytype, args: anytype) !Future;
};
```

**Example:**
```zig
const runtime = try zsync.Runtime.init(allocator, .{
    .execution_model = .thread_pool,
    .num_workers = 4,
});
defer runtime.deinit();

runtime.setGlobal();
```

### `Runtime.init(allocator, config)`

Creates a new runtime instance.

**Parameters:**
- `allocator`: Memory allocator
- `config`: Runtime configuration

**Returns:** `!*Runtime`

**Errors:**
- `error.OutOfMemory`
- `error.PlatformUnsupported`
- `error.GreenThreadsNotSupported`

### `Runtime.spawn(task_fn, args)`

Spawns a task on the runtime.

**Parameters:**
- `task_fn`: Function to execute
- `args`: Tuple of arguments

**Returns:** `!Future`

**Example:**
```zig
fn myTask(x: i32, y: i32) !void {
    std.debug.print("Sum: {d}\n", .{x + y});
}

const future = try runtime.spawn(myTask, .{10, 20});
try future.await();
```

---

## Task Spawning

### `spawn(task_fn, args)`

Global task spawning function.

```zig
pub fn spawn(comptime task_fn: anytype, args: anytype) !Future;
```

**Requires:** Runtime must be set as global via `setGlobal()`

**Example:**
```zig
runtime.setGlobal();

const future = try zsync.spawn(fetchData, .{user_id});
try future.await();
```

### `spawnTask(task_fn, args)`

Alias for spawn (from spawn_mod).

```zig
pub const spawnTask = spawn_mod.spawn;
```

### `spawnOn(runtime, task_fn, args)`

Spawn on a specific runtime instance.

```zig
pub fn spawnOn(runtime: *Runtime, comptime task_fn: anytype, args: anytype) !*TaskHandle;
```

**Example:**
```zig
const handle = try zsync.spawnOn(runtime, myTask, .{42});
try handle.await();
handle.deinit();
```

---

## Structured Concurrency

### `Nursery`

Container for managing multiple concurrent tasks safely.

```zig
pub const Nursery = struct {
    pub fn init(allocator: std.mem.Allocator, runtime: *Runtime) !*Nursery;
    pub fn deinit(self: *Nursery) void;
    pub fn spawn(self: *Nursery, comptime task_fn: anytype, args: anytype) !void;
    pub fn wait(self: *Nursery) !void;
    pub fn cancelAll(self: *Nursery) void;
    pub fn pendingCount(self: *Nursery) usize;
    pub fn isComplete(self: *Nursery) bool;
};
```

### `Nursery.init(allocator, runtime)`

Creates a new nursery.

**Example:**
```zig
const nursery = try zsync.Nursery.init(allocator, runtime);
defer nursery.deinit();
```

### `Nursery.spawn(task_fn, args)`

Spawns a task within the nursery.

**Example:**
```zig
try nursery.spawn(processData, .{item1});
try nursery.spawn(processData, .{item2});
```

### `Nursery.wait()`

Waits for all spawned tasks to complete.

**Errors:**
- Returns first error from any task
- Cancels remaining tasks on error

**Example:**
```zig
try nursery.wait();
```

### `withNursery(allocator, runtime, func, args)`

RAII pattern for nurseries.

```zig
pub fn withNursery(
    allocator: std.mem.Allocator,
    runtime: *Runtime,
    comptime func: anytype,
    args: anytype,
) !void;
```

**Example:**
```zig
const MyTasks = struct {
    fn run(n: *zsync.Nursery, data: []const u8) !void {
        try n.spawn(task1, .{data});
        try n.spawn(task2, .{data});
    }
};

try zsync.withNursery(allocator, runtime, MyTasks.run, .{my_data});
```

---

## Channels

### `bounded(T, allocator, capacity)`

Creates a bounded channel with fixed capacity.

```zig
pub fn bounded(comptime T: type, allocator: std.mem.Allocator, capacity: usize) !Channel(T);
```

**Example:**
```zig
var ch = try zsync.channels.bounded(i32, allocator, 100);
defer ch.deinit();

try ch.send(42);
const val = try ch.recv();
```

### `unbounded(T, allocator)`

Creates an unbounded channel that grows dynamically.

```zig
pub fn unbounded(comptime T: type, allocator: std.mem.Allocator) !UnboundedChannel(T);
```

**Example:**
```zig
var ch = try zsync.channels.unbounded([]const u8, allocator);
defer ch.deinit();

try ch.send("Hello");
try ch.send("World");
const msg = try ch.recv();
```

### `Channel(T)`

Bounded channel type.

```zig
pub fn Channel(comptime T: type) type {
    return struct {
        pub fn send(self: *Self, item: T) !void;
        pub fn recv(self: *Self) !T;
        pub fn trySend(self: *Self, item: T) !bool;
        pub fn tryRecv(self: *Self) ?T;
        pub fn close(self: *Self) void;
        pub fn isClosed(self: *Self) bool;
        pub fn len(self: *Self) usize;
        pub fn deinit(self: *Self) void;
    };
}
```

### `Channel.send(item)`

Sends an item (blocks if full).

**Errors:**
- `error.ChannelClosed`

### `Channel.recv()`

Receives an item (blocks if empty).

**Returns:** `!T`

**Errors:**
- `error.ChannelClosed`

### `Channel.trySend(item)`

Non-blocking send.

**Returns:** `!bool` (true if sent, false if full)

### `Channel.tryRecv()`

Non-blocking receive.

**Returns:** `?T` (null if empty)

---

## Buffer Pool

### `BufferPool`

Manages reusable memory buffers.

```zig
pub const BufferPool = struct {
    pub fn init(allocator: std.mem.Allocator, config: BufferPoolConfig) !*BufferPool;
    pub fn deinit(self: *BufferPool) void;
    pub fn acquire(self: *BufferPool) !*PooledBuffer;
    pub fn stats(self: *BufferPool) PoolStats;
};
```

### `BufferPoolConfig`

Configuration for buffer pool.

```zig
pub const BufferPoolConfig = struct {
    initial_capacity: usize = 64,
    buffer_size: usize = 16384, // 16KB
    max_cached: usize = 256,
    enable_zero_copy: bool = true,
};
```

### `PooledBuffer`

A buffer from the pool.

```zig
pub const PooledBuffer = struct {
    data: []u8,
    pool: *BufferPool,
    in_use: bool,

    pub fn slice(self: *Self) []u8;
    pub fn release(self: *Self) void;
};
```

**Example:**
```zig
const pool = try zsync.BufferPool.init(allocator, .{});
defer pool.deinit();

const buf = try pool.acquire();
defer buf.release();

@memcpy(buf.data[0..5], "Hello");
```

### Zero-Copy Operations

#### `sendfile(out_fd, in_fd, offset, count)`

Zero-copy file transfer (Linux/BSD/macOS).

```zig
pub fn sendfile(
    out_fd: std.posix.fd_t,
    in_fd: std.posix.fd_t,
    offset: ?*i64,
    count: usize,
) !usize;
```

**Returns:** Number of bytes transferred

**Errors:**
- `error.SendfileNotSupported`
- `error.SendfileFailed`

#### `splice(fd_in, off_in, fd_out, off_out, len, flags)`

Zero-copy pipe transfer (Linux only).

```zig
pub fn splice(
    fd_in: std.posix.fd_t,
    off_in: ?*i64,
    fd_out: std.posix.fd_t,
    off_out: ?*i64,
    len: usize,
    flags: u32,
) !usize;
```

#### `copyFileZeroCopy(allocator, source_path, dest_path)`

High-level zero-copy file copy.

```zig
pub fn copyFileZeroCopy(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    dest_path: []const u8,
) !usize;
```

**Example:**
```zig
const bytes = try zsync.copyFileZeroCopy(
    allocator,
    "source.dat",
    "dest.dat",
);
std.debug.print("Copied {d} bytes\n", .{bytes});
```

---

## Futures

### `Future`

Represents an async operation.

```zig
pub const Future = struct {
    vtable: *const FutureVTable,
    context: *anyopaque,
    cancel_token: ?*CancelToken,
    state: std.atomic.Value(State),

    pub fn poll(self: *Future) PollResult;
    pub fn await(self: *Future) IoError!void;
    pub fn cancel(self: *Future) void;
};
```

### `Future.poll()`

Non-blocking check for completion.

**Returns:** `PollResult`

```zig
pub const PollResult = union(enum) {
    pending,
    ready: void,
    cancelled,
    err: IoError,
};
```

### `Future.await()`

Blocks until future completes.

**Example:**
```zig
const future = try zsync.spawn(myTask, .{});
try future.await(); // Blocks here
```

---

## Synchronization

### `Semaphore`

Counting semaphore for resource limiting.

```zig
pub const Semaphore = sync_mod.Semaphore;
```

### `Barrier`

Synchronization point for multiple tasks.

```zig
pub const Barrier = sync_mod.Barrier;
```

### `Latch`

One-time countdown synchronization.

```zig
pub const Latch = sync_mod.Latch;
```

---

## Configuration

### `Config`

Runtime configuration options.

```zig
pub const Config = struct {
    execution_model: ExecutionModel = .auto,
    num_workers: ?u32 = null,
    enable_debugging: bool = false,
    green_thread_stack_size: usize = 65536,
    max_green_threads: u32 = 1024,
    queue_depth: ?u32 = null,
};
```

### `ExecutionModel`

Available execution models.

```zig
pub const ExecutionModel = enum {
    auto,           // Platform auto-detection
    blocking,       // Direct syscalls
    thread_pool,    // OS threads
    green_threads,  // Cooperative tasks (Linux 5.1+)
    stackless,      // WASM coroutines (planned)
};
```

### `ExecutionModel.detect()`

Automatically detects best execution model.

```zig
pub fn detect() ExecutionModel;
```

**Returns:**
- `.green_threads` on Linux 5.1+ with io_uring
- `.thread_pool` on other platforms
- Never returns `.auto`

---

## Version Information

```zig
pub const VERSION = "0.7.0";
pub const VERSION_MAJOR = 0;
pub const VERSION_MINOR = 7;
pub const VERSION_PATCH = 0;
```

### `printVersion()`

Prints version and capabilities.

```zig
pub fn printVersion() void;
```

**Output:**
```
🚀 Zsync v0.7.0 - The Tokio of Zig
Execution Models:
  ✅ blocking
  ✅ thread_pool
  ✅ green_threads (Linux 5.1+)
Platform: x86_64-linux
```

---

## Error Types

### `RuntimeError`

Runtime-specific errors.

```zig
pub const RuntimeError = error{
    RuntimeNotInitialized,
    RuntimeShutdown,
    PlatformUnsupported,
    GreenThreadsNotSupported,
};
```

### `IoError`

I/O operation errors.

```zig
pub const IoError = error{
    Cancelled,
    TimedOut,
    WouldBlock,
    // ... and std.posix errors
};
```

### `ChannelError`

Channel operation errors.

```zig
pub const ChannelError = error{
    ChannelClosed,
};
```

---

## Platform-Specific Notes

### Linux

- Green threads require kernel 5.1+
- io_uring enabled on Arch, Fedora, Gentoo, NixOS (kernel 5.1+)
- io_uring enabled on Debian, Ubuntu (kernel 5.15+)
- Zero-copy via `sendfile()` and `splice()`

### macOS

- Thread pool execution model
- Zero-copy via BSD `sendfile()`
- kqueue for event loop (future)

### Windows

- Thread pool execution model
- IOCP integration (planned)

### FreeBSD/OpenBSD/NetBSD

- Thread pool execution model
- kqueue support

### WASM

- Blocking execution only
- No threading support yet

---

## Memory Management

All zsync types follow Zig conventions:

```zig
const x = try Type.init(allocator, ...);
defer x.deinit();
```

Always call `deinit()` to prevent leaks.

---

## Thread Safety

- `Runtime`: Thread-safe after initialization
- `Nursery`: Thread-safe
- `Channel`: Thread-safe (MPMC)
- `BufferPool`: Thread-safe
- `Future`: Thread-safe

---

## Performance Tips

1. **Use buffer pool for repeated operations**
2. **Prefer nursery over manual task management**
3. **Use `.auto` execution model for cross-platform**
4. **Enable green_threads on Linux for I/O-bound workloads**
5. **Use channels for task communication**
6. **Release buffers as soon as possible**

---

For more information, see:
- [Getting Started](GETTING_STARTED.md)
- [Examples](EXAMPLES.md)
- [Performance Guide](PERFORMANCE.md)
