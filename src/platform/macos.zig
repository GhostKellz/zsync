const std = @import("std");
const builtin = @import("builtin");
const c = std.c;

// macOS kqueue support for async I/O
pub const Kqueue = struct {
    fd: i32,
    
    pub fn init() !Kqueue {
        const fd = try std.posix.kqueue();
        return Kqueue{ .fd = fd };
    }
    
    pub fn deinit(self: *Kqueue) void {
        std.posix.close(self.fd);
    }
    
    pub fn addRead(self: *Kqueue, fd: i32, udata: ?*anyopaque) !void {
        var kev = std.c.Kevent{
            .ident = @intCast(fd),
            .filter = std.c.EVFILT_READ,
            .flags = std.c.EV_ADD | std.c.EV_ENABLE,
            .fflags = 0,
            .data = 0,
            .udata = udata,
        };
        
        const result = std.c.kevent(self.fd, &kev, 1, null, 0, null);
        if (result == -1) {
            switch (std.posix.errno(result)) {
                .BADF => return error.BadFileDescriptor,
                .NOMEM => return error.SystemResources,
                .INVAL => return error.InvalidArguments,
                else => return error.Unexpected,
            }
        }
    }
    
    pub fn addWrite(self: *Kqueue, fd: i32, udata: ?*anyopaque) !void {
        var kev = std.c.Kevent{
            .ident = @intCast(fd),
            .filter = std.c.EVFILT_WRITE,
            .flags = std.c.EV_ADD | std.c.EV_ENABLE,
            .fflags = 0,
            .data = 0,
            .udata = udata,
        };
        
        const result = std.c.kevent(self.fd, &kev, 1, null, 0, null);
        if (result == -1) {
            switch (std.posix.errno(result)) {
                .BADF => return error.BadFileDescriptor,
                .NOMEM => return error.SystemResources,
                .INVAL => return error.InvalidArguments,
                else => return error.Unexpected,
            }
        }
    }
    
    pub fn addTimer(self: *Kqueue, ident: usize, timeout_ns: u64, udata: ?*anyopaque) !void {
        var kev = std.c.Kevent{
            .ident = ident,
            .filter = std.c.EVFILT_TIMER,
            .flags = std.c.EV_ADD | std.c.EV_ENABLE | std.c.EV_ONESHOT,
            .fflags = 0,
            .data = @intCast(timeout_ns / 1_000_000), // Convert to milliseconds
            .udata = udata,
        };
        
        const result = std.c.kevent(self.fd, &kev, 1, null, 0, null);
        if (result == -1) {
            switch (std.posix.errno(result)) {
                .BADF => return error.BadFileDescriptor,
                .NOMEM => return error.SystemResources,
                .INVAL => return error.InvalidArguments,
                else => return error.Unexpected,
            }
        }
    }
    
    pub fn delete(self: *Kqueue, fd: i32, filter: i16) !void {
        var kev = std.c.Kevent{
            .ident = @intCast(fd),
            .filter = filter,
            .flags = std.c.EV_DELETE,
            .fflags = 0,
            .data = 0,
            .udata = null,
        };
        
        const result = std.c.kevent(self.fd, &kev, 1, null, 0, null);
        if (result == -1) {
            switch (std.posix.errno(result)) {
                .BADF => return error.BadFileDescriptor,
                .NOENT => return error.NotFound,
                .INVAL => return error.InvalidArguments,
                else => return error.Unexpected,
            }
        }
    }
    
    pub fn wait(self: *Kqueue, events: []std.c.Kevent, timeout: ?std.c.timespec) !usize {
        const timeout_ptr = if (timeout) |*ts| ts else null;
        
        const result = std.c.kevent(self.fd, null, 0, events.ptr, @intCast(events.len), timeout_ptr);
        if (result == -1) {
            switch (std.posix.errno(result)) {
                .BADF => return error.BadFileDescriptor,
                .INTR => return error.Interrupted,
                .INVAL => return error.InvalidArguments,
                else => return error.Unexpected,
            }
        }
        
        return @intCast(result);
    }
};

// Timer support using kqueue timers
pub const Timer = struct {
    kq: *Kqueue,
    ident: usize,
    
    // Static counter for unique timer identifiers
    var next_ident: std.atomic.Value(usize) = std.atomic.Value(usize).init(1);
    
    pub fn init(kq: *Kqueue) Timer {
        return Timer{
            .kq = kq,
            .ident = next_ident.fetchAdd(1, .monotonic),
        };
    }
    
    pub fn deinit(self: *Timer) void {
        // Timer is automatically cleaned up by kqueue when it fires or is deleted
        _ = self;
    }
    
    pub fn setRelative(self: *Timer, ns: u64, udata: ?*anyopaque) !void {
        try self.kq.addTimer(self.ident, ns, udata);
    }
    
    pub fn cancel(self: *Timer) !void {
        try self.kq.delete(@intCast(self.ident), std.c.EVFILT_TIMER);
    }
};

// Event source abstraction for macOS
pub const EventSource = struct {
    kqueue: Kqueue,
    
    pub fn init() !EventSource {
        return EventSource{
            .kqueue = try Kqueue.init(),
        };
    }
    
    pub fn deinit(self: *EventSource) void {
        self.kqueue.deinit();
    }
    
    pub fn addRead(self: *EventSource, fd: i32, udata: ?*anyopaque) !void {
        try self.kqueue.addRead(fd, udata);
    }
    
    pub fn addWrite(self: *EventSource, fd: i32, udata: ?*anyopaque) !void {
        try self.kqueue.addWrite(fd, udata);
    }
    
    pub fn deleteRead(self: *EventSource, fd: i32) !void {
        try self.kqueue.delete(fd, std.c.EVFILT_READ);
    }
    
    pub fn deleteWrite(self: *EventSource, fd: i32) !void {
        try self.kqueue.delete(fd, std.c.EVFILT_WRITE);
    }
};

// Event loop integration for macOS
pub const EventLoop = struct {
    source: EventSource,
    timers: std.ArrayList(Timer),
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) !EventLoop {
        return EventLoop{
            .source = try EventSource.init(),
            .timers = std.ArrayList(Timer){ .allocator = allocator },
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *EventLoop) void {
        for (self.timers.items) |*timer| {
            timer.deinit();
        }
        self.timers.deinit();
        self.source.deinit();
    }
    
    pub fn run(self: *EventLoop) !void {
        var events: [256]std.c.Kevent = undefined;
        
        while (true) {
            const n = try self.source.kqueue.wait(&events, null);
            
            for (events[0..n]) |event| {
                switch (event.filter) {
                    std.c.EVFILT_READ => {
                        // Handle read event
                        const task_id = @intFromPtr(event.udata);
                        _ = task_id;
                        // TODO: Resume corresponding green thread for read
                    },
                    std.c.EVFILT_WRITE => {
                        // Handle write event
                        const task_id = @intFromPtr(event.udata);
                        _ = task_id;
                        // TODO: Resume corresponding green thread for write
                    },
                    std.c.EVFILT_TIMER => {
                        // Handle timer event
                        const task_id = @intFromPtr(event.udata);
                        _ = task_id;
                        // TODO: Resume corresponding green thread for timer
                    },
                    else => {
                        // Unknown event type
                        std.debug.print("Unknown kqueue event filter: {}\n", .{event.filter});
                    },
                }
                
                // Check for errors
                if (event.flags & std.c.EV_ERROR != 0) {
                    std.debug.print("kqueue event error: {}\n", .{event.data});
                }
            }
        }
    }
    
    pub fn createTimer(self: *EventLoop) !*Timer {
        const timer = Timer.init(&self.source.kqueue);
        try self.timers.append(self.allocator, timer);
        return &self.timers.items[self.timers.items.len - 1];
    }
};

// CPU affinity helpers for macOS
pub fn setThreadAffinity(cpu: u32) !void {
    // macOS doesn't support direct CPU affinity like Linux
    // We can use thread_policy_set with THREAD_AFFINITY_POLICY
    // But it's more complex and less reliable than Linux
    _ = cpu;
    
    // For now, return success but don't actually set affinity
    // TODO: Implement proper macOS thread affinity if needed
}

pub fn getNumCpus() u32 {
    return @intCast(std.Thread.getCpuCount() catch 1);
}

// Memory barriers and atomics (same as Linux)
pub inline fn memoryBarrier() void {
    std.atomic.fence(.seq_cst);
}

pub inline fn loadAcquire(comptime T: type, ptr: *const T) T {
    return @atomicLoad(T, ptr, .Acquire);
}

pub inline fn storeRelease(comptime T: type, ptr: *T, value: T) void {
    @atomicStore(T, ptr, value, .Release);
}

// macOS-specific networking optimizations
pub const NetworkOptimizations = struct {
    pub fn enableTcpNoDelay(fd: i32) !void {
        const flag: c_int = 1;
        const result = std.c.setsockopt(fd, std.c.IPPROTO.TCP, std.c.TCP_NODELAY, &flag, @sizeOf(c_int));
        if (result != 0) {
            return error.SetSockOptFailed;
        }
    }
    
    pub fn enableReuseAddr(fd: i32) !void {
        const flag: c_int = 1;
        const result = std.c.setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.REUSEADDR, &flag, @sizeOf(c_int));
        if (result != 0) {
            return error.SetSockOptFailed;
        }
    }
    
    pub fn enableReusePort(fd: i32) !void {
        const flag: c_int = 1;
        const result = std.c.setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.REUSEPORT, &flag, @sizeOf(c_int));
        if (result != 0) {
            return error.SetSockOptFailed;
        }
    }
    
    pub fn setReceiveBufferSize(fd: i32, size: c_int) !void {
        const result = std.c.setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.RCVBUF, &size, @sizeOf(c_int));
        if (result != 0) {
            return error.SetSockOptFailed;
        }
    }
    
    pub fn setSendBufferSize(fd: i32, size: c_int) !void {
        const result = std.c.setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.SNDBUF, &size, @sizeOf(c_int));
        if (result != 0) {
            return error.SetSockOptFailed;
        }
    }
};

// Grand Central Dispatch integration for macOS
pub const GCD = struct {
    // Placeholder for potential GCD integration
    // This could be used for additional async operations
    // that complement kqueue
    
    pub fn dispatchAsync(comptime func: anytype, args: anytype) void {
        _ = func;
        _ = args;
        // TODO: Implement GCD integration if needed
        // This would allow using libdispatch for certain operations
    }
};