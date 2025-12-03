# zsync Documentation

**zsync** - The Tokio of Zig

A high-performance, colorblind async runtime for Zig that provides the same ergonomic experience as Rust's Tokio.

## Overview

zsync is a dependency-free async runtime foundation that provides:

- **Colorblind Async** - Same code works in sync and async contexts
- **Multiple Execution Models** - Blocking, thread pool, green threads, io_uring
- **Zero-Cost Abstractions** - No runtime overhead when not used
- **Cross-Platform** - Linux, macOS, Windows, WASM

## Documentation

| Document | Description |
|----------|-------------|
| [Getting Started](getting-started.md) | Quick start guide |
| [API Reference](api-reference.md) | Full API documentation |
| [Architecture](architecture.md) | System design and internals |

## Quick Example

```zig
const zsync = @import("zsync");

pub fn main() !void {
    // Create runtime with optimal settings for platform
    var runtime = try zsync.createOptimalRuntime(std.heap.page_allocator);
    defer runtime.deinit();

    // Spawn concurrent tasks
    const handle = try zsync.spawn(myTask, .{});
    try handle.await();
}

fn myTask() !void {
    // Use timers
    zsync.sleep(100);

    // Use channels
    var tx, var rx = zsync.bounded(u32, 10);
    try tx.send(42);
    const value = try rx.recv();
}
```

## Ecosystem

zsync is designed to be a clean foundation for higher-level libraries:

```
┌─────────────────────────────────────────┐
│              User Application           │
├─────────┬─────────┬─────────┬───────────┤
│  zrpc   │  zhttp  │  zquic  │  zcrypto  │  ← Protocol libs
├─────────┴─────────┴─────────┴───────────┤
│                 zsync                    │  ← Async runtime
├─────────────────────────────────────────┤
│            Zig std / OS                  │
└─────────────────────────────────────────┘
```

## Version

Current: **v0.7.3**

## License

MIT
