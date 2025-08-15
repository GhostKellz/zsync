//! Zsync v0.1 - StacklessIo Implementation
//! Uses stackless coroutines from proposal #23446
//! Compatible with WASM and other platforms without stack swapping

const std = @import("std");
const builtin = @import("builtin");
const io_interface = @import("io_interface.zig");
const blocking_io = @import("blocking_io.zig");
const Io = io_interface.Io;
const Future = io_interface.Future;
const IoError = io_interface.IoError;
const IoBuffer = io_interface.IoBuffer;

/// Performance metrics for stackless execution
pub const StacklessMetrics = struct {
    coroutines_spawned: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    coroutines_completed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    total_suspend_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    total_resume_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    tail_calls_optimized: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    frame_memory_allocated: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    total_execution_time_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    
    const Self = @This();
    
    pub fn reset(self: *Self) void {
        self.coroutines_spawned.store(0, .release);
        self.coroutines_completed.store(0, .release);
        self.total_suspend_count.store(0, .release);
        self.total_resume_count.store(0, .release);
        self.tail_calls_optimized.store(0, .release);
        self.frame_memory_allocated.store(0, .release);
        self.total_execution_time_ns.store(0, .release);
    }
    
    pub fn report(self: *Self) StacklessMetricsSnapshot {
        return StacklessMetricsSnapshot{
            .coroutines_spawned = self.coroutines_spawned.load(.acquire),
            .coroutines_completed = self.coroutines_completed.load(.acquire),
            .total_suspend_count = self.total_suspend_count.load(.acquire),
            .total_resume_count = self.total_resume_count.load(.acquire),
            .tail_calls_optimized = self.tail_calls_optimized.load(.acquire),
            .frame_memory_allocated = self.frame_memory_allocated.load(.acquire),
            .total_execution_time_ns = self.total_execution_time_ns.load(.acquire),
        };
    }
};

pub const StacklessMetricsSnapshot = struct {
    coroutines_spawned: u64,
    coroutines_completed: u64,
    total_suspend_count: u64,
    total_resume_count: u64,
    tail_calls_optimized: u64,
    frame_memory_allocated: u64,
    total_execution_time_ns: u64,
    
    pub fn averageExecutionTimeNs(self: StacklessMetricsSnapshot) f64 {
        if (self.coroutines_completed == 0) return 0.0;
        return @as(f64, @floatFromInt(self.total_execution_time_ns)) / @as(f64, @floatFromInt(self.coroutines_completed));
    }
    
    pub fn suspensionsPerCoroutine(self: StacklessMetricsSnapshot) f64 {
        if (self.coroutines_completed == 0) return 0.0;
        return @as(f64, @floatFromInt(self.total_suspend_count)) / @as(f64, @floatFromInt(self.coroutines_completed));
    }
    
    pub fn resumesPerCoroutine(self: StacklessMetricsSnapshot) f64 {
        if (self.coroutines_completed == 0) return 0.0;
        return @as(f64, @floatFromInt(self.total_resume_count)) / @as(f64, @floatFromInt(self.coroutines_completed));
    }
};

/// Performance profiler for stackless execution
pub const StacklessProfiler = struct {
    enabled: bool,
    metrics: StacklessMetrics,
    start_time: std.time.Instant,
    
    const Self = @This();
    
    pub fn init(enabled: bool) Self {
        return Self{
            .enabled = enabled,
            .metrics = StacklessMetrics{},
            .start_time = std.time.Instant.now() catch unreachable,
        };
    }
    
    pub fn recordCoroutineSpawn(self: *Self, frame_size: usize) void {
        if (!self.enabled) return;
        _ = self.metrics.coroutines_spawned.fetchAdd(1, .acq_rel);
        _ = self.metrics.frame_memory_allocated.fetchAdd(frame_size, .acq_rel);
    }
    
    pub fn recordCoroutineCompletion(self: *Self, execution_time_ns: u64) void {
        if (!self.enabled) return;
        _ = self.metrics.coroutines_completed.fetchAdd(1, .acq_rel);
        _ = self.metrics.total_execution_time_ns.fetchAdd(execution_time_ns, .acq_rel);
    }
    
    pub fn recordSuspend(self: *Self) void {
        if (!self.enabled) return;
        _ = self.metrics.total_suspend_count.fetchAdd(1, .acq_rel);
    }
    
    pub fn recordResume(self: *Self) void {
        if (!self.enabled) return;
        _ = self.metrics.total_resume_count.fetchAdd(1, .acq_rel);
    }
    
    pub fn recordTailCallOptimization(self: *Self) void {
        if (!self.enabled) return;
        _ = self.metrics.tail_calls_optimized.fetchAdd(1, .acq_rel);
    }
    
    pub fn getMetrics(self: *Self) StacklessMetricsSnapshot {
        return self.metrics.report();
    }
};

/// Configuration for stackless coroutines
pub const StacklessConfig = struct {
    max_coroutines: u32 = 512,
    default_frame_size: usize = 4096,
    enable_profiling: bool = false,
};

/// Function pointer type information for #23367 support
const FuncPtrInfo = struct {
    func_ptr: *anyopaque,
    // param_types: []const type,  // TODO: Enable when Zig supports comptime in HashMap
    // return_type: type,          // TODO: Enable when Zig supports comptime in HashMap
    is_async: bool,
    
    const Self = @This();
    
    /// Create function pointer info from a restricted function pointer
    fn fromFuncPtr(comptime func_ptr: anytype) Self {
        const func_type = @TypeOf(func_ptr);
        const func_info = @typeInfo(func_type);
        
        return Self{
            .func_ptr = @ptrCast(@constCast(func_ptr)),
            // .param_types = func_info.Pointer.child.Fn.params,
            // .return_type = func_info.Pointer.child.Fn.return_type orelse void,
            .is_async = hasAsyncCallSites(func_info.Pointer.child),
        };
    }
    
    fn hasAsyncCallSites(comptime func_type: type) bool {
        // In real implementation, this would analyze the function for suspension points
        _ = func_type;
        return true; // Mock: assume all function pointers could be async
    }
};

/// Registry for restricted function pointers (#23367)
const FuncPtrRegistry = struct {
    registered_funcs: std.AutoHashMap(usize, FuncPtrInfo),
    allocator: std.mem.Allocator,
    
    const Self = @This();
    
    fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .registered_funcs = std.AutoHashMap(usize, FuncPtrInfo).init(allocator),
            .allocator = allocator,
        };
    }
    
    fn deinit(self: *Self) void {
        self.registered_funcs.deinit();
    }
    
    /// Register a restricted function pointer for async calls
    fn registerFuncPtr(self: *Self, comptime func_ptr: anytype) !usize {
        const func_info = FuncPtrInfo.fromFuncPtr(func_ptr);
        const id = @intFromPtr(func_info.func_ptr);
        try self.registered_funcs.put(id, func_info);
        return id;
    }
    
    /// Get function pointer info by ID
    fn getFuncPtrInfo(self: *Self, id: usize) ?FuncPtrInfo {
        return self.registered_funcs.get(id);
    }
};

/// Mock implementation of the proposed @async builtins from #23446
/// Enhanced with #23367 function pointer support
const AsyncBuiltins = struct {
    /// Mock: Returns the required size of the async frame buffer
    /// Supports both functions and function pointers (#23367)
    fn asyncFrameSize(func: anytype) usize {
        const func_type = @TypeOf(func);
        const type_info = @typeInfo(func_type);
        
        return switch (type_info) {
            .@"fn" => 4096, // Direct function
            .pointer => |ptr_info| switch (ptr_info.size) {
                .one => if (@typeInfo(ptr_info.child) == .@"fn") 4096 else 0, // Function pointer
                else => 0,
            },
            else => 0,
        };
    }
    
    /// Mock: Initializes an async frame with function pointer support
    fn asyncInit(frame_buf: []u8, func: anytype) *AsyncFrame {
        _ = func;
        const frame: *AsyncFrame = @ptrCast(@alignCast(frame_buf.ptr));
        frame.* = AsyncFrame{
            .state = .initialized,
            .suspend_data = null,
        };
        return frame;
    }
    
    /// Mock: Initializes async frame for restricted function pointer
    fn asyncInitFuncPtr(frame_buf: []u8, func_ptr_id: usize, registry: *FuncPtrRegistry) ?*AsyncFrame {
        if (registry.getFuncPtrInfo(func_ptr_id)) |_| {
            const frame: *AsyncFrame = @ptrCast(@alignCast(frame_buf.ptr));
            frame.* = AsyncFrame{
                .state = .initialized,
                .suspend_data = null,
            };
            return frame;
        }
        return null;
    }
    
    /// Mock: Resumes an async function
    fn asyncResume(frame: *AsyncFrame, arg: *anyopaque) ?*anyopaque {
        _ = arg;
        if (frame.state == .completed) return null;
        
        frame.state = .running;
        // Mock execution - in real implementation, this would restore state
        frame.state = .completed;
        return null; // Function completed
    }
    
    /// Mock: Suspends the current function
    fn asyncSuspend(data: *anyopaque) *anyopaque {
        // In real implementation, this would suspend and spill registers
        return data;
    }
    
    /// Mock: Retrieve current async frame pointer
    fn asyncFrame() ?*AsyncFrame {
        // In real implementation, this would return current frame
        return null;
    }
};

/// Async frame state from proposal #23446
const AsyncFrameState = enum {
    initialized,
    running,
    suspended,
    completed,
};

/// Mock AsyncFrame opaque type
const AsyncFrame = struct {
    state: AsyncFrameState,
    suspend_data: ?*anyopaque,
};

/// Awaiter chain node for tail call optimization
const AwaiterChain = struct {
    awaiter_frame: ?*AsyncFrame,
    awaitee_frame: ?*AsyncFrame,
    next: ?*AwaiterChain,
    
    const Self = @This();
    
    /// Optimize awaiter chains by flattening tail calls
    fn optimizeTailCalls(self: *Self) void {
        var current = self;
        while (current.next) |next_node| {
            // If this is a tail call pattern (awaiter immediately awaits awaitee)
            if (isTailCallPattern(current, next_node)) {
                // Flatten the chain by linking awaiter directly to final awaitee
                current.awaitee_frame = next_node.awaitee_frame;
                current.next = next_node.next;
                // next_node can now be deallocated
            } else {
                current = next_node;
            }
        }
    }
    
    fn isTailCallPattern(current: *const Self, next: *const Self) bool {
        // Check if current's awaitee is next's awaiter (tail call pattern)
        return current.awaitee_frame == next.awaiter_frame;
    }
    
    /// Execute the optimized awaiter chain
    fn executeChain(self: *Self, profiler: ?*StacklessProfiler) void {
        var current = self;
        while (current) |node| {
            if (node.awaitee_frame) |awaitee| {
                // Execute awaitee and pass result back to awaiter
                var suspend_data = AsyncBuiltins.asyncResume(awaitee, node);
                if (profiler) |p| p.recordResume();
                
                while (suspend_data != null) {
                    if (profiler) |p| p.recordSuspend();
                    suspend_data = AsyncBuiltins.asyncResume(awaitee, node);
                    if (profiler) |p| p.recordResume();
                }
                
                // Notify awaiter of completion if present
                if (node.awaiter_frame) |awaiter| {
                    _ = AsyncBuiltins.asyncResume(awaiter, node);
                    if (profiler) |p| p.recordResume();
                }
            }
            current = node.next;
        }
    }
};

/// Stackless coroutine context with tail call optimization
const StacklessCoroutine = struct {
    frame_buffer: []u8,
    frame: *AsyncFrame,
    func: *const fn (*anyopaque) void,
    ctx: *anyopaque,
    result: anyerror!void = undefined,
    completed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    awaiter_chain: ?*AwaiterChain = null,
    
    const Self = @This();
    
    fn init(allocator: std.mem.Allocator, func: *const fn (*anyopaque) void, ctx: *anyopaque) !Self {
        const frame_size = AsyncBuiltins.asyncFrameSize(func);
        const frame_buffer = try allocator.alloc(u8, frame_size);
        const frame = AsyncBuiltins.asyncInit(frame_buffer, func);
        
        return Self{
            .frame_buffer = frame_buffer,
            .frame = frame,
            .func = func,
            .ctx = ctx,
        };
    }
    
    fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.frame_buffer);
    }
    
    /// Add an awaiter chain for tail call optimization
    fn addAwaiterChain(self: *Self, allocator: std.mem.Allocator, awaiter: ?*AsyncFrame, awaitee: ?*AsyncFrame) !void {
        const chain_node = try allocator.create(AwaiterChain);
        chain_node.* = AwaiterChain{
            .awaiter_frame = awaiter,
            .awaitee_frame = awaitee,
            .next = self.awaiter_chain,
        };
        self.awaiter_chain = chain_node;
        
        // Optimize the chain immediately
        if (self.awaiter_chain) |chain| {
            chain.optimizeTailCalls();
        }
    }
    
    fn execute(self: *Self, profiler: ?*StacklessProfiler) void {
        const start_time = if (profiler) |p| p.start_time else null;
        const exec_start = if (start_time) |_| std.time.Instant.now() catch unreachable else unreachable;
        
        // If we have an optimized awaiter chain, execute it
        if (self.awaiter_chain) |chain| {
            if (profiler) |p| p.recordTailCallOptimization();
            chain.executeChain(profiler);
        } else {
            // Standard stackless execution
            var suspend_data = AsyncBuiltins.asyncResume(self.frame, self.ctx);
            if (profiler) |p| p.recordResume();
            
            while (suspend_data) |data| {
                // Handle suspended operation (e.g., I/O)
                _ = data;
                
                if (profiler) |p| p.recordSuspend();
                
                // For demo, just complete immediately
                suspend_data = AsyncBuiltins.asyncResume(self.frame, self.ctx);
                if (profiler) |p| p.recordResume();
            }
        }
        
        if (profiler) |p| {
            const exec_end = std.time.Instant.now() catch unreachable;
            const duration_ns = exec_end.since(exec_start);
            p.recordCoroutineCompletion(duration_ns);
        }
        
        self.completed.store(true, .release);
    }
};

/// Event loop for stackless coroutines with profiling support
const StacklessEventLoop = struct {
    coroutines: std.ArrayList(StacklessCoroutine),
    ready_queue: std.fifo.LinearFifo(usize, .Dynamic),
    allocator: std.mem.Allocator,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    
    const Self = @This();
    
    fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .coroutines = std.ArrayList(StacklessCoroutine).init(allocator),
            .ready_queue = std.fifo.LinearFifo(usize, .Dynamic).init(allocator),
            .allocator = allocator,
        };
    }
    
    fn deinit(self: *Self) void {
        for (self.coroutines.items) |*coro| {
            coro.deinit(self.allocator);
        }
        self.coroutines.deinit();
        self.ready_queue.deinit();
    }
    
    fn spawn(self: *Self, func: *const fn (*anyopaque) void, ctx: *anyopaque, profiler: ?*StacklessProfiler) !usize {
        const coro = try StacklessCoroutine.init(self.allocator, func, ctx);
        const id = self.coroutines.items.len;
        try self.coroutines.append(coro);
        try self.ready_queue.writeItem(id);
        
        if (profiler) |p| {
            p.recordCoroutineSpawn(coro.frame_buffer.len);
        }
        
        return id;
    }
    
    fn runWithProfiler(self: *Self, profiler: ?*StacklessProfiler) void {
        self.running.store(true, .release);
        defer self.running.store(false, .release);
        
        while (self.running.load(.acquire)) {
            if (self.ready_queue.readItem()) |coro_id| {
                var coro = &self.coroutines.items[coro_id];
                if (!coro.completed.load(.acquire)) {
                    coro.execute(profiler);
                }
            } else {
                // No ready coroutines, event loop can idle or exit
                break;
            }
        }
    }
    
    fn run(self: *Self) void {
        self.runWithProfiler(null);
    }
    
    fn yield_to_browser(self: *Self) void {
        // For WASM: yield to JavaScript event loop
        // This would be implemented using browser APIs
        _ = self;
        if (builtin.target.cpu.arch.isWasm()) {
            // In real implementation: call JavaScript setTimeout(0) or similar
        }
    }
};

/// StacklessIo implementation with function pointer support and profiling
pub const StacklessIo = struct {
    allocator: std.mem.Allocator,
    config: StacklessConfig,
    event_loop: StacklessEventLoop,
    func_ptr_registry: FuncPtrRegistry,
    profiler: StacklessProfiler,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: StacklessConfig) Self {
        return Self{
            .allocator = allocator,
            .config = config,
            .event_loop = StacklessEventLoop.init(allocator),
            .func_ptr_registry = FuncPtrRegistry.init(allocator),
            .profiler = StacklessProfiler.init(config.enable_profiling),
        };
    }

    pub fn deinit(self: *Self) void {
        self.event_loop.deinit();
        self.func_ptr_registry.deinit();
    }
    
    /// Get performance metrics
    pub fn getMetrics(self: *Self) StacklessMetricsSnapshot {
        return self.profiler.getMetrics();
    }
    
    /// Reset performance metrics
    pub fn resetMetrics(self: *Self) void {
        self.profiler.metrics.reset();
    }
    
    /// Register a function pointer for async calls (#23367)
    pub fn registerFuncPtr(self: *Self, comptime func_ptr: anytype) !usize {
        return try self.func_ptr_registry.registerFuncPtr(func_ptr);
    }
    
    /// Execute an async function pointer call
    pub fn asyncFuncPtr(self: *Self, func_ptr_id: usize, args: anytype) !Future {
        if (self.func_ptr_registry.getFuncPtrInfo(func_ptr_id)) |func_info| {
            const future_impl = try self.allocator.create(StacklessFuture);
            future_impl.* = StacklessFuture{
                .allocator = self.allocator,
                .event_loop = &self.event_loop,
                .coroutine_id = undefined,
            };
            
            const task_ctx = try self.allocator.create(FuncPtrTaskContext);
            task_ctx.* = FuncPtrTaskContext{
                .func_info = func_info,
                .args_ptr = @constCast(&args),
            };
            
            const profiler = if (self.config.enable_profiling) &self.profiler else null;
            const coro_id = try self.event_loop.spawn(
                executeFuncPtrTask,
                task_ctx,
                profiler,
            );
            
            future_impl.coroutine_id = coro_id;
            
            return Future{
                .ptr = future_impl,
                .vtable = &stackless_future_vtable,
            };
        }
        return error.UnregisteredFunctionPointer;
    }

    /// Get the Io interface for this implementation
    pub fn io(self: *Self) Io {
        return Io{
            .context = self,
            .vtable = &vtable,
        };
    }

    /// Run the stackless event loop
    pub fn run(self: *Self) void {
        if (self.config.enable_profiling) {
            self.event_loop.runWithProfiler(&self.profiler);
        } else {
            self.event_loop.run();
        }
    }

    // VTable implementation - delegate to blocking I/O for simplicity
    const vtable = io_interface.Io.IoVTable{
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
    
    // Simple delegation functions
    fn read(context: *anyopaque, buffer: []u8) IoError!Future {
        _ = context;
        var blocking_impl = blocking_io.BlockingIo.init(std.heap.page_allocator, 4096);
        defer blocking_impl.deinit();
        return blocking_impl.vtable.read(context, buffer);
    }
    
    fn write(context: *anyopaque, data: []const u8) IoError!Future {
        _ = context;
        std.debug.print("{s}", .{data});
        var future = Future.init(&writeVTable, undefined);
        return future;
    }
    
    const writeVTable = Future.FutureVTable{
        .poll = writePoll,
        .cancel = writeCancel,
        .destroy = writeDestroy,
    };
    
    fn writePoll(_: *anyopaque) IoError!Future.PollResult {
        return .ready;
    }
    
    fn writeCancel(_: *anyopaque) void {}
    
    fn writeDestroy(_: *anyopaque, _: std.mem.Allocator) void {}
    
    fn readv(_: *anyopaque, _: []IoBuffer) IoError!Future {
        return error.NotSupported;
    }
    
    fn writev(_: *anyopaque, _: []const []const u8) IoError!Future {
        return error.NotSupported;
    }
    
    fn send_file(_: *anyopaque, _: std.posix.fd_t, _: u64, _: u64) IoError!Future {
        return error.NotSupported;
    }
    
    fn copy_file_range(_: *anyopaque, _: std.posix.fd_t, _: std.posix.fd_t, _: u64) IoError!Future {
        return error.NotSupported;
    }
    
    fn accept(_: *anyopaque, _: std.posix.fd_t) IoError!Future {
        return error.NotSupported;
    }
    
    fn connect(_: *anyopaque, _: std.posix.fd_t, _: std.net.Address) IoError!Future {
        return error.NotSupported;
    }
    
    fn close(_: *anyopaque, _: std.posix.fd_t) IoError!Future {
        return error.NotSupported;
    }
    
    fn shutdown(_: *anyopaque) void {}

    fn asyncFn(ptr: *anyopaque, call_info: io_interface.AsyncCallInfo) !Future {
        const self: *Self = @ptrCast(@alignCast(ptr));
        
        const future_impl = try self.allocator.create(StacklessFuture);
        future_impl.* = StacklessFuture{
            .allocator = self.allocator,
            .event_loop = &self.event_loop,
            .coroutine_id = undefined,
            .call_info = call_info, // Store for cleanup
        };
        
        // Create task context that stores the call info
        const task_ctx = try self.allocator.create(CallInfoTaskContext);
        task_ctx.* = CallInfoTaskContext{
            .call_info = call_info,
        };
        
        const profiler = if (self.config.enable_profiling) &self.profiler else null;
        const coro_id = try self.event_loop.spawn(
            executeCallInfoTask,
            task_ctx,
            profiler,
        );
        
        future_impl.coroutine_id = coro_id;
        
        return Future{
            .ptr = future_impl,
            .vtable = &stackless_future_vtable,
            .state = std.atomic.Value(Future.State).init(.pending),
            .wakers = std.ArrayList(Future.Waker).init(self.allocator),
        };
    }

    fn asyncConcurrentFn(ptr: *anyopaque, call_infos: []io_interface.AsyncCallInfo) !io_interface.ConcurrentFuture {
        const self: *Self = @ptrCast(@alignCast(ptr));
        
        // For stackless, create multiple coroutines
        std.debug.print("📄 StacklessIo: Starting {} concurrent coroutines\n", .{call_infos.len});
        
        // For now, just execute sequentially (real impl would create multiple coroutines)
        for (call_infos) |call_info| {
            try call_info.exec_fn(call_info.call_ptr);
            call_info.deinit();
        }
        
        // Return a simple completed future
        const concurrent_future = try self.allocator.create(CompletedStacklessConcurrentFuture);
        concurrent_future.* = CompletedStacklessConcurrentFuture{
            .allocator = self.allocator,
        };
        
        return io_interface.ConcurrentFuture{
            .ptr = concurrent_future,
            .vtable = &stackless_concurrent_future_vtable,
        };
    }

    fn createFile(ptr: *anyopaque, path: []const u8, options: File.CreateOptions) !File {
        const self: *Self = @ptrCast(@alignCast(ptr));
        
        // For demo, use blocking file operations
        // In real WASM implementation, this would use browser File API
        _ = options;
        const file = try std.fs.cwd().createFile(path, .{});
        const file_impl = try self.allocator.create(StacklessFile);
        file_impl.* = StacklessFile{
            .file = file,
            .allocator = self.allocator,
        };

        return File{
            .ptr = file_impl,
            .vtable = &stackless_file_vtable,
        };
    }

    fn openFile(ptr: *anyopaque, path: []const u8, options: File.OpenOptions) !File {
        const self: *Self = @ptrCast(@alignCast(ptr));
        
        const file = try std.fs.cwd().openFile(path, .{ .mode = options.mode });
        const file_impl = try self.allocator.create(StacklessFile);
        file_impl.* = StacklessFile{
            .file = file,
            .allocator = self.allocator,
        };

        return File{
            .ptr = file_impl,
            .vtable = &stackless_file_vtable,
        };
    }

    fn tcpConnect(ptr: *anyopaque, address: std.net.Address) !TcpStream {
        const self: *Self = @ptrCast(@alignCast(ptr));
        
        // In WASM, this would use WebSocket or fetch API
        const stream = try std.net.tcpConnectToAddress(address);
        const stream_impl = try self.allocator.create(StacklessTcpStream);
        stream_impl.* = StacklessTcpStream{
            .stream = stream,
            .allocator = self.allocator,
        };

        return TcpStream{
            .ptr = stream_impl,
            .vtable = &stackless_tcp_stream_vtable,
        };
    }

    fn tcpListen(ptr: *anyopaque, address: std.net.Address) !TcpListener {
        const self: *Self = @ptrCast(@alignCast(ptr));
        
        const listener = try address.listen(.{ .reuse_address = true });
        const listener_impl = try self.allocator.create(StacklessTcpListener);
        listener_impl.* = StacklessTcpListener{
            .listener = listener,
            .allocator = self.allocator,
        };

        return TcpListener{
            .ptr = listener_impl,
            .vtable = &stackless_tcp_listener_vtable,
        };
    }

    fn udpBind(ptr: *anyopaque, address: std.net.Address) !UdpSocket {
        const self: *Self = @ptrCast(@alignCast(ptr));
        
        const sock = try std.posix.socket(address.any.family, std.posix.SOCK.DGRAM, 0);
        try std.posix.bind(sock, &address.any, address.getOsSockLen());
        const socket_impl = try self.allocator.create(StacklessUdpSocket);
        socket_impl.* = StacklessUdpSocket{
            .socket = sock,
            .allocator = self.allocator,
        };

        return UdpSocket{
            .ptr = socket_impl,
            .vtable = &stackless_udp_socket_vtable,
        };
    }
};

// Task context and execution
/// Task context for call info execution
const CallInfoTaskContext = struct {
    call_info: io_interface.AsyncCallInfo,
};

/// Task executor for call info (void return for stackless)
fn executeCallInfoTask(ctx: *anyopaque) void {
    const task_ctx: *CallInfoTaskContext = @ptrCast(@alignCast(ctx));
    task_ctx.call_info.exec_fn(task_ctx.call_info.call_ptr) catch |err| {
        // In stackless mode, errors are handled by the event loop
        std.debug.print("Stackless task error: {}\n", .{err});
    };
}

fn TaskContext(comptime FuncType: type, comptime ArgsType: type) type {
    return struct {
        func: FuncType,
        args: ArgsType,
    };
}

fn executeTask(comptime FuncType: type, comptime ArgsType: type) *const fn (*anyopaque) void {
    return struct {
        fn execute(ctx: *anyopaque) void {
            const task_ctx: *TaskContext(FuncType, ArgsType) = @ptrCast(@alignCast(ctx));
            @call(.auto, task_ctx.func, task_ctx.args) catch |err| {
                std.log.err("Stackless task failed: {}", .{err});
            };
        }
    }.execute;
}

// Function pointer task context for #23367 support
const FuncPtrTaskContext = struct {
    func_info: FuncPtrInfo,
    args_ptr: *anyopaque,
};

fn executeFuncPtrTask(ctx: *anyopaque) void {
    const task_ctx: *FuncPtrTaskContext = @ptrCast(@alignCast(ctx));
    
    // In real implementation, this would:
    // 1. Extract args from args_ptr based on func_info.param_types
    // 2. Call the function pointer with proper type casting
    // 3. Handle async suspension points if func_info.is_async
    
    // Mock execution for demonstration
    _ = task_ctx.func_info;
    _ = task_ctx.args_ptr;
    
    // Simulate work
    std.log.info("Executing function pointer task", .{});
}

// Stackless future implementation
const StacklessFuture = struct {
    allocator: std.mem.Allocator,
    event_loop: *StacklessEventLoop,
    coroutine_id: usize,
    call_info: io_interface.AsyncCallInfo,
};

const CompletedStacklessConcurrentFuture = struct {
    allocator: std.mem.Allocator,
};

const stackless_future_vtable = Future.VTable{
    .await_fn = stacklessAwait,
    .cancel_fn = stacklessCancel,
    .deinit_fn = stacklessDeinit,
};

fn stacklessAwait(ptr: *anyopaque, io: Io, options: Future.AwaitOptions) !void {
    _ = io;
    _ = options;
    const future: *StacklessFuture = @ptrCast(@alignCast(ptr));
    
    // Wait for coroutine to complete
    const coro = &future.event_loop.coroutines.items[future.coroutine_id];
    while (!coro.completed.load(.acquire)) {
        // In real implementation, this would yield to event loop
        future.event_loop.yield_to_browser();
    }
    
    return coro.result;
}

fn stacklessCancel(ptr: *anyopaque, io: Io, options: Future.CancelOptions) !void {
    _ = io;
    _ = options;
    const future: *StacklessFuture = @ptrCast(@alignCast(ptr));
    
    // Mark coroutine as completed with cancellation
    const coro = &future.event_loop.coroutines.items[future.coroutine_id];
    coro.result = error.Canceled;
    coro.completed.store(true, .release);
}

fn stacklessDeinit(ptr: *anyopaque) void {
    const future: *StacklessFuture = @ptrCast(@alignCast(ptr));
    // Clean up the call info
    future.call_info.deinit();
    future.allocator.destroy(future);
}

const stackless_concurrent_future_vtable = io_interface.ConcurrentFuture.VTable{
    .await_all_fn = stacklessConcurrentAwaitAll,
    .await_any_fn = stacklessConcurrentAwaitAny,
    .cancel_all_fn = stacklessConcurrentCancelAll,
    .deinit_fn = stacklessConcurrentDeinit,
};

fn stacklessConcurrentAwaitAll(ptr: *anyopaque, io: Io) !void {
    _ = ptr;
    _ = io;
    // Already completed
}

fn stacklessConcurrentAwaitAny(ptr: *anyopaque, io: Io) !usize {
    _ = ptr;
    _ = io;
    return 0;
}

fn stacklessConcurrentCancelAll(ptr: *anyopaque, io: Io) !void {
    _ = ptr;
    _ = io;
    // Nothing to cancel
}

fn stacklessConcurrentDeinit(ptr: *anyopaque) void {
    const future: *CompletedStacklessConcurrentFuture = @ptrCast(@alignCast(ptr));
    future.allocator.destroy(future);
}

// Stackless file implementation
const StacklessFile = struct {
    file: std.fs.File,
    allocator: std.mem.Allocator,
};

const stackless_file_vtable = File.VTable{
    .writeAll = stacklessFileWriteAll,
    .readAll = stacklessFileReadAll,
    .close = stacklessFileClose,
};

fn stacklessFileWriteAll(ptr: *anyopaque, io: Io, data: []const u8) !void {
    _ = io;
    const file_impl: *StacklessFile = @ptrCast(@alignCast(ptr));
    // In WASM, this might yield to browser between chunks
    try file_impl.file.writeAll(data);
}

fn stacklessFileReadAll(ptr: *anyopaque, io: Io, buffer: []u8) !usize {
    _ = io;
    const file_impl: *StacklessFile = @ptrCast(@alignCast(ptr));
    return try file_impl.file.readAll(buffer);
}

fn stacklessFileClose(ptr: *anyopaque, io: Io) !void {
    _ = io;
    const file_impl: *StacklessFile = @ptrCast(@alignCast(ptr));
    file_impl.file.close();
    file_impl.allocator.destroy(file_impl);
}

// Stackless TCP stream implementation
const StacklessTcpStream = struct {
    stream: std.net.Stream,
    allocator: std.mem.Allocator,
};

const stackless_tcp_stream_vtable = TcpStream.VTable{
    .read = stacklessStreamRead,
    .write = stacklessStreamWrite,
    .close = stacklessStreamClose,
};

fn stacklessStreamRead(ptr: *anyopaque, io: Io, buffer: []u8) !usize {
    _ = io;
    const stream_impl: *StacklessTcpStream = @ptrCast(@alignCast(ptr));
    // In WASM, this would use WebSocket or fetch API
    return try stream_impl.stream.readAll(buffer);
}

fn stacklessStreamWrite(ptr: *anyopaque, io: Io, data: []const u8) !usize {
    _ = io;
    const stream_impl: *StacklessTcpStream = @ptrCast(@alignCast(ptr));
    try stream_impl.stream.writeAll(data);
    return data.len;
}

fn stacklessStreamClose(ptr: *anyopaque, io: Io) !void {
    _ = io;
    const stream_impl: *StacklessTcpStream = @ptrCast(@alignCast(ptr));
    stream_impl.stream.close();
    stream_impl.allocator.destroy(stream_impl);
}

// Stackless TCP listener implementation
const StacklessTcpListener = struct {
    listener: std.net.Server,
    allocator: std.mem.Allocator,
};

const stackless_tcp_listener_vtable = TcpListener.VTable{
    .accept = stacklessListenerAccept,
    .close = stacklessListenerClose,
};

fn stacklessListenerAccept(ptr: *anyopaque, io: Io) !TcpStream {
    _ = io;
    const listener_impl: *StacklessTcpListener = @ptrCast(@alignCast(ptr));
    
    const connection = try listener_impl.listener.accept();
    const stream_impl = try listener_impl.allocator.create(StacklessTcpStream);
    stream_impl.* = StacklessTcpStream{
        .stream = connection.stream,
        .allocator = listener_impl.allocator,
    };

    return TcpStream{
        .ptr = stream_impl,
        .vtable = &stackless_tcp_stream_vtable,
    };
}

fn stacklessListenerClose(ptr: *anyopaque, io: Io) !void {
    _ = io;
    const listener_impl: *StacklessTcpListener = @ptrCast(@alignCast(ptr));
    listener_impl.listener.deinit();
    listener_impl.allocator.destroy(listener_impl);
}

// Stackless UDP socket implementation
const StacklessUdpSocket = struct {
    socket: std.posix.socket_t,
    allocator: std.mem.Allocator,
};

const stackless_udp_socket_vtable = UdpSocket.VTable{
    .sendTo = stacklessUdpSendTo,
    .recvFrom = stacklessUdpRecvFrom,
    .close = stacklessUdpClose,
};

fn stacklessUdpSendTo(ptr: *anyopaque, io: Io, data: []const u8, address: std.net.Address) !usize {
    _ = io;
    const socket_impl: *StacklessUdpSocket = @ptrCast(@alignCast(ptr));
    _ = try std.posix.sendto(socket_impl.socket, data, 0, &address.any, address.getOsSockLen());
    return data.len;
}

fn stacklessUdpRecvFrom(ptr: *anyopaque, io: Io, buffer: []u8) !io_interface.RecvFromResult {
    _ = io;
    const socket_impl: *StacklessUdpSocket = @ptrCast(@alignCast(ptr));
    var addr: std.posix.sockaddr = undefined;
    var addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);
    const bytes = try std.posix.recvfrom(socket_impl.socket, buffer, 0, &addr, &addr_len);
    return .{ .bytes = bytes, .address = std.net.Address.initPosix(@alignCast(&addr)) };
}

fn stacklessUdpClose(ptr: *anyopaque, io: Io) !void {
    _ = io;
    const socket_impl: *StacklessUdpSocket = @ptrCast(@alignCast(ptr));
    std.posix.close(socket_impl.socket);
    socket_impl.allocator.destroy(socket_impl);
}

test "stackless io basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var stackless_io = StacklessIo.init(allocator, .{});
    defer stackless_io.deinit();
    
    const io = stackless_io.io();
    
    // Test file creation
    const file = try io.vtable.createFile(io.ptr, "test_stackless.txt", .{});
    try file.writeAll(io, "Hello, StacklessIo!");
    try file.close(io);
    
    // Clean up
    std.fs.cwd().deleteFile("test_stackless.txt") catch {};
}

test "stackless io with profiling" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var stackless_io = StacklessIo.init(allocator, .{ 
        .enable_profiling = true,
        .max_coroutines = 10,
    });
    defer stackless_io.deinit();
    
    // Test basic metrics
    var metrics = stackless_io.getMetrics();
    try testing.expect(metrics.coroutines_spawned == 0);
    try testing.expect(metrics.coroutines_completed == 0);
    
    // Simulate some coroutine activity
    stackless_io.profiler.recordCoroutineSpawn(4096);
    stackless_io.profiler.recordSuspend();
    stackless_io.profiler.recordResume();
    stackless_io.profiler.recordCoroutineCompletion(1000000); // 1ms
    
    metrics = stackless_io.getMetrics();
    try testing.expect(metrics.coroutines_spawned == 1);
    try testing.expect(metrics.coroutines_completed == 1);
    try testing.expect(metrics.total_suspend_count == 1);
    try testing.expect(metrics.total_resume_count == 1);
    try testing.expect(metrics.frame_memory_allocated == 4096);
    try testing.expect(metrics.total_execution_time_ns == 1000000);
    
    // Test derived metrics
    try testing.expect(metrics.averageExecutionTimeNs() == 1000000.0);
    try testing.expect(metrics.suspensionsPerCoroutine() == 1.0);
    try testing.expect(metrics.resumesPerCoroutine() == 1.0);
    
    // Test reset
    stackless_io.resetMetrics();
    metrics = stackless_io.getMetrics();
    try testing.expect(metrics.coroutines_spawned == 0);
    try testing.expect(metrics.coroutines_completed == 0);
}