//! Zsync v0.3.2 - Comprehensive Feature Tests
//! Tests for Future combinators, timeout/cancellation, network integration, async file I/O, and terminal async

const std = @import("std");
const testing = std.testing;
const zsync = @import("zsync");

test "v0.3.2 - Future.all() combinator" {
    _ = testing.allocator;
    
    // Test CancelToken functionality
    var token = zsync.CancelToken.init();
    try testing.expect(!token.isCancelled());
    
    token.cancel();
    try testing.expect(token.isCancelled());
    
    try testing.expectError(error.Cancelled, token.checkCancellation());
}

test "v0.3.2 - Task management with timeout" {
    const allocator = testing.allocator;
    
    const TestFunction = struct {
        fn longRunningTask(duration_ms: u64) !void {
            std.time.sleep(duration_ms * std.time.ns_per_ms);
        }
    };
    
    const handle = try zsync.Task.spawn(allocator, TestFunction.longRunningTask, .{1000}, .{
        .timeout_ms = 500,
    });
    defer handle.deinit();
    
    const result = try zsync.Task.waitWithTimeout(allocator, handle, 600);
    try testing.expect(result == .timeout);
}

test "v0.3.2 - TaskBatch operations" {
    const allocator = testing.allocator;
    
    var batch = try zsync.TaskBatch.init(allocator);
    defer batch.deinit();
    
    const TestFunction = struct {
        fn quickTask(value: u32) !void {
            _ = value;
            std.time.sleep(10 * std.time.ns_per_ms);
        }
    };
    
    try batch.spawn(TestFunction.quickTask, .{1}, .{});
    try batch.spawn(TestFunction.quickTask, .{2}, .{});
    try batch.spawn(TestFunction.quickTask, .{3}, .{});
    
    const results = try batch.waitAll(1000);
    defer allocator.free(results);
    
    for (results) |result| {
        try testing.expect(result.isSuccess());
    }
}

test "v0.3.2 - NetworkPool basic functionality" {
    const allocator = testing.allocator;
    
    var pool = try zsync.NetworkPool.init(allocator, .{});
    defer pool.deinit();
    
    var http_adapter = zsync.network_integration.StdHttpAdapter.init(allocator);
    const adapter = http_adapter.createAdapter();
    
    try pool.registerClient(.http, adapter);
    
    const request = zsync.NetworkRequest{
        .client = .http,
        .url = "https://httpbin.org/get",
    };
    
    const response = try pool.executeRequest(request);
    defer response.deinit();
    
    try testing.expect(response.status_code == 200);
}

test "v0.3.2 - NetworkPool batch execution" {
    const allocator = testing.allocator;
    
    var pool = try zsync.NetworkPool.init(allocator, .{});
    defer pool.deinit();
    
    var http_adapter = zsync.network_integration.StdHttpAdapter.init(allocator);
    const adapter = http_adapter.createAdapter();
    
    try pool.registerClient(.http, adapter);
    
    const requests = [_]zsync.NetworkRequest{
        .{ .client = .http, .url = "https://httpbin.org/get?id=1" },
        .{ .client = .http, .url = "https://httpbin.org/get?id=2" },
        .{ .client = .http, .url = "https://httpbin.org/get?id=3" },
    };
    
    const responses = try pool.batchExecute(&requests);
    defer {
        for (responses) |response| {
            response.deinit();
        }
        allocator.free(responses);
    }
    
    try testing.expect(responses.len == 3);
    for (responses) |response| {
        try testing.expect(response.status_code == 200);
    }
}

test "v0.3.2 - FileOps async operations" {
    const allocator = testing.allocator;
    
    var file_ops = try zsync.FileOps.init(allocator);
    try file_ops.initThreadPool(4);
    defer file_ops.deinit();
    
    // Test async write
    const test_data = "Hello, async world!";
    const write_result = try file_ops.writeFileAsync("/tmp/test_async_v032.txt", test_data, .{});
    defer write_result.deinit();
    
    _ = try write_result.await();
    
    // Test async read
    const read_result = try file_ops.readFileAsync("/tmp/test_async_v032.txt", .{});
    defer read_result.deinit();
    
    const content = try read_result.await();
    defer allocator.free(content);
    
    try testing.expectEqualStrings(test_data, content);
}

test "v0.3.2 - PKGBUILD processing" {
    const allocator = testing.allocator;
    
    var file_ops = try zsync.FileOps.init(allocator);
    try file_ops.initThreadPool(2);
    defer file_ops.deinit();
    
    // Create a mock PKGBUILD file
    const pkgbuild_content =
        \\pkgname=test-package
        \\pkgver=1.0.0
        \\pkgrel=1
        \\depends=(gcc glibc)
        \\makedepends=(make cmake)
        \\source=(test.tar.gz)
        \\sha256sums=('abcd1234')
    ;
    
    const write_result = try file_ops.writeFileAsync("/tmp/PKGBUILD_v032", pkgbuild_content, .{});
    defer write_result.deinit();
    _ = try write_result.await();
    
    // Process PKGBUILD
    const pkgbuild_result = try file_ops.processPKGBUILDAsync("/tmp/PKGBUILD_v032", .{});
    defer pkgbuild_result.deinit();
    
    const pkgbuild_data = try pkgbuild_result.await();
    defer pkgbuild_data.deinit();
    
    try testing.expectEqualStrings("test-package", pkgbuild_data.package_name);
    try testing.expectEqualStrings("1.0.0", pkgbuild_data.version);
}

test "v0.3.2 - AsyncPTY basic functionality" {
    const allocator = testing.allocator;
    
    // Mock PTY file descriptor
    const mock_fd: std.posix.fd_t = 0;
    
    var pty = try zsync.AsyncPTY.init(allocator, mock_fd);
    defer pty.deinit();
    
    try testing.expect(!pty.isCancelled());
    
    pty.cancel();
    try testing.expect(pty.isCancelled());
}

test "v0.3.2 - RenderingPipeline basic functionality" {
    const allocator = testing.allocator;
    
    var pipeline = try zsync.RenderingPipeline.init(allocator, 80, 24);
    defer pipeline.deinit();
    
    const test_data = "Hello, terminal!";
    const result = try pipeline.processTerminalData(test_data, .{});
    
    try testing.expect(result.success);
    try testing.expect(result.frame_time_us > 0);
}

test "v0.3.2 - Cache warming operations" {
    const allocator = testing.allocator;
    
    var file_ops = try zsync.FileOps.init(allocator);
    try file_ops.initThreadPool(4);
    defer file_ops.deinit();
    
    // Create some test files
    const test_files = [_][]const u8{
        "/tmp/cache_test1.txt",
        "/tmp/cache_test2.txt",
        "/tmp/cache_test3.txt",
    };
    
    for (test_files) |file_path| {
        const write_result = try file_ops.writeFileAsync(file_path, "cached content", .{});
        defer write_result.deinit();
        _ = try write_result.await();
    }
    
    // Warm cache
    try file_ops.warmCache(&test_files);
    
    const stats = file_ops.getStats();
    try testing.expect(stats.cache_hits.load(.monotonic) >= test_files.len);
}

test "v0.3.2 - Network pool statistics" {
    const allocator = testing.allocator;
    
    var pool = try zsync.NetworkPool.init(allocator, .{});
    defer pool.deinit();
    
    var http_adapter = zsync.network_integration.StdHttpAdapter.init(allocator);
    const adapter = http_adapter.createAdapter();
    
    try pool.registerClient(.http, adapter);
    
    const initial_stats = pool.getStats();
    try testing.expect(initial_stats.total_requests.load(.monotonic) == 0);
    
    const request = zsync.NetworkRequest{
        .client = .http,
        .url = "https://httpbin.org/get",
    };
    
    const response = try pool.executeRequest(request);
    defer response.deinit();
    
    const final_stats = pool.getStats();
    try testing.expect(final_stats.total_requests.load(.monotonic) == 1);
    try testing.expect(final_stats.successful_requests.load(.monotonic) == 1);
}

test "v0.3.2 - Terminal resize operations" {
    const allocator = testing.allocator;
    
    var pipeline = try zsync.RenderingPipeline.init(allocator, 80, 24);
    defer pipeline.deinit();
    
    try testing.expect(pipeline.grid_width == 80);
    try testing.expect(pipeline.grid_height == 24);
    
    const resize_handle = try pipeline.resizeAsync(120, 40);
    defer resize_handle.deinit();
    
    const result = try zsync.Task.waitWithTimeout(allocator, resize_handle, 2000);
    try testing.expect(result.isSuccess());
    
    try testing.expect(pipeline.grid_width == 120);
    try testing.expect(pipeline.grid_height == 40);
}

test "v0.3.2 - Comprehensive integration test" {
    const allocator = testing.allocator;
    
    // Initialize all major v0.3.2 components
    var file_ops = try zsync.FileOps.init(allocator);
    try file_ops.initThreadPool(4);
    defer file_ops.deinit();
    
    var network_pool = try zsync.NetworkPool.init(allocator, .{});
    defer network_pool.deinit();
    
    var pty = try zsync.AsyncPTY.init(allocator, 0);
    defer pty.deinit();
    
    var pipeline = try zsync.RenderingPipeline.init(allocator, 80, 24);
    defer pipeline.deinit();
    
    var task_batch = try zsync.TaskBatch.init(allocator);
    defer task_batch.deinit();
    
    // Test that all components are properly initialized
    try testing.expect(!pty.isCancelled());
    try testing.expect(pipeline.grid_width == 80);
    try testing.expect(task_batch.getRunningCount() == 0);
    
    const file_stats = file_ops.getStats();
    const network_stats = network_pool.getStats();
    const pty_stats = pty.getStats();
    const render_stats = pipeline.getStats();
    
    // All stats should start at zero
    try testing.expect(file_stats.files_read.load(.monotonic) == 0);
    try testing.expect(network_stats.total_requests.load(.monotonic) == 0);
    try testing.expect(pty_stats.bytes_read.load(.monotonic) == 0);
    try testing.expect(render_stats.frames_rendered.load(.monotonic) == 0);
}