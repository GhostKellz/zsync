# WASM Features

This document covers the current WASM-facing `zsync` helpers.

## Current State

WASM support is host-bridged. The guest has no native sockets, so networking,
DNS, fetch, WebSocket, TLS-over-TCP, and sleep operations call imports supplied
by the embedding host.

## Production Direction

The production WASM story is host-ABI first:

- `zsync` defines a stable guest ABI for timers, fetch, DNS, UDP, TCP/TLS, and
  WebSocket operations.
- Browser support should be an adapter that implements this ABI with
  `fetch`, `WebSocket`, `setTimeout`, and any available datagram/stream bridge.
- WASI support should be an adapter that maps the ABI to WASI networking once
  the target host exposes the required capabilities.
- Native embedders can implement the same ABI with their own event loop or
  socket stack for tests, plugins, and server-side sandboxing.

This keeps the guest API portable without pretending that sandboxed WebAssembly
has direct sockets. If an adapter is missing, zsync returns explicit
unsupported-host errors instead of silently falling back to fake behavior.

Areas present in-tree include:

- microtask queue helpers
- promise/event-emitter style APIs
- synchronous host-bridged fetch
- host-bridged UDP, TCP/TLS, DNS, and WebSocket APIs

## Host ABI

The required `env` imports are documented in [wasm-host-abi.md](wasm-host-abi.md).

## Release Position

The WASM surface is supported only when the embedding host implements the ABI
documented above. Browser and WASI hosts that do not supply those imports should
expect the WASM networking helpers to return unsupported-host errors.
