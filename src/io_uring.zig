//! io_uring support for Zsync on Linux
//! High-performance async I/O using io_uring

const std = @import("std");
const linux = std.os.linux;
const builtin = @import("builtin");

/// io_uring errors
pub const IoUringError = error{
    NotSupported,
    SetupFailed,
    SubmissionFailed,
    CompletionFailed,
    QueueFull,
    InvalidOperation,
    OutOfMemory,
    PermissionDenied,
    Busy,
};

/// SQE (Submission Queue Entry) wrapper
pub const SubmissionEntry = struct {
    sqe: *linux.io_uring_sqe,
    user_data: u64,
    
    const Self = @This();

    /// Prepare a read operation
    pub fn prepRead(self: *Self, fd: i32, buffer: []u8, offset: u64) void {
        self.sqe.* = std.mem.zeroes(linux.io_uring_sqe);
        self.sqe.opcode = linux.IORING_OP.READ;
        self.sqe.fd = fd;
        self.sqe.off = offset;
        self.sqe.addr = @intFromPtr(buffer.ptr);
        self.sqe.len = @intCast(buffer.len);
        self.sqe.user_data = self.user_data;
    }

    /// Prepare a write operation
    pub fn prepWrite(self: *Self, fd: i32, buffer: []const u8, offset: u64) void {
        self.sqe.* = std.mem.zeroes(linux.io_uring_sqe);
        self.sqe.opcode = linux.IORING_OP.WRITE;
        self.sqe.fd = fd;
        self.sqe.off = offset;
        self.sqe.addr = @intFromPtr(buffer.ptr);
        self.sqe.len = @intCast(buffer.len);
        self.sqe.user_data = self.user_data;
    }

    /// Prepare an accept operation
    pub fn prepAccept(self: *Self, fd: i32, addr: *std.posix.sockaddr, addr_len: *u32) void {
        self.sqe.* = std.mem.zeroes(linux.io_uring_sqe);
        self.sqe.opcode = linux.IORING_OP.ACCEPT;
        self.sqe.fd = fd;
        self.sqe.addr = @intFromPtr(addr);
        self.sqe.addr2 = @intFromPtr(addr_len);
        self.sqe.user_data = self.user_data;
    }

    /// Prepare a timeout operation
    pub fn prepTimeout(self: *Self, timeout_ns: u64) void {
        self.sqe.* = std.mem.zeroes(linux.io_uring_sqe);
        self.sqe.opcode = linux.IORING_OP.TIMEOUT;
        self.sqe.addr = @intFromPtr(&timeout_ns);
        self.sqe.len = 1;
        self.sqe.user_data = self.user_data;
    }

    /// Prepare a poll operation
    pub fn prepPoll(self: *Self, fd: i32, events: u32) void {
        self.sqe.* = std.mem.zeroes(linux.io_uring_sqe);
        self.sqe.opcode = linux.IORING_OP.POLL_ADD;
        self.sqe.fd = fd;
        self.sqe.poll_events = @intCast(events);
        self.sqe.user_data = self.user_data;
    }
};

/// CQE (Completion Queue Entry) wrapper
pub const CompletionEntry = struct {
    cqe: *linux.io_uring_cqe,
    
    const Self = @This();

    pub fn getUserData(self: *const Self) u64 {
        return self.cqe.user_data;
    }

    pub fn getResult(self: *const Self) i32 {
        return self.cqe.res;
    }

    pub fn getFlags(self: *const Self) u32 {
        return self.cqe.flags;
    }

    pub fn isError(self: *const Self) bool {
        return self.cqe.res < 0;
    }

    pub fn getError(self: *const Self) std.posix.E {
        if (self.cqe.res >= 0) return .SUCCESS;
        return @enumFromInt(@as(u16, @intCast(-self.cqe.res)));
    }
};

/// io_uring ring configuration
pub const IoUringConfig = struct {
    entries: u32 = 128,
    sq_poll: bool = false,
    flags: u32 = 0,
    sq_thread_cpu: u32 = 0,
    sq_thread_idle: u32 = 0,
    features: u32 = 0,
};

/// Custom io_uring implementation for maximum compatibility
const IoUringParams = extern struct {
    sq_entries: u32 = 0,
    cq_entries: u32 = 0,
    flags: u32 = 0,
    sq_thread_cpu: u32 = 0,
    sq_thread_idle: u32 = 0,
    features: u32 = 0,
    wq_fd: u32 = 0,
    resv: [3]u32 = [_]u32{0} ** 3,
    sq_off: SqRingOffsets = .{},
    cq_off: CqRingOffsets = .{},
};

const SqRingOffsets = extern struct {
    head: u32 = 0,
    tail: u32 = 0,
    ring_mask: u32 = 0,
    ring_entries: u32 = 0,
    flags: u32 = 0,
    dropped: u32 = 0,
    array: u32 = 0,
    resv1: u32 = 0,
    user_addr: u64 = 0,
};

const CqRingOffsets = extern struct {
    head: u32 = 0,
    tail: u32 = 0,
    ring_mask: u32 = 0,
    ring_entries: u32 = 0,
    overflow: u32 = 0,
    cqes: u32 = 0,
    flags: u32 = 0,
    resv1: u32 = 0,
    user_addr: u64 = 0,
};

const IoUringSqe = extern struct {
    opcode: u8,
    flags: u8,
    ioprio: u16,
    fd: i32,
    off_addr2: extern union {
        off: u64,
        addr2: u64,
    },
    addr_splice_off_in: extern union {
        addr: u64,
        splice_off_in: u64,
    },
    len: u32,
    op_flags: extern union {
        rw_flags: u32,
        fsync_flags: u32,
        poll_events: u16,
        poll32_events: u32,
        sync_range_flags: u32,
        msg_flags: u32,
        timeout_flags: u32,
        accept_flags: u32,
        cancel_flags: u32,
        open_flags: u32,
        statx_flags: u32,
        fadvise_advice: u32,
        splice_flags: u32,
        rename_flags: u32,
        unlink_flags: u32,
        hardlink_flags: u32,
    },
    user_data: u64,
    buf_index_personality: extern union {
        buf_index: u16,
        personality: u16,
    },
    file_index: u16,
    addr3: u64,
    __pad2: [1]u64,
};

const IoUringCqe = extern struct {
    user_data: u64,
    res: i32,
    flags: u32,
};

/// io_uring ring wrapper  
pub const IoUring = struct {
    ring_fd: std.posix.fd_t,
    params: IoUringParams,
    sq: SubmissionQueue,
    cq: CompletionQueue,
    allocator: std.mem.Allocator,
    config: IoUringConfig,
    next_user_data: std.atomic.Value(u64),
    
    const Self = @This();
    
    const SubmissionQueue = struct {
        head: *u32,
        tail: *u32,
        ring_mask: *u32,
        ring_entries: *u32,
        flags: *u32,
        dropped: *u32,
        array: [*]u32,
        sqes: [*]IoUringSqe,
        mmap_ptr: []align(4096) u8,
        sqe_mmap_ptr: []align(4096) u8,
    };
    
    const CompletionQueue = struct {
        head: *u32,
        tail: *u32,
        ring_mask: *u32,
        ring_entries: *u32,
        overflow: *u32,
        cqes: [*]IoUringCqe,
        mmap_ptr: ?[]align(4096) u8,
    };
    
    // io_uring syscall constants
    const IORING_SETUP_IOPOLL: u32 = 1 << 0;
    const IORING_SETUP_SQPOLL: u32 = 1 << 1;
    const IORING_SETUP_SQ_AFF: u32 = 1 << 2;
    const IORING_SETUP_CQSIZE: u32 = 1 << 3;
    
    const IORING_OFF_SQ_RING: u64 = 0;
    const IORING_OFF_CQ_RING: u64 = 0x8000000;
    const IORING_OFF_SQES: u64 = 0x10000000;
    
    // io_uring opcodes
    const IORING_OP_NOP: u8 = 0;
    const IORING_OP_READV: u8 = 1;
    const IORING_OP_WRITEV: u8 = 2;
    const IORING_OP_FSYNC: u8 = 3;
    const IORING_OP_READ_FIXED: u8 = 4;
    const IORING_OP_WRITE_FIXED: u8 = 5;
    const IORING_OP_POLL_ADD: u8 = 6;
    const IORING_OP_POLL_REMOVE: u8 = 7;
    const IORING_OP_SYNC_FILE_RANGE: u8 = 8;
    const IORING_OP_SENDMSG: u8 = 9;
    const IORING_OP_RECVMSG: u8 = 10;
    const IORING_OP_TIMEOUT: u8 = 11;
    const IORING_OP_TIMEOUT_REMOVE: u8 = 12;
    const IORING_OP_ACCEPT: u8 = 13;
    const IORING_OP_ASYNC_CANCEL: u8 = 14;
    const IORING_OP_LINK_TIMEOUT: u8 = 15;
    const IORING_OP_CONNECT: u8 = 16;
    const IORING_OP_FALLOCATE: u8 = 17;
    const IORING_OP_OPENAT: u8 = 18;
    const IORING_OP_CLOSE: u8 = 19;
    const IORING_OP_FILES_UPDATE: u8 = 20;
    const IORING_OP_STATX: u8 = 21;
    const IORING_OP_READ: u8 = 22;
    const IORING_OP_WRITE: u8 = 23;
    const IORING_OP_FADVISE: u8 = 24;
    const IORING_OP_MADVISE: u8 = 25;
    const IORING_OP_SEND: u8 = 26;
    const IORING_OP_RECV: u8 = 27;
    const IORING_OP_OPENAT2: u8 = 28;
    const IORING_OP_EPOLL_CTL: u8 = 29;
    const IORING_OP_SPLICE: u8 = 30;
    const IORING_OP_PROVIDE_BUFFERS: u8 = 31;
    const IORING_OP_REMOVE_BUFFERS: u8 = 32;
    
    // Raw syscall wrappers - architecture-aware
    fn io_uring_setup(entries: u32, params: *IoUringParams) i32 {
        // Use the correct syscall enum for the target architecture
        switch (builtin.cpu.arch) {
            .x86_64 => {
                const SYS_io_uring_setup = @as(std.os.linux.syscalls.X64, @enumFromInt(425)); // x86_64 syscall number
                return @intCast(std.os.linux.syscall2(SYS_io_uring_setup, entries, @intFromPtr(params)));
            },
            .aarch64 => {
                const SYS_io_uring_setup = @as(std.os.linux.syscalls.Arm64, @enumFromInt(425)); // ARM64 syscall number
                return @intCast(std.os.linux.syscall2(SYS_io_uring_setup, entries, @intFromPtr(params)));
            },
            else => @compileError("io_uring not supported on this architecture"),
        }
    }
    
    fn io_uring_enter(fd: i32, to_submit: u32, min_complete: u32, flags: u32, sig: ?*anyopaque) i32 {
        const sig_ptr = if (sig) |s| @intFromPtr(s) else 0;
        
        switch (builtin.cpu.arch) {
            .x86_64 => {
                const SYS_io_uring_enter = @as(std.os.linux.syscalls.X64, @enumFromInt(426)); // x86_64 syscall number
                return @intCast(std.os.linux.syscall5(SYS_io_uring_enter, @as(usize, @bitCast(@as(isize, fd))), to_submit, min_complete, flags, sig_ptr));
            },
            .aarch64 => {
                const SYS_io_uring_enter = @as(std.os.linux.syscalls.Arm64, @enumFromInt(426)); // ARM64 syscall number
                return @intCast(std.os.linux.syscall5(SYS_io_uring_enter, @as(usize, @bitCast(@as(isize, fd))), to_submit, min_complete, flags, sig_ptr));
            },
            else => @compileError("io_uring not supported on this architecture"),
        }
    }

    /// Initialize io_uring with full implementation
    pub fn init(allocator: std.mem.Allocator, config: IoUringConfig) !Self {
        if (builtin.os.tag != .linux) {
            return IoUringError.NotSupported;
        }
        
        // Initialize io_uring parameters
        var params = IoUringParams{
            .sq_entries = 0, // Will be set by kernel
            .cq_entries = 0, // Will be set by kernel
            .flags = if (config.sq_poll) IORING_SETUP_SQPOLL else 0,
        };
        
        // Call io_uring_setup syscall
        const ring_fd = io_uring_setup(config.entries, &params);
        if (ring_fd < 0) {
            // Error handling for syscall failures
            const errno_val = @as(u32, @intCast(-ring_fd));
            return switch (errno_val) {
                38 => IoUringError.NotSupported, // ENOSYS
                12 => IoUringError.OutOfMemory,  // ENOMEM  
                1 => IoUringError.PermissionDenied, // EPERM
                else => IoUringError.SetupFailed,
            };
        }
        
        // Calculate memory map sizes
        const sq_size = params.sq_off.array + params.sq_entries * @sizeOf(u32);
        const cq_size = params.cq_off.cqes + params.cq_entries * @sizeOf(IoUringCqe);
        const sqe_size = params.sq_entries * @sizeOf(IoUringSqe);
        
        // Map submission queue
        const sq_mmap = std.posix.mmap(
            null,
            sq_size,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            ring_fd,
            IORING_OFF_SQ_RING,
        ) catch {
            std.posix.close(ring_fd);
            return IoUringError.SetupFailed;
        };
        
        // Map completion queue (may be shared with SQ)
        const cq_mmap = if (params.features & 0x1 != 0) // IORING_FEAT_SINGLE_MMAP
            null
        else
            std.posix.mmap(
                null,
                cq_size,
                .{ .READ = true, .WRITE = true },
                .{ .TYPE = .SHARED },
                ring_fd,
                IORING_OFF_CQ_RING,
            ) catch {
                std.posix.munmap(sq_mmap);
                std.posix.close(ring_fd);
                return IoUringError.SetupFailed;
            };
        
        // Map submission queue entries
        const sqe_mmap = std.posix.mmap(
            null,
            sqe_size,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            ring_fd,
            IORING_OFF_SQES,
        ) catch {
            if (cq_mmap) |cq| std.posix.munmap(cq);
            std.posix.munmap(sq_mmap);
            std.posix.close(ring_fd);
            return IoUringError.SetupFailed;
        };
        
        // Initialize submission queue pointers
        const sq = SubmissionQueue{
            .head = @ptrFromInt(@intFromPtr(sq_mmap.ptr) + params.sq_off.head),
            .tail = @ptrFromInt(@intFromPtr(sq_mmap.ptr) + params.sq_off.tail),
            .ring_mask = @ptrFromInt(@intFromPtr(sq_mmap.ptr) + params.sq_off.ring_mask),
            .ring_entries = @ptrFromInt(@intFromPtr(sq_mmap.ptr) + params.sq_off.ring_entries),
            .flags = @ptrFromInt(@intFromPtr(sq_mmap.ptr) + params.sq_off.flags),
            .dropped = @ptrFromInt(@intFromPtr(sq_mmap.ptr) + params.sq_off.dropped),
            .array = @ptrFromInt(@intFromPtr(sq_mmap.ptr) + params.sq_off.array),
            .sqes = @ptrCast(sqe_mmap.ptr),
            .mmap_ptr = sq_mmap,
            .sqe_mmap_ptr = sqe_mmap,
        };
        
        // Initialize completion queue pointers
        const cq_ptr = cq_mmap orelse sq_mmap;
        const cq = CompletionQueue{
            .head = @ptrFromInt(@intFromPtr(cq_ptr.ptr) + params.cq_off.head),
            .tail = @ptrFromInt(@intFromPtr(cq_ptr.ptr) + params.cq_off.tail),
            .ring_mask = @ptrFromInt(@intFromPtr(cq_ptr.ptr) + params.cq_off.ring_mask),
            .ring_entries = @ptrFromInt(@intFromPtr(cq_ptr.ptr) + params.cq_off.ring_entries),
            .overflow = @ptrFromInt(@intFromPtr(cq_ptr.ptr) + params.cq_off.overflow),
            .cqes = @ptrFromInt(@intFromPtr(cq_ptr.ptr) + params.cq_off.cqes),
            .mmap_ptr = cq_mmap,
        };
        
        return Self{
            .ring_fd = ring_fd,
            .params = params,
            .sq = sq,
            .cq = cq,
            .allocator = allocator,
            .config = config,
            .next_user_data = std.atomic.Value(u64).init(1),
        };
    }

    /// Deinitialize io_uring
    pub fn deinit(self: *Self) void {
        // Clean up memory mappings
        std.posix.munmap(self.sq.sqe_mmap_ptr);
        std.posix.munmap(self.sq.mmap_ptr);
        if (self.cq.mmap_ptr) |cq_mmap| {
            std.posix.munmap(cq_mmap);
        }
        
        // Close the ring file descriptor
        std.posix.close(self.ring_fd);
    }

    /// Get a submission queue entry
    pub fn getSqe(self: *Self) ?*IoUringSqe {
        const tail = self.sq.tail.*;
        const head = @atomicLoad(u32, self.sq.head, .acquire);
        const mask = self.sq.ring_mask.*;
        
        // Check if submission queue is full
        if (tail - head >= self.sq.ring_entries.*) {
            return null;
        }
        
        const idx = tail & mask;
        return &self.sq.sqes[idx];
    }
    
    /// Submit a single SQE
    pub fn submitSqe(self: *Self, _: *IoUringSqe) void {
        const tail = self.sq.tail.*;
        const mask = self.sq.ring_mask.*;
        const idx = tail & mask;
        
        // Set the array entry to point to this SQE
        self.sq.array[idx] = @intCast(idx);
        
        // Advance the tail
        @atomicStore(u32, self.sq.tail, tail + 1, .release);
    }
    
    /// Submit all pending SQEs and optionally wait for completions
    pub fn submit(self: *Self) !u32 {
        const tail = self.sq.tail.*;
        const head = @atomicLoad(u32, self.sq.head, .acquire);
        const to_submit = tail - head;
        
        if (to_submit == 0) {
            return 0;
        }
        
        const ret = io_uring_enter(self.ring_fd, to_submit, 0, 0, null);
        if (ret < 0) {
            const errno_val = @as(u32, @intCast(-ret));
            return switch (errno_val) {
                16 => IoUringError.Busy,     // EBUSY
                22 => IoUringError.SetupFailed, // EINVAL -> SetupFailed (more appropriate) 
                else => IoUringError.SubmissionFailed,
            };
        }
        
        return @intCast(ret);
    }
    
    /// Wait for and retrieve completion events
    pub fn getCompletions(self: *Self, cqes: []IoUringCqe) u32 {
        var count: u32 = 0;
        const head = self.cq.head.*;
        const tail = @atomicLoad(u32, self.cq.tail, .acquire);
        const mask = self.cq.ring_mask.*;
        
        var current_head = head;
        while (current_head != tail and count < cqes.len) {
            const idx = current_head & mask;
            cqes[count] = self.cq.cqes[idx];
            current_head += 1;
            count += 1;
        }
        
        if (count > 0) {
            @atomicStore(u32, self.cq.head, current_head, .release);
        }
        
        return count;
    }
    
    /// Setup a read operation
    pub fn prepRead(sqe: *IoUringSqe, fd: i32, buffer: []u8, offset: u64, user_data: u64) void {
        sqe.* = IoUringSqe{
            .opcode = IORING_OP_READ,
            .flags = 0,
            .ioprio = 0,
            .fd = fd,
            .off_addr2 = .{ .off = offset },
            .addr_splice_off_in = .{ .addr = @intFromPtr(buffer.ptr) },
            .len = @intCast(buffer.len),
            .op_flags = .{ .rw_flags = 0 },
            .user_data = user_data,
            .buf_index_personality = .{ .buf_index = 0 },
            .file_index = 0,
            .addr3 = 0,
            .__pad2 = [_]u64{0},
        };
    }
    
    /// Setup a write operation
    pub fn prepWrite(sqe: *IoUringSqe, fd: i32, data: []const u8, offset: u64, user_data: u64) void {
        sqe.* = IoUringSqe{
            .opcode = IORING_OP_WRITE,
            .flags = 0,
            .ioprio = 0,
            .fd = fd,
            .off_addr2 = .{ .off = offset },
            .addr_splice_off_in = .{ .addr = @intFromPtr(data.ptr) },
            .len = @intCast(data.len),
            .op_flags = .{ .rw_flags = 0 },
            .user_data = user_data,
            .buf_index_personality = .{ .buf_index = 0 },
            .file_index = 0,
            .addr3 = 0,
            .__pad2 = [_]u64{0},
        };
    }
    
    /// Setup an accept operation
    pub fn prepAccept(sqe: *IoUringSqe, fd: i32, addr: ?*std.posix.sockaddr, user_data: u64) void {
        sqe.* = IoUringSqe{
            .opcode = IORING_OP_ACCEPT,
            .flags = 0,
            .ioprio = 0,
            .fd = fd,
            .off_addr2 = .{ .off = 0 },
            .addr_splice_off_in = .{ .addr = if (addr) |a| @intFromPtr(a) else 0 },
            .len = if (addr != null) @sizeOf(std.posix.sockaddr) else 0,
            .op_flags = .{ .accept_flags = 0 },
            .user_data = user_data,
            .buf_index_personality = .{ .buf_index = 0 },
            .file_index = 0,
            .addr3 = 0,
            .__pad2 = [_]u64{0},
        };
    }
    
    /// Setup a connect operation
    pub fn prepConnect(sqe: *IoUringSqe, fd: i32, addr: *const std.posix.sockaddr, user_data: u64) void {
        sqe.* = IoUringSqe{
            .opcode = IORING_OP_CONNECT,
            .flags = 0,
            .ioprio = 0,
            .fd = fd,
            .off_addr2 = .{ .off = 0 },
            .addr_splice_off_in = .{ .addr = @intFromPtr(addr) },
            .len = @sizeOf(std.posix.sockaddr),
            .op_flags = .{ .rw_flags = 0 },
            .user_data = user_data,
            .buf_index_personality = .{ .buf_index = 0 },
            .file_index = 0,
            .addr3 = 0,
            .__pad2 = [_]u64{0},
        };
    }
    
    /// Setup a close operation
    pub fn prepClose(sqe: *IoUringSqe, fd: i32, user_data: u64) void {
        sqe.* = IoUringSqe{
            .opcode = IORING_OP_CLOSE,
            .flags = 0,
            .ioprio = 0,
            .fd = fd,
            .off_addr2 = .{ .off = 0 },
            .addr_splice_off_in = .{ .addr = 0 },
            .len = 0,
            .op_flags = .{ .rw_flags = 0 },
            .user_data = user_data,
            .buf_index_personality = .{ .buf_index = 0 },
            .file_index = 0,
            .addr3 = 0,
            .__pad2 = [_]u64{0},
        };
    }
};

/// Operation types for io_uring
pub const Operation = struct {
    opcode: enum { read, write, readv, writev, accept, connect, close, sendfile, copy_file_range },
    fd: i32,
    buffer: []u8 = &[_]u8{},
    data: []const u8 = &[_]u8{},
    offset: u64 = 0,
    addr: ?*std.posix.sockaddr = null,  // Mutable pointer for accept
};

/// Future-like structure for async operations
pub const Future = struct {
    user_data: u64,
    reactor: *IoUringReactor,
    
    const FutureSelf = @This();
    
    pub fn await(self: FutureSelf) !i32 {
        // Polling until completion
        while (true) {
            if (self.reactor.pending_ops.get(self.user_data)) |pending_op| {
                if (pending_op.completed.load(.acquire)) {
                    const result = pending_op.result;
                    // Clean up
                    _ = self.reactor.pending_ops.remove(self.user_data);
                    self.reactor.allocator.destroy(pending_op);
                    return result;
                }
            }
            
            // Poll for more completions
            _ = self.reactor.poll(1) catch 0;
            std.time.sleep(1000000); // 1ms
        }
    }
    
    pub fn destroy(self: FutureSelf, _: std.mem.Allocator) void {
        // Cleanup if operation is still pending
        if (self.reactor.pending_ops.get(self.user_data)) |pending_op| {
            _ = self.reactor.pending_ops.remove(self.user_data);
            self.reactor.allocator.destroy(pending_op);
        }
    }
};

/// High-level io_uring reactor for async operations
pub const IoUringReactor = struct {
    ring: IoUring,
    allocator: std.mem.Allocator,
    pending_ops: std.AutoHashMap(u64, *PendingOperation),
    
    const Self = @This();
    
    const PendingOperation = struct {
        result: i32 = 0,
        completed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        waker: ?*anyopaque = null,
    };
    
    pub fn init(allocator: std.mem.Allocator, config: IoUringConfig) !Self {
        const ring = try IoUring.init(allocator, config);
        
        return Self{
            .ring = ring,
            .allocator = allocator,
            .pending_ops = std.AutoHashMap(u64, *PendingOperation).init(allocator),
        };
    }
    
    pub fn deinit(self: *Self) void {
        // Clean up any remaining pending operations
        var iterator = self.pending_ops.iterator();
        while (iterator.next()) |entry| {
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.pending_ops.deinit();
        
        self.ring.deinit();
    }
    
    /// Submit an operation and return a Future-like structure
    pub fn submitOperation(self: *Self, operation: Operation) !Future {
        const sqe = self.ring.getSqe() orelse return IoUringError.QueueFull;
        const user_data = self.ring.next_user_data.fetchAdd(1, .monotonic);
        
        // Create pending operation tracking
        const pending_op = try self.allocator.create(PendingOperation);
        pending_op.* = PendingOperation{};
        
        try self.pending_ops.put(user_data, pending_op);
        
        // Setup the SQE based on operation type
        switch (operation.opcode) {
            .read => IoUring.prepRead(sqe, operation.fd, operation.buffer, operation.offset, user_data),
            .write => IoUring.prepWrite(sqe, operation.fd, @constCast(operation.data), operation.offset, user_data),
            .accept => IoUring.prepAccept(sqe, operation.fd, operation.addr, user_data),
            .connect => IoUring.prepConnect(sqe, operation.fd, operation.addr.?, user_data),
            .close => IoUring.prepClose(sqe, operation.fd, user_data),
            else => return IoUringError.NotSupported,
        }
        
        self.ring.submitSqe(sqe);
        _ = try self.ring.submit();
        
        return Future{
            .user_data = user_data,
            .reactor = self,
        };
    }
    
    /// Poll for completions and process them
    pub fn poll(self: *Self, timeout_ms: u32) !u32 {
        _ = timeout_ms; // TODO: Implement timeout
        
        var cqes: [32]IoUringCqe = undefined;
        const count = self.ring.getCompletions(&cqes);
        
        for (cqes[0..count]) |cqe| {
            if (self.pending_ops.get(cqe.user_data)) |pending_op| {
                pending_op.result = cqe.res;
                pending_op.completed.store(true, .release);
                
                // Wake up any waiting futures
                if (pending_op.waker) |waker| {
                    // Wake the future - implementation depends on waker type
                    _ = waker;
                }
            }
        }
        
        return count;
    }
};

// Tests (Linux only)
test "io_uring availability" {
    if (builtin.os.tag != .linux) return;
    
    const testing = std.testing;
    const allocator = testing.allocator;
    
    const config = IoUringConfig{ .entries = 32 };
    var ring = IoUring.init(allocator, config) catch |err| switch (err) {
        IoUringError.NotSupported => return, // Skip test if not supported
        else => return err,
    };
    defer ring.deinit();
}

test "io_uring reactor creation" {
    if (builtin.os.tag != .linux) return;
    
    const testing = std.testing;
    const allocator = testing.allocator;
    
    const config = IoUringConfig{ .entries = 32 };
    var reactor = IoUringReactor.init(allocator, config) catch |err| switch (err) {
        IoUringError.NotSupported => return, // Skip test if not supported
        else => return err,
    };
    defer reactor.deinit();
}
