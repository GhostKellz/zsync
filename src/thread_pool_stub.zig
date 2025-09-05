//! Zsync Thread Pool Stub for WASM/WASI  
//! Provides compatible API but no actual threading functionality

const std = @import("std");
const io_interface = @import("io_interface.zig");

/// Stubbed ThreadPoolIo for WASM compatibility
pub const ThreadPoolIo = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator, thread_count: u32, buffer_size: u32) !ThreadPoolIo {
        _ = thread_count;
        _ = buffer_size;
        return ThreadPoolIo{ .allocator = allocator };
    }
    
    pub fn deinit(self: *ThreadPoolIo) void {
        _ = self;
    }
    
    pub fn io(self: *ThreadPoolIo) io_interface.Io {
        // Return a blocking I/O implementation as fallback
        var blocking = @import("blocking_io.zig").BlockingIo.init(self.allocator, 4096);
        return blocking.io();
    }
};

/// Stub error types
pub const ThreadPoolError = error{
    ThreadingNotAvailable,
    InitializationFailed,
};