const std = @import("std");
const builtin = @import("builtin");

// Platform-specific imports
pub const Platform = switch (builtin.target.os.tag) {
    .linux => @import("platform/linux.zig"),
    .macos => @import("platform/macos.zig"),
    .windows => @import("platform/windows.zig"),
    .freestanding => if (builtin.target.cpu.arch.isWasm()) @import("platform/wasm.zig") else @compileError("Unsupported freestanding platform"),
    else => @compileError("Unsupported platform"),
};

// Architecture-specific imports
pub const Arch = switch (builtin.target.cpu.arch) {
    .x86_64 => @import("arch/x86_64.zig"),
    .aarch64 => @import("arch/aarch64.zig"),
    else => @import("arch/x86_64.zig"), // Fallback to x86_64 for unsupported archs
};

// Unified platform interface
pub const EventLoop = Platform.EventLoop;
pub const EventSource = Platform.EventSource;
pub const Timer = Platform.Timer;

// Architecture-specific context switching
pub const Context = Arch.Context;
pub const swapContext = Arch.swapContext;
pub const makeContext = Arch.makeContext;

// Platform detection
pub const current_os = builtin.target.os.tag;
pub const current_arch = builtin.target.cpu.arch;

pub const PlatformCapabilities = struct {
    has_io_uring: bool,
    has_epoll: bool,
    has_kqueue: bool,
    has_iocp: bool,
    has_wasm_apis: bool,
    has_workstealing: bool,
    max_threads: u32,
    
    pub fn detect() PlatformCapabilities {
        return switch (current_os) {
            .linux => PlatformCapabilities{
                .has_io_uring = true,
                .has_epoll = true,
                .has_kqueue = false,
                .has_iocp = false,
                .has_wasm_apis = false,
                .has_workstealing = true,
                .max_threads = Platform.getNumCpus() * 2,
            },
            .macos => PlatformCapabilities{
                .has_io_uring = false,
                .has_epoll = false,
                .has_kqueue = true,
                .has_iocp = false,
                .has_wasm_apis = false,
                .has_workstealing = true,
                .max_threads = Platform.getNumCpus() * 2,
            },
            .windows => PlatformCapabilities{
                .has_io_uring = false,
                .has_epoll = false,
                .has_kqueue = false,
                .has_iocp = true,
                .has_wasm_apis = false,
                .has_workstealing = true,
                .max_threads = Platform.getNumCpus() * 2,
            },
            .freestanding => if (builtin.target.cpu.arch.isWasm()) PlatformCapabilities{
                .has_io_uring = false,
                .has_epoll = false,
                .has_kqueue = false,
                .has_iocp = false,
                .has_wasm_apis = true,
                .has_workstealing = false,
                .max_threads = 1,
            } else PlatformCapabilities{
                .has_io_uring = false,
                .has_epoll = false,
                .has_kqueue = false,
                .has_iocp = false,
                .has_wasm_apis = false,
                .has_workstealing = false,
                .max_threads = 1,
            },
            else => PlatformCapabilities{
                .has_io_uring = false,
                .has_epoll = false,
                .has_kqueue = false,
                .has_iocp = false,
                .has_wasm_apis = false,
                .has_workstealing = false,
                .max_threads = 1,
            },
        };
    }
    
    pub fn getBestAsyncBackend(self: PlatformCapabilities) AsyncBackend {
        if (self.has_wasm_apis) return .wasm;
        if (self.has_io_uring) return .io_uring;
        if (self.has_kqueue) return .kqueue;
        if (self.has_iocp) return .iocp;
        if (self.has_epoll) return .epoll;
        return .blocking;
    }
};

pub const AsyncBackend = enum {
    wasm,
    io_uring,
    kqueue,
    iocp,
    epoll,
    blocking,
};

// Cross-platform async I/O operations
pub const AsyncOp = struct {
    backend: AsyncBackend,
    platform_data: union(AsyncBackend) {
        io_uring: struct {
            ring: *Platform.IoUring,
            user_data: u64,
        },
        kqueue: struct {
            fd: i32,
            udata: ?*anyopaque,
        },
        iocp: struct {
            completion_key: usize,
            overlapped: ?*anyopaque, // *windows.OVERLAPPED
        },
        epoll: struct {
            ep: *Platform.Epoll,
            fd: i32,
            events: u32,
        },
        blocking: void,
    },
    
    pub fn initRead(backend: AsyncBackend, fd: i32) AsyncOp {
        return AsyncOp{
            .backend = backend,
            .platform_data = switch (backend) {
                .kqueue => .{ .kqueue = .{ .fd = fd, .udata = null } },
                .epoll => .{ .epoll = .{ .ep = undefined, .fd = fd, .events = 0x001 } }, // EPOLLIN equivalent
                .iocp => .{ .iocp = .{ .completion_key = @intCast(fd), .overlapped = null } },
                .io_uring => .{ .io_uring = .{ .ring = undefined, .user_data = @intCast(fd) } },
                else => .{ .blocking = {} },
            },
        };
    }
    
    pub fn initWrite(backend: AsyncBackend, fd: i32) AsyncOp {
        return AsyncOp{
            .backend = backend,
            .platform_data = switch (backend) {
                .kqueue => .{ .kqueue = .{ .fd = fd, .udata = null } },
                .epoll => .{ .epoll = .{ .ep = undefined, .fd = fd, .events = 0x004 } }, // EPOLLOUT equivalent
                .iocp => .{ .iocp = .{ .completion_key = @intCast(fd), .overlapped = null } },
                .io_uring => .{ .io_uring = .{ .ring = undefined, .user_data = @intCast(fd) } },
                else => .{ .blocking = {} },
            },
        };
    }
};

// Cross-platform performance monitoring
pub const PerformanceCounters = struct {
    context_switches: u64,
    io_operations: u64,
    timer_fires: u64,
    memory_allocations: u64,
    
    pub fn init() PerformanceCounters {
        return PerformanceCounters{
            .context_switches = 0,
            .io_operations = 0,
            .timer_fires = 0,
            .memory_allocations = 0,
        };
    }
    
    pub fn incrementContextSwitches(self: *PerformanceCounters) void {
        _ = @atomicRmw(u64, &self.context_switches, .Add, 1, .monotonic);
    }
    
    pub fn incrementIoOperations(self: *PerformanceCounters) void {
        _ = @atomicRmw(u64, &self.io_operations, .Add, 1, .monotonic);
    }
    
    pub fn incrementTimerFires(self: *PerformanceCounters) void {
        _ = @atomicRmw(u64, &self.timer_fires, .Add, 1, .monotonic);
    }
    
    pub fn incrementMemoryAllocations(self: *PerformanceCounters) void {
        _ = @atomicRmw(u64, &self.memory_allocations, .Add, 1, .monotonic);
    }
    
    pub fn getReport(self: *const PerformanceCounters) void {
        std.debug.print(
            \\Performance Report:
            \\  Context Switches: {}
            \\  I/O Operations: {}
            \\  Timer Fires: {}
            \\  Memory Allocations: {}
            \\
        , .{
            self.context_switches,
            self.io_operations,
            self.timer_fires,
            self.memory_allocations,
        });
    }
};

// Cross-platform stack allocation
pub fn allocateStack(allocator: std.mem.Allocator) ![]align(4096) u8 {
    return Arch.allocateStack(allocator);
}

pub fn deallocateStack(allocator: std.mem.Allocator, stack: []u8) void {
    return Arch.deallocateStack(allocator, stack);
}

// Cross-platform memory barriers and atomics
pub inline fn memoryBarrier() void {
    Platform.memoryBarrier();
}

pub inline fn loadAcquire(comptime T: type, ptr: *const T) T {
    return Platform.loadAcquire(T, ptr);
}

pub inline fn storeRelease(comptime T: type, ptr: *T, value: T) void {
    Platform.storeRelease(T, ptr, value);
}

// Cross-platform thread utilities
pub fn setThreadAffinity(cpu: u32) !void {
    return Platform.setThreadAffinity(cpu);
}

pub fn getNumCpus() u32 {
    return Platform.getNumCpus();
}