//! zsync Synchronization Example
//! Demonstrates sync primitives

const std = @import("std");
const zsync = @import("zsync");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("zsync v{s} - Synchronization Example\n", .{zsync.VERSION});
    std.debug.print("=====================================\n\n", .{});

    // Semaphore example
    std.debug.print("--- Semaphore ---\n", .{});
    var sem = zsync.Semaphore.init(allocator, 3);
    defer sem.deinit();

    std.debug.print("Semaphore with 3 permits\n", .{});

    // Acquire permits
    sem.acquire();
    std.debug.print("Acquired 1 permit (2 remaining)\n", .{});
    sem.acquire();
    std.debug.print("Acquired 1 permit (1 remaining)\n", .{});

    // Try acquire (non-blocking)
    if (sem.tryAcquire()) {
        std.debug.print("Try-acquired 1 permit (0 remaining)\n", .{});
    }

    // This would block if we didn't have permits
    if (!sem.tryAcquire()) {
        std.debug.print("Try-acquire failed (no permits)\n", .{});
    }

    // Release permits
    sem.release();
    std.debug.print("Released 1 permit\n", .{});

    // WaitGroup example
    std.debug.print("\n--- WaitGroup ---\n", .{});
    var wg = zsync.WaitGroup.init();

    wg.add(3);
    std.debug.print("Added 3 to wait group\n", .{});

    wg.done();
    std.debug.print("Done 1\n", .{});
    wg.done();
    std.debug.print("Done 2\n", .{});
    wg.done();
    std.debug.print("Done 3\n", .{});

    // Barrier example
    std.debug.print("\n--- Barrier ---\n", .{});
    var barrier = zsync.Barrier.init(allocator, 1);
    defer barrier.deinit();

    std.debug.print("Barrier with count 1\n", .{});
    barrier.wait();
    std.debug.print("Passed barrier!\n", .{});

    std.debug.print("\nDone!\n", .{});
}
