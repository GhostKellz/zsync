const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;

// Windows IOCP (I/O Completion Ports) implementation
pub const IOCP = struct {
    handle: windows.HANDLE,
    
    pub fn init(max_concurrent_threads: u32) !IOCP {
        const handle = windows.kernel32.CreateIoCompletionPort(
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
        const result = windows.kernel32.CreateIoCompletionPort(
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
        overlapped: **windows.OVERLAPPED,
        timeout_ms: u32,
    ) !bool {
        const result = windows.kernel32.GetQueuedCompletionStatus(
            self.handle,
            bytes_transferred,
            completion_key,
            overlapped,
            timeout_ms,
        );
        
        if (result == 0) {
            const err = windows.kernel32.GetLastError();
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
        overlapped: ?*windows.OVERLAPPED,
    ) !void {
        const result = windows.kernel32.PostQueuedCompletionStatus(
            self.handle,
            bytes_transferred,
            completion_key,
            overlapped,
        );
        
        if (result == 0) {
            return error.PostCompletionStatusFailed;
        }
    }
};

// Windows async I/O operation
pub const AsyncOp = struct {
    overlapped: windows.OVERLAPPED,
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
            .overlapped = std.mem.zeroes(windows.OVERLAPPED),
            .operation_type = .read,
            .buffer = buffer,
            .completion_key = completion_key,
        };
    }
    
    pub fn initWrite(buffer: []u8, completion_key: usize) AsyncOp {
        return AsyncOp{
            .overlapped = std.mem.zeroes(windows.OVERLAPPED),
            .operation_type = .write,
            .buffer = buffer,
            .completion_key = completion_key,
        };
    }
    
    pub fn readFile(self: *AsyncOp, file_handle: windows.HANDLE) !void {
        var bytes_read: u32 = undefined;
        const result = windows.kernel32.ReadFile(
            file_handle,
            self.buffer.ptr,
            @intCast(self.buffer.len),
            &bytes_read,
            &self.overlapped,
        );
        
        if (result == 0) {
            const err = windows.kernel32.GetLastError();
            if (err != .IO_PENDING) {
                return error.ReadFileFailed;
            }
        }
    }
    
    pub fn writeFile(self: *AsyncOp, file_handle: windows.HANDLE) !void {
        var bytes_written: u32 = undefined;
        const result = windows.kernel32.WriteFile(
            file_handle,
            self.buffer.ptr,
            @intCast(self.buffer.len),
            &bytes_written,
            &self.overlapped,
        );
        
        if (result == 0) {
            const err = windows.kernel32.GetLastError();
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
        const handle = windows.kernel32.CreateWaitableTimerW(
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
        
        const result = windows.kernel32.SetWaitableTimer(
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
        const result = windows.kernel32.CancelWaitableTimer(self.handle);
        if (result == 0) {
            return error.CancelTimerFailed;
        }
    }
    
    pub fn wait(self: *Timer, timeout_ms: u32) !bool {
        const result = windows.kernel32.WaitForSingleObject(self.handle, timeout_ms);
        return switch (result) {
            windows.WAIT_OBJECT_0 => true,
            windows.WAIT_TIMEOUT => false,
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
    
    pub fn postCompletion(self: *EventSource, bytes: u32, key: usize, overlapped: ?*windows.OVERLAPPED) !void {
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
            .timers = .{},
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
        var overlapped: *windows.OVERLAPPED = undefined;
        
        while (true) {
            const has_completion = try self.source.iocp.getQueuedCompletionStatus(
                &bytes_transferred,
                &completion_key,
                &overlapped,
                windows.INFINITE, // Block indefinitely
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
        var overlapped: *windows.OVERLAPPED = undefined;
        
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
    const result = windows.kernel32.SetThreadAffinityMask(
        windows.kernel32.GetCurrentThread(),
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
    return @atomicLoad(T, ptr, .Acquire);
}

pub inline fn storeRelease(comptime T: type, ptr: *T, value: T) void {
    @atomicStore(T, ptr, value, .Release);
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