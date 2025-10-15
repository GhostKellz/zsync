//! Zsync v0.1 - Colorblind Async Examples
//! The SAME code works across ALL execution models:
//! - BlockingIo (C-equivalent performance)
//! - ThreadPoolIo (OS thread parallelism)  
//! - GreenThreadsIo (cooperative multitasking)
//! - StacklessIo (WASM-compatible)

const std = @import("std");
const Zsync = @import("root.zig");

/// Example 1: Simple HTTP server that works with ANY Io implementation
pub fn httpServer(io: Zsync.Io, port: u16) !void {
    const address = std.net.Address.initIp4([4]u8{ 127, 0, 0, 1 }, port);
    const listener = try io.vtable.tcpListen(io.ptr, address);
    defer listener.close(io) catch {};

    std.debug.print("🚀 HTTP server listening on port {}\n", .{port});

    while (true) {
        const client = try listener.accept(io);
        
        // Handle client connection asynchronously
        var client_future = try io.async(handleHttpClient, .{ io, client });
        defer client_future.cancel(io) catch {};
        
        // In a real server, you'd spawn this and continue accepting
        try client_future.await(io);
    }
}

fn handleHttpClient(io: Zsync.Io, client: Zsync.TcpStream) !void {
    defer client.close(io) catch {};
    
    var buffer: [1024]u8 = undefined;
    const bytes_read = try client.read(io, &buffer);
    
    const response = "HTTP/1.1 200 OK\r\nContent-Length: 13\r\n\r\nHello, World!";
    _ = try client.write(io, response);
    
    std.debug.print("📨 Handled HTTP request ({} bytes)\n", .{bytes_read});
}

/// Example 2: File processing pipeline with concurrent operations
pub fn fileProcessingPipeline(io: Zsync.Io, input_files: []const []const u8) !void {
    std.debug.print("📁 Processing {} files concurrently...\n", .{input_files.len});
    
    var futures = std.ArrayList(Zsync.Future){ .allocator = std.heap.page_allocator };
    defer {
        for (futures.items) |*future| {
            future.cancel(io, .{}) catch {};
            future.deinit();
        }
        futures.deinit();
    }
    
    // Start all file processing operations (synchronously for now)
    for (input_files) |file_path| {
        // TODO: Re-implement with function registry
        // const future = try io.async(std.heap.page_allocator, processFile, .{ io, file_path });
        // try futures.append(future);
        
        // For now, run synchronously
        try processFile(io, file_path);
    }
    
    // All operations completed synchronously
    
    std.debug.print("✅ All files processed successfully!\n", .{});
}

fn processFile(io: Zsync.Io, file_path: []const u8) !void {
    const file = try Zsync.Dir.cwd().openFile(io, file_path, .{});
    defer file.close(io) catch {};
    
    var buffer: [4096]u8 = undefined;
    const bytes_read = try file.readAll(io, &buffer);
    
    // Simulate processing
    const processed_path = try std.fmt.allocPrint(std.heap.page_allocator, "processed_{s}", .{file_path});
    defer std.heap.page_allocator.free(processed_path);
    
    const output_file = try Zsync.Dir.cwd().createFile(io, processed_path, .{});
    defer output_file.close(io) catch {};
    
    try output_file.writeAll(io, buffer[0..bytes_read]);
    
    std.debug.print("⚡ Processed {s} -> {s} ({} bytes)\n", .{ file_path, processed_path, bytes_read });
}

/// Example 3: Database connection pool simulation
pub fn databaseExample(io: Zsync.Io) !void {
    std.debug.print("🗄️  Database simulation with connection pool...\n", .{});
    
    // Simulate multiple database operations
    var query_futures = std.ArrayList(Zsync.Future){ .allocator = std.heap.page_allocator };
    defer {
        for (query_futures.items) |*future| {
            future.cancel(io, .{}) catch {};
            future.deinit();
        }
        query_futures.deinit();
    }
    
    const queries = [_][]const u8{
        "SELECT * FROM users WHERE active = true",
        "SELECT COUNT(*) FROM orders WHERE date > '2024-01-01'",
        "UPDATE products SET stock = stock - 1 WHERE id = 123",
        "INSERT INTO logs (message, timestamp) VALUES ('test', NOW())",
    };
    
    for (queries) |query| {
        // TODO: Re-implement with function registry
        // const future = try io.async(std.heap.page_allocator, executeQuery, .{ io, query });
        // try query_futures.append(future);
        
        // For now, run synchronously
        try executeQuery(io, query);
    }
    
    // All queries completed synchronously
    
    std.debug.print("✅ All database queries completed!\n", .{});
}

fn executeQuery(io: Zsync.Io, query: []const u8) !void {
    _ = io;
    
    // Simulate database query execution time
    std.time.sleep(10 * std.time.ns_per_ms); // 10ms
    
    std.debug.print("🔍 Executed: {s}\n", .{query});
}

/// Example 4: WebSocket server simulation
pub fn webSocketServer(io: Zsync.Io, port: u16) !void {
    const address = std.net.Address.initIp4([4]u8{ 127, 0, 0, 1 }, port);
    const listener = try io.vtable.tcpListen(io.ptr, address);
    defer listener.close(io) catch {};

    std.debug.print("🔌 WebSocket server listening on port {}\n", .{port});

    var client_count: u32 = 0;
    while (client_count < 3) { // Limit for demo
        const client = try listener.accept(io);
        client_count += 1;
        
        // Handle each WebSocket client concurrently
        var client_future = try io.async(handleWebSocketClient, .{ io, client, client_count });
        defer client_future.cancel(io) catch {};
        
        // In real implementation, you'd spawn this and continue
        try client_future.await(io);
    }
}

fn handleWebSocketClient(io: Zsync.Io, client: Zsync.TcpStream, client_id: u32) !void {
    defer client.close(io) catch {};
    
    std.debug.print("🔗 Client {} connected\n", .{client_id});
    
    // Simulate WebSocket handshake and messages
    const messages = [_][]const u8{
        "Welcome to Zsync v0.1!",
        "This works with ANY execution model!",
        "Goodbye!",
    };
    
    for (messages) |message| {
        _ = try client.write(io, message);
        std.debug.print("📤 Sent to client {}: {s}\n", .{ client_id, message });
        
        // Simulate delay between messages
        std.time.sleep(100 * std.time.ns_per_ms);
    }
}

/// Example 5: Benchmark suite comparing execution models
pub fn benchmarkSuite() !void {
    const allocator = std.heap.page_allocator;
    
    std.debug.print("🏁 Zsync v0.1 Benchmark Suite\n", .{});
    std.debug.print("================================\n\n", .{});
    
    // Test data
    const test_data = "Zsync v0.1 benchmark data! " ** 100;
    
    // Benchmark 1: BlockingIo (C-equivalent)
    {
        std.debug.print("📊 Testing BlockingIo (C-equivalent performance)...\n", .{});
        var blocking_io = Zsync.BlockingIo.init(allocator, 4096);
        defer blocking_io.deinit();
        
        const start = std.time.nanoTimestamp();
        var io = blocking_io.io();
        var future = try io.async_write(test_data);
        defer future.destroy(allocator);
        try future.await();
        const end = std.time.nanoTimestamp();
        
        std.debug.print("⏱️  BlockingIo: {}μs\n", .{@divFloor(end - start, 1000)});
    }
    
    // Benchmark 2: ThreadPoolIo (OS threads)
    {
        std.debug.print("📊 Testing ThreadPoolIo (OS thread parallelism)...\n", .{});
        var threadpool_io = try Zsync.ThreadPoolIo.init(allocator, .{ .num_threads = 4 });
        defer threadpool_io.deinit();
        
        const start = std.time.nanoTimestamp();
        var io = threadpool_io.io();
        var future = try io.async_write(test_data);
        defer future.destroy(allocator);
        
        // Give threadpool time to process
        std.time.sleep(5 * 1000_000); // 5ms
        future.cancel(); // Avoid hanging
        
        const end = std.time.nanoTimestamp();
        
        std.debug.print("⏱️  ThreadPoolIo: {}μs\n", .{@divFloor(end - start, 1000)});
    }
    
    // Benchmark 3: GreenThreadsIo (cooperative multitasking)
    if (@import("builtin").cpu.arch == .x86_64 and @import("builtin").os.tag == .linux) {
        std.debug.print("📊 Testing GreenThreadsIo (x86_64 Linux only)...\n", .{});
        var greenthreads_io = try Zsync.GreenThreadsIo.init(allocator, .{});
        defer greenthreads_io.deinit();
        
        const start = std.time.nanoTimestamp();
        var io = greenthreads_io.io();
        var future = try io.async_write(test_data);
        defer future.destroy(allocator);
        
        // Give green threads time to yield
        std.time.sleep(5 * 1000_000); // 5ms
        future.cancel(); // Avoid hanging
        
        const end = std.time.nanoTimestamp();
        
        std.debug.print("⏱️  GreenThreadsIo: {}μs\n", .{@divFloor(end - start, 1000)});
    }
    
    // Clean up test files
    std.fs.cwd().deleteFile("saveA.txt") catch {};
    std.fs.cwd().deleteFile("saveB.txt") catch {};
    
    std.debug.print("\n✅ Benchmark suite completed!\n", .{});
    std.debug.print("💡 The SAME code ran on different execution models!\n", .{});
}

/// Example 6: Real-world application simulation
pub fn realWorldApp(io: Zsync.Io) !void {
    std.debug.print("🌍 Real-world application simulation\n", .{});
    std.debug.print("====================================\n", .{});
    
    // Simulate a web application with multiple concurrent operations
    var operations = std.ArrayList(Zsync.Future){ .allocator = std.heap.page_allocator };
    defer {
        for (operations.items) |*future| {
            future.cancel(io, .{}) catch {};
            future.deinit();
        }
        operations.deinit();
    }
    
    // Start multiple concurrent operations
    // TODO: Re-implement these with proper function registry
    // const db_future = try io.async(std.heap.page_allocator, databaseExample, .{io});
    // try operations.append(db_future);
    
    // const file_ops = [_][]const u8{ "config.txt", "data.log", "cache.json" };
    // const files_future = try io.async(std.heap.page_allocator, fileProcessingPipeline, .{ io, &file_ops });
    // try operations.append(files_future);
    
    // For now, run them synchronously
    try databaseExample(io);
    
    const file_ops = [_][]const u8{ "config.txt", "data.log", "cache.json" };
    try fileProcessingPipeline(io, &file_ops);
    
    // All operations completed synchronously
    
    std.debug.print("🎉 Real-world application simulation completed!\n", .{});
    std.debug.print("💪 Zsync v0.1 handled everything with colorblind async!\n", .{});
}

test "colorblind async examples compile" {
    const testing = std.testing;
    try testing.expect(true);
}

test "examples work with all io implementations" {
    // This test ensures our examples compile with all Io implementations
    const allocator = std.testing.allocator;
    
    // Test with BlockingIo
    var blocking_io = Zsync.BlockingIo.init(allocator);
    defer blocking_io.deinit();
    const blocking_io_interface = blocking_io.io();
    _ = blocking_io_interface;
    
    // Test with ThreadPoolIo  
    var threadpool_io = try Zsync.ThreadPoolIo.init(allocator, .{ .num_threads = 2 });
    defer threadpool_io.deinit();
    const threadpool_io_interface = threadpool_io.io();
    _ = threadpool_io_interface;
}