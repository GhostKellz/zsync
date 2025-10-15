//! Example: Semaphore for Rate Limiting
//! Shows how to use Semaphore to limit concurrency

const std = @import("std");
const zsync = @import("zsync");

pub fn main() !void {
    std.debug.print("\n🚦 Zsync v0.6.0 - Semaphore Example\n\n", .{});

    // Create semaphore with 3 permits (max 3 concurrent operations)
    var sem = zsync.Semaphore.init(3);

    std.debug.print("Semaphore initialized with 3 permits\n", .{});
    std.debug.print("Available permits: {}\n\n", .{sem.availablePermits()});

    // Simulate concurrent access
    std.debug.print("Task 1: Acquiring permit...\n", .{});
    sem.acquire();
    std.debug.print("Task 1: Acquired! Available: {}\n\n", .{sem.availablePermits()});

    std.debug.print("Task 2: Acquiring permit...\n", .{});
    sem.acquire();
    std.debug.print("Task 2: Acquired! Available: {}\n\n", .{sem.availablePermits()});

    std.debug.print("Task 3: Acquiring permit...\n", .{});
    sem.acquire();
    std.debug.print("Task 3: Acquired! Available: {}\n\n", .{sem.availablePermits()});

    // Try to acquire when none available
    std.debug.print("Task 4: Trying to acquire (should fail)...\n", .{});
    const acquired = sem.tryAcquire();
    std.debug.print("Task 4: tryAcquire() = {}\n\n", .{acquired});

    // Release permits
    std.debug.print("Task 1: Releasing permit...\n", .{});
    sem.release();
    std.debug.print("Available permits: {}\n\n", .{sem.availablePermits()});

    std.debug.print("Task 4: Trying again...\n", .{});
    const acquired2 = sem.tryAcquire();
    std.debug.print("Task 4: tryAcquire() = {}\n\n", .{acquired2});

    std.debug.print("✅ Semaphore example complete!\n\n", .{});
}
