//! zsync- Platform-Specific Runtime Factory
//! Creates optimized runtime instances based on platform capabilities

const std = @import("std");
const builtin = @import("builtin");

const io_interface = @import("io_interface.zig");
const platform_runtime = @import("platform_runtime.zig");
const platform_imports = @import("platform_imports.zig");
const compat = @import("compat/thread.zig");

// Use conditional imports
const blocking_io = platform_imports.blocking_io;
const green_threads = platform_imports.linux.green_threads;
const windows_iocp = platform_imports.windows.iocp;
const windows_iocp_io = @import("windows_iocp_io.zig");
const macos_kqueue = platform_imports.macos.kqueue;
const wasm_runtime = platform_imports.wasm.stackless;

pub const RuntimeFactory = struct {
    allocator: std.mem.Allocator,
    platform: platform_runtime.PlatformRuntime,

    const Self = @This();

    /// Create factory with optimal platform detection
    pub fn init(allocator: std.mem.Allocator) !Self {
        const platform = try platform_runtime.createOptimalRuntime(allocator);

        return Self{
            .allocator = allocator,
            .platform = platform,
        };
    }

    /// Create platform-optimized async runtime
    pub fn createAsyncRuntime(self: *Self) !AsyncRuntime {
        const config = self.platform.getRecommendedConfig();

        switch (self.platform.backend) {
            .linux_io_uring => {
                if (builtin.os.tag == .linux) {
                    const runtime = try green_threads.createGreenThreadsIo(self.allocator, config.queue_depth);
                    return AsyncRuntime{ .linux_io_uring = runtime };
                } else {
                    return self.createFallbackRuntime();
                }
            },
            .linux_epoll => {
                // TODO: Implement epoll-based runtime
                return self.createFallbackRuntime();
            },
            .windows_iocp => {
                if (builtin.os.tag == .windows and windows_iocp != void) {
                    const runtime = try windows_iocp_io.createWindowsIocpIo(self.allocator, config.thread_count);
                    return AsyncRuntime{ .windows_iocp = runtime };
                } else {
                    return self.createFallbackRuntime();
                }
            },
            .windows_select => {
                // TODO: Implement select-based runtime for Windows
                return self.createFallbackRuntime();
            },
            .macos_kqueue => {
                if (builtin.os.tag == .macos and macos_kqueue != void) {
                    // TODO: Implement kqueue runtime
                    return self.createFallbackRuntime();
                } else {
                    return self.createFallbackRuntime();
                }
            },
            .macos_poll => {
                // TODO: Implement poll-based runtime for macOS
                return self.createFallbackRuntime();
            },
            .wasm_promise, .wasm_stackless => {
                if ((builtin.os.tag == .wasi or builtin.os.tag == .freestanding) and wasm_runtime != void) {
                    // TODO: Implement WASM runtime
                    return self.createFallbackRuntime();
                } else {
                    return self.createFallbackRuntime();
                }
            },
            .posix_blocking, .generic_blocking => {
                return self.createFallbackRuntime();
            },
        }
    }

    /// Create blocking I/O fallback runtime
    fn createFallbackRuntime(self: *Self) !AsyncRuntime {
        // On Windows, use IOCP backend as fallback (fd_t is void on Windows)
        if (builtin.os.tag == .windows) {
            // Use reasonable thread count based on CPU cores (min 2, max 16)
            const cpu_count = std.Thread.getCpuCount() catch 4;
            const thread_count: u32 = @intCast(@min(16, @max(2, cpu_count)));
            const runtime = try windows_iocp_io.WindowsIocpIo.init(self.allocator, thread_count);
            return AsyncRuntime{ .windows_iocp = runtime };
        }
        const runtime = blocking_io.BlockingIo.init(self.allocator, 4096);
        return AsyncRuntime{ .blocking = runtime };
    }

    /// Print platform information and recommendations
    pub fn printInfo(self: *const Self) void {
        self.platform.printPlatformInfo();
    }

    /// Get current platform capabilities
    pub fn getCapabilities(self: *const Self) platform_runtime.PlatformCapabilities {
        return self.platform.capabilities;
    }

    /// Check if high-performance backend is available
    pub fn isHighPerformance(self: *const Self) bool {
        return self.platform.isHighPerformance();
    }
};

/// Platform-specific runtime union
pub const AsyncRuntime = union(enum) {
    // Linux
    linux_io_uring: platform_imports.PlatformSpecificType(if (green_threads != void) green_threads.GreenThreadsIo else void),
    linux_epoll: void, // TODO: Implement

    // Windows
    windows_iocp: platform_imports.PlatformSpecificType(if (windows_iocp != void) windows_iocp_io.WindowsIocpIo else void),
    windows_select: void, // TODO: Implement

    // macOS
    macos_kqueue: void, // TODO: Implement
    macos_poll: void, // TODO: Implement

    // WASM
    wasm_promise: void, // TODO: Implement
    wasm_stackless: void, // TODO: Implement

    // Fallback
    blocking: blocking_io.BlockingIo,

    const Self = @This();

    /// Get unified I/O interface for any runtime
    /// Panics if called on a placeholder variant that was never properly constructed.
    /// All valid AsyncRuntime instances are created via RuntimeFactory.createAsyncRuntime(),
    /// which only produces linux_io_uring, windows_iocp, or blocking variants.
    pub fn io(self: *Self) io_interface.Io {
        return switch (self.*) {
            .linux_io_uring => |*runtime| {
                if (builtin.os.tag == .linux) return runtime.io();
                unreachable;
            },
            .blocking => |*runtime| runtime.io(),
            .windows_iocp => |*runtime| {
                if (builtin.os.tag == .windows and windows_iocp != void) return runtime.io();
                unreachable;
            },
            // Placeholder variants - these are never constructed by the factory
            // If reached, it means manual construction of an invalid AsyncRuntime
            .linux_epoll,
            .windows_select,
            .macos_kqueue,
            .macos_poll,
            .wasm_promise,
            .wasm_stackless,
            => @panic("AsyncRuntime: unimplemented backend variant - use RuntimeFactory.createAsyncRuntime()"),
        };
    }

    /// Cleanup runtime resources
    pub fn deinit(self: *Self) void {
        switch (self.*) {
            .linux_io_uring => |*runtime| {
                if (builtin.os.tag == .linux) {
                    runtime.deinit();
                }
            },
            .blocking => |*runtime| runtime.deinit(),
            .windows_iocp => |*runtime| {
                if (builtin.os.tag == .windows and windows_iocp != void) {
                    runtime.deinit();
                }
            },
            inline else => {
                // No cleanup needed for unimplemented runtimes
            },
        }
    }

    /// Register a descriptor known to be a socket with the active backend.
    pub fn registerSocket(self: *Self, fd: std.posix.fd_t) !void {
        switch (self.*) {
            .windows_iocp => |*runtime| {
                if (builtin.os.tag == .windows and windows_iocp != void) {
                    try runtime.registerSocket(fd);
                }
            },
            inline else => {},
        }
    }

    /// Register a descriptor known to be a file with the active backend.
    pub fn registerFile(self: *Self, fd: std.posix.fd_t) !void {
        switch (self.*) {
            .windows_iocp => |*runtime| {
                if (builtin.os.tag == .windows and windows_iocp != void) {
                    try runtime.registerFile(fd);
                }
            },
            inline else => {},
        }
    }

    /// Get runtime performance metrics
    pub fn getMetrics(self: *const Self) RuntimeMetrics {
        return switch (self.*) {
            .linux_io_uring => |*runtime| {
                if (builtin.os.tag == .linux) {
                    return RuntimeMetrics{
                        .operations_submitted = runtime.getMetrics().operations_submitted.load(.monotonic),
                        .operations_completed = runtime.getMetrics().operations_completed.load(.monotonic),
                        .green_threads_spawned = runtime.getMetrics().green_threads_spawned.load(.monotonic),
                        .context_switches = runtime.getMetrics().context_switches.load(.monotonic),
                    };
                } else {
                    return RuntimeMetrics{};
                }
            },
            .blocking => |*runtime| RuntimeMetrics{
                .operations_submitted = runtime.getMetrics().operations_completed.load(.monotonic),
                .operations_completed = runtime.getMetrics().operations_completed.load(.monotonic),
                .green_threads_spawned = 0,
                .context_switches = 0,
            },
            inline else => RuntimeMetrics{}, // Default empty metrics
        };
    }

    /// Poll for async events (platform-specific)
    pub fn poll(self: *Self, timeout_ms: u32) !void {
        switch (self.*) {
            .linux_io_uring => |*runtime| {
                if (builtin.os.tag == .linux) {
                    try runtime.poll(timeout_ms);
                } else {
                    compat.sleepMillis(timeout_ms);
                }
            },
            .blocking => {
                // Blocking I/O doesn't need polling
                compat.sleepMillis(timeout_ms);
            },
            inline else => {
                // Fallback: just sleep
                compat.sleepMillis(timeout_ms);
            },
        }
    }

    /// Get backend name
    pub fn getBackendName(self: *const Self) []const u8 {
        return switch (self.*) {
            .linux_io_uring => "Linux io_uring",
            .linux_epoll => "Linux epoll",
            .windows_iocp => "Windows IOCP",
            .windows_select => "Windows select",
            .macos_kqueue => "macOS kqueue",
            .macos_poll => "macOS poll",
            .wasm_promise => "WASM Promise",
            .wasm_stackless => "WASM Stackless",
            .blocking => "Blocking I/O",
        };
    }
};

/// Unified runtime metrics
pub const RuntimeMetrics = struct {
    operations_submitted: u64 = 0,
    operations_completed: u64 = 0,
    green_threads_spawned: u64 = 0,
    context_switches: u64 = 0,
};
