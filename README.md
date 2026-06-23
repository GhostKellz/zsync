<p align="center">
  <img src="assets/icons/zsync.png" alt="Zsync Logo" width="200" height="200" />
</p>

<h1 align="center">Zsync</h1>

<p align="center">
  <strong>Async Runtime for Zig</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Zig-0.17.0--dev-F7A41D?style=for-the-badge&logo=zig&logoColor=white" alt="Zig 0.17.0-dev">
  <img src="https://img.shields.io/badge/std.Io-F7A41D?style=for-the-badge&logo=zig&logoColor=white" alt="std.Io">
  <img src="https://img.shields.io/badge/Linux-FCC624?style=for-the-badge&logo=linux&logoColor=black" alt="Linux">
  <img src="https://img.shields.io/badge/WASM-654FF0?style=for-the-badge&logo=webassembly&logoColor=white" alt="WASM">
  <img src="https://img.shields.io/badge/Windows-0078D4?style=for-the-badge&logo=windows&logoColor=white" alt="Windows">
  <img src="https://img.shields.io/badge/macOS-111111?style=for-the-badge&logo=apple&logoColor=white" alt="macOS">
</p>

## Overview

Zsync is an async runtime for Zig built on top of `std.Io`. It layers
Tokio-style structured-concurrency primitives — nurseries, channels, timers, and
synchronization types — over `std.Io.Threaded`, which owns task scheduling and
platform I/O backend selection. Zsync no longer ships its own per-platform
reactor; it delegates that to the standard library.

### Key Features

- **Built on `std.Io`**: scheduling and I/O backend selection are owned by the standard library
- **Colorblind async**: the same code runs whether the backend is sync or async (`io.async` / `future.await`)
- **Tokio-style modules**: `zsync.task`, `zsync.time`, `zsync.net`, `zsync.channel.mpsc`, `zsync.process`, and `zsync.signal` provide stable scan-friendly namespaces
- **Structured concurrency**: nurseries and `JoinSet` for scoped task lifetimes
- **Primitives**: bounded/unbounded channels, timers, mutex/condition primitives, broadcast/watch channels
- **Cross-platform**: Linux, macOS, Windows, BSD, and WASM via `std.Io.Threaded`

```zig
const std = @import("std");
const zsync = @import("zsync");

fn double(x: u32) u32 {
    return x * 2;
}

fn task() void {
    // Acquire the Io installed by zsync.run - no magic injection.
    const io = zsync.getGlobalIo() orelse return;

    var f = io.async(double, .{@as(u32, 21)});
    const result = f.await(io);
    std.debug.print("result = {d}\n", .{result});
}

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();

    zsync.run(gpa.allocator(), task, .{});
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

Concurrency is expressed with structured tasks. `zsync.run` installs a
process-global `std.Io.Threaded`-backed `Io`, runs your entry task, and tears
the runtime down on return. Inside a task, acquire the `Io` with
`zsync.getGlobalIo()`.

```zig
const std = @import("std");
const zsync = @import("zsync");

fn greet(id: u32) u32 {
    std.debug.print("task {d} running\n", .{id});
    return id * id;
}

fn task() void {
    const io = zsync.getGlobalIo() orelse return;

    // Same code path whether the backend runs sync or async.
    var f0 = io.async(greet, .{@as(u32, 1)});
    var f1 = io.async(greet, .{@as(u32, 2)});

    const r0 = f0.await(io);
    const r1 = f1.await(io);
    std.debug.print("results: {d}, {d}\n", .{ r0, r1 });
}

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();

    zsync.run(gpa.allocator(), task, .{});
}
```

## Runtime & Scheduling

Zsync delegates scheduling and platform I/O backend selection to
`std.Io.Threaded`. There are no zsync-owned execution models to choose between -
the standard library picks the appropriate mechanism per target.

For finer control, create a `Runtime` directly instead of using `zsync.run`:

```zig
var runtime = zsync.Runtime.init(allocator, .{});
defer runtime.deinit();
const io = runtime.io();

var future = io.async(work, .{args});
const result = future.await(io);
```

## API Examples

Prefer the Tokio-style namespaces for new code:

```zig
const io = zsync.getGlobalIo() orelse return;
var stream = try zsync.net.TcpStream.connect(io, "127.0.0.1", 8080);
defer stream.close();

var timer = zsync.time.interval(1000);
timer.tick();

const ch = try zsync.channel.mpsc.bounded(u32, allocator, 16);
try ch.sender.send(42);
const value = try ch.receiver.recv();
_ = value;
```

### Channel Communication

```zig
const ch = try zsync.channel.mpsc.bounded(i32, allocator, 10);
defer {
    ch.channel.deinit();
    allocator.destroy(ch.channel);
}
try ch.sender.send(42);
const value = try ch.receiver.recv();
_ = value;
```

### Timer Operations

```zig
zsync.time.sleep(1000); // Sleep for 1 second
zsync.time.yieldNow();  // Cooperative yield
```

### Future Combinators

`selectFuture`, `selectTimeout`, `selectCancellable`, `allFutures`, and
`anyFuture` operate on zsync's generic `Future(T)` helper. `std.Io.Future`
values should still be awaited with the active `Io` handle.

## Platform Support

Scheduling and platform I/O backend selection are owned by `std.Io.Threaded`,
so zsync runs anywhere the standard library does:

- **Linux**: `std.Io.Threaded`
- **macOS**: `std.Io.Threaded`
- **Windows**: `std.Io.Threaded`
- **FreeBSD/OpenBSD**: `std.Io.Threaded`
- **WASM**: `std.Io.Threaded`

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

- [Docs Index](docs/README.md)
- [Getting Started](docs/getting-started/quickstart.md)
- [API Reference](docs/reference/api.md)
- [Examples](docs/guides/examples.md)
- [Architecture](docs/internals/architecture.md)
- [Architecture Diagrams](docs/internals/diagrams.md)
- [Experimental Features](docs/roadmap/experimental-features.md)
- [Future Roadmap](docs/roadmap/future-roadmap.md)
- [Performance](docs/guides/performance.md)
- [Integration](docs/guides/integration.md)
- [Security](docs/security/policy.md)
- [WASM Features](docs/platforms/wasm.md)
- [WASM Host ABI](docs/platforms/wasm-host-abi.md)

## Links

- [Issues](https://github.com/ghostkellz/zsync/issues)
