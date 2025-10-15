//! Example: Simple HTTP Server
//! Shows how to build an HTTP server with zsync v0.6.0

const std = @import("std");
const zsync = @import("zsync");
const http = zsync.http_server;

fn handleRequest(req: *http.Request, res: *http.Response) !void {
    std.debug.print("📥 {} {s}\n", .{ req.method, req.path });

    if (std.mem.eql(u8, req.path, "/")) {
        try res.status(200);
        try res.header("Content-Type", "text/html");
        try res.write(
            \\<!DOCTYPE html>
            \\<html>
            \\<head><title>Zsync HTTP Server</title></head>
            \\<body>
            \\  <h1>🚀 Zsync v0.6.0 HTTP Server</h1>
            \\  <p>High-performance async HTTP server built with zsync!</p>
            \\  <ul>
            \\    <li><a href="/api/status">API Status</a></li>
            \\    <li><a href="/api/version">Version Info</a></li>
            \\  </ul>
            \\</body>
            \\</html>
        );
    } else if (std.mem.eql(u8, req.path, "/api/status")) {
        try res.status(200);
        try res.header("Content-Type", "application/json");
        try res.write("{\"status\":\"ok\",\"uptime\":123}");
    } else if (std.mem.eql(u8, req.path, "/api/version")) {
        try res.status(200);
        try res.header("Content-Type", "application/json");
        try res.write("{\"version\":\"0.6.0\",\"runtime\":\"zsync\"}");
    } else {
        try res.status(404);
        try res.header("Content-Type", "text/plain");
        try res.write("404 Not Found");
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n", .{});
    std.debug.print("═══════════════════════════════════════════════════════════\n", .{});
    std.debug.print("  Zsync v0.6.0 HTTP Server Example\n", .{});
    std.debug.print("═══════════════════════════════════════════════════════════\n", .{});
    std.debug.print("\n", .{});

    const address = try std.net.Address.parseIp("127.0.0.1", 8080);

    std.debug.print("Starting HTTP server...\n", .{});
    std.debug.print("Open http://127.0.0.1:8080 in your browser\n", .{});
    std.debug.print("Press Ctrl+C to stop\n\n", .{});

    try http.listen(allocator, address, handleRequest);
}
