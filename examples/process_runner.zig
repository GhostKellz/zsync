//! zsync Process Example
//! Demonstrates std.Io-backed process output capture.

const std = @import("std");
const zsync = @import("zsync");

const ProcessTask = struct {
    allocator: std.mem.Allocator,

    fn run(self: *const ProcessTask) void {
        const io = zsync.getGlobalIo() orelse return;

        var cmd = zsync.process.Command.init(self.allocator, &.{ "zig", "version" });
        _ = cmd.withOutputLimit(.limited(1024), .limited(1024));

        var output = cmd.output(io) catch |err| {
            std.debug.print("process failed: {}\n", .{err});
            return;
        };
        defer output.deinit(self.allocator);

        std.debug.print("exit success: {}\n", .{output.status.success()});
        std.debug.print("zig version: {s}", .{output.stdout});
    }
};

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    const task = ProcessTask{ .allocator = allocator };
    zsync.run(allocator, ProcessTask.run, .{&task});
}
