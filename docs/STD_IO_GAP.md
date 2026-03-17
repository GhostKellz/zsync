# Zsync vs std.Io Gap Analysis

Comparison between zsync's I/O system and Zig 0.16's std.Io for compatibility planning.

## Overview

Both zsync and std.Io use VTable-based polymorphic I/O interfaces. std.Io is more comprehensive with filesystem, networking, and concurrency primitives built-in.

## Architecture Comparison

| Aspect | zsync | std.Io |
|--------|-------|--------|
| VTable dispatch | Yes | Yes |
| Execution models | blocking, thread_pool, green_threads | Threaded, Evented (Uring/Kqueue/Dispatch) |
| Future type | zsync.Future | AnyFuture |
| Cancellation | CancelToken | Built-in cancel/recancel |
| Grouping | Nursery | Group |

## VTable Operations

### Core Async (both have similar concepts)

| Operation | zsync | std.Io |
|-----------|-------|--------|
| Async dispatch | `poll` pattern | `async` returns Future |
| Await | `Future.await()` | `await` vtable fn |
| Cancel | `Future.cancel()` | `cancel` vtable fn |
| Concurrent spawn | `spawn()` | `concurrent` vtable fn |
| Group spawn | `Nursery.spawn()` | `groupAsync`/`groupConcurrent` |

### I/O Operations

| Operation | zsync | std.Io |
|-----------|-------|--------|
| Read | `io.read()` | `operate(Operation.read)` |
| Write | `io.write()` | `operate(Operation.write)` |
| Vectorized read | `io.readv()` | `operate()` with iovecs |
| Vectorized write | `io.writev()` | `operate()` with iovecs |
| Accept | `io.accept()` | `operate(Operation.accept)` |
| Connect | `io.connect()` | `operate(Operation.connect)` |
| Close | `io.close()` | `fileClose`/`dirClose` |
| Send file | `io.send_file()` | `fileWriteFileStreaming` |

### Filesystem (std.Io has more)

| Operation | zsync | std.Io |
|-----------|-------|--------|
| Open file | `AsyncFile.open()` | `dirOpenFile` |
| Create file | Limited | `dirCreateFile` |
| Directory ops | Limited | Full (create, open, stat, delete, rename) |
| Symlinks | No | Yes |
| Permissions | No | Yes |
| Timestamps | No | Yes |

### Synchronization

| Primitive | zsync | std.Io |
|-----------|-------|--------|
| Mutex | `compat.Mutex` | `RwLock` |
| Semaphore | `sync.Semaphore` | `Semaphore` |
| Futex | Via compat | `futexWait`/`futexWake` |
| WaitGroup | `sync.WaitGroup` | Via Group |

## What zsync Provides That std.Io Doesn't

1. **Tokio-style APIs**: JoinSet, BroadcastChannel, WatchChannel, OnceCell, CancellationToken
2. **Higher-level channels**: bounded/unbounded channels with MPMC support
3. **Buffer pool**: Reusable buffer management
4. **Rate limiting**: TokenBucket, LeakyBucket, SlidingWindow
5. **Connection pool**: Health-checked connection management
6. **WebSocket**: RFC 6455 implementation
7. **File watching**: Cross-platform file system monitoring
8. **Platform detection**: Automatic optimal configuration

## Adapter Strategy

### Using zsync with std.Io code

```zig
// Wrap std.Io for zsync compatibility
const StdIoAdapter = struct {
    std_io: *std.Io,

    pub fn io(self: *StdIoAdapter) zsync.Io {
        return zsync.Io.init(&vtable, self);
    }

    // Implement zsync VTable methods using std.Io calls
};
```

### Using zsync.Io in std.Io contexts

```zig
// zsync's blocking backend uses std.posix directly
// For async contexts, zsync provides its own event loop

fn myTask(io: zsync.Io) !void {
    // This works with any zsync backend
    var future = try io.write("data");
    defer future.destroy(io.getAllocator());
    try future.await();
}
```

## Recommended Approach for v0.7.7

1. **Keep zsync's simpler VTable** - It's easier to implement and use
2. **Add std.Io shim where needed** - For interop with std.Io-based libraries
3. **Document the pattern** - Show how to bridge between the two
4. **Future consideration** - Full std.Io adapter in v0.8+

## References

- `/opt/zig-0.16.0-dev/lib/std/Io.zig` - std.Io source
- `/data/projects/zsync/src/io_interface.zig` - zsync Io interface
- `/data/projects/zsync/src/blocking_io.zig` - zsync blocking implementation
