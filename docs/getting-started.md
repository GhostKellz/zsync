# Getting Started

## Install

```bash
zig fetch --save https://github.com/ghostkellz/zsync/archive/refs/heads/main.tar.gz
```

Then add the dependency in `build.zig`:

```zig
const zsync = b.dependency("zsync", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("zsync", zsync.module("zsync"));
```

## Minimum Zig Version

`zsync` requires Zig `0.17.0-dev` or later (the release that introduced
`std.Io`).

## Smallest Example

`zsync.run` installs a process-global `std.Io.Threaded`-backed `Io`, runs your
entry task, and tears the runtime down on return. Acquire the `Io` inside a task
with `zsync.getGlobalIo()`.

```zig
const std = @import("std");
const zsync = @import("zsync");

fn double(x: u32) u32 {
    return x * 2;
}

fn task() void {
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

`zsync.run` returns whatever your task function returns (including its error
set); there are no execution models to choose between — scheduling and platform
I/O backend selection are owned by `std.Io.Threaded`.

## Runtime Configuration

For finer control, create a `Runtime` directly. `RuntimeOptions` is intentionally
slim — the only knob is `stack_size` (0 = backend default).

```zig
const std = @import("std");
const zsync = @import("zsync");

fn work(x: u32) u32 {
    return x + 1;
}

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();

    var runtime = zsync.Runtime.init(gpa.allocator(), .{});
    defer runtime.deinit();
    const io = runtime.io();

    var future = io.async(work, .{@as(u32, 41)});
    const result = future.await(io);
    std.debug.print("result = {d}\n", .{result});
}
```

## Structured Concurrency

A `Nursery` scopes a group of tasks to a single lifetime — `wait()` blocks until
all spawned tasks complete.

```zig
const std = @import("std");
const zsync = @import("zsync");

fn work(id: u32) void {
    _ = id;
    zsync.sleep(10);
}

fn task() void {
    const io = zsync.getGlobalIo() orelse return;

    var nursery = zsync.Nursery.init(io);
    defer nursery.deinit();

    nursery.spawn(work, .{@as(u32, 1)}) catch return;
    nursery.spawn(work, .{@as(u32, 2)}) catch return;
    nursery.spawn(work, .{@as(u32, 3)}) catch return;

    nursery.wait() catch return;
}

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();

    zsync.run(gpa.allocator(), task, .{});
}
```

## Next Steps

- [api-reference.md](api-reference.md)
- [examples.md](examples.md)
- [integration.md](integration.md)
