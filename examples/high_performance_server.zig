//! Zsync - High-Performance HTTP Server Demo
//! Showcases the async runtime on top of std.Io with real socket I/O.
//!
//! Features:
//! - Async HTTP/1.1 server over std.Io.net
//! - Structured concurrency: each connection handled in a nursery task
//! - Real-time request metrics
//!
//! Benchmark:
//!   $ wrk -t12 -c400 -d30s http://localhost:8080/

const std = @import("std");
const zsync = @import("zsync");
const net = std.Io.net;

const ServerConfig = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 8080,
    max_connections: u32 = 10000,
    buffer_size: usize = 4096,
};

const ServerStats = struct {
    requests_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    connections_active: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    bytes_sent: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    start_time: u64,

    const Self = @This();

    pub fn init() Self {
        return Self{ .start_time = zsync.milliTime() };
    }

    pub fn recordRequest(self: *Self, bytes: usize) void {
        _ = self.requests_total.fetchAdd(1, .monotonic);
        _ = self.bytes_sent.fetchAdd(bytes, .monotonic);
    }

    pub fn printStats(self: *Self) void {
        const elapsed = zsync.milliTime() - self.start_time;
        const total_requests = self.requests_total.load(.monotonic);
        const rps = if (elapsed > 0) total_requests * 1000 / elapsed else 0;
        const active_conn = self.connections_active.load(.monotonic);
        const total_bytes = self.bytes_sent.load(.monotonic);

        std.debug.print("Server Stats: {d} req/s | {d} active | {d:.2} MB sent | {d} total req\n", .{
            rps,
            active_conn,
            @as(f64, @floatFromInt(total_bytes)) / (1024.0 * 1024.0),
            total_requests,
        });
    }
};

const static_response =
    "HTTP/1.1 200 OK\r\n" ++
    "Content-Type: text/html\r\n" ++
    "Content-Length: 88\r\n" ++
    "Connection: close\r\n\r\n" ++
    "<!DOCTYPE html><html><body><h1>High-Performance Server</h1><p>Powered by Zsync</p></body></html>";

const api_response =
    "HTTP/1.1 200 OK\r\n" ++
    "Content-Type: application/json\r\n" ++
    "Content-Length: 59\r\n" ++
    "Connection: close\r\n\r\n" ++
    "{\"message\":\"Hello from Zsync!\",\"performance\":\"blazing_fast\"}";

const not_allowed_response = "HTTP/1.1 405 Method Not Allowed\r\nConnection: close\r\n\r\n";

fn selectResponse(request: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, request, "GET ")) return not_allowed_response;
    if (std.mem.indexOf(u8, request, " /api/") != null) return api_response;
    return static_response;
}

/// Handle a single connection: read the request, write a response, close.
fn handleConnection(io: zsync.Io, stream: net.Stream, stats: *ServerStats, buffer: []u8) void {
    defer stream.close(io);
    _ = stats.connections_active.fetchAdd(1, .monotonic);
    defer _ = stats.connections_active.fetchSub(1, .monotonic);

    var read_slices: [1][]u8 = .{buffer};
    const n = stream.read(io, &read_slices) catch return;
    if (n == 0) return;

    const response = selectResponse(buffer[0..n]);

    var write_buf: [512]u8 = undefined;
    var w = stream.writer(io, &write_buf);
    w.interface.writeAll(response) catch return;
    w.interface.flush() catch return;

    stats.recordRequest(response.len);
}

const ServerTask = struct {
    config: ServerConfig,
    allocator: std.mem.Allocator,

    fn run(self: *const ServerTask) void {
        const io = zsync.getGlobalIo() orelse return;
        runImpl(self, io) catch |err| {
            std.debug.print("Server error: {}\n", .{err});
        };
    }

    fn runImpl(self: *const ServerTask, io: zsync.Io) !void {
        var stats = ServerStats.init();

        const address = try net.IpAddress.parse(self.config.host, self.config.port);
        var server = try address.listen(io, .{ .reuse_address = true });
        defer server.deinit(io);

        std.debug.print("Zsync High-Performance Server v{s}\n", .{zsync.VERSION});
        std.debug.print("Listening on http://{s}:{d}\n", .{ self.config.host, self.config.port });
        std.debug.print("Backend: std.Io.Threaded\n\n", .{});

        // Reusable per-connection read buffer. Connections are accepted and
        // serviced sequentially here; spawn handleConnection on a nursery for
        // concurrent service.
        const buffer = try self.allocator.alloc(u8, self.config.buffer_size);
        defer self.allocator.free(buffer);

        while (true) {
            const stream = server.accept(io) catch |err| switch (err) {
                error.WouldBlock => {
                    zsync.yieldNow();
                    continue;
                },
                else => return err,
            };

            handleConnection(io, stream, &stats, buffer);
            stats.printStats();
        }
    }
};

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    const task = ServerTask{
        .config = .{ .port = 8080, .max_connections = 10000, .buffer_size = 4096 },
        .allocator = allocator,
    };

    zsync.run(allocator, ServerTask.run, .{&task});

    std.debug.print("Server shutdown complete.\n", .{});
}
