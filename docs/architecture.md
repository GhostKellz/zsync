# zsync Architecture

## Design Philosophy

zsync follows several key principles:

1. **Colorblind Async** - Code should work identically whether running synchronously or asynchronously
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
├─────────┬─────────┬─────────┬─────────┬─────────────────────┤
│Blocking │ThreadPool│io_uring │  Green  │      WASM         │
│   Io    │    Io    │   Io    │ Threads │    Microtasks     │
├─────────┴─────────┴─────────┴─────────┴─────────────────────┤
│                     Platform Layer                           │
│  ┌─────────┬─────────┬─────────┬─────────┬─────────────────┐│
│  │  Linux  │  macOS  │ Windows │  BSD    │      WASM       ││
│  │io_uring │ kqueue  │  IOCP   │ kqueue  │   Event Loop    ││
│  └─────────┴─────────┴─────────┴─────────┴─────────────────┘│
└─────────────────────────────────────────────────────────────┘
```

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
    // ...
};
```

Key responsibilities:
- Initialize appropriate I/O backend based on config
- Track runtime metrics
- Manage global runtime instance

### 3. Thread Pool (`thread_pool.zig`, `std_io.zig`)

Real thread pool implementation with:

- Worker threads with condition variable signaling
- Lock-free work queue (SinglyLinkedList)
- Futex-based completion events
- Automatic thread spawning up to CPU count

```zig
pub const Threaded = struct {
    run_queue: std.SinglyLinkedList,
    cond: std.Thread.Condition,
    workers: []Worker,
    // ...
};
```

### 4. Timer System (`timer.zig`)

Hierarchical timer wheel for efficient timer management:

```zig
pub const TimerWheel = struct {
    timers: HashMap(u64, TimerEntry),
    sorted_timers: ArrayList(u64),  // Sorted by expiry
    // ...
};
```

Features:
- O(log n) insertion
- O(1) expiry checking
- Interval timer support
- Global timer wheel with auto-init

### 5. Channels (`channel.zig`, `channels.zig`)

Message passing primitives:

- **Bounded channels** - Fixed capacity with backpressure
- **Unbounded channels** - Unlimited capacity
- **OneShot channels** - Single value transfer

### 6. Synchronization (`sync.zig`)

Async-aware synchronization primitives:

- `AsyncMutex` - Non-blocking mutex
- `AsyncRwLock` - Reader-writer lock
- `Semaphore` - Counting semaphore
- `Barrier` - Synchronization barrier
- `WaitGroup` - Go-style wait group

## Platform Backends

### Linux

- **io_uring** - Kernel-level async I/O (5.1+)
- **epoll** - Fallback for older kernels
- Zero-copy: `sendfile`, `splice`

### macOS

- **kqueue** - BSD event notification
- **GCD** - Grand Central Dispatch integration
- Thread pool fallback

### Windows

- **IOCP** - I/O Completion Ports
- Thread pool with IOCP integration

### WASM

- **Microtask queue** - Browser event loop integration
- Promise-based async
- No threading (single-threaded)

## Memory Management

zsync is careful about memory:

1. **Allocator Threading** - All allocations go through user-provided allocator
2. **Buffer Pooling** - Reusable buffers for I/O
3. **Page Alignment** - Zero-copy buffers are page-aligned
4. **Arena Patterns** - Short-lived allocations use arenas

## Error Handling

Consistent error handling across all components:

```zig
pub const IoError = error{
    WouldBlock,
    Cancelled,
    Timeout,
    ConnectionReset,
    // ...
};
```

## Future Directions

- [ ] io_uring Evented backend with full fiber support
- [ ] HTTP/2 and HTTP/3 (in zhttp)
- [ ] TLS integration (in zcrypto)
- [ ] Distributed runtime support

## File Organization

```
src/
├── root.zig           # Public API exports
├── runtime.zig        # Runtime management
├── io_interface.zig   # Colorblind I/O interface
├── blocking_io.zig    # Synchronous I/O backend
├── std_io.zig         # std.Io compatible backend
├── thread_pool.zig    # Thread pool implementation
├── timer.zig          # Timer wheel
├── channel.zig        # Channel primitives
├── sync.zig           # Synchronization primitives
├── scheduler.zig      # Task scheduler
├── nursery.zig        # Structured concurrency
├── zero_copy.zig      # Zero-copy I/O utilities
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
