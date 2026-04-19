# API Reference

This is a concise reference for the supported `v0.8.0` surface.

## Core Types

### `Runtime`

```zig
pub fn init(allocator: std.mem.Allocator, config: Config) !*Runtime
pub fn deinit(self: *Runtime) void
pub fn run(self: *Runtime, comptime task_fn: anytype, args: anytype) !void
pub fn spawn(self: *Runtime, comptime task_fn: anytype, args: anytype) !Future
pub fn timeout(self: *Runtime, future: Future, timeout_ms: u64) !Future
pub fn race(self: *Runtime, futures: []Future) !Future
pub fn all(self: *Runtime, futures: []Future) !Future
```

`race()`, `all()`, and `timeout()` are public, but still considered experimental for `v0.8.0`.

### `Io`

```zig
pub fn read(self: *Io, buffer: []u8) IoError!Future
pub fn write(self: *Io, data: []const u8) IoError!Future
pub fn readv(self: *Io, buffers: []IoBuffer) IoError!Future
pub fn writev(self: *Io, data: []const []const u8) IoError!Future
pub fn accept(self: *Io, fd: std.posix.fd_t) IoError!Future
pub fn connect(self: *Io, fd: std.posix.fd_t, address: std.net.Address) IoError!Future
pub fn close(self: *Io, fd: std.posix.fd_t) IoError!Future
pub fn getMode(self: *const Io) IoMode
pub fn supportsVectorized(self: *const Io) bool
pub fn supportsZeroCopy(self: *const Io) bool
pub fn getAllocator(self: *const Io) std.mem.Allocator
```

### `Future`

```zig
pub fn await(self: *Future) IoError!void
pub fn poll(self: *Future) Future.PollResult
pub fn cancel(self: *Future) void
pub fn destroy(self: *Future) void
```

`Future.destroy()` is zero-argument.

### `BlockingIo`

```zig
pub fn init(allocator: std.mem.Allocator, buffer_size: usize) BlockingIo
pub fn deinit(self: *BlockingIo) void
pub fn io(self: *BlockingIo) Io
```

### `ThreadPoolIo`

```zig
pub fn init(allocator: std.mem.Allocator, config: ThreadPoolConfig) !ThreadPoolIo
pub fn deinit(self: *ThreadPoolIo) void
pub fn io(self: *ThreadPoolIo) Io
```

### `Nursery`

```zig
pub fn init(allocator: std.mem.Allocator, runtime: *Runtime) !*Nursery
pub fn deinit(self: *Nursery) void
pub fn spawn(self: *Nursery, comptime task_fn: anytype, args: anytype) !void
pub fn wait(self: *Nursery) !void
```

### Channels

```zig
pub const bounded = channel.bounded
pub const unbounded = channel.unbounded
```

### Timers

```zig
pub fn sleep(duration_ms: u64) void
pub fn yieldNow() void
pub const Interval = struct { ... }
```

### Task Spawning (`spawn.zig`)

For CPU-bound work that should run on the thread pool:

```zig
pub fn spawn(comptime task_fn: anytype, args: anytype) !*TaskHandle
pub fn spawnOn(runtime: *Runtime, comptime task_fn: anytype, args: anytype) !*TaskHandle
```

**TaskHandle**

```zig
pub fn await(self: *TaskHandle) !void     // Block until task completes
pub fn poll(self: *TaskHandle) bool       // Check completion without blocking
pub fn deinit(self: *TaskHandle) void     // Clean up handle
```

**Usage**

```zig
const spawn = @import("zsync").spawn;

fn cpuBoundWork(io: Io, data: []const u8) !void {
    // Heavy computation here (crypto, parsing, etc.)
}

// Spawn on thread pool (if available)
const handle = try spawn.spawn(cpuBoundWork, .{my_data});
defer handle.deinit();

// Do other work while task runs...

// Wait for completion
try handle.await();
```

When using `thread_pool` execution model, tasks run asynchronously on pool workers. For `blocking` mode, tasks execute synchronously on the calling thread.

## Convenience Functions

```zig
pub fn run(comptime task_fn: anytype, args: anytype) !void
pub fn runBlocking(comptime task_fn: anytype, args: anytype) !void
pub fn runHighPerf(comptime task_fn: anytype, args: anytype) !void
pub fn createOptimalRuntime(allocator: std.mem.Allocator) !*Runtime
pub fn runtimeBuilder(allocator: std.mem.Allocator) RuntimeBuilder
```

## Known Limitations

- `Io.readSync()` and `Io.writeSync()` return actual byte count when the backend provides it; backends without result tracking fall back to requested length.
- `io_uring.poll()` uses cooperative polling (100µs intervals) instead of kernel-level timeout.

## See Also

- [getting-started.md](getting-started.md)
- [examples.md](examples.md)
- [integration.md](integration.md)
