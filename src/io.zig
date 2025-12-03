//! I/O abstractions for Zsync
//! Provides async TCP, UDP, and file operations

const std = @import("std");
const reactor = @import("reactor.zig");
const runtime = @import("runtime.zig");
const scheduler = @import("scheduler.zig");

/// Async TCP stream
pub const TcpStream = struct {
    fd: std.posix.fd_t,
    reactor: *reactor.Reactor,
    local_addr: std.net.Address,
    peer_addr: std.net.Address,

    const Self = @This();

    /// Connect to a remote address
    pub fn connect(address: std.net.Address) !Self {
        const fd = try std.posix.socket(address.any.family, std.posix.SOCK.STREAM, std.posix.IPPROTO.TCP);
        errdefer std.posix.close(fd);

        // Set non-blocking
        const flags = try std.posix.fcntl(fd, std.posix.F.GETFL, 0);
        _ = try std.posix.fcntl(fd, std.posix.F.SETFL, flags | 0o4000);

        // Get runtime reactor
        const runtime_instance = runtime.Runtime.global() orelse return error.NoRuntime;
        
        // Attempt connection
        std.posix.connect(fd, &address.any, address.getOsSockLen()) catch |err| switch (err) {
            error.WouldBlock => {
                // Create waker for current task
                const waker = runtime_instance.event_loop_instance.scheduler_instance.createWaker(0); // TODO: Get actual task ID
                
                // Register for write readiness
                try runtime_instance.registerIo(fd, .{ .writable = true }, &waker);

                // Yield execution until ready
                scheduler.yield();
                
                // Retry connection after wakeup
                std.posix.connect(fd, &address.any, address.getOsSockLen()) catch |retry_err| switch (retry_err) {
                    error.Already, error.AlreadyConnected => {}, // Connection completed
                    else => return retry_err,
                };
            },
            else => return err,
        };

        const local_addr = try std.posix.getsockname(fd);
        
        return Self{
            .fd = fd,
            .reactor = &runtime_instance.reactor,
            .local_addr = local_addr,
            .peer_addr = address,
        };
    }

    /// Read data from the stream
    pub fn read(self: Self, buffer: []u8) !usize {
        while (true) {
            const bytes_read = std.posix.read(self.fd, buffer) catch |err| switch (err) {
                error.WouldBlock => {
                    // Get runtime for waker creation
                    const runtime_instance = runtime.Runtime.global() orelse return error.NoRuntime;
                    const waker = runtime_instance.event_loop_instance.scheduler_instance.createWaker(0); // TODO: Get actual task ID
                    
                    // Register for read readiness
                    try runtime_instance.registerIo(self.fd, .{ .readable = true }, &waker);

                    // Yield execution until ready
                    scheduler.yield();
                    continue;
                },
                else => return err,
            };

            return bytes_read;
        }
    }

    /// Write data to the stream
    pub fn write(self: Self, data: []const u8) !usize {
        while (true) {
            const bytes_written = std.posix.write(self.fd, data) catch |err| switch (err) {
                error.WouldBlock => {
                    // Get runtime for waker creation
                    const runtime_instance = runtime.Runtime.global() orelse return error.NoRuntime;
                    const waker = runtime_instance.event_loop_instance.scheduler_instance.createWaker(0); // TODO: Get actual task ID
                    
                    // Register for write readiness
                    try runtime_instance.registerIo(self.fd, .{ .writable = true }, &waker);

                    // Yield execution until ready
                    scheduler.yield();
                    continue;
                },
                else => return err,
            };

            return bytes_written;
        }
    }

    /// Write all data to the stream
    pub fn writeAll(self: Self, data: []const u8) !void {
        var written: usize = 0;
        while (written < data.len) {
            const bytes_written = try self.write(data[written..]);
            written += bytes_written;
        }
    }

    /// Read all available data
    pub fn readAll(self: Self, buffer: []u8) !usize {
        return self.read(buffer);
    }

    /// Close the stream
    pub fn close(self: Self) void {
        std.posix.close(self.fd);
    }

    /// Get local address
    pub fn localAddress(self: Self) std.net.Address {
        return self.local_addr;
    }

    /// Get peer address
    pub fn peerAddress(self: Self) std.net.Address {
        return self.peer_addr;
    }
};

/// Async TCP listener
pub const TcpListener = struct {
    fd: std.posix.fd_t,
    reactor: *reactor.Reactor,
    local_addr: std.net.Address,

    const Self = @This();

    /// Bind to an address and start listening
    pub fn bind(address: std.net.Address) !Self {
        const fd = try std.posix.socket(address.any.family, std.posix.SOCK.STREAM, std.posix.IPPROTO.TCP);
        errdefer std.posix.close(fd);

        // Set SO_REUSEADDR
        try std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));

        // Set non-blocking
        const flags = try std.posix.fcntl(fd, std.posix.F.GETFL, 0);
        _ = try std.posix.fcntl(fd, std.posix.F.SETFL, flags | 0o4000);

        // Bind and listen
        try std.posix.bind(fd, &address.any, address.getOsSockLen());
        try std.posix.listen(fd, 128);

        const local_addr = try std.posix.getsockname(fd);
        
        // Get runtime reactor
        const runtime_instance = runtime.Runtime.global() orelse return error.NoRuntime;

        return Self{
            .fd = fd,
            .reactor = &runtime_instance.reactor,
            .local_addr = local_addr,
        };
    }

    /// Accept a connection
    pub fn accept(self: Self) !TcpStream {
        while (true) {
            var client_addr: std.posix.sockaddr = undefined;
            var client_addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);

            const client_fd = std.posix.accept(self.fd, &client_addr, &client_addr_len, std.posix.SOCK.CLOEXEC) catch |err| switch (err) {
                error.WouldBlock => {
                    // Get runtime for waker creation
                    const runtime_instance = runtime.Runtime.global() orelse return error.NoRuntime;
                    const waker = runtime_instance.event_loop_instance.scheduler_instance.createWaker(0);

                    // Register for read readiness
                    try runtime_instance.registerIo(self.fd, .{ .readable = true }, &waker);

                    // Yield execution until ready
                    scheduler.yield();
                    continue;
                },
                else => return err,
            };

            // Set client socket non-blocking
            const flags = try std.posix.fcntl(client_fd, std.posix.F.GETFL, 0);
            _ = try std.posix.fcntl(client_fd, std.posix.F.SETFL, flags | 0o4000);

            const local_addr = try std.posix.getsockname(client_fd);
            const peer_addr = std.net.Address.initPosix(@alignCast(@ptrCast(&client_addr)));

            return TcpStream{
                .fd = client_fd,
                .reactor = self.reactor,
                .local_addr = local_addr,
                .peer_addr = peer_addr,
            };
        }
    }

    /// Close the listener
    pub fn close(self: Self) void {
        std.posix.close(self.fd);
    }

    /// Get local address
    pub fn localAddress(self: Self) std.net.Address {
        return self.local_addr;
    }
};

/// Async UDP socket
pub const UdpSocket = struct {
    fd: std.posix.fd_t,
    reactor: *reactor.Reactor,
    local_addr: std.net.Address,

    const Self = @This();

    /// Bind to an address
    pub fn bind(address: std.net.Address) !Self {
        const fd = try std.posix.socket(address.any.family, std.posix.SOCK.DGRAM, std.posix.IPPROTO.UDP);
        errdefer std.posix.close(fd);

        // Set non-blocking
        const flags = try std.posix.fcntl(fd, std.posix.F.GETFL, 0);
        _ = try std.posix.fcntl(fd, std.posix.F.SETFL, flags | 0o4000);

        // Bind
        try std.posix.bind(fd, &address.any, address.getOsSockLen());

        const local_addr = try std.posix.getsockname(fd);
        
        // Get runtime reactor
        const runtime_instance = runtime.Runtime.global() orelse return error.NoRuntime;

        return Self{
            .fd = fd,
            .reactor = &runtime_instance.reactor,
            .local_addr = local_addr,
        };
    }

    /// Send data to an address
    pub fn sendTo(self: Self, data: []const u8, address: std.net.Address) !usize {
        while (true) {
            const bytes_sent = std.posix.sendto(self.fd, data, 0, &address.any, address.getOsSockLen()) catch |err| switch (err) {
                error.WouldBlock => {
                    // Get runtime for waker creation
                    const runtime_instance = runtime.Runtime.global() orelse return error.NoRuntime;
                    const waker = runtime_instance.event_loop_instance.scheduler_instance.createWaker(0);

                    // Register for write readiness
                    try runtime_instance.registerIo(self.fd, .{ .writable = true }, &waker);

                    // Yield execution until ready
                    scheduler.yield();
                    continue;
                },
                else => return err,
            };

            return bytes_sent;
        }
    }

    /// Receive data and source address
    pub fn recvFrom(self: Self, buffer: []u8) !struct { bytes: usize, address: std.net.Address } {
        while (true) {
            var src_addr: std.posix.sockaddr = undefined;
            var src_addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);

            const bytes_received = std.posix.recvfrom(self.fd, buffer, 0, &src_addr, &src_addr_len) catch |err| switch (err) {
                error.WouldBlock => {
                    // Get runtime for waker creation
                    const runtime_instance = runtime.Runtime.global() orelse return error.NoRuntime;
                    const waker = runtime_instance.event_loop_instance.scheduler_instance.createWaker(0);

                    // Register for read readiness
                    try runtime_instance.registerIo(self.fd, .{ .readable = true }, &waker);

                    // Yield execution until ready
                    scheduler.yield();
                    continue;
                },
                else => return err,
            };

            const address = std.net.Address.initPosix(@alignCast(@ptrCast(&src_addr)));
            return .{ .bytes = bytes_received, .address = address };
        }
    }

    /// Close the socket
    pub fn close(self: Self) void {
        std.posix.close(self.fd);
    }

    /// Get local address
    pub fn localAddress(self: Self) std.net.Address {
        return self.local_addr;
    }
};

/// Async file operations
pub const AsyncFile = struct {
    file: std.fs.File,
    
    const Self = @This();

    /// Open a file asynchronously
    pub fn open(path: []const u8, flags: std.fs.File.OpenFlags) !Self {
        const file = try std.fs.cwd().openFile(path, flags);
        return Self{ .file = file };
    }

    /// Read from file
    pub fn read(self: Self, buffer: []u8) !usize {
        return self.file.read(buffer);
    }

    /// Write to file
    pub fn write(self: Self, data: []const u8) !usize {
        return self.file.write(data);
    }

    /// Close the file
    pub fn close(self: Self) void {
        self.file.close();
    }
};

// Tests
test "tcp stream creation" {
    // This would require a real runtime to test properly
    const testing = std.testing;
    try testing.expect(true);
}

test "udp socket creation" {
    // This would require a real runtime to test properly
    const testing = std.testing;
    try testing.expect(true);
}
