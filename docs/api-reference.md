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
pub fn bounded(comptime T: type, allocator: std.mem.Allocator, capacity: usize) !Channel(T)
pub fn unbounded(comptime T: type, allocator: std.mem.Allocator) !UnboundedChannel(T)
```

Both channel types expose:

```zig
pub fn send(self: *Self, item: T) !void
pub fn recv(self: *Self) !T
pub fn deinit(self: *Self) void
```

```zig
var ch = try zsync.channels.bounded(i32, allocator, 10);
defer ch.deinit();
try ch.send(42);
const value = try ch.recv();
```

## Timers

```zig
pub fn sleep(duration_ms: u64) void
pub fn yieldNow() void
pub const Interval = struct { ... }
```

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

- [getting-started.md](getting-started.md)
- [examples.md](examples.md)
- [integration.md](integration.md)
