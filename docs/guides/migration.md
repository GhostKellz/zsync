# Migration Notes

## Minimum Zig Version

The current release line requires Zig `0.17.0-dev` or later (the release that
introduced `std.Io`).

## Rebased onto `std.Io`

zsync no longer ships its own `Io` vtable or per-platform backends. The `Io`
interface is now Zig's standard-library `std.Io`, re-exported as `zsync.Io`.
Scheduling and platform I/O backend selection are owned by `std.Io.Threaded`.

Removed in the rebase: the custom `Io` vtable, `BlockingIo`, `ThreadPoolIo`,
execution-model selection (`RuntimeOptions.execution_model` /
`.thread_pool_threads`), and zero-copy helpers (`readv`/`writev`/`IoBuffer`).

## Futures

Futures are `std.Io.Future` values from `io.async(...)`, awaited with the `Io`
handle:

```zig
var future = io.async(work, .{args});
const result = future.await(io);
```

The old allocator-taking or zero-argument `Future.destroy()` patterns no longer
apply.

## Runtime Config

`Runtime.init` takes `RuntimeOptions` by value and does not return an error
union. The only knob is `stack_size` (0 = backend default):

```zig
var runtime = zsync.Runtime.init(allocator, .{});
defer runtime.deinit();
const io = runtime.io();
```

## Supported Surface

The supported migration target is the core runtime surface:

- `run` / `getGlobalIo`
- `Runtime`
- `Io` (re-exported `std.Io`)
- `Nursery`
- `spawn` / `spawnOn`
- channels
- timers

Experimental modules remain in-tree but are not the recommended migration target for stable downstream use.

## See Also

- [API Reference](../reference/api.md)
- [Tokio Primitives](../reference/tokio-primitives.md)
- [std.Io Gap](../internals/std-io-gap.md)
