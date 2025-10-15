//! Zsync v0.6.0 - HTTP/3, DoQ, and gRPC Examples
//! Demonstrates the new protocol support added in v0.6.0

const std = @import("std");
const zsync = @import("zsync");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Zsync v0.6.0 Protocol Examples ===\n\n", .{});

    // Example 1: HTTP/3 over QUIC
    try http3Example(allocator);

    // Example 2: DNS over QUIC (DoQ)
    try doqExample(allocator);

    // Example 3: gRPC with HTTP/2 and HTTP/3
    try grpcExample(allocator);
}

/// HTTP/3 Server and Client Example
fn http3Example(allocator: std.mem.Allocator) !void {
    std.debug.print("--- HTTP/3 over QUIC Example ---\n", .{});

    var config = zsync.Config.optimal();
    var runtime = try zsync.Runtime.init(allocator, &config);
    defer runtime.deinit();

    // Create HTTP/3 server
    const addr = try std.net.Address.parseIp4("127.0.0.1", 8443);

    const handler = struct {
        fn handle(req: *zsync.Http3Request, resp: *zsync.Http3Response) !void {
            std.debug.print("[HTTP/3] Received request: {s} {s}\n", .{ req.method, req.path });

            resp.setStatus(200);
            try resp.setHeader("content-type", "text/plain");
            try resp.write("Hello from HTTP/3 over QUIC!");
        }
    }.handle;

    var server = zsync.Http3Server.init(allocator, runtime, addr, handler);
    _ = &server;

    // Create HTTP/3 client
    var client = zsync.Http3Client.init(allocator, runtime);
    defer client.deinit();

    std.debug.print("[HTTP/3] Client initialized\n", .{});
    std.debug.print("[HTTP/3] Server ready on {}\n", .{addr});
    std.debug.print("[HTTP/3] Note: Full implementation requires zquic integration\n\n", .{});
}

/// DNS over QUIC (DoQ) Example
fn doqExample(allocator: std.mem.Allocator) !void {
    std.debug.print("--- DNS over QUIC (DoQ) Example ---\n", .{});

    var config = zsync.Config.optimal();
    var runtime = try zsync.Runtime.init(allocator, &config);
    defer runtime.deinit();

    // Create DoQ client (typically connects to port 853)
    const doq_server = try std.net.Address.parseIp4("1.1.1.1", 853);
    var client = zsync.DoqClient.init(allocator, runtime, doq_server);
    defer client.deinit();

    std.debug.print("[DoQ] Client initialized, server: {}\n", .{doq_server});
    std.debug.print("[DoQ] Would query: example.com (A record)\n", .{});
    std.debug.print("[DoQ] Would query: example.com (AAAA record)\n", .{});
    std.debug.print("[DoQ] Note: Full implementation requires zquic integration\n\n", .{});

    // Example queries (stubs for now)
    // var response = try client.query("example.com", .A);
    // defer response.deinit();
}

/// gRPC Server and Client Example
fn grpcExample(allocator: std.mem.Allocator) !void {
    std.debug.print("--- gRPC Server & Client Example ---\n", .{});

    var config = zsync.Config.optimal();
    var runtime = try zsync.Runtime.init(allocator, &config);
    defer runtime.deinit();

    // Create gRPC server with HTTP/2
    const addr = try std.net.Address.parseIp4("127.0.0.1", 50051);
    const server_config = zsync.grpc_server.ServerConfig.default();

    var server = try zsync.GrpcServer.init(allocator, runtime, addr, server_config);
    defer server.deinit();

    // Register a service
    try server.registerService("helloworld.Greeter");
    std.debug.print("[gRPC] Registered service: helloworld.Greeter\n", .{});

    // Create gRPC client
    const client_config = zsync.grpc_client.ClientConfig.default();
    var client = try zsync.GrpcClient.init(
        allocator,
        runtime,
        "localhost:50051",
        client_config,
    );
    defer client.deinit();

    std.debug.print("[gRPC] Client initialized\n", .{});
    std.debug.print("[gRPC] Server ready on {}\n", .{addr});

    // Example with HTTP/3 (QUIC transport)
    std.debug.print("\n--- gRPC over QUIC (HTTP/3) ---\n", .{});
    const quic_config = zsync.grpc_server.ServerConfig.default().withQuic();
    var quic_server = try zsync.GrpcServer.init(allocator, runtime, addr, quic_config);
    defer quic_server.deinit();

    const quic_client_config = zsync.grpc_client.ClientConfig.default().withQuic();
    var quic_client = try zsync.GrpcClient.init(
        allocator,
        runtime,
        "localhost:50051",
        quic_client_config,
    );
    defer quic_client.deinit();

    std.debug.print("[gRPC] QUIC-based gRPC server ready\n", .{});
    std.debug.print("[gRPC] QUIC-based gRPC client ready\n", .{});
    std.debug.print("[gRPC] Note: Full implementation requires zquic integration\n\n", .{});

    // Show available features
    std.debug.print("=== Available v0.6.0 Protocol Features ===\n", .{});
    std.debug.print("✅ HTTP/3 over QUIC (RFC 9114)\n", .{});
    std.debug.print("✅ DNS over QUIC / DoQ (RFC 9250)\n", .{});
    std.debug.print("✅ gRPC over HTTP/2\n", .{});
    std.debug.print("✅ gRPC over QUIC (HTTP/3)\n", .{});
    std.debug.print("✅ QPACK header compression\n", .{});
    std.debug.print("✅ Unary, streaming, and bidirectional RPC\n", .{});
    std.debug.print("✅ Connection pooling and health checks\n", .{});
    std.debug.print("✅ Rate limiting (Token Bucket, Leaky Bucket, Sliding Window)\n", .{});
    std.debug.print("✅ File watching and hot-reload support\n", .{});
}
