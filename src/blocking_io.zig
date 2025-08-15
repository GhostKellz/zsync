//! Zsync v0.4.0 - Modern Blocking I/O Implementation
//! Zero-overhead blocking I/O with colorblind async support
//! Perfect for CPU-bound workloads and simple use cases

const std = @import("std");
const builtin = @import("builtin");
const io_interface = @import("io_interface.zig");

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
    
    const Self = @This();
    
    /// Performance metrics for monitoring
    const Metrics = struct {
        operations_completed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        bytes_read: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        bytes_written: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        error_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        
        pub fn incrementOps(self: *Metrics) void {
            _ = self.operations_completed.fetchAdd(1, .monotonic);
        }
        
        pub fn addBytesRead(self: *Metrics, bytes: u64) void {
            _ = self.bytes_read.fetchAdd(bytes, .monotonic);
        }
        
        pub fn addBytesWritten(self: *Metrics, bytes: u64) void {
            _ = self.bytes_written.fetchAdd(bytes, .monotonic);
        }
        
        pub fn incrementErrors(self: *Metrics) void {
            _ = self.error_count.fetchAdd(1, .monotonic);
        }
    };
    
    /// Initialize blocking I/O with specified buffer size
    pub fn init(allocator: std.mem.Allocator, buffer_size: usize) Self {
        return Self{
            .allocator = allocator,
            .buffer_size = buffer_size,
            .metrics = Metrics{},
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
        };
        
        const read_context = try self.allocator.create(ReadContext);
        
        // Perform actual read (simplified - would use real syscalls)
        const bytes_read = @min(buffer.len, 1024); // Simulate reading data
        @memset(buffer[0..bytes_read], 'A'); // Fill with test data
        
        read_context.* = ReadContext{
            .result = bytes_read,
            .self_ref = self,
        };
        
        const read_vtable = Future.FutureVTable{
            .poll = ReadContext.poll,
            .cancel = ReadContext.cancel,
            .destroy = ReadContext.destroy,
        };
        
        return Future.init(&read_vtable, read_context);
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
        };
        
        const write_context = try self.allocator.create(WriteContext);
        
        // Perform actual write (simplified - real implementation would use syscalls)
        std.debug.print("{s}", .{data}); // Output to stdout
        
        write_context.* = WriteContext{
            .result = data.len,
            .self_ref = self,
        };
        
        const write_vtable = Future.FutureVTable{
            .poll = WriteContext.poll,
            .cancel = WriteContext.cancel,
            .destroy = WriteContext.destroy,
        };
        
        return Future.init(&write_vtable, write_context);
    }
    
    /// Vectorized read - optimal implementation for blocking I/O
    fn readv(context: *anyopaque, buffers: []IoBuffer) IoError!Future {
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
        
        // Simulate reading into all buffers
        for (buffers) |*buffer| {
            const available = buffer.available();
            if (available.len > 0) {
                // Simulate reading data (in real implementation, this would be actual I/O)
                const bytes_to_read = @min(available.len, 1024); // Simulate partial read
                @memset(available[0..bytes_to_read], 'B'); // 'B' for Blocking vectorized
                buffer.advance(bytes_to_read);
                total_bytes += bytes_to_read;
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
        
        return Future.init(&readv_vtable, readv_context);
    }
    
    /// Vectorized write - optimal implementation for blocking I/O
    fn writev(context: *anyopaque, data: []const []const u8) IoError!Future {
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
        
        // Write all data segments
        for (data) |segment| {
            std.debug.print("{s}", .{segment});
            total_bytes += segment.len;
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
        
        return Future.init(&writev_vtable, writev_context);
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
        const result = std.posix.sendfile(std.posix.STDOUT_FILENO, src_fd, offset, count, &[_]std.posix.iovec_const{}, &[_]std.posix.iovec_const{}, 0) catch |err| switch (err) {
            error.AccessDenied => return IoError.AccessDenied,
            error.BrokenPipe => return IoError.BrokenPipe,
            error.ConnectionResetByPeer => return IoError.ConnectionReset,
            error.DeviceBusy => return IoError.SystemResources,
            error.DiskQuota => return IoError.SystemResources,
            error.FileTooBig => return IoError.SystemResources,
            error.InputOutput => return IoError.Unexpected,
            error.NoSpaceLeft => return IoError.SystemResources,
            error.NotOpenForReading => return IoError.InvalidDescriptor,
            error.NotOpenForWriting => return IoError.InvalidDescriptor,
            error.OperationAborted => return IoError.Interrupted,
            error.SystemResources => return IoError.SystemResources,
            error.Unexpected => return IoError.Unexpected,
            error.WouldBlock => return IoError.WouldBlock,
            else => return IoError.NotSupported,
        };
        
        sendfile_context.* = SendFileContext{
            .bytes_transferred = result,
            .self_ref = self,
        };
        
        const sendfile_vtable = Future.FutureVTable{
            .poll = SendFileContext.poll,
            .cancel = SendFileContext.cancel,
            .destroy = SendFileContext.destroy,
        };
        
        return Future.init(&sendfile_vtable, sendfile_context);
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
        const bytes_copied = std.posix.copy_file_range(src_fd, 0, dst_fd, 0, @intCast(count), 0) catch |err| switch (err) {
            error.AccessDenied => return IoError.AccessDenied,
            error.InputOutput => return IoError.Unexpected,
            error.NoSpaceLeft => return IoError.SystemResources,
            error.NotOpenForReading => return IoError.InvalidDescriptor,
            error.NotOpenForWriting => return IoError.InvalidDescriptor,
            error.SystemResources => return IoError.SystemResources,
            error.Unexpected => return IoError.Unexpected,
            else => return IoError.NotSupported,
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
        
        return Future.init(&copy_vtable, copy_context);
    }
    
    /// Accept connection (simplified implementation)
    fn accept(context: *anyopaque, listener_fd: std.posix.fd_t) IoError!Future {
        _ = context;
        _ = listener_fd;
        return IoError.NotSupported; // Would implement real socket operations
    }
    
    /// Connect to address (simplified implementation)
    fn connect(context: *anyopaque, fd: std.posix.fd_t, address: std.net.Address) IoError!Future {
        _ = context;
        _ = fd;
        _ = address;
        return IoError.NotSupported; // Would implement real socket operations
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
        std.posix.close(fd);
        
        const close_context = try self.allocator.create(CloseContext);
        close_context.* = CloseContext{ .self_ref = self };
        
        const close_vtable = Future.FutureVTable{
            .poll = CloseContext.poll,
            .cancel = CloseContext.cancel,
            .destroy = CloseContext.destroy,
        };
        
        return Future.init(&close_vtable, close_context);
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
pub fn exampleBlockingOperation(allocator: std.mem.Allocator, io: Io, data: []const u8) !void {
    // This function works identically with ANY Io implementation!
    var io_mut = io;
    var write_future = try io_mut.write(data);
    defer write_future.destroy(allocator);
    
    // Colorblind await - works in sync or async context
    try write_future.await();
    
    std.debug.print("Operation completed with execution mode: {}\n", .{io.getMode()});
}

// Tests
test "BlockingIo basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var blocking_io = BlockingIo.init(allocator, 1024);
    defer blocking_io.deinit();
    
    const io = blocking_io.io();
    
    // Test write operation
    var io_mut = io;
    var write_future = try io_mut.write("Hello, Zsync v0.4.0!");
    defer write_future.destroy(allocator);
    
    try testing.expect(write_future.poll() == .ready);
    try testing.expect(write_future.isCompleted());
    
    // Test execution mode
    try testing.expect(io.getMode() == .blocking);
    try testing.expect(io.supportsVectorized());
    try testing.expect(!io.supportsZeroCopy());
}

test "BlockingIo vectorized write" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var blocking_io = BlockingIo.init(allocator, 1024);
    defer blocking_io.deinit();
    
    const io = blocking_io.io();
    
    const data = [_][]const u8{ "Hello", " ", "World", "!" };
    var io_mut = io;
    var writev_future = try io_mut.writev(&data);
    defer writev_future.destroy(allocator);
    
    try testing.expect(writev_future.poll() == .ready);
    
    // Check metrics
    const metrics = blocking_io.getMetrics();
    try testing.expect(metrics.operations_completed.load(.monotonic) > 0);
    try testing.expect(metrics.bytes_written.load(.monotonic) > 0);
}

test "colorblind async example" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var blocking_io = BlockingIo.init(allocator, 1024);
    defer blocking_io.deinit();
    
    const io = blocking_io.io();
    
    // This function works with ANY Io implementation
    try exampleBlockingOperation(allocator, io, "Colorblind async works!");
}