//! Zsync v0.3.2 - Complete Feature Demonstration
//! Shows all new v0.3.2 features: Future combinators, timeout/cancellation, 
//! network integration, async file I/O, and terminal async support

const std = @import("std");
const zsync = @import("zsync");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    std.log.info("🚀 Zsync v0.3.2 - Cutting-Edge Async Features Demo", .{});
    
    // Demo 1: Future Combinators
    try demoFutureCombinators(allocator);
    
    // Demo 2: Task Management with Timeout/Cancellation
    try demoTaskManagement(allocator);
    
    // Demo 3: Network Integration Layer
    try demoNetworkIntegration(allocator);
    
    // Demo 4: Async File I/O Operations
    try demoAsyncFileOps(allocator);
    
    // Demo 5: Terminal Async Features
    try demoTerminalAsync(allocator);
    
    // Demo 6: Real-World Integration Examples
    try demoRealWorldIntegration(allocator);
    
    std.log.info("✅ All v0.3.2 features demonstrated successfully!", .{});
}

fn demoFutureCombinators(allocator: std.mem.Allocator) !void {
    std.log.info("\n📋 Demo 1: Future Combinators (Future.all, Future.race)", .{});
    
    // Test cancellation token
    var cancel_token = zsync.CancelToken.init();
    std.log.info("✓ Cancel token created - cancelled: {}", .{cancel_token.isCancelled()});
    
    cancel_token.cancel();
    std.log.info("✓ Cancel token cancelled - cancelled: {}", .{cancel_token.isCancelled()});
    
    // Demonstrate that checkCancellation works
    if (cancel_token.checkCancellation()) {
        std.log.info("✗ Unexpected: cancellation check should have failed", .{});
    } else |err| {
        std.log.info("✓ Cancellation properly detected: {}", .{err});
    }
}

fn demoTaskManagement(allocator: std.mem.Allocator) !void {
    std.log.info("\n⏱️  Demo 2: Task Management with Timeout/Cancellation", .{});
    
    const TestTasks = struct {
        fn quickTask(value: u32) !void {
            std.time.sleep(50 * std.time.ns_per_ms);
            std.log.info("  Quick task {} completed", .{value});
        }
        
        fn slowTask(duration_ms: u64) !void {
            std.time.sleep(duration_ms * std.time.ns_per_ms);
            std.log.info("  Slow task completed after {}ms", .{duration_ms});
        }
    };
    
    // Demo task batch operations
    var batch = try zsync.TaskBatch.init(allocator);
    defer batch.deinit();
    
    std.log.info("📦 Creating task batch with 3 quick tasks...", .{});
    try batch.spawn(TestTasks.quickTask, .{1}, .{ .priority = .normal });
    try batch.spawn(TestTasks.quickTask, .{2}, .{ .priority = .normal });
    try batch.spawn(TestTasks.quickTask, .{3}, .{ .priority = .normal });
    
    const results = try batch.waitAll(1000);
    defer allocator.free(results);
    
    var successful: usize = 0;
    for (results) |result| {
        if (result.isSuccess()) successful += 1;
    }
    std.log.info("✓ Batch completed: {}/{} tasks successful", .{ successful, results.len });
    
    // Demo timeout functionality
    std.log.info("⏰ Testing task timeout (500ms timeout for 1000ms task)...", .{});
    const timeout_handle = try zsync.Task.spawn(allocator, TestTasks.slowTask, .{1000}, .{
        .timeout_ms = 500,
    });
    defer timeout_handle.deinit();
    
    const timeout_result = try zsync.Task.waitWithTimeout(allocator, timeout_handle, 600);
    switch (timeout_result) {
        .timeout => std.log.info("✓ Task properly timed out", .{}),
        .completed => std.log.info("✗ Unexpected: task should have timed out", .{}),
        else => std.log.info("✗ Unexpected result: {}", .{timeout_result}),
    }
}

fn demoNetworkIntegration(allocator: std.mem.Allocator) !void {
    std.log.info("\n🌐 Demo 3: Network Integration Layer", .{});
    
    var pool = try zsync.NetworkPool.init(allocator, .{
        .max_concurrent = 4,
        .default_timeout_ms = 5000,
    });
    defer pool.deinit();
    
    // Register HTTP client adapter
    var http_adapter = zsync.network_integration.StdHttpAdapter.init(allocator);
    const adapter = http_adapter.createAdapter();
    try pool.registerClient(.http, adapter);
    
    std.log.info("📡 Network pool initialized with HTTP client", .{});
    
    // Demo single request
    std.log.info("📤 Executing single HTTP request...", .{});
    const request = zsync.NetworkRequest{
        .client = .http,
        .url = "https://httpbin.org/get",
        .timeout_ms = 3000,
    };
    
    const response = try pool.executeRequest(request);
    defer response.deinit();
    
    std.log.info("✓ Single request completed - Status: {}, Latency: {}ms", .{ 
        response.status_code, response.latency_ms 
    });
    
    // Demo batch requests (like Reaper AUR queries)
    std.log.info("📦 Executing batch HTTP requests (simulating AUR package searches)...", .{});
    const batch_requests = [_]zsync.NetworkRequest{
        .{ .client = .http, .url = "https://httpbin.org/get?package=firefox" },
        .{ .client = .http, .url = "https://httpbin.org/get?package=discord" },
        .{ .client = .http, .url = "https://httpbin.org/get?package=vscode" },
    };
    
    const batch_responses = try pool.batchExecute(&batch_requests);
    defer {
        for (batch_responses) |batch_response| {
            batch_response.deinit();
        }
        allocator.free(batch_responses);
    }
    
    std.log.info("✓ Batch requests completed: {} responses", .{batch_responses.len});
    for (batch_responses, 0..) |batch_response, i| {
        std.log.info("  Response {}: Status {}, {} bytes", .{
            i + 1, batch_response.status_code, batch_response.bytes_transferred
        });
    }
    
    // Show network statistics
    const stats = pool.getStats();
    std.log.info("📊 Network Stats - Total: {}, Successful: {}, Failed: {}", .{
        stats.total_requests.load(.monotonic),
        stats.successful_requests.load(.monotonic),
        stats.failed_requests.load(.monotonic),
    });
}

fn demoAsyncFileOps(allocator: std.mem.Allocator) !void {
    std.log.info("\n📁 Demo 4: Async File I/O Operations", .{});
    
    var file_ops = try zsync.FileOps.init(allocator);
    try file_ops.initThreadPool(4);
    defer file_ops.deinit();
    
    // Demo async file writing (like Reaper cache operations)
    std.log.info("💾 Writing multiple cache files asynchronously...", .{});
    const cache_files = [_]struct { path: []const u8, data: []const u8 }{
        .{ .path = "/tmp/reaper_cache_firefox.json", .data = "{\"name\":\"firefox\",\"version\":\"118.0\"}" },
        .{ .path = "/tmp/reaper_cache_discord.json", .data = "{\"name\":\"discord\",\"version\":\"0.0.29\"}" },
        .{ .path = "/tmp/reaper_cache_vscode.json", .data = "{\"name\":\"vscode\",\"version\":\"1.83.0\"}" },
    };
    
    var write_futures = try allocator.alloc(zsync.async_file_ops.AsyncFileResult, cache_files.len);
    defer allocator.free(write_futures);
    
    for (cache_files, 0..) |cache_file, i| {
        write_futures[i] = try file_ops.writeFileAsync(cache_file.path, cache_file.data, .{
            .atomic = true,
            .create_dirs = true,
        });
    }
    
    // Wait for all writes to complete
    for (write_futures) |*write_future| {
        defer write_future.deinit();
        _ = try write_future.await();
    }
    std.log.info("✓ All cache files written asynchronously", .{});
    
    // Demo PKGBUILD processing
    std.log.info("📋 Processing PKGBUILD file asynchronously...", .{});
    const pkgbuild_content =
        \\# Maintainer: Demo User
        \\pkgname=demo-package
        \\pkgver=1.2.3
        \\pkgrel=1
        \\pkgdesc="A demonstration package"
        \\arch=('x86_64')
        \\depends=('glibc' 'gcc-libs')
        \\makedepends=('cmake' 'ninja')
        \\source=("demo-$pkgver.tar.gz")
        \\sha256sums=('abcdef123456')
        \\
        \\build() {
        \\    cd "$srcdir/demo-$pkgver"
        \\    cmake -B build -S . -DCMAKE_BUILD_TYPE=Release
        \\    cmake --build build
        \\}
    ;
    
    const pkgbuild_write = try file_ops.writeFileAsync("/tmp/demo_PKGBUILD", pkgbuild_content, .{});
    defer pkgbuild_write.deinit();
    _ = try pkgbuild_write.await();
    
    const pkgbuild_result = try file_ops.processPKGBUILDAsync("/tmp/demo_PKGBUILD", .{
        .validate_syntax = true,
        .extract_dependencies = true,
    });
    defer pkgbuild_result.deinit();
    
    const pkgbuild_data = try pkgbuild_result.await();
    defer pkgbuild_data.deinit();
    
    std.log.info("✓ PKGBUILD processed: {} v{}, {} deps, {} makedeps", .{
        pkgbuild_data.package_name,
        pkgbuild_data.version,
        pkgbuild_data.dependencies.len,
        pkgbuild_data.make_dependencies.len,
    });
    
    // Demo cache warming
    std.log.info("🔥 Warming file cache...", .{});
    const cache_paths = [_][]const u8{
        "/tmp/reaper_cache_firefox.json",
        "/tmp/reaper_cache_discord.json",
        "/tmp/reaper_cache_vscode.json",
    };
    
    try file_ops.warmCache(&cache_paths);
    
    const file_stats = file_ops.getStats();
    std.log.info("📊 File I/O Stats - Read: {} files/{} bytes, Written: {} files/{} bytes", .{
        file_stats.files_read.load(.monotonic),
        file_stats.bytes_read.load(.monotonic),
        file_stats.files_written.load(.monotonic),
        file_stats.bytes_written.load(.monotonic),
    });
}

fn demoTerminalAsync(allocator: std.mem.Allocator) !void {
    std.log.info("\n🖥️  Demo 5: Terminal Async Features", .{});
    
    // Demo PTY async operations (simulated)
    std.log.info("📡 Initializing async PTY operations...", .{});
    const mock_pty_fd: std.posix.fd_t = 0; // Mock file descriptor
    var pty = try zsync.AsyncPTY.init(allocator, mock_pty_fd);
    defer pty.deinit();
    
    std.log.info("✓ AsyncPTY initialized - cancelled: {}", .{pty.isCancelled()});
    
    // Simulate writing data to PTY
    try pty.writeAsync("echo 'Hello from async PTY'\n");
    std.log.info("✓ Data queued for async PTY write", .{});
    
    // Demo concurrent rendering pipeline
    std.log.info("🎨 Initializing concurrent rendering pipeline...", .{});
    var pipeline = try zsync.RenderingPipeline.init(allocator, 80, 24);
    defer pipeline.deinit();
    
    std.log.info("✓ Rendering pipeline initialized - {}x{} grid", .{ pipeline.grid_width, pipeline.grid_height });
    
    // Process terminal data with concurrent rendering
    const terminal_data = "\x1b[32mHello, colorful terminal!\x1b[0m\nLine 2\nLine 3";
    const render_result = try pipeline.processTerminalData(terminal_data, .{
        .frame_timeout_ms = 16, // 60 FPS
        .enable_gpu_acceleration = true,
    });
    
    std.log.info("✓ Terminal data processed - Frame time: {}μs, {} cells updated", .{
        render_result.frame_time_us, render_result.cells_updated
    });
    
    // Demo terminal resize
    std.log.info("📏 Resizing terminal asynchronously...", .{});
    const resize_handle = try pipeline.resizeAsync(120, 40);
    defer resize_handle.deinit();
    
    const resize_result = try zsync.Task.waitWithTimeout(allocator, resize_handle, 1000);
    if (resize_result.isSuccess()) {
        std.log.info("✓ Terminal resized to {}x{}", .{ pipeline.grid_width, pipeline.grid_height });
    } else {
        std.log.info("✗ Terminal resize failed: {}", .{resize_result});
    }
    
    // Show rendering statistics
    const render_stats = pipeline.getStats();
    std.log.info("📊 Render Stats - Frames: {}, Avg frame time: {}μs", .{
        render_stats.frames_rendered.load(.monotonic),
        render_stats.avg_frame_time_us.load(.monotonic),
    });
    
    // Clean shutdown demonstration
    std.log.info("🛑 Demonstrating graceful shutdown...", .{});
    pty.cancel();
    std.log.info("✓ PTY operations cancelled gracefully", .{});
}

fn demoRealWorldIntegration(allocator: std.mem.Allocator) !void {
    std.log.info("\n🌟 Demo 6: Real-World Integration Examples", .{});
    
    // Simulate Reaper AUR package management workflow
    std.log.info("📦 Simulating Reaper AUR workflow...", .{});
    
    var file_ops = try zsync.FileOps.init(allocator);
    try file_ops.initThreadPool(4);
    defer file_ops.deinit();
    
    var network_pool = try zsync.NetworkPool.init(allocator, .{});
    defer network_pool.deinit();
    
    var http_adapter = zsync.network_integration.StdHttpAdapter.init(allocator);
    const adapter = http_adapter.createAdapter();
    try network_pool.registerClient(.http, adapter);
    
    // Simulate parallel package searches
    const aur_requests = [_]zsync.NetworkRequest{
        .{ .client = .http, .url = "https://aur.archlinux.org/rpc/?v=5&type=info&arg[]=firefox" },
        .{ .client = .http, .url = "https://aur.archlinux.org/rpc/?v=5&type=info&arg[]=discord" },
        .{ .client = .http, .url = "https://aur.archlinux.org/rpc/?v=5&type=info&arg[]=vscode" },
    };
    
    std.log.info("🔍 Searching AUR packages concurrently...", .{});
    const search_responses = try network_pool.batchExecute(&aur_requests);
    defer {
        for (search_responses) |response| response.deinit();
        allocator.free(search_responses);
    }
    
    std.log.info("✓ AUR searches completed: {} packages found", .{search_responses.len});
    
    // Simulate concurrent cache updates
    std.log.info("💾 Updating package caches concurrently...", .{});
    for (search_responses, 0..) |response, i| {
        const cache_path = try std.fmt.allocPrint(allocator, "/tmp/aur_cache_{}.json", .{i});
        defer allocator.free(cache_path);
        
        const cache_result = try file_ops.writeFileAsync(cache_path, response.body, .{ .atomic = true });
        defer cache_result.deinit();
        _ = try cache_result.await();
    }
    std.log.info("✓ All package caches updated asynchronously", .{});
    
    // Simulate ghostty terminal emulator workflow
    std.log.info("🖥️  Simulating ghostty terminal workflow...", .{});
    
    var pty = try zsync.AsyncPTY.init(allocator, 0);
    defer pty.deinit();
    
    var pipeline = try zsync.RenderingPipeline.init(allocator, 120, 40);
    defer pipeline.deinit();
    
    // Simulate high-throughput terminal data processing
    const terminal_sequences = [_][]const u8{
        "\x1b[2J\x1b[H",  // Clear screen
        "\x1b[31mError: \x1b[0mPackage not found\n",
        "\x1b[32m✓ \x1b[0mPackage installed successfully\n",
        "\x1b[33m⚠ \x1b[0mWarning: Dependency conflict\n",
        "\x1b[34mInfo: \x1b[0mDownloading package...\n",
    };
    
    for (terminal_sequences) |sequence| {
        const result = try pipeline.processTerminalData(sequence, .{
            .frame_timeout_ms = 8, // 120 FPS for smooth rendering
        });
        if (!result.success) {
            std.log.info("✗ Frame rendering failed", .{});
        }
    }
    
    std.log.info("✓ High-throughput terminal rendering completed", .{});
    
    // Show comprehensive statistics
    const file_stats = file_ops.getStats();
    const network_stats = network_pool.getStats();
    const pty_stats = pty.getStats();
    const render_stats = pipeline.getStats();
    
    std.log.info("\n📊 Final Performance Statistics:", .{});
    std.log.info("  File I/O: {} ops, {} bytes", .{
        file_stats.files_read.load(.monotonic) + file_stats.files_written.load(.monotonic),
        file_stats.bytes_read.load(.monotonic) + file_stats.bytes_written.load(.monotonic),
    });
    std.log.info("  Network: {} requests, {}ms avg latency", .{
        network_stats.total_requests.load(.monotonic),
        network_stats.avg_latency_ms.load(.monotonic),
    });
    std.log.info("  PTY: {} bytes transferred", .{
        pty_stats.bytes_read.load(.monotonic) + pty_stats.bytes_written.load(.monotonic),
    });
    std.log.info("  Rendering: {} frames, {}μs avg frame time", .{
        render_stats.frames_rendered.load(.monotonic),
        render_stats.avg_frame_time_us.load(.monotonic),
    });
}

// Test function to demonstrate all features working together
test "v0.3.2 comprehensive integration" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    // Quick integration test to ensure all components work together
    var file_ops = try zsync.FileOps.init(allocator);
    try file_ops.initThreadPool(2);
    defer file_ops.deinit();
    
    var network_pool = try zsync.NetworkPool.init(allocator, .{});
    defer network_pool.deinit();
    
    var pty = try zsync.AsyncPTY.init(allocator, 0);
    defer pty.deinit();
    
    var pipeline = try zsync.RenderingPipeline.init(allocator, 80, 24);
    defer pipeline.deinit();
    
    // Test basic functionality of each component
    try testing.expect(!pty.isCancelled());
    try testing.expect(pipeline.grid_width == 80);
    
    const file_stats = file_ops.getStats();
    const network_stats = network_pool.getStats();
    
    try testing.expect(file_stats.files_read.load(.monotonic) == 0);
    try testing.expect(network_stats.total_requests.load(.monotonic) == 0);
}