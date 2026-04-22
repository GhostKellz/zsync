# zsync vs std.Io

This document summarizes the current gap between `zsync` and Zig's evolving `std.Io` surface.

## Shared Concepts

- vtable-based I/O abstraction
- async operation handles
- backend-specific capability reporting
- cancellation and timeout coordination

## Where `std.Io` Is Broader

- filesystem coverage
- process operations
- grouping and batching primitives
- more unified time and timeout primitives

## Where `zsync` Still Adds Value

- a smaller runtime-facing API for downstream packages already using `zsync`
- channels and nursery-oriented structured concurrency
- a simpler migration path for projects already written around `zsync.Io`

## Current Interop Pattern

```zig
fn task() !void {
    var io = zsync.getGlobalIo() orelse return error.NoRuntime;
    var future = try io.write("data");
    defer future.destroy();
    try future.await();
}
```

## v0.8.1 Position

`v0.8.1` aligns zsync's async API with Zig 0.17.0-dev `std.Io` patterns:
- No automatic Io injection - tasks acquire Io explicitly via `getGlobalIo()`
- `run()` and `spawn()` pass args directly to task functions
- Task signatures match what callers pass (no hidden first parameter)

This brings zsync closer to std.Io's explicit argument passing philosophy while maintaining zsync's structured concurrency features (channels, nursery).
