//! Thread Pool Stub for WASM
//! WASM doesn't support native threads, so this provides a no-op implementation

const std = @import("std");
const io_interface = @import("io_interface.zig");

/// Stub ThreadPoolIo for WASM - no actual threading
pub const ThreadPoolIo = struct {
    allocator: std.mem.Allocator,
    thread_count: u32,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, thread_count: u32, _: u32) !Self {
        return Self{
            .allocator = allocator,
            .thread_count = thread_count,
        };
    }

    pub fn deinit(_: *Self) void {}

    pub fn io(_: *Self) io_interface.Io {
        // Return a blocking I/O interface for WASM
        return io_interface.Io{
            .vtable = undefined,
            .userdata = undefined,
        };
    }
};
