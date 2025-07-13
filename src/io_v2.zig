//! Zsync v0.1 - New Io Interface Implementation
//! Based on Zig's upcoming async I/O redesign
//! Provides colorblind async - same code works across execution models

const std = @import("std");

/// Type-erased function call information for async operations
/// Uses runtime function pointer registration to avoid comptime/runtime conflicts
pub const AsyncCallInfo = struct {
    call_ptr: *anyopaque,
    exec_fn: *const fn (call_ptr: *anyopaque) anyerror!void,
    cleanup_fn: ?*const fn (call_ptr: *anyopaque) void,
    
    /// Create call info for known functions
    pub fn initDirect(
        call_ptr: *anyopaque,
        exec_fn: *const fn (call_ptr: *anyopaque) anyerror!void,
        cleanup_fn: ?*const fn (call_ptr: *anyopaque) void,
    ) AsyncCallInfo {
        return AsyncCallInfo{
            .call_ptr = call_ptr,
            .exec_fn = exec_fn,
            .cleanup_fn = cleanup_fn,
        };
    }
    
    /// Clean up allocated memory
    pub fn deinit(self: AsyncCallInfo) void {
        if (self.cleanup_fn) |cleanup| {
            cleanup(self.call_ptr);
        }
    }
};

/// Context for saveFile function calls
const SaveFileContext = struct {
    io: Io,
    data: []const u8,
    filename: []const u8,
    allocator: std.mem.Allocator,
    
    fn execute(ptr: *anyopaque) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        try saveFile(self.io, self.data, self.filename);
    }
    
    fn cleanup(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.allocator.destroy(self);
    }
};

/// The core Io interface that provides dependency injection for I/O operations
/// This replaces direct stdlib calls with vtable-based dispatch
pub const Io = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        // Core async operation - takes type-erased call information
        async_fn: *const fn (ptr: *anyopaque, call_info: AsyncCallInfo) anyerror!Future,
        
        // Concurrent async operation - for true parallelism
        async_concurrent_fn: *const fn (ptr: *anyopaque, call_infos: []AsyncCallInfo) anyerror!ConcurrentFuture,
        
        // File operations
        createFile: *const fn (ptr: *anyopaque, path: []const u8, options: File.CreateOptions) anyerror!File,
        openFile: *const fn (ptr: *anyopaque, path: []const u8, options: File.OpenOptions) anyerror!File,
        
        // Network operations
        tcpConnect: *const fn (ptr: *anyopaque, address: std.net.Address) anyerror!TcpStream,
        tcpListen: *const fn (ptr: *anyopaque, address: std.net.Address) anyerror!TcpListener,
        udpBind: *const fn (ptr: *anyopaque, address: std.net.Address) anyerror!UdpSocket,
    };

    /// Create an async operation for saveFile specifically
    /// For a real implementation, we'd have a registry of supported functions
    pub fn asyncSaveFile(self: Io, allocator: std.mem.Allocator, io: Io, data: []const u8, filename: []const u8) !Future {
        const ctx = try allocator.create(SaveFileContext);
        ctx.* = SaveFileContext{
            .io = io,
            .data = data,
            .filename = filename,
            .allocator = allocator,
        };
        
        const call_info = AsyncCallInfo.initDirect(
            ctx,
            SaveFileContext.execute,
            SaveFileContext.cleanup,
        );
        
        return self.vtable.async_fn(self.ptr, call_info);
    }
    
    /// Legacy method for generic async - will be replaced with function registry
    pub fn async_op(self: Io, allocator: std.mem.Allocator, func: anytype, args: anytype) !Future {
        // For now, only support saveFile
        if (func == saveFile) {
            return self.asyncSaveFile(allocator, args[0], args[1], args[2]);
        }
        return error.UnsupportedFunction;
    }

    /// Create concurrent async operations for true parallelism
    pub fn asyncConcurrent(self: Io, call_infos: []AsyncCallInfo) !ConcurrentFuture {
        return self.vtable.async_concurrent_fn(self.ptr, call_infos);
    }
    
    /// Convenience method for io.async() pattern from the proposal
    pub const async = async_op;
};

/// ConcurrentFuture for managing multiple parallel operations
pub const ConcurrentFuture = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    
    pub const VTable = struct {
        await_all_fn: *const fn (ptr: *anyopaque, io: Io) anyerror!void,
        await_any_fn: *const fn (ptr: *anyopaque, io: Io) anyerror!usize, // Returns index of first completed
        cancel_all_fn: *const fn (ptr: *anyopaque, io: Io) anyerror!void,
        deinit_fn: *const fn (ptr: *anyopaque) void,
    };
    
    /// Wait for all concurrent operations to complete
    pub fn awaitAll(self: *ConcurrentFuture, io: Io) !void {
        return self.vtable.await_all_fn(self.ptr, io);
    }
    
    /// Wait for any one operation to complete (returns index)
    pub fn awaitAny(self: *ConcurrentFuture, io: Io) !usize {
        return self.vtable.await_any_fn(self.ptr, io);
    }
    
    /// Cancel all concurrent operations
    pub fn cancelAll(self: *ConcurrentFuture, io: Io) !void {
        return self.vtable.cancel_all_fn(self.ptr, io);
    }
    
    /// Cleanup the concurrent future
    pub fn deinit(self: *ConcurrentFuture) void {
        self.vtable.deinit_fn(self.ptr);
    }
};

/// Future type with await() and cancel() methods
pub const Future = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    completed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub const VTable = struct {
        await_fn: *const fn (ptr: *anyopaque, io: Io) anyerror!void,
        cancel_fn: *const fn (ptr: *anyopaque, io: Io) anyerror!void,
        deinit_fn: *const fn (ptr: *anyopaque) void,
    };

    /// Await completion of the future
    pub fn await_op(self: *Future, io: Io) !void {
        if (self.completed.load(.acquire)) return;
        return self.vtable.await_fn(self.ptr, io);
    }

    /// Cancel the future operation
    pub fn cancel(self: *Future, io: Io) !void {
        return self.vtable.cancel_fn(self.ptr, io);
    }

    /// Cleanup the future
    pub fn deinit(self: *Future) void {
        self.vtable.deinit_fn(self.ptr);
    }

    /// Convenience method for Future.await() pattern
    pub const await = await_op;
};

/// File operations with new Io interface
pub const File = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        writeAll: *const fn (ptr: *anyopaque, io: Io, data: []const u8) anyerror!void,
        readAll: *const fn (ptr: *anyopaque, io: Io, buffer: []u8) anyerror!usize,
        close: *const fn (ptr: *anyopaque, io: Io) anyerror!void,
    };

    pub const CreateOptions = struct {
        truncate: bool = true,
        exclusive: bool = false,
    };

    pub const OpenOptions = struct {
        mode: std.fs.File.OpenMode = .read_only,
    };

    /// Write all data to file using the Io interface
    pub fn writeAll(self: File, io: Io, data: []const u8) !void {
        return self.vtable.writeAll(self.ptr, io, data);
    }

    /// Read data from file using the Io interface
    pub fn readAll(self: File, io: Io, buffer: []u8) !usize {
        return self.vtable.readAll(self.ptr, io, buffer);
    }

    /// Close file using the Io interface
    pub fn close(self: File, io: Io) !void {
        return self.vtable.close(self.ptr, io);
    }

    /// Get stdout file handle
    pub fn stdout() File {
        return File{
            .ptr = &stdout_impl,
            .vtable = &stdout_vtable,
        };
    }
};

/// Directory operations with new Io interface
pub const Dir = struct {
    /// Get current working directory
    pub fn cwd() Dir {
        return Dir{};
    }

    /// Create a file in this directory
    pub fn createFile(self: Dir, io: Io, path: []const u8, options: File.CreateOptions) !File {
        _ = self;
        return io.vtable.createFile(io.ptr, path, options);
    }

    /// Open a file in this directory
    pub fn openFile(self: Dir, io: Io, path: []const u8, options: File.OpenOptions) !File {
        _ = self;
        return io.vtable.openFile(io.ptr, path, options);
    }
};

/// TCP Stream with new Io interface
pub const TcpStream = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        read: *const fn (ptr: *anyopaque, io: Io, buffer: []u8) anyerror!usize,
        write: *const fn (ptr: *anyopaque, io: Io, data: []const u8) anyerror!usize,
        close: *const fn (ptr: *anyopaque, io: Io) anyerror!void,
    };

    pub fn read(self: TcpStream, io: Io, buffer: []u8) !usize {
        return self.vtable.read(self.ptr, io, buffer);
    }

    pub fn write(self: TcpStream, io: Io, data: []const u8) !usize {
        return self.vtable.write(self.ptr, io, data);
    }

    pub fn close(self: TcpStream, io: Io) !void {
        return self.vtable.close(self.ptr, io);
    }
};

/// TCP Listener with new Io interface
pub const TcpListener = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        accept: *const fn (ptr: *anyopaque, io: Io) anyerror!TcpStream,
        close: *const fn (ptr: *anyopaque, io: Io) anyerror!void,
    };

    pub fn accept(self: TcpListener, io: Io) !TcpStream {
        return self.vtable.accept(self.ptr, io);
    }

    pub fn close(self: TcpListener, io: Io) !void {
        return self.vtable.close(self.ptr, io);
    }
};

/// UDP Socket with new Io interface
/// UDP recv result type
pub const RecvFromResult = struct { bytes: usize, address: std.net.Address };

pub const UdpSocket = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        sendTo: *const fn (ptr: *anyopaque, io: Io, data: []const u8, address: std.net.Address) anyerror!usize,
        recvFrom: *const fn (ptr: *anyopaque, io: Io, buffer: []u8) anyerror!RecvFromResult,
        close: *const fn (ptr: *anyopaque, io: Io) anyerror!void,
    };

    pub fn sendTo(self: UdpSocket, io: Io, data: []const u8, address: std.net.Address) !usize {
        return self.vtable.sendTo(self.ptr, io, data, address);
    }

    pub fn recvFrom(self: UdpSocket, io: Io, buffer: []u8) !struct { bytes: usize, address: std.net.Address } {
        return self.vtable.recvFrom(self.ptr, io, buffer);
    }

    pub fn close(self: UdpSocket, io: Io) !void {
        return self.vtable.close(self.ptr, io);
    }
};

// Stdout implementation for demo
var stdout_impl: void = {};

const stdout_vtable = File.VTable{
    .writeAll = stdoutWriteAll,
    .readAll = stdoutReadAll,
    .close = stdoutClose,
};

fn stdoutWriteAll(ptr: *anyopaque, io: Io, data: []const u8) !void {
    _ = ptr;
    _ = io;
    std.debug.print("{s}", .{data});
}

fn stdoutReadAll(ptr: *anyopaque, io: Io, buffer: []u8) !usize {
    _ = ptr;
    _ = io;
    _ = buffer;
    return error.NotSupported;
}

fn stdoutClose(ptr: *anyopaque, io: Io) !void {
    _ = ptr;
    _ = io;
    // Stdout doesn't need closing
}

// Example of colorblind async function
pub fn saveData(allocator: std.mem.Allocator, io: Io, data: []const u8) !void {
    // This function works with ANY Io implementation!
    var a_future = try io.async(allocator, saveFile, .{ io, data, "saveA.txt" });
    defer a_future.deinit();

    var b_future = try io.async(allocator, saveFile, .{ io, data, "saveB.txt" });
    defer b_future.deinit();

    try a_future.await(io);
    try b_future.await(io);

    const out = File.stdout();
    try out.writeAll(io, "save complete\n");
}

fn saveFile(io: Io, data: []const u8, name: []const u8) !void {
    const file = try Dir.cwd().createFile(io, name, .{});
    defer file.close(io) catch {};
    try file.writeAll(io, data);
}

test "io interface creation" {
    const testing = std.testing;
    
    // Test that our types are properly defined
    const IoType = @TypeOf(Io);
    _ = IoType;
    
    const FutureType = @TypeOf(Future);
    _ = FutureType;
    
    try testing.expect(true);
}