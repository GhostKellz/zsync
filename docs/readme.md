# zsync Documentation

Reference documentation for `zsync` `v0.8.0`.

## Supported Surface

The supported `v0.8.0` surface is:

- `Runtime`
- `Io`
- `Future`
- `BlockingIo`
- `ThreadPoolIo`
- channels
- timers
- nursery

Experimental modules and helpers remain in the repository, but they are outside the stability guarantees for this release.

## Documents

| Document | Purpose |
|---|---|
| [getting-started.md](getting-started.md) | Quick start and basic usage |
| [api-reference.md](api-reference.md) | Public API overview |
| [architecture.md](architecture.md) | Runtime structure and backend notes |
| [examples.md](examples.md) | Supported usage patterns |
| [integration.md](integration.md) | Integration patterns for downstream projects |
| [migration.md](migration.md) | Zig 0.17 migration notes |
| [performance.md](performance.md) | Performance guidance |
| [std-io-gap.md](std-io-gap.md) | `zsync` vs `std.Io` comparison |
| [tokio-primitives.md](tokio-primitives.md) | Primitive parity and status |
| [wasm/wasm-features.md](wasm/wasm-features.md) | WASM notes and limitations |

## Notes

- `Future.destroy()` is zero-argument.
- `race()`, `all()`, and `timeout()` are present in the public API, but they are still treated as experimental for `v0.8.0`.
- The root `README.md` is the main project landing page. This directory is for focused technical docs.
