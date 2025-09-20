<div align="center">
  <img src="assets/icons/zsync.png" alt="Zsync Logo" width="200" height="200">

  # Zsync - High-Performance Async Runtime for Zig

  [![Zig](https://img.shields.io/badge/Zig-0.16--dev-orange.svg)](https://ziglang.org/)
  [![Green Threads](https://img.shields.io/badge/Green_Threads-Async-green.svg)](#green-thread-mode-linux)
  [![io_uring](https://img.shields.io/badge/io__uring-Linux-blue.svg)](#platform-support)
  [![Performance](https://img.shields.io/badge/Performance-Production_Ready-brightgreen.svg)](#benchmarks)
  [![Zero Cost](https://img.shields.io/badge/Zero_Cost-Abstractions-purple.svg)](#key-features)
</div>

## Overview

Zsync is a high-performance async runtime for Zig, inspired by Rust's Tokio. It provides efficient async I/O operations with multiple execution models and platform-specific optimizations.

### Key Features

- **Multiple Execution Models**: Blocking, thread pool, green threads, and auto-detection
- **Zero-Cost Abstractions**: Pay only for what you use
- **Platform Optimizations**: io_uring support on Linux with automatic capability detection
- **Advanced I/O**: Vectorized operations, zero-copy transfers, and efficient buffer management
- **Future Combinators**: `race()`, `all()`, `timeout()` for complex async patterns
- **Cancellation Support**: Cooperative cancellation with proper cleanup

```zig
const zsync = @import("zsync");

pub fn main() !void {
    // Spawn concurrent tasks
    _ = try zsync.spawn(handleClient, .{client1});
    _ = try zsync.spawn(handleClient, .{client2});
    
    // Use channels for communication
    const ch = try zsync.bounded([]const u8, allocator, 100);
    try ch.sender.send("Hello from Zsync!");
    const msg = try ch.receiver.recv();
    
    // Sleep without blocking
    zsync.sleep(1000); // 1 second
    
    // Cooperative yielding
    zsync.yieldNow();
}
```

## Installation

### Using Zig Build System

Add as a dependency to your Zig project:

```bash
zig fetch --save https://github.com/ghostkellz/zsync/archive/refs/heads/main.tar.gz
```

Add to your `build.zig`:

```zig
const zsync = b.dependency("zsync", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("zsync", zsync.module("zsync"));
```

## Quick Start

```zig
const std = @import("std");
const zsync = @import("src/runtime.zig");

fn fileProcessor(io: zsync.Io) !void {
    // Vectorized I/O operations
    var buffers = [_]zsync.IoBuffer{
        zsync.IoBuffer.init(&buffer1),
        zsync.IoBuffer.init(&buffer2),
    };
    
    var read_future = try io.readv(&buffers);
    defer read_future.destroy(io.getAllocator());
    try read_future.await();
    
    // Zero-copy operations (Linux)
    if (io.supportsZeroCopy()) {
        var copy_future = try io.copyFileRange(src_fd, dst_fd, size);
        defer copy_future.destroy(io.getAllocator());
        try copy_future.await();
    }
}

pub fn main() !void {
    try zsync.run(fileProcessor, {}); // Auto-detects best execution model
}
```

## Execution Models

### Blocking Mode
Direct system calls with minimal overhead. Best for simple applications or when async overhead isn't justified.

### Thread Pool Mode
True parallelism with work-stealing threads. Ideal for CPU-bound tasks and multi-core utilization.

### Green Thread Mode (Linux)
Cooperative multitasking with io_uring support. Excellent for high-concurrency I/O workloads.

### Auto Mode
Intelligently selects the best execution model based on platform capabilities and workload characteristics.

## API Examples

### Channel Communication

```zig
const ch = try zsync.bounded(i32, allocator, 10);
try ch.sender.send(42);
const value = try ch.receiver.recv();
```

### Timer Operations

```zig
zsync.sleep(1000); // Sleep for 1 second
zsync.yieldNow();  // Cooperative yield
```

### Future Combinators

```zig
// Race multiple futures
const result = try zsync.race(&[_]*Future{ future1, future2 });

// Wait for all futures
try zsync.all(&[_]*Future{ future1, future2, future3 });

// Timeout operations
const result = try zsync.timeout(future, 5000); // 5 second timeout
```

## Platform Support

- **Linux**: Full support with io_uring optimizations
- **macOS**: kqueue-based event loop (planned)
- **Windows**: IOCP support (planned)
- **FreeBSD**: kqueue support (planned)

## Testing

```bash
zig build test
```

## Benchmarks

Run performance benchmarks:

```bash
zig build bench
```

## Contributing

Contributions are welcome! Please ensure:
- Code follows Zig style guidelines
- Tests pass with `zig build test`
- Performance benchmarks show no regressions

## License

MIT License - See [LICENSE](LICENSE) for details.

## Links

- [Repository](https://github.com/ghostkellz/zsync)
- [Documentation](https://github.com/ghostkellz/zsync/wiki)
- [Issues](https://github.com/ghostkellz/zsync/issues)
