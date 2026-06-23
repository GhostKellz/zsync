# zsync Architecture

## Design Philosophy

zsync follows several key principles:

1. **Build on `std.Io`** - scheduling and platform I/O backend selection are owned
   by the standard library, not by zsync
2. **Colorblind Async** - the same code runs whether the backend is sync or async
3. **Structured Concurrency** - scoped task lifetimes via nurseries and `JoinSet`
4. **Composability** - small, focused modules that compose well

## System Overview

zsync no longer ships its own per-platform reactor or `Io` vtable. It layers
Tokio-style primitives over `std.Io.Threaded`, which owns task scheduling and
platform I/O backend selection.

```
┌─────────────────────────────────────────────────────────────┐
│                      User Application                        │
├─────────────────────────────────────────────────────────────┤
│                        zsync API                             │
│  ┌─────────┬─────────┬─────────┬─────────┬─────────────────┐ │
│  │ Runtime │ Nursery │Channels │ Timers  │ Sync primitives │ │
│  └─────────┴─────────┴─────────┴─────────┴─────────────────┘ │
├─────────────────────────────────────────────────────────────┤
│                  std.Io  (re-exported as zsync.Io)           │
├─────────────────────────────────────────────────────────────┤
│                     std.Io.Threaded                          │
│        (owns scheduling + platform I/O backend select)       │
├─────────────────────────────────────────────────────────────┤
│         Linux · macOS · Windows · BSD · WASM                 │
└─────────────────────────────────────────────────────────────┘
```

## Core Components

### 1. `Io` Interface

The `Io` interface is Zig's standard-library `std.Io`, re-exported as
`zsync.Io`. zsync does not define its own vtable — `async`/`await`, networking
(`std.Io.net`), randomness (`io.random`), and timers all come from the standard
library. This keeps zsync aligned with the language as `std.Io` evolves.

### 2. Runtime (`std_runtime.zig`)

`Runtime` owns a `std.Io.Threaded` backend and exposes the `Io` handle:

```zig
pub const Runtime = struct {
    threaded: std.Io.Threaded,
    allocator: std.mem.Allocator,
};
```

`zsync.run` builds a `Threaded` backend, installs a process-global `Io`, runs
the entry task, and tears everything down on return. `RuntimeOptions` is
intentionally slim (`stack_size` only) — there are no execution models to
select, because std owns scheduling.

### 3. Structured Concurrency (`nursery.zig`)

A `Nursery` scopes a group of tasks to a single lifetime. `spawn` adds tasks and
`wait` blocks until they all complete. `withNursery` runs a function inside a
nursery scoped to a given `Io`.

### 4. Channels (`channels.zig`, `channel.zig`)

Message-passing primitives:

- **Bounded channels** - fixed capacity with backpressure
- **Unbounded channels** - dynamic capacity
- MPMC (multi-producer, multi-consumer) support

### 5. Timers (`timer.zig`, `sleep.zig`)

- `sleep(ms)` and `yieldNow()`
- `Interval` for periodic ticks

### 6. Synchronization (`sync.zig`)

- `AsyncMutex`, `AsyncRwLock`, `Semaphore`, `Barrier`, `WaitGroup`
- Broadcast/watch channels

### 7. Task Spawning (`spawn.zig`)

Thin wrappers over `io.async`:

- `spawn(fn, args)` — spawn against the process-global `Io`
- `spawnOn(io, fn, args)` — spawn on an explicit `Io`

Both return a `std.Io.Future` awaited with `future.await(io)`.

### 8. Networking (`net/`, `networking.zig`)

Built on `std.Io.net`:

- `net/websocket.zig` — WebSocket (RFC 6455)
- `net/pool.zig` — connection pooling
- `net/rate_limit.zig` — rate limiting

## Platform Support

All platforms route through `std.Io.Threaded`; the standard library picks the
appropriate mechanism per target. zsync does not select backends itself.

| Platform | Backend |
|----------|---------|
| Linux | `std.Io.Threaded` |
| macOS | `std.Io.Threaded` |
| Windows | `std.Io.Threaded` |
| BSD | `std.Io.Threaded` |
| WASM | `std.Io.Threaded` |

## Memory Management

1. **Allocator threading** - all allocations go through a user-provided allocator
2. **Buffer pooling** - reusable buffers for I/O operations (`buffer_pool.zig`)
3. **Deferred cleanup** - `defer runtime.deinit()` / `defer nursery.deinit()`

## File Organization

```
src/
├── root.zig            # Public API exports
├── std_runtime.zig     # std.Io.Threaded-backed Runtime + run/getGlobalIo
├── spawn.zig           # spawn / spawnOn over io.async
├── nursery.zig         # Structured concurrency
├── channels.zig        # Bounded/unbounded channels
├── channel.zig         # Channel primitives
├── sync.zig            # Synchronization primitives
├── timer.zig           # Timers / intervals
├── sleep.zig           # sleep / yieldNow
├── select.zig          # Future combinators (experimental)
├── future.zig          # Future helpers
├── buffer_pool.zig     # Buffer management
├── streams.zig         # Stream helpers
├── networking.zig      # std.Io.net helpers
├── diagnostics.zig     # Runtime diagnostics
├── platform_detect.zig # Platform detection (diagnostics only)
├── compat/
│   └── thread.zig      # Compatibility shims for Zig dev toolchains
├── net/
│   ├── websocket.zig   # WebSocket RFC 6455 (std.Io.net)
│   ├── pool.zig        # Connection pooling
│   └── rate_limit.zig  # Rate limiting
└── wasm/
    ├── async.zig       # WASM async support
    └── microtask.zig   # Microtask queue
```
