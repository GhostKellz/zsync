# WASM Host ABI

`zsync` WASM networking delegates socket, DNS, HTTP, WebSocket, and sleep work
to the embedding host through synchronous `env` imports. The guest owns memory
for pointer/length arguments. The host must copy data it needs after returning.

Negative `i32` return values are errors unless a function documents a different
meaning. Non-negative handles are host-owned resources and must remain valid
until the matching close/free import is called.

## Adapter Contract

`zsync` treats this ABI as the stable production boundary for WASM. The guest
does not assume a browser, WASI, or native host. Instead, hosts implement these
imports using the capabilities they actually have:

- browser adapters: `fetch`, `WebSocket`, timers, and optional stream/datagram
  bridges
- WASI adapters: WASI networking and clocks when available
- native adapters: host sockets/event loops for plugins, tests, and sandboxes

Hosts should return a negative error code when an operation is unavailable.
Guest code maps that to explicit zsync errors; it must not infer networking
support from the target triple alone.

## Async

```zig
extern "env" fn zsync_sleep_ms(ms: u64) void;
```

`zsync_sleep_ms` blocks or schedules the host sleep for `ms` milliseconds before
returning to the guest.

## Fetch

Used by `wasm/async.zig` and `wasm/net.zig`.

```zig
extern "env" fn zsync_fetch(
    method_ptr: [*]const u8,
    method_len: usize,
    url_ptr: [*]const u8,
    url_len: usize,
    body_ptr: ?[*]const u8,
    body_len: usize,
    status_out: *u16,
    len_out: *usize,
) i32;

extern "env" fn zsync_fetch_read(handle: i32, dest: [*]u8, len: usize) void;
extern "env" fn zsync_fetch_free(handle: i32) void;
```

`zsync_fetch` returns a non-negative response handle, writes the HTTP status to
`status_out`, and writes the response body length to `len_out`. The guest then
allocates `len_out` bytes, calls `zsync_fetch_read`, and finally calls
`zsync_fetch_free`.

## UDP

```zig
extern "env" fn zsync_udp_bind(ip_ptr: [*]const u8, ip_len: usize, port: u16) i32;
extern "env" fn zsync_udp_send(handle: i32, data_ptr: [*]const u8, data_len: usize, ip_ptr: [*]const u8, ip_len: usize, port: u16) i32;
extern "env" fn zsync_udp_recv(handle: i32, buf_ptr: [*]u8, buf_len: usize, ip_out: [*]u8, ip_out_len: usize, ip_len_out: *usize, port_out: *u16) i32;
extern "env" fn zsync_udp_close(handle: i32) void;
```

IP addresses are serialized as raw IPv4/IPv6 bytes. `zsync_udp_recv` returns the
number of bytes written to `buf_ptr`, writes the source IP bytes to `ip_out`,
writes the source IP byte count to `ip_len_out`, and writes the source port to
`port_out`.

## DNS

```zig
extern "env" fn zsync_dns_resolve(host_ptr: [*]const u8, host_len: usize, out_ptr: [*]u8, out_len: usize, count_out: *usize) i32;
```

The host writes packed IP address records to `out_ptr` and writes the number of
records to `count_out`.

## TCP/TLS

```zig
extern "env" fn zsync_tcp_connect(host_ptr: [*]const u8, host_len: usize, port: u16, tls: i32) i32;
extern "env" fn zsync_tcp_send(handle: i32, data_ptr: [*]const u8, data_len: usize) i32;
extern "env" fn zsync_tcp_recv(handle: i32, buf_ptr: [*]u8, buf_len: usize) i32;
extern "env" fn zsync_tcp_close(handle: i32) void;
```

`tls != 0` requests that the host establish a TLS-protected connection. The host
is responsible for certificate policy.

## WebSocket

```zig
extern "env" fn zsync_ws_open(url_ptr: [*]const u8, url_len: usize) i32;
extern "env" fn zsync_ws_send(handle: i32, data_ptr: [*]const u8, data_len: usize, is_binary: i32) i32;
extern "env" fn zsync_ws_recv(handle: i32, buf_ptr: [*]u8, buf_len: usize) i32;
extern "env" fn zsync_ws_close(handle: i32) void;
```

`zsync_ws_recv` returns the number of payload bytes copied into `buf_ptr`.
`is_binary != 0` sends a binary message; otherwise the payload is sent as text.
