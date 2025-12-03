//! zsync- Conditional Platform Imports
//! Prevents platform-specific code from being compiled on wrong targets

const std = @import("std");
const builtin = @import("builtin");

// Conditional imports based on platform
pub const linux = struct {
    pub const io_uring = if (builtin.os.tag == .linux) @import("io_uring.zig") else void;
    pub const green_threads = if (builtin.os.tag == .linux) @import("green_threads.zig") else void;
    pub const platform_linux = if (builtin.os.tag == .linux) @import("platform/linux.zig") else void;
};

pub const windows = struct {
    pub const iocp = if (builtin.os.tag == .windows) @import("platform/windows.zig") else void;
    pub const overlapped_io = if (builtin.os.tag == .windows) void else void; // TODO: Implement
};

pub const macos = struct {
    pub const kqueue = if (builtin.os.tag == .macos) @import("platform/macos.zig") else void;
    pub const gcd = if (builtin.os.tag == .macos) void else void; // TODO: Implement
};

pub const wasm = struct {
    pub const stackless = if (builtin.os.tag == .wasi or builtin.os.tag == .freestanding) @import("platform/wasm.zig") else void;
    pub const promises = if (builtin.os.tag == .wasi or builtin.os.tag == .freestanding) void else void; // TODO: Implement
};

// Always available cross-platform implementations
pub const blocking_io = @import("blocking_io.zig");
pub const io_interface = @import("io_interface.zig");
pub const runtime_factory = @import("runtime_factory.zig");
pub const platform_runtime = @import("platform_runtime.zig");

// Platform-specific type helpers
pub fn PlatformSpecificType(comptime T: type) type {
    return if (T == void) struct {} else T;
}

// Check if a platform-specific feature is available
pub fn isAvailable(comptime platform_module: anytype) bool {
    return @TypeOf(platform_module) != void;
}