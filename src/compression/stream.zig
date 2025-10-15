//! Zsync v0.6.0 - Async Compression Streaming
//! Async wrapper for compression libraries like zpack

const std = @import("std");
const Runtime = @import("../runtime.zig").Runtime;
const channels = @import("../channels.zig");

/// Compression Algorithm
pub const Algorithm = enum {
    lz77,
    rle,
    zlib,
    zstd,
    lz4,
};

/// Compression Level
pub const Level = enum(u8) {
    fastest = 1,
    default_ = 6,
    best = 9,
};

/// Compression Config
pub const CompressionConfig = struct {
    algorithm: Algorithm = .lz77,
    level: Level = .default_,
    buffer_size: usize = 64 * 1024, // 64 KB chunks
};

/// Async Compressor
pub const AsyncCompressor = struct {
    allocator: std.mem.Allocator,
    runtime: *Runtime,
    config: CompressionConfig,
    input_channel: channels.UnboundedChannel([]const u8),
    output_channel: channels.UnboundedChannel([]const u8),
    running: std.atomic.Value(bool),

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        runtime: *Runtime,
        config: CompressionConfig,
    ) !Self {
        return Self{
            .allocator = allocator,
            .runtime = runtime,
            .config = config,
            .input_channel = try channels.unbounded([]const u8, allocator),
            .output_channel = try channels.unbounded([]const u8, allocator),
            .running = std.atomic.Value(bool).init(false),
        };
    }

    pub fn deinit(self: *Self) void {
        self.input_channel.deinit();
        self.output_channel.deinit();
    }

    /// Start compression worker
    pub fn start(self: *Self) !void {
        self.running.store(true, .release);

        while (self.running.load(.acquire)) {
            // Receive chunk
            const chunk = self.input_channel.recv() catch break;

            // Compress chunk (TODO: integrate with zpack)
            const compressed = try self.compressChunk(chunk);

            // Send compressed chunk
            try self.output_channel.send(compressed);
        }
    }

    /// Stop compression worker
    pub fn stop(self: *Self) void {
        self.running.store(false, .release);
    }

    /// Send data to compress
    pub fn write(self: *Self, data: []const u8) !void {
        try self.input_channel.send(data);
    }

    /// Receive compressed data
    pub fn read(self: *Self) ![]const u8 {
        return try self.output_channel.recv();
    }

    /// Compress chunk (integrate with zpack)
    fn compressChunk(self: *Self, data: []const u8) ![]const u8 {
        // TODO: Call zpack compression
        // For now, just copy data
        const compressed = try self.allocator.dupe(u8, data);
        return compressed;
    }
};

/// Async Decompressor
pub const AsyncDecompressor = struct {
    allocator: std.mem.Allocator,
    runtime: *Runtime,
    config: CompressionConfig,
    input_channel: channels.UnboundedChannel([]const u8),
    output_channel: channels.UnboundedChannel([]const u8),
    running: std.atomic.Value(bool),

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        runtime: *Runtime,
        config: CompressionConfig,
    ) !Self {
        return Self{
            .allocator = allocator,
            .runtime = runtime,
            .config = config,
            .input_channel = try channels.unbounded([]const u8, allocator),
            .output_channel = try channels.unbounded([]const u8, allocator),
            .running = std.atomic.Value(bool).init(false),
        };
    }

    pub fn deinit(self: *Self) void {
        self.input_channel.deinit();
        self.output_channel.deinit();
    }

    /// Start decompression worker
    pub fn start(self: *Self) !void {
        self.running.store(true, .release);

        while (self.running.load(.acquire)) {
            // Receive compressed chunk
            const chunk = self.input_channel.recv() catch break;

            // Decompress chunk (TODO: integrate with zpack)
            const decompressed = try self.decompressChunk(chunk);

            // Send decompressed chunk
            try self.output_channel.send(decompressed);
        }
    }

    /// Stop decompression worker
    pub fn stop(self: *Self) void {
        self.running.store(false, .release);
    }

    /// Send compressed data to decompress
    pub fn write(self: *Self, data: []const u8) !void {
        try self.input_channel.send(data);
    }

    /// Receive decompressed data
    pub fn read(self: *Self) ![]const u8 {
        return try self.output_channel.recv();
    }

    /// Decompress chunk (integrate with zpack)
    fn decompressChunk(self: *Self, data: []const u8) ![]const u8 {
        // TODO: Call zpack decompression
        // For now, just copy data
        const decompressed = try self.allocator.dupe(u8, data);
        return decompressed;
    }
};

/// Compress file asynchronously
pub fn compressFileAsync(
    allocator: std.mem.Allocator,
    runtime: *Runtime,
    input_path: []const u8,
    output_path: []const u8,
    config: CompressionConfig,
) !void {
    var compressor = try AsyncCompressor.init(allocator, runtime, config);
    defer compressor.deinit();

    // Start compression worker
    _ = try runtime.spawn(struct {
        fn worker(comp: *AsyncCompressor) !void {
            try comp.start();
        }
    }.worker, .{&compressor});

    // Read input file in chunks
    const file = try std.fs.cwd().openFile(input_path, .{});
    defer file.close();

    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const n = try file.read(&buffer);
        if (n == 0) break;

        try compressor.write(buffer[0..n]);
    }

    compressor.stop();

    // Write compressed output
    const out_file = try std.fs.cwd().createFile(output_path, .{});
    defer out_file.close();

    while (true) {
        const compressed = compressor.read() catch break;
        defer allocator.free(compressed);

        try out_file.writeAll(compressed);
    }
}

/// Decompress file asynchronously
pub fn decompressFileAsync(
    allocator: std.mem.Allocator,
    runtime: *Runtime,
    input_path: []const u8,
    output_path: []const u8,
    config: CompressionConfig,
) !void {
    var decompressor = try AsyncDecompressor.init(allocator, runtime, config);
    defer decompressor.deinit();

    // Start decompression worker
    _ = try runtime.spawn(struct {
        fn worker(decomp: *AsyncDecompressor) !void {
            try decomp.start();
        }
    }.worker, .{&decompressor});

    // Read compressed input
    const file = try std.fs.cwd().openFile(input_path, .{});
    defer file.close();

    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const n = try file.read(&buffer);
        if (n == 0) break;

        try decompressor.write(buffer[0..n]);
    }

    decompressor.stop();

    // Write decompressed output
    const out_file = try std.fs.cwd().createFile(output_path, .{});
    defer out_file.close();

    while (true) {
        const decompressed = decompressor.read() catch break;
        defer allocator.free(decompressed);

        try out_file.writeAll(decompressed);
    }
}

// Tests
test "async compressor init" {
    const testing = std.testing;

    var config = @import("../runtime.zig").Config.optimal();
    var runtime = try @import("../runtime.zig").Runtime.init(testing.allocator, &config);
    defer runtime.deinit();

    var compressor = try AsyncCompressor.init(
        testing.allocator,
        runtime,
        CompressionConfig{},
    );
    defer compressor.deinit();

    try testing.expect(!compressor.running.load(.acquire));
}
