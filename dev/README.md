# zsync Development Tools

Local CI and testing infrastructure for zsync development.

## Quick Start

```bash
# Run full CI suite
./dev/ci.sh

# Check Zig 0.16 compatibility
./dev/check-zig-compat.sh

# Memory leak detection
./dev/memcheck.sh
```

## Scripts

| Script | Purpose |
|--------|---------|
| `ci.sh` | Full CI suite: build, test, lint, compatibility |
| `check-zig-compat.sh` | Scan for deprecated Zig 0.16 APIs |
| `memcheck.sh` | Memory leak detection (GPA + valgrind) |

## Zig 0.16.0-dev Compatibility

Key API changes to watch for:

### ArrayList
```zig
// OLD (deprecated)
var list = ArrayList(T).init(allocator);
list.append(item);
list.deinit();

// NEW (0.16)
var list: ArrayList(T) = .{};
list.append(allocator, item);
list.deinit(allocator);
```

### Time APIs
```zig
// OLD (deprecated)
const ts = std.time.milliTimestamp();

// NEW (0.16)
const now = std.time.Instant.now() catch unreachable;
const elapsed = now.since(start);
```

### Async/Await
Zig 0.16 removed language-level async. Use zsync runtime instead:
```zig
// Use zsync's async primitives
const runtime = try zsync.Runtime.init(allocator, .{});
try runtime.spawn(myAsyncFn, .{args});
```

## Memory Safety

zsync uses Zig's `GeneralPurposeAllocator` in debug builds which automatically detects:
- Memory leaks
- Double frees
- Use after free
- Buffer overflows

All tests run with GPA enabled by default.
