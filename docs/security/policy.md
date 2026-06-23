# Security Policy

Security-sensitive reports should use the root [SECURITY.md](../../SECURITY.md)
process. Do not open public issues for vulnerabilities.

## Runtime Security Scope

zsync is an async runtime helper library. Security-sensitive areas include:

- task cancellation or nursery bugs that leak work past expected lifetime
- HTTP, TLS, DNS, or WebSocket parsing bugs
- certificate verification or TLS downgrade behavior
- WASM host ABI memory ownership mistakes
- process or signal helper behavior that can expose unintended data
- denial-of-service risks from unbounded queues, response bodies, or task growth

## Current Security Posture

| Area | Policy |
|---|---|
| TLS | Native HTTPS uses Zig std TLS with certificate and host verification by default |
| Custom CAs | PEM CA bundle files are supported for private/internal trust roots |
| Downgrade behavior | zsync must not silently downgrade HTTPS/TLS to plaintext |
| WASM TLS | TLS is terminated by the host adapter; the guest ABI declares intent |
| HTTP bodies | HTTP response reads enforce header and body limits |
| WebSocket | RFC 6455 validation rejects invalid masking, opcodes, control frames, UTF-8, and fragmented ordering |
| Experimental APIs | Experimental modules are outside stable guarantees and should be isolated in production consumers |

## Dependency And Toolchain Auditing

zsync has no package-manager dependency graph comparable to Cargo or npm, but
release checks should still include:

- `zig build test --summary all`
- `zig build examples --summary all`
- `zig build release --summary all`
- review of Zig toolchain changes affecting `std.Io`, `std.Io.net`, and
  `std.crypto.tls`

## Production Hardening Checklist

- [ ] Use the latest zsync release or current `main` for security fixes.
- [ ] Keep Zig `0.17.0-dev` or later aligned with the tested toolchain.
- [ ] Use native TLS verification for HTTPS clients unless a test explicitly
      disables verification.
- [ ] Avoid relying on experimental modules for critical production paths.
- [ ] Bound queues, response bodies, and task fan-out in application code.
- [ ] Treat WASM host imports as a trust boundary and validate every pointer,
      length, handle, and return code.

## Related Docs

- [TLS Backend](../guides/tls-backend.md)
- [WASM Host ABI](../platforms/wasm-host-abi.md)
- [Tokio Primitives](../reference/tokio-primitives.md)
- [Experimental Features](../roadmap/experimental-features.md)
