//! zsync- Colorblind Async I/O Interface
//! Implements Zig's new async paradigm with true function colorblind design
//! Compatible with all execution models: blocking, thread pool, green threads, stackless

const std = @import("std");
const builtin = @import("builtin");
const compat = @import("compat/thread.zig");

/// Sleep for specified seconds and nanoseconds using syscall
fn nanosleepNs(sec: isize, nsec: isize) void {
    if (builtin.os.tag == .linux) {
        const ts = std.os.linux.timespec{ .sec = sec, .nsec = nsec };
        _ = std.os.linux.nanosleep(&ts, null);
    }
}

/// Execution mode selection for colorblind async
pub const IoMode = enum {
    blocking, // Direct syscalls, C-equivalent performance
    evented, // Event-driven with platform-specific optimizations
    auto, // Runtime detection of optimal mode
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
            .children = .empty,
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
    allocator: std.mem.Allocator,

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
        get_result: ?*const fn (context: *anyopaque) ?IoResult = null,
    };

    pub fn init(allocator: std.mem.Allocator, vtable: *const FutureVTable, context: *anyopaque) Future {
        return Future{
            .vtable = vtable,
            .context = context,
            .cancel_token = null,
            .state = std.atomic.Value(State).init(.pending),
            .allocator = allocator,
        };
    }

    pub fn getAllocator(self: *const Future) std.mem.Allocator {
        return self.allocator;
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
                        .blocking => nanosleepNs(0, 100_000), // 100μs cooperative yield
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

    /// Destroy the future and clean up resources using stored allocator
    pub fn destroy(self: *Future) void {
        if (self.cancel_token) |token| {
            token.deinit();
        }
        self.vtable.destroy(self.context, self.allocator);
    }

    /// Return backend-specific completion information when available.
    pub fn getResult(self: *Future) ?IoResult {
        const get_result = self.vtable.get_result orelse return null;
        return get_result(self.context);
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
            *const fn (context: *anyopaque, fd: std.posix.fd_t, address: *const std.posix.sockaddr, addr_len: std.posix.socklen_t) IoError!Future,

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
    /// Returns NotSupported if backend doesn't support vectorized I/O
    pub fn readv(self: *Io, buffers: []IoBuffer) IoError!Future {
        if (self.vtable.supports_vectorized(self.context)) {
            return self.vtable.readv(self.context, buffers);
        }
        return IoError.NotSupported;
    }

    /// High-performance vectorized write
    /// Returns NotSupported if backend doesn't support vectorized I/O
    pub fn writev(self: *Io, data: []const []const u8) IoError!Future {
        if (self.vtable.supports_vectorized(self.context)) {
            return self.vtable.writev(self.context, data);
        }
        return IoError.NotSupported;
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
        if (builtin.target.cpu.arch == .wasm32) {
            return IoError.NotSupported;
        }
        return self.vtable.connect(self.context, fd, &address.any, address.getOsSockLen());
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

    /// Convenience method for simple blocking read.
    ///
    /// Returns the actual byte count when the backend exposes completion result
    /// information. Backends that do not expose a typed result still fall back to
    /// `buffer.len` after a successful await.
    pub fn readSync(self: *Io, buffer: []u8) IoError!usize {
        var future = try self.read(buffer);
        defer future.destroy();
        try future.await();
        if (future.getResult()) |result| return result.bytes_transferred;
        return buffer.len; // NOTE: Returns requested length, not actual bytes read
    }

    /// Convenience method for simple blocking write.
    ///
    /// Returns the actual byte count when the backend exposes completion result
    /// information. Backends that do not expose a typed result still fall back to
    /// `data.len` after a successful await.
    pub fn writeSync(self: *Io, data: []const u8) IoError!usize {
        var future = try self.write(data);
        defer future.destroy();
        try future.await();
        if (future.getResult()) |result| return result.bytes_transferred;
        return data.len; // NOTE: Returns requested length, not actual bytes written
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

        return Future.init(allocator, &vtable, context);
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

        return Future.init(allocator, &vtable, context);
    }

    /// Add timeout to any future
    pub fn timeout(allocator: std.mem.Allocator, future: Future, timeout_ms: u64) !Future {
        const TimeoutContext = struct {
            future: Future,
            start_time: compat.Instant,
            timeout_ns: u64,
            allocator: std.mem.Allocator,

            fn poll(context: *anyopaque) Future.PollResult {
                const self: *@This() = @ptrCast(@alignCast(context));

                // Check timeout first
                const now = compat.Instant.now() catch unreachable;
                const elapsed = now.since(self.start_time);
                if (elapsed >= self.timeout_ns) {
                    self.future.cancel();
                    return .{ .err = IoError.TimedOut };
                }

                return self.future.poll();
            }

            fn cancel(context: *anyopaque) void {
                const self: *@This() = @ptrCast(@alignCast(context));
                self.future.cancel();
            }

            fn destroy(context: *anyopaque, _: std.mem.Allocator) void {
                const self: *@This() = @ptrCast(@alignCast(context));
                self.future.destroy();
                self.allocator.destroy(self);
            }
        };

        const context = try allocator.create(TimeoutContext);
        const now = compat.Instant.now() catch unreachable;
        context.* = TimeoutContext{
            .future = future,
            .start_time = now,
            .timeout_ns = timeout_ms * std.time.ns_per_ms,
            .allocator = allocator,
        };

        const vtable = Future.FutureVTable{
            .poll = TimeoutContext.poll,
            .cancel = TimeoutContext.cancel,
            .destroy = TimeoutContext.destroy,
        };

        return Future.init(allocator, &vtable, context);
    }
};

// Platform-specific yield implementations
fn yield() void {
    nanosleepNs(0, 1000); // Simple yield
}

fn autoYield() void {
    // Detect optimal yield strategy at runtime
    if (std.Thread.getCpuCount() catch 1 > 1) {
        yield(); // Multi-core: proper yield
    } else {
        nanosleepNs(0, 10_000); // Single-core: longer sleep
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

    var future = Future.init(testing.allocator, &vtable, &context);
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

test "Combinators.timeout returns TimedOut" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create a future that stays pending forever
    const PendingContext = struct {
        fn poll(_: *anyopaque) Future.PollResult {
            return .pending;
        }
        fn cancel(_: *anyopaque) void {}
        fn destroy(_: *anyopaque, _: std.mem.Allocator) void {}
    };

    const vtable = Future.FutureVTable{
        .poll = PendingContext.poll,
        .cancel = PendingContext.cancel,
        .destroy = PendingContext.destroy,
    };

    var ctx: u8 = 0;
    const inner_future = Future.init(allocator, &vtable, &ctx);

    // Wrap with 1ms timeout
    var timeout_future = try Combinators.timeout(allocator, inner_future, 1);
    defer timeout_future.destroy();

    // Wait a bit for timeout to trigger
    const ts = std.os.linux.timespec{ .sec = 0, .nsec = 5 * std.time.ns_per_ms };
    _ = std.os.linux.nanosleep(&ts, null);

    // Poll should return TimedOut error
    const result = timeout_future.poll();
    try testing.expect(result == .err);
    try testing.expect(result.err == IoError.TimedOut);
}

test "readSync and writeSync use backend result when available" {
    const testing = std.testing;

    const TestContext = struct {
        result: IoResult,

        fn poll(_: *anyopaque) Future.PollResult {
            return .ready;
        }

        fn cancel(_: *anyopaque) void {}

        fn destroy(_: *anyopaque, _: std.mem.Allocator) void {}

        fn getResult(context: *anyopaque) ?IoResult {
            const self: *@This() = @ptrCast(@alignCast(context));
            return self.result;
        }
    };

    const Backend = struct {
        read_ctx: TestContext,
        write_ctx: TestContext,

        fn read(context: *anyopaque, _: []u8) IoError!Future {
            const self: *@This() = @ptrCast(@alignCast(context));
            const vtable = Future.FutureVTable{
                .poll = TestContext.poll,
                .cancel = TestContext.cancel,
                .destroy = TestContext.destroy,
                .get_result = TestContext.getResult,
            };
            return Future.init(testing.allocator, &vtable, &self.read_ctx);
        }

        fn write(context: *anyopaque, _: []const u8) IoError!Future {
            const self: *@This() = @ptrCast(@alignCast(context));
            const vtable = Future.FutureVTable{
                .poll = TestContext.poll,
                .cancel = TestContext.cancel,
                .destroy = TestContext.destroy,
                .get_result = TestContext.getResult,
            };
            return Future.init(testing.allocator, &vtable, &self.write_ctx);
        }

        fn readv(_: *anyopaque, _: []IoBuffer) IoError!Future {
            return IoError.NotSupported;
        }
        fn writev(_: *anyopaque, _: []const []const u8) IoError!Future {
            return IoError.NotSupported;
        }
        fn sendFile(_: *anyopaque, _: std.posix.fd_t, _: u64, _: u64) IoError!Future {
            return IoError.NotSupported;
        }
        fn copyFileRange(_: *anyopaque, _: std.posix.fd_t, _: std.posix.fd_t, _: u64) IoError!Future {
            return IoError.NotSupported;
        }
        fn accept(_: *anyopaque, _: std.posix.fd_t) IoError!Future {
            return IoError.NotSupported;
        }
        fn connect(_: *anyopaque, _: std.posix.fd_t, _: *const std.posix.sockaddr, _: std.posix.socklen_t) IoError!Future {
            return IoError.NotSupported;
        }
        fn close(_: *anyopaque, _: std.posix.fd_t) IoError!Future {
            return IoError.NotSupported;
        }
        fn shutdown(_: *anyopaque) void {}
        fn getMode(_: *anyopaque) IoMode {
            return .blocking;
        }
        fn supportsVectorized(_: *anyopaque) bool {
            return false;
        }
        fn supportsZeroCopy(_: *anyopaque) bool {
            return false;
        }
        fn getAllocator(_: *anyopaque) std.mem.Allocator {
            return testing.allocator;
        }

        const io_vtable = Io.IoVTable{
            .read = read,
            .write = write,
            .readv = readv,
            .writev = writev,
            .send_file = sendFile,
            .copy_file_range = copyFileRange,
            .accept = accept,
            .connect = connect,
            .close = close,
            .shutdown = shutdown,
            .get_mode = getMode,
            .supports_vectorized = supportsVectorized,
            .supports_zero_copy = supportsZeroCopy,
            .get_allocator = getAllocator,
        };
    };

    var backend = Backend{
        .read_ctx = .{ .result = .{ .bytes_transferred = 3 } },
        .write_ctx = .{ .result = .{ .bytes_transferred = 2 } },
    };

    var io = Io.init(&Backend.io_vtable, &backend);
    var buffer: [8]u8 = undefined;
    try testing.expectEqual(@as(usize, 3), try io.readSync(&buffer));
    try testing.expectEqual(@as(usize, 2), try io.writeSync("hello"));
}
