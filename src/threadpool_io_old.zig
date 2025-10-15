//! Zsync v0.4.0 - Modern ThreadPoolIo Implementation
//! Uses a pool of OS threads to execute blocking I/O operations
//! Provides parallelism for I/O-bound workloads with cancellation support

const std = @import("std");
const builtin = @import("builtin");
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
        accept: struct { listener_fd: std.posix.fd_t },
        connect: struct { fd: std.posix.fd_t, address: std.net.Address },
        send_file: struct { src_fd: std.posix.fd_t, dst_fd: std.posix.fd_t, offset: u64, count: u64 },
        close: struct { fd: std.posix.fd_t },
    };
};

/// Thread pool future that can be cancelled
const ThreadPoolFuture = struct {
    result: std.atomic.Value(?IoError!IoResult),
    cancelled: std.atomic.Value(bool),
    allocator: std.mem.Allocator,
    
    const Self = @This();
    
    fn init(allocator: std.mem.Allocator) !*Self {
        const future = try allocator.create(Self);
        future.* = Self{
            .result = std.atomic.Value(?IoError!IoResult).init(null),
            .cancelled = std.atomic.Value(bool).init(false),
            .allocator = allocator,
        };
        return future;
    }
    
    fn poll(context: *anyopaque) IoError!Future.PollResult {
        const self: *Self = @ptrCast(@alignCast(context));
        
        if (self.cancelled.load(.acquire)) {
            return IoError.Cancelled;
        }
        
        if (self.result.load(.acquire)) |result| {
            _ = result catch |err| return err;
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
        allocator.destroy(self);
    }
    
    fn setResult(self: *Self, result: IoError!IoResult) void {
        self.result.store(result, .release);
    }
    
    const vtable = Future.FutureVTable{
        .poll = poll,
        .cancel = cancel,
        .destroy = destroy,
    };
    
    pub fn toFuture(self: *Self) Future {
        return Future.init(&vtable, self);
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
            if (self.pool.taskQueue.get()) |task| {
                if (!task.future.cancelled.load(.acquire)) {
                    const result = self.executeTask(task);
                    task.future.setResult(result);
                }
            } else {
                // No tasks available, yield briefly
                std.time.sleep(1000_000); // 1ms
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
                            error.Interrupted => IoError.Interrupted,
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
            
            .accept => |op| blk: {
                var client_addr: std.posix.sockaddr = undefined;
                var addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);
                
                const client_fd = std.posix.accept(op.listener_fd, &client_addr, &addr_len) catch |err| {
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
                std.posix.connect(op.fd, &op.address.any, op.address.getOsSockLen()) catch |err| {
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
                const bytes_sent = if (builtin.os.tag == .linux) blk2: {
                    var sent_offset = op.offset;
                    break :blk2 std.posix.sendfile(op.dst_fd, op.src_fd, &sent_offset, op.count) catch 0;
                } else blk2: {
                    // Fallback manual copy
                    var buffer: [8192]u8 = undefined;
                    var total_copied: usize = 0;
                    var remaining = op.count;
                    
                    while (remaining > 0 and total_copied < op.count) {
                        const to_read = @min(remaining, buffer.len);
                        const bytes_read = std.posix.pread(op.src_fd, buffer[0..to_read], op.offset + total_copied) catch break;
                        if (bytes_read == 0) break;
                        
                        const bytes_written = std.posix.write(op.dst_fd, buffer[0..bytes_read]) catch break;
                        total_copied += bytes_written;
                        remaining -= bytes_read;
                        
                        if (bytes_written < bytes_read) break;
                    }
                    
                    break :blk2 total_copied;
                };
                
                break :blk IoResult{
                    .bytes_transferred = bytes_sent,
                    .error_code = null,
                };
            },
            
            .close => |op| blk: {
                std.posix.close(op.fd);
                break :blk IoResult{
                    .bytes_transferred = 0,
                    .error_code = null,
                };
            },
        };
    }
};

/// Simple thread-safe task queue
const TaskQueue = struct {
    tasks: std.ArrayList(Task),
    mutex: std.Thread.Mutex,
    condition: std.Thread.Condition,
    allocator: std.mem.Allocator,
    
    const Self = @This();
    
    fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .tasks = std.ArrayList(Task){ .allocator = allocator },
            .mutex = std.Thread.Mutex{},
            .condition = std.Thread.Condition{},
            .allocator = allocator,
        };
    }
    
    fn deinit(self: *Self) void {
        self.tasks.deinit();
    }
    
    fn put(self: *Self, task: Task) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        try self.tasks.append(self.allocator, task);
        self.condition.signal();
    }
    
    fn get(self: *Self) ?Task {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (self.tasks.items.len == 0) {
            return null;
        }
        
        return self.tasks.orderedRemove(0);
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
                .stack_size = config.stack_size orelse std.Thread.default_stack_size,
            }, Worker.run, .{worker});
        }
        
        return self;
    }
    
    /// Shutdown thread pool
    pub fn deinit(self: *Self) void {
        self.running.store(false, .release);
        
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
            .operation = .{ .read = .{ .fd = std.io.getStdIn().handle, .buffer = buffer } },
            .future = future,
        };
        
        try self.taskQueue.put(task);
        return future.toFuture();
    }
    
    fn write(context: *anyopaque, data: []const u8) IoError!Future {
        const self: *Self = @ptrCast(@alignCast(context));
        
        const future = try ThreadPoolFuture.init(self.allocator);
        const task = Task{
            .operation = .{ .write = .{ .fd = std.io.getStdOut().handle, .data = data } },
            .future = future,
        };
        
        try self.taskQueue.put(task);
        return future.toFuture();
    }
    
    fn readv(context: *anyopaque, buffers: []IoBuffer) IoError!Future {
        const self: *Self = @ptrCast(@alignCast(context));
        
        // For simplicity, read into the first buffer
        // A full implementation would handle multiple buffers
        if (buffers.len == 0) {
            const future = try ThreadPoolFuture.init(self.allocator);
            future.setResult(IoResult{ .bytes_transferred = 0, .error_code = null });
            return future.toFuture();
        }
        
        return self.read(context, buffers[0].available());
    }
    
    fn writev(context: *anyopaque, buffers: []const []const u8) IoError!Future {
        const self: *Self = @ptrCast(@alignCast(context));
        
        // For simplicity, write the first buffer
        // A full implementation would handle multiple buffers
        if (buffers.len == 0) {
            const future = try ThreadPoolFuture.init(self.allocator);
            future.setResult(IoResult{ .bytes_transferred = 0, .error_code = null });
            return future.toFuture();
        }
        
        return self.write(context, buffers[0]);
    }
    
    fn send_file(context: *anyopaque, src_fd: std.posix.fd_t, offset: u64, count: u64) IoError!Future {
        const self: *Self = @ptrCast(@alignCast(context));
        
        const future = try ThreadPoolFuture.init(self.allocator);
        const task = Task{
            .operation = .{ .send_file = .{
                .src_fd = src_fd,
                .dst_fd = std.io.getStdOut().handle,
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
            .operation = .{ .send_file = .{
                .src_fd = src_fd,
                .dst_fd = dst_fd,
                .offset = 0,
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
    
    fn connect(context: *anyopaque, fd: std.posix.fd_t, address: std.net.Address) IoError!Future {
        const self: *Self = @ptrCast(@alignCast(context));
        
        const future = try ThreadPoolFuture.init(self.allocator);
        const task = Task{
            .operation = .{ .connect = .{ .fd = fd, .address = address } },
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

// Helper functions
fn Ok(result: IoResult) IoError!IoResult {
    return result;
}

// Tests
test "ThreadPoolIo creation" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var pool = try ThreadPoolIo.init(allocator, .{ .num_threads = 2 });
    defer pool.deinit();
    
    const io = pool.io();
    _ = io; // Test that we can create the interface
}

test "ThreadPoolIo basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var pool = try ThreadPoolIo.init(allocator, .{ .num_threads = 1 });
    defer pool.deinit();
    
    const io = pool.io();
    
    // Test write operation
    var future = try io.async_write("Hello ThreadPool!");
    defer future.destroy(allocator);
    
    try future.await();
}

/// Thread pool worker state
const WorkerThread = struct {
    thread: std.Thread,
    last_active: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    should_terminate: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

/// Task queue abstraction
const TaskQueue = union(QueueType) {
    locked_fifo: struct {
        queue: std.fifo.LinearFifo(TaskRef, .Dynamic),
        mutex: std.Thread.Mutex = .{},
        condition: std.Thread.Condition = .{},
    },
    lock_free: lockfree.MPMCQueue(TaskRef),
    work_stealing: struct {
        global_queue: lockfree.LockFreeQueue(TaskRef),
        local_deques: std.ArrayList(lockfree.WorkStealingDeque(TaskRef)),
    },
    
    fn init(allocator: std.mem.Allocator, queue_type: QueueType, max_size: u32, num_threads: u32) !TaskQueue {
        return switch (queue_type) {
            .locked_fifo => TaskQueue{
                .locked_fifo = .{
                    .queue = std.fifo.LinearFifo(TaskRef, .Dynamic).init(allocator),
                },
            },
            .lock_free => TaskQueue{
                .lock_free = try lockfree.MPMCQueue(TaskRef).init(allocator, std.math.ceilPowerOfTwo(u32, max_size) catch max_size),
            },
            .work_stealing => blk: {
                var local_deques = std.ArrayList(lockfree.WorkStealingDeque(TaskRef)){ .allocator = allocator };
                try local_deques.ensureTotalCapacity(num_threads);
                for (0..num_threads) |_| {
                    try local_deques.append(try lockfree.WorkStealingDeque(TaskRef).init(allocator));
                }
                break :blk TaskQueue{
                    .work_stealing = .{
                        .global_queue = try lockfree.LockFreeQueue(TaskRef).init(allocator),
                        .local_deques = local_deques,
                    },
                };
            },
        };
    }
    
    fn deinit(self: *TaskQueue) void {
        switch (self.*) {
            .locked_fifo => |*q| q.queue.deinit(),
            .lock_free => |*q| q.deinit(),
            .work_stealing => |*q| {
                q.global_queue.deinit();
                for (q.local_deques.items) |*deque| {
                    deque.deinit();
                }
                q.local_deques.deinit();
            },
        }
    }
    
    fn enqueue(self: *TaskQueue, task: TaskRef) !void {
        switch (self.*) {
            .locked_fifo => |*q| {
                q.mutex.lock();
                defer q.mutex.unlock();
                try q.queue.writeItem(task);
                q.condition.signal();
            },
            .lock_free => |*q| try q.enqueue(task),
            .work_stealing => |*q| try q.global_queue.enqueue(task),
        }
    }
    
    fn dequeue(self: *TaskQueue, thread_id: ?usize) ?TaskRef {
        switch (self.*) {
            .locked_fifo => |*q| {
                q.mutex.lock();
                defer q.mutex.unlock();
                return q.queue.readItem();
            },
            .lock_free => |*q| return q.dequeue(),
            .work_stealing => |*q| {
                // Try local deque first if we have a thread ID
                if (thread_id) |tid| {
                    if (tid < q.local_deques.items.len) {
                        if (q.local_deques.items[tid].popBottom()) |task| {
                            return task;
                        }
                    }
                }
                
                // Try global queue
                if (q.global_queue.dequeue()) |task| {
                    return task;
                }
                
                // Try stealing from other threads
                if (thread_id) |tid| {
                    for (q.local_deques.items, 0..) |*deque, i| {
                        if (i != tid) {
                            if (deque.steal()) |task| {
                                return task;
                            }
                        }
                    }
                }
                
                return null;
            },
        }
    }
    
    fn pushLocal(self: *TaskQueue, task: TaskRef, thread_id: usize) !void {
        switch (self.*) {
            .work_stealing => |*q| {
                if (thread_id < q.local_deques.items.len) {
                    q.local_deques.items[thread_id].pushBottom(task) catch {
                        // If local deque is full, push to global queue
                        try q.global_queue.enqueue(task);
                    };
                } else {
                    try q.global_queue.enqueue(task);
                }
            },
            else => try self.enqueue(task),
        }
    }
    
    fn count(self: *const TaskQueue) usize {
        return switch (self.*) {
            .locked_fifo => |*q| q.queue.count,
            .lock_free => |*q| q.count(),
            .work_stealing => |*q| {
                var total: usize = q.global_queue.count();
                for (q.local_deques.items) |*deque| {
                    total += deque.count();
                }
                return total;
            },
        };
    }
    
    fn waitForWork(self: *TaskQueue, mutex: ?*std.Thread.Mutex) void {
        switch (self.*) {
            .locked_fifo => |*q| {
                if (mutex) |m| {
                    q.condition.wait(m);
                }
            },
            else => {
                // Lock-free queues don't need to wait, just yield
                std.Thread.yield() catch {};
            },
        }
    }
    
    fn signalWorkers(self: *TaskQueue) void {
        switch (self.*) {
            .locked_fifo => |*q| q.condition.broadcast(),
            else => {}, // Lock-free queues don't need signaling
        }
    }
};

/// ThreadPoolIo implementation
pub const ThreadPoolIo = struct {
    allocator: std.mem.Allocator,
    config: ThreadPoolConfig,
    threads: std.ArrayList(WorkerThread),
    task_queue: TaskQueue,
    shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    blocking_io_impl: blocking_io.BlockingIo,
    // Dynamic scaling state
    active_threads: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    scaling_mutex: std.Thread.Mutex = .{},
    last_scale_check: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    // Note: Using local stats instead of TLS to avoid segfaults
    // Condition variable for signaling threads
    queue_condition: std.Thread.Condition = .{},

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: ThreadPoolConfig) !Self {
        var self = Self{
            .allocator = allocator,
            .config = config,
            .threads = std.ArrayList(WorkerThread){ .allocator = allocator },
            .task_queue = try TaskQueue.init(allocator, config.queue_type, config.max_queue_size, config.max_threads),
            .blocking_io_impl = blocking_io.BlockingIo.init(allocator),
        };

        // Start initial worker threads
        try self.threads.ensureTotalCapacity(config.max_threads);
        for (0..config.num_threads) |i| {
            const worker = WorkerThread{
                .thread = try std.Thread.spawn(.{}, workerThread, .{ &self, i }),
            };
            try self.threads.append(self.allocator, worker);
        }
        self.active_threads.store(@intCast(config.num_threads), .release);

        return self;
    }

    pub fn deinit(self: *Self) void {
        // Signal shutdown
        self.shutdown.store(true, .release);
        
        // Signal all threads to terminate
        for (self.threads.items) |*worker| {
            worker.should_terminate.store(true, .release);
        }
        
        // Wake all threads
        self.task_queue.signalWorkers();
        
        // Wait for threads to finish
        for (self.threads.items) |*worker| {
            worker.thread.join();
        }
        
        self.threads.deinit();
        self.task_queue.deinit();
        self.blocking_io_impl.deinit();
    }

    /// Get the Io interface for this implementation
    pub fn io(self: *Self) Io {
        return Io{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    fn submitTask(self: *Self, task: TaskRef) !void {
        if (self.task_queue.count() >= self.config.max_queue_size) {
            return error.QueueFull;
        }
        
        try self.task_queue.enqueue(task);
        
        // Check if we need to scale up
        if (self.config.enable_dynamic_scaling) {
            self.checkAndScale();
        }
    }
    
    /// Check queue load and scale thread pool if necessary
    fn checkAndScale(self: *Self) void {
        const now = std.time.milliTimestamp();
        const last_check = self.last_scale_check.load(.acquire);
        
        // Only check scaling every 100ms to avoid thrashing
        if (now - last_check < 100) return;
        if (self.last_scale_check.cmpxchgWeak(last_check, now, .acq_rel, .monotonic) != null) return;
        
        self.scaling_mutex.lock();
        defer self.scaling_mutex.unlock();
        
        const queue_size = self.task_queue.count();
        const queue_capacity = self.config.max_queue_size;
        const load_ratio = @as(f64, @floatFromInt(queue_size)) / @as(f64, @floatFromInt(queue_capacity));
        const current_threads = self.active_threads.load(.acquire);
        
        // Scale up if queue is getting full and we have room for more threads
        if (load_ratio > self.config.scale_up_threshold and current_threads < self.config.max_threads) {
            self.scaleUp() catch |err| {
                std.debug.print("Failed to scale up thread pool: {}\n", .{err});
            };
        }
        // Scale down if queue is mostly empty and we have more than minimum threads
        else if (load_ratio < self.config.scale_down_threshold and current_threads > self.config.min_threads) {
            self.scaleDown();
        }
    }
    
    /// Add a new worker thread to the pool
    fn scaleUp(self: *Self) !void {
        const thread_id = self.threads.items.len;
        const worker = WorkerThread{
            .thread = try std.Thread.spawn(.{}, workerThread, .{ self, thread_id }),
        };
        try self.threads.append(self.allocator, worker);
        _ = self.active_threads.fetchAdd(1, .acq_rel);
        
        std.debug.print("🔧 Scaled up thread pool to {} threads\n", .{self.active_threads.load(.acquire)});
    }
    
    /// Mark a thread for termination when it becomes idle
    fn scaleDown(self: *Self) void {
        // Find the most recently added thread that's not already marked for termination
        var i = self.threads.items.len;
        while (i > 0) {
            i -= 1;
            const worker = &self.threads.items[i];
            
            if (!worker.should_terminate.load(.acquire)) {
                worker.should_terminate.store(true, .release);
                _ = self.active_threads.fetchSub(1, .acq_rel);
                self.queue_condition.signal(); // Wake the thread so it can check termination flag
                
                std.debug.print("🔧 Marked thread for termination, active threads: {}\n", .{self.active_threads.load(.acquire)});
                break;
            }
        }
    }

    fn workerThread(self: *Self, thread_id: usize) void {
        const worker = &self.threads.items[thread_id];
        var idle_start: ?i64 = null;
        
        // Use simple local statistics instead of TLS to avoid segfault
        var local_stats = ThreadStats.init(self.allocator);
        local_stats.thread_id = @intCast(thread_id);
        const stats = &local_stats;
        
        defer {
            // Print final stats when thread exits
            std.debug.print("🧵 Thread {} exiting: {} tasks executed, avg {}ns per task\n", .{
                thread_id, 
                stats.tasks_executed,
                if (stats.tasks_executed > 0) stats.total_execution_time_ns / stats.tasks_executed else 0,
            });
            // No TLS cleanup needed with local stats
        }
        
        while (!self.shutdown.load(.acquire) and !worker.should_terminate.load(.acquire)) {
            // Try to get a task from the queue
            const task = self.task_queue.dequeue(thread_id);
            
            if (task == null) {
                // No task available
                if (idle_start == null) idle_start = std.time.milliTimestamp();
                
                // Check if this thread should terminate due to idle timeout
                if (self.config.enable_dynamic_scaling and idle_start != null) {
                    const idle_time = std.time.milliTimestamp() - idle_start.?;
                    if (idle_time > self.config.thread_idle_timeout_ms and self.active_threads.load(.acquire) > self.config.min_threads) {
                        worker.should_terminate.store(true, .release);
                        return;
                    }
                }
                
                // Wait a bit before trying again (for lock-free queues)
                self.task_queue.waitForWork(null);
                continue;
            }
            
            const actual_task = task.?;
            
            // Reset idle timer since we got work
            idle_start = null;
            worker.last_active.store(std.time.milliTimestamp(), .release);
            
            // Track execution time for statistics
            const start_time = std.time.nanoTimestamp();
            
            // Execute task
            actual_task.future.result = actual_task.func(actual_task.ctx);
            actual_task.future.completed.store(true, .release);
            actual_task.future.completion_condition.signal();
            
            // Clean up task context memory
            self.allocator.destroy(@as(*CallInfoTaskContext, @ptrCast(@alignCast(actual_task.ctx))));
            
            // Clean up task memory
            self.allocator.destroy(actual_task);
            
            // Update thread-local statistics
            const end_time = std.time.nanoTimestamp();
            stats.tasks_executed += 1;
            stats.total_execution_time_ns += @intCast(end_time - start_time);
        }
    }

    // VTable implementation
    const vtable = Io.VTable{
        .async_fn = asyncFn,
        .async_concurrent_fn = asyncConcurrentFn,
        .createFile = createFile,
        .openFile = openFile,
        .tcpConnect = tcpConnect,
        .tcpListen = tcpListen,
        .udpBind = udpBind,
    };

    fn asyncFn(ptr: *anyopaque, call_info: io_interface.AsyncCallInfo) !Future {
        const self: *Self = @ptrCast(@alignCast(ptr));
        
        // Create future and task context
        const future_impl = try self.allocator.create(ThreadPoolFuture);
        future_impl.* = ThreadPoolFuture{
            .allocator = self.allocator,
            .completed = std.atomic.Value(bool).init(false),
            .completion_condition = .{},
            .completion_mutex = .{},
            .result = undefined,
            .call_info = call_info, // Store call_info for cleanup
        };
        
        // Create task context that stores the call info
        const task_ctx = try self.allocator.create(CallInfoTaskContext);
        task_ctx.* = CallInfoTaskContext{
            .call_info = call_info,
        };
        
        const task = try self.allocator.create(Task);
        task.* = Task{
            .func = executeCallInfoTask,
            .ctx = task_ctx,
            .future = future_impl,
        };
        
        try self.submitTask(task);
        
        return Future{
            .ptr = future_impl,
            .vtable = &threadpool_future_vtable,
            .state = std.atomic.Value(Future.State).init(.pending),
            .wakers = std.ArrayList(Future.Waker){ .allocator = self.allocator },
        };
    }

    fn asyncConcurrentFn(ptr: *anyopaque, call_infos: []io_interface.AsyncCallInfo) !io_interface.ConcurrentFuture {
        const self: *Self = @ptrCast(@alignCast(ptr));
        
        std.debug.print("🚀 ThreadPoolIo: Starting {} concurrent operations\n", .{call_infos.len});
        
        // Create concurrent future to manage all operations
        const concurrent_future = try self.allocator.create(ThreadPoolConcurrentFuture);
        concurrent_future.* = ThreadPoolConcurrentFuture{
            .allocator = self.allocator,
            .futures = try self.allocator.alloc(*ThreadPoolFuture, call_infos.len),
            .completed_count = std.atomic.Value(usize).init(0),
            .total_count = call_infos.len,
        };
        
        // Submit all operations to thread pool for true parallelism
        for (call_infos, 0..) |call_info, i| {
            const future_impl = try self.allocator.create(ThreadPoolFuture);
            future_impl.* = ThreadPoolFuture{
                .allocator = self.allocator,
                .completed = std.atomic.Value(bool).init(false),
                .completion_condition = .{},
                .completion_mutex = .{},
                .result = undefined,
                .call_info = call_info,
            };
            
            concurrent_future.futures[i] = future_impl;
            
            const task_ctx = try self.allocator.create(CallInfoTaskContext);
            task_ctx.* = CallInfoTaskContext{
                .call_info = call_info,
            };
            
            const task = try self.allocator.create(Task);
            task.* = Task{
                .func = executeCallInfoTaskConcurrent,
                .ctx = task_ctx,
                .future = future_impl,
            };
            
            try self.submitTask(task);
        }
        
        return io_interface.ConcurrentFuture{
            .ptr = concurrent_future,
            .vtable = &threadpool_concurrent_future_vtable,
        };
    }

    fn createFile(ptr: *anyopaque, path: []const u8, options: File.CreateOptions) !File {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.blocking_io_impl.io().vtable.createFile(self.blocking_io_impl.io().ptr, path, options);
    }

    fn openFile(ptr: *anyopaque, path: []const u8, options: File.OpenOptions) !File {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.blocking_io_impl.io().vtable.openFile(self.blocking_io_impl.io().ptr, path, options);
    }

    fn tcpConnect(ptr: *anyopaque, address: std.net.Address) !TcpStream {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.blocking_io_impl.io().vtable.tcpConnect(self.blocking_io_impl.io().ptr, address);
    }

    fn tcpListen(ptr: *anyopaque, address: std.net.Address) !TcpListener {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.blocking_io_impl.io().vtable.tcpListen(self.blocking_io_impl.io().ptr, address);
    }

    fn udpBind(ptr: *anyopaque, address: std.net.Address) !UdpSocket {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.blocking_io_impl.io().vtable.udpBind(self.blocking_io_impl.io().ptr, address);
    }
};

/// Task context for call info execution
const CallInfoTaskContext = struct {
    call_info: io_interface.AsyncCallInfo,
};

/// Task executor for call info
fn executeCallInfoTask(ctx: *anyopaque) anyerror!void {
    const task_ctx: *CallInfoTaskContext = @ptrCast(@alignCast(ctx));
    try task_ctx.call_info.exec_fn(task_ctx.call_info.call_ptr);
}

/// Task context for storing function and arguments (legacy)
fn TaskContext(comptime FuncType: type, comptime ArgsType: type) type {
    return struct {
        func: FuncType,
        args: ArgsType,
    };
}

/// Generic task executor (legacy)
fn executeTask(comptime FuncType: type, comptime ArgsType: type) *const fn (*anyopaque) anyerror!void {
    return struct {
        fn execute(ctx: *anyopaque) anyerror!void {
            const task_ctx: *TaskContext(FuncType, ArgsType) = @ptrCast(@alignCast(ctx));
            try @call(.auto, task_ctx.func, task_ctx.args);
        }
    }.execute;
}

/// ThreadPool future implementation
const ThreadPoolFuture = struct {
    allocator: std.mem.Allocator,
    completed: std.atomic.Value(bool),
    completion_condition: std.Thread.Condition,
    completion_mutex: std.Thread.Mutex,
    result: anyerror!void,
    call_info: io_interface.AsyncCallInfo,
};

/// ThreadPool concurrent future for managing multiple parallel operations
const ThreadPoolConcurrentFuture = struct {
    allocator: std.mem.Allocator,
    futures: []*ThreadPoolFuture,
    completed_count: std.atomic.Value(usize),
    total_count: usize,
};

const threadpool_future_vtable = Future.VTable{
    .await_fn = threadpoolAwait,
    .cancel_fn = threadpoolCancel,
    .deinit_fn = threadpoolDeinit,
};

fn threadpoolAwait(ptr: *anyopaque, io: Io, options: Future.AwaitOptions) !void {
    _ = io;
    _ = options;
    const future: *ThreadPoolFuture = @ptrCast(@alignCast(ptr));
    
    if (future.completed.load(.acquire)) {
        return future.result;
    }
    
    future.completion_mutex.lock();
    defer future.completion_mutex.unlock();
    
    while (!future.completed.load(.acquire)) {
        future.completion_condition.wait(&future.completion_mutex);
    }
    
    return future.result;
}

fn threadpoolCancel(ptr: *anyopaque, io: Io, options: Future.CancelOptions) !void {
    _ = io;
    _ = options;
    const future: *ThreadPoolFuture = @ptrCast(@alignCast(ptr));
    
    // For simplicity, we can't cancel tasks already submitted to thread pool
    // In a full implementation, we'd need cancellation tokens
    if (!future.completed.load(.acquire)) {
        future.result = error.Canceled;
        future.completed.store(true, .release);
        future.completion_condition.signal();
    }
    
    return future.result;
}

fn threadpoolDeinit(ptr: *anyopaque) void {
    const future: *ThreadPoolFuture = @ptrCast(@alignCast(ptr));
    // Clean up the call info
    future.call_info.deinit();
    future.allocator.destroy(future);
}

// Concurrent task executor that notifies concurrent future
fn executeCallInfoTaskConcurrent(ctx: *anyopaque) anyerror!void {
    const task_ctx: *CallInfoTaskContext = @ptrCast(@alignCast(ctx));
    try task_ctx.call_info.exec_fn(task_ctx.call_info.call_ptr);
}

const threadpool_concurrent_future_vtable = io_interface.ConcurrentFuture.VTable{
    .await_all_fn = threadpoolAwaitAll,
    .await_any_fn = threadpoolAwaitAny,
    .cancel_all_fn = threadpoolCancelAll,
    .deinit_fn = threadpoolConcurrentDeinit,
};

fn threadpoolAwaitAll(ptr: *anyopaque, io: Io) !void {
    _ = io;
    const concurrent_future: *ThreadPoolConcurrentFuture = @ptrCast(@alignCast(ptr));
    
    std.debug.print("⏳ Waiting for {} concurrent operations to complete...\n", .{concurrent_future.total_count});
    
    // Wait for all futures to complete
    for (concurrent_future.futures) |future| {
        future.completion_mutex.lock();
        defer future.completion_mutex.unlock();
        
        while (!future.completed.load(.acquire)) {
            future.completion_condition.wait(&future.completion_mutex);
        }
        
        // Propagate any errors
        try future.result;
    }
    
    std.debug.print("✅ All {} concurrent operations completed!\n", .{concurrent_future.total_count});
}

fn threadpoolAwaitAny(ptr: *anyopaque, io: Io) !usize {
    _ = io;
    const concurrent_future: *ThreadPoolConcurrentFuture = @ptrCast(@alignCast(ptr));
    
    std.debug.print("⏳ Waiting for any of {} concurrent operations to complete...\n", .{concurrent_future.total_count});
    
    // Busy wait for any future to complete (could be optimized with a single condition variable)
    while (true) {
        for (concurrent_future.futures, 0..) |future, i| {
            if (future.completed.load(.acquire)) {
                std.debug.print("🎯 Operation {} completed first!\n", .{i});
                try future.result;
                return i;
            }
        }
        std.Thread.yield() catch {};
    }
}

fn threadpoolCancelAll(ptr: *anyopaque, io: Io) !void {
    _ = io;
    const concurrent_future: *ThreadPoolConcurrentFuture = @ptrCast(@alignCast(ptr));
    
    std.debug.print("❌ Cancelling {} concurrent operations...\n", .{concurrent_future.total_count});
    
    // Cancel all futures
    for (concurrent_future.futures) |future| {
        if (!future.completed.load(.acquire)) {
            future.result = error.Canceled;
            future.completed.store(true, .release);
            future.completion_condition.signal();
        }
    }
}

fn threadpoolConcurrentDeinit(ptr: *anyopaque) void {
    const concurrent_future: *ThreadPoolConcurrentFuture = @ptrCast(@alignCast(ptr));
    
    // Clean up all futures
    for (concurrent_future.futures) |future| {
        future.call_info.deinit();
        concurrent_future.allocator.destroy(future);
    }
    
    concurrent_future.allocator.free(concurrent_future.futures);
    concurrent_future.allocator.destroy(concurrent_future);
}

test "threadpool io basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var threadpool_io = try ThreadPoolIo.init(allocator, .{ .num_threads = 2 });
    defer threadpool_io.deinit();
    
    const io = threadpool_io.io();
    
    // Test file creation (delegated to blocking IO)
    const file = try io.vtable.createFile(io.ptr, "test_threadpool.txt", .{});
    try file.writeAll(io, "Hello, ThreadPoolIo!");
    try file.close(io);
    
    // Clean up
    std.fs.cwd().deleteFile("test_threadpool.txt") catch {};
}

test "threadpool io colorblind async with parallelism" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var threadpool_io = try ThreadPoolIo.init(allocator, .{ .num_threads = 4 });
    defer threadpool_io.deinit();
    
    const io = threadpool_io.io();
    
    // This will execute saveFile calls in parallel on different threads!
    try io_interface.saveData(allocator, io, "Test data from ThreadPool IO with parallelism");
    
    // Clean up
    std.fs.cwd().deleteFile("saveA.txt") catch {};
    std.fs.cwd().deleteFile("saveB.txt") catch {};
}