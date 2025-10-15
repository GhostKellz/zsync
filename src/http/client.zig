//! Zsync v0.6.0 - HTTP Client
//! Async HTTP client built on zsync

const std = @import("std");
const server = @import("server.zig");

pub const Request = server.Request;
pub const Response = server.Response;

/// HTTP Client for making requests
pub const HttpClient = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
        };
    }

    /// Make a GET request
    pub fn get(self: *Self, url: []const u8) !Response {
        return self.request(.GET, url, null);
    }

    /// Make a POST request
    pub fn post(self: *Self, url: []const u8, body: ?[]const u8) !Response {
        return self.request(.POST, url, body);
    }

    /// Make a generic HTTP request
    pub fn request(self: *Self, method: Request.Method, url: []const u8, body: ?[]const u8) !Response {
        _ = method;
        _ = url;
        _ = body;

        // TODO: Implement actual HTTP client
        // For now, return a mock response
        var response = Response.init(self.allocator);
        response.status_code = 200;
        try response.write("Mock response");
        return response;
    }
};
