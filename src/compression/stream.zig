//! zsync Async Compression Streaming
//! Async wrappers around the standard library DEFLATE codec.

const std = @import("std");
const Runtime = @import("../std_runtime.zig").Runtime;
const channels = @import("../channels.zig");

const flate = std.compress.flate;

/// Container format for the backing DEFLATE codec.
pub const Algorithm = enum {
    /// Raw DEFLATE stream (RFC 1951), no header or checksum.
    deflate,
    /// gzip container (RFC 1952) with CRC-32 footer.
    gzip,
    /// zlib container (RFC 1950) with Adler-32 footer.
    zlib,

    fn container(self: Algorithm) flate.Container {
        return switch (self) {
            .deflate => .raw,
            .gzip => .gzip,
            .zlib => .zlib,
        };
    }
};

/// Compression effort, mapped to DEFLATE match-search aggressiveness.
pub const Level = enum(u8) {
    fastest = 1,
    default_ = 6,
    best = 9,

    fn options(self: Level) flate.Compress.Options {
        return switch (self) {
            .fastest => flate.Compress.Options.fastest,
            .default_ => flate.Compress.Options.default,
            .best => flate.Compress.Options.best,
        };
    }
};

/// Compression Config
pub const CompressionConfig = struct {
    algorithm: Algorithm = .gzip,
    level: Level = .default_,
    buffer_size: usize = 64 * 1024, // 64 KB chunks
};

/// Compress `data` into a single, self-contained DEFLATE stream.
/// Caller owns the returned buffer.
pub fn compressBuffer(
    allocator: std.mem.Allocator,
    data: []const u8,
    config: CompressionConfig,
) ![]u8 {
    var window: [flate.max_window_len]u8 = undefined;

    // `Compress.init` asserts the output writer has at least 8 bytes of buffer;
    // size the initial allocation generously to limit reallocations.
    var out: std.Io.Writer.Allocating = try .initCapacity(allocator, @max(64, data.len / 2));
    errdefer out.deinit();

    var comp = try flate.Compress.init(
        &out.writer,
        &window,
        config.algorithm.container(),
        config.level.options(),
    );
    try comp.writer.writeAll(data);
    try comp.finish();

    return out.toOwnedSlice();
}

/// Decompress a complete DEFLATE stream produced with the same container.
/// Caller owns the returned buffer.
pub fn decompressBuffer(
    allocator: std.mem.Allocator,
    data: []const u8,
    config: CompressionConfig,
) ![]u8 {
    var in: std.Io.Reader = .fixed(data);
    var window: [flate.max_window_len]u8 = undefined;

    var decomp: flate.Decompress = .init(&in, config.algorithm.container(), &window);

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    _ = try decomp.reader.streamRemaining(&out.writer);
    return out.toOwnedSlice();
}

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

            // Each message is compressed into an independent DEFLATE stream.
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

    /// Compress a single message into a complete DEFLATE stream.
    fn compressChunk(self: *Self, data: []const u8) ![]const u8 {
        return compressBuffer(self.allocator, data, self.config);
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

            // Each message is an independent DEFLATE stream.
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

    /// Decompress a single complete DEFLATE stream message.
    fn decompressChunk(self: *Self, data: []const u8) ![]const u8 {
        return decompressBuffer(self.allocator, data, self.config);
    }
};

/// Compress a file into a single DEFLATE stream.
pub fn compressFileAsync(
    allocator: std.mem.Allocator,
    runtime: *Runtime,
    input_path: []const u8,
    output_path: []const u8,
    config: CompressionConfig,
) !void {
    const io = runtime.io();

    const input = try std.Io.Dir.cwd().readFileAlloc(io, input_path, allocator, .unlimited);
    defer allocator.free(input);

    const compressed = try compressBuffer(allocator, input, config);
    defer allocator.free(compressed);

    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = output_path,
        .data = compressed,
    });
}

/// Decompress a DEFLATE-compressed file.
pub fn decompressFileAsync(
    allocator: std.mem.Allocator,
    runtime: *Runtime,
    input_path: []const u8,
    output_path: []const u8,
    config: CompressionConfig,
) !void {
    const io = runtime.io();

    const input = try std.Io.Dir.cwd().readFileAlloc(io, input_path, allocator, .unlimited);
    defer allocator.free(input);

    const decompressed = try decompressBuffer(allocator, input, config);
    defer allocator.free(decompressed);

    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = output_path,
        .data = decompressed,
    });
}

// Tests
test "async compressor init" {
    const testing = std.testing;

    var runtime = Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var compressor = try AsyncCompressor.init(
        testing.allocator,
        &runtime,
        CompressionConfig{},
    );
    defer compressor.deinit();

    try testing.expect(!compressor.running.load(.acquire));
}

test "compress/decompress round-trip across containers" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const unit = "The quick brown fox jumps over the lazy dog. ";
    var original_buf: [unit.len * 32]u8 = undefined;
    for (0..32) |i| @memcpy(original_buf[i * unit.len ..][0..unit.len], unit);
    const original: []const u8 = &original_buf;

    for ([_]Algorithm{ .deflate, .gzip, .zlib }) |algorithm| {
        const config = CompressionConfig{ .algorithm = algorithm, .level = .best };

        const compressed = try compressBuffer(allocator, original, config);
        defer allocator.free(compressed);

        // Highly repetitive input must actually shrink.
        try testing.expect(compressed.len < original.len);

        const restored = try decompressBuffer(allocator, compressed, config);
        defer allocator.free(restored);

        try testing.expectEqualSlices(u8, original, restored);
    }
}

test "compress file round-trip" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var runtime = Runtime.init(allocator, .{});
    defer runtime.deinit();
    const io = runtime.io();

    const dir_name = "zsync_compress_test_dir";
    try std.Io.Dir.cwd().createDir(io, dir_name, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    const src = dir_name ++ "/source.txt";
    const packed_path = dir_name ++ "/source.gz";
    const restored = dir_name ++ "/restored.txt";

    const unit = "zsync streaming compression payload\n";
    var payload_buf: [unit.len * 64]u8 = undefined;
    for (0..64) |i| @memcpy(payload_buf[i * unit.len ..][0..unit.len], unit);
    const payload: []const u8 = &payload_buf;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = src, .data = payload });

    const config = CompressionConfig{ .algorithm = .gzip };
    try compressFileAsync(allocator, &runtime, src, packed_path, config);
    try decompressFileAsync(allocator, &runtime, packed_path, restored, config);

    const result = try std.Io.Dir.cwd().readFileAlloc(io, restored, allocator, .unlimited);
    defer allocator.free(result);

    try testing.expectEqualSlices(u8, payload, result);
}
