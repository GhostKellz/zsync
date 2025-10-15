const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("io_v2.zig");
const Io = io_mod.Io;
const Handle = std.posix.fd_t;

pub const ZeroCopyError = error{
    BufferNotAligned,
    BufferTooSmall,
    UnsupportedPlatform,
    InvalidHandle,
    OperationInProgress,
    OutOfMemory,
};

pub const BufferPool = struct {
    allocator: std.mem.Allocator,
    page_size: usize,
    free_buffers: std.ArrayList([]align(std.mem.page_size) u8),
    active_buffers: std.AutoHashMap(usize, BufferInfo),
    mutex: std.Thread.Mutex,

    const BufferInfo = struct {
        buffer: []align(std.mem.page_size) u8,
        ref_count: usize,
        pinned: bool,
    };

    pub fn init(allocator: std.mem.Allocator) !BufferPool {
        return BufferPool{
            .allocator = allocator,
            .page_size = std.mem.page_size,
            .free_buffers = std.ArrayList([]align(std.mem.page_size) u8){ .allocator = allocator },
            .active_buffers = std.AutoHashMap(usize, BufferInfo).init(allocator),
            .mutex = std.Thread.Mutex{},
        };
    }

    pub fn deinit(self: *BufferPool) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.free_buffers.items) |buffer| {
            self.allocator.free(buffer);
        }
        self.free_buffers.deinit();

        var iter = self.active_buffers.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.buffer);
        }
        self.active_buffers.deinit();
    }

    pub fn acquire(self: *BufferPool, size: usize) ![]align(std.mem.page_size) u8 {
        const aligned_size = std.mem.alignForward(usize, size, self.page_size);
        
        self.mutex.lock();
        defer self.mutex.unlock();

        // Check free list first
        var i: usize = 0;
        while (i < self.free_buffers.items.len) : (i += 1) {
            if (self.free_buffers.items[i].len >= aligned_size) {
                const buffer = self.free_buffers.orderedRemove(i);
                const ptr = @intFromPtr(buffer.ptr);
                try self.active_buffers.put(ptr, .{
                    .buffer = buffer,
                    .ref_count = 1,
                    .pinned = false,
                });
                return buffer[0..size];
            }
        }

        // Allocate new buffer
        const buffer = try self.allocator.alignedAlloc(u8, self.page_size, aligned_size);
        const ptr = @intFromPtr(buffer.ptr);
        try self.active_buffers.put(ptr, .{
            .buffer = buffer,
            .ref_count = 1,
            .pinned = false,
        });
        return buffer[0..size];
    }

    pub fn release(self: *BufferPool, buffer: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const ptr = @intFromPtr(buffer.ptr);
        if (self.active_buffers.getPtr(ptr)) |info| {
            info.ref_count -= 1;
            if (info.ref_count == 0 and !info.pinned) {
                const full_buffer = info.buffer;
                _ = self.active_buffers.remove(ptr);
                self.free_buffers.append(self.allocator, full_buffer) catch {
                    // If we can't add to free list, just deallocate
                    self.allocator.free(full_buffer);
                };
            }
        }
    }

    pub fn pin(self: *BufferPool, buffer: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const ptr = @intFromPtr(buffer.ptr);
        if (self.active_buffers.getPtr(ptr)) |info| {
            info.pinned = true;
        } else {
            return ZeroCopyError.InvalidHandle;
        }
    }

    pub fn unpin(self: *BufferPool, buffer: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const ptr = @intFromPtr(buffer.ptr);
        if (self.active_buffers.getPtr(ptr)) |info| {
            info.pinned = false;
            if (info.ref_count == 0) {
                const full_buffer = info.buffer;
                _ = self.active_buffers.remove(ptr);
                self.free_buffers.append(self.allocator, full_buffer) catch {
                    self.allocator.free(full_buffer);
                };
            }
        }
    }
};

pub const ZeroCopyIo = struct {
    buffer_pool: *BufferPool,

    pub fn init(buffer_pool: *BufferPool) ZeroCopyIo {
        return .{ .buffer_pool = buffer_pool };
    }

    pub fn readZeroCopy(self: ZeroCopyIo, io: Io, handle: Handle, size: usize) ![]align(std.mem.page_size) u8 {
        const buffer = try self.buffer_pool.acquire(size);
        errdefer self.buffer_pool.release(buffer);

        const bytes_read = try io.read(handle, buffer);
        if (bytes_read < buffer.len) {
            return buffer[0..bytes_read];
        }
        return buffer;
    }

    pub fn writeZeroCopy(self: ZeroCopyIo, io: Io, handle: Handle, data: []const u8) !usize {
        // For zero-copy write, we need to ensure the buffer is properly aligned
        if (@intFromPtr(data.ptr) % std.mem.page_size != 0) {
            // Fallback to regular write if not aligned
            return io.write(handle, data);
        }

        // Pin the buffer during write operation
        try self.buffer_pool.pin(data);
        defer self.buffer_pool.unpin(data);

        return io.write(handle, data);
    }

    pub fn sendfileZeroCopy(self: ZeroCopyIo, io: Io, out_fd: Handle, in_fd: Handle, offset: ?u64, count: usize) !usize {
        if (builtin.os.tag == .linux) {
            // Use sendfile system call on Linux for true zero-copy
            return self.sendfileLinux(io, out_fd, in_fd, offset, count);
        } else if (builtin.os.tag == .macos) {
            // Use sendfile on macOS
            return self.sendfileDarwin(io, out_fd, in_fd, offset, count);
        } else {
            // Fallback to read/write for other platforms
            return self.sendfileFallback(io, out_fd, in_fd, offset, count);
        }
    }

    fn sendfileLinux(self: ZeroCopyIo, io: Io, out_fd: Handle, in_fd: Handle, offset: ?u64, count: usize) !usize {
        _ = self;
        var off = offset;
        const result = try io.sendfile(out_fd, in_fd, &off, count);
        return result;
    }

    fn sendfileDarwin(self: ZeroCopyIo, io: Io, out_fd: Handle, in_fd: Handle, offset: ?u64, count: usize) !usize {
        _ = self;
        const off = offset orelse 0;
        var len = count;
        try io.sendfile(in_fd, out_fd, off, &len, null, 0);
        return len;
    }

    fn sendfileFallback(self: ZeroCopyIo, io: Io, out_fd: Handle, in_fd: Handle, offset: ?u64, count: usize) !usize {
        const buffer = try self.buffer_pool.acquire(@min(count, 64 * 1024)); // 64KB chunks
        defer self.buffer_pool.release(buffer);

        if (offset) |off| {
            try io.lseek(in_fd, @intCast(off), .set);
        }

        var total_transferred: usize = 0;
        while (total_transferred < count) {
            const to_read = @min(buffer.len, count - total_transferred);
            const bytes_read = try io.read(in_fd, buffer[0..to_read]);
            if (bytes_read == 0) break;

            var written: usize = 0;
            while (written < bytes_read) {
                written += try io.write(out_fd, buffer[written..bytes_read]);
            }
            total_transferred += written;
        }

        return total_transferred;
    }

    pub fn spliceZeroCopy(self: ZeroCopyIo, io: Io, in_fd: Handle, out_fd: Handle, count: usize) !usize {
        if (builtin.os.tag == .linux) {
            // Use splice system call on Linux for pipe-to-pipe zero-copy
            return self.spliceLinux(io, in_fd, out_fd, count);
        } else {
            // Fallback to sendfile or read/write
            return self.sendfileZeroCopy(io, out_fd, in_fd, null, count);
        }
    }

    fn spliceLinux(self: ZeroCopyIo, io: Io, in_fd: Handle, out_fd: Handle, count: usize) !usize {
        _ = self;
        const SPLICE_F_MOVE = 1;
        const SPLICE_F_MORE = 4;
        const flags = SPLICE_F_MOVE | SPLICE_F_MORE;
        
        return io.splice(in_fd, null, out_fd, null, count, flags);
    }

    pub fn mmapZeroCopy(self: ZeroCopyIo, io: Io, handle: Handle, size: usize, offset: u64) ![]align(std.mem.page_size) u8 {
        _ = self;
        const prot = std.os.PROT.READ | std.os.PROT.WRITE;
        const flags = std.os.MAP.SHARED;
        
        const ptr = try io.mmap(null, size, prot, flags, handle, offset);
        return @as([*]align(std.mem.page_size) u8, @ptrCast(@alignCast(ptr)))[0..size];
    }

    pub fn munmapZeroCopy(self: ZeroCopyIo, io: Io, buffer: []align(std.mem.page_size) u8) !void {
        _ = self;
        try io.munmap(@ptrCast(buffer.ptr), buffer.len);
    }
};

pub const ZeroCopyStream = struct {
    io: Io,
    zero_copy: *ZeroCopyIo,
    read_handle: ?Handle,
    write_handle: ?Handle,
    buffer_size: usize,

    pub fn init(io: Io, zero_copy: *ZeroCopyIo, buffer_size: usize) ZeroCopyStream {
        return .{
            .io = io,
            .zero_copy = zero_copy,
            .read_handle = null,
            .write_handle = null,
            .buffer_size = buffer_size,
        };
    }

    pub fn setReadHandle(self: *ZeroCopyStream, handle: Handle) void {
        self.read_handle = handle;
    }

    pub fn setWriteHandle(self: *ZeroCopyStream, handle: Handle) void {
        self.write_handle = handle;
    }

    pub fn transferZeroCopy(self: *ZeroCopyStream, count: usize) !usize {
        const in_handle = self.read_handle orelse return ZeroCopyError.InvalidHandle;
        const out_handle = self.write_handle orelse return ZeroCopyError.InvalidHandle;

        // Try splice first (Linux pipe-to-pipe)
        if (builtin.os.tag == .linux) {
            return self.zero_copy.spliceZeroCopy(self.io, in_handle, out_handle, count) catch |err| switch (err) {
                error.SystemResources => {
                    // Fallback to sendfile
                    return self.zero_copy.sendfileZeroCopy(self.io, out_handle, in_handle, null, count);
                },
                else => return err,
            };
        }

        // Try sendfile
        return self.zero_copy.sendfileZeroCopy(self.io, out_handle, in_handle, null, count);
    }

    pub fn pipeZeroCopy(self: *ZeroCopyStream, transformer: anytype) !void {
        const in_handle = self.read_handle orelse return ZeroCopyError.InvalidHandle;
        const out_handle = self.write_handle orelse return ZeroCopyError.InvalidHandle;

        while (true) {
            const buffer = try self.zero_copy.readZeroCopy(self.io, in_handle, self.buffer_size);
            defer self.zero_copy.buffer_pool.release(buffer);

            if (buffer.len == 0) break;

            // Apply transformation
            const transformed = try transformer.transform(buffer);
            
            var written: usize = 0;
            while (written < transformed.len) {
                written += try self.zero_copy.writeZeroCopy(self.io, out_handle, transformed[written..]);
            }
        }
    }
};

// Ring buffer for zero-copy circular buffer operations
pub const ZeroCopyRingBuffer = struct {
    buffer: []align(std.mem.page_size) u8,
    read_idx: usize,
    write_idx: usize,
    size: usize,
    mutex: std.Thread.Mutex,
    not_empty: std.Thread.Condition,
    not_full: std.Thread.Condition,

    pub fn init(allocator: std.mem.Allocator, size: usize) !ZeroCopyRingBuffer {
        const aligned_size = std.mem.alignForward(usize, size, std.mem.page_size);
        const buffer = try allocator.alignedAlloc(u8, std.mem.page_size, aligned_size);
        
        return .{
            .buffer = buffer,
            .read_idx = 0,
            .write_idx = 0,
            .size = 0,
            .mutex = std.Thread.Mutex{},
            .not_empty = std.Thread.Condition{},
            .not_full = std.Thread.Condition{},
        };
    }

    pub fn deinit(self: *ZeroCopyRingBuffer, allocator: std.mem.Allocator) void {
        allocator.free(self.buffer);
    }

    pub fn writeableSlice(self: *ZeroCopyRingBuffer) !struct { ptr: [*]u8, len: usize } {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.size == self.buffer.len) {
            self.not_full.wait(&self.mutex);
        }

        const available = self.buffer.len - self.size;
        const contiguous = if (self.write_idx >= self.read_idx)
            self.buffer.len - self.write_idx
        else
            self.read_idx - self.write_idx;

        const len = @min(available, contiguous);
        return .{ .ptr = self.buffer.ptr + self.write_idx, .len = len };
    }

    pub fn commitWrite(self: *ZeroCopyRingBuffer, len: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.write_idx = (self.write_idx + len) % self.buffer.len;
        self.size += len;
        self.not_empty.signal();
    }

    pub fn readableSlice(self: *ZeroCopyRingBuffer) !struct { ptr: [*]const u8, len: usize } {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.size == 0) {
            self.not_empty.wait(&self.mutex);
        }

        const contiguous = if (self.read_idx <= self.write_idx)
            self.write_idx - self.read_idx
        else
            self.buffer.len - self.read_idx;

        const len = @min(self.size, contiguous);
        return .{ .ptr = self.buffer.ptr + self.read_idx, .len = len };
    }

    pub fn commitRead(self: *ZeroCopyRingBuffer, len: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.read_idx = (self.read_idx + len) % self.buffer.len;
        self.size -= len;
        self.not_full.signal();
    }
};