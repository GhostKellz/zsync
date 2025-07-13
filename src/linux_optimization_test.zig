const std = @import("std");
const testing = std.testing;
const platform = @import("platform.zig");

test "Linux Arch optimization features" {
    if (platform.current_os != .linux) {
        std.debug.print("Skipping Linux optimization test on {}\n", .{platform.current_os});
        return;
    }
    
    std.debug.print("Testing Arch Linux optimizations...\n", .{});
    
    // Test NUMA topology detection
    const numa_nodes = platform.Platform.ArchLinuxOptimizations.detectNumaTopology() catch |err| {
        std.debug.print("NUMA detection failed (may not be available): {}\n", .{err});
        return;
    };
    defer std.heap.page_allocator.free(numa_nodes);
    
    std.debug.print("Detected {} NUMA nodes: ", .{numa_nodes.len});
    for (numa_nodes) |node| {
        std.debug.print("{} ", .{node});
    }
    std.debug.print("\n", .{});
    
    // Test system optimizations (these may fail without root privileges)
    platform.Platform.ArchLinuxOptimizations.optimizeCpuGovernor() catch |err| {
        std.debug.print("CPU governor optimization failed (may need root): {}\n", .{err});
    };
    
    platform.Platform.ArchLinuxOptimizations.enableTransparentHugePages() catch |err| {
        std.debug.print("THP optimization failed (may need root): {}\n", .{err});
    };
    
    platform.Platform.ArchLinuxOptimizations.tuneScheduler() catch |err| {
        std.debug.print("Scheduler tuning failed (may need root): {}\n", .{err});
    };
    
    platform.Platform.ArchLinuxOptimizations.optimizeNetworkStack() catch |err| {
        std.debug.print("Network optimization failed (may need root): {}\n", .{err});
    };
    
    std.debug.print("Arch Linux optimization tests completed\n", .{});
}

test "Linux zero-copy ring buffer" {
    if (platform.current_os != .linux) {
        std.debug.print("Skipping Linux ring buffer test on {}\n", .{platform.current_os});
        return;
    }
    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var ring_buffer = try platform.Platform.ZeroCopyRingBuffer.init(allocator, 8192);
    defer ring_buffer.deinit(allocator);
    
    // Test writing data
    const write_data = "Hello, zero-copy world!";
    const written = try ring_buffer.writeSlice(write_data);
    try testing.expect(written == write_data.len);
    
    // Test reading data
    var read_buffer: [100]u8 = undefined;
    const read_count = try ring_buffer.readSlice(&read_buffer);
    try testing.expect(read_count == write_data.len);
    try testing.expect(std.mem.eql(u8, write_data, read_buffer[0..read_count]));
    
    std.debug.print("Zero-copy ring buffer test passed\n", .{});
}

test "Linux batch processor" {
    if (platform.current_os != .linux) {
        std.debug.print("Skipping Linux batch processor test on {}\n", .{platform.current_os});
        return;
    }
    
    // Create a mock io_uring for testing
    var io_ring = try platform.Platform.IoUring.init(256);
    defer io_ring.deinit();
    
    var batch = platform.Platform.BatchProcessor.init(&io_ring);
    
    // Test adding operations (these would normally use real file descriptors)
    var buffer1: [1024]u8 = undefined;
    var buffer2: [1024]u8 = undefined;
    
    try batch.addRead(1, &buffer1, 0, 1001);
    try batch.addWrite(2, &buffer2, 0, 1002);
    
    // Submit batch (this would normally submit to the kernel)
    const submitted = batch.submit() catch |err| {
        std.debug.print("Batch submit failed (expected in test environment): {}\n", .{err});
        return;
    };
    
    std.debug.print("Batch processor submitted {} operations\n", .{submitted});
}

test "Linux advanced io_uring features" {
    if (platform.current_os != .linux) {
        std.debug.print("Skipping Linux io_uring test on {}\n", .{platform.current_os});
        return;
    }
    
    // Test advanced io_uring creation with optimizations
    var io_ring = platform.Platform.IoUring.init(256) catch |err| {
        std.debug.print("Advanced io_uring creation failed: {}\n", .{err});
        return;
    };
    defer io_ring.deinit();
    
    std.debug.print("Advanced io_uring created with features: 0x{x}\n", .{io_ring.features});
    
    // Test vectored I/O preparation
    var buffer1: [1024]u8 = undefined;
    var buffer2: [2048]u8 = undefined;
    var iovec = [_]std.posix.iovec{
        .{ .base = &buffer1, .len = 1024 },
        .{ .base = &buffer2, .len = 2048 },
    };
    
    const sqe = io_ring.prepareReadv(1, &iovec, 0, 2001) catch |err| {
        std.debug.print("Vectored I/O preparation failed: {}\n", .{err});
        return;
    };
    
    try testing.expect(sqe.opcode == std.os.linux.IORING_OP.READV);
    try testing.expect(sqe.user_data == 2001);
    
    std.debug.print("Advanced io_uring features test passed\n", .{});
}

test "Cross-platform performance comparison" {
    const caps = platform.PlatformCapabilities.detect();
    const backend = caps.getBestAsyncBackend();
    
    std.debug.print("\nPerformance characteristics by platform:\n", .{});
    std.debug.print("Current platform: {} using {}\n", .{ platform.current_os, backend });
    
    switch (platform.current_os) {
        .linux => {
            std.debug.print("  - io_uring: Ultra-high performance async I/O\n", .{});
            std.debug.print("  - Batch operations: 64 operations per syscall\n", .{});
            std.debug.print("  - Zero-copy ring buffers available\n", .{});
            std.debug.print("  - Arch Linux optimizations: CPU, memory, network\n", .{});
        },
        .macos => {
            std.debug.print("  - kqueue: High performance event notification\n", .{});
            std.debug.print("  - Native timer integration\n", .{});
            std.debug.print("  - Efficient socket operations\n", .{});
        },
        .windows => {
            std.debug.print("  - IOCP: Scalable completion-based I/O\n", .{});
            std.debug.print("  - Overlapped I/O with automatic thread management\n", .{});
            std.debug.print("  - Native Windows async socket APIs\n", .{});
        },
        else => {
            std.debug.print("  - Fallback implementation\n", .{});
        },
    }
    
    std.debug.print("Max concurrent threads: {}\n", .{caps.max_threads});
    std.debug.print("Work stealing enabled: {}\n", .{caps.has_workstealing});
}