//! Zsync v0.1 - Colorblind Async Runtime for Zig
//! Now aligned with Zig's new async I/O paradigm
//! Same code works across blocking, threaded, and green thread execution models

const std = @import("std");

// Zsync v0.1 - New Io Interface (Primary APIs)
pub const io_v2 = @import("io_v2.zig");
pub const BlockingIo = @import("blocking_io.zig").BlockingIo;
pub const ThreadPoolIo = @import("threadpool_io.zig").ThreadPoolIo;
pub const GreenThreadsIo = @import("greenthreads_io.zig").GreenThreadsIo;
pub const StacklessIo = @import("stackless_io.zig").StacklessIo;

// Re-export core v0.1 types for convenience
pub const Io = io_v2.Io;
pub const Future = io_v2.Future;
pub const File = io_v2.File;
pub const Dir = io_v2.Dir;
pub const TcpStream = io_v2.TcpStream;
pub const TcpListener = io_v2.TcpListener;
pub const UdpSocket = io_v2.UdpSocket;

// v0.1 Colorblind async examples
pub const saveData = io_v2.saveData;
pub const examples_v2 = @import("examples_v2.zig");

// v0.1 Advanced features
pub const advanced_io = @import("advanced_io.zig");
pub const Writer = advanced_io.Writer;
pub const AdvancedReader = advanced_io.AdvancedReader;
pub const AdvancedTcpStream = advanced_io.AdvancedTcpStream;
pub const AdvancedConnectionPool = advanced_io.ConnectionPool;

// v0.1 Thread-local storage
pub const thread_local_storage = @import("thread_local_storage.zig");
pub const TlsKey = thread_local_storage.TlsKey;
pub const ThreadLocal = thread_local_storage.ThreadLocal;

// v0.1 Lock-free data structures
pub const lockfree_queue = @import("lockfree_queue.zig");
pub const LockFreeQueue = lockfree_queue.LockFreeQueue;
pub const MPMCQueue = lockfree_queue.MPMCQueue;
pub const WorkStealingDeque = lockfree_queue.WorkStealingDeque;

// v0.1 Deprecation system
pub const deprecation = @import("deprecation.zig");

// v0.1 Testing and validation
pub const testing_framework = @import("testing_framework.zig");
pub const TestSuite = testing_framework.TestSuite;
pub const runComprehensiveTests = testing_framework.runComprehensiveTests;

// v0.1 Migration and compatibility
pub const migration_guide = @import("migration_guide.zig");
pub const MigrationGuide = migration_guide.MigrationGuide;
pub const CompatibilityLayer = migration_guide.CompatibilityLayer;
pub const demonstrateMigration = migration_guide.demonstrateMigration;

// Zsync v1.x Compatibility Layer (Legacy)
pub const runtime = @import("runtime.zig");
pub const task = @import("task.zig");
pub const reactor = @import("reactor.zig");
pub const timer = @import("timer.zig");
pub const channel = @import("channel.zig");
pub const io = @import("io.zig");
pub const examples = @import("examples.zig");
pub const simple = @import("simple.zig");
pub const scheduler = @import("scheduler.zig");
pub const event_loop = @import("event_loop.zig");
pub const zquic_integration = @import("zquic_integration.zig");
pub const async_runtime = @import("async_runtime.zig");
pub const connection_pool = @import("connection_pool.zig");

// Advanced Features
pub const multithread = @import("multithread.zig");
pub const io_uring = @import("io_uring.zig");
pub const networking = @import("networking.zig");
pub const benchmarks = @import("benchmarks.zig");

// Re-export commonly used types and functions
pub const Runtime = runtime.Runtime;
pub const TaskQueue = task.TaskQueue;
pub const JoinHandle = task.JoinHandle;
pub const Waker = task.Waker;
pub const Reactor = reactor.Reactor;
pub const TimerWheel = timer.TimerWheel;
pub const TimerHandle = timer.TimerHandle;
pub const AsyncScheduler = scheduler.AsyncScheduler;
pub const EventLoop = event_loop.EventLoop;
pub const TaskPriority = scheduler.TaskPriority;
pub const AsyncRuntime = async_runtime.AsyncRuntime;
pub const TaskHandle = async_runtime.TaskHandle;
pub const Sleep = async_runtime.Sleep;
pub const ConnectionPool = connection_pool.ConnectionPool;
pub const PoolConfig = connection_pool.PoolConfig;

// Phase 3 & 4 Advanced Types (v0.1)
pub const MultiThreadRuntime = multithread.MultiThreadRuntime;
pub const WorkerConfig = multithread.WorkerConfig;
pub const IoUring = io_uring.IoUring;
pub const IoUringReactor = io_uring.IoUringReactor;
pub const TlsStream = networking.TlsStream;
pub const HttpClient = networking.HttpClient;
pub const WebSocketConnection = networking.WebSocketConnection;
pub const DnsResolver = networking.DnsResolver;
pub const BenchmarkSuite = benchmarks.BenchmarkSuite;

// Convenience functions
pub const run = runtime.run;
pub const runHighPerf = runtime.runHighPerf;
pub const runIoFocused = runtime.runIoFocused; // Perfect for zquic!
pub const spawn = runtime.spawn;
pub const spawnUrgent = runtime.spawnUrgent;
pub const spawnAsync = runtime.spawnAsync; // New async spawn with TaskHandle
pub const sleep = runtime.sleep;
pub const asyncSleep = runtime.asyncSleep; // True async sleep
pub const blockOn = runtime.blockOn; // Block on async function
pub const registerIo = runtime.registerIo;
pub const getStats = runtime.getStats;

// Global async runtime functions
pub const globalSpawn = async_runtime.spawn;
pub const globalSleep = async_runtime.sleep;
pub const yieldNow = async_runtime.yield_now;

// Advanced runtime functions (v0.1)
pub const runMultiThreaded = multithread.MultiThreadRuntime.init;
pub const runBenchmarks = benchmarks.runBenchmarks;

// Channel creation functions
pub const bounded = channel.bounded;
pub const unbounded = channel.unbounded;
pub const oneshot = channel.OneShot;

// High-level API for easy usage
pub fn init(allocator: std.mem.Allocator) !*Runtime {
    return Runtime.init(allocator, .{});
}

pub fn defaultRuntime(comptime main_task: anytype) !void {
    try run(main_task);
}

// Legacy function for compatibility
pub fn advancedPrint() !void {
    const stdout = std.debug.print;

    stdout("Zsync async runtime initialized!\n", .{});
    stdout("Run `zig build test` to run the tests.\n", .{});
}

pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "basic add functionality" {
    try std.testing.expect(add(3, 7) == 10);
}

test "zsync runtime creation" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    const rt = try init(allocator);
    defer rt.deinit();
    
    try testing.expect(!rt.running.load(.acquire));
}

test "zsync exports" {
    // Test that our exports are accessible
    const testing = std.testing;
    
    // Test runtime types
    const RuntimeType = @TypeOf(Runtime);
    _ = RuntimeType;
    
    // Test functions exist
    const run_func = run;
    _ = run_func;
    
    const spawn_func = spawn;
    _ = spawn_func;
    
    try testing.expect(true);
}
