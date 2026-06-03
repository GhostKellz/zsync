# Future Roadmap

This document outlines planned improvements for zsync. Since the `std.Io`
rebase, platform I/O backends (io_uring, IOCP, kqueue) are owned by the Zig
standard library — zsync's roadmap focuses on the structured-concurrency layer
it provides on top of `std.Io`.

## Primitives & Ergonomics

- Promote future combinators (`race`, `all`, `timeout`) from experimental to a
  stable, well-tested surface once `std.Io` cancellation semantics settle.
- Broaden nursery / `JoinSet` ergonomics for scoped task lifetimes.
- Continue parity work on Tokio-style primitives (broadcast/watch channels,
  sync types). See [tokio-primitives.md](tokio-primitives.md).

## Networking

- Stabilize the `net/` helpers (WebSocket, connection pooling, rate limiting) as
  `std.Io.net` matures.
- Expand integration test coverage for the HTTP/WebSocket examples.

## Tracking `std.Io`

- Track upstream `std.Io` / `std.Io.Threaded` changes and keep the re-exported
  surface (`zsync.Io`) aligned as the standard library evolves.
- Remove compat shims (`compat/thread.zig`) once the corresponding std APIs
  stabilize.

## Documentation & Testing

- Keep examples and docs verified against the current public surface.
- Expand cross-platform runtime testing beyond cross-compilation.

Priorities are subject to change based on upstream `std.Io` progress and
community feedback.
