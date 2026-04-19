# WASM Features

This document covers the current WASM-facing `zsync` helpers.

## Current State

WASM support in `zsync` is still partial and should be treated as experimental.

Areas present in-tree include:

- microtask queue helpers
- browser-oriented async helpers
- promise/event-emitter style APIs

## Release Position

These helpers are not part of the supported `v0.8.0` surface.

Use them only if you are comfortable with experimental APIs and partial implementations.
