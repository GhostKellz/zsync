//! Zsync v0.4.0 - Colorblind Async Runtime
//! The definitive async runtime for Zig following the latest async paradigm
//! True colorblind async: same code works across all execution models

const std = @import("std");
const builtin = @import("builtin");
const io_interface = @import("io_interface_v4.zig");
const blocking_io = @import("blocking_io_v4.zig");

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
        return switch (builtin.os.tag) {
            .linux => switch (builtin.cpu.arch) {
                .x86_64 => .green_threads, // io_uring available
                else => .thread_pool,
            },
            .windows => .thread_pool,   // IOCP available
            .macos => .green_threads,   // kqueue available  
            .wasi => .stackless,        // WASM environment
            else => .blocking,          // Fallback
        };
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
};

/// Runtime errors
pub const RuntimeError = error{
    AlreadyRunning,
    RuntimeShutdown,
    InvalidExecutionModel,
    OutOfMemory,
    SystemResourceExhausted,
    ConfigurationError,
};

/// Performance metrics for the runtime
pub const RuntimeMetrics = struct {
    tasks_spawned: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    tasks_completed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    futures_created: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    futures_cancelled: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    total_io_operations: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    average_latency_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    
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
    
    pub fn recordIoOperation(self: *RuntimeMetrics, latency_ns: u64) void {
        _ = self.total_io_operations.fetchAdd(1, .monotonic);
        // Simple moving average
        const current_avg = self.average_latency_ns.load(.monotonic);
        const new_avg = (current_avg + latency_ns) / 2;
        self.average_latency_ns.store(new_avg, .monotonic);
    }
};

/// Global runtime instance (singleton pattern)
var global_runtime: ?*Runtime = null;
var global_runtime_mutex = std.Thread.Mutex{};

/// Zsync v0.4.0 Modern Async Runtime
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
        thread_pool: void, // TODO: Implement in next phase
        green_threads: void, // TODO: Implement in next phase  
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
            .thread_pool => IoImplementation{ .thread_pool = {} }, // TODO
            .green_threads => IoImplementation{ .green_threads = {} }, // TODO
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
            .thread_pool => {}, // TODO
            .green_threads => {}, // TODO  
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
            .thread_pool => unreachable, // TODO
            .green_threads => unreachable, // TODO
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
            logInfo("🚀 Zsync v0.4.0 Runtime starting with {s} execution model", .{model_name});
        }
        
        const start_time = std.time.Instant.now() catch unreachable;
        
        // Execute main task with colorblind async
        const io = self.getIo();
        try self.executeTask(task_fn, args, io);
        
        const execution_time = std.time.Instant.now() catch unreachable - start_time;
        
        if (self.config.enable_debugging) {
            logInfo("✅ Runtime completed in {d}ms", .{@divTrunc(execution_time, std.time.ns_per_ms)});
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
    
    /// Spawn a new task (for future use with multiple tasks)
    pub fn spawn(self: *Self, comptime task_fn: anytype, args: anytype) !Future {
        _ = self;
        _ = task_fn;
        _ = args;
        // TODO: Implement task spawning for concurrent execution
        return error.NotImplemented;
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
        .thread_pool_threads = @max(1, std.Thread.getCpuCount() catch 4),
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
    const testing = std.testing;
    
    const TestTask = struct {
        fn task(io: Io) !void {
            const data = "Hello, Zsync v0.4.0!";
            var future = try io.write(data);
            defer future.destroy(testing.allocator);
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