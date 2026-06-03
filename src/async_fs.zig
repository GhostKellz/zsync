//! zsync - Async Filesystem Operations
//! Filesystem helpers built on `std.Io`. These are thin convenience wrappers
//! that carry an `std.Io` handle (and an allocator), performing their work
//! through the runtime's I/O backend rather than blocking `std.fs` calls.

const std = @import("std");

const Io = std.Io;
const Dir = std.Io.Dir;
const File = std.Io.File;

/// Async file handle. Reads and writes track an internal cursor and are issued
/// as positional operations through the supplied `std.Io`.
pub const AsyncFile = struct {
    file: File,
    io: Io,
    allocator: std.mem.Allocator,
    pos: u64 = 0,

    const Self = @This();

    /// Open an existing file relative to the current working directory.
    pub fn open(allocator: std.mem.Allocator, io: Io, path: []const u8, flags: Dir.OpenFileOptions) !Self {
        const file = try Dir.cwd().openFile(io, path, flags);
        return Self{ .file = file, .io = io, .allocator = allocator };
    }

    /// Create (or truncate) a file relative to the current working directory.
    pub fn create(allocator: std.mem.Allocator, io: Io, path: []const u8, flags: Dir.CreateFileOptions) !Self {
        const file = try Dir.cwd().createFile(io, path, flags);
        return Self{ .file = file, .io = io, .allocator = allocator };
    }

    /// Read from the current cursor into `buffer`, advancing the cursor by the
    /// number of bytes read. Returns the number of bytes read (0 at EOF).
    pub fn read(self: *Self, buffer: []u8) !usize {
        const n = try self.file.readPositionalAll(self.io, buffer, self.pos);
        self.pos += n;
        return n;
    }

    /// Write `buffer` at the current cursor, advancing the cursor. Returns the
    /// number of bytes written.
    pub fn write(self: *Self, buffer: []const u8) !usize {
        try self.file.writePositionalAll(self.io, buffer, self.pos);
        self.pos += buffer.len;
        return buffer.len;
    }

    /// Read the entire file into freshly allocated memory.
    pub fn readToEnd(self: *Self, allocator: std.mem.Allocator) ![]u8 {
        const st = try self.file.stat(self.io);
        const size = st.size;

        const buffer = try allocator.alloc(u8, size);
        errdefer allocator.free(buffer);

        const bytes_read = try self.file.readPositionalAll(self.io, buffer, 0);
        if (bytes_read != size) {
            return error.UnexpectedEof;
        }

        return buffer;
    }

    /// Write all of `buffer` at the current cursor, advancing the cursor.
    pub fn writeAll(self: *Self, buffer: []const u8) !void {
        try self.file.writePositionalAll(self.io, buffer, self.pos);
        self.pos += buffer.len;
    }

    /// Move the read/write cursor to an absolute position.
    pub fn seekTo(self: *Self, pos: u64) void {
        self.pos = pos;
    }

    /// Get the current cursor position.
    pub fn getPos(self: *Self) u64 {
        return self.pos;
    }

    /// Get the file size in bytes.
    pub fn getSize(self: *Self) !u64 {
        const st = try self.file.stat(self.io);
        return st.size;
    }

    /// Flush file contents to durable storage.
    pub fn sync(self: *Self) !void {
        return self.file.sync(self.io);
    }

    /// Close the file handle.
    pub fn close(self: *Self) void {
        self.file.close(self.io);
    }
};

/// Async directory operations.
pub const AsyncDir = struct {
    dir: Dir,
    io: Io,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Open a directory (with iteration enabled) relative to the cwd.
    pub fn open(allocator: std.mem.Allocator, io: Io, path: []const u8) !Self {
        const dir = try Dir.cwd().openDir(io, path, .{ .iterate = true });
        return Self{ .dir = dir, .io = io, .allocator = allocator };
    }

    /// Create a directory relative to the cwd.
    pub fn create(io: Io, path: []const u8) !void {
        try Dir.cwd().createDir(io, path, .default_dir);
    }

    /// List directory contents. Caller owns the returned list and its items;
    /// free items individually and `deinit(allocator)` the list.
    pub fn list(self: *Self, allocator: std.mem.Allocator) !std.ArrayList([]const u8) {
        var result: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (result.items) |item| {
                allocator.free(item);
            }
            result.deinit(allocator);
        }

        var iter = self.dir.iterate();
        while (try iter.next(self.io)) |entry| {
            const name = try allocator.dupe(u8, entry.name);
            try result.append(allocator, name);
        }

        return result;
    }

    /// Check if a path exists within this directory.
    pub fn exists(self: *Self, path: []const u8) bool {
        self.dir.access(self.io, path, .{}) catch return false;
        return true;
    }

    /// Remove a file within this directory.
    pub fn removeFile(self: *Self, path: []const u8) !void {
        try self.dir.deleteFile(self.io, path);
    }

    /// Remove a sub-directory within this directory.
    pub fn removeDir(self: *Self, path: []const u8) !void {
        try self.dir.deleteDir(self.io, path);
    }

    /// Close the directory handle.
    pub fn close(self: *Self) void {
        self.dir.close(self.io);
    }
};

/// High-level async filesystem API. Carries an `std.Io` handle for all
/// operations against the current working directory.
pub const AsyncFs = struct {
    allocator: std.mem.Allocator,
    io: Io,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, io: Io) Self {
        return Self{ .allocator = allocator, .io = io };
    }

    /// Read file contents into freshly allocated memory.
    pub fn readFile(self: *Self, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        var file = try AsyncFile.open(self.allocator, self.io, path, .{});
        defer file.close();

        return file.readToEnd(allocator);
    }

    /// Write file contents, truncating any existing file.
    pub fn writeFile(self: *Self, path: []const u8, contents: []const u8) !void {
        var file = try AsyncFile.create(self.allocator, self.io, path, .{});
        defer file.close();

        try file.writeAll(contents);
    }

    /// Append contents to the end of a file.
    pub fn appendFile(self: *Self, path: []const u8, contents: []const u8) !void {
        var file = try AsyncFile.open(self.allocator, self.io, path, .{ .mode = .write_only });
        defer file.close();

        file.seekTo(try file.getSize());
        try file.writeAll(contents);
    }

    /// Copy a file within the current working directory.
    pub fn copyFile(self: *Self, source: []const u8, dest: []const u8) !void {
        try Dir.cwd().copyFile(source, Dir.cwd(), dest, self.io, .{});
    }

    /// Remove a file relative to the cwd.
    pub fn removeFile(self: *Self, path: []const u8) !void {
        try Dir.cwd().deleteFile(self.io, path);
    }

    /// Create a directory relative to the cwd.
    pub fn createDir(self: *Self, path: []const u8) !void {
        try Dir.cwd().createDir(self.io, path, .default_dir);
    }

    /// Remove a directory relative to the cwd.
    pub fn removeDir(self: *Self, path: []const u8) !void {
        try Dir.cwd().deleteDir(self.io, path);
    }

    /// Check if a path exists relative to the cwd.
    pub fn exists(self: *Self, path: []const u8) bool {
        Dir.cwd().access(self.io, path, .{}) catch return false;
        return true;
    }

    /// Get file metadata relative to the cwd.
    pub fn metadata(self: *Self, path: []const u8) !File.Stat {
        var file = try Dir.cwd().openFile(self.io, path, .{});
        defer file.close(self.io);
        return file.stat(self.io);
    }
};

// Tests
test "async file read/write" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Write file (request read access so we can read it back on the same handle)
    var file = try AsyncFile.create(allocator, io, "test_async.txt", .{ .read = true });
    defer file.close();
    defer Dir.cwd().deleteFile(io, "test_async.txt") catch {};

    try file.writeAll("Hello, Async FS!");

    // Read back
    file.seekTo(0);
    var buffer: [100]u8 = undefined;
    const bytes_read = try file.read(&buffer);

    try testing.expectEqualStrings("Hello, Async FS!", buffer[0..bytes_read]);
}

test "async fs high-level API" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var fs = AsyncFs.init(allocator, io);

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
