//! Zsync v0.1 - ThreadPoolIo Implementation
//! Uses a pool of OS threads to execute blocking I/O operations
//! Provides parallelism for I/O-bound workloads

const std = @import("std");
const io_interface = @import("io_v2.zig");
const blocking_io = @import("blocking_io.zig");
const tls = @import("thread_local_storage.zig");
const lockfree = @import("lockfree_queue.zig");
const Io = io_interface.Io;
const Future = io_interface.Future;
const File = io_interface.File;
const TcpStream = io_interface.TcpStream;
const TcpListener = io_interface.TcpListener;
const UdpSocket = io_interface.UdpSocket;

/// Task queue implementation type
pub const QueueType = enum {
    locked_fifo,    // Standard locked FIFO queue
    lock_free,      // Lock-free MPMC queue
    work_stealing,  // Work-stealing deques per thread
};

/// Configuration for thread pool
pub const ThreadPoolConfig = struct {
    num_threads: u32 = 4,
    max_queue_size: u32 = 1024,
    // Dynamic scaling parameters
    enable_dynamic_scaling: bool = true,
    min_threads: u32 = 1,
    max_threads: u32 = 16,
    scale_up_threshold: f64 = 0.8,   // Scale up when queue is 80% full
    scale_down_threshold: f64 = 0.2, // Scale down when queue is 20% full
    thread_idle_timeout_ms: u64 = 5000, // Kill idle threads after 5s
    // Queue configuration
    queue_type: QueueType = .lock_free,
};

/// Task to be executed in thread pool
const Task = struct {
    func: *const fn (*anyopaque) anyerror!void,
    ctx: *anyopaque,
    future: *ThreadPoolFuture,
};

/// Atomic-safe task reference for use in lock-free queues
const TaskRef = *Task;

/// Per-thread statistics for monitoring
const ThreadStats = struct {
    tasks_executed: u64 = 0,
    total_execution_time_ns: u64 = 0,
    thread_id: u32 = 0,
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) ThreadStats {
        return ThreadStats{
            .allocator = allocator,
            .thread_id = 0, // Will be set later
        };
    }
    
    fn deinit(self: *ThreadStats) void {
        _ = self;
        // No cleanup needed for basic stats
    }
};

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
                var local_deques = std.ArrayList(lockfree.WorkStealingDeque(TaskRef)).init(allocator);
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
            .threads = std.ArrayList(WorkerThread).init(allocator),
            .task_queue = try TaskQueue.init(allocator, config.queue_type, config.max_queue_size, config.max_threads),
            .blocking_io_impl = blocking_io.BlockingIo.init(allocator),
        };

        // Start initial worker threads
        try self.threads.ensureTotalCapacity(config.max_threads);
        for (0..config.num_threads) |i| {
            const worker = WorkerThread{
                .thread = try std.Thread.spawn(.{}, workerThread, .{ &self, i }),
            };
            try self.threads.append(worker);
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
        try self.threads.append(worker);
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
            .completed = std.atomic.Value(bool).init(false),
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

fn threadpoolAwait(ptr: *anyopaque, io: Io) !void {
    _ = io;
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

fn threadpoolCancel(ptr: *anyopaque, io: Io) !void {
    _ = io;
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