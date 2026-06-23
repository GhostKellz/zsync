# Experimental Features

This document outlines features that are present in zsync but outside the
stability guarantees of the supported core surface. They are functional but may
have limitations or undergo API changes.

Since the `std.Io` rebase, scheduling and platform I/O backend selection are
owned by `std.Io.Threaded`. zsync no longer ships its own per-platform reactors
(io_uring, IOCP, kqueue) — those concerns belong to the standard library.

## Future Combinators (`select.zig`)

**Status:** Experimental

`race()`, `all()`, and `timeout()` are present but not part of the stable
surface. APIs may change. Prefer the supported core runtime surface (`run`,
`Runtime`, `Nursery`, channels, timers) for stable downstream code.

## Networking (`net/`)

**Status:** Experimental

Built on `std.Io.net`:

- `net/websocket.zig` — WebSocket (RFC 6455)
- `net/pool.zig` — connection pooling
- `net/rate_limit.zig` — rate limiting

These compile and have unit-test coverage, but the APIs may evolve as
`std.Io.net` stabilizes.

## WASM Helpers (`wasm/`)

**Status:** Experimental

`wasm/async.zig` and `wasm/microtask.zig` provide microtask-queue helpers for
browser integration. Limited runtime testing.

## Platform Support

All platforms route through `std.Io.Threaded`; the standard library picks the
appropriate mechanism per target.

| Platform | Backend | Status |
|----------|---------|--------|
| Linux x86_64 | `std.Io.Threaded` | Verified |
| Linux aarch64 | `std.Io.Threaded` | Cross-compiles |
| Windows x86_64 | `std.Io.Threaded` | Cross-compiles |
| macOS aarch64 | `std.Io.Threaded` | Cross-compiles |
| WASM | `std.Io.Threaded` | Cross-compiles |

"Cross-compiles" indicates the target builds in CI but may have limited runtime
testing.
