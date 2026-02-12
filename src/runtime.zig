//! zsync - The Tokio of Zig
//! Production-ready colorblind async runtime with comprehensive platform support
//! True colorblind async: same code works across all execution models

const std = @import("std");
const builtin = @import("builtin");
const io_interface = @import("io_interface.zig");
const compat = @import("compat/thread.zig");

/// Sleep for specified seconds and nanoseconds using syscall
fn nanosleepNs(sec: isize, nsec: isize) void {
    if (builtin.os.tag == .linux) {
        const ts = std.os.linux.timespec{ .sec = sec, .nsec = nsec };
        _ = std.os.linux.nanosleep(&ts, null);
    }
}
const blocking_io = @import("blocking_io.zig");

// Conditional thread pool import - not available on WASM
const thread_pool = if (builtin.target.cpu.arch == .wasm32) 
    @import("thread_pool_stub.zig") 
else 
    @import("thread_pool.zig");

const platform_imports = @import("platform_imports.zig");
const platform_detect = @import("platform_detect.zig");

// Use conditional imports
const green_threads = platform_imports.linux.green_threads;

const Io = io_interface.Io;
const IoMode = io_interface.IoMode;
const Future = io_interface.Future;
const CancelToken = io_interface.CancelToken;
const Combinators = io_interface.Combinators;

/// Execution model for the runtime
pub const ExecutionModel = enum {
    auto,           // Automatically select best model for platform
    blocking,       // Direct syscalls, C-equivalent performance  
    thread_pool,    // OS threads for true parallelism
    green_threads,  // Cooperative tasks with stack switching
    stackless,      // Stackless coroutines for WASM compatibility
    
    /// Detect optimal execution model for current platform
    pub fn detect() ExecutionModel {
        // Thread pool is now implemented, so we can use it as default
        return switch (builtin.os.tag) {
            .linux => detectLinuxOptimal(),
            .windows => .thread_pool,   // IOCP available
            .macos => .thread_pool,     // kqueue + GCD available  
            .freebsd => .thread_pool,   // kqueue available
            .openbsd => .thread_pool,   // kqueue available
            .netbsd => .thread_pool,    // kqueue available
            .dragonfly => .thread_pool, // kqueue available
            .wasi => .blocking,        // WASM - no threads yet
            .haiku => .thread_pool,     // Native threading
            // Note: .solaris removed in Zig 0.16, use .illumos or .solaris_illumos
            .illumos => .thread_pool,   // Event ports available (covers Solaris)
            .plan9 => .blocking,        // Simple model
            .fuchsia => .thread_pool,   // Async I/O available
            else => .blocking,          // Safe fallback
        };
    }
    
    /// Detect optimal model for Linux distributions
    fn detectLinuxOptimal() ExecutionModel {
        const caps = platform_detect.detectSystemCapabilities();
        const settings = platform_detect.getDistroOptimalSettings(caps.distro);
        
        // Distribution-specific optimizations
        switch (caps.distro) {
            .arch, .fedora, .gentoo, .nixos => {
                // Cutting-edge distributions with latest kernels
                if (settings.prefer_io_uring and caps.has_io_uring) {
                    return .green_threads; // Use io_uring for maximum performance
                }
                return .thread_pool;
            },
            .debian, .ubuntu => {
                // Conservative, stability-focused distributions
                if (caps.kernel_version.major >= 5 and caps.kernel_version.minor >= 15) {
                    // Use io_uring on recent stable kernels (5.15+)
                    if (settings.prefer_io_uring and caps.has_io_uring) {
                        return .green_threads;
                    }
                }
                return .thread_pool;
            },
            .alpine => {
                // Minimal distribution, prefer lighter threading
                return .blocking;
            },
            else => {
                // Unknown distribution, use safe defaults
                return .thread_pool;
            }
        }
    }
    
    /// Check if io_uring is available on Linux
    fn checkIoUringSupport() bool {
        // Check kernel version (io_uring requires 5.1+)
        const uname = std.posix.uname();
        // Parse kernel version from uname.release
        // Format: major.minor.patch-extra
        var iter = std.mem.tokenize(u8, &uname.release, ".-");
        const major = std.fmt.parseInt(u32, iter.next() orelse "0", 10) catch 0;
        const minor = std.fmt.parseInt(u32, iter.next() orelse "0", 10) catch 0;
        
        // io_uring requires kernel 5.1+
        if (major > 5 or (major == 5 and minor >= 1)) {
            // Additional check: try to probe io_uring
            // For now, return true if kernel version is sufficient
            return true;
        }
        
        return false;
    }
};

/// Runtime configuration with performance tuning
pub const Config = struct {
    execution_model: ExecutionModel = .auto,
    
    // Thread pool settings
    thread_pool_threads: u32 = 0, // 0 = auto-detect
    thread_pool_queue_size: u32 = 1024,
    
    // Green threads settings  
    green_thread_stack_size: usize = 64 * 1024,
    max_green_threads: u32 = 1024,
    queue_depth: ?u32 = null,
    
    // Buffer management
    buffer_size: usize = 4096,
    buffer_pool_size: u32 = 64,
    
    // Performance settings
    enable_metrics: bool = false,
    enable_zero_copy: bool = true,
    enable_vectorized_io: bool = true,
    
    // Debug settings
    enable_debugging: bool = false,
    log_level: LogLevel = .info,
    
    pub const LogLevel = enum {
        trace,
        debug,
        info,
        warn,
        err,
    };

    /// Create optimal configuration for current platform
    pub fn optimal() Config {
        const model = ExecutionModel.detect();
        const cpu_count = std.Thread.getCpuCount() catch 4;

        return Config{
            .execution_model = model,
            .thread_pool_threads = @intCast(@min(cpu_count, 16)),
            .enable_zero_copy = switch (builtin.os.tag) {
                .linux => ExecutionModel.checkIoUringSupport(),
                else => false,
            },
            .enable_vectorized_io = true,
            .enable_metrics = false,
            .enable_debugging = false,
        };
    }

    /// Create optimal configuration for CLI applications
    pub fn forCli() Config {
        return Config{
            .execution_model = .blocking, // CLI tools don't need async overhead
            .enable_metrics = false,
            .enable_debugging = false,
        };
    }

    /// Create optimal configuration for servers
    pub fn forServer() Config {
        const cpu_count = std.Thread.getCpuCount() catch 4;

        return Config{
            .execution_model = .thread_pool,
            .thread_pool_threads = @intCast(@min(cpu_count * 2, 32)),
            .enable_zero_copy = true,
            .enable_vectorized_io = true,
            .enable_metrics = true,
            .enable_debugging = false,
        };
    }

    /// Create minimal configuration for embedded systems
    pub fn forEmbedded() Config {
        return Config{
            .execution_model = .blocking,
            .buffer_size = 1024, // Minimal buffer
            .buffer_pool_size = 8, // Small pool
            .enable_metrics = false,
            .enable_zero_copy = false,
            .enable_vectorized_io = false,
            .enable_debugging = false,
        };
    }

    /// Validate configuration and print warnings
    pub fn validate(self: Config) !void {
        // Thread pool validation
        if (self.execution_model == .thread_pool) {
            if (self.thread_pool_threads > 128) {
                std.debug.print("⚠️  Warning: thread_pool_threads={} is very high (max recommended: 128)\n", .{self.thread_pool_threads});
                std.debug.print("   Consider reducing for better performance.\n", .{});
                return RuntimeError.InvalidThreadCount;
            }

            if (self.thread_pool_threads == 1) {
                std.debug.print("⚠️  Warning: thread_pool_threads=1 provides no parallelism benefit.\n", .{});
                std.debug.print("   Consider using execution_model = .blocking instead.\n", .{});
            }
        }

        // Green threads validation
        if (self.execution_model == .green_threads) {
            if (builtin.os.tag != .linux) {
                std.debug.print("❌ Error: Green threads only supported on Linux\n", .{});
                return RuntimeError.GreenThreadsNotSupported;
            }

            if (self.green_thread_stack_size < 4096) {
                std.debug.print("❌ Error: green_thread_stack_size too small (min 4096 bytes)\n", .{});
                return RuntimeError.BufferSizeTooSmall;
            }
        }

        // Buffer size validation
        if (self.buffer_size < 1024) {
            std.debug.print("⚠️  Warning: buffer_size={} is very small (min recommended: 1024)\n", .{self.buffer_size});
            std.debug.print("   This may hurt performance.\n", .{});
        }

        // Zero-copy validation
        if (self.enable_zero_copy) {
            const has_support = switch (builtin.os.tag) {
                .linux => ExecutionModel.checkIoUringSupport(),
                else => false,
            };

            if (!has_support) {
                std.debug.print("⚠️  Warning: enable_zero_copy=true but zero-copy not available on this platform.\n", .{});
                std.debug.print("   Feature will be disabled.\n", .{});
            }
        }

        // Debug validation
        if (self.enable_debugging and self.enable_metrics) {
            std.debug.print("💡 Info: Both debugging and metrics enabled. This may impact performance.\n", .{});
        }
    }
};

/// Runtime errors with helpful context
pub const RuntimeError = error{
    AlreadyRunning,
    RuntimeShutdown,
    InvalidExecutionModel,
    OutOfMemory,
    SystemResourceExhausted,
    ConfigurationError,
    PlatformUnsupported,
    // v0.7 New specific errors
    ThreadPoolExhausted,
    TaskQueueFull,
    FutureAlreadyAwaited,
    CancellationRequested,
    TimeoutExpired,
    IoUringNotAvailable,
    InvalidThreadCount,
    BufferSizeTooSmall,
    GreenThreadsNotSupported,
};

/// Format error with helpful message and suggestions
pub fn formatError(err: RuntimeError) []const u8 {
    return switch (err) {
        error.ThreadPoolExhausted =>
            "Thread pool has no available workers. Consider increasing thread_pool_threads in Config or reducing concurrent task load.",
        error.IoUringNotAvailable =>
            "io_uring not available on this system. Linux kernel 5.1+ required. Consider using execution_model = .thread_pool instead.",
        error.InvalidThreadCount =>
            "Invalid thread count specified. Must be between 1 and 128. Use 0 for auto-detection based on CPU count.",
        error.BufferSizeTooSmall =>
            "Buffer size too small. Minimum 1024 bytes recommended. Increase Config.buffer_size for better performance.",
        error.GreenThreadsNotSupported =>
            "Green threads not supported on this platform. Only available on Linux with io_uring. Use execution_model = .thread_pool instead.",
        error.ConfigurationError =>
            "Invalid configuration detected. Run Config.validate() for detailed error information.",
        error.PlatformUnsupported =>
            "This execution model is not supported on your platform. Use ExecutionModel.detect() for optimal model.",
        error.AlreadyRunning =>
            "Runtime is already running. Cannot start multiple instances simultaneously.",
        error.RuntimeShutdown =>
            "Runtime has been shutdown. Create a new Runtime instance to continue.",
        error.TaskQueueFull =>
            "Task queue is full. Too many pending tasks. Wait for some to complete or increase queue_size.",
        error.FutureAlreadyAwaited =>
            "Future has already been awaited. Futures can only be awaited once.",
        error.TimeoutExpired =>
            "Operation timed out. Increase timeout duration or check if operation is stalled.",
        else => @errorName(err),
    };
}

/// Print error with helpful context
pub fn printError(err: RuntimeError) void {
    std.debug.print("❌ Zsync Error: {s}\n", .{formatError(err)});
}

/// Performance metrics for the runtime
pub const RuntimeMetrics = struct {
    // Use 32-bit atomics on WASM due to platform limitations
    const CounterType = if (builtin.target.cpu.arch == .wasm32) u32 else u64;
    
    tasks_spawned: std.atomic.Value(CounterType) = std.atomic.Value(CounterType).init(0),
    tasks_completed: std.atomic.Value(CounterType) = std.atomic.Value(CounterType).init(0),
    futures_created: std.atomic.Value(CounterType) = std.atomic.Value(CounterType).init(0),
    futures_cancelled: std.atomic.Value(CounterType) = std.atomic.Value(CounterType).init(0),
    total_io_operations: std.atomic.Value(CounterType) = std.atomic.Value(CounterType).init(0),
    average_latency_ns: std.atomic.Value(CounterType) = std.atomic.Value(CounterType).init(0),
    
    pub fn incrementTasks(self: *RuntimeMetrics) void {
        _ = self.tasks_spawned.fetchAdd(1, .monotonic);
    }
    
    pub fn completeTasks(self: *RuntimeMetrics) void {
        _ = self.tasks_completed.fetchAdd(1, .monotonic);
    }
    
    pub fn incrementFutures(self: *RuntimeMetrics) void {
        _ = self.futures_created.fetchAdd(1, .monotonic);
    }
    
    pub fn cancelFuture(self: *RuntimeMetrics) void {
        _ = self.futures_cancelled.fetchAdd(1, .monotonic);
    }
    
    pub fn recordIoOperation(self: *RuntimeMetrics, latency_ns: CounterType) void {
        _ = self.total_io_operations.fetchAdd(1, .monotonic);
        // Simple moving average
        const current_avg = self.average_latency_ns.load(.monotonic);
        const new_avg = (current_avg + latency_ns) / 2;
        self.average_latency_ns.store(new_avg, .monotonic);
    }
};

/// Global runtime instance (singleton pattern)
var global_runtime: ?*Runtime = null;
var global_runtime_mutex = compat.Mutex{};

/// zsync - The Tokio of Zig - Production-Ready Async Runtime
pub const Runtime = struct {
    allocator: std.mem.Allocator,
    config: Config,
    execution_model: ExecutionModel,
    io_impl: IoImplementation,
    running: std.atomic.Value(bool),
    metrics: RuntimeMetrics,
    cancel_token: ?*CancelToken,
    
    const Self = @This();
    
    /// Union of all possible I/O implementations
    const IoImplementation = union(ExecutionModel) {
        auto: void, // Will be resolved
        blocking: blocking_io.BlockingIo,
        thread_pool: thread_pool.ThreadPoolIo,
        green_threads: if (green_threads != void) green_threads.GreenThreadsIo else void,
        stackless: void, // TODO: Implement in next phase
    };
    
    /// Initialize a new runtime with configuration
    pub fn init(allocator: std.mem.Allocator, config: Config) !*Self {
        const runtime = try allocator.create(Self);
        errdefer allocator.destroy(runtime);
        
        // Resolve execution model
        const resolved_model = if (config.execution_model == .auto) 
            ExecutionModel.detect() 
        else 
            config.execution_model;
        
        // Validate configuration
        try validateConfig(config, resolved_model);
        
        // Create I/O implementation
        const io_impl = try createIoImplementation(allocator, config, resolved_model);
        
        runtime.* = Self{
            .allocator = allocator,
            .config = config,
            .execution_model = resolved_model,
            .io_impl = io_impl,
            .running = std.atomic.Value(bool).init(false),
            .metrics = RuntimeMetrics{},
            .cancel_token = null,
        };
        
        if (config.enable_debugging) {
            logInfo("Runtime initialized with {} execution model", .{resolved_model});
        }
        
        return runtime;
    }
    
    /// Validate runtime configuration
    fn validateConfig(config: Config, model: ExecutionModel) !void {
        switch (model) {
            .thread_pool => {
                if (config.thread_pool_threads > 128) {
                    return RuntimeError.ConfigurationError;
                }
            },
            .green_threads => {
                if (green_threads == void) {
                    return RuntimeError.PlatformUnsupported;
                }
                if (config.green_thread_stack_size < 4096) {
                    return RuntimeError.ConfigurationError;
                }
            },
            else => {},
        }
    }
    
    /// Create I/O implementation based on execution model
    fn createIoImplementation(allocator: std.mem.Allocator, config: Config, model: ExecutionModel) !IoImplementation {
        return switch (model) {
            .blocking => IoImplementation{
                .blocking = blocking_io.BlockingIo.init(allocator, config.buffer_size)
            },
            .thread_pool => IoImplementation{
                .thread_pool = try thread_pool.ThreadPoolIo.init(
                    allocator,
                    config.thread_pool_threads,
                    config.buffer_size
                )
            },
            .green_threads => IoImplementation{ .green_threads = if (green_threads != void) try green_threads.createGreenThreadsIo(allocator, config.queue_depth orelse 256) else {} },
            .stackless => IoImplementation{ .stackless = {} }, // TODO
            .auto => unreachable, // Should be resolved above
        };
    }
    
    /// Deinitialize the runtime
    pub fn deinit(self: *Self) void {
        self.shutdown();
        
        // Cleanup I/O implementation
        switch (self.io_impl) {
            .blocking => |*blocking| blocking.deinit(),
            .thread_pool => |*tp| tp.deinit(),
            .green_threads => |*impl| if (green_threads != void) impl.deinit(),
            .stackless => {}, // TODO
            .auto => {},
        }
        
        if (self.cancel_token) |token| {
            token.deinit();
        }
        
        self.allocator.destroy(self);
    }
    
    /// Set this runtime as the global runtime
    pub fn setGlobal(self: *Self) void {
        global_runtime_mutex.lock();
        defer global_runtime_mutex.unlock();
        global_runtime = self;
    }
    
    /// Get the global runtime instance
    pub fn global() ?*Self {
        global_runtime_mutex.lock();
        defer global_runtime_mutex.unlock();
        return global_runtime;
    }
    
    /// Get the Io interface for this runtime
    pub fn getIo(self: *Self) Io {
        return switch (self.io_impl) {
            .blocking => |*blocking| blocking.io(),
            .thread_pool => |*tp| tp.io(),
            .green_threads => |*impl| if (green_threads != void) impl.io() else unreachable,
            .stackless => unreachable, // TODO
            .auto => unreachable,
        };
    }
    
    /// Main runtime execution - true colorblind async
    pub fn run(self: *Self, comptime task_fn: anytype, args: anytype) !void {
        if (self.running.swap(true, .acq_rel)) {
            return RuntimeError.AlreadyRunning;
        }
        defer self.running.store(false, .release);
        
        // Set as global runtime
        self.setGlobal();
        defer {
            global_runtime_mutex.lock();
            global_runtime = null;
            global_runtime_mutex.unlock();
        }
        
        // Create master cancellation token
        self.cancel_token = try CancelToken.init(self.allocator, .user_requested);
        defer {
            if (self.cancel_token) |token| {
                token.deinit();
                self.cancel_token = null;
            }
        }
        
        const model_name = @tagName(self.execution_model);
        if (self.config.enable_debugging) {
            logInfo("🚀 zsync - The Tokio of Zig - starting with {s} execution model", .{model_name});
        }
        
        // Note: Zig 0.16 uses Instant.now() instead of nanoTimestamp()
        const start_instant = compat.Instant.now() catch unreachable;
        
        // Execute main task with colorblind async
        const io = self.getIo();
        try self.executeTask(task_fn, args, io);

        // CRITICAL FIX: Auto-shutdown after task completes
        // This signals thread pool workers to exit immediately
        // instead of waiting indefinitely for more work
        self.shutdown();

        // Give workers a brief moment to receive shutdown signal and exit
        nanosleepNs(0, 5 * std.time.ns_per_ms);

        // Calculate execution time using Instant API
        const end_instant = compat.Instant.now() catch unreachable;
        const execution_time_ns = end_instant.since(start_instant);

        if (self.config.enable_debugging) {
            logInfo("✅ Runtime completed in {d}ms", .{execution_time_ns / std.time.ns_per_ms});
            self.printMetrics();
        }
    }
    
    /// Execute a task with proper error handling and metrics
    fn executeTask(self: *Self, comptime task_fn: anytype, args: anytype, io: Io) !void {
        self.metrics.incrementTasks();
        defer self.metrics.completeTasks();
        
        const TaskType = @TypeOf(task_fn);
        const task_info = @typeInfo(TaskType);
        
        if (task_info != .@"fn") {
            @compileError("Task must be a function");
        }
        
        // Call task with appropriate arguments
        const result = switch (@typeInfo(@TypeOf(args))) {
            .@"struct" => |struct_info| blk: {
                if (struct_info.fields.len == 0) {
                    // No args, just pass io
                    break :blk task_fn(io);
                } else {
                    // Pass io + args
                    break :blk @call(.auto, task_fn, .{io} ++ args);
                }
            },
            .void => task_fn(io),
            else => task_fn(io, args),
        };
        
        return result;
    }
    
    /// Spawn a new task for concurrent execution
    pub fn spawn(self: *Self, comptime task_fn: anytype, args: anytype) !Future {
        self.metrics.incrementFutures();

        // Create task context
        const TaskContext = struct {
            runtime: *Self,
            state: std.atomic.Value(Future.State),
            result: ?anyerror,
            mutex: compat.Mutex,

            fn poll(ctx: *anyopaque) Future.PollResult {
                const task_ctx: *@This() = @ptrCast(@alignCast(ctx));
                const state = task_ctx.state.load(.acquire);

                return switch (state) {
                    .pending => .pending,
                    .ready => .ready,
                    .cancelled => .cancelled,
                    .error_state => if (task_ctx.result) |err| .{ .err = @as(io_interface.IoError, @errorCast(err)) } else .{ .err = io_interface.IoError.Unexpected },
                };
            }

            fn cancel(ctx: *anyopaque) void {
                const task_ctx: *@This() = @ptrCast(@alignCast(ctx));
                task_ctx.state.store(.cancelled, .release);
            }

            fn destroy(ctx: *anyopaque, allocator: std.mem.Allocator) void {
                const task_ctx: *@This() = @ptrCast(@alignCast(ctx));
                allocator.destroy(task_ctx);
            }

            const vtable = Future.FutureVTable{
                .poll = poll,
                .cancel = cancel,
                .destroy = destroy,
            };
        };

        const task_ctx = try self.allocator.create(TaskContext);
        task_ctx.* = .{
            .runtime = self,
            .state = std.atomic.Value(Future.State).init(.pending),
            .result = null,
            .mutex = .{},
        };

        // Execute task based on execution model
        switch (self.execution_model) {
            .blocking => {
                // Execute synchronously in blocking mode
                @call(.auto, task_fn, args) catch |err| {
                    task_ctx.result = err;
                    task_ctx.state.store(.error_state, .release);
                    return Future.init(&TaskContext.vtable, task_ctx);
                };
                task_ctx.state.store(.ready, .release);
            },
            .thread_pool => {
                // Submit to thread pool for async execution
                const ThreadTask = struct {
                    fn run(ctx: *TaskContext, func: @TypeOf(task_fn), task_args: @TypeOf(args)) void {
                        @call(.auto, func, task_args) catch |err| {
                            ctx.result = err;
                            ctx.state.store(.error_state, .release);
                            return;
                        };
                        ctx.state.store(.ready, .release);
                    }
                };

                // Create a thread to run the task
                const thread = try std.Thread.spawn(.{}, ThreadTask.run, .{ task_ctx, task_fn, args });
                thread.detach();
            },
            .green_threads => {
                // Use green thread scheduler for cooperative multitasking
                // For now, spawn a lightweight thread until green thread scheduler is fully integrated
                const ThreadTask = struct {
                    fn run(ctx: *TaskContext, func: @TypeOf(task_fn), task_args: @TypeOf(args)) void {
                        @call(.auto, func, task_args) catch |err| {
                            ctx.result = err;
                            ctx.state.store(.error_state, .release);
                            return;
                        };
                        ctx.state.store(.ready, .release);
                    }
                };
                const thread = try std.Thread.spawn(.{}, ThreadTask.run, .{ task_ctx, task_fn, args });
                thread.detach();
            },
            else => {
                // For stackless, auto - fall back to blocking for now
                @call(.auto, task_fn, args) catch |err| {
                    task_ctx.result = err;
                    task_ctx.state.store(.error_state, .release);
                    return Future.init(&TaskContext.vtable, task_ctx);
                };
                task_ctx.state.store(.ready, .release);
            },
        }

        return Future.init(&TaskContext.vtable, task_ctx);
    }
    
    /// Create a timeout future
    pub fn timeout(self: *Self, future: Future, timeout_ms: u64) !Future {
        self.metrics.incrementFutures();
        return Combinators.timeout(self.allocator, future, timeout_ms);
    }
    
    /// Race multiple futures
    pub fn race(self: *Self, futures: []Future) !Future {
        self.metrics.incrementFutures();
        return Combinators.race(self.allocator, futures);
    }
    
    /// Wait for all futures
    pub fn all(self: *Self, futures: []Future) !Future {
        self.metrics.incrementFutures();
        return Combinators.all(self.allocator, futures);
    }
    
    /// Request runtime shutdown
    pub fn shutdown(self: *Self) void {
        if (self.cancel_token) |token| {
            token.cancel();
        }
        
        // Shutdown I/O implementation
        var io = self.getIo();
        io.shutdown();
        
        if (self.config.enable_debugging) {
            logInfo("Runtime shutdown requested", .{});
        }
    }
    
    /// Check if runtime is running
    pub fn isRunning(self: *Self) bool {
        return self.running.load(.acquire);
    }
    
    /// Get current execution model name
    pub fn getExecutionModel(self: *Self) ExecutionModel {
        return self.execution_model;
    }
    
    /// Get runtime metrics
    pub fn getMetrics(self: *const Self) RuntimeMetrics {
        return self.metrics;
    }
    
    /// Print performance metrics
    fn printMetrics(self: *const Self) void {
        const metrics = self.getMetrics();
        logInfo("📊 Runtime Metrics:", .{});
        logInfo("  Tasks: {} spawned, {} completed", .{
            metrics.tasks_spawned.load(.monotonic),
            metrics.tasks_completed.load(.monotonic),
        });
        logInfo("  Futures: {} created, {} cancelled", .{
            metrics.futures_created.load(.monotonic),
            metrics.futures_cancelled.load(.monotonic),
        });
        logInfo("  I/O Ops: {}, Avg Latency: {}ns", .{
            metrics.total_io_operations.load(.monotonic),
            metrics.average_latency_ns.load(.monotonic),
        });
    }
};

/// Convenience functions for different execution models

/// Run with automatic execution model detection
pub fn run(comptime task_fn: anytype, args: anytype) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    
    const runtime = try Runtime.init(gpa.allocator(), .{});
    defer runtime.deinit();
    
    try runtime.run(task_fn, args);
}

/// Run with blocking I/O (C-equivalent performance)
pub fn runBlocking(comptime task_fn: anytype, args: anytype) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    
    const config = Config{
        .execution_model = .blocking,
        .enable_debugging = true,
    };
    
    const runtime = try Runtime.init(gpa.allocator(), config);
    defer runtime.deinit();
    
    try runtime.run(task_fn, args);
}

/// Run with high-performance configuration
pub fn runHighPerf(comptime task_fn: anytype, args: anytype) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    
    const config = Config{
        .execution_model = .thread_pool,
        .thread_pool_threads = @intCast(@max(1, std.Thread.getCpuCount() catch 4)),
        .enable_zero_copy = true,
        .enable_vectorized_io = true,
        .enable_metrics = true,
    };
    
    const runtime = try Runtime.init(gpa.allocator(), config);
    defer runtime.deinit();
    
    try runtime.run(task_fn, args);
}

/// Get the global runtime's Io interface
pub fn getGlobalIo() ?Io {
    const runtime = Runtime.global() orelse return null;
    return runtime.getIo();
}

/// Initialize a global runtime with custom configuration
pub fn initGlobalRuntime(allocator: std.mem.Allocator, config: Config) !void {
    global_runtime_mutex.lock();
    defer global_runtime_mutex.unlock();

    if (global_runtime != null) {
        return RuntimeError.AlreadyRunning;
    }

    global_runtime = try Runtime.init(allocator, config);
}

/// Deinitialize the global runtime
pub fn deinitGlobalRuntime() void {
    global_runtime_mutex.lock();
    defer global_runtime_mutex.unlock();

    if (global_runtime) |runtime| {
        runtime.deinit();
        global_runtime = null;
    }
}

/// Get the global runtime (if initialized)
pub fn getGlobalRuntime() ?*Runtime {
    return Runtime.global();
}

/// Run a simple synchronous task without async overhead
/// Perfect for CLI commands like --help, --version, etc.
pub fn runSimple(comptime task_fn: anytype, args: anytype) !void {
    // No GPA needed for truly simple tasks
    var buffer: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const allocator = fba.allocator();

    // Execute task directly without runtime overhead
    const TaskType = @TypeOf(task_fn);
    const task_info = @typeInfo(TaskType);

    if (task_info != .@"fn") {
        @compileError("Task must be a function");
    }

    // Call task based on signature
    return switch (@typeInfo(@TypeOf(args))) {
        .@"struct" => |struct_info| blk: {
            if (struct_info.fields.len == 0) {
                // No args
                break :blk task_fn(allocator);
            } else {
                // With args
                break :blk @call(.auto, task_fn, .{allocator} ++ args);
            }
        },
        .void => task_fn(allocator),
        else => task_fn(allocator, args),
    };
}

// Logging utilities
fn logInfo(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("[Zsync] " ++ fmt ++ "\n", args);
}

fn logError(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("[Zsync ERROR] " ++ fmt ++ "\n", args);
}

// Tests
test "Runtime basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    const runtime = try Runtime.init(allocator, .{ .execution_model = .blocking });
    defer runtime.deinit();
    
    try testing.expect(!runtime.isRunning());
    try testing.expect(runtime.getExecutionModel() == .blocking);
    
    const io = runtime.getIo();
    try testing.expect(io.getMode() == .blocking);
}

test "Colorblind async example" {
    const TestTask = struct {
        fn task(io: Io) !void {
            const data = "Hello, zsync - The Tokio of Zig!";
            var io_mut = io;
            var future = try io_mut.write(data);
            defer future.destroy(io.getAllocator());
            try future.await();
        }
    };
    
    try runBlocking(TestTask.task, {});
}

test "Runtime metrics" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const config = Config{
        .execution_model = .blocking,
        .enable_metrics = true,
    };

    const runtime = try Runtime.init(allocator, config);
    defer runtime.deinit();

    const metrics = runtime.getMetrics();
    try testing.expect(metrics.tasks_spawned.load(.monotonic) == 0);
    try testing.expect(metrics.tasks_completed.load(.monotonic) == 0);
}

/// Runtime Builder for ergonomic configuration
pub const RuntimeBuilder = struct {
    config: Config,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .config = Config{},
            .allocator = allocator,
        };
    }

    /// Set execution model
    pub fn executionModel(self: *Self, model: ExecutionModel) *Self {
        self.config.execution_model = model;
        return self;
    }

    /// Set thread count
    pub fn threads(self: *Self, count: u32) *Self {
        self.config.thread_pool_threads = count;
        return self;
    }

    /// Set buffer size
    pub fn bufferSize(self: *Self, size: usize) *Self {
        self.config.buffer_size = size;
        return self;
    }

    /// Enable metrics
    pub fn enableMetrics(self: *Self) *Self {
        self.config.enable_metrics = true;
        return self;
    }

    /// Enable debugging
    pub fn enableDebugging(self: *Self) *Self {
        self.config.enable_debugging = true;
        return self;
    }

    /// Enable zero-copy I/O
    pub fn enableZeroCopy(self: *Self) *Self {
        self.config.enable_zero_copy = true;
        return self;
    }

    /// Enable vectorized I/O
    pub fn enableVectorizedIo(self: *Self) *Self {
        self.config.enable_vectorized_io = true;
        return self;
    }

    /// Build the runtime
    pub fn build(self: *Self) !*Runtime {
        return Runtime.init(self.allocator, self.config);
    }
};