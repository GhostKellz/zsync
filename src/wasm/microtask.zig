//! Zsync v0.6.0 - Microtask Queue for WASM
//! Browser-compatible microtask queue for async operations in WASM

const std = @import("std");

/// Microtask function signature
pub const MicrotaskFn = *const fn (*anyopaque) anyerror!void;

/// Microtask entry
pub const Microtask = struct {
    callback: MicrotaskFn,
    context: *anyopaque,
};

/// Microtask Queue (browser-compatible)
pub const MicrotaskQueue = struct {
    allocator: std.mem.Allocator,
    tasks: std.ArrayList(Microtask),
    flushing: std.atomic.Value(bool),
    mutex: std.Thread.Mutex,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .tasks = std.ArrayList(Microtask){ .allocator = allocator },
            .flushing = std.atomic.Value(bool).init(false),
            .mutex = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        self.tasks.deinit();
    }

    /// Queue a microtask
    pub fn queueMicrotask(self: *Self, callback: MicrotaskFn, context: *anyopaque) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.tasks.append(self.allocator, Microtask{
            .callback = callback,
            .context = context,
        });
    }

    /// Flush all pending microtasks
    pub fn flush(self: *Self) !void {
        if (self.flushing.load(.acquire)) return;
        self.flushing.store(true, .release);
        defer self.flushing.store(false, .release);

        while (true) {
            // Get next batch
            self.mutex.lock();
            if (self.tasks.items.len == 0) {
                self.mutex.unlock();
                break;
            }

            const batch = try self.allocator.dupe(Microtask, self.tasks.items);
            self.tasks.clearRetainingCapacity();
            self.mutex.unlock();

            // Execute batch
            for (batch) |task| {
                task.callback(task.context) catch |err| {
                    std.debug.print("[Microtask] Error: {}\n", .{err});
                };
            }

            self.allocator.free(batch);
        }
    }

    /// Get pending task count
    pub fn pending(self: *Self) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.tasks.items.len;
    }
};

/// Global microtask queue (WASM-friendly)
var global_queue: ?*MicrotaskQueue = null;
var global_mutex: std.Thread.Mutex = .{};

/// Initialize global microtask queue
pub fn initGlobalQueue(allocator: std.mem.Allocator) !void {
    global_mutex.lock();
    defer global_mutex.unlock();

    if (global_queue == null) {
        const queue = try allocator.create(MicrotaskQueue);
        queue.* = MicrotaskQueue.init(allocator);
        global_queue = queue;
    }
}

/// Deinitialize global microtask queue
pub fn deinitGlobalQueue(allocator: std.mem.Allocator) void {
    global_mutex.lock();
    defer global_mutex.unlock();

    if (global_queue) |queue| {
        queue.deinit();
        allocator.destroy(queue);
        global_queue = null;
    }
}

/// Queue a microtask on the global queue
pub fn queueMicrotask(callback: MicrotaskFn, context: *anyopaque) !void {
    global_mutex.lock();
    const queue = global_queue;
    global_mutex.unlock();

    if (queue) |q| {
        try q.queueMicrotask(callback, context);
    } else {
        return error.QueueNotInitialized;
    }
}

/// Flush global microtask queue
pub fn flushMicrotasks() !void {
    global_mutex.lock();
    const queue = global_queue;
    global_mutex.unlock();

    if (queue) |q| {
        try q.flush();
    }
}

// Tests
test "microtask queue basic" {
    const testing = std.testing;

    var queue = MicrotaskQueue.init(testing.allocator);
    defer queue.deinit();

    const Context = struct {
        var executed: bool = false;

        fn task(ctx: *anyopaque) !void {
            _ = ctx;
            executed = true;
        }
    };

    var ctx: u32 = 0;
    try queue.queueMicrotask(Context.task, @ptrCast(&ctx));
    try testing.expectEqual(1, queue.pending());

    try queue.flush();
    try testing.expect(Context.executed);
    try testing.expectEqual(0, queue.pending());
}
