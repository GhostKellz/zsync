const std = @import("std");
const testing = std.testing;
const platform = @import("platform.zig");

test "Windows IOCP basic functionality" {
    if (platform.current_os != .windows) {
        std.debug.print("Skipping Windows test on {}\n", .{platform.current_os});
        return;
    }
    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Test event loop creation
    var event_loop = try platform.EventLoop.init(allocator);
    defer event_loop.deinit();
    
    std.debug.print("Windows EventLoop created successfully\n", .{});
    
    // Test timer creation
    _ = try event_loop.createTimer();
    std.debug.print("Timer created successfully\n", .{});
    
    // Test capabilities are correct for Windows
    const caps = platform.PlatformCapabilities.detect();
    try testing.expect(caps.has_iocp);
    try testing.expect(!caps.has_io_uring);
    try testing.expect(!caps.has_kqueue);
    try testing.expect(!caps.has_epoll);
    
    const backend = caps.getBestAsyncBackend();
    try testing.expect(backend == .iocp);
    
    std.debug.print("Windows platform capabilities verified\n", .{});
}

test "Windows IOCP async operations" {
    if (platform.current_os != .windows) {
        std.debug.print("Skipping Windows IOCP test on {}\n", .{platform.current_os});
        return;
    }
    
    const caps = platform.PlatformCapabilities.detect();
    const backend = caps.getBestAsyncBackend();
    
    const read_op = platform.AsyncOp.initRead(backend, 0);
    const write_op = platform.AsyncOp.initWrite(backend, 1);
    
    try testing.expect(read_op.backend == .iocp);
    try testing.expect(write_op.backend == .iocp);
    
    switch (read_op.platform_data) {
        .iocp => |iocp_data| {
            try testing.expect(iocp_data.completion_key == 0);
            try testing.expect(iocp_data.overlapped == null);
        },
        else => return error.WrongBackend,
    }
    
    std.debug.print("Windows async operations created successfully\n", .{});
}

test "Windows timer functionality" {
    if (platform.current_os != .windows) {
        std.debug.print("Skipping Windows timer test on {}\n", .{platform.current_os});
        return;
    }
    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var event_loop = try platform.EventLoop.init(allocator);
    defer event_loop.deinit();
    
    const timer = try event_loop.createTimer();
    
    // Test setting a timer (this would normally be async)
    try timer.setRelative(1000000000); // 1 second in nanoseconds
    std.debug.print("Timer set for 1 second\n", .{});
    
    // Test waiting for timer (with immediate timeout for testing)
    const fired = try timer.wait(0); // 0ms timeout = immediate return
    try testing.expect(!fired); // Should not have fired yet
    
    // Cancel the timer
    try timer.cancel();
    std.debug.print("Timer cancelled successfully\n", .{});
}

test "Windows networking optimizations" {
    if (platform.current_os != .windows) {
        std.debug.print("Skipping Windows networking test on {}\n", .{platform.current_os});
        return;
    }
    
    // This test would require actual Windows networking APIs
    // For now, just verify the structure exists
    const NetworkOpts = platform.Platform.NetworkOptimizations;
    _ = NetworkOpts;
    
    std.debug.print("Windows networking optimizations available\n", .{});
}