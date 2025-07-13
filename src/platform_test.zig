const std = @import("std");
const testing = std.testing;
const platform = @import("platform.zig");

test "platform detection" {
    const caps = platform.PlatformCapabilities.detect();
    
    // Print platform info
    std.debug.print("\nPlatform: {}\n", .{platform.current_os});
    std.debug.print("Architecture: {}\n", .{platform.current_arch});
    std.debug.print("Capabilities:\n", .{});
    std.debug.print("  io_uring: {}\n", .{caps.has_io_uring});
    std.debug.print("  kqueue: {}\n", .{caps.has_kqueue});
    std.debug.print("  epoll: {}\n", .{caps.has_epoll});
    std.debug.print("  iocp: {}\n", .{caps.has_iocp});
    std.debug.print("  max_threads: {}\n", .{caps.max_threads});
    
    const backend = caps.getBestAsyncBackend();
    std.debug.print("  best_backend: {}\n", .{backend});
    
    // Verify platform-specific capabilities
    switch (platform.current_os) {
        .linux => {
            try testing.expect(caps.has_io_uring or caps.has_epoll);
            try testing.expect(!caps.has_kqueue);
            try testing.expect(!caps.has_iocp);
        },
        .macos => {
            try testing.expect(caps.has_kqueue);
            try testing.expect(!caps.has_io_uring);
            try testing.expect(!caps.has_epoll);
            try testing.expect(!caps.has_iocp);
        },
        .windows => {
            try testing.expect(caps.has_iocp);
            try testing.expect(!caps.has_io_uring);
            try testing.expect(!caps.has_kqueue);
            try testing.expect(!caps.has_epoll);
        },
        else => {
            // Unknown platform - should have minimal capabilities
        },
    }
}

test "cross-platform async operations" {
    const caps = platform.PlatformCapabilities.detect();
    const backend = caps.getBestAsyncBackend();
    
    // Create async operations for different backends
    const read_op = platform.AsyncOp.initRead(backend, 0);
    const write_op = platform.AsyncOp.initWrite(backend, 1);
    
    try testing.expect(read_op.backend == backend);
    try testing.expect(write_op.backend == backend);
    
    std.debug.print("Created async ops for backend: {}\n", .{backend});
}

test "performance counters" {
    var counters = platform.PerformanceCounters.init();
    
    // Test counter operations
    counters.incrementContextSwitches();
    counters.incrementIoOperations();
    counters.incrementTimerFires();
    counters.incrementMemoryAllocations();
    
    try testing.expect(counters.context_switches == 1);
    try testing.expect(counters.io_operations == 1);
    try testing.expect(counters.timer_fires == 1);
    try testing.expect(counters.memory_allocations == 1);
    
    std.debug.print("Performance counters working correctly\n", .{});
}

test "stack allocation" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const stack = try platform.allocateStack(allocator);
    defer platform.deallocateStack(allocator, stack);
    
    try testing.expect(stack.len > 0);
    try testing.expect(@intFromPtr(stack.ptr) % 4096 == 0); // Should be page aligned
    
    std.debug.print("Allocated stack: {} bytes at 0x{x}\n", .{ stack.len, @intFromPtr(stack.ptr) });
}