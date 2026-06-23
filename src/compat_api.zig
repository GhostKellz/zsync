//! Public compatibility namespace for legacy and advisory APIs.
//!
//! New code should prefer the Tokio-style facade modules:
//! `task`, `time`, `channel`, `tokio_sync`, `net`, `process`, and `signal`.

const std = @import("std");
const std_runtime = @import("std_runtime.zig");
const spawn_mod = @import("spawn.zig");
const time = @import("time.zig");

pub const Future = std.Io.Future;
pub const Runtime = std_runtime.Runtime;
pub const RuntimeOptions = std_runtime.RuntimeOptions;

/// Spawn a high-priority task. `std.Io` owns scheduling, so this is equivalent
/// to `zsync.task.spawn` and is retained for source compatibility.
pub fn spawnUrgent(comptime task_fn: anytype, args: anytype) !Future {
    return spawn_mod.spawn(task_fn, args);
}

/// Task priority hint. Scheduling is delegated to `std.Io`, which does not
/// expose priorities; retained for API compatibility.
pub const TaskPriority = enum { low, normal, high };

/// Spawn a task with a priority hint. The hint is currently advisory only.
pub fn spawnWithPriority(comptime task_fn: anytype, args: anytype, priority: TaskPriority) !Future {
    _ = priority;
    return spawn_mod.spawn(task_fn, args);
}

/// Fluent runtime configuration kept for Tokio-shaped compatibility.
pub const RuntimeBuilder = struct {
    options: RuntimeOptions = .{},
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn new(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    /// Configure as multi-threaded runtime. Advisory under `std.Io.Threaded`.
    pub fn multiThread(self: *Self) *Self {
        return self;
    }

    /// Configure as single-threaded runtime. Advisory under `std.Io.Threaded`.
    pub fn currentThread(self: *Self) *Self {
        return self;
    }

    /// Set worker thread count. Advisory under `std.Io.Threaded`.
    pub fn workerThreads(self: *Self, count: u32) *Self {
        _ = count;
        return self;
    }

    /// Enable all runtime features. Retained for Tokio API familiarity.
    pub fn enableAll(self: *Self) *Self {
        return self;
    }

    pub fn enableTime(self: *Self) *Self {
        return self;
    }

    pub fn enableIo(self: *Self) *Self {
        return self;
    }

    pub fn threadStackSize(self: *Self, size: usize) *Self {
        self.options.stack_size = size;
        return self;
    }

    pub fn build(self: *Self) Runtime {
        return Runtime.init(self.allocator, self.options);
    }
};

pub fn runtimeBuilder(allocator: std.mem.Allocator) RuntimeBuilder {
    return RuntimeBuilder.new(allocator);
}

/// Blocking compatibility timeout. Prefer `zsync.time.timeoutFn` for explicit
/// time helpers and future-aware combinators for async work.
pub const timeoutFn = time.timeoutFn;

/// Simple hello world example showcasing task spawning on `std.Io`.
pub fn helloWorld(allocator: std.mem.Allocator) !void {
    const HelloTask = struct {
        fn task() void {
            std.debug.print("zsync - async runtime for Zig\n", .{});
            std.debug.print("powered by std.Io\n", .{});
        }
    };

    std_runtime.run(allocator, HelloTask.task, .{});
}

pub const examples = struct {
    pub const helloWorld = @import("compat_api.zig").helloWorld;
};

/// Legacy compatibility function.
pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "compat runtime builder" {
    var builder = runtimeBuilder(std.testing.allocator);
    _ = builder.currentThread().enableAll().threadStackSize(64 * 1024);

    var rt = builder.build();
    defer rt.deinit();
    _ = rt.io();
}

test "compat timeout and add" {
    const result = try timeoutFn(struct {
        fn op() u8 {
            return 1;
        }
    }.op, .{}, 1000);
    try std.testing.expectEqual(@as(u8, 1), result);
    try std.testing.expectEqual(@as(i32, 10), add(3, 7));
}
