//! Zsync v0.6.0 - Runtime Diagnostics
//! System capability detection and runtime statistics

const std = @import("std");
const builtin = @import("builtin");
const platform_detect = @import("platform_detect.zig");
const runtime_mod = @import("runtime.zig");

/// Runtime diagnostics for debugging and monitoring
pub const RuntimeDiagnostics = struct {
    /// Print system capabilities and recommended configuration
    pub fn printCapabilities(allocator: std.mem.Allocator) !void {
        _ = allocator;

        std.debug.print("\n", .{});
        std.debug.print("═══════════════════════════════════════════════════════════\n", .{});
        std.debug.print("  Zsync v0.6.0 Runtime Diagnostics\n", .{});
        std.debug.print("═══════════════════════════════════════════════════════════\n", .{});
        std.debug.print("\n", .{});

        // Platform information
        std.debug.print("🖥️  Platform:\n", .{});
        std.debug.print("   OS:           {s}\n", .{@tagName(builtin.os.tag)});
        std.debug.print("   Architecture: {s}\n", .{@tagName(builtin.cpu.arch)});

        // Detect capabilities
        const caps = platform_detect.detectSystemCapabilities();
        const settings = platform_detect.getDistroOptimalSettings(caps.distro);

        std.debug.print("   Distribution: {s}\n", .{@tagName(caps.distro)});
        std.debug.print("   Kernel:       {}.{}.{}\n", .{
            caps.kernel_version.major,
            caps.kernel_version.minor,
            caps.kernel_version.patch,
        });

        // CPU information
        const cpu_count = std.Thread.getCpuCount() catch 0;
        std.debug.print("   CPU Cores:    {}\n", .{cpu_count});

        std.debug.print("\n", .{});

        // Async I/O capabilities
        std.debug.print("⚡ Async I/O Capabilities:\n", .{});
        std.debug.print("   io_uring:     {s}\n", .{if (caps.has_io_uring) "✅ Available" else "❌ Not Available"});
        std.debug.print("   epoll:        {s}\n", .{if (caps.has_epoll) "✅ Available" else "❌ Not Available"});
        std.debug.print("   kqueue:       {s} ({s})\n", .{
            if (builtin.os.tag == .macos or builtin.os.tag == .freebsd or builtin.os.tag == .openbsd) "✅ Available" else "❌ Not Available",
            @tagName(builtin.os.tag),
        });
        std.debug.print("   IOCP:         {s} ({s})\n", .{
            if (builtin.os.tag == .windows) "✅ Available" else "❌ Not Available",
            @tagName(builtin.os.tag),
        });

        std.debug.print("\n", .{});

        // Package manager
        const pm = platform_detect.detectPackageManager();
        std.debug.print("📦 Package Manager:\n", .{});
        std.debug.print("   Detected:     {s}\n", .{@tagName(pm)});
        if (platform_detect.PackageManagerPaths.forPackageManager(pm)) |paths| {
            std.debug.print("   Binary Path:  {s}\n", .{paths.bin_path});
            std.debug.print("   Library Path: {s}\n", .{paths.lib_path});
        }

        std.debug.print("\n", .{});

        // Optimal settings
        const optimal_model = runtime_mod.ExecutionModel.detect();
        std.debug.print("🎯 Recommended Configuration:\n", .{});
        std.debug.print("   Execution Model:     {s}\n", .{@tagName(optimal_model)});
        std.debug.print("   Thread Pool Size:    {} threads\n", .{@min(cpu_count, 16)});
        std.debug.print("   Prefer io_uring:     {}\n", .{settings.prefer_io_uring});
        std.debug.print("   Aggressive Threading: {}\n", .{settings.aggressive_threading});
        std.debug.print("   Buffer Size:         {} bytes\n", .{settings.buffer_size});
        std.debug.print("   Use Huge Pages:      {}\n", .{settings.use_huge_pages});

        std.debug.print("\n", .{});
        std.debug.print("═══════════════════════════════════════════════════════════\n", .{});
        std.debug.print("\n", .{});
    }

    /// Get runtime statistics
    pub fn getStats(runtime: *runtime_mod.Runtime) RuntimeStats {
        const metrics = runtime.getMetrics();
        const model = runtime.getExecutionModel();

        return RuntimeStats{
            .execution_model = model,
            .is_running = runtime.isRunning(),
            .tasks_spawned = metrics.tasks_spawned.load(.monotonic),
            .tasks_completed = metrics.tasks_completed.load(.monotonic),
            .futures_created = metrics.futures_created.load(.monotonic),
            .futures_cancelled = metrics.futures_cancelled.load(.monotonic),
            .io_operations = metrics.total_io_operations.load(.monotonic),
            .avg_latency_ns = metrics.average_latency_ns.load(.monotonic),
        };
    }

    /// Print runtime statistics
    pub fn printStats(runtime: *runtime_mod.Runtime) void {
        const stats = getStats(runtime);

        std.debug.print("\n", .{});
        std.debug.print("📊 Runtime Statistics:\n", .{});
        std.debug.print("───────────────────────────────────────\n", .{});
        std.debug.print("  Execution Model: {s}\n", .{@tagName(stats.execution_model)});
        std.debug.print("  Status:          {s}\n", .{if (stats.is_running) "Running" else "Stopped"});
        std.debug.print("\n", .{});
        std.debug.print("  Tasks:\n", .{});
        std.debug.print("    Spawned:       {}\n", .{stats.tasks_spawned});
        std.debug.print("    Completed:     {}\n", .{stats.tasks_completed});
        std.debug.print("    Active:        {}\n", .{stats.tasks_spawned - stats.tasks_completed});
        std.debug.print("\n", .{});
        std.debug.print("  Futures:\n", .{});
        std.debug.print("    Created:       {}\n", .{stats.futures_created});
        std.debug.print("    Cancelled:     {}\n", .{stats.futures_cancelled});
        std.debug.print("\n", .{});
        std.debug.print("  I/O:\n", .{});
        std.debug.print("    Operations:    {}\n", .{stats.io_operations});
        std.debug.print("    Avg Latency:   {} ns\n", .{stats.avg_latency_ns});
        std.debug.print("───────────────────────────────────────\n", .{});
        std.debug.print("\n", .{});
    }

    /// Check if platform supports optimal async I/O
    pub fn supportsOptimalAsync() bool {
        return switch (builtin.os.tag) {
            .linux => platform_detect.detectSystemCapabilities().has_io_uring,
            .windows => true, // IOCP
            .macos, .freebsd, .openbsd, .netbsd => true, // kqueue
            else => false,
        };
    }

    /// Get recommended buffer size for this platform
    pub fn getRecommendedBufferSize() usize {
        const caps = platform_detect.detectSystemCapabilities();
        const settings = platform_detect.getDistroOptimalSettings(caps.distro);
        return settings.buffer_size;
    }
};

/// Runtime statistics snapshot
pub const RuntimeStats = struct {
    execution_model: runtime_mod.ExecutionModel,
    is_running: bool,
    tasks_spawned: u64,
    tasks_completed: u64,
    futures_created: u64,
    futures_cancelled: u64,
    io_operations: u64,
    avg_latency_ns: u64,

    /// Calculate task completion rate
    pub fn completionRate(self: RuntimeStats) f64 {
        if (self.tasks_spawned == 0) return 0.0;
        return @as(f64, @floatFromInt(self.tasks_completed)) / @as(f64, @floatFromInt(self.tasks_spawned));
    }

    /// Get active task count
    pub fn activeTasks(self: RuntimeStats) u64 {
        return self.tasks_spawned - self.tasks_completed;
    }
};

// Tests
test "diagnostics basic" {
    const testing = std.testing;

    const caps_supported = RuntimeDiagnostics.supportsOptimalAsync();
    _ = caps_supported;

    const buffer_size = RuntimeDiagnostics.getRecommendedBufferSize();
    try testing.expect(buffer_size > 0);
}
