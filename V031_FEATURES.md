# zsync v0.3.1 - High-Performance Features

## Overview
zsync v0.3.1 introduces three major performance features that significantly enhance async I/O capabilities:

- **Zero-Copy Operations** - Eliminate memory copies for high-throughput I/O
- **Hardware Acceleration** - CPU-optimized operations with SIMD support  
- **Real-time Streams** - Low-latency streaming with backpressure control

## Features

### 1. Zero-Copy Operations (`zero_copy.zig`)

**BufferPool** - Memory-efficient buffer management:
```zig
var pool = try zero_copy.BufferPool.init(allocator);
defer pool.deinit();

const buffer = try pool.acquire(64 * 1024); // 64KB aligned buffer
defer pool.release(buffer);
```

**ZeroCopyIo** - High-performance I/O operations:
```zig
const zero_copy_io = zero_copy.ZeroCopyIo.init(&pool);
const data = try zero_copy_io.readZeroCopy(io, handle, size);
try zero_copy_io.writeZeroCopy(io, handle, data);
```

**ZeroCopyRingBuffer** - Lock-free circular buffer:
```zig
var ring = try zero_copy.ZeroCopyRingBuffer.init(allocator, 4096);
defer ring.deinit(allocator);

// Producer
const write_slice = try ring.writeableSlice();
// ... write data ...
ring.commitWrite(bytes_written);

// Consumer  
const read_slice = try ring.readableSlice();
// ... read data ...
ring.commitRead(bytes_read);
```

### 2. Hardware Acceleration (`hardware_accel.zig`)

**CPU Feature Detection**:
```zig
const hw = hardware_accel.HardwareAccel.init();
const features = hw.features;
// Check: sse2, avx, avx2, neon, etc.
```

**Optimized Operations**:
```zig
// Hardware-accelerated copy
try hw.optimizedCopy(io, dst, src);

// SIMD-optimized comparison
const equal = try hw.optimizedCompare(io, data1, data2);

// Vectorized XOR
try hw.optimizedXor(io, dst, src, key);
```

**Async Hardware Operations**:
```zig
var async_hw = hardware_accel.AsyncHardwareOps.init(io);
try async_hw.asyncCopy(dst, src);
try async_hw.parallelProcess(u32, items, processFunction);
```

### 3. Real-time Streams (`realtime_streams.zig`)

**Stream Builder Pattern**:
```zig
var stream = try realtime_streams.StreamBuilder.init(allocator)
    .withBufferSize(64 * 1024)
    .withBackpressure(.drop_oldest)
    .withRateLimit(100_000)
    .withRealTimePriority()
    .build();
defer stream.deinit();
```

**Message Publishing**:
```zig
var message = try realtime_streams.StreamMessage.init(allocator, "data");
message.priority = .high;
message.deadline = std.time.microTimestamp() + 1000; // 1ms deadline
defer message.deinit();

try stream.send(io, message);
```

**Subscription with Filtering**:
```zig
const sub_id = try stream.subscribe(
    handleMessage,        // Callback function
    0xFF,                // All priority levels  
    1000,                // Max queue size
    messageFilter        // Optional filter function
);
defer stream.unsubscribe(sub_id);
```

**Predefined Stream Types**:
```zig
// High-throughput: optimized for maximum bandwidth
var ht_stream = try realtime_streams.createHighThroughputStream(allocator);

// Low-latency: optimized for minimal delay
var ll_stream = try realtime_streams.createLowLatencyStream(allocator);

// Reliable: guaranteed delivery with blocking backpressure
var rel_stream = try realtime_streams.createReliableStream(allocator);
```

## Performance Features

### Backpressure Strategies
- `block` - Block sender until buffer space available
- `drop_oldest` - Remove oldest messages when buffer full
- `drop_newest` - Reject new messages when buffer full  
- `error_on_full` - Return error when buffer full

### Hardware Optimizations
- **x86_64**: SSE2, AVX, AVX2 vectorization
- **AArch64**: NEON SIMD operations
- **Cache-aware**: Prefetching and cache line optimization
- **Platform-specific**: sendfile(), splice(), mmap() zero-copy

### Real-time Capabilities
- Priority-based message processing
- Deadline-aware message handling
- Rate limiting with token bucket
- Sub-millisecond latency targeting
- Real-time thread scheduling (Linux)

## Integration

All features integrate seamlessly with existing zsync APIs:

```zig
const zsync = @import("zsync");

// Available as top-level exports
const pool = try zsync.BufferPool.init(allocator);
const hw = zsync.HardwareAccel.init();
const stream = try zsync.StreamBuilder.init(allocator).build();
```

## Testing

Run the comprehensive test suite:
```bash
zig test tests/test_v031_features.zig
```

Try the demo:
```bash
zig run examples/v031_features_demo.zig
```

## Compatibility

- **Zig Version**: 0.15.0+
- **Platforms**: Linux, macOS, Windows, WASM
- **Architectures**: x86_64, AArch64
- **Dependencies**: None (pure Zig implementation)

---

These features maintain zsync's core philosophy of "colorblind async" - the same high-performance code works across blocking, thread pool, green threads, and future stackless execution models.