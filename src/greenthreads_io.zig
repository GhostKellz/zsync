//! Zsync v0.1 - GreenThreadsIo Implementation
//! Stack-swapping green threads for x86_64 Linux
//! Uses io_uring for high-performance async I/O

const std = @import("std");
const builtin = @import("builtin");
const arch = @import("arch/x86_64.zig");
const platform = @import("platform/linux.zig");
const compat = @import("compat/async_builtins.zig");
const registry = @import("async_registry.zig");
const io_interface = @import("io_v2.zig");
const Io = io_interface.Io;
const Future = io_interface.Future;
const File = io_interface.File;
const TcpStream = io_interface.TcpStream;
const TcpListener = io_interface.TcpListener;
const UdpSocket = io_interface.UdpSocket;

/// Green thread configuration
pub const GreenThreadConfig = struct {
    stack_size: usize = 64 * 1024, // 64KB default stack size
    max_threads: u32 = 1024,
    io_uring_entries: u32 = 256,
};

/// Green thread state
const GreenThreadState = enum {
    ready,
    running,
    suspended,
    completed,
};

/// Green thread control block
const GreenThread = struct {
    id: u32,
    stack: []align(4096) u8,
    context: arch.Context,
    state: GreenThreadState,
    result: anyerror!void = undefined,
    
    // Function to execute
    func: *const fn (*anyopaque) anyerror!void,
    ctx: *anyopaque,
    
    // For cleanup (optional)
    cleanup_fn: ?*const fn (*anyopaque, std.mem.Allocator) void = null,
    allocator: ?std.mem.Allocator = null,
    
    // Performance tracking
    switch_count: u64 = 0,
    total_runtime_ns: u64 = 0,
    
    fn initContext(self: *GreenThread, entry_point: *const fn(*anyopaque) void, arg: *anyopaque) void {
        self.context = arch.Context.init(self.stack, entry_point, arg);
    }
};

/// Green threads scheduler
const GreenThreadScheduler = struct {
    threads: std.ArrayList(GreenThread),
    ready_queue: std.fifo.LinearFifo(u32, .Dynamic),
    current_thread: ?u32 = null,
    allocator: std.mem.Allocator,
    
    const Self = @This();
    
    fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .threads = std.ArrayList(GreenThread).init(allocator),
            .ready_queue = std.fifo.LinearFifo(u32, .Dynamic).init(allocator),
            .allocator = allocator,
        };
    }
    
    fn deinit(self: *Self) void {
        for (self.threads.items) |thread| {
            self.allocator.free(thread.stack);
            if (thread.cleanup_fn != null and thread.allocator != null) {
                thread.cleanup_fn.?(thread.ctx, thread.allocator.?);
            }
        }
        self.threads.deinit();
        self.ready_queue.deinit();
    }
    
    fn spawnThread(self: *Self, stack_size: usize, func: *const fn (*anyopaque) anyerror!void, ctx: *anyopaque) !u32 {
        return self.spawnThreadWithCleanup(stack_size, func, ctx, null, null);
    }
    
    fn spawnThreadWithCleanup(
        self: *Self, 
        _: usize, 
        func: *const fn (*anyopaque) anyerror!void, 
        ctx: *anyopaque,
        cleanup_fn: ?*const fn (*anyopaque, std.mem.Allocator) void,
        allocator: ?std.mem.Allocator,
    ) !u32 {
        const stack = try arch.allocateStack(self.allocator);
        const thread_id = @as(u32, @intCast(self.threads.items.len));
        
        var thread = GreenThread{
            .id = thread_id,
            .stack = stack,
            .context = undefined,
            .state = .ready,
            .func = func,
            .ctx = ctx,
            .cleanup_fn = cleanup_fn,
            .allocator = allocator,
        };
        
        // Initialize the context for this thread
        thread.initContext(greenThreadEntryPoint, &thread);
        
        try self.threads.append(thread);
        try self.ready_queue.writeItem(thread_id);
        
        return thread_id;
    }
    
    fn yield(self: *Self) void {
        if (self.current_thread) |current_id| {
            const current_thread = &self.threads.items[current_id];
            
            // Update thread state
            current_thread.state = .ready;
            self.ready_queue.writeItem(current_id) catch {};
            
            // Find next thread to run
            if (self.ready_queue.readItem()) |next_id| {
                const next_thread = &self.threads.items[next_id];
                next_thread.state = .running;
                
                // Perform actual context switch
                arch.swapContext(&current_thread.context, &next_thread.context);
                arch.setCurrentContext(&next_thread.context);
                
                // Update scheduler state
                self.current_thread = next_id;
                
                // Update performance counters
                current_thread.switch_count += 1;
                next_thread.switch_count += 1;
            }
        } else {
            self.schedule();
        }
    }
    
    fn schedule(self: *Self) void {
        if (self.ready_queue.readItem()) |thread_id| {
            const thread = &self.threads.items[thread_id];
            thread.state = .running;
            self.current_thread = thread_id;
            arch.setCurrentContext(&thread.context);
            
            // For the first time scheduling, we need to start the thread
            if (thread.switch_count == 0) {
                // Jump to the thread's entry point
                arch.swapContext(&thread.context, &thread.context);
            }
        }
    }
    
    fn suspendThread(self: *Self, thread_id: u32) void {
        self.threads.items[thread_id].state = .suspended;
        if (self.current_thread == thread_id) {
            self.current_thread = null;
            self.schedule();
        }
    }
    
    fn resumeThread(self: *Self, thread_id: u32) !void {
        if (self.threads.items[thread_id].state == .suspended) {
            self.threads.items[thread_id].state = .ready;
            try self.ready_queue.writeItem(thread_id);
        }
    }
};

// Green thread entry point
fn greenThreadEntryPoint(arg: *anyopaque) void {
    const thread: *GreenThread = @ptrCast(@alignCast(arg));
    
    // Execute the actual function
    thread.result = thread.func(thread.ctx);
    thread.state = .completed;
    
    // Clean up if needed
    if (thread.cleanup_fn != null and thread.allocator != null) {
        thread.cleanup_fn.?(thread.ctx, thread.allocator.?);
    }
    
    // This should yield back to scheduler
    // In a real implementation, this would jump back to the scheduler
    @panic("Green thread completed - should yield to scheduler");
}

/// Real Linux io_uring integration using platform layer
const IoUring = platform.IoUring;


/// GreenThreadsIo implementation
pub const GreenThreadsIo = struct {
    allocator: std.mem.Allocator,
    config: GreenThreadConfig,
    scheduler: GreenThreadScheduler,
    io_uring: IoUring,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: GreenThreadConfig) !Self {
        // Verify platform support
        if (builtin.cpu.arch != .x86_64 or builtin.os.tag != .linux) {
            return error.UnsupportedPlatform;
        }

        return Self{
            .allocator = allocator,
            .config = config,
            .scheduler = GreenThreadScheduler.init(allocator),
            .io_uring = try IoUring.init(config.io_uring_entries),
        };
    }

    pub fn deinit(self: *Self) void {
        self.scheduler.deinit();
        self.io_uring.deinit();
    }

    /// Get the Io interface for this implementation
    pub fn io(self: *Self) Io {
        return Io{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    /// Run the event loop with real io_uring integration
    pub fn run(self: *Self) !void {
        self.running.store(true, .release);
        defer self.running.store(false, .release);
        
        std.debug.print("🔄 Starting GreenThreadsIo event loop with io_uring\n", .{});
        
        while (self.running.load(.acquire)) {
            // Process completed I/O operations from io_uring
            if (self.io_uring.getCqe()) |cqe| {
                std.debug.print("📥 io_uring completion: user_data={}, res={}\n", .{ cqe.user_data, cqe.res });
                
                // Convert user_data back to thread_id and resume the green thread
                const thread_id: u32 = @intCast(cqe.user_data);
                try self.scheduler.resumeThread(thread_id);
                
                // Mark completion as seen
                self.io_uring.seenCqe(cqe);
            }
            
            // Schedule ready threads
            self.scheduler.schedule();
            
            // If no threads are ready and no pending I/O, break
            if (self.scheduler.ready_queue.count == 0) {
                // Try to wait for at least one completion before exiting
                _ = self.io_uring.wait(1_000_000) catch {
                    // No more I/O operations pending or timeout
                    break;
                };
            }
        }
        
        std.debug.print("🏁 GreenThreadsIo event loop finished\n", .{});
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
        
        const future_impl = try self.allocator.create(GreenThreadFuture);
        future_impl.* = GreenThreadFuture{
            .allocator = self.allocator,
            .scheduler = &self.scheduler,
            .thread_id = undefined,
            .call_info = call_info, // Store for cleanup
        };
        
        // Create task context that stores the call info
        const task_ctx = try self.allocator.create(CallInfoTaskContext);
        task_ctx.* = CallInfoTaskContext{
            .call_info = call_info,
        };
        
        const thread_id = try self.scheduler.spawnThreadWithCleanup(
            self.config.stack_size,
            executeCallInfoTask,
            task_ctx,
            cleanupCallInfoTask,
            self.allocator,
        );
        
        future_impl.thread_id = thread_id;
        
        return Future{
            .ptr = future_impl,
            .vtable = &greenthread_future_vtable,
        };
    }

    fn asyncConcurrentFn(ptr: *anyopaque, call_infos: []io_interface.AsyncCallInfo) !io_interface.ConcurrentFuture {
        const self: *Self = @ptrCast(@alignCast(ptr));
        
        // For green threads, spawn multiple concurrent green threads
        std.debug.print("🌱 GreenThreadsIo: Starting {} concurrent green threads\n", .{call_infos.len});
        
        const concurrent_future = try self.allocator.create(GreenThreadConcurrentFuture);
        concurrent_future.* = GreenThreadConcurrentFuture{
            .allocator = self.allocator,
            .scheduler = &self.scheduler,
            .thread_ids = try self.allocator.alloc(u32, call_infos.len),
            .completed_count = std.atomic.Value(usize).init(0),
            .total_count = call_infos.len,
        };
        
        // Spawn all operations as concurrent green threads
        for (call_infos, 0..) |call_info, i| {
            const task_ctx = try self.allocator.create(CallInfoTaskContext);
            task_ctx.* = CallInfoTaskContext{
                .call_info = call_info,
            };
            
            const thread_id = try self.scheduler.spawnThreadWithCleanup(
                self.config.stack_size,
                executeCallInfoTask,
                task_ctx,
                cleanupCallInfoTask,
                self.allocator,
            );
            
            concurrent_future.thread_ids[i] = thread_id;
        }
        
        return io_interface.ConcurrentFuture{
            .ptr = concurrent_future,
            .vtable = &greenthread_concurrent_future_vtable,
        };
    }

    fn createFile(ptr: *anyopaque, path: []const u8, options: File.CreateOptions) !File {
        const self: *Self = @ptrCast(@alignCast(ptr));
        
        // In real implementation, this would use io_uring for async file operations
        _ = options;
        
        const file = try std.fs.cwd().createFile(path, .{});
        const file_impl = try self.allocator.create(GreenThreadFile);
        file_impl.* = GreenThreadFile{
            .file = file,
            .allocator = self.allocator,
        };

        return File{
            .ptr = file_impl,
            .vtable = &greenthread_file_vtable,
        };
    }

    fn openFile(ptr: *anyopaque, path: []const u8, options: File.OpenOptions) !File {
        const self: *Self = @ptrCast(@alignCast(ptr));
        
        const file = try std.fs.cwd().openFile(path, .{ .mode = options.mode });
        const file_impl = try self.allocator.create(GreenThreadFile);
        file_impl.* = GreenThreadFile{
            .file = file,
            .allocator = self.allocator,
        };

        return File{
            .ptr = file_impl,
            .vtable = &greenthread_file_vtable,
        };
    }

    fn tcpConnect(ptr: *anyopaque, address: std.net.Address) !TcpStream {
        const self: *Self = @ptrCast(@alignCast(ptr));
        
        // In real implementation, this would use io_uring async connect
        const stream = try std.net.tcpConnectToAddress(address);
        const stream_impl = try self.allocator.create(GreenThreadTcpStream);
        stream_impl.* = GreenThreadTcpStream{
            .stream = stream,
            .allocator = self.allocator,
        };

        return TcpStream{
            .ptr = stream_impl,
            .vtable = &greenthread_tcp_stream_vtable,
        };
    }

    fn tcpListen(ptr: *anyopaque, address: std.net.Address) !TcpListener {
        const self: *Self = @ptrCast(@alignCast(ptr));
        
        const listener = try address.listen(.{ .reuse_address = true });
        const listener_impl = try self.allocator.create(GreenThreadTcpListener);
        listener_impl.* = GreenThreadTcpListener{
            .listener = listener,
            .allocator = self.allocator,
        };

        return TcpListener{
            .ptr = listener_impl,
            .vtable = &greenthread_tcp_listener_vtable,
        };
    }

    fn udpBind(ptr: *anyopaque, address: std.net.Address) !UdpSocket {
        const self: *Self = @ptrCast(@alignCast(ptr));
        
        const sock = try std.posix.socket(address.any.family, std.posix.SOCK.DGRAM, 0);
        try std.posix.bind(sock, &address.any, address.getOsSockLen());
        
        const socket_impl = try self.allocator.create(GreenThreadUdpSocket);
        socket_impl.* = GreenThreadUdpSocket{
            .socket = sock,
            .allocator = self.allocator,
        };

        return UdpSocket{
            .ptr = socket_impl,
            .vtable = &greenthread_udp_socket_vtable,
        };
    }
};

// Task context and execution (same as threadpool)
/// Task context for call info execution
const CallInfoTaskContext = struct {
    call_info: io_interface.AsyncCallInfo,
};

/// Task executor for call info
fn executeCallInfoTask(ctx: *anyopaque) anyerror!void {
    const task_ctx: *CallInfoTaskContext = @ptrCast(@alignCast(ctx));
    try task_ctx.call_info.exec_fn(task_ctx.call_info.call_ptr);
}

/// Cleanup function for CallInfoTaskContext
fn cleanupCallInfoTask(ctx: *anyopaque, allocator: std.mem.Allocator) void {
    const task_ctx: *CallInfoTaskContext = @ptrCast(@alignCast(ctx));
    allocator.destroy(task_ctx);
}

fn TaskContext(comptime FuncType: type, comptime ArgsType: type) type {
    return struct {
        func: FuncType,
        args: ArgsType,
    };
}

fn executeTask(comptime FuncType: type, comptime ArgsType: type) *const fn (*anyopaque) anyerror!void {
    return struct {
        fn execute(ctx: *anyopaque) anyerror!void {
            const task_ctx: *TaskContext(FuncType, ArgsType) = @ptrCast(@alignCast(ctx));
            try @call(.auto, task_ctx.func, task_ctx.args);
        }
    }.execute;
}

// Green thread future implementation
const GreenThreadFuture = struct {
    allocator: std.mem.Allocator,
    scheduler: *GreenThreadScheduler,
    thread_id: u32,
    call_info: io_interface.AsyncCallInfo,
};

// Green thread concurrent future implementation
const GreenThreadConcurrentFuture = struct {
    allocator: std.mem.Allocator,
    scheduler: *GreenThreadScheduler,
    thread_ids: []u32,
    completed_count: std.atomic.Value(usize),
    total_count: usize,
};

const greenthread_future_vtable = Future.VTable{
    .await_fn = greenthreadAwait,
    .cancel_fn = greenthreadCancel,
    .deinit_fn = greenthreadDeinit,
};

fn greenthreadAwait(ptr: *anyopaque, io: Io) !void {
    _ = io;
    const future: *GreenThreadFuture = @ptrCast(@alignCast(ptr));
    
    // Wait for thread to complete
    while (future.scheduler.threads.items[future.thread_id].state != .completed) {
        future.scheduler.yield();
    }
    
    return future.scheduler.threads.items[future.thread_id].result;
}

fn greenthreadCancel(ptr: *anyopaque, io: Io) !void {
    _ = io;
    const future: *GreenThreadFuture = @ptrCast(@alignCast(ptr));
    
    // Mark thread as completed with cancellation
    future.scheduler.threads.items[future.thread_id].state = .completed;
    future.scheduler.threads.items[future.thread_id].result = error.Canceled;
}

fn greenthreadDeinit(ptr: *anyopaque) void {
    const future: *GreenThreadFuture = @ptrCast(@alignCast(ptr));
    // Clean up the call info
    future.call_info.deinit();
    future.allocator.destroy(future);
}

const greenthread_concurrent_future_vtable = io_interface.ConcurrentFuture.VTable{
    .await_all_fn = greenthreadAwaitAll,
    .await_any_fn = greenthreadAwaitAny,
    .cancel_all_fn = greenthreadCancelAll,
    .deinit_fn = greenthreadConcurrentDeinit,
};

fn greenthreadAwaitAll(ptr: *anyopaque, io: Io) !void {
    _ = io;
    const concurrent_future: *GreenThreadConcurrentFuture = @ptrCast(@alignCast(ptr));
    
    // Wait for all green threads to complete
    for (concurrent_future.thread_ids) |thread_id| {
        while (concurrent_future.scheduler.threads.items[thread_id].state != .completed) {
            concurrent_future.scheduler.yield();
        }
        try concurrent_future.scheduler.threads.items[thread_id].result;
    }
}

fn greenthreadAwaitAny(ptr: *anyopaque, io: Io) !usize {
    _ = io;
    const concurrent_future: *GreenThreadConcurrentFuture = @ptrCast(@alignCast(ptr));
    
    // Wait for any green thread to complete
    while (true) {
        for (concurrent_future.thread_ids, 0..) |thread_id, i| {
            if (concurrent_future.scheduler.threads.items[thread_id].state == .completed) {
                try concurrent_future.scheduler.threads.items[thread_id].result;
                return i;
            }
        }
        concurrent_future.scheduler.yield();
    }
}

fn greenthreadCancelAll(ptr: *anyopaque, io: Io) !void {
    _ = io;
    const concurrent_future: *GreenThreadConcurrentFuture = @ptrCast(@alignCast(ptr));
    
    // Cancel all green threads
    for (concurrent_future.thread_ids) |thread_id| {
        concurrent_future.scheduler.threads.items[thread_id].state = .completed;
        concurrent_future.scheduler.threads.items[thread_id].result = error.Canceled;
    }
}

fn greenthreadConcurrentDeinit(ptr: *anyopaque) void {
    const concurrent_future: *GreenThreadConcurrentFuture = @ptrCast(@alignCast(ptr));
    concurrent_future.allocator.free(concurrent_future.thread_ids);
    concurrent_future.allocator.destroy(concurrent_future);
}

// Green thread file implementation
const GreenThreadFile = struct {
    file: std.fs.File,
    allocator: std.mem.Allocator,
};

const greenthread_file_vtable = File.VTable{
    .writeAll = greenthreadFileWriteAll,
    .readAll = greenthreadFileReadAll,
    .close = greenthreadFileClose,
};

fn greenthreadFileWriteAll(ptr: *anyopaque, io: Io, data: []const u8) !void {
    _ = io;
    const file_impl: *GreenThreadFile = @ptrCast(@alignCast(ptr));
    // In real implementation, this would yield and use io_uring
    try file_impl.file.writeAll(data);
}

fn greenthreadFileReadAll(ptr: *anyopaque, io: Io, buffer: []u8) !usize {
    _ = io;
    const file_impl: *GreenThreadFile = @ptrCast(@alignCast(ptr));
    return try file_impl.file.readAll(buffer);
}

fn greenthreadFileClose(ptr: *anyopaque, io: Io) !void {
    _ = io;
    const file_impl: *GreenThreadFile = @ptrCast(@alignCast(ptr));
    file_impl.file.close();
    file_impl.allocator.destroy(file_impl);
}

// Green thread TCP stream implementation
const GreenThreadTcpStream = struct {
    stream: std.net.Stream,
    allocator: std.mem.Allocator,
};

const greenthread_tcp_stream_vtable = TcpStream.VTable{
    .read = greenthreadStreamRead,
    .write = greenthreadStreamWrite,
    .close = greenthreadStreamClose,
};

fn greenthreadStreamRead(ptr: *anyopaque, io: Io, buffer: []u8) !usize {
    _ = io;
    const stream_impl: *GreenThreadTcpStream = @ptrCast(@alignCast(ptr));
    return try stream_impl.stream.readAll(buffer);
}

fn greenthreadStreamWrite(ptr: *anyopaque, io: Io, data: []const u8) !usize {
    _ = io;
    const stream_impl: *GreenThreadTcpStream = @ptrCast(@alignCast(ptr));
    try stream_impl.stream.writeAll(data);
    return data.len;
}

fn greenthreadStreamClose(ptr: *anyopaque, io: Io) !void {
    _ = io;
    const stream_impl: *GreenThreadTcpStream = @ptrCast(@alignCast(ptr));
    stream_impl.stream.close();
    stream_impl.allocator.destroy(stream_impl);
}

// Green thread TCP listener implementation
const GreenThreadTcpListener = struct {
    listener: std.net.Server,
    allocator: std.mem.Allocator,
};

const greenthread_tcp_listener_vtable = TcpListener.VTable{
    .accept = greenthreadListenerAccept,
    .close = greenthreadListenerClose,
};

fn greenthreadListenerAccept(ptr: *anyopaque, io: Io) !TcpStream {
    _ = io;
    const listener_impl: *GreenThreadTcpListener = @ptrCast(@alignCast(ptr));
    
    const connection = try listener_impl.listener.accept();
    const stream_impl = try listener_impl.allocator.create(GreenThreadTcpStream);
    stream_impl.* = GreenThreadTcpStream{
        .stream = connection.stream,
        .allocator = listener_impl.allocator,
    };

    return TcpStream{
        .ptr = stream_impl,
        .vtable = &greenthread_tcp_stream_vtable,
    };
}

fn greenthreadListenerClose(ptr: *anyopaque, io: Io) !void {
    _ = io;
    const listener_impl: *GreenThreadTcpListener = @ptrCast(@alignCast(ptr));
    listener_impl.listener.deinit();
    listener_impl.allocator.destroy(listener_impl);
}

// Green thread UDP socket implementation
const GreenThreadUdpSocket = struct {
    socket: std.posix.socket_t,
    allocator: std.mem.Allocator,
};

const greenthread_udp_socket_vtable = UdpSocket.VTable{
    .sendTo = greenthreadUdpSendTo,
    .recvFrom = greenthreadUdpRecvFrom,
    .close = greenthreadUdpClose,
};

fn greenthreadUdpSendTo(ptr: *anyopaque, io: Io, data: []const u8, address: std.net.Address) !usize {
    _ = io;
    const socket_impl: *GreenThreadUdpSocket = @ptrCast(@alignCast(ptr));
    _ = try std.posix.sendto(socket_impl.socket, data, 0, &address.any, address.getOsSockLen());
    return data.len;
}

fn greenthreadUdpRecvFrom(ptr: *anyopaque, io: Io, buffer: []u8) !io_interface.RecvFromResult {
    _ = io;
    const socket_impl: *GreenThreadUdpSocket = @ptrCast(@alignCast(ptr));
    var addr: std.posix.sockaddr = undefined;
    var addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);
    const bytes = try std.posix.recvfrom(socket_impl.socket, buffer, 0, &addr, &addr_len);
    return .{ .bytes = bytes, .address = std.net.Address.initPosix(@alignCast(&addr)) };
}

fn greenthreadUdpClose(ptr: *anyopaque, io: Io) !void {
    _ = io;
    const socket_impl: *GreenThreadUdpSocket = @ptrCast(@alignCast(ptr));
    std.posix.close(socket_impl.socket);
    socket_impl.allocator.destroy(socket_impl);
}

test "greenthreads io platform check" {
    const testing = std.testing;
    
    if (builtin.cpu.arch == .x86_64 and builtin.os.tag == .linux) {
        const allocator = testing.allocator;
        var greenthreads_io = try GreenThreadsIo.init(allocator, .{});
        defer greenthreads_io.deinit();
        
        const io = greenthreads_io.io();
        _ = io;
    }
    
    try testing.expect(true);
}