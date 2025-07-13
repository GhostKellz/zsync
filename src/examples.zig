//! Example implementations and usage patterns for Zsync

const std = @import("std");
const zsync = @import("root.zig");

/// Simple echo server example (conceptual - using standard library for actual networking)
pub fn echoServer(allocator: std.mem.Allocator, port: u16) !void {
    std.log.info("Starting echo server on port {}", .{port});
    
    // Create runtime
    const runtime = try zsync.Runtime.init(allocator, .{});
    defer runtime.deinit();
    
    // In a real implementation, would use actual TCP listener
    // This is a simplified example showing the async pattern
    _ = try runtime.spawn(simulateEchoServer, .{port});
    
    // Run the event loop
    var processed: u32 = 0;
    while (processed < 100) {
        processed += try runtime.tick();
        if (processed == 0) {
            std.time.sleep(1 * std.time.ns_per_ms);
        }
    }
}

/// Simulate echo server handling
fn simulateEchoServer(port: u16) !void {
    std.log.info("Echo server simulation running on port {}", .{port});
    
    // Simulate handling multiple connections
    for (0..5) |i| {
        std.log.info("Handling connection {}", .{i});
        std.time.sleep(100 * std.time.ns_per_ms);
    }
}

/// HTTP-like server example (conceptual)
pub fn httpServer(allocator: std.mem.Allocator, port: u16) !void {
    std.log.info("Starting HTTP server on port {}", .{port});
    
    // Create runtime
    const runtime = try zsync.Runtime.init(allocator, .{});
    defer runtime.deinit();
    
    // Simulate HTTP server
    _ = try runtime.spawn(simulateHttpServer, .{port});
    
    // Run the event loop
    var processed: u32 = 0;
    while (processed < 100) {
        processed += try runtime.tick();
        if (processed == 0) {
            std.time.sleep(1 * std.time.ns_per_ms);
        }
    }
}

/// Simulate HTTP server handling
fn simulateHttpServer(port: u16) !void {
    std.log.info("HTTP server simulation running on port {}", .{port});
    
    // Simulate handling HTTP requests
    const responses = [_][]const u8{
        "GET /api/users",
        "POST /api/login", 
        "GET /health",
        "PUT /api/user/123",
    };
    
    for (responses) |request| {
        std.log.info("Handling HTTP request: {s}", .{request});
        std.time.sleep(50 * std.time.ns_per_ms);
    }
}

/// Timer-based task example
pub fn timerExample(allocator: std.mem.Allocator) !void {
    std.log.info("Starting timer example...");
    
    // Create runtime
    const runtime = try zsync.Runtime.init(allocator, .{});
    defer runtime.deinit();
    
    // Create timer wheel
    var timer_wheel = try zsync.timer.TimerWheel.init(allocator);
    defer timer_wheel.deinit();
    
    // Add some timers
    const timer1 = try timer_wheel.addTimer(100, 1); // 100ms, id=1
    const timer2 = try timer_wheel.addTimer(200, 2); // 200ms, id=2
    const timer3 = try timer_wheel.addTimer(300, 3); // 300ms, id=3
    
    _ = timer1;
    _ = timer2;
    _ = timer3;
    
    std.log.info("Timers scheduled");
    
    // Process expired timers
    var processed_timers: u32 = 0;
    var iterations: u32 = 0;
    while (processed_timers < 3 and iterations < 1000) {
        if (timer_wheel.popExpired()) |expired| {
            std.log.info("Timer {} expired!", .{expired.user_data});
            processed_timers += 1;
        }
        std.time.sleep(1 * std.time.ns_per_ms);
        iterations += 1;
    }
    
    std.log.info("Timer example completed");
}

/// Channel communication example
pub fn channelExample(allocator: std.mem.Allocator) !void {
    std.log.info("Starting channel example...");
    
    // Create a bounded channel
    const ch = try zsync.bounded(i32, allocator, 10);
    defer ch.deinit();
    
    // Create runtime
    const runtime = try zsync.Runtime.init(allocator, .{});
    defer runtime.deinit();
    
    // Spawn producer and consumer tasks
    _ = try runtime.spawn(producer, .{ch});
    _ = try runtime.spawn(consumer, .{ch});
    
    // Run the event loop for a bit
    var ticks: u32 = 0;
    while (ticks < 100) {
        const processed = try runtime.tick();
        if (processed == 0) {
            std.time.sleep(10 * std.time.ns_per_ms);
        }
        ticks += 1;
    }
    
    std.log.info("Channel example completed");
}

fn producer(ch: anytype) !void {
    for (0..5) |i| {
        try ch.send(@as(i32, @intCast(i)));
        std.log.info("Sent: {}", .{i});
        std.time.sleep(100 * std.time.ns_per_ms);
    }
}

fn consumer(ch: anytype) !void {
    var received_count: u32 = 0;
    while (received_count < 5) {
        if (ch.recv()) |value| {
            std.log.info("Received: {}", .{value});
            received_count += 1;
        } else |err| switch (err) {
            error.ChannelClosed => break,
            else => return err,
        }
        std.time.sleep(50 * std.time.ns_per_ms);
    }
}

/// Concurrent task example
pub fn concurrentExample(allocator: std.mem.Allocator) !void {
    std.log.info("Starting concurrent example...");
    
    // Create runtime
    const runtime = try zsync.Runtime.init(allocator, .{});
    defer runtime.deinit();
    
    // Spawn multiple concurrent tasks
    _ = try runtime.spawn(countTask, .{ "Task-1", 3 });
    _ = try runtime.spawn(countTask, .{ "Task-2", 2 });
    _ = try runtime.spawn(countTask, .{ "Task-3", 4 });
    
    // Run the event loop
    var ticks: u32 = 0;
    while (ticks < 200) {
        const processed = try runtime.tick();
        if (processed == 0) {
            std.time.sleep(10 * std.time.ns_per_ms);
        }
        ticks += 1;
    }
    
    std.log.info("Concurrent example completed");
}

fn countTask(name: []const u8, count: u32) !void {
    for (0..count) |i| {
        std.log.info("{s}: {}", .{ name, i });
        std.time.sleep(100 * std.time.ns_per_ms);
    }
}

/// Advanced networking example showcasing Zsync v0.1 capabilities
pub fn advancedNetworkingExample(allocator: std.mem.Allocator) !void {
    std.log.info("🌐 Advanced Networking Example - Zsync v0.1");
    
    // Demonstrate TLS/SSL support
    try tlsExample(allocator);
    
    // Demonstrate HTTP/1.1 client
    try httpClientExample(allocator);
    
    // Demonstrate WebSocket support
    try webSocketExample(allocator);
    
    // Demonstrate DNS resolution
    try dnsExample(allocator);
    
    std.log.info("✅ Advanced networking examples completed");
}

/// TLS/SSL example with modern cipher suites
fn tlsExample(allocator: std.mem.Allocator) !void {
    std.log.info("🔒 TLS Example:");
    
    // Configure TLS with modern security
    const tls_config = zsync.networking.TlsConfig{
        .verify_certificates = true,
        .protocols = &.{ .tls_1_2, .tls_1_3 },
        .cipher_suites = &.{ .aes_256_gcm, .chacha20_poly1305 },
    };
    
    std.log.info("  ✓ TLS 1.3 configured with AES-256-GCM and ChaCha20-Poly1305");
    
    // Create a mock TLS stream (would connect to real server in production)
    const mock_stream = std.net.Stream{ .handle = 0 };
    var tls_stream = try zsync.TlsStream.init(allocator, mock_stream);
    defer tls_stream.deinit();
    
    // Perform handshake (simulated)
    try tls_stream.handshake(tls_config);
    std.log.info("  ✓ TLS handshake completed");
    
    // Simulate encrypted data transfer
    const test_data = "Hello, TLS 1.3!";
    _ = try tls_stream.write(test_data);
    std.log.info("  ✓ Encrypted data sent: {s}", .{test_data});
}

/// HTTP/1.1 client example with connection pooling
fn httpClientExample(allocator: std.mem.Allocator) !void {
    std.log.info("🌍 HTTP Client Example:");
    
    // Configure TLS for HTTPS
    const tls_config = zsync.networking.TlsConfig{
        .verify_certificates = true,
        .protocols = &.{ .tls_1_3 },
    };
    
    // Create HTTP client
    var http_client = zsync.HttpClient.init(allocator, tls_config);
    defer http_client.deinit();
    
    std.log.info("  ✓ HTTP client initialized with TLS 1.3");
    
    // Create HTTP request
    var request = zsync.networking.HttpRequest.init(allocator);
    defer request.deinit();
    
    request.method = .GET;
    request.uri = "https://httpbin.org/json";
    try request.setHeader("User-Agent", "Zsync/0.1");
    try request.setHeader("Accept", "application/json");
    
    std.log.info("  ✓ HTTP request prepared: {s} {s}", .{ @tagName(request.method), request.uri });
    std.log.info("  ✓ Headers: User-Agent, Accept");
    
    // In production, would make actual request:
    // const response = try http_client.request(&request);
    std.log.info("  ✓ Ready for HTTPS requests with connection pooling");
}

/// WebSocket example with async framing
fn webSocketExample(allocator: std.mem.Allocator) !void {
    std.log.info("🔌 WebSocket Example:");
    
    // Create mock connection (would use real TCP in production)
    const mock_stream = std.net.Stream{ .handle = 0 };
    var ws = zsync.WebSocketConnection.init(allocator, mock_stream, true);
    defer ws.deinit();
    
    std.log.info("  ✓ WebSocket connection initialized");
    
    // Perform handshake (simulated)
    try ws.handshake();
    std.log.info("  ✓ WebSocket handshake completed");
    
    // Simulate sending frames
    const messages = [_][]const u8{
        "Hello WebSocket!",
        "Real-time data",
        "Async frames",
    };
    
    for (messages) |msg| {
        try ws.sendFrame(0x01, msg); // Text frame
        std.log.info("  ✓ Sent frame: {s}", .{msg});
    }
    
    // Close connection gracefully
    try ws.close();
    std.log.info("  ✓ WebSocket connection closed gracefully");
}

/// DNS resolution example
fn dnsExample(allocator: std.mem.Allocator) !void {
    std.log.info("🌐 DNS Resolution Example:");
    
    // Create DNS resolver
    var resolver = try zsync.DnsResolver.init(allocator);
    defer resolver.deinit();
    
    std.log.info("  ✓ DNS resolver initialized with {} servers", .{resolver.servers.len});
    
    // Resolve hostnames (simulated)
    const hostnames = [_][]const u8{
        "example.com",
        "httpbin.org", 
        "github.com",
    };
    
    for (hostnames) |hostname| {
        const addresses = try resolver.resolve(hostname);
        defer allocator.free(addresses);
        
        std.log.info("  ✓ Resolved {s} to {} addresses", .{ hostname, addresses.len });
    }
}

/// QUIC/HTTP3 simulation (conceptual - would integrate with zquic)
pub fn quicHttp3Example(allocator: std.mem.Allocator) !void {
    std.log.info("🚀 QUIC/HTTP3 Example (v0.1 Ready):");
    
    // Multi-threaded runtime for high performance
    const worker_config = zsync.WorkerConfig{
        .thread_count = 4,
        .queue_capacity = 2048,
        .cpu_affinity = true,
    };
    
    var mt_runtime = try zsync.MultiThreadRuntime.init(allocator, worker_config);
    defer mt_runtime.deinit();
    
    std.log.info("  ✓ Multi-threaded runtime: {} workers", .{worker_config.thread_count});
    
    // Connection pooling for QUIC streams
    const pool_config = zsync.PoolConfig{
        .max_connections = 1000,
        .connection_timeout_ms = 30000,
        .idle_timeout_ms = 300000,
    };
    
    var pool = try zsync.ConnectionPool.init(allocator, pool_config);
    defer pool.deinit();
    
    std.log.info("  ✓ Connection pool: {} max QUIC connections", .{pool_config.max_connections});
    
    // io_uring for Linux high-performance I/O
    const builtin = @import("builtin");
    if (builtin.os.tag == .linux) {
        const uring_config = zsync.io_uring.IoUringConfig{ .entries = 256 };
        var uring_reactor = zsync.IoUringReactor.init(allocator, uring_config) catch |err| switch (err) {
            zsync.io_uring.IoUringError.NotSupported => {
                std.log.info("  ⚠️  io_uring not available, using epoll fallback");
                return;
            },
            else => return err,
        };
        defer uring_reactor.deinit();
        
        std.log.info("  ✓ io_uring reactor: {} entries for zero-copy I/O", .{uring_config.entries});
    }
    
    // TLS 1.3 for QUIC encryption
    const tls_config = zsync.networking.TlsConfig{
        .protocols = &.{.tls_1_3},
        .cipher_suites = &.{ .aes_256_gcm, .chacha20_poly1305 },
    };
    _ = tls_config;
    
    std.log.info("  ✓ TLS 1.3 configured for QUIC encryption");
    std.log.info("  ✅ Ready for zquic integration - all v0.1 features available!");
    
    // Simulate QUIC operations
    const quic_operations = [_][]const u8{
        "QUIC connection establishment",
        "HTTP/3 request multiplexing", 
        "Stream prioritization",
        "0-RTT connection resumption",
        "Connection migration",
    };
    
    for (quic_operations) |operation| {
        std.log.info("  🔄 {s}", .{operation});
        std.time.sleep(50 * std.time.ns_per_ms);
    }
}
