//! Tokio-style signal namespace.
//!
//! POSIX targets install lightweight counting handlers. Other targets keep an
//! explicit unsupported boundary until Zig exposes a portable signal stream.

const std = @import("std");
const builtin = @import("builtin");
const compat = @import("compat/thread.zig");

pub const Error = error{Unsupported};

pub const SignalKind = enum {
    interrupt,
    terminate,
    hangup,
};

pub const Signal = struct {
    kind: SignalKind,
    seen: usize,

    pub fn recv(self: *Signal) Error!void {
        while (!self.tryRecv()) {
            compat.sleepNanos(1 * std.time.ns_per_ms);
        }
    }

    pub fn tryRecv(self: *Signal) bool {
        const current = counter(self.kind).load(.acquire);
        if (current == self.seen) return false;
        self.seen = current;
        return true;
    }

    pub fn recvTimeout(self: *Signal, timeout_ms: u64) Error!bool {
        const start = compat.Instant.now() catch return false;
        while (!self.tryRecv()) {
            const now = compat.Instant.now() catch return false;
            if (now.since(start) >= timeout_ms * std.time.ns_per_ms) return false;
            compat.sleepNanos(1 * std.time.ns_per_ms);
        }
        return true;
    }

    pub fn recvCancellable(self: *Signal, token: anytype) !void {
        while (!self.tryRecv()) {
            if (token.isCancelled()) return error.Cancelled;
            compat.sleepNanos(1 * std.time.ns_per_ms);
        }
    }
};

var interrupt_count = std.atomic.Value(usize).init(0);
var terminate_count = std.atomic.Value(usize).init(0);
var hangup_count = std.atomic.Value(usize).init(0);
var interrupt_installed = std.atomic.Value(bool).init(false);
var terminate_installed = std.atomic.Value(bool).init(false);
var hangup_installed = std.atomic.Value(bool).init(false);

fn supportsSignals() bool {
    return switch (builtin.os.tag) {
        .linux, .macos, .freebsd, .openbsd, .netbsd, .dragonfly, .illumos => true,
        else => false,
    };
}

fn posixSig(kind: SignalKind) std.posix.SIG {
    return switch (kind) {
        .interrupt => .INT,
        .terminate => .TERM,
        .hangup => .HUP,
    };
}

fn counter(kind: SignalKind) *std.atomic.Value(usize) {
    return switch (kind) {
        .interrupt => &interrupt_count,
        .terminate => &terminate_count,
        .hangup => &hangup_count,
    };
}

fn installed(kind: SignalKind) *std.atomic.Value(bool) {
    return switch (kind) {
        .interrupt => &interrupt_installed,
        .terminate => &terminate_installed,
        .hangup => &hangup_installed,
    };
}

fn handler(sig: std.posix.SIG) callconv(.c) void {
    if (sig == .INT) {
        _ = interrupt_count.fetchAdd(1, .release);
    } else if (sig == .TERM) {
        _ = terminate_count.fetchAdd(1, .release);
    } else if (sig == .HUP) {
        _ = hangup_count.fetchAdd(1, .release);
    }
}

fn install(kind: SignalKind) Error!void {
    if (!supportsSignals()) return error.Unsupported;

    const marker = installed(kind);
    if (marker.swap(true, .acq_rel)) return;

    var action = std.posix.Sigaction{
        .handler = .{ .handler = handler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(posixSig(kind), &action, null);
}

pub fn signal(kind: SignalKind) Error!Signal {
    try install(kind);
    return .{ .kind = kind, .seen = counter(kind).load(.acquire) };
}

pub fn ctrlC() Error!void {
    var sig = try signal(.interrupt);
    return sig.recv();
}

test "signal namespace installs or reports unsupported" {
    if (supportsSignals()) {
        var sig = try signal(.interrupt);
        try std.testing.expect(!sig.tryRecv());
    } else {
        try std.testing.expectError(error.Unsupported, signal(.interrupt));
    }
}
