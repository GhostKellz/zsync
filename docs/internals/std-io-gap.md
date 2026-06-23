# zsync vs std.Io

This document summarizes how `zsync` relates to Zig's evolving `std.Io` surface.
Since the rebase, zsync no longer defines its own `Io` abstraction — it
re-exports `std.Io` as `zsync.Io` and builds structured-concurrency primitives on
top of it.

## Shared Foundation

- the `Io` interface itself (`zsync.Io == std.Io`)
- async operation handles (`std.Io.Future`)
- scheduling via `std.Io.Threaded`
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
fn work(x: u32) u32 {
    return x * 2;
}

fn task() void {
    const io = zsync.getGlobalIo() orelse return;
    var future = io.async(work, .{@as(u32, 21)});
    const result = future.await(io);
    _ = result;
}
```

## Position

zsync's async API follows Zig's `std.Io` patterns:
- The `Io` interface is the standard library's `std.Io`, re-exported as `zsync.Io`
- No automatic Io injection - tasks acquire Io explicitly via `getGlobalIo()`
- `run()` and `spawn()` pass args directly to task functions
- Task signatures match what callers pass (no hidden first parameter)

This keeps zsync aligned with std.Io's explicit argument-passing philosophy while
adding structured-concurrency features (channels, nursery) on top.
