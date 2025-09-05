//! Zsync v0.4.0 - Colorblind Async I/O Interface
//! Implements Zig's new async paradigm with true function colorblind design
//! Compatible with all execution models: blocking, thread pool, green threads, stackless

const std = @import("std");
const builtin = @import("builtin");

/// Execution mode selection for colorblind async
pub const IoMode = enum {
    blocking,   // Direct syscalls, C-equivalent performance
    evented,    // Event-driven with platform-specific optimizations
    auto,       // Runtime detection of optimal mode
};

/// Global execution mode (can be set at comptime or runtime)
pub var io_mode: IoMode = .auto;

/// Core error types for all I/O operations
pub const IoError = error{
    // Network errors
    WouldBlock,
    ConnectionClosed,
    ConnectionRefused,
    ConnectionReset,
    NetworkUnreachable,
    BrokenPipe,
    
    // File system errors
    AccessDenied,
    FileNotFound,
    IsDir,
    NotDir,
    NameTooLong,
    
    // Resource errors
    SystemResources,
    OutOfMemory,
    InvalidDescriptor,
    
    // Operation errors
    Interrupted,
    TimedOut,
    Cancelled,
    BufferTooSmall,
    
    // Generic
    Unexpected,
    NotSupported,
} || std.mem.Allocator.Error;

/// Result type for I/O operations
pub const IoResult = struct {
    bytes_transferred: usize,
    error_code: ?IoError = null,
};

/// Cancellation token for cooperative cancellation
pub const CancelToken = struct {
    cancelled: std.atomic.Value(bool),
    reason: CancelReason,
    parent: ?*CancelToken,
    children: std.ArrayList(*CancelToken),
    allocator: std.mem.Allocator,
    
    pub const CancelReason = enum {
        user_requested,
        timeout,
        parent_cancelled,
        resource_exhausted,
        error_occurred,
    };
    
    pub fn init(allocator: std.mem.Allocator, reason: CancelReason) !*CancelToken {
        const token = try allocator.create(CancelToken);
        token.* = CancelToken{
            .cancelled = std.atomic.Value(bool).init(false),
            .reason = reason,
            .parent = null,
            .children = std.ArrayList(*CancelToken){},
            .allocator = allocator,
        };
        return token;
    }
    
    pub fn deinit(self: *CancelToken) void {
        self.children.deinit(self.allocator);
        self.allocator.destroy(self);
    }
    
    pub fn cancel(self: *CancelToken) void {
        if (self.cancelled.swap(true, .acq_rel)) return; // Already cancelled
        
        // Cascade to children
        for (self.children.items) |child| {
            if (child.reason == .parent_cancelled) {
                child.cancel();
            }
        }
    }
    
    pub fn isCancelled(self: *const CancelToken) bool {
        return self.cancelled.load(.acquire);
    }
    
    pub fn addChild(self: *CancelToken, child: *CancelToken) !void {
        child.parent = self;
        try self.children.append(self.allocator, child);
    }
};

/// Modern Future with advanced cancellation and combinators
pub const Future = struct {
    vtable: *const FutureVTable,
    context: *anyopaque,
    cancel_token: ?*CancelToken,
    state: std.atomic.Value(State),
    
    pub const State = enum(u8) {
        pending = 0,
        ready = 1,
        cancelled = 2,
        error_state = 3,
    };
    
    pub const PollResult = union(enum) {
        pending,
        ready: void,
        cancelled,
        err: IoError,
    };
    
    pub const FutureVTable = struct {
        poll: *const fn (context: *anyopaque) PollResult,
        cancel: *const fn (context: *anyopaque) void,
        destroy: *const fn (context: *anyopaque, allocator: std.mem.Allocator) void,
    };
    
    pub fn init(vtable: *const FutureVTable, context: *anyopaque) Future {
        return Future{
            .vtable = vtable,
            .context = context,
            .cancel_token = null,
            .state = std.atomic.Value(State).init(.pending),
        };
    }
    
    /// Poll the future for completion (non-blocking)
    pub fn poll(self: *Future) PollResult {
        if (self.cancel_token) |token| {
            if (token.isCancelled()) {
                self.state.store(.cancelled, .release);
                return .cancelled;
            }
        }
        
        const result = self.vtable.poll(self.context);
        switch (result) {
            .ready => self.state.store(.ready, .release),
            .cancelled => self.state.store(.cancelled, .release),
            .err => self.state.store(.error_state, .release),
            .pending => {},
        }
        return result;
    }
    
    /// Colorblind await - works in both sync and async contexts
    pub fn await(self: *Future) IoError!void {
        while (true) {
            switch (self.poll()) {
                .ready => return,
                .cancelled => return IoError.Cancelled,
                .err => |e| return e,
                .pending => {
                    // Yield based on execution mode
                    switch (io_mode) {
                        .blocking => std.Thread.sleep(100_000), // 100μs cooperative yield
                        .evented => yield(), // Platform-specific yield
                        .auto => autoYield(),
                    }
                },
            }
        }
    }
    
    /// Cancel the future
    pub fn cancel(self: *Future) void {
        if (self.cancel_token) |token| {
            token.cancel();
        }
        self.vtable.cancel(self.context);
        self.state.store(.cancelled, .release);
    }
    
    /// Destroy the future and clean up resources
    pub fn destroy(self: *Future, allocator: std.mem.Allocator) void {
        if (self.cancel_token) |token| {
            token.deinit();
        }
        self.vtable.destroy(self.context, allocator);
    }
    
    /// Check if future is completed in any final state
    pub fn isCompleted(self: *const Future) bool {
        const current_state = self.state.load(.acquire);
        return current_state != .pending;
    }
    
    /// Set cancellation token
    pub fn setCancelToken(self: *Future, token: *CancelToken) void {
        self.cancel_token = token;
    }
};

/// High-performance buffer for I/O operations
pub const IoBuffer = struct {
    data: []u8,
    len: usize,
    capacity: usize,
    
    pub fn init(data: []u8) IoBuffer {
        return IoBuffer{
            .data = data,
            .len = 0,
            .capacity = data.len,
        };
    }
    
    pub fn slice(self: *const IoBuffer) []const u8 {
        return self.data[0..self.len];
    }
    
    pub fn available(self: *const IoBuffer) []u8 {
        return self.data[self.len..self.capacity];
    }
    
    pub fn advance(self: *IoBuffer, n: usize) void {
        self.len = @min(self.len + n, self.capacity);
    }
    
    pub fn reset(self: *IoBuffer) void {
        self.len = 0;
    }
    
    pub fn remainingCapacity(self: *const IoBuffer) usize {
        return self.capacity - self.len;
    }
};

/// The core Io interface - caller-provided like Allocator
/// Supports colorblind async: same code works sync/async
pub const Io = struct {
    vtable: *const IoVTable,
    context: *anyopaque,
    
    pub const IoVTable = struct {
        // Basic I/O operations
        read: *const fn (context: *anyopaque, buffer: []u8) IoError!Future,
        write: *const fn (context: *anyopaque, data: []const u8) IoError!Future,
        
        // Vectorized I/O for performance
        readv: *const fn (context: *anyopaque, buffers: []IoBuffer) IoError!Future,
        writev: *const fn (context: *anyopaque, data: []const []const u8) IoError!Future,
        
        // Zero-copy operations
        send_file: *const fn (context: *anyopaque, src_fd: std.posix.fd_t, offset: u64, count: u64) IoError!Future,
        copy_file_range: *const fn (context: *anyopaque, src_fd: std.posix.fd_t, dst_fd: std.posix.fd_t, count: u64) IoError!Future,
        
        // Network operations
        accept: *const fn (context: *anyopaque, listener_fd: std.posix.fd_t) IoError!Future,
        connect: if (builtin.target.cpu.arch == .wasm32) 
            *const fn (context: *anyopaque, fd: std.posix.fd_t, address: []const u8) IoError!Future
        else
            *const fn (context: *anyopaque, fd: std.posix.fd_t, address: std.net.Address) IoError!Future,
        
        // Resource management
        close: *const fn (context: *anyopaque, fd: std.posix.fd_t) IoError!Future,
        shutdown: *const fn (context: *anyopaque) void,
        
        // Execution model information
        get_mode: *const fn (context: *anyopaque) IoMode,
        supports_vectorized: *const fn (context: *anyopaque) bool,
        supports_zero_copy: *const fn (context: *anyopaque) bool,
        get_allocator: *const fn (context: *anyopaque) std.mem.Allocator,
    };
    
    pub fn init(vtable: *const IoVTable, context: *anyopaque) Io {
        return Io{
            .vtable = vtable,
            .context = context,
        };
    }
    
    /// Colorblind async read - works in any execution context
    pub fn read(self: *Io, buffer: []u8) IoError!Future {
        return self.vtable.read(self.context, buffer);
    }
    
    /// Colorblind async write - works in any execution context
    pub fn write(self: *Io, data: []const u8) IoError!Future {
        return self.vtable.write(self.context, data);
    }
    
    /// High-performance vectorized read
    pub fn readv(self: *Io, buffers: []IoBuffer) IoError!Future {
        if (self.vtable.supports_vectorized(self.context)) {
            return self.vtable.readv(self.context, buffers);
        }
        // Fallback to multiple reads
        return self.read(buffers[0].available());
    }
    
    /// High-performance vectorized write
    pub fn writev(self: *Io, data: []const []const u8) IoError!Future {
        if (self.vtable.supports_vectorized(self.context)) {
            return self.vtable.writev(self.context, data);
        }
        // Fallback to multiple writes
        return self.write(data[0]);
    }
    
    /// Zero-copy file transfer
    pub fn sendFile(self: *Io, src_fd: std.posix.fd_t, offset: u64, count: u64) IoError!Future {
        if (self.vtable.supports_zero_copy(self.context)) {
            return self.vtable.send_file(self.context, src_fd, offset, count);
        }
        return IoError.NotSupported;
    }
    
    /// Zero-copy between file descriptors
    pub fn copyFileRange(self: *Io, src_fd: std.posix.fd_t, dst_fd: std.posix.fd_t, count: u64) IoError!Future {
        if (self.vtable.supports_zero_copy(self.context)) {
            return self.vtable.copy_file_range(self.context, src_fd, dst_fd, count);
        }
        return IoError.NotSupported;
    }
    
    /// Accept incoming connections
    pub fn accept(self: *Io, listener_fd: std.posix.fd_t) IoError!Future {
        return self.vtable.accept(self.context, listener_fd);
    }
    
    /// Connect to remote address
    pub fn connect(self: *Io, fd: std.posix.fd_t, address: std.net.Address) IoError!Future {
        return self.vtable.connect(self.context, fd, address);
    }
    
    /// Close file descriptor
    pub fn close(self: *Io, fd: std.posix.fd_t) IoError!Future {
        return self.vtable.close(self.context, fd);
    }
    
    /// Shutdown the I/O system
    pub fn shutdown(self: *Io) void {
        self.vtable.shutdown(self.context);
    }
    
    /// Get current execution mode
    pub fn getMode(self: *const Io) IoMode {
        return self.vtable.get_mode(self.context);
    }
    
    /// Check if vectorized I/O is supported
    pub fn supportsVectorized(self: *const Io) bool {
        return self.vtable.supports_vectorized(self.context);
    }
    
    /// Check if zero-copy operations are supported
    pub fn supportsZeroCopy(self: *const Io) bool {
        return self.vtable.supports_zero_copy(self.context);
    }
    
    /// Get the allocator used by this I/O implementation
    pub fn getAllocator(self: *const Io) std.mem.Allocator {
        return self.vtable.get_allocator(self.context);
    }
    
    /// Convenience method for simple blocking read
    pub fn readSync(self: *Io, buffer: []u8) IoError!usize {
        var future = try self.read(buffer);
        defer future.destroy(std.heap.page_allocator);
        try future.await();
        return buffer.len; // Simplified - real implementation would return actual bytes read
    }
    
    /// Convenience method for simple blocking write
    pub fn writeSync(self: *Io, data: []const u8) IoError!usize {
        var future = try self.write(data);
        defer future.destroy(std.heap.page_allocator);
        try future.await();
        return data.len;
    }
};

/// Future combinators for advanced async patterns
pub const Combinators = struct {
    /// Race multiple futures, return first to complete
    pub fn race(allocator: std.mem.Allocator, futures: []Future) !Future {
        const RaceContext = struct {
            futures: []Future,
            completed_index: ?usize,
            allocator: std.mem.Allocator,
            
            fn poll(context: *anyopaque) Future.PollResult {
                const self: *@This() = @ptrCast(@alignCast(context));
                
                for (self.futures, 0..) |*future, i| {
                    switch (future.poll()) {
                        .ready => {
                            self.completed_index = i;
                            return .ready;
                        },
                        .cancelled => return .cancelled,
                        .err => |e| return .{ .err = e },
                        .pending => continue,
                    }
                }
                return .pending;
            }
            
            fn cancel(context: *anyopaque) void {
                const self: *@This() = @ptrCast(@alignCast(context));
                for (self.futures) |*future| {
                    future.cancel();
                }
            }
            
            fn destroy(context: *anyopaque, alloc: std.mem.Allocator) void {
                const self: *@This() = @ptrCast(@alignCast(context));
                // Note: individual futures should be cleaned up by the caller
                // as they may have been created with different allocators
                alloc.destroy(self);
            }
        };
        
        const context = try allocator.create(RaceContext);
        context.* = RaceContext{
            .futures = futures,
            .completed_index = null,
            .allocator = allocator,
        };
        
        const vtable = Future.FutureVTable{
            .poll = RaceContext.poll,
            .cancel = RaceContext.cancel,
            .destroy = RaceContext.destroy,
        };
        
        return Future.init(&vtable, context);
    }
    
    /// Wait for all futures to complete
    pub fn all(allocator: std.mem.Allocator, futures: []Future) !Future {
        const AllContext = struct {
            futures: []Future,
            completed_count: std.atomic.Value(usize),
            allocator: std.mem.Allocator,
            
            fn poll(context: *anyopaque) Future.PollResult {
                const self: *@This() = @ptrCast(@alignCast(context));
                var ready_count: usize = 0;
                
                for (self.futures) |*future| {
                    switch (future.poll()) {
                        .ready => ready_count += 1,
                        .cancelled => return .cancelled,
                        .err => |e| return .{ .err = e },
                        .pending => {},
                    }
                }
                
                if (ready_count == self.futures.len) {
                    return .ready;
                }
                return .pending;
            }
            
            fn cancel(context: *anyopaque) void {
                const self: *@This() = @ptrCast(@alignCast(context));
                for (self.futures) |*future| {
                    future.cancel();
                }
            }
            
            fn destroy(context: *anyopaque, alloc: std.mem.Allocator) void {
                const self: *@This() = @ptrCast(@alignCast(context));
                // Note: individual futures should be cleaned up by the caller
                // as they may have been created with different allocators
                alloc.destroy(self);
            }
        };
        
        const context = try allocator.create(AllContext);
        context.* = AllContext{
            .futures = futures,
            .completed_count = std.atomic.Value(usize).init(0),
            .allocator = allocator,
        };
        
        const vtable = Future.FutureVTable{
            .poll = AllContext.poll,
            .cancel = AllContext.cancel,
            .destroy = AllContext.destroy,
        };
        
        return Future.init(&vtable, context);
    }
    
    /// Add timeout to any future
    pub fn timeout(allocator: std.mem.Allocator, future: Future, timeout_ms: u64) !Future {
        const TimeoutContext = struct {
            future: Future,
            deadline_ns: u64,
            allocator: std.mem.Allocator,
            
            fn poll(context: *anyopaque) Future.PollResult {
                const self: *@This() = @ptrCast(@alignCast(context));
                
                // Check timeout first
                if (std.time.nanoTimestamp() > self.deadline_ns) {
                    self.future.cancel();
                    return .{ .err = IoError.TimedOut };
                }
                
                return self.future.poll();
            }
            
            fn cancel(context: *anyopaque) void {
                const self: *@This() = @ptrCast(@alignCast(context));
                self.future.cancel();
            }
            
            fn destroy(context: *anyopaque, alloc: std.mem.Allocator) void {
                const self: *@This() = @ptrCast(@alignCast(context));
                self.future.destroy(alloc);
                alloc.destroy(self);
            }
        };
        
        const context = try allocator.create(TimeoutContext);
        context.* = TimeoutContext{
            .future = future,
            .deadline_ns = @intCast(std.time.nanoTimestamp() + @as(i128, timeout_ms * std.time.ns_per_ms)),
            .allocator = allocator,
        };
        
        const vtable = Future.FutureVTable{
            .poll = TimeoutContext.poll,
            .cancel = TimeoutContext.cancel,
            .destroy = TimeoutContext.destroy,
        };
        
        return Future.init(&vtable, context);
    }
};

// Platform-specific yield implementations
fn yield() void {
    switch (builtin.os.tag) {
        .linux => std.Thread.sleep(1000), // Simple yield
        .windows => std.Thread.sleep(1000), // Windows yield not easily accessible
        .macos => std.Thread.sleep(1000), // macOS doesn't have direct yield
        else => std.Thread.sleep(1000),
    }
}

fn autoYield() void {
    // Detect optimal yield strategy at runtime
    if (std.Thread.getCpuCount() catch 1 > 1) {
        yield(); // Multi-core: proper yield
    } else {
        std.Thread.sleep(10_000); // Single-core: longer sleep
    }
}

// Tests
test "Future basic operations" {
    const testing = std.testing;
    
    const TestContext = struct {
        ready: bool = false,
        
        fn poll(context: *anyopaque) Future.PollResult {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.ready) return .ready;
            return .pending;
        }
        
        fn cancel(_: *anyopaque) void {}
        fn destroy(_: *anyopaque, _: std.mem.Allocator) void {}
    };
    
    var context = TestContext{};
    const vtable = Future.FutureVTable{
        .poll = TestContext.poll,
        .cancel = TestContext.cancel,
        .destroy = TestContext.destroy,
    };
    
    var future = Future.init(&vtable, &context);
    try testing.expect(future.poll() == .pending);
    
    context.ready = true;
    try testing.expect(future.poll() == .ready);
    try testing.expect(future.isCompleted());
}

test "CancelToken operations" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    const parent = try CancelToken.init(allocator, .user_requested);
    defer parent.deinit();
    
    const child = try CancelToken.init(allocator, .parent_cancelled);
    defer child.deinit();
    
    try parent.addChild(child);
    
    try testing.expect(!parent.isCancelled());
    try testing.expect(!child.isCancelled());
    
    parent.cancel();
    
    try testing.expect(parent.isCancelled());
    try testing.expect(child.isCancelled());
}