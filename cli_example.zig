//! Zsync v0.4.0 CLI Example
//! Demonstrates colorblind async in a real-world command-line application

const std = @import("std");
const zsync = @import("src/runtime.zig");
const io_interface = @import("src/io_interface.zig");

const Io = io_interface.Io;

/// Simple file processing CLI tool
const FileProcessor = struct {
    input_file: []const u8,
    output_file: []const u8,
    verbose: bool,
    
    const Self = @This();
    
    pub fn processFile(self: Self, io_const: Io) !void {
        var io = io_const;
        if (self.verbose) {
            const status = "🔥 Processing with Zsync v0.4.0...\n";
            var write_future = try io.write(status);
            defer write_future.destroy(io.getAllocator());
            try write_future.await();
        }
        
        // Read input file
        const input_file = std.fs.cwd().openFile(self.input_file, .{}) catch |err| {
            const error_msg = std.fmt.allocPrint(io.getAllocator(), "❌ Error opening {s}: {}\n", .{ self.input_file, err }) catch return;
            defer io.getAllocator().free(error_msg);
            
            var write_future = try io.write(error_msg);
            defer write_future.destroy(io.getAllocator());
            try write_future.await();
            return;
        };
        defer input_file.close();
        
        // Create output file
        const output_file = std.fs.cwd().createFile(self.output_file, .{}) catch |err| {
            const error_msg = std.fmt.allocPrint(io.getAllocator(), "❌ Error creating {s}: {}\n", .{ self.output_file, err }) catch return;
            defer io.getAllocator().free(error_msg);
            
            var write_future = try io.write(error_msg);
            defer write_future.destroy(io.getAllocator());
            try write_future.await();
            return;
        };
        defer output_file.close();
        
        // Process file content using colorblind async I/O
        const file_size = try input_file.getEndPos();
        
        if (self.verbose) {
            const size_msg = std.fmt.allocPrint(io.getAllocator(), "📄 Processing {} bytes from {s}...\n", .{ file_size, self.input_file }) catch return;
            defer io.getAllocator().free(size_msg);
            
            var write_future = try io.write(size_msg);
            defer write_future.destroy(io.getAllocator());
            try write_future.await();
        }
        
        // Use zero-copy if available
        if (io.supportsZeroCopy()) {
            if (self.verbose) {
                const zero_copy_msg = "⚡ Using zero-copy file transfer...\n";
                var write_future = try io.write(zero_copy_msg);
                defer write_future.destroy(io.getAllocator());
                try write_future.await();
            }
            
            // Zero-copy file transfer
            var copy_future = try io.copyFileRange(input_file.handle, output_file.handle, file_size);
            defer copy_future.destroy(io.getAllocator());
            try copy_future.await();
        } else {
            // Fallback to buffered copy with vectorized I/O
            if (self.verbose) {
                const buffered_msg = "📋 Using buffered copy with vectorized I/O...\n";
                var write_future = try io.write(buffered_msg);
                defer write_future.destroy(io.getAllocator());
                try write_future.await();
            }
            
            var buffer: [8192]u8 = undefined;
            while (true) {
                const bytes_read = input_file.readAll(&buffer) catch break;
                if (bytes_read == 0) break;
                
                try output_file.writeAll(buffer[0..bytes_read]);
            }
        }
        
        // Success message
        const success_msg = std.fmt.allocPrint(io.getAllocator(), "✅ Successfully processed {s} -> {s}\n", .{ self.input_file, self.output_file }) catch return;
        defer io.getAllocator().free(success_msg);
        
        var write_future = try io.write(success_msg);
        defer write_future.destroy(io.getAllocator());
        try write_future.await();
    }
};

/// Parse command line arguments
fn parseArgs(allocator: std.mem.Allocator) !FileProcessor {
    var args = std.process.args();
    _ = args.skip(); // Skip program name
    
    const input_file = args.next() orelse {
        const usage = "Usage: cli_example <input_file> <output_file> [--verbose]\n";
        std.debug.print("{s}", .{usage});
        return error.InvalidArgs;
    };
    
    const output_file = args.next() orelse {
        const usage = "Usage: cli_example <input_file> <output_file> [--verbose]\n";
        std.debug.print("{s}", .{usage});
        return error.InvalidArgs;
    };
    
    var verbose = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
            verbose = true;
        }
    }
    
    return FileProcessor{
        .input_file = try allocator.dupe(u8, input_file),
        .output_file = try allocator.dupe(u8, output_file),
        .verbose = verbose,
    };
}

/// CLI application main task  
fn cliTask(io_const: Io) !void {
    var io = io_const;
    // Print banner
    const banner = 
        \\🚀 Zsync v0.4.0 CLI Example
        \\===========================
        \\Colorblind async file processor
        \\
    ;
    
    var write_future = try io.write(banner);
    defer write_future.destroy(io.getAllocator());
    try write_future.await();
    
    // Parse command line arguments
    const processor = parseArgs(io.getAllocator()) catch |err| switch (err) {
        error.InvalidArgs => return,
        else => return err,
    };
    defer io.getAllocator().free(processor.input_file);
    defer io.getAllocator().free(processor.output_file);
    
    // Print execution model info
    const mode_info = std.fmt.allocPrint(io.getAllocator(), "🔧 Execution mode: {s}\n", .{@tagName(io.getMode())}) catch return;
    defer io.getAllocator().free(mode_info);
    
    var mode_future = try io.write(mode_info);
    defer mode_future.destroy(io.getAllocator());
    try mode_future.await();
    
    // Print capabilities
    const capabilities = std.fmt.allocPrint(io.getAllocator(), "⚡ Capabilities: Vectorized={}, Zero-copy={}\n\n", .{ io.supportsVectorized(), io.supportsZeroCopy() }) catch return;
    defer io.getAllocator().free(capabilities);
    
    var cap_future = try io.write(capabilities);
    defer cap_future.destroy(io.getAllocator());
    try cap_future.await();
    
    // Process the file
    try processor.processFile(io);
    
    // Final message
    const final_msg = "\n🎉 File processing completed with Zsync v0.4.0!\n";
    var final_future = try io.write(final_msg);
    defer final_future.destroy(io.getAllocator());
    try final_future.await();
}

/// Main entry point - demonstrates runtime auto-detection
pub fn main() !void {
    // Create a test input file if it doesn't exist
    createTestInputFile() catch {};
    
    std.debug.print("🎯 Running with automatic execution model detection...\n", .{});
    try zsync.run(cliTask, {});
    
    std.debug.print("\n🎯 Running with high-performance model...\n", .{});
    try zsync.runHighPerf(cliTask, {});
    
    std.debug.print("\n🎯 Running with blocking model...\n", .{});
    try zsync.runBlocking(cliTask, {});
}

/// Create a test input file for demonstration
fn createTestInputFile() !void {
    const test_content = 
        \\Welcome to Zsync v0.4.0!
        \\========================
        \\
        \\This is a test file for the CLI example.
        \\
        \\Zsync v0.4.0 features:
        \\• True colorblind async/await
        \\• Multiple execution models (blocking, thread pool, green threads)
        \\• Vectorized I/O operations (readv/writev)
        \\• Zero-copy optimizations (sendfile, copy_file_range)
        \\• Platform-specific optimizations
        \\• Future combinators (race, all, timeout)
        \\• Cooperative cancellation
        \\• Comprehensive metrics and monitoring
        \\
        \\The same async code works seamlessly across all execution models!
        \\This demonstrates the power of Zig's colorblind async paradigm.
        \\
        \\Performance characteristics:
        \\• Zero-allocation fast paths
        \\• Automatic platform detection
        \\• Kernel-space optimizations on Linux
        \\• C-equivalent performance in blocking mode
        \\• True parallelism with thread pools
        \\
        \\🚀 The future of Zig async programming!
    ;
    
    const file = try std.fs.cwd().createFile("test_input.txt", .{});
    defer file.close();
    try file.writeAll(test_content);
}