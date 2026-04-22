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

`zsync` `v0.8.1` requires Zig `0.17.0-dev.27+0dd99c37c` or later.

## Smallest Example

```zig
const zsync = @import("zsync");

fn task() !void {
    var io = zsync.getGlobalIo() orelse return error.NoRuntime;
    var future = try io.write("hello from zsync\n");
    defer future.destroy();
    try future.await();
}

pub fn main() !void {
    try zsync.run(task, .{});
}
```

## Runtime Configuration

```zig
const std = @import("std");
const zsync = @import("zsync");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var runtime = try zsync.Runtime.init(allocator, .{
        .execution_model = .thread_pool,
        .thread_pool_threads = 4,
    });
    defer runtime.deinit();

    try runtime.run(task, .{});
}

fn task() !void {
    // Io available via zsync.getGlobalIo() if needed
}
```

## Structured Concurrency

```zig
const std = @import("std");
const zsync = @import("zsync");

fn work(id: u32) !void {
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

    try nursery.spawn(work, .{1});
    try nursery.spawn(work, .{2});
    try nursery.spawn(work, .{3});

    try nursery.wait();
}
```

## Next Steps

- [api-reference.md](api-reference.md)
- [examples.md](examples.md)
- [integration.md](integration.md)
