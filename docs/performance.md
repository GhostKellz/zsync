# Performance Guide

## Execution Model Selection

- `blocking`: lowest overhead, simplest behavior, best for tests and simple tools
- `thread_pool`: main cross-platform concurrent backend
- `auto`: good default when you want platform-aware selection

## Practical Advice

- Batch small units of work instead of spawning extremely fine-grained tasks.
- Match `thread_pool_threads` to workload type rather than setting it arbitrarily high.
- Prefer supported backends for release workloads.

## Current Caveats

- Some advanced backends and prototype modules remain experimental.
- `Io.readSync()` and `Io.writeSync()` still expose documented byte-count limitations.
- `io_uring.poll(timeout_ms)` still has a documented timeout limitation.

## See Also

- [getting-started.md](getting-started.md)
- [api-reference.md](api-reference.md)
- [examples.md](examples.md)
