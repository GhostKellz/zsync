//! zsync- Modern Blocking I/O Implementation
//! Zero-overhead blocking I/O with colorblind async support
//! Perfect for CPU-bound workloads and simple use cases
//! Cross-platform: Linux, macOS, BSD (POSIX systems)

const std = @import("std");
const builtin = @import("builtin");
const io_interface = @import("io_interface.zig");

/// Check if we're on a POSIX-compatible platform
const is_posix = switch (builtin.os.tag) {
    .linux, .macos, .freebsd, .openbsd, .netbsd, .dragonfly => true,
    else => false,
};

/// Cross-platform POSIX write wrapper (mirrors std.posix.read pattern)
fn posixWrite(fd: std.posix.fd_t, data: []const u8) IoError!usize {
    if (!is_posix) return IoError.NotSupported;
    if (data.len == 0) return 0;

    const max_count: usize = switch (builtin.os.tag) {
        .linux => 0x7ffff000,
        .macos => @intCast(std.math.maxInt(i32)),
        else => @intCast(std.math.maxInt(isize)),
    };

    while (true) {
        const rc = std.posix.system.write(fd, data.ptr, @min(data.len, max_count));
        const errno = std.posix.errno(rc);
        switch (errno) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .AGAIN => return IoError.WouldBlock,
            .CONNRESET => return IoError.ConnectionReset,
            .PIPE => return IoError.BrokenPipe,
            else => return IoError.Unexpected,
        }
    }
}

/// Cross-platform POSIX accept wrapper
fn posixAccept(listener_fd: std.posix.fd_t) IoError!std.posix.fd_t {
    if (!is_posix) return IoError.NotSupported;

    while (true) {
        const rc = std.posix.system.accept(listener_fd, null, null);
        const errno = std.posix.errno(rc);
        switch (errno) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .AGAIN => return IoError.WouldBlock,
            .CONNABORTED => return IoError.ConnectionReset,
            else => return IoError.Unexpected,
        }
    }
}

/// Cross-platform POSIX connect wrapper
fn posixConnect(fd: std.posix.fd_t, addr: *const std.posix.sockaddr, addr_len: std.posix.socklen_t) IoError!void {
    if (!is_posix) return IoError.NotSupported;

    while (true) {
        const rc = std.posix.system.connect(fd, addr, addr_len);
        const errno = std.posix.errno(rc);
        switch (errno) {
            .SUCCESS => return,
            .INTR => continue,
            .AGAIN, .INPROGRESS => return IoError.WouldBlock,
            .CONNREFUSED => return IoError.ConnectionReset,
            .CONNRESET => return IoError.ConnectionReset,
            else => return IoError.Unexpected,
        }
    }
}

const Io = io_interface.Io;
const IoMode = io_interface.IoMode;
const IoError = io_interface.IoError;
const IoBuffer = io_interface.IoBuffer;
const Future = io_interface.Future;

/// High-performance blocking I/O implementation
pub const BlockingIo = struct {
    allocator: std.mem.Allocator,
    buffer_size: usize,
    metrics: Metrics,
    read_fd: std.posix.fd_t,
    write_fd: std.posix.fd_t,

    const Self = @This();

    /// Performance metrics for monitoring
    const Metrics = struct {
        // Use 32-bit atomics on WASM due to platform limitations
        const CounterType = if (builtin.target.cpu.arch == .wasm32) u32 else u64;

        operations_completed: std.atomic.Value(CounterType) = std.atomic.Value(CounterType).init(0),
        bytes_read: std.atomic.Value(CounterType) = std.atomic.Value(CounterType).init(0),
        bytes_written: std.atomic.Value(CounterType) = std.atomic.Value(CounterType).init(0),
        error_count: std.atomic.Value(CounterType) = std.atomic.Value(CounterType).init(0),

        pub fn incrementOps(self: *Metrics) void {
            _ = self.operations_completed.fetchAdd(1, .monotonic);
        }

        pub fn addBytesRead(self: *Metrics, bytes: CounterType) void {
            _ = self.bytes_read.fetchAdd(bytes, .monotonic);
        }

        pub fn addBytesWritten(self: *Metrics, bytes: CounterType) void {
            _ = self.bytes_written.fetchAdd(bytes, .monotonic);
        }

        pub fn incrementErrors(self: *Metrics) void {
            _ = self.error_count.fetchAdd(1, .monotonic);
        }
    };

    /// Initialize blocking I/O with specified buffer size (defaults to stdin/stdout)
    /// Note: BlockingIo is POSIX-only. On Windows, use WindowsIocpIo instead.
    pub fn init(allocator: std.mem.Allocator, buffer_size: usize) Self {
        // On Windows, fd_t is *anyopaque (HANDLE), so we use undefined as placeholder
        // since all operations return NotSupported anyway
        const read_fd: std.posix.fd_t = if (is_posix) std.posix.STDIN_FILENO else undefined;
        const write_fd: std.posix.fd_t = if (is_posix) std.posix.STDOUT_FILENO else undefined;
        return Self{
            .allocator = allocator,
            .buffer_size = buffer_size,
            .metrics = Metrics{},
            .read_fd = read_fd,
            .write_fd = write_fd,
        };
    }

    /// Initialize blocking I/O with specific file descriptors
    pub fn initWithFds(allocator: std.mem.Allocator, buffer_size: usize, read_fd: std.posix.fd_t, write_fd: std.posix.fd_t) Self {
        return Self{
            .allocator = allocator,
            .buffer_size = buffer_size,
            .metrics = Metrics{},
            .read_fd = read_fd,
            .write_fd = write_fd,
        };
    }

    /// Cleanup resources
    pub fn deinit(self: *Self) void {
        _ = self; // No cleanup needed for blocking I/O
    }

    /// Get the Io interface for this implementation
    pub fn io(self: *Self) Io {
        return Io.init(&vtable, self);
    }

    /// Get performance metrics
    pub fn getMetrics(self: *const Self) Metrics {
        return self.metrics;
    }

    /// Get the allocator used by this implementation
    pub fn getAllocator(self: *const Self) std.mem.Allocator {
        return self.allocator;
    }

    /// VTable implementation for the Io interface
    const vtable = Io.IoVTable{
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
        .get_allocator = getAllocatorVtable,
    };

    // Implementation functions

    /// Blocking read operation that completes immediately
    fn read(context: *anyopaque, buffer: []u8) IoError!Future {
        const self: *Self = @ptrCast(@alignCast(context));

        // Create a future that's already completed
        const ReadContext = struct {
            result: IoError!usize,
            self_ref: *Self,

            fn poll(ctx: *anyopaque) Future.PollResult {
                const read_ctx: *@This() = @ptrCast(@alignCast(ctx));
                read_ctx.self_ref.metrics.incrementOps();

                // Simulate read operation
                if (read_ctx.result) |bytes_read| {
                    read_ctx.self_ref.metrics.addBytesRead(bytes_read);
                    return .ready;
                } else |err| {
                    read_ctx.self_ref.metrics.incrementErrors();
                    return .{ .err = err };
                }
            }

            fn cancel(_: *anyopaque) void {
                // Blocking operations can't be cancelled
            }

            fn destroy(ctx: *anyopaque, allocator: std.mem.Allocator) void {
                const read_ctx: *@This() = @ptrCast(@alignCast(ctx));
                allocator.destroy(read_ctx);
            }

            fn getResult(ctx: *anyopaque) ?io_interface.IoResult {
                const read_ctx: *@This() = @ptrCast(@alignCast(ctx));
                const bytes_read = read_ctx.result catch return null;
                return .{ .bytes_transferred = bytes_read };
            }
        };

        const read_context = try self.allocator.create(ReadContext);

        // Perform actual blocking read using POSIX syscall (Linux, macOS, BSD)
        const result: IoError!usize = blk: {
            if (is_posix) {
                break :blk std.posix.read(self.read_fd, buffer) catch |err| switch (err) {
                    error.WouldBlock => IoError.WouldBlock,
                    error.ConnectionResetByPeer => IoError.ConnectionReset,
                    else => IoError.Unexpected,
                };
            } else {
                break :blk IoError.NotSupported;
            }
        };

        read_context.* = ReadContext{
            .result = result,
            .self_ref = self,
        };

        const read_vtable = Future.FutureVTable{
            .poll = ReadContext.poll,
            .cancel = ReadContext.cancel,
            .destroy = ReadContext.destroy,
            .get_result = ReadContext.getResult,
        };

        return Future.init(self.allocator, &read_vtable, read_context);
    }

    /// Blocking write operation that completes immediately
    fn write(context: *anyopaque, data: []const u8) IoError!Future {
        const self: *Self = @ptrCast(@alignCast(context));

        const WriteContext = struct {
            result: IoError!usize,
            self_ref: *Self,

            fn poll(ctx: *anyopaque) Future.PollResult {
                const write_ctx: *@This() = @ptrCast(@alignCast(ctx));
                write_ctx.self_ref.metrics.incrementOps();

                if (write_ctx.result) |bytes_written| {
                    write_ctx.self_ref.metrics.addBytesWritten(bytes_written);
                    return .ready;
                } else |err| {
                    write_ctx.self_ref.metrics.incrementErrors();
                    return .{ .err = err };
                }
            }

            fn cancel(_: *anyopaque) void {}

            fn destroy(ctx: *anyopaque, allocator: std.mem.Allocator) void {
                const write_ctx: *@This() = @ptrCast(@alignCast(ctx));
                allocator.destroy(write_ctx);
            }

            fn getResult(ctx: *anyopaque) ?io_interface.IoResult {
                const write_ctx: *@This() = @ptrCast(@alignCast(ctx));
                const bytes_written = write_ctx.result catch return null;
                return .{ .bytes_transferred = bytes_written };
            }
        };

        const write_context = try self.allocator.create(WriteContext);

        // Perform actual blocking write using POSIX syscall (Linux, macOS, BSD)
        const result: IoError!usize = posixWrite(self.write_fd, data);

        write_context.* = WriteContext{
            .result = result,
            .self_ref = self,
        };

        const write_vtable = Future.FutureVTable{
            .poll = WriteContext.poll,
            .cancel = WriteContext.cancel,
            .destroy = WriteContext.destroy,
            .get_result = WriteContext.getResult,
        };

        return Future.init(self.allocator, &write_vtable, write_context);
    }

    /// Vectorized read - optimal implementation for blocking I/O
    fn readv(context: *anyopaque, buffers: []IoBuffer) IoError!Future {
        if (!is_posix) return IoError.NotSupported;
        if (buffers.len == 0) return IoError.BufferTooSmall;

        const self: *Self = @ptrCast(@alignCast(context));

        const ReadvContext = struct {
            total_bytes: usize,
            self_ref: *Self,

            fn poll(ctx: *anyopaque) Future.PollResult {
                const readv_ctx: *@This() = @ptrCast(@alignCast(ctx));
                readv_ctx.self_ref.metrics.incrementOps();
                readv_ctx.self_ref.metrics.addBytesRead(readv_ctx.total_bytes);
                return .ready;
            }

            fn cancel(_: *anyopaque) void {}

            fn destroy(ctx: *anyopaque, allocator: std.mem.Allocator) void {
                const readv_ctx: *@This() = @ptrCast(@alignCast(ctx));
                allocator.destroy(readv_ctx);
            }
        };

        const readv_context = try self.allocator.create(ReadvContext);
        var total_bytes: usize = 0;

        // Perform real blocking reads into all buffers
        for (buffers) |*buffer| {
            const available = buffer.available();
            if (available.len > 0) {
                const bytes_read = std.posix.read(self.read_fd, available) catch break;
                if (bytes_read == 0) break; // EOF
                buffer.advance(bytes_read);
                total_bytes += bytes_read;
            }
        }

        readv_context.* = ReadvContext{
            .total_bytes = total_bytes,
            .self_ref = self,
        };

        const readv_vtable = Future.FutureVTable{
            .poll = ReadvContext.poll,
            .cancel = ReadvContext.cancel,
            .destroy = ReadvContext.destroy,
        };

        return Future.init(self.allocator, &readv_vtable, readv_context);
    }

    /// Vectorized write - optimal implementation for blocking I/O
    fn writev(context: *anyopaque, data: []const []const u8) IoError!Future {
        if (!is_posix) return IoError.NotSupported;

        const self: *Self = @ptrCast(@alignCast(context));

        const WritevContext = struct {
            total_bytes: usize,
            self_ref: *Self,

            fn poll(ctx: *anyopaque) Future.PollResult {
                const writev_ctx: *@This() = @ptrCast(@alignCast(ctx));
                writev_ctx.self_ref.metrics.incrementOps();
                writev_ctx.self_ref.metrics.addBytesWritten(writev_ctx.total_bytes);
                return .ready;
            }

            fn cancel(_: *anyopaque) void {}

            fn destroy(ctx: *anyopaque, allocator: std.mem.Allocator) void {
                const writev_ctx: *@This() = @ptrCast(@alignCast(ctx));
                allocator.destroy(writev_ctx);
            }
        };

        const writev_context = try self.allocator.create(WritevContext);
        var total_bytes: usize = 0;

        // Perform real blocking writes for all segments
        for (data) |segment| {
            var written: usize = 0;
            while (written < segment.len) {
                const remaining = segment[written..];
                const bytes_written = posixWrite(self.write_fd, remaining) catch break;
                if (bytes_written == 0) break;
                written += bytes_written;
            }
            total_bytes += written;
        }

        writev_context.* = WritevContext{
            .total_bytes = total_bytes,
            .self_ref = self,
        };

        const writev_vtable = Future.FutureVTable{
            .poll = WritevContext.poll,
            .cancel = WritevContext.cancel,
            .destroy = WritevContext.destroy,
        };

        return Future.init(self.allocator, &writev_vtable, writev_context);
    }

    /// Zero-copy file transfer using sendfile() on Linux
    fn sendFile(context: *anyopaque, src_fd: std.posix.fd_t, offset: u64, count: u64) IoError!Future {
        const self: *Self = @ptrCast(@alignCast(context));

        if (builtin.os.tag != .linux) {
            return IoError.NotSupported;
        }

        const SendFileContext = struct {
            bytes_transferred: usize,
            self_ref: *Self,

            fn poll(ctx: *anyopaque) Future.PollResult {
                const sendfile_ctx: *@This() = @ptrCast(@alignCast(ctx));
                sendfile_ctx.self_ref.metrics.incrementOps();
                sendfile_ctx.self_ref.metrics.addBytesWritten(sendfile_ctx.bytes_transferred);
                return .ready;
            }

            fn cancel(_: *anyopaque) void {}

            fn destroy(ctx: *anyopaque, allocator: std.mem.Allocator) void {
                const sendfile_ctx: *@This() = @ptrCast(@alignCast(ctx));
                allocator.destroy(sendfile_ctx);
            }
        };

        const sendfile_context = try self.allocator.create(SendFileContext);

        // Perform zero-copy file transfer using sendfile()
        var offset_val: i64 = @intCast(offset);
        const result = std.os.linux.sendfile(self.write_fd, src_fd, &offset_val, count);
        const bytes_transferred: usize = if (std.posix.errno(result) == .SUCCESS) result else 0;

        sendfile_context.* = SendFileContext{
            .bytes_transferred = bytes_transferred,
            .self_ref = self,
        };

        const sendfile_vtable = Future.FutureVTable{
            .poll = SendFileContext.poll,
            .cancel = SendFileContext.cancel,
            .destroy = SendFileContext.destroy,
        };

        return Future.init(self.allocator, &sendfile_vtable, sendfile_context);
    }

    /// Zero-copy file range copy using copy_file_range() on Linux
    fn copyFileRange(context: *anyopaque, src_fd: std.posix.fd_t, dst_fd: std.posix.fd_t, count: u64) IoError!Future {
        const self: *Self = @ptrCast(@alignCast(context));

        if (builtin.os.tag != .linux) {
            return IoError.NotSupported;
        }

        const CopyFileRangeContext = struct {
            bytes_copied: usize,
            self_ref: *Self,

            fn poll(ctx: *anyopaque) Future.PollResult {
                const copy_ctx: *@This() = @ptrCast(@alignCast(ctx));
                copy_ctx.self_ref.metrics.incrementOps();
                copy_ctx.self_ref.metrics.addBytesRead(copy_ctx.bytes_copied);
                copy_ctx.self_ref.metrics.addBytesWritten(copy_ctx.bytes_copied);
                return .ready;
            }

            fn cancel(_: *anyopaque) void {}

            fn destroy(ctx: *anyopaque, allocator: std.mem.Allocator) void {
                const copy_ctx: *@This() = @ptrCast(@alignCast(ctx));
                allocator.destroy(copy_ctx);
            }
        };

        const copy_context = try self.allocator.create(CopyFileRangeContext);

        // Perform zero-copy file range copy using copy_file_range syscall
        const bytes_copied = blk: {
            if (builtin.os.tag == .linux) {
                const rc = std.os.linux.copy_file_range(src_fd, null, dst_fd, null, @intCast(count), 0);
                if (std.os.linux.errno(rc) != .SUCCESS) {
                    break :blk @as(usize, 0);
                }
                break :blk rc;
            } else {
                break :blk @as(usize, 0);
            }
        };

        copy_context.* = CopyFileRangeContext{
            .bytes_copied = bytes_copied,
            .self_ref = self,
        };

        const copy_vtable = Future.FutureVTable{
            .poll = CopyFileRangeContext.poll,
            .cancel = CopyFileRangeContext.cancel,
            .destroy = CopyFileRangeContext.destroy,
        };

        return Future.init(self.allocator, &copy_vtable, copy_context);
    }

    /// Accept connection on POSIX systems
    fn accept(context: *anyopaque, listener_fd: std.posix.fd_t) IoError!Future {
        const self: *Self = @ptrCast(@alignCast(context));

        if (!is_posix) {
            return IoError.NotSupported;
        }

        const AcceptContext = struct {
            result: IoError!std.posix.fd_t,
            self_ref: *Self,

            fn poll(ctx: *anyopaque) Future.PollResult {
                const accept_ctx: *@This() = @ptrCast(@alignCast(ctx));
                accept_ctx.self_ref.metrics.incrementOps();
                if (accept_ctx.result) |_| {
                    return .ready;
                } else |err| {
                    accept_ctx.self_ref.metrics.incrementErrors();
                    return .{ .err = err };
                }
            }

            fn cancel(_: *anyopaque) void {}

            fn destroy(ctx: *anyopaque, allocator: std.mem.Allocator) void {
                const accept_ctx: *@This() = @ptrCast(@alignCast(ctx));
                allocator.destroy(accept_ctx);
            }
        };

        const accept_context = try self.allocator.create(AcceptContext);
        accept_context.* = AcceptContext{
            .result = posixAccept(listener_fd),
            .self_ref = self,
        };

        const accept_vtable = Future.FutureVTable{
            .poll = AcceptContext.poll,
            .cancel = AcceptContext.cancel,
            .destroy = AcceptContext.destroy,
        };

        return Future.init(self.allocator, &accept_vtable, accept_context);
    }

    /// Connect to address on POSIX systems
    fn connect(context: *anyopaque, fd: std.posix.fd_t, address: if (builtin.target.cpu.arch == .wasm32) []const u8 else *const std.posix.sockaddr, addr_len: std.posix.socklen_t) IoError!Future {
        const self: *Self = @ptrCast(@alignCast(context));

        if (!is_posix) {
            return IoError.NotSupported;
        }

        const ConnectContext = struct {
            result: IoError!void,
            self_ref: *Self,

            fn poll(ctx: *anyopaque) Future.PollResult {
                const connect_ctx: *@This() = @ptrCast(@alignCast(ctx));
                connect_ctx.self_ref.metrics.incrementOps();
                if (connect_ctx.result) |_| {
                    return .ready;
                } else |err| {
                    connect_ctx.self_ref.metrics.incrementErrors();
                    return .{ .err = err };
                }
            }

            fn cancel(_: *anyopaque) void {}

            fn destroy(ctx: *anyopaque, allocator: std.mem.Allocator) void {
                const connect_ctx: *@This() = @ptrCast(@alignCast(ctx));
                allocator.destroy(connect_ctx);
            }
        };

        const connect_context = try self.allocator.create(ConnectContext);

        const result: IoError!void = blk: {
            if (builtin.target.cpu.arch == .wasm32) {
                break :blk IoError.NotSupported;
            } else {
                break :blk posixConnect(fd, address, addr_len);
            }
        };

        connect_context.* = ConnectContext{
            .result = result,
            .self_ref = self,
        };

        const connect_vtable = Future.FutureVTable{
            .poll = ConnectContext.poll,
            .cancel = ConnectContext.cancel,
            .destroy = ConnectContext.destroy,
        };

        return Future.init(self.allocator, &connect_vtable, connect_context);
    }

    /// Close file descriptor
    fn close(context: *anyopaque, fd: std.posix.fd_t) IoError!Future {
        const self: *Self = @ptrCast(@alignCast(context));

        const CloseContext = struct {
            self_ref: *Self,

            fn poll(ctx: *anyopaque) Future.PollResult {
                const close_ctx: *@This() = @ptrCast(@alignCast(ctx));
                close_ctx.self_ref.metrics.incrementOps();
                return .ready;
            }

            fn cancel(_: *anyopaque) void {}

            fn destroy(ctx: *anyopaque, allocator: std.mem.Allocator) void {
                const close_ctx: *@This() = @ptrCast(@alignCast(ctx));
                allocator.destroy(close_ctx);
            }
        };

        // Perform actual close
        std.Io.Threaded.closeFd(fd);

        const close_context = try self.allocator.create(CloseContext);
        close_context.* = CloseContext{ .self_ref = self };

        const close_vtable = Future.FutureVTable{
            .poll = CloseContext.poll,
            .cancel = CloseContext.cancel,
            .destroy = CloseContext.destroy,
        };

        return Future.init(self.allocator, &close_vtable, close_context);
    }

    /// Shutdown I/O operations
    fn shutdown(context: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(context));
        _ = self; // Nothing to shutdown for blocking I/O
    }

    /// Get execution mode
    fn getMode(_: *anyopaque) IoMode {
        return .blocking;
    }

    /// Check if vectorized I/O is supported
    fn supportsVectorized(_: *anyopaque) bool {
        return true; // Blocking I/O supports vectorized operations
    }

    /// Check if zero-copy operations are supported
    fn supportsZeroCopy(_: *anyopaque) bool {
        return builtin.os.tag == .linux; // sendfile/copy_file_range on Linux
    }

    /// Get the allocator (vtable function)
    fn getAllocatorVtable(context: *anyopaque) std.mem.Allocator {
        const self: *Self = @ptrCast(@alignCast(context));
        return self.allocator;
    }
};

/// Convenience function for simple blocking operations
pub fn createSimpleBlockingIo(allocator: std.mem.Allocator) BlockingIo {
    return BlockingIo.init(allocator, 4096);
}

/// Example of colorblind async function using BlockingIo
pub fn exampleBlockingOperation(_: std.mem.Allocator, io: Io, data: []const u8) !void {
    // This function works identically with ANY Io implementation!
    var io_mut = io;
    var write_future = try io_mut.write(data);
    defer write_future.destroy();

    // Colorblind await - works in sync or async context
    try write_future.await();
}

// Tests
test "BlockingIo basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Use /dev/null to avoid writing to stdout (which breaks test server protocol)
    const null_fd = std.posix.openat(std.posix.AT.FDCWD, "/dev/null", .{ .ACCMODE = .WRONLY }, 0) catch {
        return; // Skip test if /dev/null not available
    };
    defer std.Io.Threaded.closeFd(null_fd);

    var blocking_io_inst = BlockingIo.initWithFds(allocator, 1024, std.posix.STDIN_FILENO, null_fd);
    defer blocking_io_inst.deinit();

    const io = blocking_io_inst.io();

    // Test write operation (to /dev/null)
    var io_mut = io;
    var write_future = try io_mut.write("Hello, zsync!");
    defer write_future.destroy();

    try testing.expect(write_future.poll() == .ready);
    try testing.expect(write_future.isCompleted());

    // Test execution mode
    try testing.expect(io.getMode() == .blocking);
    try testing.expect(io.supportsVectorized());
    try testing.expect(io.supportsZeroCopy() == (builtin.os.tag == .linux));
}

test "BlockingIo vectorized write" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Use /dev/null to avoid writing to stdout (which breaks test server protocol)
    const null_fd = std.posix.openat(std.posix.AT.FDCWD, "/dev/null", .{ .ACCMODE = .WRONLY }, 0) catch {
        return; // Skip test if /dev/null not available
    };
    defer std.Io.Threaded.closeFd(null_fd);

    var blocking_io_inst = BlockingIo.initWithFds(allocator, 1024, std.posix.STDIN_FILENO, null_fd);
    defer blocking_io_inst.deinit();

    const io = blocking_io_inst.io();

    const data = [_][]const u8{ "Hello", " ", "World", "!" };
    var io_mut = io;
    var writev_future = try io_mut.writev(&data);
    defer writev_future.destroy();

    try testing.expect(writev_future.poll() == .ready);

    // Check metrics
    const metrics = blocking_io_inst.getMetrics();
    try testing.expect(metrics.operations_completed.load(.monotonic) > 0);
    try testing.expect(metrics.bytes_written.load(.monotonic) > 0);
}

test "colorblind async example" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Use /dev/null to avoid writing to stdout (which breaks test server protocol)
    const null_fd = std.posix.openat(std.posix.AT.FDCWD, "/dev/null", .{ .ACCMODE = .WRONLY }, 0) catch {
        // Skip test if /dev/null not available
        return;
    };
    defer std.Io.Threaded.closeFd(null_fd);

    var blocking_io_inst = BlockingIo.initWithFds(allocator, 1024, std.posix.STDIN_FILENO, null_fd);
    defer blocking_io_inst.deinit();

    const io = blocking_io_inst.io();

    // This function works with ANY Io implementation (writes to /dev/null)
    try exampleBlockingOperation(allocator, io, "Colorblind async works!");
}
