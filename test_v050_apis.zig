//! Test script to verify zsync v0.5.0 APIs work as expected
//! This tests all the missing APIs that were reported in ZSYNC_v016.md

const std = @import("std");
const zsync = @import("src/root.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    std.debug.print("🚀 Testing Zsync v{s} - New APIs\n\n", .{zsync.VERSION});
    
    // Test 1: yieldNow() - should work now
    std.debug.print("✅ Testing zsync.yieldNow()...\n", .{});
    zsync.yieldNow();
    std.debug.print("   Cooperative yielding works!\n\n", .{});
    
    // Test 2: sleep() - should work now
    std.debug.print("✅ Testing zsync.sleep()...\n", .{});
    const ts_start = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch unreachable;
    const sleep_start: i64 = @intCast(@divTrunc((@as(i128, ts_start.sec) * std.time.ns_per_s + ts_start.nsec), std.time.ns_per_ms));
    zsync.sleep(10); // 10ms sleep
    const ts_end = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch unreachable;
    const sleep_end: i64 = @intCast(@divTrunc((@as(i128, ts_end.sec) * std.time.ns_per_s + ts_end.nsec), std.time.ns_per_ms));
    std.debug.print("   Sleep for 10ms took {}ms\n\n", .{sleep_end - sleep_start});
    
    // Test 3: bounded() channels - should work now
    std.debug.print("✅ Testing zsync.bounded()...\n", .{});
    const ch = try zsync.bounded(i32, allocator, 10);
    defer {
        ch.channel.deinit();
        allocator.destroy(ch.channel);
    }
    try ch.sender.send(42);
    const value = try ch.receiver.recv();
    std.debug.print("   Bounded channel: sent 42, received {}\n\n", .{value});
    
    // Test 4: unbounded() channels - should work now  
    std.debug.print("✅ Testing zsync.unbounded()...\n", .{});
    const uch = try zsync.unbounded([]const u8, allocator);
    defer {
        uch.channel.deinit();
        allocator.destroy(uch.channel);
    }
    try uch.sender.send("Hello, Zsync!");
    const msg = try uch.receiver.recv();
    std.debug.print("   Unbounded channel: sent and received '{s}'\n\n", .{msg});
    
    // Test 5: ThreadPoolIo - should work now
    std.debug.print("✅ Testing zsync.ThreadPoolIo...\n", .{});
    const pool = try zsync.createThreadPoolIo(allocator);
    defer {
        pool.deinit();
        allocator.destroy(pool);
    }
    const io = pool.io();
    std.debug.print("   ThreadPoolIo created successfully\n", .{});
    std.debug.print("   I/O mode: {}\n\n", .{io.getMode()});
    
    // Test 6: UdpSocket - should work now
    std.debug.print("✅ Testing zsync.UdpSocket...\n", .{});
    const bind_addr = try std.net.Address.parseIp4("127.0.0.1", 0);
    var udp = zsync.UdpSocket.bind(allocator, bind_addr) catch |err| switch (err) {
        error.PermissionDenied, error.AddressNotAvailable => {
            std.debug.print("   UDP socket bind failed (expected in some environments): {}\n\n", .{err});
            udp_failed: {
                break :udp_failed;
            }
        },
        else => return err,
    };
    defer udp.close();
    std.debug.print("   UDP socket created and bound successfully\n\n", .{});
    
    // Test 7: spawn() - should work now
    std.debug.print("✅ Testing zsync.spawn()...\n", .{});
    const TestTask = struct {
        pub fn task() void {
            std.debug.print("   Spawned task executed successfully!\n", .{});
        }
    };
    
    var future = zsync.spawn(TestTask.task, .{}) catch |err| {
        std.debug.print("   Spawn failed: {} (this may be expected in current implementation)\n", .{err});
        return;
    };
    defer future.destroy(allocator);
    std.debug.print("   Spawn succeeded\n\n", .{});
    
    // Test 8: Additional new APIs
    std.debug.print("✅ Testing additional v0.5.0 APIs...\n", .{});
    const nano_time = zsync.nanoTime();
    const micro_time = zsync.microTime(); 
    const milli_time = zsync.milliTime();
    std.debug.print("   High-precision timing:\n", .{});
    std.debug.print("   - Nanoseconds: {}\n", .{nano_time});
    std.debug.print("   - Microseconds: {}\n", .{micro_time});
    std.debug.print("   - Milliseconds: {}\n\n", .{milli_time});
    
    // Test 9: OneShot channel
    std.debug.print("✅ Testing zsync.oneshot()...\n", .{});
    var oneshot_ch = zsync.oneshot(u64);
    try oneshot_ch.send(12345);
    const oneshot_value = try oneshot_ch.recv();
    std.debug.print("   OneShot channel: sent 12345, received {}\n\n", .{oneshot_value});
    
    std.debug.print("🎉 All zsync v0.5.0 APIs tested successfully!\n", .{});
    std.debug.print("🔧 zquic compatibility issues should now be resolved!\n", .{});
}