const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

// Advanced io_uring support optimized for Arch Linux
pub const IoUring = struct {
    fd: i32,
    sq: SubmissionQueue,
    cq: CompletionQueue,
    sqes: []linux.io_uring_sqe,
    features: u32,
    ring_fd: i32,

    // Advanced features for Arch Linux optimization
    sq_ring_ptr: []align(4096) u8,
    cq_ring_ptr: []align(4096) u8,
    sqe_ptr: []align(4096) u8,

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

        // Request advanced features for Arch Linux optimization
        params.flags = linux.IORING_SETUP_SQPOLL | // Kernel polling thread
            linux.IORING_SETUP_SQ_AFF | // CPU affinity for SQ poll thread
            linux.IORING_SETUP_CQSIZE; // Custom CQ size
        params.cq_entries = entries * 2; // Larger completion queue
        params.sq_thread_idle = 1000; // 1 second idle before sleeping

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
            .features = params.features,
            .ring_fd = fd,
            .sq_ring_ptr = @as([]align(4096) u8, @alignCast(sq_ring_ptr)),
            .cq_ring_ptr = @as([]align(4096) u8, @alignCast(cq_ring_ptr)),
            .sqe_ptr = @as([]align(4096) u8, @alignCast(sqe_ptr)),
        };
    }

    pub fn deinit(self: *IoUring) void {
        // Unmap memory regions
        std.posix.munmap(self.sq_ring_ptr);
        std.posix.munmap(self.cq_ring_ptr);
        std.posix.munmap(self.sqe_ptr);
        std.posix.close(self.fd);
    }

    // Arch Linux optimized submission with batching
    pub fn submitBatch(self: *IoUring, count: u32) !u32 {
        const head = @atomicLoad(u32, self.sq.head, .acquire);
        const tail = @atomicLoad(u32, self.sq.tail, .acquire);
        const mask = self.sq.mask.*;

        // Prepare batch submission
        var i: u32 = 0;
        while (i < count and (tail + i - head) < self.sq.entries.*) : (i += 1) {
            const idx = (tail + i) & mask;
            self.sq.array[idx] = idx;
        }

        // Memory barrier
        // Memory barrier - using builtin
        asm volatile ("" ::: .{ .memory = true });

        // Update tail
        @atomicStore(u32, self.sq.tail, tail + i, .release);

        // Submit to kernel with advanced flags
        const submitted = std.os.linux.io_uring_enter(
            self.fd,
            i,
            0,
            0, // Simplified flags for compatibility
            null,
        ) catch {
            std.debug.print("io_uring_enter failed\n", .{});
            return 0;
        };

        return submitted;
    }

    // Advanced SQE preparation with chaining support
    pub fn prepareSqe(self: *IoUring, op: linux.IORING_OP, fd: i32, addr: u64, len: u32, offset: u64, user_data: u64) !*linux.io_uring_sqe {
        const sqe = try self.getSqe();
        sqe.* = std.mem.zeroes(linux.io_uring_sqe);
        sqe.opcode = op;
        sqe.fd = fd;
        sqe.addr = addr;
        sqe.len = len;
        sqe.off = offset;
        sqe.user_data = user_data;
        sqe.flags = 0;
        return sqe;
    }

    // Vectored I/O support for Arch Linux optimization
    pub fn prepareReadv(self: *IoUring, fd: i32, iovec: []const std.posix.iovec, offset: u64, user_data: u64) !*linux.io_uring_sqe {
        const sqe = try self.prepareSqe(
            linux.IORING_OP.READV,
            fd,
            @intFromPtr(iovec.ptr),
            @intCast(iovec.len),
            offset,
            user_data,
        );
        return sqe;
    }

    pub fn prepareWritev(self: *IoUring, fd: i32, iovec: []const std.posix.iovec, offset: u64, user_data: u64) !*linux.io_uring_sqe {
        const sqe = try self.prepareSqe(
            linux.IORING_OP.WRITEV,
            fd,
            @intFromPtr(iovec.ptr),
            @intCast(iovec.len),
            offset,
            user_data,
        );
        return sqe;
    }

    pub fn getSqe(self: *IoUring) !*linux.io_uring_sqe {
        const head = @atomicLoad(u32, self.sq.head, .acquire);
        const tail = @atomicLoad(u32, self.sq.tail, .acquire);
        const mask = self.sq.mask.*;

        if (tail - head >= self.sq.entries.*) {
            return error.SubmissionQueueFull;
        }

        const idx = tail & mask;
        return &self.sqes[idx];
    }

    pub fn submit(self: *IoUring) !u32 {
        const head = @atomicLoad(u32, self.sq.head, .acquire);
        const tail = @atomicLoad(u32, self.sq.tail, .acquire);
        const mask = self.sq.mask.*;

        // Update submission queue array
        var i = head;
        while (i != tail) : (i += 1) {
            const idx = i & mask;
            self.sq.array[idx] = idx;
        }

        // Memory barrier
        // Memory barrier - using builtin
        asm volatile ("" ::: .{ .memory = true });

        // Update tail
        @atomicStore(u32, self.sq.tail, tail, .release);

        // Submit to kernel
        const submitted = std.os.linux.io_uring_enter(
            self.fd,
            tail - head,
            0,
            0, // Simplified flags
            null,
        ) catch 0;

        return submitted;
    }

    pub fn getCqe(self: *IoUring) ?*linux.io_uring_cqe {
        const head = @atomicLoad(u32, self.cq.head, .acquire);
        const tail = @atomicLoad(u32, self.cq.tail, .acquire);

        if (head == tail) {
            return null;
        }

        const mask = self.cq.mask.*;
        const idx = head & mask;

        return &self.cq.cqes[idx];
    }

    pub fn seenCqe(self: *IoUring, cqe: *linux.io_uring_cqe) void {
        _ = cqe;
        const head = @atomicLoad(u32, self.cq.head, .acquire);
        @atomicStore(u32, self.cq.head, head + 1, .release);
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

        return std.os.linux.io_uring_enter(
            self.fd,
            0,
            1,
            0, // Simplified flags
            ts,
        ) catch 0;
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
    asm volatile ("" ::: .{ .memory = true });
}

pub inline fn loadAcquire(comptime T: type, ptr: *const T) T {
    return @atomicLoad(T, ptr, .acquire);
}

pub inline fn storeRelease(comptime T: type, ptr: *T, value: T) void {
    @atomicStore(T, ptr, value, .release);
}

// Advanced Linux-specific optimizations for Arch Linux
pub const ArchLinuxOptimizations = struct {
    // NUMA topology detection and optimization
    pub fn detectNumaTopology() ![]u32 {
        // Read NUMA node information from /sys/devices/system/node/
        var nodes = std.ArrayList(u32).init(std.heap.page_allocator);

        var dir = std.fs.openDirAbsolute("/sys/devices/system/node/", .{ .iterate = true }) catch return nodes.toOwnedSlice();
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (std.mem.startsWith(u8, entry.name, "node") and entry.kind == .directory) {
                const node_id = std.fmt.parseInt(u32, entry.name[4..], 10) catch continue;
                try nodes.append(node_id);
            }
        }

        return nodes.toOwnedSlice();
    }

    // CPU governor optimization for async workloads
    pub fn optimizeCpuGovernor() !void {
        const governor_path = "/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor";
        const file = std.fs.openFileAbsolute(governor_path, .{ .mode = .write_only }) catch return;
        defer file.close();

        // Set to 'performance' for low-latency async I/O
        _ = file.writeAll("performance") catch {};
    }

    // IRQ affinity optimization for network interfaces
    pub fn optimizeIrqAffinity() !void {
        var proc_dir = std.fs.openDirAbsolute("/proc/irq/", .{ .iterate = true }) catch return;
        defer proc_dir.close();

        var iter = proc_dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .directory) {
                const irq_num = std.fmt.parseInt(u32, entry.name, 10) catch continue;
                _ = irq_num;

                // Set IRQ affinity to spread across CPUs
                // This is platform-specific and requires root privileges
                // Implementation would set /proc/irq/{irq}/smp_affinity
            }
        }
    }

    // Transparent huge pages optimization
    pub fn enableTransparentHugePages() !void {
        const thp_path = "/sys/kernel/mm/transparent_hugepage/enabled";
        const file = std.fs.openFileAbsolute(thp_path, .{ .mode = .write_only }) catch return;
        defer file.close();

        // Enable always for better memory performance
        _ = file.writeAll("always") catch {};
    }

    // Kernel scheduler tuning for async workloads
    pub fn tuneScheduler() !void {
        // Tune scheduler for low-latency async workloads
        const sched_params = [_]struct { path: []const u8, value: []const u8 }{
            .{ .path = "/proc/sys/kernel/sched_min_granularity_ns", .value = "1000000" }, // 1ms
            .{ .path = "/proc/sys/kernel/sched_wakeup_granularity_ns", .value = "2000000" }, // 2ms
            .{ .path = "/proc/sys/kernel/sched_migration_cost_ns", .value = "500000" }, // 0.5ms
        };

        for (sched_params) |param| {
            const file = std.fs.openFileAbsolute(param.path, .{ .mode = .write_only }) catch continue;
            defer file.close();
            _ = file.writeAll(param.value) catch {};
        }
    }

    // Network stack optimization
    pub fn optimizeNetworkStack() !void {
        const net_params = [_]struct { path: []const u8, value: []const u8 }{
            .{ .path = "/proc/sys/net/core/netdev_max_backlog", .value = "5000" },
            .{ .path = "/proc/sys/net/core/rmem_default", .value = "262144" },
            .{ .path = "/proc/sys/net/core/rmem_max", .value = "16777216" },
            .{ .path = "/proc/sys/net/core/wmem_default", .value = "262144" },
            .{ .path = "/proc/sys/net/core/wmem_max", .value = "16777216" },
            .{ .path = "/proc/sys/net/ipv4/tcp_rmem", .value = "4096 65536 16777216" },
            .{ .path = "/proc/sys/net/ipv4/tcp_wmem", .value = "4096 65536 16777216" },
            .{ .path = "/proc/sys/net/ipv4/tcp_congestion_control", .value = "bbr" },
        };

        for (net_params) |param| {
            const file = std.fs.openFileAbsolute(param.path, .{ .mode = .write_only }) catch continue;
            defer file.close();
            _ = file.writeAll(param.value) catch {};
        }
    }
};

// High-performance ring buffer for zero-copy operations
pub const ZeroCopyRingBuffer = struct {
    buffer: []align(4096) u8,
    read_pos: std.atomic.Value(u64),
    write_pos: std.atomic.Value(u64),
    capacity: u64,

    pub fn init(allocator: std.mem.Allocator, size: usize) !ZeroCopyRingBuffer {
        // Allocate page-aligned buffer for zero-copy operations
        const buffer = try allocator.alignedAlloc(u8, @enumFromInt(12), size); // 2^12 = 4096

        return ZeroCopyRingBuffer{
            .buffer = buffer,
            .read_pos = std.atomic.Value(u64).init(0),
            .write_pos = std.atomic.Value(u64).init(0),
            .capacity = size,
        };
    }

    pub fn deinit(self: *ZeroCopyRingBuffer, allocator: std.mem.Allocator) void {
        allocator.free(self.buffer);
    }

    pub fn writeSlice(self: *ZeroCopyRingBuffer, data: []const u8) !usize {
        const write_pos = self.write_pos.load(.acquire);
        const read_pos = self.read_pos.load(.acquire);
        const available = self.capacity - (write_pos - read_pos);

        if (data.len > available) {
            return error.BufferFull;
        }

        const write_idx = write_pos % self.capacity;
        const copy_len = @min(data.len, self.capacity - write_idx);

        @memcpy(self.buffer[write_idx .. write_idx + copy_len], data[0..copy_len]);

        if (copy_len < data.len) {
            // Wrap around
            @memcpy(self.buffer[0 .. data.len - copy_len], data[copy_len..]);
        }

        self.write_pos.store(write_pos + data.len, .release);
        return data.len;
    }

    pub fn readSlice(self: *ZeroCopyRingBuffer, buffer: []u8) !usize {
        const read_pos = self.read_pos.load(.acquire);
        const write_pos = self.write_pos.load(.acquire);
        const available = write_pos - read_pos;

        if (available == 0) {
            return 0;
        }

        const read_len = @min(buffer.len, available);
        const read_idx = read_pos % self.capacity;
        const copy_len = @min(read_len, self.capacity - read_idx);

        @memcpy(buffer[0..copy_len], self.buffer[read_idx .. read_idx + copy_len]);

        if (copy_len < read_len) {
            // Wrap around
            @memcpy(buffer[copy_len..read_len], self.buffer[0 .. read_len - copy_len]);
        }

        self.read_pos.store(read_pos + read_len, .release);
        return read_len;
    }
};

// Batch processor for high-throughput operations
pub const BatchProcessor = struct {
    const MAX_BATCH_SIZE = 64;

    operations: [MAX_BATCH_SIZE]BatchOp,
    count: u32,
    ring: *IoUring,

    const BatchOp = struct {
        op_type: OpType,
        fd: i32,
        buffer: []u8,
        offset: u64,
        user_data: u64,

        const OpType = enum { read, write, fsync, close };
    };

    pub fn init(ring: *IoUring) BatchProcessor {
        return BatchProcessor{
            .operations = undefined,
            .count = 0,
            .ring = ring,
        };
    }

    pub fn addRead(self: *BatchProcessor, fd: i32, buffer: []u8, offset: u64, user_data: u64) !void {
        if (self.count >= MAX_BATCH_SIZE) {
            try self.submit();
        }

        self.operations[self.count] = BatchOp{
            .op_type = .read,
            .fd = fd,
            .buffer = buffer,
            .offset = offset,
            .user_data = user_data,
        };
        self.count += 1;
    }

    pub fn addWrite(self: *BatchProcessor, fd: i32, buffer: []u8, offset: u64, user_data: u64) !void {
        if (self.count >= MAX_BATCH_SIZE) {
            try self.submit();
        }

        self.operations[self.count] = BatchOp{
            .op_type = .write,
            .fd = fd,
            .buffer = buffer,
            .offset = offset,
            .user_data = user_data,
        };
        self.count += 1;
    }

    pub fn submit(self: *BatchProcessor) !u32 {
        if (self.count == 0) return 0;

        // Prepare all SQEs in batch
        for (self.operations[0..self.count]) |op| {
            const sqe = switch (op.op_type) {
                .read => try self.ring.prepareSqe(
                    linux.IORING_OP.READ,
                    op.fd,
                    @intFromPtr(op.buffer.ptr),
                    @intCast(op.buffer.len),
                    op.offset,
                    op.user_data,
                ),
                .write => try self.ring.prepareSqe(
                    linux.IORING_OP.WRITE,
                    op.fd,
                    @intFromPtr(op.buffer.ptr),
                    @intCast(op.buffer.len),
                    op.offset,
                    op.user_data,
                ),
                .fsync => try self.ring.prepareSqe(
                    linux.IORING_OP.FSYNC,
                    op.fd,
                    0,
                    0,
                    0,
                    op.user_data,
                ),
                .close => try self.ring.prepareSqe(
                    linux.IORING_OP.CLOSE,
                    op.fd,
                    0,
                    0,
                    0,
                    op.user_data,
                ),
            };
            _ = sqe;
        }

        // Submit all operations in one system call
        const submitted = try self.ring.submitBatch(self.count);
        self.count = 0;
        return submitted;
    }
};
