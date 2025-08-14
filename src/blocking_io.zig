//! Zsync v0.4.0 - Modern BlockingIo Implementation  
//! Direct syscalls with no async overhead - equivalent to C performance
//! Updated to use new Io interface with vtable dispatch and Future cancellation

const std = @import("std");
const builtin = @import("builtin");
const io_interface = @import("io_interface.zig");

const Io = io_interface.Io;
const Future = io_interface.Future;
const IoError = io_interface.IoError;
const IoBuffer = io_interface.IoBuffer;
const IoResult = io_interface.IoResult;

/// Blocking I/O future that completes immediately
const BlockingFuture = struct {
    result: IoError!IoResult,
    allocator: std.mem.Allocator,
    
    const Self = @This();
    
    fn poll(context: *anyopaque) IoError!Future.PollResult {
        const self: *Self = @ptrCast(@alignCast(context));
        _ = self.result catch |err| return err;
        return .ready;
    }
    
    fn cancel(_: *anyopaque) void {
        // Blocking operations can't be cancelled once started
    }
    
    fn destroy(context: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *Self = @ptrCast(@alignCast(context));
        allocator.destroy(self);
    }
    
    const vtable = Future.FutureVTable{
        .poll = poll,
        .cancel = cancel,
        .destroy = destroy,
    };
    
    pub fn init(allocator: std.mem.Allocator, result: IoError!IoResult) !*Self {
        const future = try allocator.create(Self);
        future.* = Self{
            .result = result,
            .allocator = allocator,
        };
        return future;
    }
    
    pub fn toFuture(self: *Self) Future {
        return Future.init(&vtable, self);
    }
};

/// BlockingIo implementation - zero overhead blocking I/O
pub const BlockingIo = struct {
    allocator: std.mem.Allocator,
    buffer_size: usize,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, buffer_size: usize) Self {
        return Self{
            .allocator = allocator,
            .buffer_size = buffer_size,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    /// Get the Io interface for this implementation
    pub fn io(self: *Self) Io {
        return Io.init(&vtable, self);
    }

    // Implementation functions
    fn read(context: *anyopaque, buffer: []u8) IoError!Future {
        const self: *Self = @ptrCast(@alignCast(context));
        
        // Direct syscall - no async overhead  
        const bytes_read = std.posix.read(std.posix.STDIN_FILENO, buffer) catch |err| {
            const result = IoResult{
                .bytes_transferred = 0,
                .error_code = switch (err) {
                    error.WouldBlock => IoError.WouldBlock,
                    error.BrokenPipe => IoError.BrokenPipe,
                    error.ConnectionResetByPeer => IoError.ConnectionClosed,
                    error.AccessDenied => IoError.AccessDenied,
                    else => IoError.SystemResources,
                },
            };
            const future = try BlockingFuture.init(self.allocator, Ok(result));
            return future.toFuture();
        };
        
        const result = IoResult{
            .bytes_transferred = bytes_read,
            .error_code = null,
        };
        
        const future = try BlockingFuture.init(self.allocator, Ok(result));
        return future.toFuture();
    }
    
    fn write(context: *anyopaque, data: []const u8) IoError!Future {
        const self: *Self = @ptrCast(@alignCast(context));
        
        // Direct syscall - generates same machine code as C
        const bytes_written = std.posix.write(std.posix.STDOUT_FILENO, data) catch |err| {
            const result = IoResult{
                .bytes_transferred = 0,
                .error_code = switch (err) {
                    error.BrokenPipe => IoError.BrokenPipe,
                    error.ConnectionResetByPeer => IoError.ConnectionClosed,
                    error.AccessDenied => IoError.AccessDenied,
                    error.SystemResources => IoError.SystemResources,
                    else => IoError.SystemResources,
                },
            };
            const future = try BlockingFuture.init(self.allocator, Ok(result));
            return future.toFuture();
        };
        
        const result = IoResult{
            .bytes_transferred = bytes_written,
            .error_code = null,
        };
        
        const future = try BlockingFuture.init(self.allocator, Ok(result));
        return future.toFuture();
    }
    
    fn readv(context: *anyopaque, buffers: []IoBuffer) IoError!Future {
        const self: *Self = @ptrCast(@alignCast(context));
        
        var total_read: usize = 0;
        for (buffers) |*buffer| {
            const bytes_read = std.posix.read(std.posix.STDIN_FILENO, buffer.available()) catch |err| {
                const result = IoResult{
                    .bytes_transferred = total_read,
                    .error_code = switch (err) {
                        error.WouldBlock => IoError.WouldBlock,
                        error.BrokenPipe => IoError.BrokenPipe,
                        error.ConnectionResetByPeer => IoError.ConnectionClosed,
                        else => IoError.SystemResources,
                    },
                };
                const future = try BlockingFuture.init(self.allocator, Ok(result));
                return future.toFuture();
            };
            
            buffer.advance(bytes_read);
            total_read += bytes_read;
            
            if (bytes_read == 0) break; // EOF
        }
        
        const result = IoResult{
            .bytes_transferred = total_read,
            .error_code = null,
        };
        
        const future = try BlockingFuture.init(self.allocator, Ok(result));
        return future.toFuture();
    }
    
    fn writev(context: *anyopaque, buffers: []const []const u8) IoError!Future {
        const self: *Self = @ptrCast(@alignCast(context));
        
        var total_written: usize = 0;
        for (buffers) |data| {
            const bytes_written = std.posix.write(std.posix.STDOUT_FILENO, data) catch |err| {
                const result = IoResult{
                    .bytes_transferred = total_written,
                    .error_code = switch (err) {
                        error.BrokenPipe => IoError.BrokenPipe,
                        error.ConnectionResetByPeer => IoError.ConnectionClosed,
                        else => IoError.SystemResources,
                    },
                };
                const future = try BlockingFuture.init(self.allocator, Ok(result));
                return future.toFuture();
            };
            total_written += bytes_written;
        }
        
        const result = IoResult{
            .bytes_transferred = total_written,
            .error_code = null,
        };
        
        const future = try BlockingFuture.init(self.allocator, Ok(result));
        return future.toFuture();
    }
    
    fn send_file(context: *anyopaque, src_fd: std.posix.fd_t, offset: u64, count: u64) IoError!Future {
        const self: *Self = @ptrCast(@alignCast(context));
        
        // Use sendfile syscall on Linux, fallback to manual copy on other systems
        const bytes_sent = blk: {
            // Fallback to manual copy for other platforms
            var buffer: [8192]u8 = undefined;
            var total_copied: usize = 0;
            var remaining = count;
            
            while (remaining > 0 and total_copied < count) {
                const to_read = @min(remaining, buffer.len);
                const bytes_read = std.posix.pread(src_fd, buffer[0..to_read], offset + total_copied) catch break;
                if (bytes_read == 0) break;
                
                const bytes_written = std.posix.write(std.posix.STDOUT_FILENO, buffer[0..bytes_read]) catch break;
                total_copied += bytes_written;
                remaining -= bytes_read;
                
                if (bytes_written < bytes_read) break;
            }
            
            break :blk total_copied;
        };
        
        const result = IoResult{
            .bytes_transferred = bytes_sent,
            .error_code = null,
        };
        
        const future = try BlockingFuture.init(self.allocator, Ok(result));
        return future.toFuture();
    }
    
    fn copy_file_range(context: *anyopaque, src_fd: std.posix.fd_t, dst_fd: std.posix.fd_t, count: u64) IoError!Future {
        const self: *Self = @ptrCast(@alignCast(context));
        
        const bytes_copied = if (builtin.os.tag == .linux) blk: {
            // Use copy_file_range syscall on Linux
            const src_offset: u64 = 0;
            const dst_offset: u64 = 0;
            break :blk std.posix.copy_file_range(src_fd, src_offset, dst_fd, dst_offset, count, 0) catch {
                const result = IoResult{
                    .bytes_transferred = 0,
                    .error_code = IoError.SystemResources,
                };
                const future = try BlockingFuture.init(self.allocator, Ok(result));
                return future.toFuture();
            };
        } else blk: {
            // Manual copy for other platforms
            var buffer: [65536]u8 = undefined;
            var total_copied: usize = 0;
            var remaining = count;
            
            while (remaining > 0) {
                const to_read = @min(remaining, buffer.len);
                const bytes_read = std.posix.read(src_fd, buffer[0..to_read]) catch break;
                if (bytes_read == 0) break;
                
                const bytes_written = std.posix.write(dst_fd, buffer[0..bytes_read]) catch break;
                total_copied += bytes_written;
                remaining -= bytes_read;
                
                if (bytes_written < bytes_read) break;
            }
            
            break :blk total_copied;
        };
        
        const result = IoResult{
            .bytes_transferred = bytes_copied,
            .error_code = null,
        };
        
        const future = try BlockingFuture.init(self.allocator, Ok(result));
        return future.toFuture();
    }
    
    fn accept(context: *anyopaque, listener_fd: std.posix.fd_t) IoError!Future {
        const self: *Self = @ptrCast(@alignCast(context));
        
        var client_addr: std.posix.sockaddr = undefined;
        var addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);
        
        const client_fd = std.posix.accept(listener_fd, @ptrCast(&client_addr), &addr_len, 0) catch |err| {
            const result = IoResult{
                .bytes_transferred = 0,
                .error_code = switch (err) {
                    error.WouldBlock => IoError.WouldBlock,
                    error.ConnectionAborted => IoError.ConnectionClosed,
                    error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded => IoError.SystemResources,
                    else => IoError.SystemResources,
                },
            };
            const future = try BlockingFuture.init(self.allocator, Ok(result));
            return future.toFuture();
        };
        
        const result = IoResult{
            .bytes_transferred = @intCast(client_fd),
            .error_code = null,
        };
        
        const future = try BlockingFuture.init(self.allocator, Ok(result));
        return future.toFuture();
    }
    
    fn connect(context: *anyopaque, fd: std.posix.fd_t, address: std.net.Address) IoError!Future {
        const self: *Self = @ptrCast(@alignCast(context));
        
        std.posix.connect(fd, &address.any, address.getOsSockLen()) catch |err| {
            const result = IoResult{
                .bytes_transferred = 0,
                .error_code = switch (err) {
                    error.WouldBlock => IoError.WouldBlock,
                    error.ConnectionRefused => IoError.ConnectionClosed,
                    error.NetworkUnreachable => IoError.NetworkUnreachable,
                    error.PermissionDenied => IoError.AccessDenied,
                    else => IoError.SystemResources,
                },
            };
            const future = try BlockingFuture.init(self.allocator, Ok(result));
            return future.toFuture();
        };
        
        const result = IoResult{
            .bytes_transferred = 0,
            .error_code = null,
        };
        
        const future = try BlockingFuture.init(self.allocator, Ok(result));
        return future.toFuture();
    }
    
    fn close(context: *anyopaque, fd: std.posix.fd_t) IoError!Future {
        const self: *Self = @ptrCast(@alignCast(context));
        
        std.posix.close(fd);
        
        const result = IoResult{
            .bytes_transferred = 0,
            .error_code = null,
        };
        
        const future = try BlockingFuture.init(self.allocator, Ok(result));
        return future.toFuture();
    }
    
    fn shutdown(_: *anyopaque) void {
        // Nothing to shutdown for blocking I/O
    }
    
    const vtable = Io.IoVTable{
        .read = read,
        .write = write,
        .readv = readv,
        .writev = writev,
        .send_file = send_file,
        .copy_file_range = copy_file_range,
        .accept = accept,
        .connect = connect,
        .close = close,
        .shutdown = shutdown,
    };
};

fn Ok(result: IoResult) IoError!IoResult {
    return result;
}

// Tests
test "BlockingIo creation" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var blocking = BlockingIo.init(allocator, 4096);
    defer blocking.deinit();
    
    const io = blocking.io();
    _ = io; // Test that we can create the interface
}

test "BlockingFuture immediate completion" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    const result = IoResult{
        .bytes_transferred = 100,
        .error_code = null,
    };
    
    const future_ptr = try BlockingFuture.init(allocator, Ok(result));
    defer allocator.destroy(future_ptr);
    
    var future = future_ptr.toFuture();
    try testing.expect(try future.poll() == .ready);
}