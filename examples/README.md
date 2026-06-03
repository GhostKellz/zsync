# zsync Examples

Working examples demonstrating zsync features.

## Running Examples

```bash
# Build all examples (basic, channels, timers, sync) into zig-out/bin
zig build examples

# Run the high-performance HTTP server example
zig build http-server
```

## Examples

| Example | Description |
|---------|-------------|
| [basic.zig](basic.zig) | Basic runtime usage and colorblind async |
| [channels.zig](channels.zig) | Channel-based message passing |
| [timers.zig](timers.zig) | Timer and interval usage |
| [sync.zig](sync.zig) | Synchronization primitives |
| [spawn_basic.zig](spawn_basic.zig) | Task spawning with `spawn` / `spawnOn` |
| [semaphore.zig](semaphore.zig) | Semaphore usage |
| [executor.zig](executor.zig) | Executor patterns |
| [high_performance_server.zig](high_performance_server.zig) | HTTP server on `std.Io.net` |

## Quick Start

```zig
const std = @import("std");
const zsync = @import("zsync");

fn greet(id: u32) u32 {
    std.debug.print("task {d} running\n", .{id});
    return id * id;
}

fn task() void {
    // Acquire the Io installed by zsync.run - no magic injection.
    const io = zsync.getGlobalIo() orelse return;

    var f = io.async(greet, .{@as(u32, 1)});
    std.debug.print("result = {d}\n", .{f.await(io)});
}

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();

    zsync.run(gpa.allocator(), task, .{});
}
```
