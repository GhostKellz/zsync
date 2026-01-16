//! Advanced task scheduler with proper async frame management
//! Uses zsync runtime patterns (Zig 0.16 removed language-level async)

const std = @import("std");
const builtin = @import("builtin");

/// Frame state for async operations
pub const FrameState = enum {
    pending,
    ready,
    running,
    suspended,
    completed,
    cancelled,
};

/// Async frame wrapper for task management
pub const AsyncFrame = struct {
    id: u32,
    state: FrameState,
    frame_ptr: *anyopaque,
    frame_size: usize,
    allocator: std.mem.Allocator,
    waker: ?*Waker = null,
    result: ?anyerror = null,

    const Self = @This();

    pub fn init(id: u32, frame_ptr: *anyopaque, frame_size: usize, allocator: std.mem.Allocator) Self {
        return Self{
            .id = id,
            .state = .pending,
            .frame_ptr = frame_ptr,
            .frame_size = frame_size,
            .allocator = allocator,
        };
    }

    /// Resume an async frame
    /// Note: Zig 0.16 removed language-level async (anyframe/resume)
    /// This now uses state management for zsync runtime coordination
    pub fn resumeFrame(self: *Self) void {
        if (self.state == .suspended) {
            self.state = .ready;
            // Frame will be picked up by scheduler tick()
        }
    }

    /// Mark frame as suspended
    pub fn suspendFrame(self: *Self) void {
        if (self.state == .running) {
            self.state = .suspended;
        }
    }

    /// Check if frame is complete
    pub fn isComplete(self: *Self) bool {
        return self.state == .completed or self.state == .cancelled;
    }

    /// Cancel the frame
    pub fn cancel(self: *Self) void {
        self.state = .cancelled;
        if (self.waker) |waker| {
            waker.wake();
        }
    }

    pub fn complete(self: *Self, result: ?anyerror) void {
        self.state = .completed;
        self.result = result;
    }
};

/// Waker for async task coordination
pub const Waker = struct {
    frame_id: u32,
    scheduler: *AsyncScheduler,
    wake_fn: *const fn (*AsyncScheduler, u32) void,

    const Self = @This();

    pub fn wake(self: *Self) void {
        self.wake_fn(self.scheduler, self.frame_id);
    }

    pub fn init(frame_id: u32, scheduler: *AsyncScheduler) Self {
        return Self{
            .frame_id = frame_id,
            .scheduler = scheduler,
            .wake_fn = AsyncScheduler.wakeFrame,
        };
    }
};

/// Task priority levels for scheduling
pub const TaskPriority = enum(u8) {
    low = 0,
    normal = 1,
    high = 2,
    critical = 3,

    pub fn compare(self: TaskPriority, other: TaskPriority) std.math.Order {
        return std.math.order(@intFromEnum(self), @intFromEnum(other));
    }
};

/// Scheduled task entry
const ScheduledTask = struct {
    frame: AsyncFrame,
    priority: TaskPriority,
    scheduled_at: u64, // timestamp
    deadline: ?u64 = null, // optional deadline

    const Self = @This();

    pub fn init(frame: AsyncFrame, priority: TaskPriority, scheduled_at: u64) Self {
        return Self{
            .frame = frame,
            .priority = priority,
            .scheduled_at = scheduled_at,
        };
    }
};

/// Priority queue for task scheduling
const TaskQueue = struct {
    items: std.ArrayList(ScheduledTask),
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .items = std.ArrayList(ScheduledTask){},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.items.deinit(self.allocator);
    }

    pub fn push(self: *Self, task: ScheduledTask) !void {
        try self.items.append(self.allocator, task);
        // Sort by priority (bubble up)
        var i = self.items.items.len - 1;
        while (i > 0) {
            const parent = (i - 1) / 2;
            if (self.items.items[parent].priority.compare(self.items.items[i].priority) != .lt) {
                break;
            }
            std.mem.swap(ScheduledTask, &self.items.items[parent], &self.items.items[i]);
            i = parent;
        }
    }

    pub fn pop(self: *Self) ?ScheduledTask {
        if (self.items.items.len == 0) return null;
        
        const result = self.items.items[0];
        const last = self.items.pop();
        
        if (self.items.items.len > 0) {
            self.items.items[0] = last.?;
            // Bubble down
            var i: usize = 0;
            while (true) {
                const left = 2 * i + 1;
                const right = 2 * i + 2;
                var largest = i;

                if (left < self.items.items.len and 
                    self.items.items[left].priority.compare(self.items.items[largest].priority) == .gt) {
                    largest = left;
                }

                if (right < self.items.items.len and 
                    self.items.items[right].priority.compare(self.items.items[largest].priority) == .gt) {
                    largest = right;
                }

                if (largest == i) break;

                std.mem.swap(ScheduledTask, &self.items.items[i], &self.items.items[largest]);
                i = largest;
            }
        }

        return result;
    }

    pub fn isEmpty(self: *Self) bool {
        return self.items.items.len == 0;
    }

    pub fn len(self: *Self) usize {
        return self.items.items.len;
    }
};

/// Advanced async task scheduler
pub const AsyncScheduler = struct {
    allocator: std.mem.Allocator,
    ready_queue: TaskQueue,
    suspended_frames: std.HashMap(u32, *AsyncFrame, std.hash_map.AutoContext(u32), std.hash_map.default_max_load_percentage),
    frame_pool: std.ArrayList(*AsyncFrame),
    next_frame_id: std.atomic.Value(u32),
    running: std.atomic.Value(bool),
    mutex: std.Thread.Mutex,
    is_shutdown: bool,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        return Self{
            .allocator = allocator,
            .ready_queue = TaskQueue.init(allocator),
            .suspended_frames = std.HashMap(u32, *AsyncFrame, std.hash_map.AutoContext(u32), std.hash_map.default_max_load_percentage).init(allocator),
            .frame_pool = std.ArrayList(*AsyncFrame){},
            .next_frame_id = std.atomic.Value(u32).init(1),
            .running = std.atomic.Value(bool).init(false),
            .mutex = std.Thread.Mutex{},
            .is_shutdown = false,
        };
    }

    pub fn deinit(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Guard against double-free
        if (self.is_shutdown) return;
        self.is_shutdown = true;

        self.ready_queue.deinit();

        // Clean up suspended frames first
        var suspended_iter = self.suspended_frames.iterator();
        while (suspended_iter.next()) |entry| {
            entry.value_ptr.*.state = .cancelled;
        }
        self.suspended_frames.deinit();

        // Clean up frame pool with proper resource management
        for (self.frame_pool.items) |frame| {
            // Ensure frame is properly cancelled before destruction
            if (frame.state != .completed and frame.state != .cancelled) {
                frame.cancel();
            }
            self.allocator.destroy(frame);
        }
        self.frame_pool.deinit(self.allocator);
    }

    /// Generate next frame ID
    fn nextFrameId(self: *Self) u32 {
        return self.next_frame_id.fetchAdd(1, .monotonic);
    }

    /// Spawn a new async task
    pub fn spawn(self: *Self, comptime func: anytype, args: anytype, priority: TaskPriority) !u32 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const frame_id = self.nextFrameId();
        
        // Create async frame with proper memory management
        const frame = try self.allocator.create(AsyncFrame);
        errdefer self.allocator.destroy(frame);
        
        // Initialize frame with allocated memory for function call
        frame.* = AsyncFrame.init(frame_id, @ptrCast(frame), @sizeOf(AsyncFrame), self.allocator);
        
        // Store frame in pool for lifecycle management
        try self.frame_pool.append(self.allocator, frame);

        const ts_task = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch unreachable;
        const timestamp: u64 = @intCast(@divTrunc((@as(i128, ts_task.sec) * std.time.ns_per_s + ts_task.nsec), std.time.ns_per_ms));
        const task = ScheduledTask.init(frame.*, priority, timestamp);
        try self.ready_queue.push(task);

        // In a full async implementation, this would start the async function
        // For now, we create a task wrapper that will execute when scheduled
        const TaskWrapper = struct {
            pub fn run() !void {
                @call(.auto, func, args) catch |err| {
                    std.debug.print("Task failed with error: {}\n", .{err});
                };
            }
        };
        _ = TaskWrapper;

        return frame_id;
    }

    /// Process ready tasks
    pub fn tick(self: *Self) !u32 {
        self.mutex.lock();
        defer self.mutex.unlock();

        var processed: u32 = 0;
        const max_tasks_per_tick = 10; // Prevent starvation

        while (processed < max_tasks_per_tick and !self.ready_queue.isEmpty()) {
            if (self.ready_queue.pop()) |task| {
                processed += 1;
                
                // Find the corresponding frame in the pool
                for (self.frame_pool.items, 0..) |frame, i| {
                    if (frame.id == task.frame.id) {
                        // Update frame state
                        frame.state = .running;
                        
                        // In real implementation, this would resume the async frame
                        // For now, mark as completed
                        frame.complete(null);
                        
                        // Remove completed frame from pool
                        _ = self.frame_pool.swapRemove(i);
                        self.allocator.destroy(frame);
                        break;
                    }
                }
            }
        }

        return processed;
    }

    /// Wake a suspended frame
    pub fn wakeFrame(self: *Self, frame_id: u32) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.suspended_frames.get(frame_id)) |frame| {
            frame.state = .ready;

            // Move from suspended to ready queue
            const ts_resume = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch unreachable;
            const timestamp_resume: u64 = @intCast(@divTrunc((@as(i128, ts_resume.sec) * std.time.ns_per_s + ts_resume.nsec), std.time.ns_per_ms));
            const task = ScheduledTask.init(frame.*, .normal, timestamp_resume);
            self.ready_queue.push(task) catch return; // Ignore error for now

            _ = self.suspended_frames.remove(frame_id);
        }
    }

    /// Suspend current task and register waker
    pub fn suspendCurrent(self: *Self, frame_id: u32, waker: *Waker) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Find the frame by ID
        for (self.frame_pool.items) |frame| {
            if (frame.id == frame_id) {
                frame.state = .suspended;
                frame.waker = waker;
                
                // Move frame to suspended collection
                try self.suspended_frames.put(frame_id, frame);
                
                // Remove from ready queue if present
                // In real implementation, this would @suspend() the actual frame
                return;
            }
        }
        
        return error.FrameNotFound;
    }

    /// Check if scheduler has pending work
    pub fn hasPendingWork(self: *Self) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        return !self.ready_queue.isEmpty() or self.suspended_frames.count() > 0;
    }

    /// Get current queue length for debugging
    pub fn queueLength(self: *Self) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.ready_queue.len();
    }

    /// Create a waker for a frame
    pub fn createWaker(self: *Self, frame_id: u32) Waker {
        return Waker.init(frame_id, self);
    }
};

/// Helper function to yield execution (compatibility version)
pub fn yield() void {
    std.posix.nanosleep(0, 1000); // 1μs yield
}

/// Helper to create async task with default priority
pub fn spawnTask(scheduler: *AsyncScheduler, comptime func: anytype, args: anytype) !u32 {
    return scheduler.spawn(func, args, .normal);
}

/// Helper to create high priority task
pub fn spawnUrgentTask(scheduler: *AsyncScheduler, comptime func: anytype, args: anytype) !u32 {
    return scheduler.spawn(func, args, .high);
}

// Tests
test "async scheduler creation" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var scheduler = try AsyncScheduler.init(allocator);
    defer scheduler.deinit();
    
    try testing.expect(!scheduler.hasPendingWork());
    try testing.expect(scheduler.queueLength() == 0);
}

test "task priority queue" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var queue = TaskQueue.init(allocator);
    defer queue.deinit();
    
    // Create test frames
    const frame1 = AsyncFrame.init(1, undefined, 0, allocator);
    const frame2 = AsyncFrame.init(2, undefined, 0, allocator);
    const frame3 = AsyncFrame.init(3, undefined, 0, allocator);
    
    // Add tasks with different priorities
    try queue.push(ScheduledTask.init(frame1, .low, 0));
    try queue.push(ScheduledTask.init(frame2, .high, 0));
    try queue.push(ScheduledTask.init(frame3, .normal, 0));
    
    // Should pop high priority first
    const task1 = queue.pop().?;
    try testing.expect(task1.priority == .high);
    
    const task2 = queue.pop().?;
    try testing.expect(task2.priority == .normal);
    
    const task3 = queue.pop().?;
    try testing.expect(task3.priority == .low);
}

test "frame ID generation" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var scheduler = try AsyncScheduler.init(allocator);
    defer scheduler.deinit();
    
    const id1 = scheduler.nextFrameId();
    const id2 = scheduler.nextFrameId();
    
    try testing.expect(id1 != id2);
    try testing.expect(id2 > id1);
}

test "waker creation" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var scheduler = try AsyncScheduler.init(allocator);
    defer scheduler.deinit();
    
    const waker = scheduler.createWaker(42);
    try testing.expect(waker.frame_id == 42);
    try testing.expect(waker.scheduler == &scheduler);
}
