//! zsync- Modern ThreadPoolIo Implementation
//! Uses a pool of OS threads to execute blocking I/O operations
//! Provides parallelism for I/O-bound workloads with full cancellation support

const std = @import("std");
const builtin = @import("builtin");
const compat = @import("compat/thread.zig");
const io_interface = @import("io_interface.zig");

const Io = io_interface.Io;
const Future = io_interface.Future;
const IoError = io_interface.IoError;
const IoBuffer = io_interface.IoBuffer;
const IoResult = io_interface.IoResult;

/// Configuration for thread pool
pub const ThreadPoolConfig = struct {
    num_threads: u32 = 4,
    max_queue_size: u32 = 1024,
    stack_size: ?usize = null,
};

/// Task to be executed in thread pool
const Task = struct {
    operation: IoOperation,
    future: *ThreadPoolFuture,

    const IoOperation = union(enum) {
        read: struct { fd: std.posix.fd_t, buffer: []u8 },
        write: struct { fd: std.posix.fd_t, data: []const u8 },
        readv: struct { fd: std.posix.fd_t, buffers: []IoBuffer },
        writev: struct { fd: std.posix.fd_t, buffers: []const []const u8 },
        accept: struct { listener_fd: std.posix.fd_t },
        // Store sockaddr by value (using storage for max size) to avoid pointer-to-stack issues
        connect: struct {
            fd: std.posix.fd_t,
            addr_storage: std.os.linux.sockaddr.storage,
            addr_len: std.posix.socklen_t,
        },
        send_file: struct { src_fd: std.posix.fd_t, dst_fd: std.posix.fd_t, offset: u64, count: u64 },
        copy_file_range: struct { src_fd: std.posix.fd_t, dst_fd: std.posix.fd_t, count: u64 },
        close: struct { fd: std.posix.fd_t },
    };
};

/// Thread pool future that can be cancelled
const ThreadPoolFuture = struct {
    result_ptr: ?*IoError!IoResult,
    result_mutex: compat.Mutex,
    cancelled: std.atomic.Value(bool),
    allocator: std.mem.Allocator,

    const Self = @This();

    fn init(allocator: std.mem.Allocator) !*Self {
        const future = try allocator.create(Self);
        future.* = Self{
            .result_ptr = null,
            .result_mutex = compat.Mutex{},
            .cancelled = std.atomic.Value(bool).init(false),
            .allocator = allocator,
        };
        return future;
    }

    fn poll(context: *anyopaque) Future.PollResult {
        const self: *Self = @ptrCast(@alignCast(context));

        if (self.cancelled.load(.acquire)) {
            return .cancelled;
        }

        self.result_mutex.lock();
        defer self.result_mutex.unlock();

        if (self.result_ptr) |result_ptr| {
            _ = result_ptr.* catch |err| return .{ .err = err };
            return .ready;
        }

        return .pending;
    }

    fn cancel(context: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(context));
        _ = self.cancelled.swap(true, .acq_rel);
    }

    fn destroy(context: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *Self = @ptrCast(@alignCast(context));

        self.result_mutex.lock();
        if (self.result_ptr) |result_ptr| {
            allocator.destroy(result_ptr);
        }
        self.result_mutex.unlock();

        allocator.destroy(self);
    }

    fn getResult(context: *anyopaque) ?IoResult {
        const self: *Self = @ptrCast(@alignCast(context));

        self.result_mutex.lock();
        defer self.result_mutex.unlock();

        if (self.result_ptr) |result_ptr| {
            return result_ptr.* catch null;
        }
        return null;
    }

    fn setResult(self: *Self, result: IoError!IoResult) void {
        self.result_mutex.lock();
        defer self.result_mutex.unlock();

        const result_copy = self.allocator.create(@TypeOf(result)) catch return;
        result_copy.* = result;
        self.result_ptr = result_copy;
    }

    const vtable = Future.FutureVTable{
        .poll = poll,
        .cancel = cancel,
        .destroy = destroy,
        .get_result = getResult,
    };

    pub fn toFuture(self: *Self) Future {
        return Future.init(self.allocator, &vtable, self);
    }
};

/// Thread-safe task queue with proper condition-based waiting
const TaskQueue = struct {
    tasks: std.ArrayList(Task),
    mutex: compat.Mutex,
    condition: compat.Condition,
    allocator: std.mem.Allocator,
    shutdown: bool = false,

    const Self = @This();

    fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .tasks = std.ArrayList(Task).empty,
            .mutex = compat.Mutex{},
            .condition = compat.Condition{},
            .allocator = allocator,
            .shutdown = false,
        };
    }

    fn deinit(self: *Self) void {
        self.mutex.lock();
        self.shutdown = true;
        self.condition.broadcast();
        self.mutex.unlock();
        self.tasks.deinit(self.allocator);
    }

    fn put(self: *Self, task: Task) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.tasks.append(self.allocator, task);
        self.condition.signal();
    }

    /// Block until a task is available or shutdown is signaled
    fn get(self: *Self) ?Task {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Wait until we have tasks or shutdown is requested
        while (self.tasks.items.len == 0 and !self.shutdown) {
            self.condition.wait(&self.mutex);
        }

        // Check for shutdown after waking
        if (self.shutdown and self.tasks.items.len == 0) {
            return null;
        }

        return self.tasks.orderedRemove(0);
    }

    /// Non-blocking attempt to get a task
    fn tryGet(self: *Self) ?Task {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.tasks.items.len == 0) {
            return null;
        }

        return self.tasks.orderedRemove(0);
    }
};

/// Worker thread in the pool
const Worker = struct {
    thread: std.Thread,
    id: u32,
    pool: *ThreadPoolIo,

    const Self = @This();

    fn run(self: *Self) void {
        while (self.pool.running.load(.acquire)) {
            // Block waiting for task or shutdown signal
            if (self.pool.taskQueue.get()) |task| {
                if (!task.future.cancelled.load(.acquire)) {
                    const result = self.executeTask(task);
                    task.future.setResult(result);
                }
            } else {
                // get() returned null - shutdown was signaled
                break;
            }
        }
    }

    fn executeTask(self: *Self, task: Task) IoError!IoResult {
        _ = self;

        return switch (task.operation) {
            .read => |op| blk: {
                const bytes_read = std.posix.read(op.fd, op.buffer) catch |err| {
                    break :blk IoResult{
                        .bytes_transferred = 0,
                        .error_code = switch (err) {
                            error.WouldBlock => IoError.WouldBlock,
                            error.BrokenPipe => IoError.BrokenPipe,
                            error.ConnectionResetByPeer => IoError.ConnectionClosed,
                            else => IoError.SystemResources,
                        },
                    };
                };
                break :blk IoResult{
                    .bytes_transferred = bytes_read,
                    .error_code = null,
                };
            },

            .write => |op| blk: {
                const bytes_written = std.posix.write(op.fd, op.data) catch |err| {
                    break :blk IoResult{
                        .bytes_transferred = 0,
                        .error_code = switch (err) {
                            error.BrokenPipe => IoError.BrokenPipe,
                            error.ConnectionResetByPeer => IoError.ConnectionClosed,
                            else => IoError.SystemResources,
                        },
                    };
                };
                break :blk IoResult{
                    .bytes_transferred = bytes_written,
                    .error_code = null,
                };
            },

            .readv => |op| blk: {
                var total_read: usize = 0;
                for (op.buffers) |*buffer| {
                    const bytes_read = std.posix.read(op.fd, buffer.available()) catch break;
                    if (bytes_read == 0) break; // EOF
                    buffer.advance(bytes_read);
                    total_read += bytes_read;
                }

                break :blk IoResult{
                    .bytes_transferred = total_read,
                    .error_code = null,
                };
            },

            .writev => |op| blk: {
                var total_written: usize = 0;
                for (op.buffers) |data| {
                    const bytes_written = std.posix.write(op.fd, data) catch break;
                    total_written += bytes_written;
                }

                break :blk IoResult{
                    .bytes_transferred = total_written,
                    .error_code = null,
                };
            },

            .accept => |op| blk: {
                var client_addr: std.posix.sockaddr = undefined;
                var addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);

                const client_fd = std.posix.accept(op.listener_fd, @ptrCast(&client_addr), &addr_len, 0) catch |err| {
                    break :blk IoResult{
                        .bytes_transferred = 0,
                        .error_code = switch (err) {
                            error.WouldBlock => IoError.WouldBlock,
                            error.ConnectionAborted => IoError.ConnectionClosed,
                            error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded => IoError.SystemResources,
                            else => IoError.SystemResources,
                        },
                    };
                };

                break :blk IoResult{
                    .bytes_transferred = @intCast(client_fd),
                    .error_code = null,
                };
            },

            .connect => |op| blk: {
                // Use the owned sockaddr storage with correct length
                const addr_ptr: *const std.posix.sockaddr = @ptrCast(&op.addr_storage);
                std.posix.connect(op.fd, addr_ptr, op.addr_len) catch |err| {
                    break :blk IoResult{
                        .bytes_transferred = 0,
                        .error_code = switch (err) {
                            error.WouldBlock => IoError.WouldBlock,
                            error.ConnectionRefused => IoError.ConnectionClosed,
                            error.NetworkUnreachable => IoError.NetworkUnreachable,
                            error.PermissionDenied => IoError.AccessDenied,
                            else => IoError.SystemResources,
                        },
                    };
                };

                break :blk IoResult{
                    .bytes_transferred = 0,
                    .error_code = null,
                };
            },

            .send_file => |op| blk: {
                _ = op;
                // send_file/zero-copy not yet implemented
                break :blk IoResult{
                    .bytes_transferred = 0,
                    .error_code = IoError.NotSupported,
                };
            },

            .copy_file_range => |op| blk: {
                const bytes_copied = if (builtin.os.tag == .linux) blk2: {
                    const src_offset: u64 = 0;
                    const dst_offset: u64 = 0;
                    break :blk2 std.posix.copy_file_range(op.src_fd, src_offset, op.dst_fd, dst_offset, op.count, 0) catch 0;
                } else blk2: {
                    // Manual copy for other platforms
                    var buffer: [65536]u8 = undefined;
                    var total_copied: usize = 0;
                    var remaining = op.count;

                    while (remaining > 0) {
                        const to_read = @min(remaining, buffer.len);
                        const bytes_read = std.posix.read(op.src_fd, buffer[0..to_read]) catch break;
                        if (bytes_read == 0) break;

                        const bytes_written = std.posix.write(op.dst_fd, buffer[0..bytes_read]) catch break;
                        total_copied += bytes_written;
                        remaining -= bytes_read;

                        if (bytes_written < bytes_read) break;
                    }

                    break :blk2 total_copied;
                };

                break :blk IoResult{
                    .bytes_transferred = bytes_copied,
                    .error_code = null,
                };
            },

            .close => |op| blk: {
                std.Io.Threaded.closeFd(op.fd);
                break :blk IoResult{
                    .bytes_transferred = 0,
                    .error_code = null,
                };
            },
        };
    }
};

/// Thread pool I/O implementation
pub const ThreadPoolIo = struct {
    allocator: std.mem.Allocator,
    config: ThreadPoolConfig,
    workers: []Worker,
    taskQueue: TaskQueue,
    running: std.atomic.Value(bool),

    const Self = @This();

    /// Initialize thread pool
    pub fn init(allocator: std.mem.Allocator, config: ThreadPoolConfig) !Self {
        var self = Self{
            .allocator = allocator,
            .config = config,
            .workers = undefined,
            .taskQueue = TaskQueue.init(allocator),
            .running = std.atomic.Value(bool).init(true),
        };

        // Create worker threads
        self.workers = try allocator.alloc(Worker, config.num_threads);
        for (self.workers, 0..) |*worker, i| {
            worker.* = Worker{
                .thread = undefined,
                .id = @intCast(i),
                .pool = &self,
            };

            worker.thread = try std.Thread.spawn(.{
                .stack_size = config.stack_size orelse 16 * 1024 * 1024, // 16MB default stack
            }, Worker.run, .{worker});
        }

        return self;
    }

    /// Shutdown thread pool
    pub fn deinit(self: *Self) void {
        self.running.store(false, .release);

        // Signal task queue to wake up threads
        self.taskQueue.mutex.lock();
        self.taskQueue.shutdown = true;
        self.taskQueue.condition.broadcast();
        self.taskQueue.mutex.unlock();

        // Wait for all workers to finish
        for (self.workers) |*worker| {
            worker.thread.join();
        }

        self.allocator.free(self.workers);
        self.taskQueue.deinit();
    }

    /// Get Io interface
    pub fn io(self: *Self) Io {
        return Io.init(&vtable, self);
    }

    // Implementation functions
    fn read(context: *anyopaque, buffer: []u8) IoError!Future {
        const self: *Self = @ptrCast(@alignCast(context));

        const future = try ThreadPoolFuture.init(self.allocator);
        const task = Task{
            .operation = .{ .read = .{ .fd = std.posix.STDIN_FILENO, .buffer = buffer } },
            .future = future,
        };

        try self.taskQueue.put(task);
        return future.toFuture();
    }

    fn write(context: *anyopaque, data: []const u8) IoError!Future {
        const self: *Self = @ptrCast(@alignCast(context));

        const future = try ThreadPoolFuture.init(self.allocator);
        const task = Task{
            .operation = .{ .write = .{ .fd = std.posix.STDOUT_FILENO, .data = data } },
            .future = future,
        };

        try self.taskQueue.put(task);
        return future.toFuture();
    }

    fn readv(context: *anyopaque, buffers: []IoBuffer) IoError!Future {
        const self: *Self = @ptrCast(@alignCast(context));

        const future = try ThreadPoolFuture.init(self.allocator);
        const task = Task{
            .operation = .{ .readv = .{ .fd = std.posix.STDIN_FILENO, .buffers = buffers } },
            .future = future,
        };

        try self.taskQueue.put(task);
        return future.toFuture();
    }

    fn writev(context: *anyopaque, buffers: []const []const u8) IoError!Future {
        const self: *Self = @ptrCast(@alignCast(context));

        const future = try ThreadPoolFuture.init(self.allocator);
        const task = Task{
            .operation = .{ .writev = .{ .fd = std.posix.STDOUT_FILENO, .buffers = buffers } },
            .future = future,
        };

        try self.taskQueue.put(task);
        return future.toFuture();
    }

    fn send_file(context: *anyopaque, src_fd: std.posix.fd_t, offset: u64, count: u64) IoError!Future {
        const self: *Self = @ptrCast(@alignCast(context));

        const future = try ThreadPoolFuture.init(self.allocator);
        const task = Task{
            .operation = .{ .send_file = .{
                .src_fd = src_fd,
                .dst_fd = std.posix.STDOUT_FILENO,
                .offset = offset,
                .count = count,
            } },
            .future = future,
        };

        try self.taskQueue.put(task);
        return future.toFuture();
    }

    fn copy_file_range(context: *anyopaque, src_fd: std.posix.fd_t, dst_fd: std.posix.fd_t, count: u64) IoError!Future {
        const self: *Self = @ptrCast(@alignCast(context));

        const future = try ThreadPoolFuture.init(self.allocator);
        const task = Task{
            .operation = .{ .copy_file_range = .{
                .src_fd = src_fd,
                .dst_fd = dst_fd,
                .count = count,
            } },
            .future = future,
        };

        try self.taskQueue.put(task);
        return future.toFuture();
    }

    fn accept(context: *anyopaque, listener_fd: std.posix.fd_t) IoError!Future {
        const self: *Self = @ptrCast(@alignCast(context));

        const future = try ThreadPoolFuture.init(self.allocator);
        const task = Task{
            .operation = .{ .accept = .{ .listener_fd = listener_fd } },
            .future = future,
        };

        try self.taskQueue.put(task);
        return future.toFuture();
    }

    fn connect(context: *anyopaque, fd: std.posix.fd_t, address: *const std.posix.sockaddr, addr_len: std.posix.socklen_t) IoError!Future {
        const self: *Self = @ptrCast(@alignCast(context));

        const future = try ThreadPoolFuture.init(self.allocator);

        // Copy sockaddr into owned storage to avoid pointer-to-stack issues
        // The address pointer is only valid during this call, so we must copy
        var addr_storage: std.os.linux.sockaddr.storage = undefined;
        const src_bytes: [*]const u8 = @ptrCast(address);
        const dst_bytes: [*]u8 = @ptrCast(&addr_storage);
        @memcpy(dst_bytes[0..addr_len], src_bytes[0..addr_len]);

        const task = Task{
            .operation = .{ .connect = .{
                .fd = fd,
                .addr_storage = addr_storage,
                .addr_len = addr_len,
            } },
            .future = future,
        };

        try self.taskQueue.put(task);
        return future.toFuture();
    }

    fn close(context: *anyopaque, fd: std.posix.fd_t) IoError!Future {
        const self: *Self = @ptrCast(@alignCast(context));

        const future = try ThreadPoolFuture.init(self.allocator);
        const task = Task{
            .operation = .{ .close = .{ .fd = fd } },
            .future = future,
        };

        try self.taskQueue.put(task);
        return future.toFuture();
    }

    fn shutdown(context: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(context));
        self.running.store(false, .release);
    }

    fn getMode(_: *anyopaque) io_interface.IoMode {
        return .evented;
    }

    fn supportsVectorized(_: *anyopaque) bool {
        return true;
    }

    fn supportsZeroCopy(_: *anyopaque) bool {
        // send_file is not yet implemented (returns 0), so report false
        return false;
    }

    fn getAllocator(context: *anyopaque) std.mem.Allocator {
        const self: *Self = @ptrCast(@alignCast(context));
        return self.allocator;
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
        .get_mode = getMode,
        .supports_vectorized = supportsVectorized,
        .supports_zero_copy = supportsZeroCopy,
        .get_allocator = getAllocator,
    };
};

// Tests
test "TaskQueue put and get" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var queue = TaskQueue.init(allocator);
    defer queue.deinit();

    // Create a mock future for testing
    const mock_future = try ThreadPoolFuture.init(allocator);
    defer allocator.destroy(mock_future);

    // Test put and tryGet
    const task = Task{
        .operation = .{ .close = .{ .fd = 42 } },
        .future = mock_future,
    };

    try queue.put(task);

    // Should get the task back
    const retrieved = queue.tryGet();
    try testing.expect(retrieved != null);
    try testing.expectEqual(@as(std.posix.fd_t, 42), retrieved.?.operation.close.fd);

    // Queue should be empty now
    const empty = queue.tryGet();
    try testing.expect(empty == null);
}

test "ThreadPoolFuture lifecycle" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create future
    const future_ptr = try ThreadPoolFuture.init(allocator);
    var future = future_ptr.toFuture();

    // Initially pending
    const poll1 = future.poll();
    try testing.expectEqual(Future.PollResult.pending, poll1);

    // Set a result
    future_ptr.setResult(IoResult{ .bytes_transferred = 100 });

    // Now should be ready
    const poll2 = future.poll();
    try testing.expectEqual(Future.PollResult.ready, poll2);

    // Cleanup
    future.destroy();
}

test "ThreadPoolFuture cancellation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create future
    const future_ptr = try ThreadPoolFuture.init(allocator);
    var future = future_ptr.toFuture();

    // Initially pending
    const poll1 = future.poll();
    try testing.expectEqual(Future.PollResult.pending, poll1);

    // Cancel the future
    future.cancel();

    // Now should be cancelled
    const poll2 = future.poll();
    try testing.expectEqual(Future.PollResult.cancelled, poll2);

    // Cleanup
    future.destroy();
}
