const std = @import("std");
const print = std.debug.print;

const zsync = @import("../src/root.zig");
const zero_copy = @import("../src/zero_copy.zig");
const hardware_accel = @import("../src/hardware_accel.zig");
const realtime_streams = @import("../src/realtime_streams.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    print("=== zsync v0.3.1 Features Demo ===\n\n");

    // Demo 1: Zero-Copy Operations
    try demoZeroCopy(allocator);
    
    // Demo 2: Hardware Acceleration
    try demoHardwareAccel(allocator);
    
    // Demo 3: Real-time Streams
    try demoRealtimeStreams(allocator);
    
    print("\n=== Demo Complete ===\n");
}

fn demoZeroCopy(allocator: std.mem.Allocator) !void {
    print("1. Zero-Copy Operations Demo\n");
    print("   Creating buffer pool...\n");
    
    var pool = try zero_copy.BufferPool.init(allocator);
    defer pool.deinit();
    
    const zero_copy_io = zero_copy.ZeroCopyIo.init(&pool);
    
    // Acquire aligned buffer
    const buffer = try pool.acquire(64 * 1024);
    defer pool.release(buffer);
    
    print("   ✓ Acquired 64KB aligned buffer at 0x{X}\n", .{@intFromPtr(buffer.ptr)});
    print("   ✓ Buffer alignment: {} bytes\n", .{@intFromPtr(buffer.ptr) % std.mem.page_size});
    
    // Demo ring buffer
    var ring = try zero_copy.ZeroCopyRingBuffer.init(allocator, 4096);
    defer ring.deinit(allocator);
    
    const test_data = "Zero-copy high-performance data!";
    
    // Write to ring buffer
    const write_slice = try ring.writeableSlice();
    @memcpy(write_slice.ptr[0..test_data.len], test_data);
    ring.commitWrite(test_data.len);
    
    // Read from ring buffer
    const read_slice = try ring.readableSlice();
    const read_data = read_slice.ptr[0..test_data.len];
    ring.commitRead(test_data.len);
    
    print("   ✓ Ring buffer write/read: '{}'\n", .{read_data});
    print("\n");
}

fn demoHardwareAccel(allocator: std.mem.Allocator) !void {
    print("2. Hardware Acceleration Demo\n");
    
    const hw = hardware_accel.HardwareAccel.init();
    const features = hw.features;
    
    print("   CPU Features detected:\n");
    if (std.builtin.cpu.arch == .x86_64) {
        print("     SSE2: {}, AVX: {}, AVX2: {}, AES: {}\n", .{ features.sse2, features.avx, features.avx2, features.aes });
    } else if (std.builtin.cpu.arch == .aarch64) {
        print("     NEON: {}, CRC32: {}, Crypto: {}\n", .{ features.neon, features.crc32, features.crypto });
    }
    print("     Cache line size: {} bytes\n", .{features.cache_line_size});
    
    // Demo optimized operations
    const src_data = "The quick brown fox jumps over the lazy dog";
    var dst_buffer: [64]u8 = undefined;
    var xor_buffer: [64]u8 = undefined;
    const key_data = [_]u8{0xAA} ** 43; // XOR key
    
    // Create mock io
    const MockIo = struct {
        pub fn read(self: @This(), handle: anytype, buffer: []u8) !usize { _ = self; _ = handle; return buffer.len; }
        pub fn write(self: @This(), handle: anytype, data: []const u8) !usize { _ = self; _ = handle; return data.len; }
    };
    const mock_io = MockIo{};
    
    // Optimized copy
    try hw.optimizedCopy(mock_io, dst_buffer[0..src_data.len], src_data);
    print("   ✓ Hardware-accelerated copy: '{}'\n", .{dst_buffer[0..src_data.len]});
    
    // Optimized XOR
    try hw.optimizedXor(mock_io, xor_buffer[0..src_data.len], src_data, key_data[0..src_data.len]);
    print("   ✓ Hardware-accelerated XOR completed\n");
    
    // Prefetch demo
    hw.prefetch(@ptrCast(src_data.ptr), .t0);
    print("   ✓ Memory prefetch issued\n");
    
    print("\n");
}

fn demoRealtimeStreams(allocator: std.mem.Allocator) !void {
    print("3. Real-time Streams Demo\n");
    
    // Create high-throughput stream
    var stream = try realtime_streams.createHighThroughputStream(allocator);
    defer stream.deinit();
    
    print("   ✓ Created high-throughput stream\n");
    print("     Buffer size: {} bytes\n", .{stream.config.buffer_size});
    print("     Max rate: {} msg/sec\n", .{stream.config.max_messages_per_second});
    print("     Backpressure: {}\n", .{stream.config.backpressure_strategy});
    
    // Subscribe to messages
    const MessageHandler = struct {
        var received_count: u32 = 0;
        
        fn handleMessage(message: realtime_streams.StreamMessage) !void {
            received_count += 1;
            if (received_count <= 3) {
                print("     📨 Received: '{}' (priority: {})\n", .{ message.data, message.priority });
            }
        }
    };
    
    const sub_id = try stream.subscribe(
        MessageHandler.handleMessage,
        0xFF, // All priorities
        1000, // Max queue size
        null  // No filter
    );
    
    // Create mock io for message sending
    const MockIo = struct {
        allocator: std.mem.Allocator,
        
        pub fn async(self: @This(), comptime func: anytype, args: anytype) MockFuture(@TypeOf(func), @TypeOf(args)) {
            return MockFuture(@TypeOf(func), @TypeOf(args)){
                .io = self,
                .func = func,
                .args = args,
            };
        }
    };
    
    const mock_io = MockIo{ .allocator = allocator };
    
    // Send test messages
    const messages = [_][]const u8{
        "High priority message",
        "Normal priority message", 
        "Low priority message",
        "Critical alert!",
        "Batch processed",
    };
    
    const priorities = [_]realtime_streams.Priority{
        .high, .normal, .low, .critical, .normal
    };
    
    for (messages, priorities) |msg_text, priority| {
        var message = try realtime_streams.StreamMessage.init(allocator, msg_text);
        message.priority = priority;
        defer message.deinit();
        
        try stream.send(mock_io, message);
    }
    
    print("   ✓ Sent {} messages\n", .{messages.len});
    
    // Show statistics
    const stats = stream.getStats();
    print("   📊 Stream Statistics:\n");
    print("     Messages sent: {}\n", .{stats.messages_sent});
    print("     Bytes transferred: {}\n", .{stats.bytes_transferred});
    print("     Messages dropped: {}\n", .{stats.messages_dropped});
    print("     Backpressure events: {}\n", .{stats.backpressure_events});
    
    // Cleanup
    stream.unsubscribe(sub_id);
    print("   ✓ Unsubscribed from stream\n");
    
    print("\n");
}

fn MockFuture(comptime FuncType: type, comptime ArgsType: type) type {
    return struct {
        io: MockIo,
        func: FuncType,
        args: ArgsType,
        
        const Self = @This();
        
        pub fn await(self: *Self, io: MockIo) !void {
            _ = self;
            _ = io;
        }
        
        pub fn cancel(self: *Self, io: MockIo) !void {
            _ = self;
            _ = io;
        }
    };
}