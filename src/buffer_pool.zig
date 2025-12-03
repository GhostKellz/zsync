//! zsync - Buffer Pool with Zero-Copy Optimization
//! Efficient buffer management with sendfile/splice support

const std = @import("std");
const builtin = @import("builtin");

/// Configuration for buffer pool
pub const BufferPoolConfig = struct {
    /// Number of buffers to pre-allocate
    initial_capacity: usize = 64,
    /// Size of each buffer
    buffer_size: usize = 16384, // 16KB default
    /// Maximum number of buffers to cache
    max_cached: usize = 256,
    /// Enable zero-copy operations when available
    enable_zero_copy: bool = true,
};

/// A pooled buffer that gets returned to the pool on deinit
pub const PooledBuffer = struct {
    data: []u8,
    pool: *BufferPool,
    in_use: bool,

    const Self = @This();

    /// Get the buffer data
    pub fn slice(self: *Self) []u8 {
        return self.data;
    }

    /// Return buffer to pool
    pub fn release(self: *Self) void {
        if (!self.in_use) return;
        self.in_use = false;
        self.pool.returnBuffer(self);
    }
};

/// Buffer pool for efficient memory reuse
pub const BufferPool = struct {
    allocator: std.mem.Allocator,
    config: BufferPoolConfig,
    available: std.ArrayList(*PooledBuffer),
    all_buffers: std.ArrayList(*PooledBuffer),
    mutex: std.Thread.Mutex,
    total_allocated: std.atomic.Value(usize),
    total_in_use: std.atomic.Value(usize),

    const Self = @This();

    /// Initialize a new buffer pool
    pub fn init(allocator: std.mem.Allocator, config: BufferPoolConfig) !*Self {
        const pool = try allocator.create(Self);
        pool.* = Self{
            .allocator = allocator,
            .config = config,
            .available = .{},
            .all_buffers = .{},
            .mutex = .{},
            .total_allocated = std.atomic.Value(usize).init(0),
            .total_in_use = std.atomic.Value(usize).init(0),
        };

        // Pre-allocate initial buffers
        var i: usize = 0;
        while (i < config.initial_capacity) : (i += 1) {
            const buffer = try pool.createBuffer();
            try pool.available.append(allocator, buffer);
            try pool.all_buffers.append(allocator, buffer);
        }

        _ = pool.total_allocated.fetchAdd(config.initial_capacity, .release);

        return pool;
    }

    /// Create a new buffer
    fn createBuffer(self: *Self) !*PooledBuffer {
        const buffer = try self.allocator.create(PooledBuffer);
        const data = try self.allocator.alloc(u8, self.config.buffer_size);

        buffer.* = PooledBuffer{
            .data = data,
            .pool = self,
            .in_use = false,
        };

        return buffer;
    }

    /// Acquire a buffer from the pool
    pub fn acquire(self: *Self) !*PooledBuffer {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Try to get from available pool
        if (self.available.items.len > 0) {
            const buffer = self.available.pop().?;
            buffer.in_use = true;
            _ = self.total_in_use.fetchAdd(1, .release);
            return buffer;
        }

        // Create new buffer if under max
        if (self.all_buffers.items.len < self.config.max_cached) {
            const buffer = try self.createBuffer();
            try self.all_buffers.append(self.allocator, buffer);
            buffer.in_use = true;
            _ = self.total_allocated.fetchAdd(1, .release);
            _ = self.total_in_use.fetchAdd(1, .release);
            return buffer;
        }

        // Pool exhausted
        return error.BufferPoolExhausted;
    }

    /// Return a buffer to the pool
    fn returnBuffer(self: *Self, buffer: *PooledBuffer) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.available.items.len < self.config.max_cached) {
            self.available.append(self.allocator, buffer) catch {
                // If append fails, just mark as not in use
                buffer.in_use = false;
                _ = self.total_in_use.fetchSub(1, .release);
                return;
            };
            _ = self.total_in_use.fetchSub(1, .release);
        }
    }

    /// Clean up pool resources
    pub fn deinit(self: *Self) void {
        self.mutex.lock();

        // Free all buffers
        for (self.all_buffers.items) |buffer| {
            self.allocator.free(buffer.data);
            self.allocator.destroy(buffer);
        }

        self.all_buffers.deinit(self.allocator);
        self.available.deinit(self.allocator);

        // Unlock before destroying self to avoid use-after-free
        self.mutex.unlock();

        const allocator = self.allocator;
        allocator.destroy(self);
    }

    /// Get pool statistics
    pub fn stats(self: *Self) PoolStats {
        return PoolStats{
            .total_allocated = self.total_allocated.load(.acquire),
            .total_in_use = self.total_in_use.load(.acquire),
            .available = self.available.items.len,
        };
    }
};

pub const PoolStats = struct {
    total_allocated: usize,
    total_in_use: usize,
    available: usize,
};

/// Zero-copy file transfer using sendfile (Linux/BSD)
pub fn sendfile(out_fd: std.posix.fd_t, in_fd: std.posix.fd_t, offset: ?*i64, count: usize) !usize {
    if (builtin.os.tag == .linux) {
        return std.posix.sendfile(out_fd, in_fd, offset, count);
    } else if (builtin.os.tag == .freebsd or builtin.os.tag == .macos) {
        // BSD-style sendfile
        var sent: i64 = 0;
        const rc = std.c.sendfile(in_fd, out_fd, if (offset) |o| o.* else 0, count, null, &sent, 0);
        if (rc != 0) {
            return error.SendfileFailed;
        }
        if (offset) |o| {
            o.* += sent;
        }
        return @intCast(sent);
    } else {
        // Fallback: not supported on this platform
        return error.SendfileNotSupported;
    }
}

/// Zero-copy pipe transfer using splice (Linux only)
pub fn splice(
    fd_in: std.posix.fd_t,
    off_in: ?*i64,
    fd_out: std.posix.fd_t,
    off_out: ?*i64,
    len: usize,
    flags: u32,
) !usize {
    if (builtin.os.tag != .linux) {
        return error.SpliceNotSupported;
    }

    const rc = std.os.linux.splice(fd_in, off_in, fd_out, off_out, len, flags);
    return switch (std.posix.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .INVAL => error.InvalidArgument,
        .BADF => error.BadFileDescriptor,
        .NOMEM => error.OutOfMemory,
        .AGAIN => error.WouldBlock,
        else => error.SpliceFailed,
    };
}

/// Helper to copy file to file using zero-copy when possible
pub fn copyFileZeroCopy(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    dest_path: []const u8,
) !usize {
    const source = try std.fs.cwd().openFile(source_path, .{});
    defer source.close();

    const dest = try std.fs.cwd().createFile(dest_path, .{});
    defer dest.close();

    const stat = try source.stat();
    const size = stat.size;

    // Try zero-copy sendfile first
    if (builtin.os.tag == .linux or builtin.os.tag == .freebsd or builtin.os.tag == .macos) {
        var offset: i64 = 0;
        sendfile(dest.handle, source.handle, &offset, size) catch |err| {
            // Fallback to regular copy if sendfile fails
            std.debug.print("sendfile failed: {}, using fallback\n", .{err});
            return copyFileFallback(allocator, source, dest);
        };
        return size;
    }

    // Fallback for other platforms
    return copyFileFallback(allocator, source, dest);
}

fn copyFileFallback(allocator: std.mem.Allocator, source: std.fs.File, dest: std.fs.File) !usize {
    var total: usize = 0;
    var buffer = try allocator.alloc(u8, 16384);
    defer allocator.free(buffer);

    while (true) {
        const bytes_read = try source.read(buffer);
        if (bytes_read == 0) break;

        try dest.writeAll(buffer[0..bytes_read]);
        total += bytes_read;
    }

    return total;
}

// Tests
test "buffer pool basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const config = BufferPoolConfig{
        .initial_capacity = 4,
        .buffer_size = 1024,
        .max_cached = 8,
    };

    const pool = try BufferPool.init(allocator, config);
    defer pool.deinit();

    // Acquire a buffer
    const buffer1 = try pool.acquire();
    try testing.expect(buffer1.in_use);
    try testing.expectEqual(@as(usize, 1024), buffer1.data.len);

    // Acquire another
    const buffer2 = try pool.acquire();
    try testing.expect(buffer2.in_use);

    // Check stats
    const pool_stats = pool.stats();
    try testing.expectEqual(@as(usize, 2), pool_stats.total_in_use);

    // Release buffers
    buffer1.release();
    buffer2.release();

    const final_stats = pool.stats();
    try testing.expectEqual(@as(usize, 0), final_stats.total_in_use);
}

test "buffer pool reuse" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const config = BufferPoolConfig{
        .initial_capacity = 2,
        .buffer_size = 512,
        .max_cached = 4,
    };

    const pool = try BufferPool.init(allocator, config);
    defer pool.deinit();

    // Acquire, write, release
    {
        const buffer = try pool.acquire();
        defer buffer.release();
        @memcpy(buffer.data[0..5], "Hello");
    }

    // Acquire again - should reuse same buffer
    {
        const buffer = try pool.acquire();
        defer buffer.release();
        // Buffer is reused but data is not cleared
        try testing.expectEqual(@as(u8, 'H'), buffer.data[0]);
    }
}
