# zsync Examples

Working examples demonstrating zsync features.

## Running Examples

```bash
# Build all examples
zig build

# Run specific example
zig build run-example-basic
zig build run-example-channels
zig build run-example-timers
```

## Examples

| Example | Description |
|---------|-------------|
| [basic.zig](basic.zig) | Basic runtime usage and task spawning |
| [channels.zig](channels.zig) | Channel-based message passing |
| [timers.zig](timers.zig) | Timer and interval usage |
| [sync.zig](sync.zig) | Synchronization primitives |
| [zero_copy.zig](zero_copy.zig) | Zero-copy I/O operations |

## Quick Start

```zig
const std = @import("std");
const zsync = @import("zsync");

pub fn main() !void {
    std.debug.print("zsync v{s}\n", .{zsync.VERSION});

    // Simple blocking I/O
    var io = zsync.createBlockingIo(std.heap.page_allocator);
    defer io.deinit();

    // Write using colorblind async
    var future = try io.io().write("Hello, zsync!\n");
    defer future.destroy(std.heap.page_allocator);
    try future.await();
}
```
