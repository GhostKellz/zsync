//! zsync Basic Example
//! Demonstrates basic runtime usage and colorblind async I/O

const std = @import("std");
const zsync = @import("zsync");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("zsync v{s} - Basic Example\n", .{zsync.VERSION});
    std.debug.print("=============================\n\n", .{});

    // Detect optimal execution model for this platform
    const model = zsync.detectOptimalModel();
    std.debug.print("Detected optimal model: {}\n\n", .{model});

    // Create a simple blocking I/O instance
    var blocking_io = zsync.createBlockingIo(allocator);
    defer blocking_io.deinit();

    const io = blocking_io.io();

    // Demonstrate colorblind async - same code works sync and async!
    std.debug.print("Writing with colorblind async...\n", .{});

    const messages = [_][]const u8{
        "Hello from zsync!\n",
        "This is colorblind async.\n",
        "Same code works sync and async!\n",
    };

    // Vectorized write - writes multiple buffers efficiently
    var future = try io.writev(&messages);
    defer future.destroy(allocator);

    // Colorblind await - adapts to execution context
    try future.await();

    std.debug.print("\nI/O Mode: {}\n", .{io.getMode()});
    std.debug.print("Supports vectorized: {}\n", .{io.supportsVectorized()});
    std.debug.print("Supports zero-copy: {}\n", .{io.supportsZeroCopy()});

    std.debug.print("\nDone!\n", .{});
}
