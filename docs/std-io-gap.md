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
fn task(io: zsync.Io) !void {
    var future = try io.write("data");
    defer future.destroy();
    try future.await();
}
```

## v0.8.0 Position

`v0.8.0` is a Zig 0.17 compatibility release, not a full `std.Io` convergence release. The goal is a stable supported core plus clearly-labeled experimental areas.
