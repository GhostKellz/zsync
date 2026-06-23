# TLS Backend

## Decision

Native zsync TLS will use Zig std's `std.crypto.tls.Client`.

WASM TLS remains host-terminated through the documented host ABI. The guest asks
for TLS by passing `tls = 1` to `zsync_tcp_connect`; certificate verification and
socket policy belong to the adapter host.

## Native Integration

`std.crypto.tls.Client` is the right native backend because it keeps zsync inside
Zig's standard-library runtime model and avoids binding zsync to OpenSSL,
BoringSSL, mbedTLS, or platform-specific TLS APIs.

`TlsStream` now adapts `std.Io.net.Stream` into the reader/writer interfaces
required by `std.crypto.tls.Client`:

- wraps `std.Io.net.Stream` as a `std.Io.Reader` and `std.Io.Writer`
- allocate TLS input/output buffers of at least
  `std.crypto.tls.Client.min_buffer_len`
- initializes `std.crypto.tls.Client` with explicit host verification by default
- supports system roots, custom PEM CA bundle files, self-signed verification,
  and explicit verification disablement for test-only callers
- maps TLS read/write/end operations onto `TlsStream.read`, `writeAll`, and
  `close`
- lets `HttpClient.request` use the TLS stream for `https://` URIs without
  downgrading to plaintext

The current native backend intentionally returns `error.TlsUnsupported` for
client certificates, client private keys, and custom cipher-suite selection.
Those are backend policy/configuration features, not transport fallback paths.

## Verification Modes

`TlsConfig.verification` controls certificate verification:

| Mode | Behavior |
|---|---|
| `system_roots` | Load the platform CA roots and verify the server host |
| `custom_ca_bundle` | Load `ca_bundle_path` as a PEM root bundle and verify the server host |
| `self_signed` | Accept a valid self-signed server certificate for the verified host |
| `disabled` | Disable certificate and host verification |

For compatibility, `verify_certificates = false` maps to `disabled`, and setting
`ca_bundle_path` while leaving `verification = .system_roots` maps to
`custom_ca_bundle`.

## Policy

zsync must never silently downgrade HTTPS/TLS to plaintext. If the selected TLS
backend is unavailable or incomplete, APIs must return a hard error.
