# Performance Guide

## Scheduling

Scheduling and platform I/O backend selection are owned by `std.Io.Threaded`.
There are no execution models to select — the standard library picks the
appropriate mechanism per target.

## Practical Advice

- Batch small units of work instead of spawning extremely fine-grained tasks.
- Use a nursery to scope concurrent work and bound task lifetimes.
- Prefer the supported core surface for release workloads.

## Current Caveats

- Some prototype modules (future combinators, WASM helpers) remain experimental.

## See Also

- [Quickstart](../getting-started/quickstart.md)
- [API Reference](../reference/api.md)
- [Examples](examples.md)
