# Examples

Examples below stick to the supported `v0.8.0` surface.

## Basic Write

```zig
const zsync = @import("zsync");

fn task(io: zsync.Io) !void {
    var future = try io.write("example output\n");
    defer future.destroy();
    try future.await();
}

pub fn main() !void {
    try zsync.run(task, .{});
}
```

## Runtime With Explicit Config

```zig
const std = @import("std");
const zsync = @import("zsync");

fn task(io: zsync.Io) !void {
    _ = io;
    zsync.sleep(5);
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var runtime = try zsync.Runtime.init(allocator, .{
        .execution_model = .thread_pool,
        .thread_pool_threads = 4,
    });
    defer runtime.deinit();

    try runtime.run(task, .{});
}
```

## Nursery

```zig
const std = @import("std");
const zsync = @import("zsync");

fn worker(id: u32) !void {
    _ = id;
    zsync.sleep(10);
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var runtime = try zsync.Runtime.init(allocator, .{
        .execution_model = .thread_pool,
        .thread_pool_threads = 4,
    });
    defer runtime.deinit();

    const nursery = try zsync.Nursery.init(allocator, runtime);
    defer nursery.deinit();

    try nursery.spawn(worker, .{1});
    try nursery.spawn(worker, .{2});
    try nursery.spawn(worker, .{3});

    try nursery.wait();
}
```

## Channels

```zig
const std = @import("std");
const zsync = @import("zsync");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var ch = try zsync.channels.bounded(i32, allocator, 8);
    defer ch.deinit();

    try ch.send(42);
    const value = try ch.recv();
    _ = value;
}
```

## Notes

- For public examples shipped with the release, prefer `BlockingIo`, `ThreadPoolIo`, runtime helpers, channels, timers, and nursery.
- Experimental features such as combinators, green-thread backends, and stackless/WASM helpers should be documented separately as experimental.
