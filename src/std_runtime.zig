//! std.Io-based runtime foundation — the keystone of the std.Io rebase.
//!
//! Owns a `std.Io.Threaded` backend plus a process-global `Io` handle and
//! exposes the explicit-Io canonical entry points (`run`, `Runtime`, `asyncIo`,
//! `spawnIo`) alongside a `getGlobalIo()` compat shim that mirrors the legacy
//! `global_runtime` pattern.
//!
//! This module is additive: it does not yet replace zsync's custom `Io` vtable.
//! Later milestones repoint the public aliases here once the remaining consumers
//! and examples are migrated off the custom backend.

const std = @import("std");
const builtin = @import("builtin");
const compat = @import("compat/thread.zig");

/// Canonical I/O interface — Zig's colorblind `std.Io`.
pub const Io = std.Io;
/// Future handle returned by `asyncIo`/`spawnIo` (`std.Io.async`).
pub const Future = std.Io.Future;
/// Structured-concurrency task group.
pub const Group = std.Io.Group;

pub const RuntimeError = error{
    /// `spawnIo`/`getGlobalIo` called before a runtime installed a global Io.
    RuntimeNotInitialized,
};

/// Process-global `Io` handle. Compat shim so the existing singleton-style API
/// (`spawn`, `getGlobalIo`) can migrate with minimal churn. New code should
/// prefer the explicit-Io path (`asyncIo`, passing `io` through args).
var global_io: ?Io = null;
var global_io_mutex: compat.Mutex = .{};

pub fn setGlobalIo(value: Io) void {
    global_io_mutex.lock();
    defer global_io_mutex.unlock();
    global_io = value;
}

pub fn clearGlobalIo() void {
    global_io_mutex.lock();
    defer global_io_mutex.unlock();
    global_io = null;
}

/// Get the process-global `Io` handle, if a runtime has installed one.
pub fn getGlobalIo() ?Io {
    global_io_mutex.lock();
    defer global_io_mutex.unlock();
    return global_io;
}

/// Tuning knobs that map onto `std.Io.Threaded.InitOptions`. Intentionally slim;
/// the legacy `Config`/`ExecutionModel` surface is dropped — std owns scheduling.
pub const RuntimeOptions = struct {
    /// Worker stack size in bytes. 0 = backend default.
    stack_size: usize = 0,
};

/// Owns a `std.Io.Threaded` backend. Thin wrapper that aligns zsync's `Runtime`
/// surface with the std.Io world. Must not be copied after `init` (callers hold
/// it by stable address and use `&self.threaded`).
pub const Runtime = struct {
    threaded: std.Io.Threaded,
    allocator: std.mem.Allocator,

    pub fn init(gpa: std.mem.Allocator, options: RuntimeOptions) Runtime {
        var init_opts: std.Io.Threaded.InitOptions = .{};
        if (options.stack_size != 0) init_opts.stack_size = options.stack_size;
        return .{
            .threaded = std.Io.Threaded.init(gpa, init_opts),
            .allocator = gpa,
        };
    }

    /// Acquire the `Io` interface for this runtime.
    pub fn io(self: *Runtime) Io {
        return self.threaded.io();
    }

    /// Spawn an async task on this runtime, returning a `std.Io.Future`.
    pub fn spawn(self: *Runtime, comptime function: anytype, args: anytype) @TypeOf(self.threaded.io().async(function, args)) {
        return self.threaded.io().async(function, args);
    }

    pub fn deinit(self: *Runtime) void {
        self.threaded.deinit();
    }
};

/// Build a `Threaded` backend, install the process-global `Io`, run `task_fn`,
/// then tear everything down. Returns whatever `task_fn` returns (including its
/// error set). Tasks acquire `io` via `getGlobalIo()` or as an explicit arg —
/// no automatic Io injection (aligns with std.Io's explicit-argument pattern).
pub fn run(
    gpa: std.mem.Allocator,
    comptime task_fn: anytype,
    args: anytype,
) @typeInfo(@TypeOf(task_fn)).@"fn".return_type.? {
    var rt = Runtime.init(gpa, .{});
    defer rt.deinit();

    setGlobalIo(rt.io());
    defer clearGlobalIo();

    if (@TypeOf(args) == void) {
        return @call(.auto, task_fn, .{});
    }
    return @call(.auto, task_fn, args);
}

/// Blessed explicit-Io path: spawn `function` as an async task on `io`.
/// Equivalent to `io.async(function, args)`.
pub inline fn asyncIo(io: Io, comptime function: anytype, args: anytype) @TypeOf(io.async(function, args)) {
    return io.async(function, args);
}

/// Compat-shim spawn against the process-global `Io`. Prefer `asyncIo` in new
/// code. Errors if no runtime has installed a global `Io`.
pub inline fn spawnIo(
    comptime function: anytype,
    args: anytype,
) RuntimeError!@TypeOf((getGlobalIo().?).async(function, args)) {
    const io = getGlobalIo() orelse return RuntimeError.RuntimeNotInitialized;
    return io.async(function, args);
}

test "std_runtime: run installs global io and clears it afterward" {
    const Probe = struct {
        var saw_io: bool = false;
        fn task() void {
            saw_io = getGlobalIo() != null;
        }
    };
    Probe.saw_io = false;
    run(std.testing.allocator, Probe.task, .{});
    try std.testing.expect(Probe.saw_io);
    try std.testing.expect(getGlobalIo() == null);
}

test "std_runtime: asyncIo runs a task to completion via std.Io" {
    const Work = struct {
        fn add(a: u32, b: u32) u32 {
            return a + b;
        }
        fn mainTask() void {
            const io = getGlobalIo().?;
            var fut = asyncIo(io, add, .{ @as(u32, 2), @as(u32, 3) });
            const result = fut.await(io);
            std.testing.expect(result == 5) catch unreachable;
        }
    };
    run(std.testing.allocator, Work.mainTask, .{});
}
