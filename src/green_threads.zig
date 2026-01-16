//! zsync- Green Threads with io_uring
//! High-performance cooperative multitasking using io_uring for Linux

const std = @import("std");
const builtin = @import("builtin");
const io_interface = @import("io_interface.zig");
const platform_imports = @import("platform_imports.zig");
const io_uring = platform_imports.linux.io_uring;
const platform_detect = @import("platform_detect.zig");
const arch = switch (builtin.cpu.arch) {
    .x86_64 => @import("arch/x86_64.zig"),
    .aarch64 => @import("arch/aarch64.zig"),
    else => @compileError("Architecture not supported for green threads"),
};

const Io = io_interface.Io;
const IoMode = io_interface.IoMode;
const IoError = io_interface.IoError;
const IoBuffer = io_interface.IoBuffer;
const Future = io_interface.Future;

/// Green threads implementation using io_uring
pub const GreenThreadsIo = struct {
    allocator: std.mem.Allocator,
    reactor: io_uring.IoUringReactor,
    scheduler: Scheduler,
    metrics: Metrics,
    
    const Self = @This();
    
    const Metrics = struct {
        operations_submitted: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        operations_completed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        green_threads_spawned: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        context_switches: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    };
    
    /// Green thread representation - defined first for forward references
    const GreenThread = struct {
        id: u64,
        stack: []u8,
        context: arch.Context,
        state: State,
        task: Task,
        allocator: std.mem.Allocator,
        
        const ThreadSelf = @This();
        
        const State = enum {
            ready,
            running,
            blocked,
            completed,
        };
        
        const STACK_SIZE = 64 * 1024; // 64KB stack
        
        pub fn init(allocator: std.mem.Allocator, task: Task) !*ThreadSelf {
            const thread = try allocator.create(ThreadSelf);
            const stack = try arch.allocateStack(allocator);
            
            // Initialize context for this green thread
            var context: arch.Context = undefined;
            arch.makeContext(&context, stack, threadEntry, @ptrCast(thread));
            
            thread.* = ThreadSelf{
                .id = @intFromPtr(thread), // Use pointer as ID
                .stack = stack,
                .context = context,
                .state = .ready,
                .task = task,
                .allocator = allocator,
            };
            
            return thread;
        }
        
        pub fn deinit(self: *ThreadSelf) void {
            arch.deallocateStack(self.allocator, self.stack);
            self.allocator.destroy(self);
        }
        
        pub fn start(self: *ThreadSelf) void {
            self.state = .running;
            
            // Get current context to switch back to
            const old_ctx = arch.getCurrentContext();
            
            // Set this thread as current
            arch.setCurrentContext(&self.context);
            
            // Perform context switch if we have a previous context
            if (old_ctx) |old| {
                arch.swapContext(old, &self.context);
            } else {
                // First run - initialize and start execution
                self.task.run() catch {
                    self.state = .completed;
                };
            }
        }
    };
    
    /// Simple green thread scheduler
    const Scheduler = struct {
        ready_queue: std.ArrayList(*GreenThread),
        blocked_queue: std.ArrayList(*GreenThread),
        current_thread: ?*GreenThread,
        allocator: std.mem.Allocator,
        is_shutdown: bool,

        const SchedulerSelf = @This();

        pub fn init(allocator: std.mem.Allocator) SchedulerSelf {
            return SchedulerSelf{
                .ready_queue = std.ArrayList(*GreenThread){},
                .blocked_queue = std.ArrayList(*GreenThread){},
                .current_thread = null,
                .allocator = allocator,
                .is_shutdown = false,
            };
        }

        pub fn deinit(self: *SchedulerSelf) void {
            // Guard against double-free: only cleanup once
            if (self.is_shutdown) return;
            self.is_shutdown = true;

            // Clean up threads
            for (self.ready_queue.items) |thread| {
                thread.deinit();
            }
            for (self.blocked_queue.items) |thread| {
                thread.deinit();
            }

            self.ready_queue.deinit(self.allocator);
            self.blocked_queue.deinit(self.allocator);
        }
        
        pub fn spawn(self: *SchedulerSelf, task: Task) !*GreenThread {
            const thread = try GreenThread.init(self.allocator, task);
            try self.ready_queue.append(self.allocator, thread);
            return thread;
        }
        
        pub fn yield(self: *SchedulerSelf) void {
            if (self.current_thread) |current| {
                // Save context and move to ready queue
                current.state = .ready;
                self.ready_queue.append(self.allocator, current) catch return;
                
                // Context switch back to scheduler
                const scheduler_ctx = arch.getCurrentContext();
                if (scheduler_ctx) |sched| {
                    arch.swapContext(&current.context, sched);
                }
                
                self.current_thread = null;
            }
            self.schedule();
        }
        
        pub fn block(self: *SchedulerSelf, thread: *GreenThread) !void {
            try self.blocked_queue.append(self.allocator, thread);
        }
        
        pub fn unblock(self: *SchedulerSelf, thread: *GreenThread) !void {
            // Remove from blocked queue
            for (self.blocked_queue.items, 0..) |blocked_thread, i| {
                if (blocked_thread == thread) {
                    _ = self.blocked_queue.swapRemove(i);
                    try self.ready_queue.append(self.allocator, thread);
                    break;
                }
            }
        }
        
        pub fn schedule(self: *SchedulerSelf) void {
            if (self.ready_queue.items.len > 0) {
                const thread = self.ready_queue.swapRemove(0);
                self.current_thread = thread;
                thread.start();
            }
        }
    };
    
    /// Task representation
    const Task = struct {
        run_fn: *const fn () anyerror!void,
        
        const TaskSelf = @This();
        
        pub fn run(self: TaskSelf) !void {
            try self.run_fn();
        }
    };
    
    /// Entry point for green threads
    fn threadEntry(thread_ptr: *anyopaque) void {
        const thread: *GreenThread = @ptrCast(@alignCast(thread_ptr));
        
        // Execute the task
        thread.task.run() catch |err| {
            std.debug.print("Green thread task failed: {}\n", .{err});
        };
        
        // Mark as completed
        thread.state = .completed;
        
        // Yield back to scheduler
        // This should trigger a context switch back to the main scheduler
        // In a full implementation, this would properly clean up the thread
    }
    
    /// Initialize green threads with io_uring
    pub fn init(allocator: std.mem.Allocator, queue_depth: u32) !Self {
        if (builtin.os.tag != .linux) {
            return IoError.NotSupported;
        }
        
        const caps = platform_detect.detectSystemCapabilities();
        if (!caps.has_io_uring) {
            return IoError.NotSupported;
        }
        
        const config = io_uring.IoUringConfig{ .entries = queue_depth };
        const reactor = try io_uring.IoUringReactor.init(allocator, config);
        
        return Self{
            .allocator = allocator,
            .reactor = reactor,
            .scheduler = Scheduler.init(allocator),
            .metrics = Metrics{},
        };
    }
    
    /// Cleanup resources
    pub fn deinit(self: *Self) void {
        self.scheduler.deinit();
        self.reactor.deinit();
    }
    
    /// Get Io interface
    pub fn io(self: *Self) Io {
        return Io.init(&vtable, self);
    }
    
    /// Get allocator
    pub fn getAllocator(self: *const Self) std.mem.Allocator {
        return self.allocator;
    }
    
    /// Get metrics
    pub fn getMetrics(self: *const Self) Metrics {
        return self.metrics;
    }
    
    /// Process I/O events and schedule green threads
    pub fn poll(self: *Self, timeout_ms: u32) !void {
        // Process I/O completions from io_uring
        const completed = try self.reactor.poll(timeout_ms);
        _ = self.metrics.operations_completed.fetchAdd(completed, .monotonic);
        
        // Resume any green threads that were waiting on I/O
        try self.processCompletions();
        
        // Schedule ready green threads
        self.scheduler.schedule();
    }
    
    /// Process completed I/O operations and resume waiting threads
    fn processCompletions(self: *Self) !void {
        // This would iterate through completed operations
        // and resume the corresponding green threads
        // Implementation depends on io_uring reactor design
        _ = self; // Placeholder
    }
    
    /// Adapter to convert io_uring.Future to io_interface.Future
    const FutureAdapter = struct {
        io_uring_future: io_uring.Future,
        allocator: std.mem.Allocator,
        
        const FutureAdapterSelf = @This();
        
        pub fn adapterPoll(context: *anyopaque) Future.PollResult {
            const adapter: *FutureAdapterSelf = @ptrCast(@alignCast(context));
            
            // Check if the io_uring operation is complete
            if (adapter.io_uring_future.reactor.pending_ops.get(adapter.io_uring_future.user_data)) |pending_op| {
                if (pending_op.completed.load(.acquire)) {
                    const result = pending_op.result;
                    // Clean up the pending operation
                    _ = adapter.io_uring_future.reactor.pending_ops.remove(adapter.io_uring_future.user_data);
                    adapter.io_uring_future.reactor.allocator.destroy(pending_op);
                    
                    if (result >= 0) {
                        return Future.PollResult.ready;
                    } else {
                        return Future.PollResult{ .err = IoError.Unexpected };
                    }
                } else {
                    // Still pending
                    return Future.PollResult.pending;
                }
            } else {
                // Operation not found, assume ready
                return Future.PollResult.ready;
            }
        }
        
        pub fn cancel(context: *anyopaque) void {
            _ = context; // No-op for now
        }
        
        pub fn destroy(context: *anyopaque, allocator: std.mem.Allocator) void {
            const adapter: *FutureAdapterSelf = @ptrCast(@alignCast(context));
            allocator.destroy(adapter);
        }
        
        const future_vtable = Future.FutureVTable{
            .poll = adapterPoll,
            .cancel = cancel,
            .destroy = destroy,
        };
        
        pub fn toFuture(self: *FutureAdapterSelf) Future {
            return Future.init(&future_vtable, self);
        }
    };

    // VTable implementation
    const vtable = Io.IoVTable{
        .read = read,
        .write = write,
        .readv = readv,
        .writev = writev,
        .send_file = sendFile,
        .copy_file_range = copyFileRange,
        .accept = accept,
        .connect = connect,
        .close = close,
        .shutdown = shutdown,
        .get_mode = getMode,
        .supports_vectorized = supportsVectorized,
        .supports_zero_copy = supportsZeroCopy,
        .get_allocator = getAllocatorVtable,
    };
    
    // I/O operations integrated with io_uring
    fn read(context: *anyopaque, buffer: []u8) IoError!Future {
        const self: *Self = @ptrCast(@alignCast(context));
        
        // Submit read operation to io_uring
        const op = io_uring.Operation{
            .opcode = .read,
            .fd = 0, // stdin by default, caller can override
            .buffer = buffer,
            .offset = 0,
        };
        
        const io_uring_future = self.reactor.submitOperation(op) catch |err| switch (err) {
            io_uring.IoUringError.PermissionDenied => return IoError.AccessDenied,
            io_uring.IoUringError.InvalidOperation => return IoError.InvalidDescriptor,
            io_uring.IoUringError.SetupFailed => return IoError.SystemResources,
            io_uring.IoUringError.SubmissionFailed => return IoError.SystemResources,
            io_uring.IoUringError.CompletionFailed => return IoError.Interrupted,
            io_uring.IoUringError.QueueFull => return IoError.SystemResources,
            io_uring.IoUringError.Busy => return IoError.WouldBlock,
            else => |e| return e,
        };
        _ = self.metrics.operations_submitted.fetchAdd(1, .monotonic);
        
        // Create adapter
        const adapter = try self.allocator.create(FutureAdapter);
        adapter.* = FutureAdapter{
            .io_uring_future = io_uring_future,
            .allocator = self.allocator,
        };
        
        return adapter.toFuture();
    }
    
    fn write(context: *anyopaque, data: []const u8) IoError!Future {
        const self: *Self = @ptrCast(@alignCast(context));
        
        // Submit write operation to io_uring
        const op = io_uring.Operation{
            .opcode = .write,
            .fd = 1, // stdout by default, caller can override
            .data = data,
            .offset = 0,
        };
        
        const io_uring_future = self.reactor.submitOperation(op) catch |err| switch (err) {
            io_uring.IoUringError.PermissionDenied => return IoError.AccessDenied,
            io_uring.IoUringError.InvalidOperation => return IoError.InvalidDescriptor,
            io_uring.IoUringError.SetupFailed => return IoError.SystemResources,
            io_uring.IoUringError.SubmissionFailed => return IoError.SystemResources,
            io_uring.IoUringError.CompletionFailed => return IoError.Interrupted,
            io_uring.IoUringError.QueueFull => return IoError.SystemResources,
            io_uring.IoUringError.Busy => return IoError.WouldBlock,
            else => |e| return e,
        };
        _ = self.metrics.operations_submitted.fetchAdd(1, .monotonic);
        
        // Create adapter
        const adapter = try self.allocator.create(FutureAdapter);
        adapter.* = FutureAdapter{
            .io_uring_future = io_uring_future,
            .allocator = self.allocator,
        };
        
        return adapter.toFuture();
    }
    
    fn readv(context: *anyopaque, buffers: []IoBuffer) IoError!Future {
        const self: *Self = @ptrCast(@alignCast(context));
        _ = buffers;
        
        // Submit vectorized read operation to io_uring
        const op = io_uring.Operation{
            .opcode = .readv,
            .fd = 0,
            .offset = 0,
        };
        
        const io_uring_future = self.reactor.submitOperation(op) catch |err| switch (err) {
            io_uring.IoUringError.PermissionDenied => return IoError.AccessDenied,
            io_uring.IoUringError.InvalidOperation => return IoError.InvalidDescriptor,
            io_uring.IoUringError.SetupFailed => return IoError.SystemResources,
            io_uring.IoUringError.SubmissionFailed => return IoError.SystemResources,
            io_uring.IoUringError.CompletionFailed => return IoError.Interrupted,
            io_uring.IoUringError.QueueFull => return IoError.SystemResources,
            io_uring.IoUringError.Busy => return IoError.WouldBlock,
            else => |e| return e,
        };
        _ = self.metrics.operations_submitted.fetchAdd(1, .monotonic);
        
        const adapter = try self.allocator.create(FutureAdapter);
        adapter.* = FutureAdapter{
            .io_uring_future = io_uring_future,
            .allocator = self.allocator,
        };
        
        return adapter.toFuture();
    }
    
    fn writev(context: *anyopaque, buffers: []const []const u8) IoError!Future {
        const self: *Self = @ptrCast(@alignCast(context));
        _ = buffers;
        
        // Submit vectorized write operation to io_uring
        const op = io_uring.Operation{
            .opcode = .writev,
            .fd = 1,
            .offset = 0,
        };
        
        const io_uring_future = self.reactor.submitOperation(op) catch |err| switch (err) {
            io_uring.IoUringError.PermissionDenied => return IoError.AccessDenied,
            io_uring.IoUringError.InvalidOperation => return IoError.InvalidDescriptor,
            io_uring.IoUringError.SetupFailed => return IoError.SystemResources,
            io_uring.IoUringError.SubmissionFailed => return IoError.SystemResources,
            io_uring.IoUringError.CompletionFailed => return IoError.Interrupted,
            io_uring.IoUringError.QueueFull => return IoError.SystemResources,
            io_uring.IoUringError.Busy => return IoError.WouldBlock,
            else => |e| return e,
        };
        _ = self.metrics.operations_submitted.fetchAdd(1, .monotonic);
        
        const adapter = try self.allocator.create(FutureAdapter);
        adapter.* = FutureAdapter{
            .io_uring_future = io_uring_future,
            .allocator = self.allocator,
        };
        
        return adapter.toFuture();
    }
    
    fn sendFile(context: *anyopaque, out_fd: std.posix.fd_t, offset: u64, count: u64) IoError!Future {
        const self: *Self = @ptrCast(@alignCast(context));
        _ = count;
        
        const op = io_uring.Operation{
            .opcode = .sendfile,
            .fd = out_fd,
            .offset = offset,
        };
        
        const io_uring_future = self.reactor.submitOperation(op) catch |err| switch (err) {
            io_uring.IoUringError.PermissionDenied => return IoError.AccessDenied,
            io_uring.IoUringError.InvalidOperation => return IoError.InvalidDescriptor,
            io_uring.IoUringError.SetupFailed => return IoError.SystemResources,
            io_uring.IoUringError.SubmissionFailed => return IoError.SystemResources,
            io_uring.IoUringError.CompletionFailed => return IoError.Interrupted,
            io_uring.IoUringError.QueueFull => return IoError.SystemResources,
            io_uring.IoUringError.Busy => return IoError.WouldBlock,
            else => |e| return e,
        };
        _ = self.metrics.operations_submitted.fetchAdd(1, .monotonic);
        
        const adapter = try self.allocator.create(FutureAdapter);
        adapter.* = FutureAdapter{
            .io_uring_future = io_uring_future,
            .allocator = self.allocator,
        };
        
        return adapter.toFuture();
    }
    
    fn copyFileRange(context: *anyopaque, in_fd: std.posix.fd_t, out_fd: std.posix.fd_t, count: u64) IoError!Future {
        const self: *Self = @ptrCast(@alignCast(context));
        _ = in_fd;
        _ = count;
        
        const op = io_uring.Operation{
            .opcode = .copy_file_range,
            .fd = out_fd,
            .offset = 0,
        };
        
        const io_uring_future = self.reactor.submitOperation(op) catch |err| switch (err) {
            io_uring.IoUringError.PermissionDenied => return IoError.AccessDenied,
            io_uring.IoUringError.InvalidOperation => return IoError.InvalidDescriptor,
            io_uring.IoUringError.SetupFailed => return IoError.SystemResources,
            io_uring.IoUringError.SubmissionFailed => return IoError.SystemResources,
            io_uring.IoUringError.CompletionFailed => return IoError.Interrupted,
            io_uring.IoUringError.QueueFull => return IoError.SystemResources,
            io_uring.IoUringError.Busy => return IoError.WouldBlock,
            else => |e| return e,
        };
        _ = self.metrics.operations_submitted.fetchAdd(1, .monotonic);
        
        const adapter = try self.allocator.create(FutureAdapter);
        adapter.* = FutureAdapter{
            .io_uring_future = io_uring_future,
            .allocator = self.allocator,
        };
        
        return adapter.toFuture();
    }
    
    fn accept(context: *anyopaque, sockfd: std.posix.fd_t) IoError!Future {
        const self: *Self = @ptrCast(@alignCast(context));
        
        const op = io_uring.Operation{
            .opcode = .accept,
            .fd = sockfd,
            .offset = 0,
        };
        
        const io_uring_future = self.reactor.submitOperation(op) catch |err| switch (err) {
            io_uring.IoUringError.PermissionDenied => return IoError.AccessDenied,
            io_uring.IoUringError.InvalidOperation => return IoError.InvalidDescriptor,
            io_uring.IoUringError.SetupFailed => return IoError.SystemResources,
            io_uring.IoUringError.SubmissionFailed => return IoError.SystemResources,
            io_uring.IoUringError.CompletionFailed => return IoError.Interrupted,
            io_uring.IoUringError.QueueFull => return IoError.SystemResources,
            io_uring.IoUringError.Busy => return IoError.WouldBlock,
            else => |e| return e,
        };
        _ = self.metrics.operations_submitted.fetchAdd(1, .monotonic);
        
        const adapter = try self.allocator.create(FutureAdapter);
        adapter.* = FutureAdapter{
            .io_uring_future = io_uring_future,
            .allocator = self.allocator,
        };
        
        return adapter.toFuture();
    }
    
    fn connect(context: *anyopaque, sockfd: std.posix.fd_t, addr: *const std.posix.sockaddr) IoError!Future {
        const self: *Self = @ptrCast(@alignCast(context));
        _ = addr;
        
        const op = io_uring.Operation{
            .opcode = .connect,
            .fd = sockfd,
            .offset = 0,
        };
        
        const io_uring_future = self.reactor.submitOperation(op) catch |err| switch (err) {
            io_uring.IoUringError.PermissionDenied => return IoError.AccessDenied,
            io_uring.IoUringError.InvalidOperation => return IoError.InvalidDescriptor,
            io_uring.IoUringError.SetupFailed => return IoError.SystemResources,
            io_uring.IoUringError.SubmissionFailed => return IoError.SystemResources,
            io_uring.IoUringError.CompletionFailed => return IoError.Interrupted,
            io_uring.IoUringError.QueueFull => return IoError.SystemResources,
            io_uring.IoUringError.Busy => return IoError.WouldBlock,
            else => |e| return e,
        };
        _ = self.metrics.operations_submitted.fetchAdd(1, .monotonic);
        
        const adapter = try self.allocator.create(FutureAdapter);
        adapter.* = FutureAdapter{
            .io_uring_future = io_uring_future,
            .allocator = self.allocator,
        };
        
        return adapter.toFuture();
    }
    
    fn close(context: *anyopaque, fd: std.posix.fd_t) IoError!Future {
        const self: *Self = @ptrCast(@alignCast(context));
        
        const op = io_uring.Operation{
            .opcode = .close,
            .fd = fd,
            .offset = 0,
        };
        
        const io_uring_future = self.reactor.submitOperation(op) catch |err| switch (err) {
            io_uring.IoUringError.PermissionDenied => return IoError.AccessDenied,
            io_uring.IoUringError.InvalidOperation => return IoError.InvalidDescriptor,
            io_uring.IoUringError.SetupFailed => return IoError.SystemResources,
            io_uring.IoUringError.SubmissionFailed => return IoError.SystemResources,
            io_uring.IoUringError.CompletionFailed => return IoError.Interrupted,
            io_uring.IoUringError.QueueFull => return IoError.SystemResources,
            io_uring.IoUringError.Busy => return IoError.WouldBlock,
            else => |e| return e,
        };
        _ = self.metrics.operations_submitted.fetchAdd(1, .monotonic);
        
        const adapter = try self.allocator.create(FutureAdapter);
        adapter.* = FutureAdapter{
            .io_uring_future = io_uring_future,
            .allocator = self.allocator,
        };
        
        return adapter.toFuture();
    }
    
    fn shutdown(context: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(context));
        self.scheduler.deinit();
    }
    
    fn getMode(_: *anyopaque) IoMode {
        return .evented;
    }
    
    fn supportsVectorized(_: *anyopaque) bool {
        return true;
    }
    
    fn supportsZeroCopy(_: *anyopaque) bool {
        return true;
    }
    
    fn getAllocatorVtable(context: *anyopaque) std.mem.Allocator {
        const self: *Self = @ptrCast(@alignCast(context));
        return self.allocator;
    }
};

/// Create green threads implementation
pub fn createGreenThreadsIo(allocator: std.mem.Allocator, queue_depth: u32) !GreenThreadsIo {
    return GreenThreadsIo.init(allocator, queue_depth);
}

// Tests
test "green threads availability" {
    if (builtin.os.tag != .linux) return;
    
    const caps = platform_detect.detectSystemCapabilities();
    std.debug.print("Green threads (io_uring) support: {}\n", .{caps.has_io_uring});
}

test "green threads creation" {
    if (builtin.os.tag != .linux) return;
    
    const allocator = std.testing.allocator;
    
    var green_threads = createGreenThreadsIo(allocator, 32) catch |err| switch (err) {
        IoError.NotSupported => {
            std.debug.print("Green threads not supported on this system\n", .{});
            return;
        },
        else => return err,
    };
    defer green_threads.deinit();
    
    const io = green_threads.io();
    std.debug.print("Green threads created successfully\n", .{});
    std.debug.print("Mode: {}\n", .{io.getMode()});
    std.debug.print("Supports vectorized: {}\n", .{io.supportsVectorized()});
    std.debug.print("Supports zero-copy: {}\n", .{io.supportsZeroCopy()});
}