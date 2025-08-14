# Zsync Integration Guide

Zsync is a modern async I/O runtime for Zig that provides high-performance, cross-platform asynchronous operations with multiple execution models.

## Core Features

- **Multiple Execution Models**: BlockingIo, ThreadPoolIo, GreenThreadsIo, StacklessIo
- **Automatic Model Selection**: Runtime automatically selects optimal execution model per platform
- **Future-based API**: Modern async/await patterns with cancellation support
- **High-Performance I/O**: Zero-copy operations, vectorized I/O, hardware acceleration
- **Network Integration**: Built-in support for TCP/UDP, TLS, HTTP/3, QUIC protocols
- **Cross-Platform**: Linux (io_uring), macOS (kqueue), Windows (IOCP) support

## Basic Usage

### Simple Integration

```zig
const zsync = @import("zsync");

pub fn main() !void {
    try zsync.run(myAsyncMain);
}

fn myAsyncMain(io: zsync.Io) !void {
    // Your async code here
    const data = "Hello, async world!\n";
    var future = try io.async_write(data);
    defer future.destroy(allocator);
    try future.await();
}
```

### Custom Runtime Configuration

```zig
const zsync = @import("zsync");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    
    const config = zsync.runtime.Config{
        .execution_model = .thread_pool,
        .thread_pool_threads = 8,
        .buffer_size = 8192,
    };
    
    const runtime = try zsync.runtime.Runtime.init(gpa.allocator(), config);
    defer runtime.deinit();
    
    try runtime.run(myAsyncMain);
}
```

## Build Integration

Add zsync as a dependency in your `build.zig`:

```zig
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zsync_dep = b.dependency("zsync", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "your-app",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    
    exe.root_module.addImport("zsync", zsync_dep.module("zsync"));
    b.installArtifact(exe);
}
```

## API Reference

### Core Types

- **`zsync.Runtime`**: Main runtime instance with configurable execution models
- **`zsync.Io`**: Unified I/O interface with vtable dispatch
- **`zsync.Future`**: Represents pending asynchronous operations
- **`zsync.Task`**: Task management for concurrent operations
- **`zsync.CancelToken`**: Cooperative cancellation support

### Runtime Functions

```zig
// Convenience functions for different use cases
try zsync.run(main_task);              // Auto execution model
try zsync.runHighPerf(main_task);      // ThreadPool (8 threads)
try zsync.runIoFocused(main_task);     // GreenThreads (2048 max)
try zsync.runBlocking(main_task);      // Direct syscalls
```

### I/O Operations

```zig
// Basic async operations
var future = try io.async_read(buffer);
var future = try io.async_write(data);

// Vectorized I/O
var future = try io.async_readv(buffers);
var future = try io.async_writev(data_buffers);

// High-performance operations
var future = try io.async_send_file(src_fd, offset, count);
var future = try io.async_copy_file_range(src_fd, dst_fd, count);

// Network operations
var future = try io.async_accept(listener_fd);
var future = try io.async_connect(fd, address);
```

### Future Combinators

```zig
const zsync = @import("zsync");

// Timeout operations
var future_with_timeout = try zsync.future_combinators.timeout(future, 5000); // 5s timeout

// Race multiple futures
var first_result = try zsync.future_combinators.race(&[_]zsync.Future{future1, future2});

// Wait for all futures
var all_results = try zsync.future_combinators.all(&[_]zsync.Future{future1, future2});
```

### Task Management

```zig
// Batch operations
var batch = zsync.TaskBatch.init(allocator);
defer batch.deinit();

try batch.add(task1);
try batch.add(task2);
try batch.executeAll();
```

## Advanced Features

### Network Integration Layer

```zig
const zsync = @import("zsync");

var pool = try zsync.NetworkPool.init(allocator, .{
    .max_connections = 100,
    .timeout_ms = 30000,
});
defer pool.deinit();

const request = zsync.NetworkRequest{
    .method = .GET,
    .url = "https://api.example.com/data",
};

var response = try pool.execute(request);
defer response.deinit();
```

### File Operations

```zig
const zsync = @import("zsync");

var file_ops = zsync.FileOps.init(allocator);
defer file_ops.deinit();

// Async file operations with caching
var data = try file_ops.readFile("config.json");
try file_ops.writeFile("output.txt", processed_data);
```

### Hardware Acceleration

```zig
const zsync = @import("zsync");

// Enable hardware acceleration where available
const config = zsync.runtime.Config{
    .execution_model = .auto,
    .buffer_size = 64 * 1024, // Larger buffers for HW accel
};
```

## Platform-Specific Optimizations

### Linux (io_uring)
- Automatic detection and usage of io_uring for kernel >= 5.1
- Batch submission for improved throughput
- Memory-mapped I/O for large files

### macOS (kqueue)  
- Efficient event notification with kqueue
- Optimized for green threads model
- Native file monitoring support

### Windows (IOCP)
- Integration with Windows I/O Completion Ports
- Thread pool model preferred
- Native async file operations

## Performance Tuning

### Buffer Configuration
```zig
const config = zsync.runtime.Config{
    .buffer_size = 16 * 1024,        // 16KB buffers
    .thread_pool_threads = 4,         // Match CPU cores
    .max_green_threads = 1024,        // Adjust for workload
    .green_thread_stack_size = 32 * 1024, // 32KB stacks
};
```

### Execution Model Selection
- **BlockingIo**: Lowest latency, CPU-bound workloads
- **ThreadPoolIo**: High throughput, parallel processing
- **GreenThreadsIo**: High concurrency, I/O-bound workloads
- **Auto**: Platform-optimized selection

## Error Handling

```zig
const IoError = zsync.io_interface.IoError;

fn handleIoOperation(io: zsync.Io) !void {
    var future = io.async_read(buffer) catch |err| switch (err) {
        IoError.WouldBlock => return, // Handle non-blocking
        IoError.ConnectionClosed => return, // Clean shutdown
        IoError.TimedOut => return, // Retry logic
        else => return err, // Propagate other errors
    };
    
    defer future.destroy(allocator);
    future.await() catch |err| {
        // Handle completion errors
        std.log.err("I/O operation failed: {}", .{err});
    };
}
```

## Testing Integration

```zig
const testing = std.testing;
const zsync = @import("zsync");

test "zsync integration test" {
    const TestTask = struct {
        fn task(io: zsync.Io) !void {
            const data = "test data";
            var future = try io.async_write(data);
            defer future.destroy(testing.allocator);
            try future.await();
        }
    };
    
    try zsync.runBlocking(TestTask.task);
}
```

## Migration from Other Async Runtimes

### From Standard Library
Replace `std.Thread.spawn` with `zsync.spawn` for better task management.

### From Other Zig Async Libraries
Zsync provides compatibility layers and migration utilities. See `src/migration_guide.zig`.

## Troubleshooting

### Common Issues

1. **Build Errors**: Ensure Zig version >= 0.12.0
2. **Platform Compatibility**: Some features require specific OS versions
3. **Memory Usage**: Adjust buffer sizes for memory-constrained environments
4. **Performance**: Use profiling tools to identify bottlenecks

### Debug Options
```zig
// Enable debug logging
const zsync = @import("zsync");
const config = zsync.runtime.Config{
    .execution_model = .auto,
    // Debug builds automatically enable additional logging
};
```

For more examples and advanced usage patterns, see the `/examples` directory and test files in the zsync repository.