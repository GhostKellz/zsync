const std = @import("std");
const testing = std.testing;
const platform = @import("platform.zig");

test "macOS kqueue basic functionality" {
    if (platform.current_os != .macos) {
        std.debug.print("Skipping macOS test on {}\n", .{platform.current_os});
        return;
    }
    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Test event loop creation
    var event_loop = try platform.EventLoop.init(allocator);
    defer event_loop.deinit();
    
    std.debug.print("macOS EventLoop created successfully\n", .{});
    
    // Test timer creation
    const timer = try event_loop.createTimer();
    std.debug.print("Timer created with ident: {}\n", .{timer.ident});
    
    // Test capabilities are correct for macOS
    const caps = platform.PlatformCapabilities.detect();
    try testing.expect(caps.has_kqueue);
    try testing.expect(!caps.has_io_uring);
    try testing.expect(!caps.has_epoll);
    try testing.expect(!caps.has_iocp);
    
    const backend = caps.getBestAsyncBackend();
    try testing.expect(backend == .kqueue);
    
    std.debug.print("macOS platform capabilities verified\n", .{});
}

test "macOS kqueue event operations" {
    if (platform.current_os != .macos) {
        std.debug.print("Skipping macOS kqueue test on {}\n", .{platform.current_os});
        return;
    }
    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var event_loop = try platform.EventLoop.init(allocator);
    defer event_loop.deinit();
    
    // Create a pair of connected sockets for testing
    var fds: [2]i32 = undefined;
    const result = std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &fds);
    if (result != 0) {
        return error.SocketPairFailed;
    }
    defer {
        std.posix.close(fds[0]);
        std.posix.close(fds[1]);
    }
    
    // Test adding read event
    try event_loop.source.addRead(fds[0], null);
    std.debug.print("Added read event for fd {}\n", .{fds[0]});
    
    // Test adding write event  
    try event_loop.source.addWrite(fds[1], null);
    std.debug.print("Added write event for fd {}\n", .{fds[1]});
    
    // Test removing events
    try event_loop.source.deleteRead(fds[0]);
    try event_loop.source.deleteWrite(fds[1]);
    std.debug.print("Successfully added and removed kqueue events\n", .{});
}

test "macOS cross-platform async ops" {
    if (platform.current_os != .macos) {
        std.debug.print("Skipping macOS async ops test on {}\n", .{platform.current_os});
        return;
    }
    
    const caps = platform.PlatformCapabilities.detect();
    const backend = caps.getBestAsyncBackend();
    
    const read_op = platform.AsyncOp.initRead(backend, 0);
    const write_op = platform.AsyncOp.initWrite(backend, 1);
    
    try testing.expect(read_op.backend == .kqueue);
    try testing.expect(write_op.backend == .kqueue);
    
    switch (read_op.platform_data) {
        .kqueue => |kq_data| {
            try testing.expect(kq_data.fd == 0);
            try testing.expect(kq_data.udata == null);
        },
        else => return error.WrongBackend,
    }
    
    std.debug.print("macOS async operations created successfully\n", .{});
}

test "macOS networking optimizations" {
    if (platform.current_os != .macos) {
        std.debug.print("Skipping macOS networking test on {}\n", .{platform.current_os});
        return;
    }
    
    // Create a test socket
    const sock = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
    if (sock == -1) {
        return error.SocketCreationFailed;
    }
    defer std.posix.close(sock);
    
    // Test network optimizations
    try platform.Platform.NetworkOptimizations.enableTcpNoDelay(sock);
    try platform.Platform.NetworkOptimizations.enableReuseAddr(sock);
    try platform.Platform.NetworkOptimizations.enableReusePort(sock);
    try platform.Platform.NetworkOptimizations.setReceiveBufferSize(sock, 64 * 1024);
    try platform.Platform.NetworkOptimizations.setSendBufferSize(sock, 64 * 1024);
    
    std.debug.print("macOS networking optimizations applied successfully\n", .{});
}