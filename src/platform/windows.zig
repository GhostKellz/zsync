const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;

// Windows wait result constants
pub const WAIT_OBJECT_0: u32 = 0;
pub const WAIT_TIMEOUT: u32 = 258;

pub const OVERLAPPED = extern struct {
    Internal: usize = 0,
    InternalHigh: usize = 0,
    Anonymous: extern union {
        s: extern struct {
            Offset: u32,
            OffsetHigh: u32,
        },
        Pointer: ?*anyopaque,
    } = .{ .Pointer = null },
    hEvent: ?windows.HANDLE = null,
};
const wait_infinite: u32 = 0xffff_ffff;

extern "kernel32" fn CreateIoCompletionPort(
    file_handle: windows.HANDLE,
    existing_completion_port: ?windows.HANDLE,
    completion_key: usize,
    number_of_concurrent_threads: u32,
) callconv(.c) ?windows.HANDLE;

extern "kernel32" fn GetQueuedCompletionStatus(
    completion_port: windows.HANDLE,
    lpNumberOfBytesTransferred: *u32,
    lpCompletionKey: *usize,
    lpOverlapped: **OVERLAPPED,
    dwMilliseconds: u32,
) callconv(.c) windows.BOOL;

extern "kernel32" fn PostQueuedCompletionStatus(
    completion_port: windows.HANDLE,
    dwNumberOfBytesTransferred: u32,
    dwCompletionKey: usize,
    lpOverlapped: ?*OVERLAPPED,
) callconv(.c) windows.BOOL;

extern "kernel32" fn CreateWaitableTimerW(
    timer_attributes: ?*anyopaque,
    manual_reset: windows.BOOL,
    timer_name: ?[*:0]const u16,
) callconv(.c) ?windows.HANDLE;

extern "kernel32" fn SetWaitableTimer(
    timer: windows.HANDLE,
    due_time: *const i64,
    period: i32,
    completion_routine: ?*anyopaque,
    arg_to_completion_routine: ?*anyopaque,
    resume_system: windows.BOOL,
) callconv(.c) windows.BOOL;

extern "kernel32" fn CancelWaitableTimer(timer: windows.HANDLE) callconv(.c) windows.BOOL;

extern "kernel32" fn WaitForSingleObject(handle: windows.HANDLE, milliseconds: u32) callconv(.c) u32;

extern "kernel32" fn SetThreadAffinityMask(thread: windows.HANDLE, mask: usize) callconv(.c) usize;

extern "kernel32" fn GetCurrentThread() callconv(.c) windows.HANDLE;

extern "kernel32" fn GetLastError() callconv(.c) windows.Win32Error;

pub extern "kernel32" fn ReadFile(
    file_handle: windows.HANDLE,
    buffer: ?*anyopaque,
    bytes_to_read: u32,
    bytes_read: ?*u32,
    overlapped: ?*OVERLAPPED,
) callconv(.c) windows.BOOL;

pub extern "kernel32" fn WriteFile(
    file_handle: windows.HANDLE,
    buffer: ?*const anyopaque,
    bytes_to_write: u32,
    bytes_written: ?*u32,
    overlapped: ?*OVERLAPPED,
) callconv(.c) windows.BOOL;

pub extern "kernel32" fn CloseHandle(handle: windows.HANDLE) callconv(.c) windows.BOOL;

pub extern "kernel32" fn SetFilePointerEx(
    file_handle: windows.HANDLE,
    distance_to_move: i64,
    new_file_pointer: ?*i64,
    move_method: u32,
) callconv(.c) windows.BOOL;

// SetFilePointerEx move methods
pub const FILE_BEGIN: u32 = 0;
pub const FILE_CURRENT: u32 = 1;
pub const FILE_END: u32 = 2;

// Winsock2 socket functions for synchronous I/O
pub extern "ws2_32" fn recv(
    socket: windows.HANDLE,
    buf: [*]u8,
    len: c_int,
    flags: c_int,
) callconv(.c) c_int;

pub extern "ws2_32" fn send(
    socket: windows.HANDLE,
    buf: [*]const u8,
    len: c_int,
    flags: c_int,
) callconv(.c) c_int;

pub extern "ws2_32" fn closesocket(socket: windows.HANDLE) callconv(.c) c_int;

pub extern "ws2_32" fn accept(
    socket: windows.HANDLE,
    addr: ?*sockaddr,
    addrlen: ?*c_int,
) callconv(.c) windows.HANDLE;

pub extern "ws2_32" fn connect(
    socket: windows.HANDLE,
    addr: *const sockaddr,
    addrlen: c_int,
) callconv(.c) c_int;

pub extern "ws2_32" fn WSAGetLastError() callconv(.c) c_int;

// Socket address structure for accept/connect
pub const sockaddr = extern struct {
    family: u16,
    data: [14]u8,
};

// Socket error codes
pub const SOCKET_ERROR: c_int = -1;
pub const INVALID_SOCKET: windows.HANDLE = @ptrFromInt(~@as(usize, 0));
pub const WSAEWOULDBLOCK: c_int = 10035;

// Windows IOCP (I/O Completion Ports) implementation
pub const IOCP = struct {
    handle: windows.HANDLE,

    pub fn init(max_concurrent_threads: u32) !IOCP {
        const handle = CreateIoCompletionPort(
            windows.INVALID_HANDLE_VALUE,
            null,
            0,
            max_concurrent_threads,
        ) orelse return error.CreateIocpFailed;

        return IOCP{ .handle = handle };
    }

    pub fn deinit(self: *IOCP) void {
        windows.CloseHandle(self.handle);
    }

    pub fn associate(self: *IOCP, file_handle: windows.HANDLE, completion_key: usize) !void {
        const result = CreateIoCompletionPort(
            file_handle,
            self.handle,
            completion_key,
            0,
        );
        if (result == null) {
            return error.AssociateFileFailed;
        }
    }

    pub fn getQueuedCompletionStatus(
        self: *IOCP,
        bytes_transferred: *u32,
        completion_key: *usize,
        overlapped: **OVERLAPPED,
        timeout_ms: u32,
    ) !bool {
        const result = GetQueuedCompletionStatus(
            self.handle,
            bytes_transferred,
            completion_key,
            overlapped,
            timeout_ms,
        );

        if (result == .FALSE) {
            const err = GetLastError();
            if (err == .WAIT_TIMEOUT) {
                return false; // Timeout, no completion
            }
            return error.GetCompletionStatusFailed;
        }

        return true;
    }

    pub fn postQueuedCompletionStatus(
        self: *IOCP,
        bytes_transferred: u32,
        completion_key: usize,
        overlapped: ?*OVERLAPPED,
    ) !void {
        const result = PostQueuedCompletionStatus(
            self.handle,
            bytes_transferred,
            completion_key,
            overlapped,
        );

        if (result == .FALSE) {
            return error.PostCompletionStatusFailed;
        }
    }
};

// Windows async I/O operation
pub const AsyncOp = struct {
    overlapped: OVERLAPPED,
    operation_type: OperationType,
    buffer: []u8,
    completion_key: usize,

    const OperationType = enum {
        read,
        write,
        connect,
        accept,
        timer,
    };

    pub fn initRead(buffer: []u8, completion_key: usize) AsyncOp {
        return AsyncOp{
            .overlapped = std.mem.zeroes(OVERLAPPED),
            .operation_type = .read,
            .buffer = buffer,
            .completion_key = completion_key,
        };
    }

    pub fn initWrite(buffer: []u8, completion_key: usize) AsyncOp {
        return AsyncOp{
            .overlapped = std.mem.zeroes(OVERLAPPED),
            .operation_type = .write,
            .buffer = buffer,
            .completion_key = completion_key,
        };
    }

    pub fn readFile(self: *AsyncOp, file_handle: windows.HANDLE) !void {
        var bytes_read: u32 = undefined;
        const result = ReadFile(
            file_handle,
            self.buffer.ptr,
            @intCast(self.buffer.len),
            &bytes_read,
            &self.overlapped,
        );

        if (result == 0) {
            const err = GetLastError();
            if (err != .IO_PENDING) {
                return error.ReadFileFailed;
            }
        }
    }

    pub fn writeFile(self: *AsyncOp, file_handle: windows.HANDLE) !void {
        var bytes_written: u32 = undefined;
        const result = WriteFile(
            file_handle,
            self.buffer.ptr,
            @intCast(self.buffer.len),
            &bytes_written,
            &self.overlapped,
        );

        if (result == 0) {
            const err = GetLastError();
            if (err != .IO_PENDING) {
                return error.WriteFileFailed;
            }
        }
    }
};

// Windows timer using CreateWaitableTimer
pub const Timer = struct {
    handle: windows.HANDLE,

    pub fn init() !Timer {
        const handle = CreateWaitableTimerW(
            null,
            windows.TRUE, // Manual reset
            null,
        ) orelse return error.CreateTimerFailed;

        return Timer{ .handle = handle };
    }

    pub fn deinit(self: *Timer) void {
        windows.CloseHandle(self.handle);
    }

    pub fn setRelative(self: *Timer, ns: u64) !void {
        // Convert nanoseconds to 100-nanosecond intervals (negative for relative)
        const intervals: i64 = -@as(i64, @intCast(ns / 100));

        const result = SetWaitableTimer(
            self.handle,
            @ptrCast(&intervals),
            0, // No period (one-shot)
            null, // No completion routine
            null, // No arg to completion routine
            windows.FALSE, // Don't resume system
        );

        if (result == 0) {
            return error.SetTimerFailed;
        }
    }

    pub fn cancel(self: *Timer) !void {
        const result = CancelWaitableTimer(self.handle);
        if (result == 0) {
            return error.CancelTimerFailed;
        }
    }

    pub fn wait(self: *Timer, timeout_ms: u32) !bool {
        const result = WaitForSingleObject(self.handle, timeout_ms);
        return switch (result) {
            WAIT_OBJECT_0 => true,
            WAIT_TIMEOUT => false,
            else => error.WaitFailed,
        };
    }
};

// Event source abstraction for Windows
pub const EventSource = struct {
    iocp: IOCP,

    pub fn init() !EventSource {
        const num_cpus = getNumCpus();
        return EventSource{
            .iocp = try IOCP.init(num_cpus),
        };
    }

    pub fn deinit(self: *EventSource) void {
        self.iocp.deinit();
    }

    pub fn associateFile(self: *EventSource, file_handle: windows.HANDLE, completion_key: usize) !void {
        try self.iocp.associate(file_handle, completion_key);
    }

    pub fn postCompletion(self: *EventSource, bytes: u32, key: usize, overlapped: ?*OVERLAPPED) !void {
        try self.iocp.postQueuedCompletionStatus(bytes, key, overlapped);
    }
};

// Event loop integration for Windows
pub const EventLoop = struct {
    source: EventSource,
    timers: std.ArrayList(Timer),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !EventLoop {
        return EventLoop{
            .source = try EventSource.init(),
            .timers = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *EventLoop) void {
        for (self.timers.items) |*timer| {
            timer.deinit();
        }
        self.timers.deinit(self.allocator);
        self.source.deinit();
    }

    pub fn run(self: *EventLoop) !void {
        var bytes_transferred: u32 = undefined;
        var completion_key: usize = undefined;
        var overlapped: *OVERLAPPED = undefined;

        while (true) {
            const has_completion = try self.source.iocp.getQueuedCompletionStatus(
                &bytes_transferred,
                &completion_key,
                &overlapped,
                wait_infinite, // Block indefinitely
            );

            if (has_completion) {
                // Handle completion based on completion_key
                const task_id = completion_key;
                _ = task_id;
                // TODO: Resume corresponding green thread

                std.debug.print("IOCP completion: key={}, bytes={}\n", .{ completion_key, bytes_transferred });
            }
        }
    }

    pub fn createTimer(self: *EventLoop) !*Timer {
        const timer = try Timer.init();
        try self.timers.append(self.allocator, timer);
        return &self.timers.items[self.timers.items.len - 1];
    }

    pub fn runOnce(self: *EventLoop, timeout_ms: u32) !bool {
        var bytes_transferred: u32 = undefined;
        var completion_key: usize = undefined;
        var overlapped: *OVERLAPPED = undefined;

        return try self.source.iocp.getQueuedCompletionStatus(
            &bytes_transferred,
            &completion_key,
            &overlapped,
            timeout_ms,
        );
    }
};

// Windows thread affinity using SetThreadAffinityMask
pub fn setThreadAffinity(cpu: u32) !void {
    const mask: usize = @as(usize, 1) << @intCast(cpu);
    const result = SetThreadAffinityMask(
        GetCurrentThread(),
        mask,
    );

    if (result == 0) {
        return error.SetAffinityFailed;
    }
}

pub fn getNumCpus() u32 {
    return @intCast(std.Thread.getCpuCount() catch 1);
}

// Windows memory barriers and atomics
pub inline fn memoryBarrier() void {
    std.atomic.fence(.seq_cst);
}

pub inline fn loadAcquire(comptime T: type, ptr: *const T) T {
    return @atomicLoad(T, ptr, .acquire);
}

pub inline fn storeRelease(comptime T: type, ptr: *T, value: T) void {
    @atomicStore(T, ptr, value, .release);
}

// Windows-specific networking optimizations
pub const NetworkOptimizations = struct {
    pub fn enableTcpNoDelay(socket: windows.SOCKET) !void {
        const flag: c_int = 1;
        const result = windows.ws2_32.setsockopt(
            socket,
            windows.ws2_32.IPPROTO_TCP,
            windows.ws2_32.TCP_NODELAY,
            @ptrCast(&flag),
            @sizeOf(c_int),
        );
        if (result != 0) {
            return error.SetSockOptFailed;
        }
    }

    pub fn enableReuseAddr(socket: windows.SOCKET) !void {
        const flag: c_int = 1;
        const result = windows.ws2_32.setsockopt(
            socket,
            windows.ws2_32.SOL_SOCKET,
            windows.ws2_32.SO_REUSEADDR,
            @ptrCast(&flag),
            @sizeOf(c_int),
        );
        if (result != 0) {
            return error.SetSockOptFailed;
        }
    }

    pub fn setReceiveBufferSize(socket: windows.SOCKET, size: c_int) !void {
        const result = windows.ws2_32.setsockopt(
            socket,
            windows.ws2_32.SOL_SOCKET,
            windows.ws2_32.SO_RCVBUF,
            @ptrCast(&size),
            @sizeOf(c_int),
        );
        if (result != 0) {
            return error.SetSockOptFailed;
        }
    }

    pub fn setSendBufferSize(socket: windows.SOCKET, size: c_int) !void {
        const result = windows.ws2_32.setsockopt(
            socket,
            windows.ws2_32.SOL_SOCKET,
            windows.ws2_32.SO_SNDBUF,
            @ptrCast(&size),
            @sizeOf(c_int),
        );
        if (result != 0) {
            return error.SetSockOptFailed;
        }
    }
};

// Windows async socket operations using WSASend/WSARecv
pub const AsyncSocket = struct {
    socket: windows.SOCKET,

    pub fn init(family: c_int, sock_type: c_int, protocol: c_int) !AsyncSocket {
        const socket = windows.ws2_32.WSASocketW(
            family,
            sock_type,
            protocol,
            null,
            0,
            windows.ws2_32.WSA_FLAG_OVERLAPPED,
        );

        if (socket == windows.ws2_32.INVALID_SOCKET) {
            return error.CreateSocketFailed;
        }

        return AsyncSocket{ .socket = socket };
    }

    pub fn deinit(self: *AsyncSocket) void {
        _ = windows.ws2_32.closesocket(self.socket);
    }

    pub fn asyncRecv(self: *AsyncSocket, buffer: []u8, overlapped: *windows.OVERLAPPED) !void {
        var wsabuf = windows.ws2_32.WSABUF{
            .len = @intCast(buffer.len),
            .buf = buffer.ptr,
        };

        var bytes_received: u32 = undefined;
        var flags: u32 = 0;

        const result = windows.ws2_32.WSARecv(
            self.socket,
            &wsabuf,
            1,
            &bytes_received,
            &flags,
            overlapped,
            null,
        );

        if (result != 0) {
            const err = windows.ws2_32.WSAGetLastError();
            if (err != windows.ws2_32.WSA_IO_PENDING) {
                return error.AsyncRecvFailed;
            }
        }
    }

    pub fn asyncSend(self: *AsyncSocket, buffer: []const u8, overlapped: *windows.OVERLAPPED) !void {
        var wsabuf = windows.ws2_32.WSABUF{
            .len = @intCast(buffer.len),
            .buf = @constCast(buffer.ptr),
        };

        var bytes_sent: u32 = undefined;

        const result = windows.ws2_32.WSASend(
            self.socket,
            &wsabuf,
            1,
            &bytes_sent,
            0,
            overlapped,
            null,
        );

        if (result != 0) {
            const err = windows.ws2_32.WSAGetLastError();
            if (err != windows.ws2_32.WSA_IO_PENDING) {
                return error.AsyncSendFailed;
            }
        }
    }
};
