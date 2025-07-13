const std = @import("std");
const platform = @import("platform.zig");

pub fn main() !void {
    std.debug.print("🚀 zsync v0.2.0-dev - Cross-Platform Async Runtime Demo\n\n", .{});
    
    // Detect platform capabilities
    const caps = platform.PlatformCapabilities.detect();
    const backend = caps.getBestAsyncBackend();
    
    std.debug.print("Platform Information:\n", .{});
    std.debug.print("  OS: {}\n", .{platform.current_os});
    std.debug.print("  Architecture: {}\n", .{platform.current_arch});
    std.debug.print("  Best async backend: {}\n", .{backend});
    std.debug.print("  CPU count: {}\n", .{platform.getNumCpus()});
    
    std.debug.print("\nCapabilities:\n", .{});
    std.debug.print("  io_uring (Linux): {}\n", .{caps.has_io_uring});
    std.debug.print("  kqueue (macOS): {}\n", .{caps.has_kqueue});
    std.debug.print("  epoll (Linux): {}\n", .{caps.has_epoll});
    std.debug.print("  IOCP (Windows): {}\n", .{caps.has_iocp});
    std.debug.print("  Work stealing: {}\n", .{caps.has_workstealing});
    std.debug.print("  Max threads: {}\n", .{caps.max_threads});
    
    // Test stack allocation
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    std.debug.print("\nStack Allocation Test:\n", .{});
    const stack = try platform.allocateStack(allocator);
    defer platform.deallocateStack(allocator, stack);
    std.debug.print("  Allocated {} MB stack at 0x{x}\n", .{ stack.len / (1024 * 1024), @intFromPtr(stack.ptr) });
    
    // Test performance counters
    std.debug.print("\nPerformance Counter Test:\n", .{});
    var counters = platform.PerformanceCounters.init();
    counters.incrementContextSwitches();
    counters.incrementIoOperations();
    counters.incrementTimerFires();
    counters.incrementMemoryAllocations();
    
    std.debug.print("  Context switches: {}\n", .{counters.context_switches});
    std.debug.print("  I/O operations: {}\n", .{counters.io_operations});
    std.debug.print("  Timer fires: {}\n", .{counters.timer_fires});
    std.debug.print("  Memory allocations: {}\n", .{counters.memory_allocations});
    
    // Platform-specific functionality demo
    switch (platform.current_os) {
        .linux => {
            std.debug.print("\n🐧 Linux-specific features available:\n", .{});
            std.debug.print("  - io_uring for high-performance async I/O\n", .{});
            std.debug.print("  - epoll for event monitoring\n", .{});
            std.debug.print("  - Real assembly context switching\n", .{});
        },
        .macos => {
            std.debug.print("\n🍎 macOS-specific features available:\n", .{});
            std.debug.print("  - kqueue for event monitoring\n", .{});
            std.debug.print("  - Native timer support\n", .{});
            std.debug.print("  - Socket optimizations\n", .{});
            std.debug.print("  - Real assembly context switching\n", .{});
            
            // Test event loop creation on macOS
            std.debug.print("\nTesting macOS EventLoop:\n", .{});
            var event_loop = platform.EventLoop.init(allocator) catch |err| {
                std.debug.print("  Failed to create EventLoop: {}\n", .{err});
                return;
            };
            defer event_loop.deinit();
            std.debug.print("  ✅ EventLoop created successfully\n", .{});
            
            // Test timer creation
            const timer = event_loop.createTimer() catch |err| {
                std.debug.print("  Failed to create timer: {}\n", .{err});
                return;
            };
            std.debug.print("  ✅ Timer created with ident: {}\n", .{timer.ident});
        },
        .windows => {
            std.debug.print("\n🪟 Windows-specific features (TODO):\n", .{});
            std.debug.print("  - IOCP for completion-based I/O\n", .{});
            std.debug.print("  - Fiber-based context switching\n", .{});
            std.debug.print("  - Native Windows async APIs\n", .{});
        },
        else => {
            std.debug.print("\n❓ Unknown platform - using fallback implementations\n", .{});
        },
    }
    
    std.debug.print("\n✨ zsync cross-platform async runtime is ready!\n", .{});
    std.debug.print("📈 Next: Complete std.Io interface implementation\n", .{});
}