# Security Checklist

Tracked security improvements for zsync. Items are prioritized by severity and likelihood of exploitation.

## Completed (v0.7.8)

- [x] WebSocket `ensureBytes` integer underflow - `net/websocket.zig:369`
- [x] WebSocket payload read underflow - `net/websocket.zig:336`
- [x] DNS hostname length validation (253 char limit) - `dns_async.zig:255`
- [x] DNS cache memory leak on error path - `dns_async.zig:208`
- [x] io_uring buffer length truncation (u64->u32) - `io_uring.zig:29,41,517,536`

## TODO: High Priority

### Pointer Validation in Async Contexts
**Files:** `concurrent_future_real.zig:70`, `io_interface.zig:413+`, `streams.zig`

The pattern `@ptrCast(@alignCast(arg))` on `*anyopaque` from context switches has no validation. Consider:
- Adding magic number validation in debug builds
- Wrapping context pointers in a tagged struct
- Runtime checks that pointer is within expected heap regions

### Stack Bounds in Context Switching
**Files:** `arch/x86_64.zig:26,66,86-88`, `arch/aarch64.zig:124-130`

Stack pointer arithmetic doesn't validate bounds. Add:
- Debug assertions that `rsp` stays within allocated stack region
- Guard pages at stack boundaries (if not already present)
- Stack canaries in debug builds

### DNS Response Parsing Bounds
**Files:** `dns_async.zig:394-412`

When parsing DNS responses, label lengths from untrusted data aren't fully validated:
- Verify `offset + data_len` doesn't exceed buffer before slicing
- Add maximum recursion depth for compressed labels
- Validate total parsed length matches packet length

## TODO: Medium Priority

### Race Condition in DNS Cache
**File:** `dns_async.zig:201-231`

TOCTOU between `cache.count()` check and `cache.put()`. Options:
- Use a single atomic check-and-insert operation
- Accept slightly exceeding max_cache_entries (benign)
- Add mutex around entire cache operation sequence

### Completion Array Bounds
**File:** `concurrent_future_real.zig:86-87`

`completion_order[completion_index]` write could exceed array if `completion_count` races past `n`. Add bounds check or use saturating add.

### io_uring Kernel Offset Validation
**Files:** `platform/linux.zig:86-102`, `io_uring.zig:393-413`

Offsets from `io_uring_setup` are used for pointer arithmetic without validation. While these come from the kernel (trusted), defensive checks would help:
- Verify offsets don't exceed mapped region size
- Add assertions in debug builds

## TODO: Low Priority

### File Descriptor Validation
**File:** `buffer_pool.zig:206`

`splice()` called without validating fd is valid. Add `fd >= 0` check.

### PTY File Descriptor Type Check
**File:** `terminal/pty.zig:82,174`

ioctl with `TIOCSWINSZ` assumes fd is a PTY. Consider validating with `isatty()` first.

### Generic TLS Lifetime Safety
**File:** `thread_local_storage.zig:36,43`

`setTyped` accepts any pointer type without lifetime validation. Document that callers must ensure pointer outlives TLS usage, or consider requiring heap-allocated values.

## Testing Recommendations

1. **Fuzz testing** - Add AFL/libFuzzer harnesses for:
   - WebSocket frame parsing
   - DNS response parsing
   - Any network protocol handlers

2. **Sanitizers** - CI should run with:
   - AddressSanitizer (memory errors)
   - UndefinedBehaviorSanitizer (UB detection)
   - ThreadSanitizer (race conditions)

3. **Static analysis** - Consider integrating:
   - Zig's built-in safety checks (keep enabled in tests)
   - Custom comptime validation for pointer casts
