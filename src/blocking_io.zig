//! Zsync v0.1 - BlockingIo Implementation
//! Maps io.async() calls directly to blocking syscalls
//! Equivalent to C performance with zero overhead

const std = @import("std");
const io_interface = @import("io_v2.zig");
const Io = io_interface.Io;
const Future = io_interface.Future;
const File = io_interface.File;
const TcpStream = io_interface.TcpStream;
const TcpListener = io_interface.TcpListener;
const UdpSocket = io_interface.UdpSocket;

/// BlockingIo implementation - zero overhead blocking I/O
pub const BlockingIo = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    /// Get the Io interface for this implementation
    pub fn io(self: *Self) Io {
        return Io{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    // VTable implementation
    const vtable = Io.VTable{
        .async_fn = asyncFn,
        .async_concurrent_fn = asyncConcurrentFn,
        .createFile = createFile,
        .openFile = openFile,
        .tcpConnect = tcpConnect,
        .tcpListen = tcpListen,
        .udpBind = udpBind,
    };

    fn asyncFn(ptr: *anyopaque, call_info: io_interface.AsyncCallInfo) !Future {
        const self: *Self = @ptrCast(@alignCast(ptr));
        
        // In blocking mode, execute immediately and return completed future
        try call_info.exec_fn(call_info.call_ptr);
        
        // Clean up the call info since we're done with it
        call_info.deinit();
        
        // Create a completed future
        const future_impl = try self.allocator.create(CompletedFuture);
        future_impl.* = CompletedFuture{
            .allocator = self.allocator,
        };
        
        return Future{
            .ptr = future_impl,
            .vtable = &completed_future_vtable,
            .state = std.atomic.Value(Future.State).init(.completed),
            .wakers = std.ArrayList(Future.Waker).init(self.allocator),
        };
    }

    fn asyncConcurrentFn(ptr: *anyopaque, call_infos: []io_interface.AsyncCallInfo) !io_interface.ConcurrentFuture {
        const self: *Self = @ptrCast(@alignCast(ptr));
        
        // For blocking I/O, execute all operations sequentially (no true concurrency)
        for (call_infos) |call_info| {
            try call_info.exec_fn(call_info.call_ptr);
            call_info.deinit();
        }
        
        // Return an already completed concurrent future
        const concurrent_future = try self.allocator.create(CompletedConcurrentFuture);
        concurrent_future.* = CompletedConcurrentFuture{
            .allocator = self.allocator,
        };
        
        return io_interface.ConcurrentFuture{
            .ptr = concurrent_future,
            .vtable = &completed_concurrent_future_vtable,
        };
    }

    fn createFile(ptr: *anyopaque, path: []const u8, options: File.CreateOptions) !File {
        const self: *Self = @ptrCast(@alignCast(ptr));
        
        const file_impl = try self.allocator.create(BlockingFile);
        file_impl.* = BlockingFile{
            .file = try std.fs.cwd().createFile(path, .{
                .truncate = options.truncate,
                .exclusive = options.exclusive,
            }),
            .allocator = self.allocator,
        };

        return File{
            .ptr = file_impl,
            .vtable = &file_vtable,
        };
    }

    fn openFile(ptr: *anyopaque, path: []const u8, options: File.OpenOptions) !File {
        const self: *Self = @ptrCast(@alignCast(ptr));
        
        const file_impl = try self.allocator.create(BlockingFile);
        file_impl.* = BlockingFile{
            .file = try std.fs.cwd().openFile(path, .{ .mode = options.mode }),
            .allocator = self.allocator,
        };

        return File{
            .ptr = file_impl,
            .vtable = &file_vtable,
        };
    }

    fn tcpConnect(ptr: *anyopaque, address: std.net.Address) !TcpStream {
        const self: *Self = @ptrCast(@alignCast(ptr));
        
        const stream = try std.net.tcpConnectToAddress(address);
        const stream_impl = try self.allocator.create(BlockingTcpStream);
        stream_impl.* = BlockingTcpStream{
            .stream = stream,
            .allocator = self.allocator,
        };

        return TcpStream{
            .ptr = stream_impl,
            .vtable = &tcp_stream_vtable,
        };
    }

    fn tcpListen(ptr: *anyopaque, address: std.net.Address) !TcpListener {
        const self: *Self = @ptrCast(@alignCast(ptr));
        
        const listener = try address.listen(.{ .reuse_address = true });
        const listener_impl = try self.allocator.create(BlockingTcpListener);
        listener_impl.* = BlockingTcpListener{
            .listener = listener,
            .allocator = self.allocator,
        };

        return TcpListener{
            .ptr = listener_impl,
            .vtable = &tcp_listener_vtable,
        };
    }

    fn udpBind(ptr: *anyopaque, address: std.net.Address) !UdpSocket {
        const self: *Self = @ptrCast(@alignCast(ptr));
        
        // UDP socket creation placeholder
        _ = address;
        const socket_impl = try self.allocator.create(BlockingUdpSocket);
        socket_impl.* = BlockingUdpSocket{
            .allocator = self.allocator,
        };

        return UdpSocket{
            .ptr = socket_impl,
            .vtable = &udp_socket_vtable,
        };
    }
};

/// Completed future for blocking operations
const CompletedFuture = struct {
    allocator: std.mem.Allocator,
};

/// Completed concurrent future for blocking operations
const CompletedConcurrentFuture = struct {
    allocator: std.mem.Allocator,
};

const completed_future_vtable = Future.VTable{
    .await_fn = completedAwait,
    .cancel_fn = completedCancel,
    .deinit_fn = completedDeinit,
};

fn completedAwait(ptr: *anyopaque, io: Io, options: Future.AwaitOptions) !void {
    _ = ptr;
    _ = io;
    _ = options;
    // Already completed, nothing to await
}

fn completedCancel(ptr: *anyopaque, io: Io, options: Future.CancelOptions) !void {
    _ = ptr;
    _ = io;
    _ = options;
    // Already completed, nothing to cancel
}

fn completedDeinit(ptr: *anyopaque) void {
    const future: *CompletedFuture = @ptrCast(@alignCast(ptr));
    future.allocator.destroy(future);
}

const completed_concurrent_future_vtable = io_interface.ConcurrentFuture.VTable{
    .await_all_fn = completedConcurrentAwaitAll,
    .await_any_fn = completedConcurrentAwaitAny,
    .cancel_all_fn = completedConcurrentCancelAll,
    .deinit_fn = completedConcurrentDeinit,
};

fn completedConcurrentAwaitAll(ptr: *anyopaque, io: Io) !void {
    _ = ptr;
    _ = io;
    // Already completed, nothing to await
}

fn completedConcurrentAwaitAny(ptr: *anyopaque, io: Io) !usize {
    _ = ptr;
    _ = io;
    // Return 0 as "first" completed operation
    return 0;
}

fn completedConcurrentCancelAll(ptr: *anyopaque, io: Io) !void {
    _ = ptr;
    _ = io;
    // Already completed, nothing to cancel
}

fn completedConcurrentDeinit(ptr: *anyopaque) void {
    const future: *CompletedConcurrentFuture = @ptrCast(@alignCast(ptr));
    future.allocator.destroy(future);
}

/// Blocking file implementation
const BlockingFile = struct {
    file: std.fs.File,
    allocator: std.mem.Allocator,
};

const file_vtable = File.VTable{
    .writeAll = fileWriteAll,
    .readAll = fileReadAll,
    .close = fileClose,
};

fn fileWriteAll(ptr: *anyopaque, io: Io, data: []const u8) !void {
    _ = io;
    const file_impl: *BlockingFile = @ptrCast(@alignCast(ptr));
    try file_impl.file.writeAll(data);
}

fn fileReadAll(ptr: *anyopaque, io: Io, buffer: []u8) !usize {
    _ = io;
    const file_impl: *BlockingFile = @ptrCast(@alignCast(ptr));
    return try file_impl.file.readAll(buffer);
}

fn fileClose(ptr: *anyopaque, io: Io) !void {
    _ = io;
    const file_impl: *BlockingFile = @ptrCast(@alignCast(ptr));
    file_impl.file.close();
    file_impl.allocator.destroy(file_impl);
}

/// Blocking TCP stream implementation
const BlockingTcpStream = struct {
    stream: std.net.Stream,
    allocator: std.mem.Allocator,
};

const tcp_stream_vtable = TcpStream.VTable{
    .read = streamRead,
    .write = streamWrite,
    .close = streamClose,
};

fn streamRead(ptr: *anyopaque, io: Io, buffer: []u8) !usize {
    _ = io;
    const stream_impl: *BlockingTcpStream = @ptrCast(@alignCast(ptr));
    return try stream_impl.stream.readAll(buffer);
}

fn streamWrite(ptr: *anyopaque, io: Io, data: []const u8) !usize {
    _ = io;
    const stream_impl: *BlockingTcpStream = @ptrCast(@alignCast(ptr));
    try stream_impl.stream.writeAll(data);
    return data.len;
}

fn streamClose(ptr: *anyopaque, io: Io) !void {
    _ = io;
    const stream_impl: *BlockingTcpStream = @ptrCast(@alignCast(ptr));
    stream_impl.stream.close();
    stream_impl.allocator.destroy(stream_impl);
}

/// Blocking TCP listener implementation
const BlockingTcpListener = struct {
    listener: std.net.Server,
    allocator: std.mem.Allocator,
};

const tcp_listener_vtable = TcpListener.VTable{
    .accept = listenerAccept,
    .close = listenerClose,
};

fn listenerAccept(ptr: *anyopaque, io: Io) !TcpStream {
    _ = io;
    const listener_impl: *BlockingTcpListener = @ptrCast(@alignCast(ptr));
    
    const connection = try listener_impl.listener.accept();
    const stream_impl = try listener_impl.allocator.create(BlockingTcpStream);
    stream_impl.* = BlockingTcpStream{
        .stream = connection.stream,
        .allocator = listener_impl.allocator,
    };

    return TcpStream{
        .ptr = stream_impl,
        .vtable = &tcp_stream_vtable,
    };
}

fn listenerClose(ptr: *anyopaque, io: Io) !void {
    _ = io;
    const listener_impl: *BlockingTcpListener = @ptrCast(@alignCast(ptr));
    listener_impl.listener.deinit();
    listener_impl.allocator.destroy(listener_impl);
}

/// Blocking UDP socket implementation
const BlockingUdpSocket = struct {
    allocator: std.mem.Allocator,
};

const udp_socket_vtable = UdpSocket.VTable{
    .sendTo = udpSendTo,
    .recvFrom = udpRecvFrom,
    .close = udpClose,
};

fn udpSendTo(ptr: *anyopaque, io: Io, data: []const u8, address: std.net.Address) !usize {
    _ = io;
    const socket_impl: *BlockingUdpSocket = @ptrCast(@alignCast(ptr));
    // Placeholder UDP send
    _ = socket_impl;
    _ = address;
    return data.len;
}

fn udpRecvFrom(ptr: *anyopaque, io: Io, buffer: []u8) !io_interface.RecvFromResult {
    _ = io;
    const socket_impl: *BlockingUdpSocket = @ptrCast(@alignCast(ptr));
    // Placeholder UDP receive
    _ = socket_impl;
    _ = buffer;
    return .{ .bytes = 0, .address = std.net.Address.initIp4(.{0, 0, 0, 0}, 0) };
}

fn udpClose(ptr: *anyopaque, io: Io) !void {
    _ = io;
    const socket_impl: *BlockingUdpSocket = @ptrCast(@alignCast(ptr));
    // Placeholder UDP close
    socket_impl.allocator.destroy(socket_impl);
}

test "blocking io basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var blocking_io = BlockingIo.init(allocator);
    defer blocking_io.deinit();
    
    const io = blocking_io.io();
    
    // Test file creation
    const file = try io.vtable.createFile(io.ptr, "test_blocking.txt", .{});
    try file.writeAll(io, "Hello, BlockingIo!");
    try file.close(io);
    
    // Clean up
    std.fs.cwd().deleteFile("test_blocking.txt") catch {};
}

test "blocking io colorblind async" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var blocking_io = BlockingIo.init(allocator);
    defer blocking_io.deinit();
    
    const io = blocking_io.io();
    
    // Test the colorblind saveData function
    try io_interface.saveData(allocator, io, "Test data from blocking IO");
    
    // Clean up
    std.fs.cwd().deleteFile("saveA.txt") catch {};
    std.fs.cwd().deleteFile("saveB.txt") catch {};
}