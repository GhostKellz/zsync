<p align="center">
  <img src="assets/icons/zsync.png" alt="Zsync Logo" width="200" height="200" />
</p>

<h1 align="center">Zsync</h1>

<p align="center">
  <strong>Async Runtime for Zig</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Zig-F7A41D?style=for-the-badge&logo=zig&logoColor=white" alt="Zig">
  <img src="https://img.shields.io/badge/Linux-FCC624?style=for-the-badge&logo=linux&logoColor=black" alt="Linux">
  <img src="https://img.shields.io/badge/io__uring-0A66C2?style=for-the-badge&logo=linux&logoColor=white" alt="io_uring">
  <img src="https://img.shields.io/badge/Green_Threads-2E8B57?style=for-the-badge&logo=threads&logoColor=white" alt="Green Threads">
  <img src="https://img.shields.io/badge/WASM-654FF0?style=for-the-badge&logo=webassembly&logoColor=white" alt="WASM">
  <img src="https://img.shields.io/badge/Windows-0078D4?style=for-the-badge&logo=windows&logoColor=white" alt="Windows">
  <img src="https://img.shields.io/badge/macOS-111111?style=for-the-badge&logo=apple&logoColor=white" alt="macOS">
  <img src="https://img.shields.io/badge/Zero_Cost-8A2BE2?style=for-the-badge&logo=lightning&logoColor=white" alt="Zero Cost">
</p>

## Overview

Zsync is an async runtime for Zig providing efficient async I/O operations with multiple execution models and platform-specific optimizations.

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

Add zsync to your project:

```bash
zig fetch --save https://github.com/ghostkellz/zsync/archive/refs/heads/main.tar.gz
```

Or for a specific release tag:

```bash
zig fetch --save https://github.com/ghostkellz/zsync/archive/refs/tags/<tag>.tar.gz
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
const zsync = @import("zsync");

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
Direct system calls with minimal overhead. Best for simple applications.

### Thread Pool Mode
True parallelism with work-stealing threads. Ideal for CPU-bound tasks.

### Green Thread Mode (Linux)
Cooperative multitasking with io_uring support. For high-concurrency I/O workloads.

### Auto Mode
Selects the best execution model based on platform capabilities.

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
- **macOS**: Thread pool execution
- **Windows**: Thread pool execution
- **FreeBSD/OpenBSD**: Thread pool execution

## Testing

```bash
zig build test
```

## Contributing

Contributions welcome. Please ensure:
- Code follows Zig style guidelines
- Tests pass with `zig build test`

## License

MIT License - See [LICENSE](LICENSE) for details.

## Documentation

- [Getting Started](docs/GETTING_STARTED.md)
- [API Reference](docs/API_REFERENCE.md)
- [Examples](docs/EXAMPLES.md)
- [Architecture](docs/architecture.md)
- [Performance](docs/PERFORMANCE.md)

## Links

- [Repository](https://github.com/ghostkellz/zsync)
- [Issues](https://github.com/ghostkellz/zsync/issues)
