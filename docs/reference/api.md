# API Reference

A concise reference for the supported public surface. zsync layers
structured-concurrency primitives over `std.Io`; the `Io` interface itself is
re-exported from the standard library (`zsync.Io == std.Io`), so consult the Zig
docs for the full `Io` API (`async`, `await`, `net`, `random`, …).

## Entry Points

```zig
pub const Io = std.Io;

pub fn run(gpa: std.mem.Allocator, comptime task_fn: anytype, args: anytype)
    @typeInfo(@TypeOf(task_fn)).@"fn".return_type.?
pub fn getGlobalIo() ?Io
```

`run` builds a `std.Io.Threaded` backend, installs a process-global `Io`, runs
`task_fn`, then tears everything down. It returns whatever `task_fn` returns
(including its error set). Inside a task, acquire the `Io` with `getGlobalIo()`.

## Tokio-Style Namespaces

`v0.8.4` adds facade modules that make the public API easier to scan without
replacing `std.Io`:

```zig
pub const task = @import("task.zig");
pub const time = @import("time.zig");
pub const net = @import("net.zig");
pub const channel = @import("channel.zig");
pub const tokio_sync = @import("tokio_sync.zig");
pub const process = @import("process.zig");
pub const signal = @import("signal.zig");
pub const compat = @import("compat_api.zig");
```

- `zsync.task`: `run`, `spawn`, `spawnOn`, `spawnBlocking`, `Nursery`, `JoinSet`
- `zsync.time`: `sleep`, `sleepCancellable`, `interval`, `Instant`, timer helpers
- `zsync.net`: `TcpStream`, `TcpListener`, `UdpSocket`, HTTP, DNS, TLS boundary,
  and canonical RFC 6455 WebSocket types
- `zsync.channel.mpsc`: split `Sender` / `Receiver` facade over the existing
  channel implementation
- `zsync.channel.oneshot`: single-value channel facade
- `zsync.process`: `std.Io`-backed child spawn, wait/kill, output capture,
  output limits, and process timeouts
- `zsync.signal`: POSIX signal counters for shutdown loops; unsupported targets
  return `error.Unsupported`

These modules are facades over `std.Io` and existing zsync primitives. Existing
root exports remain for compatibility, but new examples should prefer the
namespaced form.

## `Runtime`

```zig
pub const RuntimeOptions = struct {
    stack_size: usize = 0, // 0 = backend default
};

pub fn init(gpa: std.mem.Allocator, options: RuntimeOptions) Runtime
pub fn io(self: *Runtime) Io
pub fn spawn(self: *Runtime, comptime function: anytype, args: anytype) Io.Future
pub fn deinit(self: *Runtime) void
```

`Runtime` owns a `std.Io.Threaded` backend. `init` does not return an error
union. Hold it by stable address (it must not be copied after `init`).

## Futures

Futures are `std.Io.Future` values returned by `io.async(...)`. Await them with
the `Io` handle:

```zig
var future = io.async(work, .{args});
const result = future.await(io);
```

## `Nursery`

Scopes a group of tasks to a single lifetime.

```zig
pub fn init(io: std.Io) Nursery
pub fn spawn(self: *Nursery, comptime task_fn: anytype, args: anytype) !void
pub fn wait(self: *Nursery) !void
pub fn cancelAll(self: *Nursery) void
pub fn deinit(self: *Nursery) void

// Convenience: run `func` inside a nursery scoped to `io`.
pub fn withNursery(io: std.Io, comptime func: anytype, args: anytype) !void
```

`wait()` returns the first task error observed by `spawn()`. If callers skip
`wait()` and only drop/cancel the nursery, they are intentionally detaching from
task results.

## Task Spawning (`spawn.zig`)

```zig
// Spawn against the process-global Io (errors if no runtime is installed).
pub fn spawn(comptime task_fn: anytype, args: anytype)
    error{RuntimeNotInitialized}!Io.Future

// Spawn on an explicit Io (preferred — matches std.Io's explicit-argument style).
pub fn spawnOn(io: Io, comptime task_fn: anytype, args: anytype) Io.Future
```

Both return a `std.Io.Future`; await it with `future.await(io)`.

```zig
const zsync = @import("zsync");

fn cpuBoundWork(data: []const u8) usize {
    return data.len; // heavy computation here (crypto, parsing, etc.)
}

fn task() void {
    const io = zsync.getGlobalIo() orelse return;
    var future = zsync.spawnOn(io, cpuBoundWork, .{my_data});
    // ... do other work ...
    const n = future.await(io);
    _ = n;
}
```

## Channels

```zig
pub fn zsync.channel.mpsc.bounded(comptime T: type, allocator: std.mem.Allocator, capacity: u32) !struct { ... }
pub fn zsync.channel.mpsc.unbounded(comptime T: type, allocator: std.mem.Allocator) !struct { ... }
```

Both channel types expose:

```zig
pub fn send(self: *Self, item: T) !void
pub fn recv(self: *Self) !T
pub fn recvTimeout(self: *Self, timeout_ms: u64) !?T
pub fn recvCancellable(self: *Self, token: anytype) !T
pub fn deinit(self: *Self) void
```

Bounded channels also expose:

```zig
pub fn trySend(self: *Self, item: T) !bool
pub fn tryRecv(self: *Self) ?T
pub fn sendTimeout(self: *Self, item: T, timeout_ms: u64) !bool
pub fn sendCancellable(self: *Self, item: T, token: anytype) !void
```

```zig
const ch = try zsync.channel.mpsc.bounded(i32, allocator, 10);
defer {
    ch.channel.deinit();
    allocator.destroy(ch.channel);
}
try ch.sender.send(42);
const value = try ch.receiver.recv();
```

## Timers

```zig
pub fn zsync.time.sleep(duration_ms: u64) void
pub fn zsync.time.sleepCancellable(duration_ms: u64, token: anytype) bool
pub fn zsync.time.yieldNow() void
pub const Interval = struct { ... }
```

`sleepCancellable` returns `true` when the duration elapses and `false` when the
token is cancelled first.

## Networking And TLS

`zsync.net` exposes `std.Io.net`-backed TCP/UDP helpers plus HTTP, DNS, TLS, and
WebSocket types from the canonical networking modules.

```zig
pub const TlsVerification = enum {
    system_roots,
    custom_ca_bundle,
    self_signed,
    disabled,
};

pub const TlsConfig = struct {
    verification: TlsVerification = .system_roots,
    verify_certificates: bool = true, // compatibility alias; false disables verification
    server_name: ?[]const u8 = null,
    ca_bundle_path: ?[]const u8 = null,
    allow_truncation_attacks: bool = false,
};
```

`HttpClient.request` uses native Zig std TLS for `https://` URIs. Custom PEM CA
bundles are supported with `verification = .custom_ca_bundle` and
`ca_bundle_path`. Client certificates, client private keys, and custom
cipher-suite overrides currently return `error.TlsUnsupported`.

## Runtime-Integrated Sync

Use these for new async/runtime-facing code:

```zig
pub const IoSemaphore = struct {
    pub fn acquire(self: *Self, io: std.Io) !void
    pub fn acquireTimeout(self: *Self, io: std.Io, timeout: std.Io.Timeout) !void
}

pub const IoMutex = struct {
    pub fn lock(self: *Self, io: std.Io) !void
    pub fn tryLock(self: *Self) bool
}

pub const IoRwLock = struct {
    pub fn lockRead(self: *Self, io: std.Io) !void
    pub fn lockWrite(self: *Self, io: std.Io) !void
}

pub const IoWaitGroup = struct {
    pub fn wait(self: *Self, io: std.Io) !void
    pub fn waitTimeout(self: *Self, io: std.Io, timeout: std.Io.Timeout) !void
}
```

Legacy `Semaphore`, `AsyncMutex`, `AsyncRwLock`, and `WaitGroup` remain
available for source compatibility, but they block OS threads.

## Cancellation And Timeouts

```zig
pub const CancellationToken = struct {
    pub fn cancel(self: *Self) void
    pub fn isCancelled(self: *const Self) bool
    pub fn waitForCancellation(self: *Self) void
    pub fn child(self: *Self) !*CancellationToken
};
```

Token-aware helpers accept any token-like object with `isCancelled() bool`.
When cancellation wins, APIs return `error.Cancelled` except
`sleepCancellable`, which returns `false`.

Timeout helpers use a monotonic clock and return `null` or `false` on timeout,
depending on whether the operation returns a value. Timeout does not close the
underlying primitive; it only bounds that wait attempt.

Future combinators:

```zig
pub fn selectTimeout(comptime T: type, allocator: std.mem.Allocator, futures: []*Future(T), timeout_ms: u64) !?T
pub fn selectCancellable(comptime T: type, allocator: std.mem.Allocator, futures: []*Future(T), token: anytype) !?T
```

`selectTimeout` and `selectCancellable` cancel still-pending futures when the
timeout or cancellation wins.

## Time

```zig
pub fn milliTime() i64
pub fn nanoTime() i64
```

## Version

```zig
pub const VERSION: []const u8 // sourced from build.zig.zon
```

## See Also

- [Quickstart](../getting-started/quickstart.md)
- [Examples](../guides/examples.md)
- [Integration](../guides/integration.md)
