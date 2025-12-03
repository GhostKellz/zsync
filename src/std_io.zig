//! zsync - std.Io Compatible Interface
//! Implements Zig 0.16's std.Io VTable pattern for seamless integration
//! Provides real threaded concurrency with worker pool

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const posix = std.posix;

// ============================================================================
// Public Types
// ============================================================================

/// zsync I/O implementation compatible with std.Io patterns
pub const Io = struct {
    userdata: ?*anyopaque,
    vtable: *const VTable,

    const Self = @This();

    /// Dispatch an async task
    /// The task may or may not run concurrently depending on the backend
    pub fn @"async"(
        self: Self,
        comptime func: anytype,
        args: anytype,
    ) Future(@typeInfo(@TypeOf(func)).@"fn".return_type.?) {
        const Result = @typeInfo(@TypeOf(func)).@"fn".return_type.?;
        const Args = @TypeOf(args);

        const TypeErased = struct {
            fn start(context: *const anyopaque, result_ptr: *anyopaque) void {
                const ctx: *const Args = @ptrCast(@alignCast(context));
                const res: *Result = @ptrCast(@alignCast(result_ptr));
                res.* = @call(.auto, func, ctx.*);
            }
        };

        var future: Future(Result) = undefined;
        future.any_future = self.vtable.@"async"(
            self.userdata,
            @as([*]u8, @ptrCast(&future.result))[0..@sizeOf(Result)],
            .of(Result),
            @as([*]const u8, @ptrCast(&args))[0..@sizeOf(Args)],
            .of(Args),
            TypeErased.start,
        );
        return future;
    }

    /// Dispatch a concurrent task
    /// Guarantees parallel execution, returns error if unavailable
    pub fn concurrent(
        self: Self,
        comptime func: anytype,
        args: anytype,
    ) ConcurrentError!Future(@typeInfo(@TypeOf(func)).@"fn".return_type.?) {
        const Result = @typeInfo(@TypeOf(func)).@"fn".return_type.?;
        const Args = @TypeOf(args);

        const TypeErased = struct {
            fn start(context: *const anyopaque, result_ptr: *anyopaque) void {
                const ctx: *const Args = @ptrCast(@alignCast(context));
                const res: *Result = @ptrCast(@alignCast(result_ptr));
                res.* = @call(.auto, func, ctx.*);
            }
        };

        var future: Future(Result) = undefined;
        future.any_future = try self.vtable.concurrent(
            self.userdata,
            @sizeOf(Result),
            .of(Result),
            @as([*]const u8, @ptrCast(&args))[0..@sizeOf(Args)],
            .of(Args),
            TypeErased.start,
        );
        return future;
    }

    /// Check if cancellation has been requested for current task
    pub fn cancelRequested(self: Self) bool {
        return self.vtable.cancelRequested(self.userdata);
    }

    /// Sleep for a duration
    pub fn sleep(self: Self, nanoseconds: u64) void {
        self.vtable.sleep(self.userdata, nanoseconds);
    }
};

/// Future handle for async operations
pub fn Future(comptime T: type) type {
    return struct {
        any_future: ?*AnyFuture,
        result: T,

        const Self = @This();

        /// Wait for the result - blocks until task completes
        pub fn @"await"(self: *Self, io: Io) T {
            const any_future = self.any_future orelse return self.result;
            io.vtable.@"await"(
                io.userdata,
                any_future,
                @as([*]u8, @ptrCast(&self.result))[0..@sizeOf(T)],
                .of(T),
            );
            self.any_future = null;
            return self.result;
        }

        /// Cancel the task and wait for cleanup
        pub fn cancel(self: *Self, io: Io) T {
            const any_future = self.any_future orelse return self.result;
            io.vtable.cancel(
                io.userdata,
                any_future,
                @as([*]u8, @ptrCast(&self.result))[0..@sizeOf(T)],
                .of(T),
            );
            self.any_future = null;
            return self.result;
        }
    };
}

/// Opaque future type for VTable
pub const AnyFuture = opaque {};

/// Error returned when concurrency is unavailable
pub const ConcurrentError = error{ConcurrencyUnavailable};

/// Cancelable result wrapper
pub const Cancelable = error{Canceled};

/// Limit type for thread pool sizing
pub const Limit = enum(usize) {
    nothing = 0,
    unlimited = std.math.maxInt(usize),
    _,

    pub fn limited(n: usize) Limit {
        return @enumFromInt(n);
    }
};

// ============================================================================
// VTable Definition
// ============================================================================

/// VTable for std.Io compatibility
pub const VTable = struct {
    @"async": *const fn (
        userdata: ?*anyopaque,
        result: []u8,
        result_alignment: Alignment,
        context: []const u8,
        context_alignment: Alignment,
        start: *const fn (*const anyopaque, *anyopaque) void,
    ) ?*AnyFuture,

    concurrent: *const fn (
        userdata: ?*anyopaque,
        result_len: usize,
        result_alignment: Alignment,
        context: []const u8,
        context_alignment: Alignment,
        start: *const fn (*const anyopaque, *anyopaque) void,
    ) ConcurrentError!*AnyFuture,

    @"await": *const fn (
        userdata: ?*anyopaque,
        any_future: *AnyFuture,
        result: []u8,
        result_alignment: Alignment,
    ) void,

    cancel: *const fn (
        userdata: ?*anyopaque,
        any_future: *AnyFuture,
        result: []u8,
        result_alignment: Alignment,
    ) void,

    cancelRequested: *const fn (?*anyopaque) bool,

    sleep: *const fn (?*anyopaque, nanoseconds: u64) void,
};

// ============================================================================
// Threaded Backend - Real Thread Pool Implementation
// ============================================================================

/// Threaded I/O backend with real worker thread pool
/// Provides actual concurrent execution of async tasks
pub const Threaded = struct {
    allocator: Allocator,
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    run_queue: std.SinglyLinkedList = .{},
    join_requested: bool = false,
    stack_size: usize,
    wait_group: std.Thread.WaitGroup = .{},
    async_limit: Limit,
    concurrent_limit: Limit = .unlimited,
    busy_count: usize = 0,

    const Self = @This();

    /// Thread-local storage for current closure (for cancellation)
    threadlocal var current_closure: ?*Closure = null;

    /// Initialize threaded backend with allocator
    pub fn init(allocator: Allocator) Self {
        const cpu_count = std.Thread.getCpuCount() catch 4;
        return .{
            .allocator = allocator,
            .stack_size = std.Thread.SpawnConfig.default_stack_size,
            .async_limit = Limit.limited(cpu_count),
        };
    }

    /// Initialize with custom limits
    pub fn initWithLimits(allocator: Allocator, async_limit: Limit, concurrent_limit: Limit) Self {
        return .{
            .allocator = allocator,
            .stack_size = std.Thread.SpawnConfig.default_stack_size,
            .async_limit = async_limit,
            .concurrent_limit = concurrent_limit,
        };
    }

    /// Single-threaded mode (no real concurrency)
    pub const init_single_threaded: Self = .{
        .allocator = std.heap.page_allocator,
        .stack_size = std.Thread.SpawnConfig.default_stack_size,
        .async_limit = .nothing,
        .concurrent_limit = .nothing,
    };

    pub fn deinit(self: *Self) void {
        self.join();
        self.* = undefined;
    }

    fn join(self: *Self) void {
        if (builtin.single_threaded) return;
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.join_requested = true;
        }
        self.cond.broadcast();
        self.wait_group.wait();
    }

    /// Worker thread main loop
    fn worker(self: *Self) void {
        defer self.wait_group.finish();

        self.mutex.lock();
        defer self.mutex.unlock();

        while (true) {
            while (self.run_queue.popFirst()) |closure_node| {
                self.mutex.unlock();
                const closure: *Closure = @fieldParentPtr("node", closure_node);
                closure.start(closure);
                self.mutex.lock();
                self.busy_count -= 1;
            }
            if (self.join_requested) break;
            self.cond.wait(&self.mutex);
        }
    }

    /// Get Io interface for this backend
    pub fn io(self: *Self) Io {
        return .{
            .userdata = self,
            .vtable = &threaded_vtable,
        };
    }

    // ========================================================================
    // Internal Types
    // ========================================================================

    const CancelId = enum(usize) {
        none = 0,
        canceling = std.math.maxInt(usize),
        _,

        fn currentThread() CancelId {
            return @enumFromInt(std.Thread.getCurrentId());
        }
    };

    const Closure = struct {
        start: *const fn (*Closure) void,
        node: std.SinglyLinkedList.Node = .{},
        cancel_tid: std.atomic.Value(CancelId),

        fn requestCancel(closure: *Closure) void {
            _ = closure.cancel_tid.swap(.canceling, .acq_rel);
        }
    };

    /// Reset event for task completion signaling
    const ResetEvent = struct {
        state: std.atomic.Value(State) = .{ .raw = .unset },

        const State = enum(u32) {
            unset = 0,
            set = 1,
            waiting = 2,
        };

        const unset: ResetEvent = .{ .state = .{ .raw = .unset } };

        fn set(self: *ResetEvent) void {
            const prev = self.state.swap(.set, .release);
            if (prev == .waiting) {
                std.Thread.Futex.wake(@ptrCast(&self.state), 1);
            }
        }

        fn wait(self: *ResetEvent) void {
            while (true) {
                const state = self.state.load(.acquire);
                if (state == .set) return;

                if (self.state.cmpxchgWeak(.unset, .waiting, .acquire, .acquire)) |_| {
                    continue;
                }

                std.Thread.Futex.wait(@ptrCast(&self.state), @intFromEnum(State.waiting), null);
            }
        }
    };

    /// Async task closure with trailing context and result data
    const AsyncClosure = struct {
        closure: Closure,
        func: *const fn (context: *const anyopaque, result: *anyopaque) void,
        reset_event: ResetEvent,
        context_alignment: Alignment,
        result_offset: usize,
        alloc_len: usize,

        fn start(closure: *Closure) void {
            const ac: *AsyncClosure = @alignCast(@fieldParentPtr("closure", closure));
            const tid: CancelId = .currentThread();

            // Try to claim the task
            _ = ac.closure.cancel_tid.cmpxchgStrong(.none, tid, .acq_rel, .acquire);

            current_closure = closure;
            ac.func(ac.contextPointer(), ac.resultPointer());
            current_closure = null;

            // Clear thread ID to prevent spurious cancellation signals
            _ = ac.closure.cancel_tid.cmpxchgStrong(tid, .none, .acq_rel, .acquire);

            ac.reset_event.set();
        }

        fn resultPointer(ac: *AsyncClosure) [*]u8 {
            const base: [*]u8 = @ptrCast(ac);
            return base + ac.result_offset;
        }

        fn contextPointer(ac: *AsyncClosure) [*]u8 {
            const base: [*]u8 = @ptrCast(ac);
            const context_offset = ac.context_alignment.forward(@intFromPtr(ac) + @sizeOf(AsyncClosure)) - @intFromPtr(ac);
            return base + context_offset;
        }

        fn create(
            gpa: Allocator,
            result_len: usize,
            result_alignment: Alignment,
            context: []const u8,
            context_alignment: Alignment,
            func: *const fn (context: *const anyopaque, result: *anyopaque) void,
        ) Allocator.Error!*AsyncClosure {
            const max_context_misalignment = context_alignment.toByteUnits() -| @alignOf(AsyncClosure);
            const worst_case_context_offset = context_alignment.forward(@sizeOf(AsyncClosure) + max_context_misalignment);
            const worst_case_result_offset = result_alignment.forward(worst_case_context_offset + context.len);
            const alloc_len = worst_case_result_offset + result_len;

            const mem = try gpa.alignedAlloc(u8, .of(AsyncClosure), alloc_len);
            const ac: *AsyncClosure = @ptrCast(@alignCast(mem.ptr));

            const actual_context_addr = context_alignment.forward(@intFromPtr(ac) + @sizeOf(AsyncClosure));
            const actual_result_addr = result_alignment.forward(actual_context_addr + context.len);
            const actual_result_offset = actual_result_addr - @intFromPtr(ac);

            ac.* = .{
                .closure = .{
                    .cancel_tid = .{ .raw = .none },
                    .start = start,
                },
                .func = func,
                .context_alignment = context_alignment,
                .result_offset = actual_result_offset,
                .alloc_len = alloc_len,
                .reset_event = .unset,
            };
            @memcpy(ac.contextPointer()[0..context.len], context);
            return ac;
        }

        fn waitAndDeinit(ac: *AsyncClosure, t: *Threaded, result: []u8) void {
            ac.reset_event.wait();
            @memcpy(result, ac.resultPointer()[0..result.len]);
            ac.destroy(t.allocator);
        }

        fn cancelAndDeinit(ac: *AsyncClosure, t: *Threaded, result: []u8) void {
            ac.closure.requestCancel();
            ac.reset_event.wait();
            @memcpy(result, ac.resultPointer()[0..result.len]);
            ac.destroy(t.allocator);
        }

        fn destroy(ac: *AsyncClosure, gpa: Allocator) void {
            const base: [*]align(@alignOf(AsyncClosure)) u8 = @ptrCast(ac);
            gpa.free(base[0..ac.alloc_len]);
        }
    };

    // ========================================================================
    // VTable Implementation
    // ========================================================================

    const threaded_vtable: VTable = .{
        .@"async" = threadedAsync,
        .concurrent = threadedConcurrent,
        .@"await" = threadedAwait,
        .cancel = threadedCancel,
        .cancelRequested = threadedCancelRequested,
        .sleep = threadedSleep,
    };

    fn threadedAsync(
        userdata: ?*anyopaque,
        result: []u8,
        result_alignment: Alignment,
        context: []const u8,
        context_alignment: Alignment,
        start: *const fn (*const anyopaque, *anyopaque) void,
    ) ?*AnyFuture {
        const t: *Threaded = @ptrCast(@alignCast(userdata.?));

        if (builtin.single_threaded) {
            start(context.ptr, result.ptr);
            return null;
        }

        const gpa = t.allocator;
        const ac = AsyncClosure.create(gpa, result.len, result_alignment, context, context_alignment, start) catch {
            // Fallback: run synchronously
            start(context.ptr, result.ptr);
            return null;
        };

        t.mutex.lock();

        const busy_count = t.busy_count;

        // Check if we've hit the async limit
        if (busy_count >= @intFromEnum(t.async_limit)) {
            t.mutex.unlock();
            ac.destroy(gpa);
            start(context.ptr, result.ptr);
            return null;
        }

        t.busy_count = busy_count + 1;

        // Spawn new worker if needed
        const pool_size = t.wait_group.value();
        if (pool_size == 0 or pool_size <= busy_count) {
            t.wait_group.start();
            const thread = std.Thread.spawn(.{ .stack_size = t.stack_size }, worker, .{t}) catch {
                t.wait_group.finish();
                t.busy_count = busy_count;
                t.mutex.unlock();
                ac.destroy(gpa);
                start(context.ptr, result.ptr);
                return null;
            };
            thread.detach();
        }

        t.run_queue.prepend(&ac.closure.node);
        t.mutex.unlock();
        t.cond.signal();
        return @ptrCast(ac);
    }

    fn threadedConcurrent(
        userdata: ?*anyopaque,
        result_len: usize,
        result_alignment: Alignment,
        context: []const u8,
        context_alignment: Alignment,
        start: *const fn (*const anyopaque, *anyopaque) void,
    ) ConcurrentError!*AnyFuture {
        if (builtin.single_threaded) return error.ConcurrencyUnavailable;

        const t: *Threaded = @ptrCast(@alignCast(userdata.?));
        const gpa = t.allocator;

        const ac = AsyncClosure.create(gpa, result_len, result_alignment, context, context_alignment, start) catch
            return error.ConcurrencyUnavailable;
        errdefer ac.destroy(gpa);

        t.mutex.lock();
        defer t.mutex.unlock();

        const busy_count = t.busy_count;

        if (busy_count >= @intFromEnum(t.concurrent_limit))
            return error.ConcurrencyUnavailable;

        t.busy_count = busy_count + 1;

        // Spawn new worker if needed
        const pool_size = t.wait_group.value();
        if (pool_size == 0 or pool_size <= busy_count) {
            t.wait_group.start();
            const thread = std.Thread.spawn(.{ .stack_size = t.stack_size }, worker, .{t}) catch {
                t.wait_group.finish();
                t.busy_count = busy_count;
                return error.ConcurrencyUnavailable;
            };
            thread.detach();
        }

        t.run_queue.prepend(&ac.closure.node);
        t.cond.signal();
        return @ptrCast(ac);
    }

    fn threadedAwait(
        userdata: ?*anyopaque,
        any_future: *AnyFuture,
        result: []u8,
        result_alignment: Alignment,
    ) void {
        _ = result_alignment;
        const t: *Threaded = @ptrCast(@alignCast(userdata.?));
        const ac: *AsyncClosure = @ptrCast(@alignCast(any_future));
        ac.waitAndDeinit(t, result);
    }

    fn threadedCancel(
        userdata: ?*anyopaque,
        any_future: *AnyFuture,
        result: []u8,
        result_alignment: Alignment,
    ) void {
        _ = result_alignment;
        const t: *Threaded = @ptrCast(@alignCast(userdata.?));
        const ac: *AsyncClosure = @ptrCast(@alignCast(any_future));
        ac.cancelAndDeinit(t, result);
    }

    fn threadedCancelRequested(userdata: ?*anyopaque) bool {
        _ = userdata;
        if (current_closure) |closure| {
            return closure.cancel_tid.load(.acquire) == .canceling;
        }
        return false;
    }

    fn threadedSleep(userdata: ?*anyopaque, nanoseconds: u64) void {
        _ = userdata;
        std.time.sleep(nanoseconds);
    }
};

// ============================================================================
// Blocking Backend - Simple synchronous execution
// ============================================================================

/// Blocking I/O backend - runs everything synchronously
/// Useful for simple use cases or as fallback
pub const Blocking = struct {
    allocator: Allocator,

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        self.* = undefined;
    }

    pub fn io(self: *Self) Io {
        return .{
            .userdata = self,
            .vtable = &blocking_vtable,
        };
    }

    const blocking_vtable: VTable = .{
        .@"async" = blockingAsync,
        .concurrent = blockingConcurrent,
        .@"await" = blockingAwait,
        .cancel = blockingCancel,
        .cancelRequested = blockingCancelRequested,
        .sleep = blockingSleep,
    };

    fn blockingAsync(
        userdata: ?*anyopaque,
        result: []u8,
        result_alignment: Alignment,
        context: []const u8,
        context_alignment: Alignment,
        start: *const fn (*const anyopaque, *anyopaque) void,
    ) ?*AnyFuture {
        _ = userdata;
        _ = result_alignment;
        _ = context_alignment;
        start(context.ptr, result.ptr);
        return null; // Eager result
    }

    fn blockingConcurrent(
        userdata: ?*anyopaque,
        result_len: usize,
        result_alignment: Alignment,
        context: []const u8,
        context_alignment: Alignment,
        start: *const fn (*const anyopaque, *anyopaque) void,
    ) ConcurrentError!*AnyFuture {
        _ = userdata;
        _ = result_len;
        _ = result_alignment;
        _ = context;
        _ = context_alignment;
        _ = start;
        return error.ConcurrencyUnavailable;
    }

    fn blockingAwait(
        userdata: ?*anyopaque,
        any_future: *AnyFuture,
        result: []u8,
        result_alignment: Alignment,
    ) void {
        _ = userdata;
        _ = any_future;
        _ = result;
        _ = result_alignment;
    }

    fn blockingCancel(
        userdata: ?*anyopaque,
        any_future: *AnyFuture,
        result: []u8,
        result_alignment: Alignment,
    ) void {
        _ = userdata;
        _ = any_future;
        _ = result;
        _ = result_alignment;
    }

    fn blockingCancelRequested(userdata: ?*anyopaque) bool {
        _ = userdata;
        return false;
    }

    fn blockingSleep(userdata: ?*anyopaque, nanoseconds: u64) void {
        _ = userdata;
        std.time.sleep(nanoseconds);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "threaded basic async" {
    const testing = std.testing;

    var t = Threaded.init(testing.allocator);
    defer t.deinit();

    const io_instance = t.io();

    const add = struct {
        fn call(a: i32, b: i32) i32 {
            return a + b;
        }
    }.call;

    var future = io_instance.@"async"(add, .{ 2, 3 });
    const result = future.@"await"(io_instance);

    try testing.expectEqual(@as(i32, 5), result);
}

test "threaded concurrent" {
    const testing = std.testing;

    var t = Threaded.init(testing.allocator);
    defer t.deinit();

    const io_instance = t.io();

    const multiply = struct {
        fn call(a: i32, b: i32) i32 {
            return a * b;
        }
    }.call;

    // This should spawn a real thread
    var future = io_instance.concurrent(multiply, .{ 6, 7 }) catch {
        // Concurrency unavailable is acceptable in some environments
        return;
    };
    const result = future.@"await"(io_instance);

    try testing.expectEqual(@as(i32, 42), result);
}

test "threaded multiple concurrent tasks" {
    const testing = std.testing;

    var t = Threaded.init(testing.allocator);
    defer t.deinit();

    const io_instance = t.io();

    const work = struct {
        fn call(x: i32) i32 {
            // Simulate some work
            var sum: i32 = 0;
            var i: i32 = 0;
            while (i < 1000) : (i += 1) {
                sum += x;
            }
            return sum;
        }
    }.call;

    // Spawn multiple concurrent tasks
    var future1 = io_instance.@"async"(work, .{@as(i32, 1)});
    var future2 = io_instance.@"async"(work, .{@as(i32, 2)});
    var future3 = io_instance.@"async"(work, .{@as(i32, 3)});

    const r1 = future1.@"await"(io_instance);
    const r2 = future2.@"await"(io_instance);
    const r3 = future3.@"await"(io_instance);

    try testing.expectEqual(@as(i32, 1000), r1);
    try testing.expectEqual(@as(i32, 2000), r2);
    try testing.expectEqual(@as(i32, 3000), r3);
}

test "blocking basic" {
    const testing = std.testing;

    var b = Blocking.init(testing.allocator);
    defer b.deinit();

    const io_instance = b.io();

    const sub = struct {
        fn call(a: i32, b_val: i32) i32 {
            return a - b_val;
        }
    }.call;

    var future = io_instance.@"async"(sub, .{ 10, 3 });
    const result = future.@"await"(io_instance);

    try testing.expectEqual(@as(i32, 7), result);
}

test "cancel requested" {
    const testing = std.testing;

    var t = Threaded.init(testing.allocator);
    defer t.deinit();

    const io_instance = t.io();

    // Outside of a task, should return false
    try testing.expect(!io_instance.cancelRequested());
}
