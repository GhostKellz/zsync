//! zsync Channels Example
//! Demonstrates channel-based message passing with blocking and non-blocking APIs

const std = @import("std");
const zsync = @import("zsync");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("zsync v{s} - Channels Example\n", .{zsync.VERSION});
    std.debug.print("==============================\n\n", .{});

    // Create a bounded channel with capacity 5
    var channel = zsync.Channel(u32).init(allocator, 5);
    defer channel.deinit();

    std.debug.print("Created bounded channel with capacity 5\n\n", .{});

    // --- Blocking Send/Recv ---
    std.debug.print("--- Blocking API (send/recv) ---\n", .{});
    for (0..3) |i| {
        try channel.send(@intCast(i * 10));
        std.debug.print("  send({})\n", .{i * 10});
    }

    for (0..3) |_| {
        const value = try channel.recv();
        std.debug.print("  recv() -> {}\n", .{value});
    }

    // --- Non-blocking trySend/tryRecv (Fast Paths) ---
    std.debug.print("\n--- Non-blocking API (trySend/tryRecv) ---\n", .{});

    // trySend returns bool indicating success
    var sent: u32 = 0;
    for (0..10) |i| {
        const success = try channel.trySend(@intCast(i));
        if (success) {
            sent += 1;
        } else {
            std.debug.print("  trySend({}) -> channel full!\n", .{i});
        }
    }
    std.debug.print("  Successfully sent {} items (capacity: 5)\n", .{sent});

    // tryRecv returns ?T (null if empty)
    std.debug.print("  Draining with tryRecv:\n", .{});
    var received: u32 = 0;
    while (channel.tryRecv()) |value| {
        std.debug.print("    tryRecv() -> {}\n", .{value});
        received += 1;
    }
    std.debug.print("  Received {} items\n", .{received});

    // tryRecv on empty channel
    const empty_result = channel.tryRecv();
    std.debug.print("  tryRecv() on empty -> {?}\n", .{empty_result});

    // --- Unbounded Channel ---
    std.debug.print("\n--- Unbounded Channel ---\n", .{});

    var unbounded = zsync.UnboundedChannel([]const u8).init(allocator);
    defer unbounded.deinit();

    // Unbounded channels never block on send
    try unbounded.send("Hello");
    try unbounded.send("from");
    try unbounded.send("zsync!");

    std.debug.print("  Messages: ", .{});
    while (unbounded.tryRecv()) |msg| {
        std.debug.print("{s} ", .{msg});
    }
    std.debug.print("\n", .{});

    // --- Use Case: Producer/Consumer Pattern ---
    std.debug.print("\n--- Use Case: Batch Processing ---\n", .{});

    var work_queue = zsync.Channel(u32).init(allocator, 100);
    defer work_queue.deinit();

    // Producer: batch send items
    var items_queued: u32 = 0;
    for (0..50) |i| {
        if (try work_queue.trySend(@intCast(i))) {
            items_queued += 1;
        }
    }
    std.debug.print("  Queued {} work items\n", .{items_queued});

    // Consumer: process all available items
    var items_processed: u32 = 0;
    while (work_queue.tryRecv()) |_| {
        items_processed += 1;
    }
    std.debug.print("  Processed {} work items\n", .{items_processed});

    std.debug.print("\nDone!\n", .{});
}
