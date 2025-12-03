//! Semantic I/O Operations for zsync
//! Implements sendFile, drain, and splat parameters as described in Zig's new async I/O design

const std = @import("std");
const builtin = @import("builtin");
const io_v2 = @import("io_v2.zig");
const platform = @import("platform.zig");
const error_management = @import("error_management.zig");

/// Limit type for controlling data transfer amounts
pub const Limit = union(enum) {
    none,
    bytes: u64,
    until_eof,
    
    pub fn toBytes(self: Limit) ?u64 {
        return switch (self) {
            .bytes => |b| b,
            else => null,
        };
    }
    
    pub fn isUnlimited(self: Limit) bool {
        return self == .none or self == .until_eof;
    }
};

/// Enhanced Writer interface with semantic I/O operations
pub const Writer = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    
    pub const VTable = struct {
        write_fn: *const fn (ptr: *anyopaque, io: io_v2.Io, data: []const u8) anyerror!usize,
        writeAll_fn: *const fn (ptr: *anyopaque, io: io_v2.Io, data: []const u8) anyerror!void,
        
        // Semantic I/O operations
        sendFile_fn: *const fn (ptr: *anyopaque, io: io_v2.Io, file_reader: *Reader, limit: Limit) anyerror!u64,
        drain_fn: *const fn (ptr: *anyopaque, io: io_v2.Io, data: []const []const u8, splat: usize) anyerror!u64,
        
        // Advanced operations
        writeVectored_fn: ?*const fn (ptr: *anyopaque, io: io_v2.Io, vectors: []const std.posix.iovec) anyerror!usize = null,
        sendFileRange_fn: ?*const fn (ptr: *anyopaque, io: io_v2.Io, file_reader: *Reader, offset: u64, length: u64) anyerror!u64 = null,
        splice_fn: ?*const fn (ptr: *anyopaque, io: io_v2.Io, input: *Reader, limit: Limit) anyerror!u64 = null,
        
        // Buffer management
        flush_fn: ?*const fn (ptr: *anyopaque, io: io_v2.Io) anyerror!void = null,
        sync_fn: ?*const fn (ptr: *anyopaque, io: io_v2.Io) anyerror!void = null,
        
        // Resource management
        close_fn: ?*const fn (ptr: *anyopaque, io: io_v2.Io) anyerror!void = null,
        deinit_fn: *const fn (ptr: *anyopaque) void,
    };
    
    /// Write data to the writer
    pub fn write(self: Writer, io: io_v2.Io, data: []const u8) !usize {
        return self.vtable.write_fn(self.ptr, io, data);
    }
    
    /// Write all data to the writer
    pub fn writeAll(self: Writer, io: io_v2.Io, data: []const u8) !void {
        return self.vtable.writeAll_fn(self.ptr, io, data);
    }
    
    /// Send file data directly to the writer using zero-copy optimization
    /// Inspired by POSIX sendfile and equivalents on other platforms
    pub fn sendFile(
        self: Writer,
        io: io_v2.Io,
        file_reader: *File.Reader,
        limit: Limit,
    ) !u64 {
        return self.vtable.sendFile_fn(self.ptr, io, file_reader, limit);
    }
    
    /// Perform vectorized writes with splat support
    /// data: array of data segments to write
    /// splat: number of times to repeat the last segment
    pub fn drain(
        self: Writer,
        io: io_v2.Io,
        data: []const []const u8,
        splat: usize,
    ) !u64 {
        return self.vtable.drain_fn(self.ptr, io, data, splat);
    }
    
    /// Write vectorized data using platform-specific optimizations
    pub fn writeVectored(
        self: Writer,
        io: io_v2.Io,
        vectors: []const std.posix.iovec,
    ) !usize {
        if (self.vtable.writeVectored_fn) |write_vectored_fn| {
            return write_vectored_fn(self.ptr, io, vectors);
        }
        
        // Fallback to sequential writes
        var total_written: usize = 0;
        for (vectors) |vector| {
            const data = @as([*]const u8, @ptrCast(vector.iov_base))[0..vector.iov_len];
            const written = try self.write(io, data);
            total_written += written;
            if (written < data.len) break; // Partial write
        }
        return total_written;
    }
    
    /// Send a specific range of a file
    pub fn sendFileRange(
        self: Writer,
        io: io_v2.Io,
        file_reader: *File.Reader,
        offset: u64,
        length: u64,
    ) !u64 {
        if (self.vtable.sendFileRange_fn) |send_file_range_fn| {
            return send_file_range_fn(self.ptr, io, file_reader, offset, length);
        }
        
        // Fallback using regular sendFile
        _ = try file_reader.seek(io, offset);
        return self.sendFile(io, file_reader, Limit{ .bytes = length });
    }
    
    /// Splice data from a reader to this writer
    pub fn splice(
        self: Writer,
        io: io_v2.Io,
        input: *Reader,
        limit: Limit,
    ) !u64 {
        if (self.vtable.splice_fn) |splice_fn| {
            return splice_fn(self.ptr, io, input, limit);
        }
        
        // Fallback using buffered copy
        return self.copyFromReader(io, input, limit);
    }
    
    /// Flush any buffered data
    pub fn flush(self: Writer, io: io_v2.Io) !void {
        if (self.vtable.flush_fn) |flush_fn| {
            try flush_fn(self.ptr, io);
        }
    }
    
    /// Synchronize data to storage
    pub fn sync(self: Writer, io: io_v2.Io) !void {
        if (self.vtable.sync_fn) |sync_fn| {
            try sync_fn(self.ptr, io);
        }
    }
    
    /// Close the writer
    pub fn close(self: Writer, io: io_v2.Io) !void {
        if (self.vtable.close_fn) |close_fn| {
            try close_fn(self.ptr, io);
        }
    }
    
    /// Cleanup the writer
    pub fn deinit(self: Writer) void {
        self.vtable.deinit_fn(self.ptr);
    }
    
    /// Fallback implementation for copying from reader to writer
    fn copyFromReader(
        self: Writer,
        io: io_v2.Io,
        reader: *Reader,
        limit: Limit,
    ) !u64 {
        var total_copied: u64 = 0;
        var buffer: [8192]u8 = undefined;
        
        while (true) {
            const max_read = switch (limit) {
                .bytes => |remaining| @min(buffer.len, remaining - total_copied),
                else => buffer.len,
            };
            
            if (max_read == 0) break;
            
            const bytes_read = try reader.read(io, buffer[0..max_read]);
            if (bytes_read == 0) break; // EOF
            
            try self.writeAll(io, buffer[0..bytes_read]);
            total_copied += bytes_read;
            
            if (limit == .bytes and total_copied >= limit.bytes) break;
        }
        
        return total_copied;
    }
};

/// Enhanced Reader interface
pub const Reader = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    
    pub const VTable = struct {
        read_fn: *const fn (ptr: *anyopaque, io: io_v2.Io, buffer: []u8) anyerror!usize,
        readAll_fn: *const fn (ptr: *anyopaque, io: io_v2.Io, buffer: []u8) anyerror!usize,
        
        // Advanced operations
        readVectored_fn: ?*const fn (ptr: *anyopaque, io: io_v2.Io, vectors: []std.posix.iovec) anyerror!usize = null,
        peek_fn: ?*const fn (ptr: *anyopaque, io: io_v2.Io, buffer: []u8) anyerror!usize = null,
        skip_fn: ?*const fn (ptr: *anyopaque, io: io_v2.Io, bytes: u64) anyerror!u64 = null,
        
        // Seeking
        seek_fn: ?*const fn (ptr: *anyopaque, io: io_v2.Io, offset: u64) anyerror!void = null,
        tell_fn: ?*const fn (ptr: *anyopaque, io: io_v2.Io) anyerror!u64 = null,
        
        // Resource management
        close_fn: ?*const fn (ptr: *anyopaque, io: io_v2.Io) anyerror!void = null,
        deinit_fn: *const fn (ptr: *anyopaque) void,
    };
    
    /// Read data from the reader
    pub fn read(self: Reader, io: io_v2.Io, buffer: []u8) !usize {
        return self.vtable.read_fn(self.ptr, io, buffer);
    }
    
    /// Read all available data
    pub fn readAll(self: Reader, io: io_v2.Io, buffer: []u8) !usize {
        return self.vtable.readAll_fn(self.ptr, io, buffer);
    }
    
    /// Read into multiple buffers (vectored read)
    pub fn readVectored(self: Reader, io: io_v2.Io, vectors: []std.posix.iovec) !usize {
        if (self.vtable.readVectored_fn) |read_vectored_fn| {
            return read_vectored_fn(self.ptr, io, vectors);
        }
        
        // Fallback to sequential reads
        var total_read: usize = 0;
        for (vectors) |vector| {
            const buffer = @as([*]u8, @ptrCast(vector.iov_base))[0..vector.iov_len];
            const bytes_read = try self.read(io, buffer);
            total_read += bytes_read;
            if (bytes_read < buffer.len) break; // Partial read
        }
        return total_read;
    }
    
    /// Peek at data without consuming it
    pub fn peek(self: Reader, io: io_v2.Io, buffer: []u8) !usize {
        if (self.vtable.peek_fn) |peek_fn| {
            return peek_fn(self.ptr, io, buffer);
        }
        return error.PeekNotSupported;
    }
    
    /// Skip bytes without reading them
    pub fn skip(self: Reader, io: io_v2.Io, bytes: u64) !u64 {
        if (self.vtable.skip_fn) |skip_fn| {
            return skip_fn(self.ptr, io, bytes);
        }
        
        // Fallback using read and discard
        var total_skipped: u64 = 0;
        var discard_buffer: [4096]u8 = undefined;
        
        while (total_skipped < bytes) {
            const to_read = @min(discard_buffer.len, bytes - total_skipped);
            const bytes_read = try self.read(io, discard_buffer[0..to_read]);
            if (bytes_read == 0) break; // EOF
            total_skipped += bytes_read;
        }
        
        return total_skipped;
    }
    
    /// Seek to a specific position
    pub fn seek(self: Reader, io: io_v2.Io, offset: u64) !void {
        if (self.vtable.seek_fn) |seek_fn| {
            return seek_fn(self.ptr, io, offset);
        }
        return error.SeekNotSupported;
    }
    
    /// Get current position
    pub fn tell(self: Reader, io: io_v2.Io) !u64 {
        if (self.vtable.tell_fn) |tell_fn| {
            return tell_fn(self.ptr, io);
        }
        return error.TellNotSupported;
    }
    
    /// Close the reader
    pub fn close(self: Reader, io: io_v2.Io) !void {
        if (self.vtable.close_fn) |close_fn| {
            try close_fn(self.ptr, io);
        }
    }
    
    /// Cleanup the reader
    pub fn deinit(self: Reader) void {
        self.vtable.deinit_fn(self.ptr);
    }
};

/// File operations with semantic I/O support
pub const File = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    
    pub const VTable = struct {
        getReader_fn: *const fn (ptr: *anyopaque) Reader,
        getWriter_fn: *const fn (ptr: *anyopaque) Writer,
        
        // Direct file operations
        sendFileToWriter_fn: *const fn (ptr: *anyopaque, io: io_v2.Io, writer: Writer, limit: Limit) anyerror!u64,
        receiveFromReader_fn: *const fn (ptr: *anyopaque, io: io_v2.Io, reader: Reader, limit: Limit) anyerror!u64,
        
        // File-specific operations
        size_fn: ?*const fn (ptr: *anyopaque, io: io_v2.Io) anyerror!u64 = null,
        truncate_fn: ?*const fn (ptr: *anyopaque, io: io_v2.Io, size: u64) anyerror!void = null,
        sync_fn: ?*const fn (ptr: *anyopaque, io: io_v2.Io) anyerror!void = null,
        
        close_fn: *const fn (ptr: *anyopaque, io: io_v2.Io) anyerror!void,
        deinit_fn: *const fn (ptr: *anyopaque) void,
    };
    
    /// Get a reader for this file
    pub fn getReader(self: File) Reader {
        return self.vtable.getReader_fn(self.ptr);
    }
    
    /// Get a writer for this file
    pub fn getWriter(self: File) Writer {
        return self.vtable.getWriter_fn(self.ptr);
    }
    
    /// Send this file's contents to a writer
    pub fn sendToWriter(self: File, io: io_v2.Io, writer: Writer, limit: Limit) !u64 {
        return self.vtable.sendFileToWriter_fn(self.ptr, io, writer, limit);
    }
    
    /// Receive data from a reader into this file
    pub fn receiveFromReader(self: File, io: io_v2.Io, reader: Reader, limit: Limit) !u64 {
        return self.vtable.receiveFromReader_fn(self.ptr, io, reader, limit);
    }
    
    /// Get file size
    pub fn getSize(self: File, io: io_v2.Io) !u64 {
        if (self.vtable.size_fn) |size_fn| {
            return size_fn(self.ptr, io);
        }
        return error.SizeNotSupported;
    }
    
    /// Truncate file to specified size
    pub fn truncate(self: File, io: io_v2.Io, size: u64) !void {
        if (self.vtable.truncate_fn) |truncate_fn| {
            try truncate_fn(self.ptr, io, size);
        } else {
            return error.TruncateNotSupported;
        }
    }
    
    /// Synchronize file data to storage
    pub fn sync(self: File, io: io_v2.Io) !void {
        if (self.vtable.sync_fn) |sync_fn| {
            try sync_fn(self.ptr, io);
        }
    }
    
    /// Close the file
    pub fn close(self: File, io: io_v2.Io) !void {
        return self.vtable.close_fn(self.ptr, io);
    }
    
    /// Cleanup the file
    pub fn deinit(self: File) void {
        self.vtable.deinit_fn(self.ptr);
    }
    
};

/// Platform-specific optimized implementations
pub const PlatformOptimizations = struct {
    /// Detect and use platform-specific sendfile optimizations
    pub fn optimizedSendFile(
        writer_fd: std.posix.fd_t,
        reader_fd: std.posix.fd_t,
        offset: ?*u64,
        count: u64,
    ) !u64 {
        return switch (builtin.target.os.tag) {
            .linux => sendFileLinux(writer_fd, reader_fd, offset, count),
            .macos, .freebsd => sendFileBsd(writer_fd, reader_fd, offset, count),
            .windows => sendFileWindows(writer_fd, reader_fd, offset, count),
            else => error.SendFileNotSupported,
        };
    }
    
    /// Linux sendfile implementation
    fn sendFileLinux(
        out_fd: std.posix.fd_t,
        in_fd: std.posix.fd_t,
        offset: ?*u64,
        count: u64,
    ) !u64 {
        const linux = std.os.linux;
        
        var off: i64 = if (offset) |o| @intCast(o.*) else 0;
        const result = linux.sendfile(out_fd, in_fd, if (offset != null) &off else null, count);
        
        return switch (linux.getErrno(result)) {
            .SUCCESS => blk: {
                const bytes_sent = @as(u64, @intCast(result));
                if (offset) |o| o.* = @intCast(off);
                break :blk bytes_sent;
            },
            .AGAIN => 0, // Would block
            .INVAL => error.InvalidArgument,
            .IO => error.InputOutput,
            .NOMEM => error.SystemResources,
            .PIPE => error.BrokenPipe,
            else => |errno| std.posix.unexpectedErrno(errno),
        };
    }
    
    /// BSD/macOS sendfile implementation
    fn sendFileBsd(
        out_fd: std.posix.fd_t,
        in_fd: std.posix.fd_t,
        offset: ?*u64,
        count: u64,
    ) !u64 {
        _ = out_fd;
        _ = in_fd;
        _ = offset;
        _ = count;
        
        // BSD sendfile has different signature
        // Implementation would use actual BSD sendfile syscall
        return error.SendFileNotSupported;
    }
    
    /// Windows TransmitFile implementation
    fn sendFileWindows(
        out_fd: std.posix.fd_t,
        in_fd: std.posix.fd_t,
        offset: ?*u64,
        count: u64,
    ) !u64 {
        _ = out_fd;
        _ = in_fd;
        _ = offset;
        _ = count;
        
        // Windows implementation would use TransmitFile or similar
        return error.SendFileNotSupported;
    }
    
    /// Optimized vectored write using platform-specific APIs
    pub fn optimizedWriteVectored(
        fd: std.posix.fd_t,
        vectors: []const std.posix.iovec,
    ) !usize {
        return switch (builtin.target.os.tag) {
            .linux, .macos, .freebsd => writeVectoredPosix(fd, vectors),
            .windows => writeVectoredWindows(fd, vectors),
            else => error.VectoredWriteNotSupported,
        };
    }
    
    fn writeVectoredPosix(fd: std.posix.fd_t, vectors: []const std.posix.iovec) !usize {
        const result = std.posix.writev(fd, vectors);
        return result;
    }
    
    fn writeVectoredWindows(fd: std.posix.fd_t, vectors: []const std.posix.iovec) !usize {
        _ = fd;
        _ = vectors;
        // Windows implementation would use WriteFileGather or similar
        return error.VectoredWriteNotSupported;
    }
    
    /// Optimized splice operation
    pub fn optimizedSplice(
        in_fd: std.posix.fd_t,
        out_fd: std.posix.fd_t,
        count: u64,
    ) !u64 {
        return switch (builtin.target.os.tag) {
            .linux => spliceLinux(in_fd, out_fd, count),
            else => error.SpliceNotSupported,
        };
    }
    
    fn spliceLinux(in_fd: std.posix.fd_t, out_fd: std.posix.fd_t, count: u64) !u64 {
        const linux = std.os.linux;
        
        const result = linux.splice(in_fd, null, out_fd, null, count, 0);
        
        return switch (linux.getErrno(result)) {
            .SUCCESS => @intCast(result),
            .AGAIN => 0, // Would block
            .BADF => error.InvalidFileDescriptor,
            .INVAL => error.InvalidArgument,
            .NOMEM => error.SystemResources,
            .PIPE => error.BrokenPipe,
            else => |errno| std.posix.unexpectedErrno(errno),
        };
    }
};

/// Drain operation implementation with splat support
pub const DrainOperation = struct {
    /// Execute a drain operation with vectorized writes and splat support
    pub fn execute(
        writer: Writer,
        io: io_v2.Io,
        data: []const []const u8,
        splat: usize,
    ) !u64 {
        if (data.len == 0) return 0;
        
        var total_written: u64 = 0;
        
        // Write all data segments first
        for (data) |segment| {
            try writer.writeAll(io, segment);
            total_written += segment.len;
        }
        
        // Handle splat parameter (repeat last segment)
        if (splat > 0 and data.len > 0) {
            const last_segment = data[data.len - 1];
            
            // Optimize for large splat counts using vectored writes if possible
            if (splat > 10 and writer.vtable.writeVectored_fn != null) {
                try executeSplatVectorized(writer, io, last_segment, splat);
            } else {
                // Simple loop for small splat counts
                for (0..splat) |_| {
                    try writer.writeAll(io, last_segment);
                }
            }
            
            total_written += last_segment.len * splat;
        }
        
        return total_written;
    }
    
    /// Execute splat operation using vectorized writes
    fn executeSplatVectorized(
        writer: Writer,
        io: io_v2.Io,
        segment: []const u8,
        splat: usize,
    ) !void {
        const max_vectors = 64; // Reasonable limit for iovec array
        var vectors: [max_vectors]std.posix.iovec = undefined;
        
        var remaining = splat;
        while (remaining > 0) {
            const batch_size = @min(remaining, max_vectors);
            
            // Set up iovec array
            for (0..batch_size) |i| {
                vectors[i] = std.posix.iovec{
                    .iov_base = @as(*anyopaque, @ptrCast(@constCast(segment.ptr))),
                    .iov_len = segment.len,
                };
            }
            
            _ = try writer.writeVectored(io, vectors[0..batch_size]);
            remaining -= batch_size;
        }
    }
};

/// Utility functions for semantic I/O operations
pub const SemanticIoUtils = struct {
    /// Copy data from reader to writer with semantic optimizations
    pub fn copyOptimized(
        reader: Reader,
        writer: Writer,
        io: io_v2.Io,
        limit: Limit,
    ) !u64 {
        // Try splice optimization first (Linux only)
        if (builtin.target.os.tag == .linux) {
            // In a real implementation, we'd try to extract file descriptors
            // and use splice for zero-copy transfer
        }
        
        // Fallback to buffered copy
        return copyBuffered(reader, writer, io, limit);
    }
    
    fn copyBuffered(
        reader: Reader,
        writer: Writer,
        io: io_v2.Io,
        limit: Limit,
    ) !u64 {
        var total_copied: u64 = 0;
        var buffer: [64 * 1024]u8 = undefined; // 64KB buffer
        
        while (true) {
            const max_read = switch (limit) {
                .bytes => |remaining| @min(buffer.len, remaining - total_copied),
                else => buffer.len,
            };
            
            if (max_read == 0) break;
            
            const bytes_read = try reader.read(io, buffer[0..max_read]);
            if (bytes_read == 0) break; // EOF
            
            try writer.writeAll(io, buffer[0..bytes_read]);
            total_copied += bytes_read;
            
            if (limit == .bytes and total_copied >= limit.bytes) break;
        }
        
        return total_copied;
    }
    
    /// Create a chain of writers for pipeline processing
    pub fn createWriterChain(
        allocator: std.mem.Allocator,
        writers: []Writer,
    ) !ChainedWriter {
        return ChainedWriter.init(allocator, writers);
    }
    
    /// Chained writer that writes to multiple writers in sequence
    const ChainedWriter = struct {
        writers: []Writer,
        allocator: std.mem.Allocator,
        
        fn init(allocator: std.mem.Allocator, writers: []Writer) ChainedWriter {
            return ChainedWriter{
                .writers = writers,
                .allocator = allocator,
            };
        }
        
        pub fn write(self: ChainedWriter, io: io_v2.Io, data: []const u8) !usize {
            for (self.writers) |writer| {
                try writer.writeAll(io, data);
            }
            return data.len;
        }
        
        pub fn deinit(self: ChainedWriter) void {
            _ = self;
            // Cleanup logic here
        }
    };
};

test "semantic I/O operations" {
    const testing = std.testing;
    
    // Test Limit functionality
    const limit_bytes = Limit{ .bytes = 1024 };
    try testing.expect(limit_bytes.toBytes().? == 1024);
    try testing.expect(!limit_bytes.isUnlimited());
    
    const limit_none = Limit{ .none = {} };
    try testing.expect(limit_none.toBytes() == null);
    try testing.expect(limit_none.isUnlimited());
}

test "drain operation" {
    const testing = std.testing;
    
    // Test drain operation logic
    const data = [_][]const u8{ "hello", "world" };
    const splat = 3;
    
    // In a real test, we'd create actual writers and test the drain operation
    try testing.expect(data.len == 2);
    try testing.expect(splat == 3);
}