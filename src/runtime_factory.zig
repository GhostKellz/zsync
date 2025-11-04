//! Zsync v0.5.2 - Platform-Specific Runtime Factory
//! Creates optimized runtime instances based on platform capabilities

const std = @import("std");
const builtin = @import("builtin");

const io_interface = @import("io_interface.zig");
const platform_runtime = @import("platform_runtime.zig");
const platform_imports = @import("platform_imports.zig");

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
    pub fn io(self: *Self) io_interface.Io {
        return switch (self.*) {
            .linux_io_uring => |*runtime| {
                if (builtin.os.tag == .linux) {
                    return runtime.io();
                } else {
                    // This should never happen due to factory logic, but provide fallback
                    var simple_runtime = blocking_io.createSimpleBlockingIo(std.heap.page_allocator);
                    return simple_runtime.io();
                }
            },
            .blocking => |*runtime| runtime.io(),
            .windows_iocp => |*runtime| {
                if (builtin.os.tag == .windows and windows_iocp != void) {
                    return runtime.io();
                } else {
                    // Fallback to simple blocking I/O
                    var simple_runtime = blocking_io.createSimpleBlockingIo(std.heap.page_allocator);
                    return simple_runtime.io();
                }
            },
            
            // Other platforms return blocking I/O interface for now
            inline else => {
                // This creates a minimal blocking I/O interface
                var simple_runtime = blocking_io.createSimpleBlockingIo(std.heap.page_allocator);
                return simple_runtime.io();
            },
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
                    std.posix.nanosleep(0, timeout_ms * 1000);
                }
            },
            .blocking => {
                // Blocking I/O doesn't need polling
                std.posix.nanosleep(0, timeout_ms * 1000); // Convert to nanoseconds
            },
            inline else => {
                // Fallback: just sleep
                std.posix.nanosleep(0, timeout_ms * 1000);
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