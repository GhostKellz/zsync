const std = @import("std");
const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;

const zsync = @import("../src/root.zig");
const zero_copy = @import("../src/zero_copy.zig");
const hardware_accel = @import("../src/hardware_accel.zig");
const realtime_streams = @import("../src/realtime_streams.zig");

// Mock Io for testing
const MockIo = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) MockIo {
        return .{ .allocator = allocator };
    }
    
    pub fn read(self: MockIo, handle: anytype, buffer: []u8) !usize {
        _ = self;
        _ = handle;
        // Mock read - fill with test data
        for (buffer, 0..) |*byte, i| {
            byte.* = @as(u8, @intCast(i % 256));
        }
        return buffer.len;
    }
    
    pub fn write(self: MockIo, handle: anytype, data: []const u8) !usize {
        _ = self;
        _ = handle;
        return data.len;
    }
    
    pub fn sendfile(self: MockIo, out_fd: anytype, in_fd: anytype, offset: anytype, count: usize) !usize {
        _ = self;
        _ = out_fd;
        _ = in_fd;
        _ = offset;
        return count;
    }
    
    pub fn splice(self: MockIo, in_fd: anytype, in_off: anytype, out_fd: anytype, out_off: anytype, count: usize, flags: u32) !usize {
        _ = self;
        _ = in_fd;
        _ = in_off;
        _ = out_fd;
        _ = out_off;
        _ = flags;
        return count;
    }
    
    pub fn mmap(self: MockIo, addr: anytype, length: usize, prot: anytype, flags: anytype, fd: anytype, offset: u64) !*anyopaque {
        _ = addr;
        _ = prot;
        _ = flags;
        _ = fd;
        _ = offset;
        const ptr = try self.allocator.alignedAlloc(u8, std.mem.page_size, length);
        return @ptrCast(ptr.ptr);
    }
    
    pub fn munmap(self: MockIo, addr: *anyopaque, length: usize) !void {
        _ = length;
        const ptr: [*]align(std.mem.page_size) u8 = @ptrCast(@alignCast(addr));
        self.allocator.free(ptr[0..length]);
    }
    
    pub fn lseek(self: MockIo, fd: anytype, offset: i64, whence: anytype) !void {
        _ = self;
        _ = fd;
        _ = offset;
        _ = whence;
    }
    
    pub fn async(self: MockIo, comptime func: anytype, args: anytype) MockFuture(@TypeOf(func), @TypeOf(args)) {
        return MockFuture(@TypeOf(func), @TypeOf(args)){
            .io = self,
            .func = func,
            .args = args,
            .completed = false,
        };
    }
};

fn MockFuture(comptime FuncType: type, comptime ArgsType: type) type {
    return struct {
        io: MockIo,
        func: FuncType,
        args: ArgsType,
        completed: bool,
        
        const Self = @This();
        
        pub fn await(self: *Self, io: anytype) !@typeInfo(@TypeOf(self.func)).Fn.return_type.? {
            _ = io;
            self.completed = true;
            return @call(.auto, self.func, self.args);
        }
        
        pub fn cancel(self: *Self, io: anytype) !void {
            _ = self;
            _ = io;
        }
    };
}

// Zero-Copy Tests
test "BufferPool acquire and release" {
    var pool = try zero_copy.BufferPool.init(testing.allocator);
    defer pool.deinit();
    
    const buffer1 = try pool.acquire(4096);
    try expect(buffer1.len == 4096);
    try expect(@intFromPtr(buffer1.ptr) % std.mem.page_size == 0);
    
    const buffer2 = try pool.acquire(8192);
    try expect(buffer2.len == 8192);
    
    pool.release(buffer1);
    pool.release(buffer2);
    
    // Should reuse released buffer
    const buffer3 = try pool.acquire(4096);
    try expect(buffer3.ptr == buffer1.ptr);
    
    pool.release(buffer3);
}

test "BufferPool pin and unpin" {
    var pool = try zero_copy.BufferPool.init(testing.allocator);
    defer pool.deinit();
    
    const buffer = try pool.acquire(4096);
    try pool.pin(buffer);
    
    pool.release(buffer); // Should not actually release due to pin
    try pool.pin(buffer); // Should still work
    
    pool.unpin(buffer);
    pool.unpin(buffer); // Should actually release now
}

test "ZeroCopyIo read and write" {
    var pool = try zero_copy.BufferPool.init(testing.allocator);
    defer pool.deinit();
    
    const zero_copy_io = zero_copy.ZeroCopyIo.init(&pool);
    const mock_io = MockIo.init(testing.allocator);
    
    const buffer = try zero_copy_io.readZeroCopy(mock_io, 0, 4096);
    defer pool.release(buffer);
    
    try expect(buffer.len == 4096);
    
    // Verify mock data pattern
    for (buffer, 0..) |byte, i| {
        try expectEqual(@as(u8, @intCast(i % 256)), byte);
    }
    
    const written = try zero_copy_io.writeZeroCopy(mock_io, 1, buffer);
    try expectEqual(@as(usize, 4096), written);
}

test "ZeroCopyRingBuffer operations" {
    var ring = try zero_copy.ZeroCopyRingBuffer.init(testing.allocator, 1024);
    defer ring.deinit(testing.allocator);
    
    // Test write
    const write_slice = try ring.writeableSlice();
    try expect(write_slice.len > 0);
    
    const test_data = "Hello, World!";
    @memcpy(write_slice.ptr[0..test_data.len], test_data);
    ring.commitWrite(test_data.len);
    
    // Test read
    const read_slice = try ring.readableSlice();
    try expect(read_slice.len >= test_data.len);
    
    const read_data = read_slice.ptr[0..test_data.len];
    try expect(std.mem.eql(u8, test_data, read_data));
    
    ring.commitRead(test_data.len);
}

// Hardware Acceleration Tests
test "CpuFeatures detection" {
    const features = hardware_accel.HardwareAccel.detectCapabilities();
    
    // Should detect at least some basic features
    if (std.builtin.cpu.arch == .x86_64) {
        try expect(features.sse2); // SSE2 is baseline for x86_64
        try expect(features.cache_line_size > 0);
    } else if (std.builtin.cpu.arch == .aarch64) {
        try expect(features.neon); // NEON is mandatory on AArch64
        try expect(features.cache_line_size > 0);
    }
}

test "Hardware accelerated copy" {
    const hw = hardware_accel.HardwareAccel.init();
    const mock_io = MockIo.init(testing.allocator);
    
    const src = "The quick brown fox jumps over the lazy dog";
    var dst: [64]u8 = undefined;
    
    try hw.optimizedCopy(mock_io, dst[0..src.len], src);
    try expect(std.mem.eql(u8, src, dst[0..src.len]));
}

test "Hardware accelerated compare" {
    const hw = hardware_accel.HardwareAccel.init();
    const mock_io = MockIo.init(testing.allocator);
    
    const data1 = "identical data";
    const data2 = "identical data";
    const data3 = "different data";
    
    try expect(try hw.optimizedCompare(mock_io, data1, data2));
    try expect(!try hw.optimizedCompare(mock_io, data1, data3));
}

test "Hardware accelerated XOR" {
    const hw = hardware_accel.HardwareAccel.init();
    const mock_io = MockIo.init(testing.allocator);
    
    const src = [_]u8{ 0xAA, 0xBB, 0xCC, 0xDD };
    const key = [_]u8{ 0xFF, 0x00, 0xFF, 0x00 };
    var dst: [4]u8 = undefined;
    
    try hw.optimizedXor(mock_io, &dst, &src, &key);
    
    const expected = [_]u8{ 0x55, 0xBB, 0x33, 0xDD };
    try expect(std.mem.eql(u8, &expected, &dst));
}

test "AsyncHardwareOps parallel processing" {
    var async_hw = hardware_accel.AsyncHardwareOps.init(MockIo.init(testing.allocator));
    
    var items = [_]u32{ 1, 2, 3, 4, 5, 6, 7, 8 };
    
    const ProcessItem = struct {
        fn process(io: anytype, item: *u32) !void {
            _ = io;
            item.* *= 2;
        }
    };
    
    try async_hw.parallelProcess(u32, &items, ProcessItem.process);
    
    const expected = [_]u32{ 2, 4, 6, 8, 10, 12, 14, 16 };
    try expect(std.mem.eql(u32, &expected, &items));
}

// Real-time Streams Tests
test "StreamMessage creation and expiration" {
    var message = try realtime_streams.StreamMessage.init(testing.allocator, "test data");
    defer message.deinit();
    
    try expect(std.mem.eql(u8, "test data", message.data));
    try expect(message.priority == .normal);
    try expect(!message.isExpired());
    
    // Test expiration
    message.deadline = std.time.microTimestamp() - 1000; // 1ms ago
    try expect(message.isExpired());
}

test "StreamStats operations" {
    var stats = realtime_streams.StreamStats{};
    
    _ = stats.messages_sent.fetchAdd(100, .acq_rel);
    _ = stats.bytes_transferred.fetchAdd(1024, .acq_rel);
    _ = stats.messages_dropped.fetchAdd(5, .acq_rel);
    
    const snapshot = stats.getSnapshot();
    try expectEqual(@as(u64, 100), snapshot.messages_sent);
    try expectEqual(@as(u64, 1024), snapshot.bytes_transferred);
    try expectEqual(@as(u64, 5), snapshot.messages_dropped);
    
    try expectEqual(@as(f64, 0.05), snapshot.getDropRate());
}

test "RateLimiter token bucket" {
    var limiter = realtime_streams.RateLimiter.init(100); // 100 tokens per second
    
    // Should be able to acquire initial tokens
    try expect(limiter.tryAcquire(10));
    try expect(limiter.tryAcquire(50));
    
    // Should fail when bucket is empty
    try expect(!limiter.tryAcquire(50)); // Remaining < 50
    
    // Sleep to allow refill (in real test, would need actual time passage)
    std.time.sleep(10_000); // 10ms
    
    // Should be able to acquire again after refill
    try expect(limiter.tryAcquire(1));
}

test "RealtimeStream basic operations" {
    const config = realtime_streams.StreamConfig{
        .buffer_size = 1024,
        .max_buffer_count = 4,
        .backpressure_strategy = .drop_oldest,
        .enable_rate_limiting = false,
    };
    
    var stream = try realtime_streams.RealtimeStream.init(testing.allocator, config);
    defer stream.deinit();
    
    const mock_io = MockIo.init(testing.allocator);
    
    // Test subscription
    const TestCallback = struct {
        var received_count: u32 = 0;
        
        fn callback(message: realtime_streams.StreamMessage) !void {
            _ = message;
            received_count += 1;
        }
    };
    
    const sub_id = try stream.subscribe(
        TestCallback.callback,
        0xFF, // All priorities
        100,  // Max queue size
        null  // No filter
    );
    
    // Test message sending
    var message = try realtime_streams.StreamMessage.init(testing.allocator, "test message");
    defer message.deinit();
    
    try stream.send(mock_io, message);
    
    // Verify subscription exists
    try expect(stream.subscribers.items.len == 1);
    try expect(stream.subscribers.items[0].id == sub_id);
    
    // Test unsubscribe
    stream.unsubscribe(sub_id);
    try expect(stream.subscribers.items.len == 0);
}

test "StreamBuilder configuration" {
    const stream = try realtime_streams.StreamBuilder.init(testing.allocator)
        .withBufferSize(8192)
        .withBackpressure(.block)
        .withRateLimit(1000)
        .withDeadline(500)
        .build();
    defer {
        var s = stream;
        s.deinit();
    }
    
    try expectEqual(@as(usize, 8192), stream.config.buffer_size);
    try expectEqual(realtime_streams.BackpressureStrategy.block, stream.config.backpressure_strategy);
    try expect(stream.config.enable_rate_limiting);
    try expectEqual(@as(u64, 1000), stream.config.max_messages_per_second);
    try expectEqual(@as(u64, 500), stream.config.deadline_microseconds.?);
}

test "High throughput stream configuration" {
    const stream = try realtime_streams.createHighThroughputStream(testing.allocator);
    defer {
        var s = stream;
        s.deinit();
    }
    
    try expectEqual(@as(usize, 64 * 1024), stream.config.buffer_size);
    try expectEqual(realtime_streams.BackpressureStrategy.drop_oldest, stream.config.backpressure_strategy);
    try expect(stream.config.enable_rate_limiting);
    try expectEqual(@as(u64, 100_000), stream.config.max_messages_per_second);
}

test "Low latency stream configuration" {
    const stream = try realtime_streams.createLowLatencyStream(testing.allocator);
    defer {
        var s = stream;
        s.deinit();
    }
    
    try expectEqual(@as(usize, 4 * 1024), stream.config.buffer_size);
    try expectEqual(realtime_streams.BackpressureStrategy.error_on_full, stream.config.backpressure_strategy);
    try expect(stream.config.real_time_priority);
    try expectEqual(@as(u64, 100), stream.config.deadline_microseconds.?);
}

// Integration Tests
test "Zero-copy with hardware acceleration" {
    var pool = try zero_copy.BufferPool.init(testing.allocator);
    defer pool.deinit();
    
    const zero_copy_io = zero_copy.ZeroCopyIo.init(&pool);
    const hw = hardware_accel.HardwareAccel.init();
    const mock_io = MockIo.init(testing.allocator);
    
    // Read data with zero-copy
    const buffer = try zero_copy_io.readZeroCopy(mock_io, 0, 1024);
    defer pool.release(buffer);
    
    // Process with hardware acceleration
    var result: [1024]u8 = undefined;
    try hw.optimizedCopy(mock_io, &result, buffer);
    
    // Verify data integrity
    try expect(std.mem.eql(u8, buffer, &result));
}

test "Real-time stream with zero-copy and hardware acceleration" {
    const config = realtime_streams.StreamConfig{
        .buffer_size = 4096,
        .max_buffer_count = 8,
        .enable_zero_copy = true,
        .enable_hardware_accel = true,
        .backpressure_strategy = .block,
    };
    
    var stream = try realtime_streams.RealtimeStream.init(testing.allocator, config);
    defer stream.deinit();
    
    const mock_io = MockIo.init(testing.allocator);
    
    // Verify configuration
    try expect(stream.config.enable_zero_copy);
    try expect(stream.config.enable_hardware_accel);
    
    // Test that hardware acceleration is initialized
    try expect(stream.hardware_accel.features.cache_line_size > 0);
}

// Performance benchmarks
test "Zero-copy performance" {
    var pool = try zero_copy.BufferPool.init(testing.allocator);
    defer pool.deinit();
    
    const zero_copy_io = zero_copy.ZeroCopyIo.init(&pool);
    const mock_io = MockIo.init(testing.allocator);
    
    const iterations = 1000;
    const buffer_size = 64 * 1024;
    
    const start_time = std.time.microTimestamp();
    
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const buffer = try zero_copy_io.readZeroCopy(mock_io, 0, buffer_size);
        _ = try zero_copy_io.writeZeroCopy(mock_io, 1, buffer);
        pool.release(buffer);
    }
    
    const end_time = std.time.microTimestamp();
    const elapsed = end_time - start_time;
    const ops_per_second = (iterations * 1_000_000) / elapsed;
    
    std.debug.print("Zero-copy ops/sec: {d}\n", .{ops_per_second});
    
    // Should be significantly faster than regular copy
    try expect(ops_per_second > 1000); // At least 1000 ops/sec
}

test "Hardware acceleration performance" {
    const hw = hardware_accel.HardwareAccel.init();
    const mock_io = MockIo.init(testing.allocator);
    
    const data_size = 1024 * 1024; // 1MB
    const src = try testing.allocator.alloc(u8, data_size);
    defer testing.allocator.free(src);
    const dst = try testing.allocator.alloc(u8, data_size);
    defer testing.allocator.free(dst);
    
    // Fill with test data
    for (src, 0..) |*byte, i| {
        byte.* = @as(u8, @intCast(i % 256));
    }
    
    const iterations = 100;
    const start_time = std.time.microTimestamp();
    
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        try hw.optimizedCopy(mock_io, dst, src);
    }
    
    const end_time = std.time.microTimestamp();
    const elapsed = end_time - start_time;
    const bytes_per_second = (data_size * iterations * 1_000_000) / elapsed;
    const mbps = bytes_per_second / (1024 * 1024);
    
    std.debug.print("Hardware accel throughput: {d} MB/s\n", .{mbps});
    
    // Should achieve reasonable throughput
    try expect(mbps > 100); // At least 100 MB/s
}

// Error handling tests
test "Zero-copy error conditions" {
    var pool = try zero_copy.BufferPool.init(testing.allocator);
    defer pool.deinit();
    
    // Test invalid buffer operations
    const invalid_buffer = [_]u8{1, 2, 3, 4};
    try testing.expectError(zero_copy.ZeroCopyError.InvalidHandle, pool.pin(&invalid_buffer));
}

test "Stream error conditions" {
    const config = realtime_streams.StreamConfig{
        .buffer_size = 64,
        .max_buffer_count = 1, // Very small to trigger backpressure
        .backpressure_strategy = .error_on_full,
        .enable_rate_limiting = true,
        .max_messages_per_second = 1, // Very low to trigger rate limiting
    };
    
    var stream = try realtime_streams.RealtimeStream.init(testing.allocator, config);
    defer stream.deinit();
    
    const mock_io = MockIo.init(testing.allocator);
    
    // First message should succeed
    var message1 = try realtime_streams.StreamMessage.init(testing.allocator, "message1");
    defer message1.deinit();
    try stream.send(mock_io, message1);
    
    // Second message should trigger backpressure error
    var message2 = try realtime_streams.StreamMessage.init(testing.allocator, "message2");
    defer message2.deinit();
    try testing.expectError(realtime_streams.StreamError.BufferOverflow, stream.send(mock_io, message2));
}

// Memory leak detection
test "Memory cleanup verification" {
    // This test runs all major operations and verifies no memory leaks
    const allocator = std.testing.allocator;
    
    // Zero-copy operations
    {
        var pool = try zero_copy.BufferPool.init(allocator);
        defer pool.deinit();
        
        const zero_copy_io = zero_copy.ZeroCopyIo.init(&pool);
        const mock_io = MockIo.init(allocator);
        
        var i: usize = 0;
        while (i < 10) : (i += 1) {
            const buffer = try zero_copy_io.readZeroCopy(mock_io, 0, 1024);
            pool.release(buffer);
        }
    }
    
    // Stream operations
    {
        const config = realtime_streams.StreamConfig{
            .buffer_size = 1024,
            .max_buffer_count = 4,
        };
        
        var stream = try realtime_streams.RealtimeStream.init(allocator, config);
        defer stream.deinit();
        
        const mock_io = MockIo.init(allocator);
        
        var i: usize = 0;
        while (i < 5) : (i += 1) {
            var message = try realtime_streams.StreamMessage.init(allocator, "test");
            defer message.deinit();
            try stream.send(mock_io, message);
        }
    }
    
    // All memory should be properly cleaned up by defer statements
}