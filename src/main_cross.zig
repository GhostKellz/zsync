const std = @import("std");
const root = @import("root.zig");
const runtime_factory = @import("runtime_factory.zig");
const platform_runtime = @import("platform_runtime.zig");

/// Backend maturity demonstration.
///
/// This executable showcases zsync's platform detection and backend selection.
/// It is NOT a supported API surface - it exists to demonstrate which backends
/// are available on each platform and their current maturity level.
///
/// Platform support status:
/// - Linux: io_uring (native), epoll (fallback), thread pool (universal)
/// - macOS: kqueue (native), thread pool (fallback)
/// - Windows: IOCP (partial), thread pool (primary)
/// - WASM: microtask queue (limited)
/// - Other: thread pool fallback
///
/// Some I/O operations return NotSupported on platforms where the backend
/// is not yet fully implemented. This is expected and documented behavior.
pub fn main() !void {
    const allocator = std.heap.page_allocator;

    if (comptime @import("builtin").target.os.tag == .freestanding) {
        return;
    }

    std.debug.print("zsync - Cross-Platform Async Runtime (Backend Demo)\n", .{});
    std.debug.print("=" ** 60 ++ "\n", .{});

    // Create platform-optimized runtime factory
    var factory = try runtime_factory.RuntimeFactory.init(allocator);

    // Print detailed platform information
    factory.printInfo();

    // Create optimal async runtime for this platform
    var async_runtime = try factory.createAsyncRuntime();
    defer async_runtime.deinit();

    std.debug.print("Runtime Backend: {s}\n", .{async_runtime.getBackendName()});
    std.debug.print("High Performance: {}\n", .{factory.isHighPerformance()});

    // Get I/O interface
    var io = async_runtime.io();

    std.debug.print("\nI/O Capabilities:\n", .{});
    std.debug.print("  Mode: {}\n", .{io.getMode()});
    std.debug.print("  Vectorized I/O: {}\n", .{io.supportsVectorized()});
    std.debug.print("  Zero-copy I/O: {}\n", .{io.supportsZeroCopy()});

    // Demonstrate async I/O (may return NotSupported on some platforms)
    std.debug.print("\nTesting Async Operations...\n", .{});

    const test_message = "Hello from zsync cross-platform runtime!";
    var write_future = io.write(test_message) catch |err| switch (err) {
        error.NotSupported => {
            // Expected on platforms where async I/O backend is not yet complete
            std.debug.print("[INFO] Async I/O not implemented for this backend\n", .{});
            std.debug.print("       This is expected - use ThreadPoolIo as fallback\n", .{});
            return;
        },
        else => return err,
    };
    defer write_future.destroy();

    // Poll runtime for completion
    var poll_count: u32 = 0;
    while (poll_count < 10) {
        try async_runtime.poll(10); // 10ms timeout

        switch (write_future.poll()) {
            .ready => {
                std.debug.print("[OK] Async write completed\n", .{});
                break;
            },
            .pending => {
                poll_count += 1;
                continue;
            },
            .cancelled => {
                std.debug.print("[WARN] Operation cancelled\n", .{});
                break;
            },
            .err => |e| {
                std.debug.print("[ERROR] Operation failed: {}\n", .{e});
                break;
            },
        }
    }

    // Show runtime metrics
    const metrics = async_runtime.getMetrics();
    std.debug.print("\nRuntime Metrics:\n", .{});
    std.debug.print("  Operations Submitted: {}\n", .{metrics.operations_submitted});
    std.debug.print("  Operations Completed: {}\n", .{metrics.operations_completed});
    std.debug.print("  Green Threads: {}\n", .{metrics.green_threads_spawned});
    std.debug.print("  Context Switches: {}\n", .{metrics.context_switches});

    // Legacy compatibility test
    std.debug.print("\nTesting Legacy API Compatibility...\n", .{});
    try root.helloWorld(allocator);

    std.debug.print("\nBackend demo completed. Backend: {s}\n", .{async_runtime.getBackendName()});
    std.debug.print("Note: Some platforms use fallback backends with limited features.\n", .{});
}
