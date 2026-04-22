# Migration Notes

## Minimum Zig Version

The current release line requires Zig `0.17.0-dev.27+0dd99c37c` or later.

## `Future.destroy()`

The current API uses zero-argument destruction:

```zig
var future = try io.write("data");
defer future.destroy();
try future.await();
```

Old docs and older code may still show allocator-taking cleanup. That pattern is obsolete.

## Runtime Config

`Runtime.init` takes `Config` by value:

```zig
var runtime = try zsync.Runtime.init(allocator, .{
    .execution_model = .thread_pool,
    .thread_pool_threads = 4,
});
defer runtime.deinit();
```

## Supported Surface

For `v0.8.1`, the supported migration target is the core runtime surface:

- `Runtime`
- `Io`
- `Future`
- `BlockingIo`
- `ThreadPoolIo`
- channels
- timers
- nursery

Experimental modules remain in-tree but are not the recommended migration target for stable downstream use.

## See Also

- [api-reference.md](api-reference.md)
- [tokio-primitives.md](tokio-primitives.md)
- [std-io-gap.md](std-io-gap.md)
