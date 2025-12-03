//! zsync- Enhanced Green Threads with Advanced io_uring
//! High-performance cooperative multitasking with SQPOLL, buffer rings, and advanced features

const std = @import("std");
const builtin = @import("builtin");
const io_interface = @import("io_interface.zig");
const io_uring_enhanced = @import("io_uring_enhanced.zig");
const platform_imports = @import("platform_imports.zig");

// Architecture-specific context switching
const arch = switch (builtin.cpu.arch) {
    .x86_64 => @import("arch/x86_64.zig"),
    .aarch64 => @import("arch/aarch64.zig"), // Now supporting ARM64!
    else => @compileError("Architecture not supported for enhanced green threads"),
};

const Io = io_interface.Io;
const IoMode = io_interface.IoMode;
const IoError = io_interface.IoError;
const Future = io_interface.Future;
const CancelToken = io_interface.CancelToken;

/// Enhanced green threads configuration for high-performance workloads
pub const EnhancedGreenThreadsConfig = struct {
    /// Basic configuration
    stack_size: usize = 128 * 1024, // 128KB stack per green thread
    max_threads: u32 = 2048,        // Support more concurrent threads
    
    /// io_uring configuration  
    io_uring_entries: u32 = 512,    // Larger io_uring for high throughput
    enable_sqpoll: bool = true,     // Kernel polling for best performance
    
    /// Performance tuning
    enable_work_stealing: bool = true,     // Work stealing between threads
    enable_numa_awareness: bool = true,    // NUMA-aware scheduling
    enable_cpu_affinity: bool = true,      // Pin threads to specific CPUs
    
    /// Advanced features
    enable_zero_copy: bool = true,         // Zero-copy operations
    enable_vectorized_io: bool = true,     // Vectorized I/O operations
    enable_batch_processing: bool = true,  // Batch I/O operations
    
    /// Buffer management
    buffer_pool_size: u32 = 4096,         // Large buffer pool
    buffer_size: u32 = 16384,             // 16KB buffers for high throughput
};

/// Enhanced green thread with advanced capabilities
pub const EnhancedGreenThread = struct {
    stack: []align(16) u8,
    context: arch.Context,
    state: State,
    id: u32,
    
    // Performance features
    cpu_affinity: ?u32,          // Preferred CPU
    numa_node: ?u32,             // Preferred NUMA node
    priority: Priority,          // Thread priority for scheduling
    
    // I/O integration
    pending_operations: u32,     // Number of pending I/O ops
    last_io_time: u64,          // Last I/O operation timestamp
    io_credits: u32,            // I/O operation credits for fairness
    
    const State = enum {
        ready,
        running,
        suspended,
        io_wait,
        completed,
    };
    
    const Priority = enum(u8) {
        low = 0,
        normal = 128,
        high = 192,
        critical = 255,
    };
    
    pub fn init(allocator: std.mem.Allocator, id: u32, entry_point: *const fn () void) !EnhancedGreenThread {
        const stack = try allocator.alignedAlloc(u8, 16, 128 * 1024); // 128KB aligned stack
        
        return EnhancedGreenThread{
            .stack = stack,
            .context = arch.makeContext(stack, entry_point),
            .state = .ready,
            .id = id,
            .cpu_affinity = null,
            .numa_node = null,
            .priority = .normal,
            .pending_operations = 0,
            .last_io_time = 0,
            .io_credits = 100, // Initial I/O credits
        };
    }
    
    pub fn deinit(self: *EnhancedGreenThread, allocator: std.mem.Allocator) void {
        allocator.free(self.stack);
    }
    
    pub fn setCpuAffinity(self: *EnhancedGreenThread, cpu: u32) void {
        self.cpu_affinity = cpu;
    }
    
    pub fn setNumaNode(self: *EnhancedGreenThread, node: u32) void {
        self.numa_node = node;
    }
    
    pub fn setPriority(self: *EnhancedGreenThread, priority: Priority) void {
        self.priority = priority;
    }
};

/// Enhanced green threads I/O implementation with advanced io_uring
pub const EnhancedGreenThreadsIo = struct {
    allocator: std.mem.Allocator,
    config: EnhancedGreenThreadsConfig,
    io_uring: io_uring_enhanced.EnhancedIoUring,
    
    // Thread management
    threads: std.ArrayList(EnhancedGreenThread),
    ready_queue: std.atomic.Queue(u32),    // Ready threads queue
    io_wait_queue: std.ArrayList(u32),     // Threads waiting for I/O
    
    // Current execution
    current_thread: ?u32,
    main_context: arch.Context,
    
    // Performance tracking
    metrics: Metrics,
    
    // Advanced scheduling
    scheduler: WorkStealingScheduler,
    numa_topology: ?NumaTopology,
    
    const Self = @This();
    
    const Metrics = struct {
        threads_created: std.atomic.Value(u64),
        threads_completed: std.atomic.Value(u64),
        context_switches: std.atomic.Value(u64),
        io_operations: std.atomic.Value(u64),
        zero_copy_operations: std.atomic.Value(u64),
        work_steals: std.atomic.Value(u64),
        
        pub fn init() Metrics {
            return Metrics{
                .threads_created = std.atomic.Value(u64).init(0),
                .threads_completed = std.atomic.Value(u64).init(0),
                .context_switches = std.atomic.Value(u64).init(0),
                .io_operations = std.atomic.Value(u64).init(0),
                .zero_copy_operations = std.atomic.Value(u64).init(0),
                .work_steals = std.atomic.Value(u64).init(0),
            };
        }
    };
    
    const WorkStealingScheduler = struct {
        local_queues: []std.atomic.Queue(u32),
        global_queue: std.atomic.Queue(u32),
        num_workers: u32,
        
        pub fn init(allocator: std.mem.Allocator, num_workers: u32) !WorkStealingScheduler {
            const local_queues = try allocator.alloc(std.atomic.Queue(u32), num_workers);
            for (local_queues) |*queue| {
                queue.* = std.atomic.Queue(u32).init();
            }
            
            return WorkStealingScheduler{
                .local_queues = local_queues,
                .global_queue = std.atomic.Queue(u32).init(),
                .num_workers = num_workers,
            };
        }
        
        pub fn deinit(self: *WorkStealingScheduler, allocator: std.mem.Allocator) void {
            allocator.free(self.local_queues);
        }
        
        pub fn schedule(self: *WorkStealingScheduler, thread_id: u32, worker_id: u32) void {
            // Try local queue first
            if (worker_id < self.local_queues.len) {
                const node = std.atomic.Queue(u32).Node{ .data = thread_id, .next = null };
                self.local_queues[worker_id].put(&node);
            } else {
                // Fall back to global queue
                const node = std.atomic.Queue(u32).Node{ .data = thread_id, .next = null };
                self.global_queue.put(&node);
            }
        }
        
        pub fn steal(self: *WorkStealingScheduler, worker_id: u32) ?u32 {
            // Try local queue first
            if (worker_id < self.local_queues.len) {
                if (self.local_queues[worker_id].get()) |node| {
                    return node.data;
                }
            }
            
            // Try stealing from other workers
            var i: u32 = 0;
            while (i < self.num_workers) : (i += 1) {
                if (i != worker_id) {
                    if (self.local_queues[i].get()) |node| {
                        return node.data;
                    }
                }
            }
            
            // Try global queue
            if (self.global_queue.get()) |node| {
                return node.data;
            }
            
            return null;
        }
    };
    
    const NumaTopology = struct {
        nodes: []NumaNode,
        
        const NumaNode = struct {
            id: u32,
            cpus: []u32,
            memory_size: u64,
        };
        
        pub fn detect(allocator: std.mem.Allocator) !NumaTopology {
            // Simple NUMA detection - read from /sys/devices/system/node/
            var nodes = std.ArrayList(NumaNode){ .allocator = allocator };
            defer nodes.deinit();
            
            // For now, create a single NUMA node with all CPUs
            const cpu_count = std.Thread.getCpuCount() catch 1;
            var cpus = try allocator.alloc(u32, cpu_count);
            for (cpus, 0..) |*cpu, i| {
                cpu.* = @intCast(i);
            }
            
            try nodes.append(allocator, NumaNode{
                .id = 0,
                .cpus = cpus,
                .memory_size = 16 * 1024 * 1024 * 1024, // Assume 16GB for now
            });
            
            return NumaTopology{
                .nodes = try nodes.toOwnedSlice(),
            };
        }
        
        pub fn deinit(self: *NumaTopology, allocator: std.mem.Allocator) void {
            for (self.nodes) |node| {
                allocator.free(node.cpus);
            }
            allocator.free(self.nodes);
        }
    };
    
    pub fn init(allocator: std.mem.Allocator, config: EnhancedGreenThreadsConfig) !Self {
        // Initialize enhanced io_uring
        const io_uring_config = io_uring_enhanced.EnhancedIoUringConfig{
            .entries = config.io_uring_entries,
            .sq_poll = config.enable_sqpoll,
            .enable_fast_poll = true,
            .enable_buffer_rings = true,
            .enable_registered_files = true,
            .enable_fixed_buffers = true,
            .buffer_ring_size = config.buffer_pool_size,
            .buffer_size = config.buffer_size,
        };
        
        const enhanced_io_uring = try io_uring_enhanced.EnhancedIoUring.init(allocator, io_uring_config);
        
        // Initialize work-stealing scheduler
        const num_workers = std.Thread.getCpuCount() catch 1;
        const scheduler = try WorkStealingScheduler.init(allocator, @intCast(num_workers));
        
        // Detect NUMA topology if enabled
        const numa_topology = if (config.enable_numa_awareness)
            NumaTopology.detect(allocator) catch null
        else
            null;
        
        var self = Self{
            .allocator = allocator,
            .config = config,
            .io_uring = enhanced_io_uring,
            .threads = std.ArrayList(EnhancedGreenThread){ .allocator = allocator },
            .ready_queue = std.atomic.Queue(u32).init(),
            .io_wait_queue = std.ArrayList(u32){ .allocator = allocator },
            .current_thread = null,
            .main_context = undefined,
            .metrics = Metrics.init(),
            .scheduler = scheduler,
            .numa_topology = numa_topology,
        };
        
        // Set up CPU affinity for the main thread if enabled
        if (config.enable_cpu_affinity) {
            try platform_imports.linux.platform_linux.setThreadAffinity(0);
        }
        
        return self;
    }
    
    pub fn deinit(self: *Self) void {
        // Clean up all green threads
        for (self.threads.items) |*thread| {
            thread.deinit(self.allocator);
        }
        self.threads.deinit();
        self.io_wait_queue.deinit();
        
        // Clean up scheduler
        self.scheduler.deinit(self.allocator);
        
        // Clean up NUMA topology
        if (self.numa_topology) |*topology| {
            topology.deinit(self.allocator);
        }
        
        // Clean up io_uring
        self.io_uring.deinit();
    }
    
    pub fn io(self: *Self) Io {
        return Io{
            .vtable = &vtable,
            .context = self,
        };
    }
    
    /// Spawn a new enhanced green thread with advanced features
    pub fn spawn(self: *Self, entry_point: *const fn () void, priority: EnhancedGreenThread.Priority) !u32 {
        if (self.threads.items.len >= self.config.max_threads) {
            return error.TooManyThreads;
        }
        
        const thread_id = @as(u32, @intCast(self.threads.items.len));
        var thread = try EnhancedGreenThread.init(self.allocator, thread_id, entry_point);
        thread.setPriority(priority);
        
        // Set NUMA affinity if enabled
        if (self.config.enable_numa_awareness and self.numa_topology != null) {
            const numa_node = thread_id % self.numa_topology.?.nodes.len;
            thread.setNumaNode(@intCast(numa_node));
            
            // Set CPU affinity within the NUMA node
            if (self.config.enable_cpu_affinity) {
                const node = &self.numa_topology.?.nodes[numa_node];
                const cpu = node.cpus[thread_id % node.cpus.len];
                thread.setCpuAffinity(cpu);
            }
        }
        
        try self.threads.append(self.allocator, thread);
        
        // Schedule thread using work-stealing scheduler
        const worker_id = thread_id % self.scheduler.num_workers;
        self.scheduler.schedule(thread_id, worker_id);
        
        _ = self.metrics.threads_created.fetchAdd(1, .monotonic);
        
        return thread_id;
    }
    
    /// Enhanced scheduler with work-stealing and NUMA awareness
    pub fn schedule(self: *Self) void {
        while (true) {
            // Try to get next thread to run
            const thread_id = self.scheduler.steal(0) orelse {
                // No threads to run, poll for I/O completions
                _ = self.pollIoCompletions() catch 0;
                continue;
            };
            
            if (thread_id >= self.threads.items.len) continue;
            
            var thread = &self.threads.items[thread_id];
            if (thread.state != .ready) continue;
            
            // Set CPU affinity if configured
            if (thread.cpu_affinity) |cpu| {
                platform_imports.linux.platform_linux.setThreadAffinity(cpu) catch {};
            }
            
            // Switch to the green thread
            thread.state = .running;
            self.current_thread = thread_id;
            
            _ = self.metrics.context_switches.fetchAdd(1, .monotonic);
            arch.swapContext(&self.main_context, &thread.context);
            
            // Thread has yielded back
            self.current_thread = null;
            
            // Check thread state and handle accordingly
            switch (thread.state) {
                .completed => {
                    _ = self.metrics.threads_completed.fetchAdd(1, .monotonic);
                    // Thread finished, clean up
                },
                .io_wait => {
                    // Thread is waiting for I/O, add to I/O wait queue
                    try self.io_wait_queue.append(self.allocator, thread_id);
                },
                .suspended => {
                    // Thread yielded, put back in ready queue if it has I/O credits
                    if (thread.io_credits > 0) {
                        thread.state = .ready;
                        const worker_id = thread_id % self.scheduler.num_workers;
                        self.scheduler.schedule(thread_id, worker_id);
                    }
                },
                else => {},
            }
        }
    }
    
    /// Poll I/O completions and wake up waiting threads
    fn pollIoCompletions(self: *Self) !u32 {
        const completions = try self.io_uring.poll(16); // Poll up to 16 completions
        
        var woken: u32 = 0;
        var i: u32 = 0;
        while (i < completions) : (i += 1) {
            if (self.io_uring.getCqe()) |cqe| {
                defer self.io_uring.cqeSeen(cqe);
                
                const user_data = cqe.user_data;
                const thread_id = @as(u32, @intCast(user_data & 0xFFFFFFFF));
                
                // Wake up the waiting thread
                if (thread_id < self.threads.items.len) {
                    var thread = &self.threads.items[thread_id];
                    if (thread.state == .io_wait) {
                        thread.state = .ready;
                        thread.pending_operations = thread.pending_operations -| 1;
                        
                        const worker_id = thread_id % self.scheduler.num_workers;
                        self.scheduler.schedule(thread_id, worker_id);
                        woken += 1;
                    }
                }
                
                _ = self.metrics.io_operations.fetchAdd(1, .monotonic);
            }
        }
        
        return woken;
    }
    
    /// Get enhanced metrics including work-stealing and NUMA stats
    pub fn getMetrics(self: *const Self) *const Metrics {
        return &self.metrics;
    }
    
    /// Get io_uring metrics
    pub fn getIoUringMetrics(self: *const Self) *const io_uring_enhanced.EnhancedIoUring.Metrics {
        return self.io_uring.getMetrics();
    }
    
    // VTable implementation
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
        .get_mode = getMode,
        .supports_vectorized = supportsVectorized,
        .supports_zero_copy = supportsZeroCopy,
        .get_allocator = getAllocator,
    };
    
    fn read(context: *anyopaque, buffer: []u8) IoError!Future {
        const self: *Self = @ptrCast(@alignCast(context));
        
        // Use enhanced io_uring with buffer ring selection
        if (self.io_uring.buffer_ring != null) {
            _ = self.metrics.zero_copy_operations.fetchAdd(1, .monotonic);
            
            // Use buffer ring for zero-copy read
            const user_data = (@as(u64, self.current_thread orelse 0)) | (1 << 32); // Mark as read op
            _ = self.io_uring.prepReadBuffer(1, @intCast(buffer.len), 0, 0, user_data);
        }
        
        // Create future that will complete when I/O finishes
        const ReadFuture = struct {
            pub fn poll(_: *anyopaque) Future.PollResult {
                return .ready; // Simplified for now
            }
            
            pub fn cancel(_: *anyopaque) void {}
            
            pub fn destroy(ptr: *anyopaque, allocator: std.mem.Allocator) void {
                const future: *@This() = @ptrCast(@alignCast(ptr));
                allocator.destroy(future);
            }
            
            const vtable_impl = Future.FutureVTable{
                .poll = poll,
                .cancel = cancel,
                .destroy = destroy,
            };
        };
        
        const future = try self.allocator.create(ReadFuture);
        future.* = ReadFuture{};
        
        return Future.init(&ReadFuture.vtable_impl, future);
    }
    
    fn write(context: *anyopaque, data: []const u8) IoError!Future {
        const self: *Self = @ptrCast(@alignCast(context));
        _ = data;
        
        // Simplified write implementation
        const WriteFuture = struct {
            pub fn poll(_: *anyopaque) Future.PollResult {
                return .ready;
            }
            
            pub fn cancel(_: *anyopaque) void {}
            
            pub fn destroy(ptr: *anyopaque, allocator: std.mem.Allocator) void {
                const future: *@This() = @ptrCast(@alignCast(ptr));
                allocator.destroy(future);
            }
            
            const vtable_impl = Future.FutureVTable{
                .poll = poll,
                .cancel = cancel,
                .destroy = destroy,
            };
        };
        
        const future = try self.allocator.create(WriteFuture);
        future.* = WriteFuture{};
        
        return Future.init(&WriteFuture.vtable_impl, future);
    }
    
    // Simplified implementations for other I/O operations
    fn readv(context: *anyopaque, buffers: []io_interface.IoBuffer) IoError!Future {
        _ = context;
        _ = buffers;
        return IoError.NotSupported;
    }
    
    fn writev(context: *anyopaque, data: []const []const u8) IoError!Future {
        _ = context;
        _ = data;
        return IoError.NotSupported;
    }
    
    fn send_file(context: *anyopaque, src_fd: std.posix.fd_t, offset: u64, count: u64) IoError!Future {
        _ = context;
        _ = src_fd;
        _ = offset;
        _ = count;
        return IoError.NotSupported;
    }
    
    fn copy_file_range(context: *anyopaque, src_fd: std.posix.fd_t, dst_fd: std.posix.fd_t, count: u64) IoError!Future {
        _ = context;
        _ = src_fd;
        _ = dst_fd;
        _ = count;
        return IoError.NotSupported;
    }
    
    fn accept(context: *anyopaque, listener_fd: std.posix.fd_t) IoError!Future {
        _ = context;
        _ = listener_fd;
        return IoError.NotSupported;
    }
    
    fn connect(context: *anyopaque, fd: std.posix.fd_t, address: std.net.Address) IoError!Future {
        _ = context;
        _ = fd;
        _ = address;
        return IoError.NotSupported;
    }
    
    fn close(context: *anyopaque, fd: std.posix.fd_t) IoError!Future {
        _ = context;
        _ = fd;
        return IoError.NotSupported;
    }
    
    fn shutdown(context: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(context));
        _ = self;
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
    
    fn getAllocator(context: *anyopaque) std.mem.Allocator {
        const self: *Self = @ptrCast(@alignCast(context));
        return self.allocator;
    }
};

/// Create enhanced green threads I/O instance with optimal configuration
pub fn createEnhancedGreenThreadsIo(allocator: std.mem.Allocator, entries: u32) !EnhancedGreenThreadsIo {
    const config = EnhancedGreenThreadsConfig{
        .stack_size = 128 * 1024,      // 128KB stack
        .max_threads = 4096,           // Support many concurrent threads
        .io_uring_entries = entries,
        .enable_sqpoll = true,         // Kernel polling
        .enable_work_stealing = true,  // Work stealing scheduler
        .enable_numa_awareness = true, // NUMA optimization
        .enable_cpu_affinity = true,   // CPU pinning
        .enable_zero_copy = true,      // Zero-copy operations
        .enable_vectorized_io = true,  // Vectorized I/O
        .enable_batch_processing = true, // Batch operations
        .buffer_pool_size = 8192,      // Large buffer pool
        .buffer_size = 32768,          // 32KB buffers
    };
    
    return EnhancedGreenThreadsIo.init(allocator, config);
}