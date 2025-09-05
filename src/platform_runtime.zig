//! Zsync v0.5.2 - Cross-Platform Async Runtime Selection
//! Automatic platform detection and optimal backend selection

const std = @import("std");
const builtin = @import("builtin");
const io_interface = @import("io_interface.zig");

/// Platform-specific runtime backend types
pub const RuntimeBackend = enum {
    // Linux: High-performance io_uring
    linux_io_uring,
    linux_epoll,
    
    // Windows: I/O Completion Ports 
    windows_iocp,
    windows_select,
    
    // macOS: kqueue + GCD integration
    macos_kqueue,
    macos_poll,
    
    // WASM: Stackless execution with Web APIs
    wasm_stackless,
    wasm_promise,
    
    // Fallback: POSIX-compatible blocking I/O
    posix_blocking,
    generic_blocking,
};

/// Platform capabilities detection
pub const PlatformCapabilities = struct {
    // Linux capabilities
    has_io_uring: bool = false,
    has_epoll: bool = false,
    io_uring_version: u32 = 0,
    
    // Windows capabilities  
    has_iocp: bool = false,
    has_overlapped_io: bool = false,
    
    // macOS capabilities
    has_kqueue: bool = false,
    has_gcd: bool = false,
    
    // WASM capabilities
    has_web_workers: bool = false,
    has_promises: bool = false,
    
    // Network capabilities
    has_sendfile: bool = false,
    has_splice: bool = false,
    supports_ipv6: bool = false,
    supports_unix_sockets: bool = false,
    
    // Performance features
    supports_zero_copy: bool = false,
    supports_vectorized_io: bool = false,
    max_concurrent_ops: u32 = 1024,
    
    // System info
    cpu_count: u32 = 1,
    page_size: usize = 4096,
    cache_line_size: usize = 64,
};

/// Detect current platform capabilities at comptime and runtime
pub fn detectCapabilities() PlatformCapabilities {
    var caps = PlatformCapabilities{};
    
    // Compile-time platform detection
    switch (builtin.os.tag) {
        .linux => {
            caps = detectLinuxCapabilities();
        },
        .windows => {
            caps = detectWindowsCapabilities();
        },
        .macos => {
            caps = detectMacOSCapabilities();
        },
        .wasi, .freestanding => {
            caps = detectWasmCapabilities();
        },
        else => {
            caps = detectGenericCapabilities();
        },
    }
    
    // Common system info
    caps.cpu_count = @intCast(std.Thread.getCpuCount() catch 1);
    caps.page_size = 4096; // Standard page size, could be detected at runtime
    caps.cache_line_size = 64; // Standard cache line size
    
    return caps;
}

/// Linux capability detection with io_uring version checking
fn detectLinuxCapabilities() PlatformCapabilities {
    var caps = PlatformCapabilities{};
    
    if (builtin.os.tag == .linux) {
        // Check io_uring availability
        caps.has_io_uring = checkIoUringSupport();
        if (caps.has_io_uring) {
            caps.io_uring_version = getIoUringVersion();
            caps.supports_zero_copy = caps.io_uring_version >= 59; // Linux 5.9+
            caps.supports_vectorized_io = true;
            caps.max_concurrent_ops = 32768; // High-performance io_uring limit
        }
        
        // Always available on Linux
        caps.has_epoll = true;
        caps.has_sendfile = true;
        caps.has_splice = true;
        caps.supports_unix_sockets = true;
        caps.supports_ipv6 = true;
        
        if (!caps.supports_vectorized_io) {
            caps.supports_vectorized_io = true; // epoll + readv/writev
        }
    }
    
    return caps;
}

/// Windows capability detection with IOCP support
fn detectWindowsCapabilities() PlatformCapabilities {
    var caps = PlatformCapabilities{};
    
    if (builtin.os.tag == .windows) {
        // IOCP is available on Windows NT+
        caps.has_iocp = true;
        caps.has_overlapped_io = true;
        caps.supports_vectorized_io = true; // WSASend/WSARecv with multiple buffers
        caps.supports_ipv6 = true;
        caps.max_concurrent_ops = 16384; // IOCP recommended limit
        
        // Windows-specific optimizations
        caps.supports_zero_copy = false; // Not implemented yet
    }
    
    return caps;
}

/// macOS capability detection with kqueue and GCD
fn detectMacOSCapabilities() PlatformCapabilities {
    var caps = PlatformCapabilities{};
    
    if (builtin.os.tag == .macos) {
        caps.has_kqueue = true;
        caps.has_gcd = true; // Grand Central Dispatch always available
        caps.supports_vectorized_io = true; // readv/writev support
        caps.supports_unix_sockets = true;
        caps.supports_ipv6 = true;
        caps.has_sendfile = true;
        caps.max_concurrent_ops = 8192; // kqueue typical limit
    }
    
    return caps;
}

/// WASM capability detection
fn detectWasmCapabilities() PlatformCapabilities {
    var caps = PlatformCapabilities{};
    
    if (builtin.os.tag == .wasi or builtin.os.tag == .freestanding) {
        // WASM environment
        caps.has_promises = true;
        caps.has_web_workers = true; // Assume modern browser
        caps.max_concurrent_ops = 256; // Lower limit for WASM
        caps.cpu_count = 1; // Single-threaded by default
        
        // Limited networking in WASM
        caps.supports_ipv6 = false;
        caps.supports_unix_sockets = false;
    }
    
    return caps;
}

/// Generic/fallback capability detection
fn detectGenericCapabilities() PlatformCapabilities {
    var caps = PlatformCapabilities{};
    
    // Conservative defaults for unknown platforms
    caps.supports_vectorized_io = true; // Most POSIX systems support readv/writev
    caps.supports_ipv6 = true;
    caps.max_concurrent_ops = 1024;
    
    return caps;
}

/// Check if io_uring is available on Linux
fn checkIoUringSupport() bool {
    if (builtin.os.tag != .linux) return false;
    
    // Try to create a minimal io_uring instance
    const fd = std.posix.openZ("/dev/null", .{}, 0) catch return false;
    defer std.posix.close(fd);
    
    // This would normally check io_uring_setup syscall
    // For now, assume modern Linux has it
    return true;
}

/// Get io_uring kernel version (simplified)
fn getIoUringVersion() u32 {
    // In real implementation, this would parse /proc/version or use uname
    // For now, assume a modern kernel version
    return 60; // Represents Linux 6.0+ with full io_uring support
}

/// Select optimal runtime backend for current platform
pub fn selectOptimalBackend(caps: PlatformCapabilities) RuntimeBackend {
    return switch (builtin.os.tag) {
        .linux => {
            if (caps.has_io_uring and caps.io_uring_version >= 58) {
                return .linux_io_uring; // Prefer io_uring for Linux 5.8+
            } else if (caps.has_epoll) {
                return .linux_epoll; // Fallback to epoll
            } else {
                return .posix_blocking;
            }
        },
        .windows => {
            if (caps.has_iocp) {
                return .windows_iocp; // Windows I/O Completion Ports
            } else {
                return .windows_select; // Fallback to select()
            }
        },
        .macos => {
            if (caps.has_kqueue) {
                return .macos_kqueue; // macOS kqueue with GCD
            } else {
                return .macos_poll; // Fallback to poll()
            }
        },
        .wasi, .freestanding => {
            if (caps.has_promises) {
                return .wasm_promise; // Promise-based async for WASM
            } else {
                return .wasm_stackless; // Stackless coroutines
            }
        },
        else => {
            return .generic_blocking; // Safe fallback for unknown platforms
        },
    };
}

/// Create platform-optimized runtime instance
pub fn createOptimalRuntime(allocator: std.mem.Allocator) !PlatformRuntime {
    const caps = detectCapabilities();
    const backend = selectOptimalBackend(caps);
    
    return PlatformRuntime{
        .backend = backend,
        .capabilities = caps,
        .allocator = allocator,
    };
}

/// Platform-specific runtime wrapper
pub const PlatformRuntime = struct {
    backend: RuntimeBackend,
    capabilities: PlatformCapabilities,
    allocator: std.mem.Allocator,
    
    const Self = @This();
    
    /// Get human-readable backend name
    pub fn getBackendName(self: *const Self) []const u8 {
        return switch (self.backend) {
            .linux_io_uring => "Linux io_uring (High Performance)",
            .linux_epoll => "Linux epoll",
            .windows_iocp => "Windows IOCP (High Performance)", 
            .windows_select => "Windows select()",
            .macos_kqueue => "macOS kqueue + GCD (High Performance)",
            .macos_poll => "macOS poll()",
            .wasm_promise => "WASM Promise-based",
            .wasm_stackless => "WASM Stackless",
            .posix_blocking => "POSIX Blocking I/O",
            .generic_blocking => "Generic Blocking I/O",
        };
    }
    
    /// Check if current backend supports high performance features
    pub fn isHighPerformance(self: *const Self) bool {
        return switch (self.backend) {
            .linux_io_uring, .windows_iocp, .macos_kqueue => true,
            else => false,
        };
    }
    
    /// Get recommended configuration for current platform
    pub fn getRecommendedConfig(self: *const Self) RuntimeConfig {
        return RuntimeConfig{
            .max_concurrent_ops = self.capabilities.max_concurrent_ops,
            .thread_count = @min(self.capabilities.cpu_count * 2, 16),
            .enable_zero_copy = self.capabilities.supports_zero_copy,
            .enable_vectorized_io = self.capabilities.supports_vectorized_io,
            .buffer_size = if (self.isHighPerformance()) 8192 else 4096,
            .queue_depth = if (self.isHighPerformance()) 1024 else 256,
        };
    }
    
    /// Print detailed platform information
    pub fn printPlatformInfo(self: *const Self) void {
        std.debug.print("\n🚀 Zsync v0.5.2 - Platform Runtime Information\n", .{});
        std.debug.print("=" ** 50 ++ "\n", .{});
        std.debug.print("Platform: {s}\n", .{@tagName(builtin.os.tag)});
        std.debug.print("Architecture: {s}\n", .{@tagName(builtin.cpu.arch)});
        std.debug.print("Backend: {s}\n", .{self.getBackendName()});
        std.debug.print("High Performance: {}\n", .{self.isHighPerformance()});
        
        std.debug.print("\n📊 Capabilities:\n", .{});
        std.debug.print("  CPU Cores: {}\n", .{self.capabilities.cpu_count});
        std.debug.print("  Max Concurrent Ops: {}\n", .{self.capabilities.max_concurrent_ops});
        std.debug.print("  Zero-copy I/O: {}\n", .{self.capabilities.supports_zero_copy});
        std.debug.print("  Vectorized I/O: {}\n", .{self.capabilities.supports_vectorized_io});
        std.debug.print("  IPv6 Support: {}\n", .{self.capabilities.supports_ipv6});
        
        if (builtin.os.tag == .linux) {
            std.debug.print("  io_uring: {} (v{})\n", .{ self.capabilities.has_io_uring, self.capabilities.io_uring_version });
            std.debug.print("  epoll: {}\n", .{self.capabilities.has_epoll});
        }
        
        if (builtin.os.tag == .windows) {
            std.debug.print("  IOCP: {}\n", .{self.capabilities.has_iocp});
            std.debug.print("  Overlapped I/O: {}\n", .{self.capabilities.has_overlapped_io});
        }
        
        if (builtin.os.tag == .macos) {
            std.debug.print("  kqueue: {}\n", .{self.capabilities.has_kqueue});
            std.debug.print("  Grand Central Dispatch: {}\n", .{self.capabilities.has_gcd});
        }
        
        const config = self.getRecommendedConfig();
        std.debug.print("\n⚙️ Recommended Configuration:\n", .{});
        std.debug.print("  Threads: {}\n", .{config.thread_count});
        std.debug.print("  Queue Depth: {}\n", .{config.queue_depth});
        std.debug.print("  Buffer Size: {} bytes\n", .{config.buffer_size});
        std.debug.print("=" ** 50 ++ "\n\n", .{});
    }
};

/// Runtime configuration optimized for platform
pub const RuntimeConfig = struct {
    max_concurrent_ops: u32,
    thread_count: u32,
    enable_zero_copy: bool,
    enable_vectorized_io: bool,
    buffer_size: usize,
    queue_depth: u32,
};