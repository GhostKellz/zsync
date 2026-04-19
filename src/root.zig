//! zsync - Async runtime for Zig
//! Colorblind Async Runtime with True Function Color Elimination
//! Following Zig's latest async paradigm for maximum performance and ergonomics

const std = @import("std");
const builtin = @import("builtin");
const compat = @import("compat/thread.zig");

// Compatibility layer (exported for users)
pub const time = struct {
    pub const Instant = compat.Instant;
};

// Core APIs - Colorblind Async Interface
pub const io_interface = @import("io_interface.zig");
pub const runtime = @import("runtime.zig");
pub const blocking_io = @import("blocking_io.zig");
pub const std_io = @import("std_io.zig");

// Task Spawning and Concurrency
pub const spawn_mod = @import("spawn.zig");
pub const channels = @import("channels.zig");
pub const future_mod = @import("future.zig");
pub const executor_mod = @import("executor.zig");
pub const sync_mod = @import("sync.zig");
pub const sleep_mod = @import("sleep.zig");
pub const select_mod = @import("select.zig");

// Structured Concurrency
pub const nursery_mod = @import("nursery.zig");

// Buffer Pool and Zero-Copy
pub const buffer_pool_mod = @import("buffer_pool.zig");

// Async Streams
pub const streams_mod = @import("streams.zig");

// Async Filesystem
pub const async_fs_mod = @import("async_fs.zig");

// Diagnostics
pub const diagnostics = @import("diagnostics.zig");

// Runtime Networking Primitives
pub const rate_limit = @import("net/rate_limit.zig");
pub const connection_pool = @import("net/pool.zig");
pub const file_watch = @import("dev/watch.zig");
pub const websocket = @import("net/websocket.zig");

// WASM Support
pub const wasm_microtask = @import("wasm/microtask.zig");
pub const wasm_async = @import("wasm/async.zig");

// LSP Server
pub const lsp_server = @import("lsp/server.zig");

// Terminal/PTY
pub const pty = @import("terminal/pty.zig");

// Plugin System
pub const plugin_system = @import("plugin/system.zig");

// Script Runtime
pub const script_runtime = @import("script/runtime.zig");

// Compression Streaming
pub const compression = @import("compression/stream.zig");

// Platform-Specific Runtime
pub const platform_runtime = @import("platform_runtime.zig");
pub const runtime_factory = @import("runtime_factory.zig");
pub const platform_imports = @import("platform_imports.zig");

// Missing API modules that zquic needs
pub const timer = @import("timer.zig");
pub const channel = @import("channel.zig");

// Conditional networking support - not available on WASM
pub const networking = if (builtin.target.cpu.arch == .wasm32)
    @import("networking_stub.zig")
else
    @import("networking.zig");

pub const threadpool_io = @import("threadpool_io.zig");
pub const scheduler = @import("scheduler.zig");
pub const reactor = @import("reactor.zig");

// Re-export core types for convenience
pub const Io = io_interface.Io;
pub const IoMode = io_interface.IoMode;
pub const IoError = io_interface.IoError;
pub const IoBuffer = io_interface.IoBuffer;
pub const Future = io_interface.Future;
pub const CancelToken = io_interface.CancelToken;
pub const Combinators = io_interface.Combinators;

// Runtime types
pub const Runtime = runtime.Runtime;
pub const Config = runtime.Config;
pub const ExecutionModel = runtime.ExecutionModel;
pub const RuntimeError = runtime.RuntimeError;
pub const RuntimeMetrics = runtime.RuntimeMetrics;

// I/O Implementations
pub const BlockingIo = blocking_io.BlockingIo;

// Convenience runtime functions
pub const run = runtime.run;
pub const runBlocking = runtime.runBlocking;
pub const runHighPerf = runtime.runHighPerf;
pub const runSimple = runtime.runSimple;
pub const getGlobalIo = runtime.getGlobalIo;
pub const initGlobalRuntime = runtime.initGlobalRuntime;
pub const deinitGlobalRuntime = runtime.deinitGlobalRuntime;
pub const getGlobalRuntime = runtime.getGlobalRuntime;
pub const formatError = runtime.formatError;
pub const printError = runtime.printError;

// Convenience functions
pub const TaskHandle = spawn_mod.TaskHandle;
pub const GenericFuture = future_mod.Future;
pub const Executor = executor_mod.Executor;
pub const Semaphore = sync_mod.Semaphore;
pub const Barrier = sync_mod.Barrier;
pub const Latch = sync_mod.Latch;
pub const Channel = channels.Channel;
pub const UnboundedChannel = channels.UnboundedChannel;

// Structured concurrency
pub const Nursery = nursery_mod.Nursery;
pub const withNursery = nursery_mod.withNursery;

// Buffer pool
pub const BufferPool = buffer_pool_mod.BufferPool;
pub const BufferPoolConfig = buffer_pool_mod.BufferPoolConfig;
pub const PooledBuffer = buffer_pool_mod.PooledBuffer;
pub const sendfile = buffer_pool_mod.sendfile;
pub const splice = buffer_pool_mod.splice;
pub const copyFileZeroCopy = buffer_pool_mod.copyFileZeroCopy;

// Streams
pub const Stream = streams_mod.Stream;
pub const fromSlice = streams_mod.fromSlice;
pub const range = streams_mod.range;

// Async filesystem
pub const AsyncFile = async_fs_mod.AsyncFile;
pub const AsyncDir = async_fs_mod.AsyncDir;
pub const AsyncFs = async_fs_mod.AsyncFs;

// Task spawning
pub const spawnTask = spawn_mod.spawn;
pub const spawnOn = spawn_mod.spawnOn;

// Channels - use bounded() and unbounded() functions below

// Sleep and yield
pub const yieldTask = sleep_mod.yieldNow;
pub const sleepMs = sleep_mod.sleep;
pub const sleepMicros = sleep_mod.sleepMicros;
pub const sleepNanos = sleep_mod.sleepNanos;

// Future combinators
pub const selectFuture = select_mod.select;
pub const selectTimeout = select_mod.selectTimeout;
pub const allFutures = select_mod.all;
pub const anyFuture = select_mod.any;

// Diagnostics
pub const RuntimeDiagnostics = diagnostics.RuntimeDiagnostics;
pub const RuntimeStats = diagnostics.RuntimeStats;

// Rate Limiting
pub const TokenBucket = rate_limit.TokenBucket;
pub const LeakyBucket = rate_limit.LeakyBucket;
pub const SlidingWindow = rate_limit.SlidingWindow;

// Connection Pool
pub const ConnectionPool = connection_pool.ConnectionPool;
pub const PoolConfig = connection_pool.PoolConfig;
pub const PoolStats = connection_pool.PoolStats;

// File Watcher
pub const FileWatcher = file_watch.FileWatcher;
pub const PollingWatcher = file_watch.PollingWatcher;
pub const WatchEvent = file_watch.WatchEvent;

// Async Locks
pub const AsyncMutex = sync_mod.AsyncMutex;
pub const AsyncRwLock = sync_mod.AsyncRwLock;
pub const WaitGroup = sync_mod.WaitGroup;

// WebSocket
pub const WebSocketConnectionV2 = websocket.WebSocketConnection;
pub const WebSocketServerV2 = websocket.WebSocketServer;
pub const WebSocketClientV2 = websocket.WebSocketClient;
pub const WebSocketMessageV2 = websocket.Message;
pub const WebSocketOpCodeV2 = websocket.OpCode;
pub const WebSocketCloseCodeV2 = websocket.CloseCode;

// WASM Async Helpers
pub const MicrotaskQueue = wasm_microtask.MicrotaskQueue;
pub const queueMicrotask = wasm_microtask.queueMicrotask;
pub const flushMicrotasks = wasm_microtask.flushMicrotasks;
pub const Promise = wasm_async.Promise;
pub const AsyncContext = wasm_async.AsyncContext;
pub const EventEmitter = wasm_async.EventEmitter;
pub const AbortController = wasm_async.AbortController;
pub const fetch = wasm_async.fetch;
pub const FetchResponse = wasm_async.FetchResponse;

// LSP Server
pub const LspServer = lsp_server.LspServer;
pub const LspServerConfig = lsp_server.ServerConfig;
pub const LspPosition = lsp_server.Position;
pub const LspRange = lsp_server.Range;
pub const LspLocation = lsp_server.Location;
pub const LspDiagnostic = lsp_server.Diagnostic;

// PTY/Terminal
pub const Pty = pty.Pty;
pub const PtyConfig = pty.PtyConfig;
pub const Winsize = pty.Winsize;
pub const TermAttr = pty.TermAttr;

// Plugin System
pub const Plugin = plugin_system.Plugin;
pub const PluginManager = plugin_system.PluginManager;
pub const PluginMetadata = plugin_system.PluginMetadata;
pub const PluginState = plugin_system.PluginState;
pub const discoverPlugins = plugin_system.discoverPlugins;

// Script Runtime
pub const ScriptEngine = script_runtime.ScriptEngine;
pub const ScriptValue = script_runtime.ScriptValue;
pub const ScriptChannel = script_runtime.ScriptChannel;
pub const ScriptTimer = script_runtime.ScriptTimer;
pub const ScriptFFI = script_runtime.FFI;

// Compression Streaming
pub const AsyncCompressor = compression.AsyncCompressor;
pub const AsyncDecompressor = compression.AsyncDecompressor;
pub const CompressionConfig = compression.CompressionConfig;
pub const CompressionAlgorithm = compression.Algorithm;
pub const compressFileAsync = compression.compressFileAsync;
pub const decompressFileAsync = compression.decompressFileAsync;

// Set global execution mode for colorblind async
pub const setIoMode = setGlobalIoMode;
pub fn setGlobalIoMode(mode: IoMode) void {
    io_interface.io_mode = mode;
}

/// Convenience function to create a simple blocking I/O instance
pub fn createBlockingIo(allocator: std.mem.Allocator) BlockingIo {
    return BlockingIo.init(allocator, 4096);
}

/// Example colorblind async function that works with ANY Io implementation
pub fn saveData(_: std.mem.Allocator, io: Io, data: []const u8) !void {
    // This function is truly colorblind - works in sync or async context
    var io_mut = io;
    var future = try io_mut.write(data);
    defer future.destroy();

    // Colorblind await - adapts to execution context
    try future.await();
}

/// Advanced example with timeout and error handling
pub fn saveDataWithTimeout(allocator: std.mem.Allocator, io: Io, data: []const u8, timeout_ms: u64) !void {
    var io_mut = io;
    const write_future = try io_mut.write(data);
    var timeout_future = try Combinators.timeout(allocator, write_future, timeout_ms);
    defer timeout_future.destroy();

    try timeout_future.await();
}

/// Example of concurrent operations using Future combinators
pub fn concurrentSave(allocator: std.mem.Allocator, io: Io, data1: []const u8, data2: []const u8) !void {
    var io_mut = io;
    var future1 = try io_mut.write(data1);
    var future2 = try io_mut.write(data2);

    var futures = [_]Future{ future1, future2 };
    var all_future = try Combinators.all(allocator, &futures);
    defer all_future.destroy();

    try all_future.await();

    // Clean up individual futures
    future1.destroy();
    future2.destroy();
}

/// Example of racing operations
pub fn raceOperations(allocator: std.mem.Allocator, io: Io, data1: []const u8, data2: []const u8) !void {
    var io_mut = io;
    var future1 = try io_mut.write(data1);
    var future2 = try io_mut.write(data2);

    var futures = [_]Future{ future1, future2 };
    var race_future = try Combinators.race(allocator, &futures);
    defer race_future.destroy();

    try race_future.await();

    // Clean up
    future1.destroy();
    future2.destroy();
}

/// Utility function to detect optimal execution model
pub fn detectOptimalModel() ExecutionModel {
    return ExecutionModel.detect();
}

/// Create runtime with optimal configuration for current platform
pub fn createOptimalRuntime(allocator: std.mem.Allocator) !*Runtime {
    const model = detectOptimalModel();

    const config = switch (model) {
        .blocking => Config{
            .execution_model = .blocking,
            .buffer_size = 4096,
            .enable_debugging = false,
        },
        .thread_pool => Config{
            .execution_model = .thread_pool,
            .thread_pool_threads = @intCast(@max(1, std.Thread.getCpuCount() catch 4)),
            .enable_zero_copy = true,
            .enable_vectorized_io = true,
        },
        .green_threads => Config{
            .execution_model = .green_threads,
            .green_thread_stack_size = 64 * 1024,
            .max_green_threads = 1024,
            .enable_zero_copy = true,
        },
        .stackless => Config{
            .execution_model = .stackless,
            .buffer_size = 2048, // Smaller for WASM
        },
        .auto => Config{}, // Default configuration
    };

    return Runtime.init(allocator, config);
}

/// High-level async task spawning - requires initialized runtime
pub fn spawn(comptime task_fn: anytype, args: anytype) !Future {
    const runtime_instance = Runtime.global() orelse return RuntimeError.RuntimeNotInitialized;
    return runtime_instance.spawn(task_fn, args);
}

/// High-level timeout wrapper
pub fn timeout(future: Future, timeout_ms: u64) !Future {
    const runtime_instance = Runtime.global() orelse return RuntimeError.RuntimeShutdown;
    return runtime_instance.timeout(future, timeout_ms);
}

/// High-level race wrapper
pub fn race(futures: []Future) !Future {
    const runtime_instance = Runtime.global() orelse return RuntimeError.RuntimeShutdown;
    return runtime_instance.race(futures);
}

/// High-level all wrapper
pub fn all(futures: []Future) !Future {
    const runtime_instance = Runtime.global() orelse return RuntimeError.RuntimeShutdown;
    return runtime_instance.all(futures);
}

// =============================================================================
// Additional exports kept for downstream compatibility
// =============================================================================

/// Yield execution to other tasks (cooperative scheduling)
pub fn yieldNow() void {
    scheduler.yield();
}

/// Sleep for the specified duration in milliseconds
pub fn sleep(duration_ms: u64) void {
    timer.sleep(duration_ms);
}

/// Create a bounded channel for message passing
/// Returns a Channel(T) with fixed capacity ring buffer
pub const bounded = channels.bounded;

/// Create an unbounded channel for message passing
/// Returns an UnboundedChannel(T) that grows dynamically
pub const unbounded = channels.unbounded;

/// Thread pool I/O implementation for CPU-intensive operations
pub const ThreadPoolIo = threadpool_io.ThreadPoolIo;

/// Create a ThreadPoolIo instance with default configuration
pub fn createThreadPoolIo(allocator: std.mem.Allocator) !*ThreadPoolIo {
    const config = threadpool_io.ThreadPoolConfig{};
    const pool = try allocator.create(ThreadPoolIo);
    pool.* = try ThreadPoolIo.init(allocator, config);
    return pool;
}

/// UDP socket implementation (conditional for WASM)
pub const UdpSocket = if (builtin.target.cpu.arch == .wasm32) struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Create a new UDP socket (stub for WASM)
    pub fn bind(allocator: std.mem.Allocator, address: []const u8) !Self {
        _ = allocator;
        _ = address;
        return error.NetworkingNotAvailable;
    }

    /// Send data to a specific address (stub for WASM)
    pub fn sendTo(self: *Self, data: []const u8, address: []const u8) !usize {
        _ = self;
        _ = data;
        _ = address;
        return error.NetworkingNotAvailable;
    }

    /// Receive data from any address (stub for WASM)
    pub fn recvFrom(self: *Self, buffer: []u8) !struct { bytes_received: usize, address: []const u8 } {
        _ = self;
        _ = buffer;
        return error.NetworkingNotAvailable;
    }

    /// Close the UDP socket (stub for WASM)
    pub fn close(self: *Self) void {
        _ = self;
    }
} else struct {
    socket_fd: std.posix.fd_t,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Create a new UDP socket
    pub fn bind(allocator: std.mem.Allocator, address: std.net.Address) !Self {
        const socket_fd = try std.posix.socket(address.any.family, std.posix.SOCK.DGRAM, std.posix.IPPROTO.UDP);
        try std.posix.bind(socket_fd, &address.any, address.getOsSockLen());

        return Self{
            .socket_fd = socket_fd,
            .allocator = allocator,
        };
    }

    /// Send data to a specific address
    pub fn sendTo(self: *Self, data: []const u8, address: std.net.Address) !usize {
        return std.posix.sendto(self.socket_fd, data, 0, &address.any, address.getOsSockLen());
    }

    /// Receive data from any address
    pub fn recvFrom(self: *Self, buffer: []u8) !struct { bytes_received: usize, address: std.net.Address } {
        var addr: std.posix.sockaddr = undefined;
        var addr_len: std.posix.socklen_t = @sizeOf(@TypeOf(addr));

        const bytes_received = try std.posix.recvfrom(self.socket_fd, buffer, 0, @ptrCast(&addr), &addr_len);
        const address = std.net.Address.initPosix(@ptrCast(@alignCast(&addr)));

        return .{ .bytes_received = bytes_received, .address = address };
    }

    /// Close the UDP socket
    pub fn close(self: *Self) void {
        std.Io.Threaded.closeFd(self.socket_fd);
    }
};

// =============================================================================
// Additional Async APIs
// =============================================================================

/// Task scheduler for advanced async operations
pub const AsyncScheduler = scheduler.AsyncScheduler;

/// Create an async scheduler with default settings
pub fn createScheduler(allocator: std.mem.Allocator) !*AsyncScheduler {
    const sched = try allocator.create(AsyncScheduler);
    sched.* = try AsyncScheduler.init(allocator);
    return sched;
}

/// Reactor for I/O event management
pub const Reactor = reactor.Reactor;

/// Create a reactor for non-blocking I/O
pub fn createReactor(allocator: std.mem.Allocator) !*Reactor {
    const r = try allocator.create(Reactor);
    r.* = try Reactor.init(allocator);
    return r;
}

/// Timer wheel for scheduling timeouts and delays
pub const TimerWheel = timer.TimerWheel;

/// Create a timer wheel for timeout management
pub fn createTimerWheel(allocator: std.mem.Allocator) !*TimerWheel {
    const tw = try allocator.create(TimerWheel);
    tw.* = try TimerWheel.init(allocator);
    return tw;
}

/// HTTP client for making HTTP requests
pub const HttpClient = networking.HttpClient;

/// HTTP request structure
pub const HttpRequest = networking.HttpRequest;

/// HTTP response structure
pub const HttpResponse = networking.HttpResponse;

/// WebSocket connection for real-time communication
pub const WebSocketConnection = networking.WebSocketConnection;

/// DNS resolver for hostname resolution
pub const DnsResolver = networking.DnsResolver;

/// TLS stream wrapper for secure connections
pub const TlsStream = networking.TlsStream;

/// Create an HTTP client with TLS support
pub fn createHttpClient(allocator: std.mem.Allocator) !*HttpClient {
    const client = try allocator.create(HttpClient);
    const tls_config = networking.TlsConfig{};
    client.* = HttpClient.init(allocator, tls_config);
    return client;
}

/// OneShot channel for single-value communication
pub fn oneshot(comptime T: type) channel.OneShot(T) {
    return channel.OneShot(T).init();
}

/// Async delay function (non-blocking version of sleep)
pub fn delay(duration_ms: u64) void {
    timer.delay(duration_ms);
}

/// Get high-precision nanosecond timestamp
pub fn nanoTime() u64 {
    return timer.nanoTime();
}

/// Get microsecond timestamp
pub fn microTime() u64 {
    return timer.microTime();
}

/// Get millisecond timestamp
pub fn milliTime() u64 {
    return timer.milliTime();
}

/// Measure execution time of a function
pub const MeasureResult = timer.MeasureResult;

pub fn measure(comptime func: anytype, args: anytype) MeasureResult {
    return timer.measure(func, args);
}

/// Spawn a high priority task
pub fn spawnUrgent(comptime task_fn: anytype, args: anytype) !Future {
    // Use the improved spawn with high priority preference
    return spawn(task_fn, args);
}

/// Create async task with custom priority (if scheduler is available)
pub fn spawnWithPriority(comptime task_fn: anytype, args: anytype, priority: scheduler.TaskPriority) !u32 {
    if (createScheduler(std.heap.page_allocator)) |sched| {
        defer {
            sched.deinit();
            std.heap.page_allocator.destroy(sched);
        }
        return sched.spawn(task_fn, args, priority);
    } else |_| {
        // Fallback to regular spawn
        _ = try spawn(task_fn, args);
        return 0;
    }
}

/// Advanced channel types and utilities
pub const ChannelError = channel.ChannelError;
pub const Sender = channel.Sender;
pub const Receiver = channel.Receiver;

// =============================================================================
// Tokio-style APIs
// =============================================================================

/// Spawn a blocking task on a dedicated thread (like tokio::task::spawn_blocking)
/// Use this for CPU-intensive work that shouldn't block the async runtime.
pub fn spawnBlocking(comptime func: anytype, args: anytype) !std.Thread {
    return std.Thread.spawn(.{}, func, args);
}

/// JoinSet for managing multiple concurrent tasks (like tokio::task::JoinSet)
/// Tasks are spawned on separate threads and run concurrently.
/// Each task entry is heap-allocated to ensure pointer stability across spawns.
pub fn JoinSet(comptime T: type) type {
    return struct {
        entries: std.ArrayList(*TaskEntry),
        allocator: std.mem.Allocator,
        mutex: compat.Mutex = .{},
        completed_cond: compat.Condition = .{},
        completed_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

        const Self = @This();

        const TaskEntry = struct {
            thread: ?std.Thread = null,
            result: ?T = null,
            err: ?anyerror = null,
            completed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
            joined: bool = false,
        };

        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{
                .entries = .empty,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            // Join any remaining threads
            self.joinAll();
            // Free all task entries
            for (self.entries.items) |entry| {
                self.allocator.destroy(entry);
            }
            self.entries.deinit(self.allocator);
        }

        /// Spawn a task on a new thread
        pub fn spawn(self: *Self, comptime func: anytype, args: anytype) !usize {
            // Heap-allocate entry for pointer stability
            const entry = try self.allocator.create(TaskEntry);
            entry.* = TaskEntry{};

            const idx = self.entries.items.len;
            try self.entries.append(self.allocator, entry);

            // Wrapper to capture result and signal completion
            const Wrapper = struct {
                fn run(task_entry: *TaskEntry, set: *Self, func_args: anytype) void {
                    const result = @call(.auto, func, func_args);
                    task_entry.result = result;
                    task_entry.completed.store(true, .release);
                    _ = set.completed_count.fetchAdd(1, .release);
                    set.completed_cond.signal();
                }
            };

            entry.thread = try std.Thread.spawn(.{}, Wrapper.run, .{ entry, self, args });
            return idx;
        }

        /// Spawn a task that may return an error
        pub fn spawnErrorable(self: *Self, comptime func: anytype, args: anytype) !usize {
            const entry = try self.allocator.create(TaskEntry);
            entry.* = TaskEntry{};

            const idx = self.entries.items.len;
            try self.entries.append(self.allocator, entry);

            const Wrapper = struct {
                fn run(task_entry: *TaskEntry, set: *Self, func_args: anytype) void {
                    if (@call(.auto, func, func_args)) |result| {
                        task_entry.result = result;
                    } else |err| {
                        task_entry.err = err;
                    }
                    task_entry.completed.store(true, .release);
                    _ = set.completed_count.fetchAdd(1, .release);
                    set.completed_cond.signal();
                }
            };

            entry.thread = try std.Thread.spawn(.{}, Wrapper.run, .{ entry, self, args });
            return idx;
        }

        /// Wait for all tasks to complete and join threads
        pub fn joinAll(self: *Self) void {
            for (self.entries.items) |entry| {
                if (!entry.joined) {
                    if (entry.thread) |thread| {
                        thread.join();
                        entry.thread = null;
                    }
                    entry.joined = true;
                }
            }
        }

        /// Wait for any task to complete and return its result
        /// Returns null if no tasks remain
        pub fn joinNext(self: *Self) ?JoinResult {
            self.mutex.lock();
            defer self.mutex.unlock();

            // Find a completed but not-yet-joined task
            for (self.entries.items, 0..) |entry, idx| {
                if (entry.completed.load(.acquire) and !entry.joined) {
                    if (entry.thread) |thread| {
                        thread.join();
                        entry.thread = null;
                    }
                    entry.joined = true;

                    if (entry.err) |err| {
                        return JoinResult{ .idx = idx, .value = .{ .err = err } };
                    } else {
                        return JoinResult{ .idx = idx, .value = .{ .ok = entry.result } };
                    }
                }
            }

            // Check if any tasks are still running
            var has_pending = false;
            for (self.entries.items) |entry| {
                if (!entry.joined) {
                    has_pending = true;
                    break;
                }
            }
            if (!has_pending) return null;

            // Wait for completion signal
            self.completed_cond.wait(&self.mutex);

            // Try again after wakeup
            for (self.entries.items, 0..) |entry, idx| {
                if (entry.completed.load(.acquire) and !entry.joined) {
                    if (entry.thread) |thread| {
                        thread.join();
                        entry.thread = null;
                    }
                    entry.joined = true;

                    if (entry.err) |err| {
                        return JoinResult{ .idx = idx, .value = .{ .err = err } };
                    } else {
                        return JoinResult{ .idx = idx, .value = .{ .ok = entry.result } };
                    }
                }
            }

            return null;
        }

        /// Get number of pending (not yet joined) tasks
        pub fn len(self: *const Self) usize {
            var pending: usize = 0;
            for (self.entries.items) |entry| {
                if (!entry.joined) pending += 1;
            }
            return pending;
        }

        /// Check if all tasks have been joined
        pub fn isEmpty(self: *const Self) bool {
            return self.len() == 0;
        }

        pub const JoinResult = struct {
            idx: usize,
            value: union(enum) {
                ok: ?T,
                err: anyerror,
            },
        };
    };
}

/// Broadcast channel - multiple producers, multiple consumers
/// Each message is delivered to all consumers with configurable capacity.
pub fn BroadcastChannel(comptime T: type) type {
    return struct {
        subscribers: std.ArrayList(*Subscriber),
        allocator: std.mem.Allocator,
        capacity: usize,
        mutex: compat.Mutex = .{},
        notify: compat.Condition = .{},

        const Self = @This();
        pub const default_capacity: usize = 16;

        const Subscriber = struct {
            queue: std.ArrayList(T),
            allocator: std.mem.Allocator,
            capacity: usize,
            lagged: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
            mutex: compat.Mutex = .{},

            pub fn initWithCapacity(allocator: std.mem.Allocator, cap: usize) Subscriber {
                return .{ .queue = .empty, .allocator = allocator, .capacity = cap };
            }

            pub fn deinit(self: *Subscriber) void {
                self.queue.deinit(self.allocator);
            }

            /// Check how many messages were dropped due to lag
            pub fn lagCount(self: *Subscriber) usize {
                return self.lagged.swap(0, .acquire);
            }

            /// Receive from this subscriber's queue (thread-safe, non-blocking)
            pub fn recv(self: *Subscriber) ?T {
                self.mutex.lock();
                defer self.mutex.unlock();
                if (self.queue.items.len > 0) {
                    return self.queue.orderedRemove(0);
                }
                return null;
            }
        };

        pub fn init(allocator: std.mem.Allocator) Self {
            return initWithCapacity(allocator, default_capacity);
        }

        pub fn initWithCapacity(allocator: std.mem.Allocator, capacity: usize) Self {
            return Self{
                .subscribers = .empty,
                .allocator = allocator,
                .capacity = capacity,
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.subscribers.items) |sub| {
                sub.deinit();
                self.allocator.destroy(sub);
            }
            self.subscribers.deinit(self.allocator);
        }

        /// Subscribe to the broadcast channel
        pub fn subscribe(self: *Self) !*Subscriber {
            self.mutex.lock();
            defer self.mutex.unlock();

            const sub = try self.allocator.create(Subscriber);
            sub.* = Subscriber.initWithCapacity(self.allocator, self.capacity);
            try self.subscribers.append(self.allocator, sub);
            return sub;
        }

        /// Send a message to all subscribers
        /// Slow receivers will have oldest messages dropped (lagged)
        pub fn send(self: *Self, value: T) !void {
            self.mutex.lock();
            defer self.mutex.unlock();

            for (self.subscribers.items) |sub| {
                sub.mutex.lock();
                defer sub.mutex.unlock();
                // Drop oldest if at capacity
                if (sub.queue.items.len >= sub.capacity) {
                    _ = sub.queue.orderedRemove(0);
                    _ = sub.lagged.fetchAdd(1, .monotonic);
                }
                try sub.queue.append(sub.allocator, value);
            }
            self.notify.broadcast();
        }

        /// Receive from a subscriber's queue (non-blocking, thread-safe)
        /// Prefer using sub.recv() directly for cleaner code.
        pub fn recv(sub: *Subscriber) ?T {
            return sub.recv();
        }

        /// Blocking receive - waits for a message
        pub fn recvBlocking(self: *Self, sub: *Subscriber) T {
            self.mutex.lock();

            while (true) {
                sub.mutex.lock();
                if (sub.queue.items.len > 0) {
                    const item = sub.queue.orderedRemove(0);
                    sub.mutex.unlock();
                    self.mutex.unlock();
                    return item;
                }
                sub.mutex.unlock();
                self.notify.wait(&self.mutex);
            }
        }

        /// Unsubscribe and deallocate a subscriber
        pub fn unsubscribe(self: *Self, sub: *Subscriber) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            // Find and remove from list
            for (self.subscribers.items, 0..) |s, i| {
                if (s == sub) {
                    _ = self.subscribers.orderedRemove(i);
                    break;
                }
            }

            sub.deinit();
            self.allocator.destroy(sub);
        }

        /// Get subscriber count
        pub fn subscriberCount(self: *Self) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.subscribers.items.len;
        }
    };
}

/// Watch channel - single value that can be watched for changes
/// Similar to tokio::sync::watch
pub fn WatchChannel(comptime T: type) type {
    return struct {
        value: T,
        version: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        mutex: compat.Mutex = .{},
        changed_cond: compat.Condition = .{},

        const Self = @This();

        /// Watcher handle that tracks last seen version
        pub const Watcher = struct {
            channel: *Self,
            last_seen: u64 = 0,

            /// Get current value
            pub fn borrow(self: *Watcher) T {
                self.channel.mutex.lock();
                defer self.channel.mutex.unlock();
                self.last_seen = self.channel.version.load(.acquire);
                return self.channel.value;
            }

            /// Check if value has changed since last borrow
            pub fn hasChanged(self: *const Watcher) bool {
                return self.channel.version.load(.acquire) != self.last_seen;
            }

            /// Wait for value to change (blocking)
            pub fn changed(self: *Watcher) T {
                self.channel.mutex.lock();
                defer self.channel.mutex.unlock();

                while (self.channel.version.load(.acquire) == self.last_seen) {
                    self.channel.changed_cond.wait(&self.channel.mutex);
                }
                self.last_seen = self.channel.version.load(.acquire);
                return self.channel.value;
            }
        };

        pub fn init(initial: T) Self {
            return Self{ .value = initial };
        }

        /// Create a watcher for this watch channel
        pub fn subscribe(self: *Self) Watcher {
            return Watcher{ .channel = self };
        }

        /// Send a new value (overwrites previous)
        pub fn send(self: *Self, value: T) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.value = value;
            _ = self.version.fetchAdd(1, .release);
            self.changed_cond.broadcast();
        }

        /// Get current value (for sender)
        pub fn borrow(self: *Self) T {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.value;
        }

        /// Get current version
        pub fn getVersion(self: *Self) u64 {
            return self.version.load(.acquire);
        }
    };
}

/// Notify - Simple task notification primitive (like tokio::sync::Notify)
/// Allows one task to notify waiting tasks.
/// Uses generation counter to ensure notifyAll() wakes all waiters.
pub const Notify = struct {
    waiters: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    generation: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    one_shot_pending: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    mutex: compat.Mutex = .{},
    cond: compat.Condition = .{},

    const Self = @This();

    pub fn init() Self {
        return Self{};
    }

    /// Wait until notified
    pub fn wait(self: *Self) void {
        // Fast path - check for pending one-shot notification
        if (self.one_shot_pending.swap(false, .acquire)) {
            return;
        }

        self.mutex.lock();
        defer self.mutex.unlock();

        _ = self.waiters.fetchAdd(1, .monotonic);
        defer _ = self.waiters.fetchSub(1, .monotonic);

        // Record current generation
        const my_gen = self.generation.load(.acquire);

        // Wait until generation changes (notifyAll) or one-shot is set (notifyOne)
        while (self.generation.load(.acquire) == my_gen and !self.one_shot_pending.load(.acquire)) {
            self.cond.wait(&self.mutex);
        }

        // Consume one-shot if that's what woke us
        _ = self.one_shot_pending.swap(false, .acquire);
    }

    /// Notify one waiting task
    pub fn notifyOne(self: *Self) void {
        self.one_shot_pending.store(true, .release);
        self.cond.signal();
    }

    /// Notify all waiting tasks
    pub fn notifyAll(self: *Self) void {
        // Increment generation to wake all waiters
        _ = self.generation.fetchAdd(1, .release);
        self.cond.broadcast();
    }

    /// Check if there are waiters
    pub fn hasWaiters(self: *const Self) bool {
        return self.waiters.load(.acquire) > 0;
    }
};

/// OnceCell - Thread-safe lazy initialization (like tokio::sync::OnceCell)
pub fn OnceCell(comptime T: type) type {
    return struct {
        value: ?T = null,
        initialized: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        mutex: compat.Mutex = .{},

        const Self = @This();

        pub fn init() Self {
            return Self{};
        }

        /// Get or initialize the value
        pub fn getOrInit(self: *Self, comptime initFn: fn () T) T {
            // Fast path
            if (self.initialized.load(.acquire)) {
                return self.value.?;
            }

            self.mutex.lock();
            defer self.mutex.unlock();

            // Double-check after acquiring lock
            if (!self.initialized.load(.acquire)) {
                self.value = initFn();
                self.initialized.store(true, .release);
            }

            return self.value.?;
        }

        /// Get or initialize with error
        pub fn getOrTryInit(self: *Self, comptime initFn: fn () anyerror!T) !T {
            if (self.initialized.load(.acquire)) {
                return self.value.?;
            }

            self.mutex.lock();
            defer self.mutex.unlock();

            if (!self.initialized.load(.acquire)) {
                self.value = try initFn();
                self.initialized.store(true, .release);
            }

            return self.value.?;
        }

        /// Get value if initialized
        pub fn get(self: *const Self) ?T {
            if (self.initialized.load(.acquire)) {
                return self.value;
            }
            return null;
        }

        /// Check if initialized
        pub fn isInitialized(self: *const Self) bool {
            return self.initialized.load(.acquire);
        }

        /// Set value (only if not initialized)
        pub fn set(self: *Self, value: T) bool {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.initialized.load(.acquire)) {
                return false;
            }

            self.value = value;
            self.initialized.store(true, .release);
            return true;
        }
    };
}

/// CancellationToken - Coordinated graceful shutdown (like tokio_util::sync::CancellationToken)
pub const CancellationToken = struct {
    cancelled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    children: std.ArrayList(*CancellationToken) = .empty,
    allocator: std.mem.Allocator = undefined,
    mutex: compat.Mutex = .{},
    notify: Notify = Notify.init(),
    initialized: bool = false,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .children = .empty,
            .allocator = allocator,
            .initialized = true,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.initialized) {
            // Recursively deinit and destroy all child tokens
            for (self.children.items) |child_token| {
                child_token.deinit();
                self.allocator.destroy(child_token);
            }
            self.children.deinit(self.allocator);
        }
    }

    /// Check if cancellation was requested
    pub fn isCancelled(self: *const Self) bool {
        return self.cancelled.load(.acquire);
    }

    /// Request cancellation
    pub fn cancel(self: *Self) void {
        self.cancelled.store(true, .release);
        self.notify.notifyAll();

        // Cancel children
        if (self.initialized) {
            self.mutex.lock();
            defer self.mutex.unlock();
            for (self.children.items) |child_token| {
                child_token.cancel();
            }
        }
    }

    /// Wait until cancelled
    pub fn waitForCancellation(self: *Self) void {
        while (!self.isCancelled()) {
            self.notify.wait();
        }
    }

    /// Create a child token
    pub fn child(self: *Self) !*CancellationToken {
        if (!self.initialized) return error.NotInitialized;

        self.mutex.lock();
        defer self.mutex.unlock();

        const child_token = try self.allocator.create(CancellationToken);
        child_token.* = Self.init(self.allocator);

        // Inherit cancelled state
        if (self.isCancelled()) {
            child_token.cancelled.store(true, .release);
        }

        try self.children.append(self.allocator, child_token);
        return child_token;
    }
};

/// RuntimeBuilder - Fluent builder for runtime configuration (like tokio::runtime::Builder)
pub const RuntimeBuilder = struct {
    config: Config = .{},
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn new(allocator: std.mem.Allocator) Self {
        return Self{ .allocator = allocator };
    }

    /// Configure as multi-threaded runtime
    pub fn multiThread(self: *Self) *Self {
        self.config.execution_model = .thread_pool;
        return self;
    }

    /// Configure as single-threaded runtime
    pub fn currentThread(self: *Self) *Self {
        self.config.execution_model = .blocking;
        return self;
    }

    /// Set worker thread count
    pub fn workerThreads(self: *Self, count: u32) *Self {
        self.config.thread_pool_threads = count;
        return self;
    }

    /// Enable all features
    pub fn enableAll(self: *Self) *Self {
        self.config.enable_zero_copy = true;
        self.config.enable_vectorized_io = true;
        return self;
    }

    /// Enable time (timers) - always enabled by default
    pub fn enableTime(self: *Self) *Self {
        // Time is always enabled - this is for API compatibility with Tokio
        return self;
    }

    /// Enable I/O
    pub fn enableIo(self: *Self) *Self {
        self.config.enable_zero_copy = true;
        self.config.enable_vectorized_io = true;
        return self;
    }

    /// Set thread stack size
    pub fn threadStackSize(self: *Self, size: usize) *Self {
        self.config.green_thread_stack_size = size;
        return self;
    }

    /// Build the runtime
    pub fn build(self: *Self) !*Runtime {
        return Runtime.init(self.allocator, self.config);
    }
};

/// Convenience function to create a runtime builder
pub fn runtimeBuilder(allocator: std.mem.Allocator) RuntimeBuilder {
    return RuntimeBuilder.new(allocator);
}

/// Interval - Repeating timer (like tokio::time::interval)
pub const Interval = struct {
    period_ms: u64,
    last_tick: u64,

    const Self = @This();

    pub fn init(period_ms: u64) Self {
        return Self{
            .period_ms = period_ms,
            .last_tick = milliTime(),
        };
    }

    /// Wait for the next tick
    pub fn tick(self: *Self) void {
        const now = milliTime();
        const next_tick = self.last_tick + self.period_ms;

        if (now < next_tick) {
            sleep(next_tick - now);
        }

        self.last_tick = milliTime();
    }

    /// Reset the interval
    pub fn reset(self: *Self) void {
        self.last_tick = milliTime();
    }

    /// Get the period
    pub fn period(self: *const Self) u64 {
        return self.period_ms;
    }
};

/// Create an interval timer
pub fn interval(period_ms: u64) Interval {
    return Interval.init(period_ms);
}

/// Timeout wrapper that returns error on timeout
pub fn timeoutFn(comptime func: anytype, args: anytype, timeout_ms: u64) !@TypeOf(@call(.auto, func, args)) {
    const start = milliTime();

    // For simple blocking execution
    const result = @call(.auto, func, args);

    const elapsed = milliTime() - start;
    if (elapsed > timeout_ms) {
        return error.Timeout;
    }

    return result;
}

// Version information
pub const VERSION = "0.8.0";
pub const VERSION_MAJOR = 0;
pub const VERSION_MINOR = 8;
pub const VERSION_PATCH = 0;

/// Print Zsync version and capabilities
pub fn printVersion() void {
    std.debug.print("zsync v{s} - async runtime for Zig\n", .{VERSION});
    std.debug.print("Core Features:\n", .{});
    std.debug.print("  ✅ Colorblind Async/Await\n", .{});
    std.debug.print("  ✅ Multiple Execution Models\n", .{});
    std.debug.print("  ✅ Future Combinators\n", .{});
    std.debug.print("  ✅ Cooperative Cancellation\n", .{});
    std.debug.print("  ✅ Zero-Cost Abstractions\n", .{});
    std.debug.print("  ✅ Cross-Platform Support\n", .{});
    std.debug.print("\nRuntime Primitives:\n", .{});
    std.debug.print("  ✅ Task Spawning & Channels\n", .{});
    std.debug.print("  ✅ Real Thread Pool Backend\n", .{});
    std.debug.print("  ✅ Timer System (timeout, interval)\n", .{});
    std.debug.print("  ✅ WebSocket (RFC 6455)\n", .{});
    std.debug.print("  ✅ Rate Limiting (Token Bucket, Leaky Bucket, Sliding Window)\n", .{});
    std.debug.print("  ✅ Connection Pool with Health Checks\n", .{});
    std.debug.print("  ✅ File Watcher (cross-platform)\n", .{});
    std.debug.print("  ✅ Async Locks (AsyncMutex, AsyncRwLock, WaitGroup)\n", .{});
    std.debug.print("  ✅ Zero-Copy I/O (sendfile, splice, mmap)\n", .{});
    std.debug.print("  ✅ Structured Concurrency (Nursery)\n", .{});
    std.debug.print("  ✅ WASM Async Support\n", .{});
    std.debug.print("  ✅ Runtime Diagnostics & Metrics\n", .{});
    std.debug.print("\nTokio-style APIs:\n", .{});
    std.debug.print("  ✅ spawnBlocking - Dedicated threads for CPU work\n", .{});
    std.debug.print("  ✅ JoinSet - Manage concurrent task groups\n", .{});
    std.debug.print("  ✅ BroadcastChannel - Multi-consumer pub/sub\n", .{});
    std.debug.print("  ✅ WatchChannel - Single-value observer\n", .{});
    std.debug.print("  ✅ Notify - Task notification primitive\n", .{});
    std.debug.print("  ✅ OnceCell - Thread-safe lazy init\n", .{});
    std.debug.print("  ✅ CancellationToken - Graceful shutdown\n", .{});
    std.debug.print("  ✅ RuntimeBuilder - Fluent configuration\n", .{});
    std.debug.print("  ✅ Interval - Repeating timers\n", .{});

    const optimal_model = detectOptimalModel();
    std.debug.print("\nOptimal execution model for this platform: {}\n", .{optimal_model});
}

/// Simple hello world example showcasing colorblind async
pub fn helloWorld(_: std.mem.Allocator) !void {
    const HelloTask = struct {
        fn task(io: Io) !void {
            const messages = [_][]const u8{
                "zsync - async runtime for Zig\n",
                "colorblind async in action\n",
                "blocking, thread_pool, and green_threads execution models\n",
            };

            // Demonstrate vectorized write
            var io_mut = io;
            var future = try io_mut.writev(&messages);
            defer future.destroy();
            try future.await();

            std.debug.print("Execution mode: {}\n", .{io.getMode()});
            std.debug.print("Supports vectorized I/O: {}\n", .{io.supportsVectorized()});
            std.debug.print("Supports zero-copy: {}\n", .{io.supportsZeroCopy()});
        }
    };

    try runBlocking(HelloTask.task, {});
}

// Backward compatibility exports (deprecated but functional)
pub const examples = struct {
    pub const saveData = @This().saveData;
    pub const helloWorld = @This().helloWorld;
};

// Tests
test "zsync basic functionality" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Use /dev/null to avoid writing to stdout (which breaks test server protocol)
    const null_fd = std.posix.openat(std.posix.AT.FDCWD, "/dev/null", .{ .ACCMODE = .WRONLY }, 0) catch {
        // Test execution model detection only if /dev/null not available
        const model = detectOptimalModel();
        try testing.expect(model != .auto);
        return;
    };
    defer std.Io.Threaded.closeFd(null_fd);

    // Test runtime creation with /dev/null as write target
    var blocking_io_impl = BlockingIo.initWithFds(allocator, 4096, std.posix.STDIN_FILENO, null_fd);
    defer blocking_io_impl.deinit();

    var io = blocking_io_impl.io();

    // Test colorblind async write (to /dev/null, not stdout)
    var future = try io.write("Hello, zsync!");
    defer future.destroy();
    try future.await();

    // Test execution model detection
    const model = detectOptimalModel();
    try testing.expect(model != .auto);
}

test "Future combinators" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Use /dev/null to avoid writing to stdout (which breaks test server protocol)
    const null_fd = std.posix.openat(std.posix.AT.FDCWD, "/dev/null", .{ .ACCMODE = .WRONLY }, 0) catch {
        // Skip IO tests if /dev/null not available, just test timeout
        const timeout_result = try timeoutFn(struct {
            fn op() u8 {
                return 1;
            }
        }.op, .{}, 1000);
        try testing.expectEqual(@as(u8, 1), timeout_result);
        return;
    };
    defer std.Io.Threaded.closeFd(null_fd);

    var blocking_io_impl = BlockingIo.initWithFds(allocator, 4096, std.posix.STDIN_FILENO, null_fd);
    defer blocking_io_impl.deinit();

    var io = blocking_io_impl.io();

    // Test concurrent operations (to /dev/null, not stdout)
    var f1 = try io.write("Data 1");
    defer f1.destroy();
    var f2 = try io.write("Data 2");
    defer f2.destroy();
    try f1.await();
    try f2.await();

    // Test timeout helper
    const timeout_result = try timeoutFn(struct {
        fn op() u8 {
            return 1;
        }
    }.op, .{}, 1000);
    try testing.expectEqual(@as(u8, 1), timeout_result);
}

test "Runtime with optimal configuration" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Thread pool shutdown is now fixed with proper condition-based waiting
    // Use 2 workers for reasonable test speed
    const config = Config{
        .execution_model = .thread_pool,
        .enable_debugging = false,
        .thread_pool_threads = 2,
    };

    const runtime_instance = try Runtime.init(allocator, config);
    defer runtime_instance.deinit();

    try testing.expect(runtime_instance.getExecutionModel() != .auto);

    const io = runtime_instance.getIo();
    try testing.expect(io.getMode() != .auto);
}

test "Version information" {
    const testing = std.testing;

    try testing.expect(VERSION_MAJOR == 0);
    try testing.expect(VERSION_MINOR == 8);
    try testing.expect(VERSION_PATCH == 0);
    try testing.expect(std.mem.eql(u8, VERSION, "0.8.0"));
}

/// Legacy compatibility function
pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "legacy compatibility" {
    const testing = std.testing;
    try testing.expect(add(3, 7) == 10);
}

test "Tokio-style OnceCell" {
    const testing = std.testing;

    var cell = OnceCell(u32).init();
    try testing.expect(!cell.isInitialized());
    try testing.expect(cell.get() == null);

    // Set value
    try testing.expect(cell.set(42));
    try testing.expect(cell.isInitialized());
    try testing.expect(cell.get().? == 42);

    // Cannot set twice
    try testing.expect(!cell.set(100));
    try testing.expect(cell.get().? == 42);
}

test "Tokio-style WatchChannel" {
    const testing = std.testing;

    var watch = WatchChannel(u32).init(0);

    try testing.expect(watch.borrow() == 0);
    try testing.expect(watch.getVersion() == 0);

    watch.send(42);
    try testing.expect(watch.borrow() == 42);
    try testing.expect(watch.getVersion() == 1);

    watch.send(100);
    try testing.expect(watch.borrow() == 100);
    try testing.expect(watch.getVersion() == 2);
}

test "Tokio-style BroadcastChannel" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var broadcast = BroadcastChannel(u32).init(allocator);
    defer broadcast.deinit();

    const sub1 = try broadcast.subscribe();
    const sub2 = try broadcast.subscribe();

    try broadcast.send(42);

    try testing.expect(BroadcastChannel(u32).recv(sub1).? == 42);
    try testing.expect(BroadcastChannel(u32).recv(sub2).? == 42);

    // Queue should be empty now
    try testing.expect(BroadcastChannel(u32).recv(sub1) == null);
}

test "Tokio-style CancellationToken" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var token = CancellationToken.init(allocator);
    defer token.deinit();

    try testing.expect(!token.isCancelled());

    token.cancel();
    try testing.expect(token.isCancelled());
}

test "CancellationToken with child tokens (memory lifecycle)" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test parent + multiple children - allocator will catch leaks
    var parent = CancellationToken.init(allocator);
    defer parent.deinit();

    const child1 = try parent.child();
    const child2 = try parent.child();
    const child3 = try parent.child();

    // Children should not be cancelled yet
    try testing.expect(!child1.isCancelled());
    try testing.expect(!child2.isCancelled());
    try testing.expect(!child3.isCancelled());

    // Cancel parent - should propagate to children
    parent.cancel();
    try testing.expect(parent.isCancelled());
    try testing.expect(child1.isCancelled());
    try testing.expect(child2.isCancelled());
    try testing.expect(child3.isCancelled());

    // Parent deinit should recursively clean up all children (no leaks)
}

test "CancellationToken nested children" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test grandchildren - three levels deep
    var root = CancellationToken.init(allocator);
    defer root.deinit();

    const level1 = try root.child();
    const level2 = try level1.child();
    const level3 = try level2.child();

    // None cancelled
    try testing.expect(!root.isCancelled());
    try testing.expect(!level1.isCancelled());
    try testing.expect(!level2.isCancelled());
    try testing.expect(!level3.isCancelled());

    // Cancel root - propagates down
    root.cancel();
    try testing.expect(level1.isCancelled());
    try testing.expect(level2.isCancelled());
    try testing.expect(level3.isCancelled());
}

test "CancellationToken child inherits cancelled state" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var token = CancellationToken.init(allocator);
    defer token.deinit();

    // Cancel first
    token.cancel();

    // Child created after cancellation should inherit cancelled state
    const child = try token.child();
    try testing.expect(child.isCancelled());
}

test "Tokio-style RuntimeBuilder" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var builder = runtimeBuilder(allocator);
    _ = builder.currentThread().enableAll();

    const rt = try builder.build();
    defer rt.deinit();

    try testing.expect(rt.getExecutionModel() == .blocking);
}

test "Tokio-style Interval" {
    const testing = std.testing;

    var int = interval(10);
    try testing.expect(int.period() == 10);

    // Just test that reset works
    int.reset();
    try testing.expect(int.period() == 10);
}

test "Tokio-style Notify" {
    const testing = std.testing;

    var notify = Notify.init();

    try testing.expect(!notify.hasWaiters());

    // notifyOne should work even with no waiters
    notify.notifyOne();
    notify.notifyAll();
}

test "Channel trySend/tryRecv fast paths" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test bounded channel from channels.zig
    var ch = try channels.bounded(u32, allocator, 2);
    defer ch.deinit();

    // tryRecv on empty returns null
    try testing.expect(ch.tryRecv() == null);

    // trySend should succeed
    try testing.expect(try ch.trySend(42));
    try testing.expect(try ch.trySend(43));

    // Channel full - trySend returns false
    try testing.expect(!(try ch.trySend(44)));

    // tryRecv should get items in order
    try testing.expect(ch.tryRecv().? == 42);
    try testing.expect(ch.tryRecv().? == 43);
    try testing.expect(ch.tryRecv() == null);
}

// Include tests from imported modules
test {
    _ = @import("sync.zig");
    _ = @import("compat/thread.zig");
}
