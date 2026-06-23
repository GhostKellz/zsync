//! Tokio-style process namespace.
//!
//! This module is a small facade over Zig's `std.process` APIs using an explicit
//! `std.Io` handle. It does not invent a process runtime; it gives zsync users a
//! stable Tokio-shaped namespace that follows the standard library backend.

const std = @import("std");

pub const Error = std.process.SpawnError || std.process.Child.WaitError || std.process.RunError;

pub const Command = struct {
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    cwd: std.process.Child.Cwd = .inherit,
    environ_map: ?*const std.process.Environ.Map = null,
    stdout_limit: std.Io.Limit = .unlimited,
    stderr_limit: std.Io.Limit = .unlimited,
    reserve_amount: usize = 64,
    timeout: std.Io.Timeout = .none,
    create_no_window: bool = true,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, argv: []const []const u8) Self {
        return .{ .allocator = allocator, .argv = argv };
    }

    pub fn withCwd(self: *Self, cwd: std.process.Child.Cwd) *Self {
        self.cwd = cwd;
        return self;
    }

    pub fn withEnv(self: *Self, environ_map: *const std.process.Environ.Map) *Self {
        self.environ_map = environ_map;
        return self;
    }

    pub fn withOutputLimit(self: *Self, stdout_limit: std.Io.Limit, stderr_limit: std.Io.Limit) *Self {
        self.stdout_limit = stdout_limit;
        self.stderr_limit = stderr_limit;
        return self;
    }

    pub fn withTimeout(self: *Self, timeout: std.Io.Timeout) *Self {
        self.timeout = timeout;
        return self;
    }

    pub fn spawn(self: *Self, io: std.Io) Error!Child {
        const child = try std.process.spawn(io, .{
            .argv = self.argv,
            .cwd = self.cwd,
            .environ_map = self.environ_map,
            .stdin = .ignore,
            .stdout = .inherit,
            .stderr = .inherit,
            .create_no_window = self.create_no_window,
        });
        return .{ .inner = child };
    }

    pub fn output(self: *Self, io: std.Io) Error!Output {
        const result = try std.process.run(self.allocator, io, .{
            .argv = self.argv,
            .cwd = self.cwd,
            .environ_map = self.environ_map,
            .stdout_limit = self.stdout_limit,
            .stderr_limit = self.stderr_limit,
            .reserve_amount = self.reserve_amount,
            .timeout = self.timeout,
            .create_no_window = self.create_no_window,
        });
        return .{
            .status = ExitStatus.fromTerm(result.term),
            .stdout = result.stdout,
            .stderr = result.stderr,
        };
    }
};

pub const Child = struct {
    inner: std.process.Child,

    pub fn wait(self: *Child, io: std.Io) Error!ExitStatus {
        return ExitStatus.fromTerm(try self.inner.wait(io));
    }

    pub fn kill(self: *Child, io: std.Io) void {
        self.inner.kill(io);
    }
};

pub const ExitStatus = struct {
    code: ?u8 = null,
    signal: ?std.posix.SIG = null,
    stopped: ?std.posix.SIG = null,
    unknown: ?u32 = null,

    pub fn fromTerm(term: std.process.Child.Term) ExitStatus {
        return switch (term) {
            .exited => |code| .{ .code = code },
            .signal => |sig| .{ .signal = sig },
            .stopped => |sig| .{ .stopped = sig },
            .unknown => |code| .{ .unknown = code },
        };
    }

    pub fn success(self: ExitStatus) bool {
        return self.code != null and self.code.? == 0;
    }
};

pub const Output = struct {
    status: ExitStatus,
    stdout: []const u8,
    stderr: []const u8,

    pub fn deinit(self: *Output, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
        self.* = undefined;
    }
};

test "process output captures stdout" {
    const Work = struct {
        fn task() void {
            const io = @import("std_runtime.zig").getGlobalIo().?;
            var cmd = Command.init(std.testing.allocator, &.{ "zig", "version" });
            var out = cmd.output(io) catch unreachable;
            defer out.deinit(std.testing.allocator);

            std.testing.expect(out.status.success()) catch unreachable;
            std.testing.expect(out.stdout.len > 0) catch unreachable;
        }
    };

    @import("std_runtime.zig").run(std.testing.allocator, Work.task, .{});
}
