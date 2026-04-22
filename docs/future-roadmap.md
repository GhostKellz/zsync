# Future Roadmap

This document outlines planned improvements and features for zsync.

## Windows Native I/O

### Phase 1: Current State (v0.8.1) ✓

- Worker thread pool with IOCP completion signaling
- Synchronous I/O via `ReadFile`/`WriteFile` and `recv`/`send`
- Descriptor kind tracking (file vs socket)
- Basic socket operations (`accept`, `connect`, `close`)

### Phase 2: Overlapped File I/O

Replace synchronous file operations with true overlapped I/O:

```zig
// Current (synchronous in worker thread)
ReadFile(handle, buffer, len, &bytes_read, null);

// Target (overlapped)
ReadFile(handle, buffer, len, null, &overlapped);
// ... wait for IOCP completion
```

Benefits:
- Eliminates worker thread overhead for file I/O
- Better scalability for many concurrent file operations
- Lower latency for disk operations

### Phase 3: Winsock Overlapped I/O

Replace synchronous socket operations with overlapped Winsock:

| Current | Target |
|---------|--------|
| `recv()` | `WSARecv()` with overlapped |
| `send()` | `WSASend()` with overlapped |
| `accept()` | `AcceptEx()` |
| `connect()` | `ConnectEx()` |

Implementation steps:
1. Load function pointers via `WSAIoctl` (required for `AcceptEx`/`ConnectEx`)
2. Implement overlapped receive/send with WSABUF arrays
3. Implement AcceptEx with pre-allocated accept buffers
4. Implement ConnectEx with proper socket binding

### Phase 4: Zero-Copy Support

Investigate `TransmitFile` for zero-copy file-to-socket transfers:

```zig
TransmitFile(
    socket,
    file_handle,
    bytes_to_send,
    bytes_per_send,
    overlapped,
    null,
    0
);
```

---

## Linux Enhancements

### io_uring Improvements

1. **Kernel timeout**: Replace cooperative polling with `io_uring_enter` timeout
2. **Registered buffers**: Use `IORING_REGISTER_BUFFERS` for zero-copy
3. **Fixed files**: Use `IORING_REGISTER_FILES` for reduced syscall overhead
4. **Multishot accept**: Use `IORING_ACCEPT_MULTISHOT` for high-throughput servers

### Green Threads

1. Fix `processCompletions()` stub
2. Proper buffer handling in vectored operations
3. Stack pooling for reduced allocation
4. Integration with io_uring SQE batching

---

## macOS Support

### kqueue Backend

Implement native kqueue backend for macOS:

```zig
pub const KqueueBackend = struct {
    kq: i32,

    pub fn addRead(self: *@This(), fd: i32, udata: usize) !void {
        var ev: std.os.darwin.Kevent = .{
            .ident = @intCast(fd),
            .filter = std.os.darwin.EVFILT.READ,
            .flags = std.os.darwin.EV.ADD,
            .udata = udata,
            // ...
        };
        try kevent(self.kq, &[_]Kevent{ev}, &[_]Kevent{}, null);
    }
};
```

---

## Cross-Platform Goals

### Unified API

Ensure consistent behavior across platforms:

| Feature | Linux | Windows | macOS |
|---------|-------|---------|-------|
| File read/write | io_uring | IOCP | kqueue + read |
| Socket I/O | io_uring | IOCP + Winsock | kqueue + recv |
| Timers | timerfd | Waitable timers | kqueue EVFILT_TIMER |
| File watching | inotify | ReadDirectoryChangesW | kqueue EVFILT_VNODE |

### Performance Targets

- Sub-microsecond operation submission
- Linear scaling to 100K+ concurrent operations
- Zero-copy where supported by OS
- Minimal allocation in hot paths

---

## Documentation

- API reference with examples
- Platform-specific guides
- Performance tuning guide
- Migration guide from other async runtimes

---

## Version Timeline

| Version | Focus |
|---------|-------|
| v0.8.1 | Windows compiles, basic native I/O |
| v0.9.0 | Windows overlapped file I/O |
| v1.0.0 | Windows overlapped socket I/O, macOS kqueue |
| v1.1.0 | Performance optimization, zero-copy |

Timeline is subject to change based on community feedback and priorities.
