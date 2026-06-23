# Integration Guide

This guide covers the supported integration patterns for downstream projects.

## Canonical Runtime Pattern

`zsync.run` installs a process-global `Io`, runs your entry task, and tears the
runtime down on return. Acquire the `Io` inside a task with `getGlobalIo()`.

```zig
const std = @import("std");
const zsync = @import("zsync");

fn double(x: u32) u32 {
    return x * 2;
}

fn task() void {
    const io = zsync.getGlobalIo() orelse return;
    var f = io.async(double, .{@as(u32, 21)});
    std.debug.print("result = {d}\n", .{f.await(io)});
}

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();

    zsync.run(gpa.allocator(), task, .{});
}
```

## Testing Pattern

For tests, drive a `Runtime` directly so you control setup and teardown:

```zig
const std = @import("std");
const zsync = @import("zsync");

fn add(a: u32, b: u32) u32 {
    return a + b;
}

test "integration task" {
    var runtime = zsync.Runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();
    const io = runtime.io();

    var future = io.async(add, .{ @as(u32, 2), @as(u32, 3) });
    try std.testing.expectEqual(@as(u32, 5), future.await(io));
}
```

## Runtime Guidance

Scheduling and platform I/O backend selection are owned by `std.Io.Threaded`;
there are no execution models to choose. Use `zsync.run` for an application
entry point, or `zsync.Runtime.init` when you need to own the runtime lifetime
explicitly.

## Supported Surface

This guide assumes use of:

- `run` / `getGlobalIo`
- `Runtime`
- `Io` (re-exported `std.Io`)
- `Nursery`
- `spawn` / `spawnOn`
- channels
- timers

Experimental modules are intentionally excluded from the recommended integration path.

## See Also

- [Quickstart](../getting-started/quickstart.md)
- [API Reference](../reference/api.md)
- [Examples](examples.md)
