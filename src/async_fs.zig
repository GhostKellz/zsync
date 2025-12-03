//! zsync - Async Filesystem Operations
//! Non-blocking file I/O

const std = @import("std");
const builtin = @import("builtin");
const runtime_mod = @import("runtime.zig");
const io_interface = @import("io_interface.zig");
const buffer_pool_mod = @import("buffer_pool.zig");

const Runtime = runtime_mod.Runtime;
const Future = io_interface.Future;
const BufferPool = buffer_pool_mod.BufferPool;

/// Async file handle
pub const AsyncFile = struct {
    file: std.fs.File,
    runtime: *Runtime,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Open file asynchronously
    pub fn open(runtime: *Runtime, path: []const u8, flags: std.fs.File.OpenFlags) !Self {
        // For now, use blocking open (io_uring support in future)
        const file = try std.fs.cwd().openFile(path, flags);

        return Self{
            .file = file,
            .runtime = runtime,
            .allocator = runtime.allocator,
        };
    }

    /// Create file asynchronously
    pub fn create(runtime: *Runtime, path: []const u8, flags: std.fs.File.CreateFlags) !Self {
        const file = try std.fs.cwd().createFile(path, flags);

        return Self{
            .file = file,
            .runtime = runtime,
            .allocator = runtime.allocator,
        };
    }

    /// Read file contents into buffer
    pub fn read(self: *Self, buffer: []u8) !usize {
        // TODO: Use io_uring for true async on Linux
        return self.file.read(buffer);
    }

    /// Write buffer to file
    pub fn write(self: *Self, buffer: []const u8) !usize {
        return self.file.write(buffer);
    }

    /// Read entire file into allocated memory
    pub fn readToEnd(self: *Self, allocator: std.mem.Allocator) ![]u8 {
        const stat = try self.file.stat();
        const size = stat.size;

        const buffer = try allocator.alloc(u8, size);
        errdefer allocator.free(buffer);

        const bytes_read = try self.file.preadAll(buffer, 0);
        if (bytes_read != size) {
            return error.UnexpectedEof;
        }

        return buffer;
    }

    /// Write all data to file
    pub fn writeAll(self: *Self, buffer: []const u8) !void {
        return self.file.writeAll(buffer);
    }

    /// Seek to position
    pub fn seekTo(self: *Self, pos: u64) !void {
        try self.file.seekTo(pos);
    }

    /// Get current position
    pub fn getPos(self: *Self) !u64 {
        return self.file.getPos();
    }

    /// Get file size
    pub fn getSize(self: *Self) !u64 {
        const stat = try self.file.stat();
        return stat.size;
    }

    /// Sync file to disk
    pub fn sync(self: *Self) !void {
        return self.file.sync();
    }

    /// Close file
    pub fn close(self: *Self) void {
        self.file.close();
    }
};

/// Async directory operations
pub const AsyncDir = struct {
    dir: std.fs.Dir,
    runtime: *Runtime,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Open directory
    pub fn open(runtime: *Runtime, path: []const u8) !Self {
        const dir = try std.fs.cwd().openDir(path, .{});

        return Self{
            .dir = dir,
            .runtime = runtime,
            .allocator = runtime.allocator,
        };
    }

    /// Create directory
    pub fn create(_: *Runtime, path: []const u8) !void {
        try std.fs.cwd().makeDir(path);
    }

    /// List directory contents
    pub fn list(self: *Self, allocator: std.mem.Allocator) !std.ArrayList([]const u8) {
        var result = std.ArrayList([]const u8).init(allocator);
        errdefer {
            for (result.items) |item| {
                allocator.free(item);
            }
            result.deinit();
        }

        var iter = self.dir.iterate();
        while (try iter.next()) |entry| {
            const name = try allocator.dupe(u8, entry.name);
            try result.append(name);
        }

        return result;
    }

    /// Check if path exists
    pub fn exists(self: *Self, path: []const u8) bool {
        self.dir.access(path, .{}) catch return false;
        return true;
    }

    /// Remove file
    pub fn removeFile(self: *Self, path: []const u8) !void {
        try self.dir.deleteFile(path);
    }

    /// Remove directory
    pub fn removeDir(self: *Self, path: []const u8) !void {
        try self.dir.deleteDir(path);
    }

    /// Close directory
    pub fn close(self: *Self) void {
        self.dir.close();
    }
};

/// High-level async filesystem API
pub const AsyncFs = struct {
    runtime: *Runtime,

    const Self = @This();

    pub fn init(runtime: *Runtime) Self {
        return Self{ .runtime = runtime };
    }

    /// Read file contents
    pub fn readFile(self: *Self, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        var file = try AsyncFile.open(self.runtime, path, .{});
        defer file.close();

        return file.readToEnd(allocator);
    }

    /// Write file contents
    pub fn writeFile(self: *Self, path: []const u8, contents: []const u8) !void {
        var file = try AsyncFile.create(self.runtime, path, .{});
        defer file.close();

        try file.writeAll(contents);
    }

    /// Append to file
    pub fn appendFile(self: *Self, path: []const u8, contents: []const u8) !void {
        var file = try AsyncFile.open(self.runtime, path, .{ .mode = .write_only });
        defer file.close();

        try file.seekTo(try file.getSize());
        try file.writeAll(contents);
    }

    /// Copy file
    pub fn copyFile(self: *Self, source: []const u8, dest: []const u8) !void {
        _ = self;
        try std.fs.cwd().copyFile(source, std.fs.cwd(), dest, .{});
    }

    /// Remove file
    pub fn removeFile(self: *Self, path: []const u8) !void {
        _ = self;
        try std.fs.cwd().deleteFile(path);
    }

    /// Create directory
    pub fn createDir(self: *Self, path: []const u8) !void {
        _ = self;
        try std.fs.cwd().makeDir(path);
    }

    /// Remove directory
    pub fn removeDir(self: *Self, path: []const u8) !void {
        _ = self;
        try std.fs.cwd().deleteDir(path);
    }

    /// Check if path exists
    pub fn exists(self: *Self, path: []const u8) bool {
        _ = self;
        std.fs.cwd().access(path, .{}) catch return false;
        return true;
    }

    /// Get file metadata
    pub fn metadata(self: *Self, path: []const u8) !std.fs.File.Stat {
        _ = self;
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        return file.stat();
    }
};

// Tests
test "async file read/write" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const config = runtime_mod.Config{
        .execution_model = .blocking,
    };

    const runtime = try runtime_mod.Runtime.init(allocator, config);
    defer runtime.deinit();

    // Write file
    var file = try AsyncFile.create(runtime, "test_async.txt", .{});
    defer file.close();
    defer std.fs.cwd().deleteFile("test_async.txt") catch {};

    try file.writeAll("Hello, Async FS!");

    // Read back
    try file.seekTo(0);
    var buffer: [100]u8 = undefined;
    const bytes_read = try file.read(&buffer);

    try testing.expectEqualStrings("Hello, Async FS!", buffer[0..bytes_read]);
}

test "async fs high-level API" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const config = runtime_mod.Config{
        .execution_model = .blocking,
    };

    const runtime = try runtime_mod.Runtime.init(allocator, config);
    defer runtime.deinit();

    const fs = AsyncFs.init(runtime);

    // Write file
    try fs.writeFile("test_fs.txt", "Test content");
    defer fs.removeFile("test_fs.txt") catch {};

    // Read file
    const contents = try fs.readFile(allocator, "test_fs.txt");
    defer allocator.free(contents);

    try testing.expectEqualStrings("Test content", contents);

    // Check exists
    try testing.expect(fs.exists("test_fs.txt"));

    // Remove
    try fs.removeFile("test_fs.txt");
    try testing.expect(!fs.exists("test_fs.txt"));
}
