# zsync API Documentation

## Overview

zsync provides a future-compatible async runtime for Zig that aligns with the upcoming `std.Io` interface design. The API is designed to be "colorblind" - the same code works across multiple execution models without modification.

## Current API (v0.1.x)

### Core Types

```zig
const zsync = @import("zsync");
const std = @import("std");

// I/O interface type (future std.Io compatible)
const Io = zsync.Io;

// Future type for async operations
const Future = zsync.Future;
```

### Execution Models

zsync supports multiple execution models through different `Io` implementations:

#### 1. Blocking I/O
```zig
const blocking_io = zsync.BlockingIo.init();
// Maps directly to syscalls - C-equivalent performance
// Best for: CPU-bound tasks, simple applications
```

#### 2. Thread Pool I/O
```zig
const thread_pool_io = try zsync.ThreadPoolIo.init(allocator, .{
    .max_threads = 8,
    .queue_size = 1024,
});
defer thread_pool_io.deinit();
// Uses OS threads for parallelism
// Best for: Mixed I/O and CPU workloads
```

#### 3. Green Threads I/O
```zig
const green_threads_io = try zsync.GreenThreadsIo.init(allocator, .{
    .stack_size = 64 * 1024,
    .max_threads = std.Thread.getCpuCount(),
});
defer green_threads_io.deinit();
// Stack-swapping coroutines with io_uring/epoll
// Best for: High-concurrency I/O-bound applications
```

### Basic Async Operations

#### Spawning Async Tasks
```zig
fn saveData(io: Io, data: []const u8) !void {
    // Spawn concurrent file operations
    var future_a = io.async(saveFile, .{ io, data, "saveA.txt" });
    defer future_a.cancel(io) catch {};
    
    var future_b = io.async(saveFile, .{ io, data, "saveB.txt" });
    defer future_b.cancel(io) catch {};
    
    // Wait for completion
    try future_a.await(io);
    try future_b.await(io);
}

fn saveFile(io: Io, data: []const u8, path: []const u8) !void {
    const file = try Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    try file.writeAll(io, data);
}
```

#### Error Handling and Cancellation
```zig
fn robustOperation(io: Io) !void {
    var future = io.async(longRunningTask, .{io});
    defer future.cancel(io) catch {}; // Always cleanup
    
    // Early return triggers cancellation via defer
    if (shouldCancel()) return error.Canceled;
    
    try future.await(io);
}
```

### Timer Operations

```zig
// High-precision sleep
try zsync.time.sleep(io, 1000); // 1 second

// Timeout wrapper
const result = zsync.time.timeout(io, 5000, longOperation, .{io});
try result; // Error if timeout exceeded
```

### Channel Communication

```zig
// Create bounded channel
var channel = try zsync.Channel([]const u8).init(allocator, 100);
defer channel.deinit();

// Producer
var send_future = channel.send(io, "hello");
defer send_future.cancel(io) catch {};

// Consumer  
var recv_future = channel.recv(io);
defer recv_future.cancel(io) catch {};

try send_future.await(io);
const message = try recv_future.await(io);
```

### Network Operations

#### TCP Server
```zig
fn runServer(io: Io) !void {
    const listener = try zsync.net.TcpListener.bind(io, "127.0.0.1", 8080);
    defer listener.close(io);
    
    while (true) {
        const conn = try listener.accept(io);
        _ = io.async(handleConnection, .{ io, conn });
    }
}

fn handleConnection(io: Io, conn: zsync.net.TcpStream) !void {
    defer conn.close(io);
    
    var buffer: [1024]u8 = undefined;
    const bytes_read = try conn.read(io, &buffer);
    try conn.writeAll(io, buffer[0..bytes_read]);
}
```

#### TCP Client
```zig
fn runClient(io: Io) !void {
    const conn = try zsync.net.TcpStream.connect(io, "127.0.0.1", 8080);
    defer conn.close(io);
    
    try conn.writeAll(io, "Hello, Server!");
    
    var buffer: [1024]u8 = undefined;
    const bytes_read = try conn.read(io, &buffer);
    std.debug.print("Received: {s}\n", .{buffer[0..bytes_read]});
}
```

## Planned API (v0.2.x)

### Full std.Io Compatibility

```zig
// Direct compatibility with Zig's std.Io interface
fn saveData(io: std.Io, data: []const u8) !void {
    var a_future = io.async(saveFile, .{io, data, "saveA.txt"});
    defer a_future.cancel(io) catch {};
    
    var b_future = io.async(saveFile, .{io, data, "saveB.txt"});
    defer b_future.cancel(io) catch {};
    
    try a_future.await(io);
    try b_future.await(io);
    
    const out: std.Io.File = .stdout();
    try out.writeAll(io, "save complete");
}
```

### Stackless Coroutines (WASM-Compatible)

```zig
const stackless_io = try zsync.StacklessIo.init(allocator, .{
    .frame_pool_size = 1000,
    .max_concurrent = 10000,
});
defer stackless_io.deinit();

// Same API, but works in WASM environments
fn wasmCompatibleCode(io: std.Io) !void {
    var future = io.async(asyncOperation, .{io});
    defer future.cancel(io) catch {};
    try future.await(io);
}
```

### Advanced I/O Operations

```zig
// Zero-copy file transfers
const reader = try file.reader(io);
try writer.sendFile(io, reader, .{ .limit = 1024 * 1024 });

// Vectorized writes with repetition
const segments = [_][]const u8{ "Hello", " ", "World" };
try writer.drain(io, &segments, 10); // Repeat "World" 10 times
```

### Enhanced Error Handling

```zig
fn robustNetworking(io: std.Io) !void {
    var conn_future = io.async(connectWithRetry, .{io, "example.com", 80});
    defer conn_future.cancel(io) catch {};
    
    const conn = conn_future.await(io) catch |err| switch (err) {
        error.ConnectionRefused => return error.ServiceUnavailable,
        error.Canceled => return error.OperationCanceled,
        else => return err,
    };
    
    defer conn.close(io);
    // ... rest of operation
}
```

## Migration Guide

### From Sync to Async

**Before (synchronous):**
```zig
fn processFile(path: []const u8) !void {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    
    const contents = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(contents);
    
    processData(contents);
}
```

**After (async with zsync):**
```zig
fn processFile(io: Io, path: []const u8) !void {
    const file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    
    const contents = try file.readToEndAlloc(io, allocator, 1024 * 1024);
    defer allocator.free(contents);
    
    var future = io.async(processData, .{contents});
    defer future.cancel(io) catch {};
    try future.await(io);
}
```

### Choosing an Execution Model

| Use Case | Recommended Model | Rationale |
|----------|------------------|-----------|
| CPU-intensive computation | `BlockingIo` | No async overhead, direct syscalls |
| Mixed I/O and CPU work | `ThreadPoolIo` | OS threads handle blocking efficiently |
| High-concurrency servers | `GreenThreadsIo` | Efficient context switching, io_uring |
| WASM applications | `StacklessIo` (v0.2+) | No stack swapping, browser compatible |
| Embedded systems | `BlockingIo` or custom | Minimal memory footprint |

## Best Practices

### Resource Management
```zig
// Always use defer for cleanup
fn safeAsyncOperation(io: Io) !void {
    var future = io.async(operation, .{io});
    defer future.cancel(io) catch {}; // Ensures cleanup on early return
    
    // ... other operations that might fail
    
    try future.await(io);
}
```

### Error Propagation
```zig
// Separate await and error handling for proper resource cleanup
fn properErrorHandling(io: Io) !void {
    var future_a = io.async(taskA, .{io});
    defer future_a.cancel(io) catch {};
    
    var future_b = io.async(taskB, .{io});
    defer future_b.cancel(io) catch {};
    
    // Await both before checking errors
    const result_a = future_a.await(io);
    const result_b = future_b.await(io);
    
    // Now handle errors
    try result_a;
    try result_b;
}
```

### Performance Optimization
```zig
// Use single Io implementation per program for de-virtualization
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    
    // Single Io type enables guaranteed de-virtualization
    const io = try zsync.GreenThreadsIo.init(gpa.allocator(), .{});
    defer io.deinit();
    
    try runApplication(io.interface());
}
```

## Platform Support

| Platform | v0.1.x | v0.2.x | Notes |
|----------|--------|--------|-------|
| Linux x86_64 | ✅ Full | ✅ Full | io_uring, epoll, green threads |
| Linux ARM64 | ⚠️ Limited | ✅ Full | No green threads in v0.1.x |
| macOS x86_64 | ⚠️ Limited | ✅ Full | kqueue integration in v0.2.x |
| macOS ARM64 | ⚠️ Limited | ✅ Full | kqueue integration in v0.2.x |
| Windows x64 | ❌ None | ✅ Full | IOCP integration in v0.2.x |
| WASM | ❌ None | ✅ Full | Stackless coroutines only |

## Examples

See the `examples/` directory for complete working examples:
- `examples/http_server.zig` - HTTP server with different I/O models
- `examples/echo_server.zig` - TCP echo server
- `examples/file_processor.zig` - Concurrent file processing
- `examples/chat_server.zig` - WebSocket-style chat server
- `examples/benchmark.zig` - Performance comparison across models

## Contributing

zsync is designed to be the reference implementation for Zig's async I/O future. Contributions are welcome! See `CONTRIBUTING.md` for guidelines.

## Compatibility

zsync maintains compatibility with:
- Zig 0.15.x (current stable)
- Future Zig 0.16+ async features (seamless migration planned)
- Standard library evolution (tracks std.Io development)

For the latest updates, see [FUTURE.md](FUTURE.md) and [ROAD_TO_0.2.md](ROAD_TO_0.2.md).