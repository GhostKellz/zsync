# zsync Architecture

## Design Philosophy

zsync follows several key principles:

1. **Colorblind Async** - Code works identically whether running synchronously or asynchronously
2. **Zero-Cost Abstractions** - Pay only for what you use
3. **Platform Optimization** - Use the best backend for each platform
4. **Composability** - Small, focused modules that compose well

## System Overview

```
┌─────────────────────────────────────────────────────────────┐
│                      User Application                        │
├─────────────────────────────────────────────────────────────┤
│                        zsync API                             │
│  ┌─────────┬─────────┬─────────┬─────────┬─────────────────┐│
│  │ Runtime │ Channels│ Timers  │  Sync   │ Zero-Copy I/O   ││
│  └─────────┴─────────┴─────────┴─────────┴─────────────────┘│
├─────────────────────────────────────────────────────────────┤
│                     Io Interface (VTable)                    │
├─────────┬─────────┬─────────┬───────────────────────────────┤
│Blocking │ThreadPool│io_uring │      Green Threads           │
│   Io    │    Io    │   Io    │       (Linux)                │
├─────────┴─────────┴─────────┴───────────────────────────────┤
│                     Platform Layer                           │
│  ┌─────────┬─────────┬─────────┬─────────┬─────────────────┐│
│  │  Linux  │  macOS  │ Windows │  BSD    │      WASM       ││
│  │io_uring │ (pool)  │ (pool)  │ (pool)  │   (blocking)    ││
│  └─────────┴─────────┴─────────┴─────────┴─────────────────┘│
└─────────────────────────────────────────────────────────────┘
```

## Feature Status

| Feature | Linux | macOS | Windows | BSD | WASM |
|---------|-------|-------|---------|-----|------|
| Blocking I/O | ✅ | ✅ | ✅ | ✅ | ✅ |
| Thread Pool | ✅ | ✅ | ✅ | ✅ | ❌ |
| Green Threads | ✅ (io_uring) | ❌ | ❌ | ❌ | ❌ |
| Zero-Copy | ✅ | Partial | ❌ | Partial | ❌ |
| Channels | ✅ | ✅ | ✅ | ✅ | ✅ |
| Timers | ✅ | ✅ | ✅ | ✅ | ✅ |

## Core Components

### 1. Io Interface (`io_interface.zig`)

The heart of zsync's colorblind async design. Uses a VTable pattern to abstract different I/O backends:

```zig
pub const Io = struct {
    vtable: *const IoVTable,
    userdata: *anyopaque,
};

const IoVTable = struct {
    read: *const fn (...) Future,
    write: *const fn (...) Future,
    close: *const fn (...) void,
    // ...
};
```

This allows:
- Same code works with blocking, thread pool, or async backends
- Runtime selection of execution model
- Zero overhead when inlined

### 2. Runtime (`runtime.zig`)

Manages the execution environment:

```zig
pub const Runtime = struct {
    allocator: Allocator,
    config: Config,
    io_impl: IoImplementation,
    metrics: RuntimeMetrics,
};
```

Key responsibilities:
- Initialize appropriate I/O backend based on config
- Track runtime metrics
- Manage global runtime instance

### 3. Thread Pool (`thread_pool.zig`)

Thread pool implementation with:

- Worker threads with futex-based signaling
- Lock-free work queue
- Automatic worker count based on CPU cores
- Graceful shutdown with task draining

### 4. Timer System (`timer.zig`)

Timer wheel for efficient timer management:

- O(log n) insertion
- O(1) expiry checking
- Interval timer support
- Global timer wheel with auto-init

### 5. Channels (`channel.zig`, `channels.zig`)

Message passing primitives:

- **Bounded channels** - Fixed capacity with backpressure
- **Unbounded channels** - Dynamic capacity
- MPMC (multi-producer, multi-consumer) support

### 6. Synchronization (`sync.zig`)

Synchronization primitives:

- `AsyncMutex` - Non-blocking mutex
- `AsyncRwLock` - Reader-writer lock
- `Semaphore` - Counting semaphore
- `Barrier` - Synchronization barrier
- `WaitGroup` - Go-style wait group

### 7. Task Spawning (`spawn.zig`)

For CPU-bound work that should run on thread pool workers:

```zig
// Spawn returns immediately, task runs on pool
const handle = try spawn.spawn(heavyComputation, .{data});
defer handle.deinit();

// Do other work while task executes...

// Block until complete
try handle.await();
```

**When to use spawn vs Io:**

| Use Case | API |
|----------|-----|
| File/network I/O | `Io.read()`, `Io.write()` |
| CPU-bound work (crypto, parsing, compression) | `spawn.spawn()` |
| Mixed (I/O + computation) | Spawn task that uses `Io` |

**Memory lifecycle:**
- `spawn()` allocates a TaskHandle (caller owns)
- Thread pool manages internal WorkItem
- Task wrapper self-cleans after execution

## Platform Backends

### Linux (Full Support)

- **io_uring** - Kernel-level async I/O (kernel 5.1+)
- **epoll** - Fallback for older kernels
- Zero-copy: `sendfile`, `splice`, `copy_file_range`
- Green threads with cooperative scheduling

### macOS (Thread Pool)

- Thread pool execution model
- `sendfile` for zero-copy (partial)
- kqueue backend not yet implemented

### Windows (Experimental IOCP)

- Thread pool with IOCP completion signaling
- Native I/O: `ReadFile`/`WriteFile` for files, `recv`/`send` for sockets
- True overlapped I/O (AcceptEx, ConnectEx) not yet implemented

### BSD (Thread Pool)

- Thread pool execution model
- kqueue backend not yet implemented

### WASM (Blocking Only)

- Blocking execution model
- No threading support
- Microtask queue for browser integration

## Memory Management

zsync is careful about memory:

1. **Allocator Threading** - All allocations go through user-provided allocator
2. **Buffer Pooling** - Reusable buffers for I/O operations
3. **Page Alignment** - Zero-copy buffers are page-aligned
4. **Deferred cleanup** - `defer future.destroy()` pattern

## Error Handling

Consistent error handling across all components:

```zig
pub const IoError = error{
    WouldBlock,
    Cancelled,
    TimedOut,
    ConnectionClosed,
    BrokenPipe,
    // ...
};
```

## Roadmap

### Planned
- [ ] kqueue backend for macOS/BSD
- [ ] True overlapped I/O for Windows (AcceptEx, ConnectEx)
- [ ] Full std.Io adapter

### Completed
- [x] Zig 0.17.0-dev compatibility
- [x] Windows IOCP backend (experimental)
- [x] Cross-platform POSIX I/O in BlockingIo
- [x] Tokio-style primitives (partial)
- [x] Structured concurrency (Nursery)

### Complete
- [x] Colorblind async interface
- [x] Thread pool execution
- [x] io_uring green threads (Linux)
- [x] Channels (bounded/unbounded)
- [x] Timer system
- [x] Zero-copy I/O (Linux)
- [x] Buffer pool
- [x] WebSocket (RFC 6455)
- [x] Rate limiting
- [x] Connection pooling

## File Organization

```
src/
├── root.zig           # Public API exports
├── runtime.zig        # Runtime management
├── io_interface.zig   # Colorblind I/O interface
├── blocking_io.zig    # Synchronous I/O backend
├── thread_pool.zig    # Thread pool implementation
├── greenthreads_io.zig# Green threads (Linux)
├── spawn.zig          # CPU-bound task spawning
├── timer.zig          # Timer wheel
├── channel.zig        # Channel primitives
├── sync.zig           # Synchronization primitives
├── scheduler.zig      # Task scheduler
├── nursery.zig        # Structured concurrency
├── buffer_pool.zig    # Buffer management
├── select.zig         # Future combinators (race, all, timeout)
├── compat/
│   └── thread.zig     # Compatibility shims for Zig dev toolchains
├── net/
│   ├── websocket.zig  # WebSocket RFC 6455
│   ├── pool.zig       # Connection pooling
│   └── rate_limit.zig # Rate limiting
├── platform/
│   ├── linux.zig      # Linux-specific
│   └── macos.zig      # macOS-specific
└── wasm/
    ├── async.zig      # WASM async support
    └── microtask.zig  # Microtask queue
```
