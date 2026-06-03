# Examples

Examples below use the supported public surface built on `std.Io`.

## Basic Async Task

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

## Runtime Created Directly

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

## Nursery

```zig
const std = @import("std");
const zsync = @import("zsync");

fn worker(id: u32) void {
    _ = id;
    zsync.sleep(10);
}

fn task() void {
    const io = zsync.getGlobalIo() orelse return;

    var nursery = zsync.Nursery.init(io);
    defer nursery.deinit();

    nursery.spawn(worker, .{@as(u32, 1)}) catch return;
    nursery.spawn(worker, .{@as(u32, 2)}) catch return;
    nursery.spawn(worker, .{@as(u32, 3)}) catch return;

    nursery.wait() catch return;
}

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();

    zsync.run(gpa.allocator(), task, .{});
}
```

## Channels

```zig
const std = @import("std");
const zsync = @import("zsync");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var ch = try zsync.channels.bounded(i32, allocator, 8);
    defer ch.deinit();

    try ch.send(42);
    const value = try ch.recv();
    _ = value;
}
```

## Notes

- Scheduling and platform I/O backend selection are owned by `std.Io.Threaded`;
  there are no execution models to configure.
- Experimental features such as future combinators (`select.zig`) and WASM
  helpers are documented separately as experimental.
