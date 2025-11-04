# Zsync v0.7.0 Performance Guide

Optimize your zsync applications for maximum performance.

## Table of Contents

- [Execution Model Selection](#execution-model-selection)
- [Buffer Pool Optimization](#buffer-pool-optimization)
- [Task Granularity](#task-granularity)
- [Channel Performance](#channel-performance)
- [Zero-Copy I/O](#zero-copy-io)
- [Memory Management](#memory-management)
- [Platform-Specific Tuning](#platform-specific-tuning)
- [Benchmarking](#benchmarking)

---

## Execution Model Selection

### Quick Reference

| Workload Type | Best Model | Reason |
|---------------|------------|--------|
| I/O-bound (Linux 5.1+) | `green_threads` | io_uring, minimal overhead |
| I/O-bound (other) | `thread_pool` | Parallelism, non-blocking |
| CPU-bound | `thread_pool` | True parallelism across cores |
| Mixed | `.auto` | Platform detection |
| Simple/Testing | `blocking` | Zero overhead |

### Detailed Comparison

#### Green Threads (Linux 5.1+)
**Best for:** Web servers, databases, high-concurrency I/O

**Pros:**
- Minimal memory per task (~4KB stack)
- Zero-copy io_uring operations
- 100K+ concurrent tasks possible
- Low context-switch overhead

**Cons:**
- Linux-only
- Not ideal for CPU-bound work

**Configuration:**
```zig
const config = zsync.Config{
    .execution_model = .green_threads,
    .queue_depth = 256, // io_uring queue size
    .green_thread_stack_size = 65536, // 64KB
    .max_green_threads = 10000,
};
```

#### Thread Pool
**Best for:** CPU-bound work, cross-platform I/O

**Pros:**
- True parallelism
- Cross-platform
- Good for CPU-intensive tasks

**Cons:**
- Higher memory per worker (~2MB)
- Limited scalability (typically 4-32 workers)

**Configuration:**
```zig
const config = zsync.Config{
    .execution_model = .thread_pool,
    .num_workers = 4, // Match CPU cores for CPU-bound
};
```

**Worker Count Guidelines:**
- CPU-bound: `num_workers = CPU cores`
- I/O-bound: `num_workers = CPU cores * 2-4`
- Mixed: Start with `CPU cores * 2`, benchmark

---

## Buffer Pool Optimization

### Sizing Strategy

```zig
const pool = try zsync.BufferPool.init(allocator, .{
    .initial_capacity = 32,      // Pre-allocate
    .buffer_size = 16384,        // 16KB typical
    .max_cached = 128,           // Cap total buffers
    .enable_zero_copy = true,    // Use sendfile/splice
});
```

### Buffer Size Selection

| Use Case | Recommended Size |
|----------|------------------|
| Network packets | 4KB - 8KB |
| File I/O | 16KB - 64KB |
| Large transfers | 1MB - 4MB |
| Memory constrained | 4KB |

### Pool Capacity Tuning

**Formula:**
```
max_cached = concurrent_operations * avg_buffers_per_operation * 1.5
```

**Example:** 100 concurrent HTTP connections, 2 buffers each:
```zig
.max_cached = 100 * 2 * 1.5 = 300
```

### Monitoring

```zig
const stats = pool.stats();
std.debug.print("Pool utilization: {d}%\n", .{
    (stats.total_in_use * 100) / stats.total_allocated
});

// If utilization > 90%, increase max_cached
// If utilization < 30%, decrease max_cached
```

---

## Task Granularity

### Rule of Thumb

**Minimum task duration:** 10-100μs

Tasks shorter than this should be batched.

### Bad: Too Fine-Grained

```zig
// DON'T: Spawn task for each item (overhead dominates)
for (items) |item| {
    try nursery.spawn(processItem, .{item});
}
```

### Good: Batched Processing

```zig
// DO: Process chunks in parallel
const chunk_size = 1000;
var i: usize = 0;
while (i < items.len) : (i += chunk_size) {
    const end = @min(i + chunk_size, items.len);
    const chunk = items[i..end];
    try nursery.spawn(processChunk, .{chunk});
}
```

### Optimal Chunk Size

```
chunk_size = total_items / (num_workers * 4)
```

This creates 4x work items per worker for load balancing.

---

## Channel Performance

### Bounded vs Unbounded

**Bounded** (recommended for most cases):
```zig
var ch = try zsync.channels.bounded(T, allocator, capacity);
```

**Pros:**
- Fixed memory usage
- Backpressure prevents overflow
- Better cache locality

**Unbounded:**
```zig
var ch = try zsync.channels.unbounded(T, allocator);
```

**Use when:**
- Producer rate highly variable
- Cannot afford to block producer
- Memory not constrained

### Capacity Sizing

**Formula:**
```
capacity = avg_production_rate * max_consumer_latency
```

**Example:** 1000 items/sec, max latency 100ms:
```
capacity = 1000 * 0.1 = 100
```

### Performance Tips

1. **Batch sends when possible**
```zig
// Better: Send batch
for (items) |item| {
    _ = try ch.trySend(item) or break; // Non-blocking
}
```

2. **Use tryRecv() for non-blocking**
```zig
while (ch.tryRecv()) |item| {
    process(item);
}
```

3. **Close channels when done**
```zig
defer ch.close(); // Signals consumers
```

---

## Zero-Copy I/O

### sendfile() Performance

**10x faster than read/write loop** for large files.

```zig
// Traditional (slow)
while (true) {
    const bytes = try source.read(buffer);
    if (bytes == 0) break;
    try dest.writeAll(buffer[0..bytes]);
}

// Zero-copy (fast)
const bytes = try zsync.sendfile(dest.handle, source.handle, null, size);
```

### When to Use

| Operation | Use Zero-Copy? |
|-----------|----------------|
| File-to-file copy | ✅ Yes |
| File-to-socket | ✅ Yes (sendfile) |
| Socket-to-file | ✅ Yes (splice on Linux) |
| File-to-memory (processing) | ❌ No (need buffer access) |

### Platform Support

- **Linux:** sendfile() + splice()
- **macOS/FreeBSD:** BSD sendfile()
- **Windows:** TransmitFile() (planned)

---

## Memory Management

### Allocation Patterns

**Bad:**
```zig
// Allocates on every task
fn task() !void {
    const data = try allocator.alloc(u8, 1024);
    defer allocator.free(data);
    // ...
}
```

**Good:**
```zig
// Use buffer pool
fn task(pool: *zsync.BufferPool) !void {
    const buffer = try pool.acquire();
    defer buffer.release();
    // ...
}
```

### Arena Allocator for Tasks

```zig
fn task() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // All allocations freed at once
    const data1 = try allocator.alloc(u8, 1024);
    const data2 = try allocator.alloc(u8, 2048);
}
```

---

## Platform-Specific Tuning

### Linux (io_uring)

**Optimal Configuration:**
```zig
const config = zsync.Config{
    .execution_model = .green_threads,
    .queue_depth = 256,  // Start here
    .max_green_threads = 10000,
};
```

**Queue Depth Tuning:**
- Small (64): Low latency, fewer concurrent ops
- Medium (256): Balanced (recommended)
- Large (1024): High throughput, more memory

**Kernel Version Impact:**
- 5.1-5.4: Basic io_uring
- 5.5-5.10: Improved performance
- 5.11+: Best performance, more features

### macOS

```zig
const config = zsync.Config{
    .execution_model = .thread_pool,
    .num_workers = 4, // Match cores
};
```

**Tips:**
- Use sendfile() for file transfers
- Thread pool performs well on M-series chips
- Disable debugging in release builds

### Windows (Future)

Planned IOCP integration for optimal performance.

---

## Benchmarking

### Measuring Throughput

```zig
const start = std.time.Instant.now() catch unreachable;

// Do work
for (0..iterations) |_| {
    try doWork();
}

const end = std.time.Instant.now() catch unreachable;
const elapsed_ns = end.since(start);
const throughput = (iterations * 1_000_000_000) / elapsed_ns;

std.debug.print("Throughput: {d} ops/sec\n", .{throughput});
```

### Measuring Latency

```zig
var latencies = std.ArrayList(u64).init(allocator);
defer latencies.deinit();

for (0..iterations) |_| {
    const start = std.time.Instant.now() catch unreachable;
    try doWork();
    const end = std.time.Instant.now() catch unreachable;

    try latencies.append(end.since(start));
}

// Calculate percentiles
std.sort.pdq(u64, latencies.items, {}, std.sort.asc(u64));
const p50 = latencies.items[latencies.items.len / 2];
const p95 = latencies.items[(latencies.items.len * 95) / 100];
const p99 = latencies.items[(latencies.items.len * 99) / 100];

std.debug.print("p50: {d}ns, p95: {d}ns, p99: {d}ns\n", .{p50, p95, p99});
```

---

## Performance Checklist

- [ ] Using `.auto` or appropriate execution model
- [ ] Worker count tuned for workload
- [ ] Buffer pool configured and used
- [ ] Tasks have reasonable granularity (>10μs)
- [ ] Channels sized appropriately
- [ ] Zero-copy I/O where applicable
- [ ] Nurseries for structured concurrency
- [ ] Buffers released promptly
- [ ] Profiled with real workload
- [ ] Tested on target platform

---

## Common Performance Issues

### Issue: High Memory Usage

**Cause:** Too many cached buffers or workers

**Solution:**
```zig
// Reduce buffer pool
.max_cached = 64, // Down from 256

// Reduce workers
.num_workers = 2, // Down from 8
```

### Issue: Low Throughput

**Cause:** Blocking operations, poor task granularity

**Solution:**
- Use async I/O (green_threads on Linux)
- Batch small tasks
- Increase worker count for CPU-bound

### Issue: High Latency (p99)

**Cause:** Task contention, lock contention

**Solution:**
- Reduce worker count
- Use lock-free data structures (channels)
- Profile to find bottlenecks

---

## Profiling Tools

### Linux
```bash
# CPU profiling
perf record -g ./your_app
perf report

# Memory profiling
valgrind --tool=massif ./your_app
ms_print massif.out.*
```

### macOS
```bash
# Instruments (GUI)
instruments -t "Time Profiler" ./your_app

# dtrace
sudo dtrace -n 'pid$target:::entry { @[ustack()] = count(); }' -p <pid>
```

---

For more information:
- [Getting Started](GETTING_STARTED.md)
- [API Reference](API_REFERENCE.md)
- [Examples](EXAMPLES.md)
