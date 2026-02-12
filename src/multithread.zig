//! Multi-threading support for Zsync
//! Work-stealing task scheduler with thread-safe operations

const std = @import("std");
const compat = @import("compat/thread.zig");
const task = @import("task.zig");
const scheduler = @import("scheduler.zig");
const reactor = @import("reactor.zig");

/// Work-stealing task queue for multi-threaded execution
pub const WorkStealingQueue = struct {
    items: []?*task.Task,
    head: std.atomic.Value(u32),
    tail: std.atomic.Value(u32),
    capacity: u32,
    mask: u32,
    allocator: std.mem.Allocator,
    mutex: compat.Mutex,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, capacity: u32) !Self {
        const cap = std.math.ceilPowerOfTwo(u32, capacity) catch return error.InvalidCapacity;
        const items = try allocator.alloc(?*task.Task, cap);
        @memset(items, null);

        return Self{
            .items = items,
            .head = std.atomic.Value(u32).init(0),
            .tail = std.atomic.Value(u32).init(0),
            .capacity = cap,
            .mask = cap - 1,
            .allocator = allocator,
            .mutex = compat.Mutex{},
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.items);
    }

    /// Push a task to the tail (only called by owner thread)
    pub fn push(self: *Self, task_item: *task.Task) !void {
        const tail = self.tail.load(.monotonic);
        const head = self.head.load(.acquire);
        
        if (tail - head >= self.capacity) {
            return error.QueueFull;
        }

        const index = tail & self.mask;
        self.items[index] = task_item;
        self.tail.store(tail + 1, .release);
    }

    /// Pop a task from the tail (only called by owner thread)
    pub fn pop(self: *Self) ?*task.Task {
        const tail = self.tail.load(.monotonic);
        const head = self.head.load(.acquire);
        
        if (tail == head) return null;

        const new_tail = tail - 1;
        const index = new_tail & self.mask;
        const task_item = self.items[index];
        self.items[index] = null;
        self.tail.store(new_tail, .monotonic);
        
        return task_item;
    }

    /// Steal a task from the head (called by other threads)
    pub fn steal(self: *Self) ?*task.Task {
        self.mutex.lock();
        defer self.mutex.unlock();

        const head = self.head.load(.acquire);
        const tail = self.tail.load(.acquire);
        
        if (head >= tail) return null;

        const index = head & self.mask;
        const task_item = self.items[index];
        if (task_item == null) return null;

        self.items[index] = null;
        self.head.store(head + 1, .release);
        
        return task_item;
    }

    pub fn isEmpty(self: *Self) bool {
        const head = self.head.load(.acquire);
        const tail = self.tail.load(.acquire);
        return head >= tail;
    }
};

/// Thread pool worker configuration
pub const WorkerConfig = struct {
    thread_count: u32 = 0, // 0 means auto-detect
    queue_capacity: u32 = 1024,
    cpu_affinity: bool = false,
    work_steal_attempts: u32 = 10,
};

/// Multi-threaded runtime worker
pub const Worker = struct {
    id: u32,
    thread: std.Thread,
    local_queue: WorkStealingQueue,
    global_queue: *WorkStealingQueue,
    other_queues: []*WorkStealingQueue,
    running: std.atomic.Value(bool),
    allocator: std.mem.Allocator,
    scheduler_instance: scheduler.AsyncScheduler,
    reactor_instance: ?reactor.Reactor,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        id: u32,
        global_queue: *WorkStealingQueue,
        other_queues: []*WorkStealingQueue,
        config: WorkerConfig,
    ) !Self {
        return Self{
            .id = id,
            .thread = undefined,
            .local_queue = try WorkStealingQueue.init(allocator, config.queue_capacity),
            .global_queue = global_queue,
            .other_queues = other_queues,
            .running = std.atomic.Value(bool).init(false),
            .allocator = allocator,
            .scheduler_instance = try scheduler.AsyncScheduler.init(allocator),
            .reactor_instance = null,
        };
    }

    pub fn deinit(self: *Self) void {
        self.local_queue.deinit();
        self.scheduler_instance.deinit();
        if (self.reactor_instance) |*react| {
            react.deinit();
        }
    }

    /// Start the worker thread
    pub fn start(self: *Self) !void {
        self.running.store(true, .release);
        self.thread = try std.Thread.spawn(.{}, workerMain, .{self});
    }

    /// Stop the worker thread
    pub fn stop(self: *Self) void {
        self.running.store(false, .release);
        self.thread.join();
    }

    /// Main worker loop
    fn workerMain(self: *Self) void {
        // Initialize reactor for I/O worker (worker 0)
        if (self.id == 0) {
            self.reactor_instance = reactor.Reactor.init(self.allocator, .{}) catch |err| {
                std.log.err("Failed to initialize reactor on worker {}: {}", .{ self.id, err });
                return;
            };
        }

        while (self.running.load(.acquire)) {
            // Try to get work in priority order:
            // 1. Local queue (fastest)
            // 2. Global queue
            // 3. Steal from other workers
            const task_to_run = self.getNextTask();
            
            if (task_to_run) |task_item| {
                self.executeTask(task_item);
            } else {
                // No work available, handle I/O or yield
                if (self.reactor_instance) |*react| {
                    _ = react.poll(1) catch 0; // 1ms timeout
                } else {
                    std.time.sleep(1 * std.time.ns_per_ms); // 1ms yield
                }
            }

            // Process scheduler events
            _ = self.scheduler_instance.tick() catch 0;
        }
    }

    /// Get the next task to execute
    fn getNextTask(self: *Self) ?*task.Task {
        // 1. Try local queue first
        if (self.local_queue.pop()) |task_item| {
            return task_item;
        }

        // 2. Try global queue
        if (self.global_queue.steal()) |task_item| {
            return task_item;
        }

        // 3. Try stealing from other workers
        var attempts: u32 = 0;
        while (attempts < 10) : (attempts += 1) {
            for (self.other_queues) |other_queue| {
                if (other_queue.steal()) |task_item| {
                    return task_item;
                }
            }
        }

        return null;
    }

    /// Execute a task
    fn executeTask(self: *Self, task_item: *task.Task) void {
        _ = self;
        _ = task_item;
        // Task execution would be implemented here
        // For now, this is a placeholder
    }

    /// Schedule a task on this worker
    pub fn scheduleTask(self: *Self, task_item: *task.Task) !void {
        try self.local_queue.push(task_item);
    }
};

/// Multi-threaded runtime
pub const MultiThreadRuntime = struct {
    allocator: std.mem.Allocator,
    workers: []Worker,
    global_queue: WorkStealingQueue,
    worker_queues: []*WorkStealingQueue,
    config: WorkerConfig,
    running: std.atomic.Value(bool),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: WorkerConfig) !Self {
        const thread_count = if (config.thread_count == 0) 
            @min(std.Thread.getCpuCount() catch 4, 16) 
        else 
            config.thread_count;

        var global_queue = try WorkStealingQueue.init(allocator, config.queue_capacity * thread_count);
        
        // Allocate workers and their queue pointers
        const workers = try allocator.alloc(Worker, thread_count);
        const worker_queues = try allocator.alloc(*WorkStealingQueue, thread_count);

        // Initialize workers
        var i: u32 = 0;
        while (i < thread_count) : (i += 1) {
            workers[i] = try Worker.init(
                allocator,
                i,
                &global_queue,
                worker_queues[0..i], // Other workers' queues
                config,
            );
            worker_queues[i] = &workers[i].local_queue;
        }

        // Update all workers with complete queue list
        for (workers) |*worker| {
            worker.other_queues = worker_queues;
        }

        return Self{
            .allocator = allocator,
            .workers = workers,
            .global_queue = global_queue,
            .worker_queues = worker_queues,
            .config = config,
            .running = std.atomic.Value(bool).init(false),
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.workers) |*worker| {
            worker.deinit();
        }
        self.allocator.free(self.workers);
        self.allocator.free(self.worker_queues);
        self.global_queue.deinit();
    }

    /// Start the runtime
    pub fn start(self: *Self) !void {
        self.running.store(true, .release);
        
        for (self.workers) |*worker| {
            try worker.start();
        }
    }

    /// Stop the runtime
    pub fn stop(self: *Self) void {
        self.running.store(false, .release);
        
        for (self.workers) |*worker| {
            worker.stop();
        }
    }

    /// Spawn a task on the runtime
    pub fn spawn(self: *Self, comptime func: anytype, args: anytype) !void {
        _ = self;
        _ = func;
        _ = args;
        // Task spawning would be implemented here
        // This would create a task and add it to the least loaded worker
    }

    /// Get runtime statistics
    pub fn getStats(self: *Self) RuntimeStats {
        var total_queued: u32 = 0;
        const total_executed: u32 = 0; // TODO: Implement proper task counting

        for (self.workers) |*worker| {
            if (!worker.local_queue.isEmpty()) {
                total_queued += 1;
            }
        }

        return RuntimeStats{
            .thread_count = @intCast(self.workers.len),
            .total_tasks_queued = total_queued,
            .total_tasks_executed = total_executed,
            .is_running = self.running.load(.acquire),
        };
    }
};

/// Runtime statistics
pub const RuntimeStats = struct {
    thread_count: u32,
    total_tasks_queued: u32,
    total_tasks_executed: u32,
    is_running: bool,
};

// Tests
test "work stealing queue basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var queue = try WorkStealingQueue.init(allocator, 8);
    defer queue.deinit();
    
    try testing.expect(queue.isEmpty());
}

test "multi-thread runtime creation" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    const config = WorkerConfig{ .thread_count = 2, .queue_capacity = 16 };
    var runtime = try MultiThreadRuntime.init(allocator, config);
    defer runtime.deinit();
    
    const stats = runtime.getStats();
    try testing.expect(stats.thread_count == 2);
    try testing.expect(!stats.is_running);
}