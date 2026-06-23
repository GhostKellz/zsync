//! zsync - Async runtime for Zig
//! Colorblind Async Runtime with True Function Color Elimination
//! Following Zig's latest async paradigm for maximum performance and ergonomics

const std = @import("std");
const builtin = @import("builtin");

// Tokio-style facade modules.
pub const task = @import("task.zig");
pub const time = @import("time.zig");
pub const net = @import("net.zig");
pub const process = @import("process.zig");
pub const signal = @import("signal.zig");
pub const compat = @import("compat_api.zig");

// Core runtime foundation — Zig's std.Io
pub const std_runtime = @import("std_runtime.zig");

// Task Spawning and Concurrency
pub const spawn_mod = @import("spawn.zig");
pub const channels = @import("channels.zig");
pub const future_mod = @import("future.zig");
pub const executor_mod = @import("executor.zig");
pub const sync_mod = @import("sync.zig");
pub const tokio_sync = @import("tokio_sync.zig");
pub const sleep_mod = @import("sleep.zig");
pub const select_mod = @import("select.zig");
pub const join_set_mod = @import("join_set.zig");

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

// Missing API modules that zquic needs
pub const timer = @import("timer.zig");
pub const channel = @import("channel.zig");

// Networking. On wasm32 there are no native sockets, so the implementation is
// delegated to the JavaScript/WASI host via `wasm/net.zig`; every other target
// uses the std.Io-backed stack in `networking.zig`.
pub const networking = if (builtin.target.cpu.arch == .wasm32)
    @import("wasm/net.zig")
else
    @import("networking.zig");

// Re-export core types for convenience — backed by Zig's std.Io
pub const Io = std.Io;
pub const Future = std.Io.Future;
pub const Group = std.Io.Group;

// Runtime types
pub const Runtime = std_runtime.Runtime;
pub const RuntimeOptions = std_runtime.RuntimeOptions;
pub const RuntimeError = std_runtime.RuntimeError;

// Convenience runtime functions
pub const run = std_runtime.run;
pub const getGlobalIo = std_runtime.getGlobalIo;
pub const setGlobalIo = std_runtime.setGlobalIo;
pub const clearGlobalIo = std_runtime.clearGlobalIo;

// Convenience functions
pub const GenericFuture = future_mod.Future;
pub const Executor = executor_mod.Executor;
pub const Semaphore = sync_mod.Semaphore;
pub const IoSemaphore = sync_mod.IoSemaphore;
pub const IoMutex = sync_mod.IoMutex;
pub const IoRwLock = sync_mod.IoRwLock;
pub const IoWaitGroup = sync_mod.IoWaitGroup;
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
pub const sleepCancellable = sleep_mod.sleepCancellable;

// Future combinators
pub const selectFuture = select_mod.select;
pub const selectTimeout = select_mod.selectTimeout;
pub const selectCancellable = select_mod.selectCancellable;
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

// WebSocket - canonical RFC 6455 implementation.
pub const WebSocketConnection = websocket.WebSocketConnection;
pub const WebSocketServer = websocket.WebSocketServer;
pub const WebSocketClient = websocket.WebSocketClient;
pub const WebSocketMessage = websocket.Message;
pub const WebSocketOpCode = websocket.OpCode;
pub const WebSocketCloseCode = websocket.CloseCode;

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

/// High-level async task spawning on the process-global runtime.
/// Returns a `std.Io.Future`; await it with `future.await(io)`.
pub const spawn = spawn_mod.spawn;

// =============================================================================
// Additional exports kept for downstream compatibility
// =============================================================================

/// Yield execution to other tasks (cooperative scheduling)
pub fn yieldNow() void {
    sleep_mod.yieldNow() catch {};
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

/// UDP socket. On wasm32 this is the host-bridged datagram socket from
/// `wasm/net.zig`; elsewhere it is backed directly by `std.Io.net`.
pub const UdpSocket = net.UdpSocket;

// =============================================================================
// Additional Async APIs
// =============================================================================

/// Timer wheel for scheduling timeouts and delays
pub const TimerWheel = time.TimerWheel;

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

/// DNS resolver for hostname resolution
pub const DnsResolver = networking.DnsResolver;

/// TLS stream wrapper for secure connections
pub const TlsStream = networking.TlsStream;

/// Create an HTTP client with TLS support. Requires a runtime to be installed
/// (see `run`) so the client can be bound to the active `std.Io`.
pub fn createHttpClient(allocator: std.mem.Allocator) !*HttpClient {
    const io = getGlobalIo() orelse return error.NoRuntimeInstalled;
    const client = try allocator.create(HttpClient);
    errdefer allocator.destroy(client);
    const tls_config = networking.TlsConfig{};
    client.* = HttpClient.init(allocator, io, tls_config);
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
    return time.nanoTime();
}

/// Get microsecond timestamp
pub fn microTime() u64 {
    return time.microTime();
}

/// Get millisecond timestamp
pub fn milliTime() u64 {
    return time.milliTime();
}

/// Measure execution time of a function
pub const MeasureResult = time.MeasureResult;

pub fn measure(comptime func: anytype, args: anytype) MeasureResult {
    return timer.measure(func, args);
}

/// Legacy/advisory spawn helpers retained for source compatibility.
pub const spawnUrgent = compat.spawnUrgent;
pub const TaskPriority = compat.TaskPriority;
pub const spawnWithPriority = compat.spawnWithPriority;

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

/// JoinSet for managing multiple blocking tasks on dedicated OS threads.
pub const JoinSet = join_set_mod.JoinSet;

pub const BroadcastChannel = tokio_sync.BroadcastChannel;
pub const WatchChannel = tokio_sync.WatchChannel;
pub const Notify = tokio_sync.Notify;
pub const OnceCell = tokio_sync.OnceCell;
pub const CancellationToken = tokio_sync.CancellationToken;

/// Legacy/advisory runtime helpers retained for source compatibility.
pub const RuntimeBuilder = compat.RuntimeBuilder;
pub const runtimeBuilder = compat.runtimeBuilder;

/// Time helpers are canonical under `zsync.time`; root aliases remain stable.
pub const Interval = time.Interval;
pub const interval = time.interval;
pub const timeoutFn = time.timeoutFn;

// Version information - pulled from build.zig.zon via build options
const build_options = @import("build_options");
pub const VERSION = build_options.version;
pub const VERSION_PARSED = std.SemanticVersion.parse(VERSION) catch unreachable;
pub const VERSION_MAJOR = VERSION_PARSED.major;
pub const VERSION_MINOR = VERSION_PARSED.minor;
pub const VERSION_PATCH = VERSION_PARSED.patch;

/// Print Zsync version and capabilities
pub fn printVersion() void {
    std.debug.print("zsync v{s} - async runtime for Zig\n", .{VERSION});
    std.debug.print("Core Features:\n", .{});
    std.debug.print("  ✅ Colorblind Async/Await\n", .{});
    std.debug.print("  ✅ std.Io.Threaded Backend\n", .{});
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
    std.debug.print("\nBacked by std.Io (std.Io.Threaded)\n", .{});
}

// Backward compatibility exports
pub const helloWorld = compat.helloWorld;
pub const examples = compat.examples;

// Tests
test "zsync basic functionality" {
    const Shared = struct {
        var ran: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
        fn task() void {
            _ = ran.fetchAdd(1, .release);
        }
    };
    Shared.ran.store(0, .release);
    std_runtime.run(std.testing.allocator, Shared.task, .{});
    try std.testing.expectEqual(@as(u32, 1), Shared.ran.load(.acquire));
}

test "Future combinators" {
    const testing = std.testing;

    // Timeout helper (wall-clock based) still applies under std.Io.
    const timeout_result = try timeoutFn(struct {
        fn op() u8 {
            return 1;
        }
    }.op, .{}, 1000);
    try testing.expectEqual(@as(u8, 1), timeout_result);
}

test "Runtime spawns and awaits a future" {
    const Work = struct {
        fn addValues(a: u32, b: u32) u32 {
            return a + b;
        }
        fn mainTask() void {
            const io = std_runtime.getGlobalIo().?;
            var fut = io.async(addValues, .{ @as(u32, 20), @as(u32, 22) });
            std.testing.expectEqual(@as(u32, 42), fut.await(io)) catch unreachable;
        }
    };
    std_runtime.run(std.testing.allocator, Work.mainTask, .{});
}

test "Version information" {
    const testing = std.testing;

    // Version is pulled from build.zig.zon - verify it parses correctly
    try testing.expect(VERSION.len > 0);
    try testing.expect(VERSION_MAJOR >= 0);
    try testing.expect(VERSION_MINOR >= 0);
    try testing.expect(VERSION_PATCH >= 0);
    // Verify VERSION_PARSED matches the components
    try testing.expect(VERSION_PARSED.major == VERSION_MAJOR);
    try testing.expect(VERSION_PARSED.minor == VERSION_MINOR);
    try testing.expect(VERSION_PARSED.patch == VERSION_PATCH);
}

/// Legacy compatibility function.
pub const add = compat.add;

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

    var watcher = watch.subscribe();
    _ = watcher.borrow();
    try testing.expect(watcher.changedTimeout(1) == null);
    watch.send(101);
    try testing.expect(watcher.changedTimeout(1).? == 101);

    var token = CancellationToken.init(testing.allocator);
    defer token.deinit();
    token.cancel();
    try testing.expectError(error.Cancelled, watcher.changedCancellable(&token));
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
    try testing.expect(broadcast.recvBlockingTimeout(sub1, 1) == null);

    try broadcast.send(99);
    try testing.expect(broadcast.recvBlockingTimeout(sub1, 1).? == 99);

    var token = CancellationToken.init(allocator);
    defer token.deinit();
    token.cancel();
    try testing.expectError(error.Cancelled, broadcast.recvBlockingCancellable(sub1, &token));
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
    _ = builder.currentThread().enableAll().threadStackSize(64 * 1024);

    var rt = builder.build();
    defer rt.deinit();

    // Runtime exposes a usable std.Io interface.
    _ = rt.io();
    try testing.expect(true);
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

// Include tests from imported modules. Every public re-export is force-referenced
// here so the entire public surface is continuously compiled and its tests run —
// this is what prevents a module from silently rotting against std.Io changes.
test {
    _ = @import("task.zig");
    _ = @import("time.zig");
    _ = @import("net.zig");
    _ = @import("process.zig");
    _ = @import("signal.zig");
    _ = @import("compat_api.zig");
    _ = @import("compat/thread.zig");
    _ = @import("std_runtime.zig");
    _ = @import("spawn.zig");
    _ = @import("channels.zig");
    _ = @import("channel.zig");
    _ = @import("future.zig");
    _ = @import("executor.zig");
    _ = @import("sync.zig");
    _ = @import("tokio_sync.zig");
    _ = @import("sleep.zig");
    _ = @import("select.zig");
    _ = @import("join_set.zig");
    _ = @import("nursery.zig");
    _ = @import("buffer_pool.zig");
    _ = @import("streams.zig");
    _ = @import("timer.zig");
    _ = @import("diagnostics.zig");

    // Root-level networking helpers are lazily analyzed; reference them so their
    // signatures stay in sync with the active networking backend.
    _ = &createHttpClient;
    _ = &createTimerWheel;

    // WASM async helpers are written against portable compat primitives, so their
    // tests run on the host too. The JS host bindings they wrap are excluded at
    // comptime on non-wasm targets.
    _ = @import("wasm/microtask.zig");
    _ = @import("wasm/async.zig");
    _ = @import("wasm/net.zig");

    if (builtin.target.cpu.arch != .wasm32) {
        _ = @import("networking.zig");
        _ = @import("net/websocket.zig");
        _ = @import("net/pool.zig");
        _ = @import("net/rate_limit.zig");
        _ = @import("async_fs.zig");
        _ = @import("dev/watch.zig");
        _ = @import("lsp/server.zig");
        _ = @import("terminal/pty.zig");
        _ = @import("plugin/system.zig");
        _ = @import("script/runtime.zig");
        _ = @import("compression/stream.zig");
    }
}
