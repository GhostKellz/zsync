const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

// io_uring support for async I/O
pub const IoUring = struct {
    fd: i32,
    sq: SubmissionQueue,
    cq: CompletionQueue,
    sqes: []linux.io_uring_sqe,
    
    const SubmissionQueue = struct {
        head: *u32,
        tail: *u32,
        mask: *u32,
        entries: *u32,
        flags: *u32,
        dropped: *u32,
        array: []u32,
    };
    
    const CompletionQueue = struct {
        head: *u32,
        tail: *u32,
        mask: *u32,
        entries: *u32,
        overflow: *u32,
        cqes: []linux.io_uring_cqe,
    };
    
    pub fn init(entries: u32) !IoUring {
        var params = std.mem.zeroes(linux.io_uring_params);
        
        const fd = @as(i32, @intCast(std.os.linux.io_uring_setup(entries, &params)));
        errdefer std.posix.close(fd);
        
        // Map submission queue
        const sq_ring_size = params.sq_off.array + params.sq_entries * @sizeOf(u32);
        const sq_ring_ptr = try std.posix.mmap(
            null,
            sq_ring_size,
            linux.PROT.READ | linux.PROT.WRITE,
            .{ .TYPE = .SHARED, .POPULATE = true },
            fd,
            linux.IORING_OFF_SQ_RING,
        );
        
        // Map submission queue entries
        const sqe_size = params.sq_entries * @sizeOf(linux.io_uring_sqe);
        const sqe_ptr = try std.posix.mmap(
            null,
            sqe_size,
            linux.PROT.READ | linux.PROT.WRITE,
            .{ .TYPE = .SHARED, .POPULATE = true },
            fd,
            linux.IORING_OFF_SQES,
        );
        
        // Map completion queue
        const cq_ring_size = params.cq_off.cqes + params.cq_entries * @sizeOf(linux.io_uring_cqe);
        const cq_ring_ptr = try std.posix.mmap(
            null,
            cq_ring_size,
            linux.PROT.READ | linux.PROT.WRITE,
            .{ .TYPE = .SHARED, .POPULATE = true },
            fd,
            linux.IORING_OFF_CQ_RING,
        );
        
        // Setup submission queue
        const sq = SubmissionQueue{
            .head = @ptrFromInt(@intFromPtr(sq_ring_ptr.ptr) + params.sq_off.head),
            .tail = @ptrFromInt(@intFromPtr(sq_ring_ptr.ptr) + params.sq_off.tail),
            .mask = @ptrFromInt(@intFromPtr(sq_ring_ptr.ptr) + params.sq_off.ring_mask),
            .entries = @ptrFromInt(@intFromPtr(sq_ring_ptr.ptr) + params.sq_off.ring_entries),
            .flags = @ptrFromInt(@intFromPtr(sq_ring_ptr.ptr) + params.sq_off.flags),
            .dropped = @ptrFromInt(@intFromPtr(sq_ring_ptr.ptr) + params.sq_off.dropped),
            .array = @as([*]u32, @ptrFromInt(@intFromPtr(sq_ring_ptr.ptr) + params.sq_off.array))[0..params.sq_entries],
        };
        
        // Setup completion queue
        const cq = CompletionQueue{
            .head = @ptrFromInt(@intFromPtr(cq_ring_ptr.ptr) + params.cq_off.head),
            .tail = @ptrFromInt(@intFromPtr(cq_ring_ptr.ptr) + params.cq_off.tail),
            .mask = @ptrFromInt(@intFromPtr(cq_ring_ptr.ptr) + params.cq_off.ring_mask),
            .entries = @ptrFromInt(@intFromPtr(cq_ring_ptr.ptr) + params.cq_off.ring_entries),
            .overflow = @ptrFromInt(@intFromPtr(cq_ring_ptr.ptr) + params.cq_off.overflow),
            .cqes = @as([*]linux.io_uring_cqe, @ptrFromInt(@intFromPtr(cq_ring_ptr.ptr) + params.cq_off.cqes))[0..params.cq_entries],
        };
        
        const sqes = @as([*]linux.io_uring_sqe, @ptrCast(@alignCast(sqe_ptr.ptr)))[0..params.sq_entries];
        
        return IoUring{
            .fd = fd,
            .sq = sq,
            .cq = cq,
            .sqes = sqes,
        };
    }
    
    pub fn deinit(self: *IoUring) void {
        std.posix.close(self.fd);
        // TODO: unmap memory regions
    }
    
    pub fn getSqe(self: *IoUring) !*linux.io_uring_sqe {
        const head = @atomicLoad(u32, self.sq.head, .Acquire);
        const tail = @atomicLoad(u32, self.sq.tail, .Acquire);
        const mask = self.sq.mask.*;
        
        if (tail - head >= self.sq.entries.*) {
            return error.SubmissionQueueFull;
        }
        
        const idx = tail & mask;
        return &self.sqes[idx];
    }
    
    pub fn submit(self: *IoUring) !u32 {
        const head = @atomicLoad(u32, self.sq.head, .Acquire);
        const tail = @atomicLoad(u32, self.sq.tail, .Acquire);
        const mask = self.sq.mask.*;
        
        // Update submission queue array
        var i = head;
        while (i != tail) : (i += 1) {
            const idx = i & mask;
            self.sq.array[idx] = idx;
        }
        
        // Memory barrier
        std.atomic.fence(.release);
        
        // Update tail
        @atomicStore(u32, self.sq.tail, tail, .Release);
        
        // Submit to kernel
        const submitted = try std.os.linux.io_uring_enter(
            self.fd,
            tail - head,
            0,
            linux.IORING_ENTER_GETEVENTS,
            null,
        );
        
        return submitted;
    }
    
    pub fn getCqe(self: *IoUring) ?*linux.io_uring_cqe {
        const head = @atomicLoad(u32, self.cq.head, .Acquire);
        const tail = @atomicLoad(u32, self.cq.tail, .Acquire);
        
        if (head == tail) {
            return null;
        }
        
        const mask = self.cq.mask.*;
        const idx = head & mask;
        
        return &self.cq.cqes[idx];
    }
    
    pub fn seenCqe(self: *IoUring, cqe: *linux.io_uring_cqe) void {
        _ = cqe;
        const head = @atomicLoad(u32, self.cq.head, .Acquire);
        @atomicStore(u32, self.cq.head, head + 1, .Release);
    }
    
    pub fn wait(self: *IoUring, timeout_ns: ?u64) !u32 {
        var ts: ?linux.timespec = null;
        var ts_val: linux.timespec = undefined;
        
        if (timeout_ns) |ns| {
            ts_val = .{
                .tv_sec = @intCast(ns / 1_000_000_000),
                .tv_nsec = @intCast(ns % 1_000_000_000),
            };
            ts = &ts_val;
        }
        
        return try std.os.linux.io_uring_enter(
            self.fd,
            0,
            1,
            linux.IORING_ENTER_GETEVENTS,
            ts,
        );
    }
};

// Epoll support for event monitoring
pub const Epoll = struct {
    fd: i32,
    
    pub fn init() !Epoll {
        const fd = try std.posix.epoll_create1(linux.EPOLL_CLOEXEC);
        return Epoll{ .fd = fd };
    }
    
    pub fn deinit(self: *Epoll) void {
        std.posix.close(self.fd);
    }
    
    pub fn add(self: *Epoll, fd: i32, events: u32, data: u64) !void {
        var ev = linux.epoll_event{
            .events = events,
            .data = .{ .u64 = data },
        };
        try std.posix.epoll_ctl(self.fd, linux.EPOLL_CTL_ADD, fd, &ev);
    }
    
    pub fn modify(self: *Epoll, fd: i32, events: u32, data: u64) !void {
        var ev = linux.epoll_event{
            .events = events,
            .data = .{ .u64 = data },
        };
        try std.posix.epoll_ctl(self.fd, linux.EPOLL_CTL_MOD, fd, &ev);
    }
    
    pub fn delete(self: *Epoll, fd: i32) !void {
        try std.posix.epoll_ctl(self.fd, linux.EPOLL_CTL_DEL, fd, null);
    }
    
    pub fn wait(self: *Epoll, events: []linux.epoll_event, timeout_ms: i32) !usize {
        const n = try std.posix.epoll_wait(self.fd, events, timeout_ms);
        return n;
    }
};

// Event source abstraction
pub const EventSource = union(enum) {
    io_uring: *IoUring,
    epoll: *Epoll,
    
    pub fn init(use_io_uring: bool) !EventSource {
        if (use_io_uring) {
            // Check if io_uring is available
            if (checkIoUringSupport()) {
                var ring = try IoUring.init(256);
                return EventSource{ .io_uring = &ring };
            }
        }
        
        // Fallback to epoll
        var epoll = try Epoll.init();
        return EventSource{ .epoll = &epoll };
    }
    
    pub fn deinit(self: *EventSource) void {
        switch (self.*) {
            .io_uring => |ring| ring.deinit(),
            .epoll => |ep| ep.deinit(),
        }
    }
};

// Check if io_uring is supported
fn checkIoUringSupport() bool {
    // Try to create a small io_uring instance
    var params = std.mem.zeroes(linux.io_uring_params);
    const fd = linux.io_uring_setup(2, &params) catch return false;
    std.posix.close(@intCast(fd));
    return true;
}

// Timer support using timerfd
pub const Timer = struct {
    fd: i32,
    
    pub fn init() !Timer {
        const fd = try std.posix.timerfd_create(linux.CLOCK.MONOTONIC, linux.TFD_CLOEXEC);
        return Timer{ .fd = fd };
    }
    
    pub fn deinit(self: *Timer) void {
        std.posix.close(self.fd);
    }
    
    pub fn setRelative(self: *Timer, ns: u64) !void {
        const spec = linux.itimerspec{
            .it_interval = .{ .tv_sec = 0, .tv_nsec = 0 },
            .it_value = .{
                .tv_sec = @intCast(ns / 1_000_000_000),
                .tv_nsec = @intCast(ns % 1_000_000_000),
            },
        };
        try std.posix.timerfd_settime(self.fd, 0, &spec, null);
    }
    
    pub fn setAbsolute(self: *Timer, ns: u64) !void {
        const spec = linux.itimerspec{
            .it_interval = .{ .tv_sec = 0, .tv_nsec = 0 },
            .it_value = .{
                .tv_sec = @intCast(ns / 1_000_000_000),
                .tv_nsec = @intCast(ns % 1_000_000_000),
            },
        };
        try std.posix.timerfd_settime(self.fd, linux.TFD_TIMER_ABSTIME, &spec, null);
    }
    
    pub fn read(self: *Timer) !u64 {
        var buf: u64 = undefined;
        _ = try std.posix.read(self.fd, std.mem.asBytes(&buf));
        return buf;
    }
};

// Event loop integration
pub const EventLoop = struct {
    source: EventSource,
    timers: std.ArrayList(Timer),
    
    pub fn init(allocator: std.mem.Allocator) !EventLoop {
        return EventLoop{
            .source = try EventSource.init(true),
            .timers = std.ArrayList(Timer).init(allocator),
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
        switch (self.source) {
            .io_uring => |ring| try self.runIoUring(ring),
            .epoll => |ep| try self.runEpoll(ep),
        }
    }
    
    fn runIoUring(self: *EventLoop, ring: *IoUring) !void {
        _ = self;
        while (true) {
            _ = try ring.wait(null);
            
            // Process completions
            while (ring.getCqe()) |cqe| {
                defer ring.seenCqe(cqe);
                
                // Handle completion based on user_data
                const task_id = cqe.user_data;
                _ = task_id;
                // TODO: Resume corresponding green thread
            }
        }
    }
    
    fn runEpoll(self: *EventLoop, ep: *Epoll) !void {
        _ = self;
        var events: [256]linux.epoll_event = undefined;
        
        while (true) {
            const n = try ep.wait(&events, -1);
            
            for (events[0..n]) |event| {
                const task_id = event.data.u64;
                _ = task_id;
                // TODO: Resume corresponding green thread
            }
        }
    }
};

// CPU affinity helpers
pub fn setThreadAffinity(cpu: u32) !void {
    var set = std.mem.zeroes(linux.cpu_set_t);
    linux.CPU_SET(cpu, &set);
    
    try std.os.linux.sched_setaffinity(0, @sizeOf(linux.cpu_set_t), &set);
}

pub fn getNumCpus() u32 {
    return @intCast(std.Thread.getCpuCount() catch 1);
}

// Memory barriers and atomics
pub inline fn memoryBarrier() void {
    std.atomic.fence(.seq_cst);
}

pub inline fn loadAcquire(comptime T: type, ptr: *const T) T {
    return @atomicLoad(T, ptr, .Acquire);
}

pub inline fn storeRelease(comptime T: type, ptr: *T, value: T) void {
    @atomicStore(T, ptr, value, .Release);
}