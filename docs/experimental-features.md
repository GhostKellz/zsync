# Experimental Features

This document outlines experimental features in zsync that are functional but may have limitations or undergo API changes.

## Windows IOCP Backend

**Status:** Experimental (v0.8.1+)

The Windows backend uses I/O Completion Ports (IOCP) with a worker thread pool model for synchronous I/O operations.

### Supported Operations

| Operation | Status | Implementation |
|-----------|--------|----------------|
| `read` | Working | `ReadFile` (files) / `recv` (sockets) |
| `write` | Working | `WriteFile` (files) / `send` (sockets) |
| `readv` | Working | Looped `ReadFile`/`recv` |
| `writev` | Working | Looped `WriteFile`/`send` |
| `accept` | Working | ws2_32 `accept` |
| `connect` | Working | ws2_32 `connect` |
| `close` | Working | `CloseHandle` (files) / `closesocket` (sockets) |
| `send_file` | Working | `SetFilePointerEx` + `ReadFile` + `WriteFile`/`send` |
| `copy_file_range` | Working | `ReadFile` + `WriteFile` |

### Architecture

```
┌─────────────────────────────────────────────┐
│              Application                     │
├─────────────────────────────────────────────┤
│           WindowsIocpIo                      │
│  ┌──────────────────────────────────────┐   │
│  │ IOCP Completion Port                  │   │
│  │ ┌──────┐ ┌──────┐ ┌──────┐           │   │
│  │ │Worker│ │Worker│ │Worker│ ...        │   │
│  │ │Thread│ │Thread│ │Thread│           │   │
│  │ └──────┘ └──────┘ └──────┘           │   │
│  └──────────────────────────────────────┘   │
├─────────────────────────────────────────────┤
│  ReadFile │ WriteFile │ recv │ send │ etc  │
└─────────────────────────────────────────────┘
```

### Current Limitations

1. **Synchronous under the hood**: Operations execute synchronously in worker threads, with IOCP signaling completion. True overlapped I/O is planned for future releases.

2. **Descriptor registration**: Sockets must be registered as sockets via `registerSocket()` for proper `recv`/`send` routing. Unregistered descriptors default to file I/O.

3. **No overlapped extensions**: `AcceptEx`, `ConnectEx`, `WSARecv`, `WSASend` are not yet used. These would enable kernel-managed async completion.

### Usage Example

```zig
const std = @import("std");
const zsync = @import("zsync");

pub fn main() !void {
    // Create runtime - automatically uses WindowsIocpIo on Windows
    const runtime = try zsync.createOptimalRuntime(std.heap.page_allocator);
    defer runtime.deinit();

    // Get I/O interface
    var io = runtime.getIo();

    // For socket operations, register the socket first
    try runtime.registerSocket(my_socket);

    // Now read/write will use recv/send for sockets
    var read_future = try io.read(buffer);
    defer read_future.destroy();
    try read_future.await();
}
```

### Testing

The Windows backend passes cross-compilation but has not been extensively tested on real Windows systems. Testing on Windows is appreciated.

---

## Green Threads (Linux)

**Status:** Experimental

The green threads implementation on Linux provides cooperative multitasking with io_uring integration.

### Known Limitations

- `processCompletions()` is a stub implementation
- `readv`/`writev` may ignore buffer contents in some code paths
- `connect()` may ignore address parameter in some code paths
- Green threads may hang indefinitely on blocking I/O if io_uring completions are not polled

### Recommended Usage

For production workloads, prefer the standard `BlockingIo` or `ThreadPoolIo` backends until green threads mature.

---

## Platform Support Matrix

| Platform | Backend | Status |
|----------|---------|--------|
| Linux x86_64 | io_uring | Stable |
| Linux x86_64 | BlockingIo | Stable |
| Linux aarch64 | BlockingIo | Stable |
| Windows x86_64 | IOCP | Experimental |
| macOS aarch64 | BlockingIo | Compiles |
| WASM | Stackless | Compiles |

"Compiles" indicates the code builds but may have limited runtime testing.
