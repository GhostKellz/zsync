//! zsync- Enhanced Task Management with Cancellation
//! Provides timeout support, task batching, and graceful cancellation

const std = @import("std");
const compat = @import("compat/thread.zig");
const future_combinators = @import("future_combinators.zig");
const io_v2 = @import("io_v2.zig");

/// Enhanced task spawning with timeout and cancellation support
pub const Task = struct {
    id: u32,
    cancel_token: *future_combinators.CancelToken,
    timeout_ms: ?u64,
    priority: TaskPriority,
    state: std.atomic.Value(TaskState),
    
    const Self = @This();
    
    pub const TaskState = enum(u8) {
        pending = 0,
        running = 1,
        completed = 2,
        cancelled = 3,
        timeout = 4,
        failed = 5,
    };
    
    pub const TaskPriority = enum(u8) {
        low = 0,
        normal = 1,
        high = 2,
        critical = 3,
    };
    
    /// Spawn a task with optional timeout and cancellation
    pub fn spawn(
        allocator: std.mem.Allocator,
        comptime func: anytype,
        args: anytype,
        options: SpawnOptions,
    ) !TaskHandle {
        const task_id = generateTaskId();
        const cancel_token = try future_combinators.createCancelToken(allocator);
        
        const task = try allocator.create(Task);
        task.* = Task{
            .id = task_id,
            .cancel_token = cancel_token,
            .timeout_ms = options.timeout_ms,
            .priority = options.priority,
            .state = std.atomic.Value(TaskState).init(.pending),
        };
        
        const handle = TaskHandle{
            .task = task,
            .allocator = allocator,
        };
        
        // Start the task execution
        try startTaskExecution(task, func, args, allocator);
        
        return handle;
    }
    
    /// Wait for task completion with optional timeout
    pub fn waitWithTimeout(
        allocator: std.mem.Allocator,
        handle: TaskHandle,
        timeout_ms: u64,
    ) !TaskResult {
        const context = try allocator.create(WaitContext);
        context.* = WaitContext.init(handle, timeout_ms);
        
        return context.await();
    }
    
    /// Cancel a running task
    pub fn cancel(handle: TaskHandle) void {
        handle.task.cancel_token.cancel();
        handle.task.state.store(.cancelled, .release);
    }
    
    /// Get current task state
    pub fn getState(handle: TaskHandle) TaskState {
        return handle.task.state.load(.acquire);
    }
    
    var task_id_counter: std.atomic.Value(u32) = std.atomic.Value(u32).init(1);
    
    fn generateTaskId() u32 {
        return task_id_counter.fetchAdd(1, .monotonic);
    }
    
    fn startTaskExecution(
        task: *Task,
        comptime func: anytype,
        args: anytype,
        allocator: std.mem.Allocator,
    ) !void {
        const ExecutionContext = struct {
            task_ref: *Task,
            func_ptr: @TypeOf(func),
            args_data: @TypeOf(args),
            allocator: std.mem.Allocator,
            
            fn execute(self: *@This()) void {
                self.task_ref.state.store(.running, .release);
                
                // Check for cancellation before starting
                if (self.task_ref.cancel_token.isCancelled()) {
                    self.task_ref.state.store(.cancelled, .release);
                    return;
                }
                
                // Execute with timeout if specified
                if (self.task_ref.timeout_ms) |timeout| {
                    const timeout_thread = std.Thread.spawn(.{}, timeoutWorker, .{self.task_ref, timeout}) catch return;
                    timeout_thread.detach();
                }
                
                // Execute the actual function
                self.func_ptr(self.args_data) catch |err| {
                    _ = err; // TODO: Store error information
                    self.task_ref.state.store(.failed, .release);
                    return;
                };
                
                // Mark as completed if not already cancelled/timed out
                const current_state = self.task_ref.state.load(.acquire);
                if (current_state == .running) {
                    self.task_ref.state.store(.completed, .release);
                }
            }
            
            fn timeoutWorker(task_ref: *Task, timeout_ms: u64) void {
                std.time.sleep(timeout_ms * std.time.ns_per_ms);
                
                const current_state = task_ref.state.load(.acquire);
                if (current_state == .running) {
                    task_ref.cancel_token.cancel();
                    task_ref.state.store(.timeout, .release);
                }
            }
        };
        
        const ctx = try allocator.create(ExecutionContext);
        ctx.* = ExecutionContext{
            .task_ref = task,
            .func_ptr = func,
            .args_data = args,
            .allocator = allocator,
        };
        
        const execution_thread = try std.Thread.spawn(.{}, ExecutionContext.execute, .{ctx});
        execution_thread.detach();
    }
};

/// Options for task spawning
pub const SpawnOptions = struct {
    timeout_ms: ?u64 = null,
    priority: Task.TaskPriority = .normal,
    retry_count: u32 = 0,
    retry_delay_ms: u64 = 1000,
};

/// Handle for managing spawned tasks
pub const TaskHandle = struct {
    task: *Task,
    allocator: std.mem.Allocator,
    
    const Self = @This();
    
    pub fn deinit(self: Self) void {
        self.allocator.destroy(self.task.cancel_token);
        self.allocator.destroy(self.task);
    }
};

/// Result of task execution
pub const TaskResult = union(enum) {
    completed: void,
    cancelled: void,
    timeout: void,
    failed: anyerror,
    
    const Self = @This();
    
    pub fn isSuccess(self: Self) bool {
        return switch (self) {
            .completed => true,
            else => false,
        };
    }
    
    pub fn unwrap(self: Self) !void {
        return switch (self) {
            .completed => {},
            .cancelled => error.TaskCancelled,
            .timeout => error.TaskTimeout,
            .failed => |err| err,
        };
    }
};

/// Context for waiting on task completion
const WaitContext = struct {
    handle: TaskHandle,
    timeout_ms: u64,
    completed: std.atomic.Value(bool),
    result: ?TaskResult,
    mutex: compat.Mutex,
    condition: std.Thread.Condition,
    
    const Self = @This();
    
    pub fn init(handle: TaskHandle, timeout_ms: u64) Self {
        return Self{
            .handle = handle,
            .timeout_ms = timeout_ms,
            .completed = std.atomic.Value(bool).init(false),
            .result = null,
            .mutex = compat.Mutex{},
            .condition = std.Thread.Condition{},
        };
    }
    
    pub fn await(self: *Self) !TaskResult {
        // Start timeout timer
        const timeout_thread = try std.Thread.spawn(.{}, timeoutWatcher, .{self});
        timeout_thread.detach();
        
        // Start state watcher
        const state_thread = try std.Thread.spawn(.{}, stateWatcher, .{self});
        state_thread.detach();
        
        // Wait for completion
        self.mutex.lock();
        defer self.mutex.unlock();
        
        while (!self.completed.load(.acquire)) {
            self.condition.wait(&self.mutex);
        }
        
        return self.result orelse error.MissingResult;
    }
    
    fn timeoutWatcher(self: *Self) void {
        std.time.sleep(self.timeout_ms * std.time.ns_per_ms);
        
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (!self.completed.load(.acquire)) {
            Task.cancel(self.handle);
            self.result = TaskResult{ .timeout = {} };
            self.completed.store(true, .release);
            self.condition.broadcast();
        }
    }
    
    fn stateWatcher(self: *Self) void {
        while (!self.completed.load(.acquire)) {
            const state = Task.getState(self.handle);
            
            switch (state) {
                .completed => {
                    self.mutex.lock();
                    defer self.mutex.unlock();
                    
                    if (!self.completed.load(.acquire)) {
                        self.result = TaskResult{ .completed = {} };
                        self.completed.store(true, .release);
                        self.condition.broadcast();
                    }
                    break;
                },
                .cancelled => {
                    self.mutex.lock();
                    defer self.mutex.unlock();
                    
                    if (!self.completed.load(.acquire)) {
                        self.result = TaskResult{ .cancelled = {} };
                        self.completed.store(true, .release);
                        self.condition.broadcast();
                    }
                    break;
                },
                .timeout => {
                    self.mutex.lock();
                    defer self.mutex.unlock();
                    
                    if (!self.completed.load(.acquire)) {
                        self.result = TaskResult{ .timeout = {} };
                        self.completed.store(true, .release);
                        self.condition.broadcast();
                    }
                    break;
                },
                .failed => {
                    self.mutex.lock();
                    defer self.mutex.unlock();
                    
                    if (!self.completed.load(.acquire)) {
                        self.result = TaskResult{ .failed = error.TaskExecutionFailed };
                        self.completed.store(true, .release);
                        self.condition.broadcast();
                    }
                    break;
                },
                else => {
                    std.time.sleep(1 * std.time.ns_per_ms); // Small delay
                },
            }
        }
    }
};

/// Batch task manager for coordinated operations
pub const TaskBatch = struct {
    allocator: std.mem.Allocator,
    tasks: std.ArrayList(TaskHandle),
    cancel_all_token: *future_combinators.CancelToken,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) !Self {
        const cancel_token = try future_combinators.createCancelToken(allocator);
        
        return Self{
            .allocator = allocator,
            .tasks = std.ArrayList(TaskHandle){ .allocator = allocator },
            .cancel_all_token = cancel_token,
        };
    }
    
    pub fn deinit(self: Self) void {
        for (self.tasks.items) |handle| {
            handle.deinit();
        }
        self.tasks.deinit();
        self.allocator.destroy(self.cancel_all_token);
    }
    
    /// Spawn a task as part of this batch
    pub fn spawn(
        self: *Self,
        comptime func: anytype,
        args: anytype,
        options: SpawnOptions,
    ) !void {
        const handle = try Task.spawn(self.allocator, func, args, options);
        try self.tasks.append(self.allocator, handle);
    }
    
    /// Cancel all tasks in the batch
    pub fn cancelAll(self: *Self) void {
        self.cancel_all_token.cancel();
        for (self.tasks.items) |handle| {
            Task.cancel(handle);
        }
    }
    
    /// Wait for all tasks to complete
    pub fn waitAll(self: *Self, timeout_ms: u64) ![]TaskResult {
        var results = try self.allocator.alloc(TaskResult, self.tasks.items.len);
        
        for (self.tasks.items, 0..) |handle, i| {
            results[i] = try Task.waitWithTimeout(self.allocator, handle, timeout_ms);
        }
        
        return results;
    }
    
    /// Get count of completed tasks
    pub fn getCompletedCount(self: *const Self) usize {
        var count: usize = 0;
        for (self.tasks.items) |handle| {
            const state = Task.getState(handle);
            if (state == .completed) {
                count += 1;
            }
        }
        return count;
    }
    
    /// Get count of running tasks
    pub fn getRunningCount(self: *const Self) usize {
        var count: usize = 0;
        for (self.tasks.items) |handle| {
            const state = Task.getState(handle);
            if (state == .running) {
                count += 1;
            }
        }
        return count;
    }
};

test "Task spawning and cancellation" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    const TestFunction = struct {
        fn longRunningTask(duration_ms: u64) !void {
            std.time.sleep(duration_ms * std.time.ns_per_ms);
        }
    };
    
    const handle = try Task.spawn(allocator, TestFunction.longRunningTask, .{1000}, .{
        .timeout_ms = 500,
    });
    defer handle.deinit();
    
    const result = try Task.waitWithTimeout(allocator, handle, 600);
    try testing.expect(result == .timeout);
}

test "TaskBatch operations" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var batch = try TaskBatch.init(allocator);
    defer batch.deinit();
    
    const TestFunction = struct {
        fn quickTask(value: u32) !void {
            _ = value;
            std.time.sleep(10 * std.time.ns_per_ms);
        }
    };
    
    try batch.spawn(TestFunction.quickTask, .{1}, .{});
    try batch.spawn(TestFunction.quickTask, .{2}, .{});
    try batch.spawn(TestFunction.quickTask, .{3}, .{});
    
    const results = try batch.waitAll(1000);
    defer allocator.free(results);
    
    for (results) |result| {
        try testing.expect(result.isSuccess());
    }
}