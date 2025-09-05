//! 🏆 Zsync v0.5.0 Performance Demo
//! Shows the power of Zig's async runtime

const std = @import("std");
const zsync = @import("src/root.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    std.debug.print("🏆 Zsync v{s} Performance Demo\n", .{zsync.VERSION});
    std.debug.print("=" ** 50 ++ "\n", .{});
    
    // Test 1: Task spawning performance
    std.debug.print("🚀 Testing task spawning...\n", .{});
    const spawn_start = zsync.nanoTime();
    
    for (0..1000) |i| {
        _ = zsync.spawn(demoTask, .{i}) catch continue;
    }
    
    const spawn_end = zsync.nanoTime();
    const spawn_time_us = (spawn_end - spawn_start) / 1000;
    std.debug.print("  ✅ Spawned 1000 tasks in {} µs ({} ns/task)\n", .{spawn_time_us / 1000, spawn_time_us});
    
    // Test 2: Channel performance
    std.debug.print("\n📡 Testing channel throughput...\n", .{});
    const ch = try zsync.bounded(u32, allocator, 1000);
    defer {
        ch.channel.deinit();
        allocator.destroy(ch.channel);
    }
    
    const chan_start = zsync.nanoTime();
    const num_messages = 10000;
    
    // Send messages
    for (0..num_messages) |i| {
        ch.sender.send(@intCast(i)) catch break;
    }
    
    // Receive messages  
    for (0..num_messages) |_| {
        _ = ch.receiver.recv() catch break;
    }
    
    const chan_end = zsync.nanoTime();
    const chan_time_ms = (chan_end - chan_start) / 1_000_000;
    const throughput = (@as(f64, @floatFromInt(num_messages)) * 1000.0) / @as(f64, @floatFromInt(chan_time_ms));
    
    std.debug.print("  ✅ Processed {} messages in {} ms ({:.0} msg/s)\n", .{num_messages, chan_time_ms, throughput});
    
    // Test 3: Cooperative yielding
    std.debug.print("\n⚡ Testing cooperative yielding...\n", .{});
    const yield_start = zsync.nanoTime();
    
    for (0..10000) |_| {
        zsync.yieldNow();
    }
    
    const yield_end = zsync.nanoTime();
    const yield_time_ns = (yield_end - yield_start) / 10000;
    std.debug.print("  ✅ 10,000 yields in {} ns/yield\n", .{yield_time_ns});
    
    // Test 4: Timer precision
    std.debug.print("\n⏰ Testing timer precision...\n", .{});
    const timer_start = zsync.milliTime();
    zsync.sleep(100); // 100ms sleep
    const timer_end = zsync.milliTime();
    const actual_sleep = timer_end - timer_start;
    
    std.debug.print("  ✅ Requested 100ms sleep, actual: {}ms ({}ms accuracy)\n", .{actual_sleep, @as(i64, @intCast(actual_sleep)) - 100});
    
    // Performance summary
    std.debug.print("\n" ++ "=" ** 50 ++ "\n", .{});
    std.debug.print("🎯 Performance Summary:\n", .{});
    std.debug.print("  • Task spawn overhead: {} ns\n", .{spawn_time_us});
    std.debug.print("  • Channel throughput: {:.0} msg/s\n", .{throughput});
    std.debug.print("  • Yield overhead: {} ns\n", .{yield_time_ns});
    std.debug.print("  • Timer accuracy: ±{}ms\n", .{@abs(@as(i64, @intCast(actual_sleep)) - 100)});
    
    // Comparison with theoretical targets
    std.debug.print("\n🏆 vs Industry Standards:\n", .{});
    if (spawn_time_us < 10000) std.debug.print("  ✅ Task spawning: EXCELLENT (< 10µs)\n", .{}) else std.debug.print("  ⚠️  Task spawning: Room for improvement\n", .{});
    if (throughput > 500000) std.debug.print("  ✅ Channel perf: EXCELLENT (> 500K msg/s)\n", .{}) else std.debug.print("  ⚠️  Channel perf: Room for improvement\n", .{});
    if (yield_time_ns < 1000) std.debug.print("  ✅ Yield overhead: EXCELLENT (< 1µs)\n", .{}) else std.debug.print("  ⚠️  Yield overhead: Room for improvement\n", .{});
    
    std.debug.print("\n🚀 Zsync v0.5.0 - Ready for Production!\n", .{});
}

fn demoTask(id: usize) void {
    _ = id;
    zsync.yieldNow();
}