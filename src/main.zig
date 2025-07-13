const std = @import("std");
const Zsync = @import("root.zig");

pub fn main() !void {
    const print = std.debug.print;
    
    print("🚀 Zsync v0.1 - Colorblind Async Runtime!\n", .{});
    print("===========================================\n\n", .{});
    
    print("💡 Same code works across ALL execution models:\n", .{});
    print("   • BlockingIo (C-equivalent performance)\n", .{});
    print("   • ThreadPoolIo (OS thread parallelism)\n", .{});  
    print("   • GreenThreadsIo (cooperative multitasking)\n", .{});
    print("   • StacklessIo (WASM-compatible)\n\n", .{});
    
    // Test all execution models with the SAME code
    try testAllExecutionModels();
    
    print("\n🎯 Running comprehensive examples...\n", .{});
    try runV2Examples();
    
    print("\n🔄 Legacy v1.x compatibility test...\n", .{});
    try legacyCompatibilityTest();
    
    print("\n🏁 Zsync v0.1 showcase completed!\n", .{});
    print("🌟 Fully aligned with Zig's new async I/O paradigm!\n", .{});
}

fn testAllExecutionModels() !void {
    const allocator = std.heap.page_allocator;
    const test_data = "Zsync v0.1 test data";
    
    // 1. BlockingIo - C-equivalent performance
    {
        std.debug.print("📊 Testing BlockingIo...\n", .{});
        var blocking_io = Zsync.BlockingIo.init(allocator);
        defer blocking_io.deinit();
        
        const io = blocking_io.io();
        try Zsync.saveData(allocator, io, test_data);
        std.debug.print("✅ BlockingIo test completed!\n", .{});
    }
    
    // 2. ThreadPoolIo - OS thread parallelism
    {
        std.debug.print("📊 Testing ThreadPoolIo...\n", .{});
        var threadpool_io = try Zsync.ThreadPoolIo.init(allocator, .{ .num_threads = 2 });
        defer threadpool_io.deinit();
        
        const io = threadpool_io.io();
        try Zsync.saveData(allocator, io, test_data);
        std.debug.print("✅ ThreadPoolIo test completed!\n", .{});
    }
    
    // 3. GreenThreadsIo - only on supported platforms
    if (@import("builtin").target.cpu.arch == .x86_64 and @import("builtin").target.os.tag == .linux) {
        std.debug.print("📊 Testing GreenThreadsIo (x86_64 Linux)...\n", .{});
        var greenthreads_io = try Zsync.GreenThreadsIo.init(allocator, .{});
        defer greenthreads_io.deinit();
        
        try Zsync.saveData(allocator, greenthreads_io.io(), test_data);
        std.debug.print("✅ GreenThreadsIo test completed!\n", .{});
    } else {
        std.debug.print("⚠️  GreenThreadsIo skipped (requires x86_64 Linux)\n", .{});
    }
    
    // 4. StacklessIo - WASM compatible
    {
        std.debug.print("📊 Testing StacklessIo...\n", .{});
        var stackless_io = Zsync.StacklessIo.init(allocator, .{});
        defer stackless_io.deinit();
        
        try Zsync.saveData(allocator, stackless_io.io(), test_data);
        std.debug.print("✅ StacklessIo test completed!\n", .{});
    }
    
    // Clean up test files
    std.fs.cwd().deleteFile("saveA.txt") catch {};
    std.fs.cwd().deleteFile("saveB.txt") catch {};
}

fn runV2Examples() !void {
    const examples = Zsync.examples_v2;
    
    try examples.benchmarkSuite();
    
    // Use BlockingIo for the demo
    const allocator = std.heap.page_allocator;
    var blocking_io = Zsync.BlockingIo.init(allocator);
    defer blocking_io.deinit();
    
    try examples.realWorldApp(blocking_io.io());
    
    // Clean up any example files
    std.fs.cwd().deleteFile("processed_config.txt") catch {};
    std.fs.cwd().deleteFile("processed_data.log") catch {};
    std.fs.cwd().deleteFile("processed_cache.json") catch {};
}

fn legacyCompatibilityTest() !void {
    std.debug.print("🔄 Testing v1.x compatibility layer...\n", .{});
    
    // Create a runtime using the legacy API
    const runtime = try Zsync.Runtime.init(std.heap.page_allocator, .{});
    defer runtime.deinit();
    
    try runtime.run(legacyDemo);
    
    std.debug.print("✅ Legacy compatibility confirmed!\n", .{});
}

fn legacyDemo() !void {
    std.debug.print("   📱 Legacy v1.x demo running\n", .{});
    std.debug.print("   ✅ v1.x APIs still work alongside v0.1!\n", .{});
}

test "v0.1 functionality" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    // Test that all v0.1 Io implementations can be created
    var blocking_io = Zsync.BlockingIo.init(allocator);
    defer blocking_io.deinit();
    
    var threadpool_io = try Zsync.ThreadPoolIo.init(allocator, .{ .num_threads = 1 });
    defer threadpool_io.deinit();
    
    var stackless_io = Zsync.StacklessIo.init(allocator, .{});
    defer stackless_io.deinit();
    
    // Test colorblind async function works with all
    try Zsync.saveData(allocator, blocking_io.io(), "test");
    try Zsync.saveData(allocator, threadpool_io.io(), "test");
    try Zsync.saveData(allocator, stackless_io.io(), "test");
    
    // Clean up
    std.fs.cwd().deleteFile("saveA.txt") catch {};
    std.fs.cwd().deleteFile("saveB.txt") catch {};
    
    try testing.expect(true);
}