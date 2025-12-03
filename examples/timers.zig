//! zsync Timers Example
//! Demonstrates timer and sleep functionality

const std = @import("std");
const zsync = @import("zsync");

pub fn main() !void {
    std.debug.print("zsync v{s} - Timers Example\n", .{zsync.VERSION});
    std.debug.print("============================\n\n", .{});

    // High-precision timing
    const start_ms = zsync.milliTime();
    std.debug.print("Start time: {}ms\n", .{start_ms});

    // Simple sleep
    std.debug.print("\nSleeping for 100ms...\n", .{});
    zsync.sleep(100);

    const after_sleep = zsync.milliTime();
    std.debug.print("Elapsed: {}ms\n", .{after_sleep - start_ms});

    // Measure function execution time
    std.debug.print("\n--- Measuring Execution Time ---\n", .{});

    const WorkFunc = struct {
        fn doWork() u64 {
            var sum: u64 = 0;
            for (0..1000000) |i| {
                sum +%= i;
            }
            return sum;
        }
    };

    const result = zsync.measure(WorkFunc.doWork, .{});
    std.debug.print("Work result: {}\n", .{result.result});
    std.debug.print("Duration: {}ns ({d:.2}ms)\n", .{
        result.duration_ns,
        @as(f64, @floatFromInt(result.duration_ns)) / 1_000_000.0,
    });

    // Nanosecond precision
    std.debug.print("\n--- Precision Timestamps ---\n", .{});
    std.debug.print("Nano time:  {}\n", .{zsync.nanoTime()});
    std.debug.print("Micro time: {}\n", .{zsync.microTime()});
    std.debug.print("Milli time: {}\n", .{zsync.milliTime()});

    std.debug.print("\nDone!\n", .{});
}
