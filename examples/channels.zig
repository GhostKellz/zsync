//! Example: Channel Communication
//! Shows how to use bounded and unbounded channels

const std = @import("std");
const zsync = @import("zsync");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n📨 Zsync v0.6.0 - Channel Communication Example\n\n", .{});

    // Bounded channel example
    std.debug.print("--- Bounded Channel ---\n", .{});
    var bounded_ch = try zsync.boundedChannel(i32, allocator, 10);
    defer bounded_ch.deinit();

    try bounded_ch.send(42);
    try bounded_ch.send(100);
    try bounded_ch.send(256);

    std.debug.print("Sent: 42, 100, 256\n", .{});

    const val1 = try bounded_ch.recv();
    const val2 = try bounded_ch.recv();
    const val3 = try bounded_ch.recv();

    std.debug.print("Received: {}, {}, {}\n\n", .{ val1, val2, val3 });

    // Unbounded channel example
    std.debug.print("--- Unbounded Channel ---\n", .{});
    var unbounded_ch = try zsync.unboundedChannel([]const u8, allocator);
    defer unbounded_ch.deinit();

    try unbounded_ch.send("Hello");
    try unbounded_ch.send("from");
    try unbounded_ch.send("zsync");

    std.debug.print("Channel length: {}\n", .{unbounded_ch.len()});

    while (unbounded_ch.tryRecv()) |msg| {
        std.debug.print("Message: {s}\n", .{msg});
    }

    std.debug.print("\n✅ Channel communication successful!\n\n", .{});
}
