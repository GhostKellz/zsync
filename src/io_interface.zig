//! Modern Io interface following Zig's new async I/O architecture
//! Provides vtable-based dispatch with execution model independence

const std = @import("std");
const builtin = @import("builtin");

/// I/O operation errors
pub const IoError = error{
    WouldBlock,
    ConnectionClosed,
    BrokenPipe,
    AccessDenied,
    SystemResources,
    Interrupted,
    InvalidDescriptor,
    NetworkUnreachable,
    TimedOut,
    Cancelled,
    BufferTooSmall,
} || std.mem.Allocator.Error;

/// Future represents a pending asynchronous operation
pub const Future = struct {
    vtable: *const FutureVTable,
    context: *anyopaque,
    cancelled: std.atomic.Value(bool),
    
    const Self = @This();
    
    pub const FutureVTable = struct {
        poll: *const fn (context: *anyopaque) IoError!PollResult,
        cancel: *const fn (context: *anyopaque) void,
        destroy: *const fn (context: *anyopaque, allocator: std.mem.Allocator) void,
    };
    
    pub const PollResult = enum {
        pending,
        ready,
    };
    
    /// Initialize a future
    pub fn init(vtable: *const FutureVTable, context: *anyopaque) Self {
        return Self{
            .vtable = vtable,
            .context = context,
            .cancelled = std.atomic.Value(bool).init(false),
        };
    }
    
    /// Poll the future for completion
    pub fn poll(self: *Self) IoError!PollResult {
        if (self.cancelled.load(.acquire)) {
            return IoError.Cancelled;
        }
        return self.vtable.poll(self.context);
    }
    
    /// Cancel the future
    pub fn cancel(self: *Self) void {
        if (!self.cancelled.swap(true, .acq_rel)) {
            self.vtable.cancel(self.context);
        }
    }
    
    /// Check if cancelled
    pub fn isCancelled(self: *Self) bool {
        return self.cancelled.load(.acquire);
    }
    
    /// Destroy the future
    pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
        self.vtable.destroy(self.context, allocator);
    }
    
    /// Await the future until completion (blocking version)
    pub fn await(self: *Self) IoError!void {
        while (true) {
            switch (try self.poll()) {
                .ready => return,
                .pending => {
                    std.time.sleep(100_000); // 100μs cooperative yield
                    continue;
                },
            }
        }
    }
};

/// Buffer for I/O operations
pub const IoBuffer = struct {
    data: []u8,
    len: usize,
    
    const Self = @This();
    
    pub fn init(data: []u8) Self {
        return Self{
            .data = data,
            .len = 0,
        };
    }
    
    pub fn slice(self: *const Self) []const u8 {
        return self.data[0..self.len];
    }
    
    pub fn available(self: *const Self) []u8 {
        return self.data[self.len..];
    }
    
    pub fn advance(self: *Self, n: usize) void {
        self.len = @min(self.len + n, self.data.len);
    }
    
    pub fn reset(self: *Self) void {
        self.len = 0;
    }
};

/// Modern Io interface with vtable dispatch
pub const Io = struct {
    vtable: *const IoVTable,
    context: *anyopaque,
    
    const Self = @This();
    
    pub const IoVTable = struct {
        // Basic I/O operations
        read: *const fn (context: *anyopaque, buffer: []u8) IoError!Future,
        write: *const fn (context: *anyopaque, data: []const u8) IoError!Future,
        
        // Vectorized I/O operations
        readv: *const fn (context: *anyopaque, buffers: []IoBuffer) IoError!Future,
        writev: *const fn (context: *anyopaque, buffers: []const []const u8) IoError!Future,
        
        // Semantic operations
        send_file: *const fn (context: *anyopaque, src_fd: std.posix.fd_t, offset: u64, count: u64) IoError!Future,
        copy_file_range: *const fn (context: *anyopaque, src_fd: std.posix.fd_t, dst_fd: std.posix.fd_t, count: u64) IoError!Future,
        
        // Connection operations
        accept: *const fn (context: *anyopaque, listener_fd: std.posix.fd_t) IoError!Future,
        connect: *const fn (context: *anyopaque, fd: std.posix.fd_t, address: std.net.Address) IoError!Future,
        
        // Shutdown and cleanup
        close: *const fn (context: *anyopaque, fd: std.posix.fd_t) IoError!Future,
        shutdown: *const fn (context: *anyopaque) void,
    };
    
    /// Initialize Io interface
    pub fn init(vtable: *const IoVTable, context: *anyopaque) Self {
        return Self{
            .vtable = vtable,
            .context = context,
        };
    }
    
    /// Async read operation
    pub fn async_read(self: *Self, buffer: []u8) IoError!Future {
        return self.vtable.read(self.context, buffer);
    }
    
    /// Async write operation  
    pub fn async_write(self: *Self, data: []const u8) IoError!Future {
        return self.vtable.write(self.context, data);
    }
    
    /// Vectorized read operation
    pub fn async_readv(self: *Self, buffers: []IoBuffer) IoError!Future {
        return self.vtable.readv(self.context, buffers);
    }
    
    /// Vectorized write operation
    pub fn async_writev(self: *Self, buffers: []const []const u8) IoError!Future {
        return self.vtable.writev(self.context, buffers);
    }
    
    /// High-performance file sending
    pub fn async_send_file(self: *Self, src_fd: std.posix.fd_t, offset: u64, count: u64) IoError!Future {
        return self.vtable.send_file(self.context, src_fd, offset, count);
    }
    
    /// Copy between file descriptors
    pub fn async_copy_file_range(self: *Self, src_fd: std.posix.fd_t, dst_fd: std.posix.fd_t, count: u64) IoError!Future {
        return self.vtable.copy_file_range(self.context, src_fd, dst_fd, count);
    }
    
    /// Accept incoming connections
    pub fn async_accept(self: *Self, listener_fd: std.posix.fd_t) IoError!Future {
        return self.vtable.accept(self.context, listener_fd);
    }
    
    /// Connect to remote address
    pub fn async_connect(self: *Self, fd: std.posix.fd_t, address: std.net.Address) IoError!Future {
        return self.vtable.connect(self.context, fd, address);
    }
    
    /// Close file descriptor
    pub fn async_close(self: *Self, fd: std.posix.fd_t) IoError!Future {
        return self.vtable.close(self.context, fd);
    }
    
    /// Shutdown the I/O system
    pub fn shutdown(self: *Self) void {
        self.vtable.shutdown(self.context);
    }
    
    /// Convenience method for simple blocking read
    pub fn read(self: *Self, buffer: []u8) IoError!usize {
        var future = try self.async_read(buffer);
        defer future.destroy(std.heap.page_allocator); // TODO: Pass proper allocator
        try future.await();
        return buffer.len; // Simplified for demo
    }
    
    /// Convenience method for simple blocking write
    pub fn write(self: *Self, data: []const u8) IoError!usize {
        var future = try self.async_write(data);
        defer future.destroy(std.heap.page_allocator); // TODO: Pass proper allocator  
        try future.await();
        return data.len; // Simplified for demo
    }
};

/// Combined Io operations result
pub const IoResult = struct {
    bytes_transferred: usize,
    error_code: ?IoError = null,
    
    pub fn isSuccess(self: *const @This()) bool {
        return self.error_code == null;
    }
    
    pub fn getError(self: *const @This()) ?IoError {
        return self.error_code;
    }
};

// Tests
test "Future creation and cancellation" {
    const testing = std.testing;
    
    const TestContext = struct {
        cancelled: bool = false,
        
        fn poll(_: *anyopaque) IoError!Future.PollResult {
            return .pending;
        }
        
        fn cancel(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.cancelled = true;
        }
        
        fn destroy(_: *anyopaque, _: std.mem.Allocator) void {}
    };
    
    var context = TestContext{};
    const vtable = Future.FutureVTable{
        .poll = TestContext.poll,
        .cancel = TestContext.cancel,
        .destroy = TestContext.destroy,
    };
    
    var future = Future.init(&vtable, &context);
    try testing.expect(!future.isCancelled());
    
    future.cancel();
    try testing.expect(future.isCancelled());
    try testing.expect(context.cancelled);
}

test "IoBuffer operations" {
    const testing = std.testing;
    
    var buffer_data: [1024]u8 = undefined;
    var buffer = IoBuffer.init(&buffer_data);
    
    try testing.expect(buffer.slice().len == 0);
    try testing.expect(buffer.available().len == 1024);
    
    buffer.advance(100);
    try testing.expect(buffer.slice().len == 100);
    try testing.expect(buffer.available().len == 924);
    
    buffer.reset();
    try testing.expect(buffer.slice().len == 0);
}