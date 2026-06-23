//! zsync Channels Example
//! Demonstrates channel-based message passing with blocking and non-blocking APIs

const std = @import("std");
const zsync = @import("zsync");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("zsync v{s} - Channels Example\n", .{zsync.VERSION});
    std.debug.print("==============================\n\n", .{});

    // Create a bounded mpsc channel with capacity 5
    const channel = try zsync.channel.mpsc.bounded(u32, allocator, 5);
    defer {
        channel.channel.deinit();
        allocator.destroy(channel.channel);
    }

    std.debug.print("Created bounded channel with capacity 5\n\n", .{});

    // --- Blocking Send/Recv ---
    std.debug.print("--- Blocking API (send/recv) ---\n", .{});
    for (0..3) |i| {
        try channel.sender.send(@intCast(i * 10));
        std.debug.print("  send({})\n", .{i * 10});
    }

    for (0..3) |_| {
        const value = try channel.receiver.recv();
        std.debug.print("  recv() -> {}\n", .{value});
    }

    // --- Non-blocking trySend/tryRecv (Fast Paths) ---
    std.debug.print("\n--- Non-blocking API (trySend/tryRecv) ---\n", .{});

    // trySend returns ChannelFull when the bounded queue has no space.
    var sent: u32 = 0;
    for (0..10) |i| {
        channel.sender.trySend(@intCast(i)) catch |err| {
            std.debug.print("  trySend({}) -> {s}\n", .{ i, @errorName(err) });
            continue;
        };
        sent += 1;
    }
    std.debug.print("  Successfully sent {} items (capacity: 5)\n", .{sent});

    // tryRecv returns ChannelEmpty when no message is available.
    std.debug.print("  Draining with tryRecv:\n", .{});
    var received: u32 = 0;
    while (true) {
        const value = channel.receiver.tryRecv() catch break;
        std.debug.print("    tryRecv() -> {}\n", .{value});
        received += 1;
    }
    std.debug.print("  Received {} items\n", .{received});

    // tryRecv on empty channel
    _ = channel.receiver.tryRecv() catch |err| {
        std.debug.print("  tryRecv() on empty -> {s}\n", .{@errorName(err)});
    };

    // --- Unbounded Channel ---
    std.debug.print("\n--- Unbounded Channel ---\n", .{});

    const unbounded = try zsync.channel.mpsc.unbounded([]const u8, allocator);
    defer {
        unbounded.channel.deinit();
        allocator.destroy(unbounded.channel);
    }

    // Unbounded channels never block on send
    try unbounded.sender.send("Hello");
    try unbounded.sender.send("from");
    try unbounded.sender.send("zsync!");

    std.debug.print("  Messages: ", .{});
    while (true) {
        const msg = unbounded.receiver.tryRecv() catch break;
        std.debug.print("{s} ", .{msg});
    }
    std.debug.print("\n", .{});

    // --- Use Case: Producer/Consumer Pattern ---
    std.debug.print("\n--- Use Case: Batch Processing ---\n", .{});

    const work_queue = try zsync.channel.mpsc.bounded(u32, allocator, 100);
    defer {
        work_queue.channel.deinit();
        allocator.destroy(work_queue.channel);
    }

    // Producer: batch send items
    var items_queued: u32 = 0;
    for (0..50) |i| {
        work_queue.sender.trySend(@intCast(i)) catch continue;
        items_queued += 1;
    }
    std.debug.print("  Queued {} work items\n", .{items_queued});

    // Consumer: process all available items
    var items_processed: u32 = 0;
    while (true) {
        _ = work_queue.receiver.tryRecv() catch break;
        items_processed += 1;
    }
    std.debug.print("  Processed {} work items\n", .{items_processed});

    std.debug.print("\nDone!\n", .{});
}
