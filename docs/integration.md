# Integration Guide

This guide covers the supported `v0.8.1` integration patterns for downstream projects.

## Canonical Runtime Pattern

```zig
const std = @import("std");
const zsync = @import("zsync");

fn task() !void {
    var io = zsync.getGlobalIo() orelse return error.NoRuntime;
    var future = try io.write("hello from zsync\n");
    defer future.destroy();
    try future.await();
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var runtime = try zsync.Runtime.init(allocator, .{});
    defer runtime.deinit();

    try runtime.run(task, .{});
}
```

## Testing Pattern

```zig
const std = @import("std");
const zsync = @import("zsync");

test "integration task" {
    const allocator = std.testing.allocator;

    var blocking = zsync.createBlockingIo(allocator);
    defer blocking.deinit();

    var io = blocking.io();
    var future = try io.write("test");
    defer future.destroy();
    try future.await();
}
```

## Execution Model Guidance

- `.blocking`: simple tools, tests, deterministic execution
- `.thread_pool`: CPU-bound work and the main cross-platform async backend
- `.auto`: good default when you want platform-aware selection

## Supported Surface

This guide assumes use of:

- `Runtime`
- `Io`
- `Future`
- `BlockingIo`
- `ThreadPoolIo`
- channels
- timers
- nursery

Experimental modules are intentionally excluded from the recommended integration path for `v0.8.1`.

## See Also

- [getting-started.md](getting-started.md)
- [api-reference.md](api-reference.md)
- [examples.md](examples.md)
