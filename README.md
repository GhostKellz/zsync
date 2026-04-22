<p align="center">
  <img src="assets/icons/zsync.png" alt="Zsync Logo" width="200" height="200" />
</p>

<h1 align="center">Zsync</h1>

<p align="center">
  <strong>Async Runtime for Zig</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Zig-0.17.0--dev-F7A41D?style=for-the-badge&logo=zig&logoColor=white" alt="Zig 0.17.0-dev">
  <img src="https://img.shields.io/badge/Linux-FCC624?style=for-the-badge&logo=linux&logoColor=black" alt="Linux">
  <img src="https://img.shields.io/badge/io__uring-0A66C2?style=for-the-badge&logo=linux&logoColor=white" alt="io_uring">
  <img src="https://img.shields.io/badge/Green_Threads-2E8B57?style=for-the-badge&logo=threads&logoColor=white" alt="Green Threads">
  <img src="https://img.shields.io/badge/WASM-654FF0?style=for-the-badge&logo=webassembly&logoColor=white" alt="WASM">
  <img src="https://img.shields.io/badge/Windows-0078D4?style=for-the-badge&logo=windows&logoColor=white" alt="Windows">
  <img src="https://img.shields.io/badge/macOS-111111?style=for-the-badge&logo=apple&logoColor=white" alt="macOS">
  <img src="https://img.shields.io/badge/Zero_Cost-8A2BE2?style=for-the-badge&logo=lightning&logoColor=white" alt="Zero Cost">
</p>

## Overview

Zsync is an async runtime for Zig with blocking, thread-pool, and Linux-focused high-concurrency execution models.

### Key Features

- **Multiple Execution Models**: Blocking, thread pool, and auto-detection
- **Zero-Cost Abstractions**: Pay only for what you use
- **Platform Optimizations**: io_uring support on Linux with automatic capability detection
- **Advanced I/O**: Vectorized operations, backend capability detection, and efficient buffer management
- **Cancellation Support**: Cooperative cancellation with proper cleanup

### Supported vs Experimental

**Supported (v0.8.1):** `Runtime`, `Io`, `Future`, `BlockingIo`, `ThreadPoolIo`, channels, timers, nursery.

**Experimental:** Future combinators (`race`, `all`, `timeout`), green threads, stackless I/O, network integration, and other warning-labeled prototype modules. See [CHANGELOG.md](CHANGELOG.md) for details.

```zig
const zsync = @import("zsync");

pub fn main() !void {
    // Spawn concurrent tasks
    _ = try zsync.spawn(handleClient, .{client1});
    _ = try zsync.spawn(handleClient, .{client2});

    // Use channels for communication
    var ch = try zsync.channels.bounded([]const u8, allocator, 100);
    defer ch.deinit();
    try ch.send("Hello from Zsync!");
    const msg = try ch.recv();
    _ = msg;

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

fn fileProcessor() !void {
    // Acquire Io explicitly - no magic injection
    var io = zsync.getGlobalIo() orelse return error.NoRuntime;

    // Vectorized I/O operations
    var buffers = [_]zsync.IoBuffer{
        zsync.IoBuffer.init(&buffer1),
        zsync.IoBuffer.init(&buffer2),
    };

    var read_future = try io.readv(&buffers);
    defer read_future.destroy();
    try read_future.await();

    // Zero-copy operations (Linux)
    if (io.supportsZeroCopy()) {
        var copy_future = try io.copyFileRange(src_fd, dst_fd, size);
        defer copy_future.destroy();
        try copy_future.await();
    }
}

pub fn main() !void {
    try zsync.run(fileProcessor, .{}); // Auto-detects best execution model
}
```

## Execution Models

### Blocking Mode
Direct system calls with minimal overhead. Best for simple applications.

### Thread Pool Mode
True parallelism with work-stealing threads. Ideal for CPU-bound tasks.

### Green Thread Mode (Linux)
Present in the repository, but not part of the supported `v0.8.1` release surface.

### Auto Mode
Selects the best execution model based on platform capabilities.

## API Examples

### Channel Communication

```zig
var ch = try zsync.channels.bounded(i32, allocator, 10);
defer ch.deinit();
try ch.send(42);
const value = try ch.recv();
_ = value;
```

### Timer Operations

```zig
zsync.sleep(1000); // Sleep for 1 second
zsync.yieldNow();  // Cooperative yield
```

### Future Combinators

Future combinators are currently experimental for `v0.8.1`. Prefer the supported core runtime surface for stable downstream code.

## Platform Support

- **Linux**: Full support with io_uring optimizations
- **macOS**: Thread pool execution
- **Windows**: Experimental IOCP with native I/O (ReadFile/WriteFile, recv/send)
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

- [Docs Index](docs/readme.md)
- [Getting Started](docs/getting-started.md)
- [API Reference](docs/api-reference.md)
- [Examples](docs/examples.md)
- [Architecture](docs/architecture.md)
- [Experimental Features](docs/experimental-features.md)
- [Future Roadmap](docs/future-roadmap.md)
- [Performance](docs/performance.md)
- [Integration](docs/integration.md)
- [WASM Features](docs/wasm/wasm-features.md)

## Links

- [Issues](https://github.com/ghostkellz/zsync/issues)
