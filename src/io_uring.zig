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
    pub fn prepAccept(self: *Self, fd: i32, addr: *std.net.Address, addr_len: *u32) void {
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
    flags: u32 = 0,
    sq_thread_cpu: u32 = 0,
    sq_thread_idle: u32 = 0,
    features: u32 = 0,
};

/// io_uring ring wrapper
pub const IoUring = struct {
    ring: linux.io_uring,
    allocator: std.mem.Allocator,
    config: IoUringConfig,
    next_user_data: std.atomic.Value(u64),

    const Self = @This();

    /// Initialize io_uring
    pub fn init(allocator: std.mem.Allocator, config: IoUringConfig) !Self {
        if (builtin.os.tag != .linux) {
            return IoUringError.NotSupported;
        }

        var ring: linux.io_uring = undefined;
        const setup_result = linux.io_uring_setup(config.entries, &ring.params);
        
        if (linux.getErrno(setup_result) != .SUCCESS) {
            return IoUringError.SetupFailed;
        }

        ring.ring_fd = @intCast(setup_result);

        // Map the submission and completion queues
        const sq_size = ring.params.sq_off.array + ring.params.sq_entries * @sizeOf(u32);
        const cq_size = ring.params.cq_off.cqes + ring.params.cq_entries * @sizeOf(linux.io_uring_cqe);

        const sq_ptr = std.posix.mmap(
            null,
            sq_size,
            std.posix.PROT.READ | std.posix.PROT.WRITE,
            .{ .TYPE = .SHARED },
            ring.ring_fd,
            linux.IORING_OFF_SQ_RING,
        ) catch return IoUringError.SetupFailed;

        const cq_ptr = if (ring.params.features & linux.IORING_FEAT_SINGLE_MMAP != 0)
            sq_ptr
        else
            std.posix.mmap(
                null,
                cq_size,
                std.posix.PROT.READ | std.posix.PROT.WRITE,
                .{ .TYPE = .SHARED },
                ring.ring_fd,
                linux.IORING_OFF_CQ_RING,
            ) catch return IoUringError.SetupFailed;

        // Map the submission queue entries
        const sqe_size = ring.params.sq_entries * @sizeOf(linux.io_uring_sqe);
        const sqe_ptr = std.posix.mmap(
            null,
            sqe_size,
            std.posix.PROT.READ | std.posix.PROT.WRITE,
            .{ .TYPE = .SHARED },
            ring.ring_fd,
            linux.IORING_OFF_SQES,
        ) catch return IoUringError.SetupFailed;

        // Initialize pointers
        ring.sq.head = @as(*u32, @ptrFromInt(@intFromPtr(sq_ptr) + ring.params.sq_off.head));
        ring.sq.tail = @as(*u32, @ptrFromInt(@intFromPtr(sq_ptr) + ring.params.sq_off.tail));
        ring.sq.ring_mask = @as(*u32, @ptrFromInt(@intFromPtr(sq_ptr) + ring.params.sq_off.ring_mask));
        ring.sq.ring_entries = @as(*u32, @ptrFromInt(@intFromPtr(sq_ptr) + ring.params.sq_off.ring_entries));
        ring.sq.flags = @as(*u32, @ptrFromInt(@intFromPtr(sq_ptr) + ring.params.sq_off.flags));
        ring.sq.dropped = @as(*u32, @ptrFromInt(@intFromPtr(sq_ptr) + ring.params.sq_off.dropped));
        ring.sq.array = @as(*u32, @ptrFromInt(@intFromPtr(sq_ptr) + ring.params.sq_off.array));
        ring.sq.sqes = @as(*linux.io_uring_sqe, @ptrFromInt(@intFromPtr(sqe_ptr)));

        ring.cq.head = @as(*u32, @ptrFromInt(@intFromPtr(cq_ptr) + ring.params.cq_off.head));
        ring.cq.tail = @as(*u32, @ptrFromInt(@intFromPtr(cq_ptr) + ring.params.cq_off.tail));
        ring.cq.ring_mask = @as(*u32, @ptrFromInt(@intFromPtr(cq_ptr) + ring.params.cq_off.ring_mask));
        ring.cq.ring_entries = @as(*u32, @ptrFromInt(@intFromPtr(cq_ptr) + ring.params.cq_off.ring_entries));
        ring.cq.overflow = @as(*u32, @ptrFromInt(@intFromPtr(cq_ptr) + ring.params.cq_off.overflow));
        ring.cq.cqes = @as(*linux.io_uring_cqe, @ptrFromInt(@intFromPtr(cq_ptr) + ring.params.cq_off.cqes));

        return Self{
            .ring = ring,
            .allocator = allocator,
            .config = config,
            .next_user_data = std.atomic.Value(u64).init(1),
        };
    }

    /// Deinitialize io_uring
    pub fn deinit(self: *Self) void {
        std.posix.close(self.ring.ring_fd);
    }

    /// Get a submission queue entry
    pub fn getSqe(self: *Self) ?SubmissionEntry {
        const tail = self.ring.sq.tail.*;
        const head = @atomicLoad(u32, self.ring.sq.head, .acquire);
        const mask = self.ring.sq.ring_mask.*;

        if (tail - head >= self.ring.sq.ring_entries.*) {
            return null; // Queue full
        }

        const index = tail & mask;
        const sqe = &self.ring.sq.sqes[index];
        const user_data = self.next_user_data.fetchAdd(1, .monotonic);

        return SubmissionEntry{
            .sqe = sqe,
            .user_data = user_data,
        };
    }

    /// Submit all pending operations
    pub fn submit(self: *Self) !u32 {
        const result = linux.io_uring_enter(
            self.ring.ring_fd,
            0, // to_submit (auto-calculated)
            0, // min_complete
            0, // flags
            null, // sig
        );

        if (linux.getErrno(result) != .SUCCESS) {
            return IoUringError.SubmissionFailed;
        }

        return @intCast(result);
    }

    /// Submit and wait for completions
    pub fn submitAndWait(self: *Self, wait_nr: u32) !u32 {
        const result = linux.io_uring_enter(
            self.ring.ring_fd,
            0, // to_submit
            wait_nr,
            linux.IORING_ENTER_GETEVENTS,
            null, // sig
        );

        if (linux.getErrno(result) != .SUCCESS) {
            return IoUringError.SubmissionFailed;
        }

        return @intCast(result);
    }

    /// Peek at completion queue
    pub fn peekCqe(self: *Self) ?CompletionEntry {
        const head = @atomicLoad(u32, self.ring.cq.head, .acquire);
        const tail = self.ring.cq.tail.*;

        if (head == tail) {
            return null; // No completions
        }

        const mask = self.ring.cq.ring_mask.*;
        const index = head & mask;
        const cqe = &self.ring.cq.cqes[index];

        return CompletionEntry{ .cqe = cqe };
    }

    /// Advance completion queue head
    pub fn cqAdvance(self: *Self, count: u32) void {
        @atomicStore(u32, self.ring.cq.head, self.ring.cq.head.* + count, .release);
    }

    /// Wait for and return a completion
    pub fn waitCqe(self: *Self) !CompletionEntry {
        // Check if completion is already available
        if (self.peekCqe()) |cqe| {
            return cqe;
        }

        // Submit and wait for at least one completion
        _ = try self.submitAndWait(1);

        // Should have at least one completion now
        return self.peekCqe() orelse IoUringError.CompletionFailed;
    }

    /// Process all available completions
    pub fn processCompletions(self: *Self, handler: anytype) !u32 {
        var processed: u32 = 0;
        
        while (self.peekCqe()) |cqe| {
            handler(cqe) catch {};
            self.cqAdvance(1);
            processed += 1;
        }

        return processed;
    }
};

/// Async I/O operation future
pub const AsyncIoOp = struct {
    user_data: u64,
    completed: bool = false,
    result: i32 = 0,
    error_code: std.posix.E = .SUCCESS,

    const Self = @This();

    pub fn init(user_data: u64) Self {
        return Self{ .user_data = user_data };
    }

    pub fn isReady(self: *const Self) bool {
        return self.completed;
    }

    pub fn getResult(self: *const Self) !i32 {
        if (!self.completed) return error.NotReady;
        if (self.error_code != .SUCCESS) return std.posix.unexpectedErrno(self.error_code);
        return self.result;
    }

    pub fn complete(self: *Self, result: i32, error_code: std.posix.E) void {
        self.result = result;
        self.error_code = error_code;
        self.completed = true;
    }
};

/// io_uring-based reactor for high-performance I/O
pub const IoUringReactor = struct {
    ring: IoUring,
    pending_ops: std.HashMap(u64, *AsyncIoOp, std.hash_map.AutoContext(u64), std.hash_map.default_max_load_percentage),
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: IoUringConfig) !Self {
        return Self{
            .ring = try IoUring.init(allocator, config),
            .pending_ops = std.HashMap(u64, *AsyncIoOp, std.hash_map.AutoContext(u64), std.hash_map.default_max_load_percentage).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.ring.deinit();
        self.pending_ops.deinit();
    }

    /// Async read operation
    pub fn readAsync(self: *Self, fd: i32, buffer: []u8, offset: u64) !*AsyncIoOp {
        const sqe = self.ring.getSqe() orelse return IoUringError.QueueFull;
        
        const op = try self.allocator.create(AsyncIoOp);
        op.* = AsyncIoOp.init(sqe.user_data);
        
        sqe.prepRead(fd, buffer, offset);
        try self.pending_ops.put(sqe.user_data, op);
        
        return op;
    }

    /// Async write operation
    pub fn writeAsync(self: *Self, fd: i32, buffer: []const u8, offset: u64) !*AsyncIoOp {
        const sqe = self.ring.getSqe() orelse return IoUringError.QueueFull;
        
        const op = try self.allocator.create(AsyncIoOp);
        op.* = AsyncIoOp.init(sqe.user_data);
        
        sqe.prepWrite(fd, buffer, offset);
        try self.pending_ops.put(sqe.user_data, op);
        
        return op;
    }

    /// Process I/O events
    pub fn poll(self: *Self, timeout_ms: u32) !u32 {
        _ = timeout_ms;
        
        // Submit pending operations
        _ = try self.ring.submit();
        
        // Process completions
        const CompletionHandler = struct {
            reactor: *Self,
            
            fn handleCompletion(handler: @This(), cqe: CompletionEntry) void {
                const user_data = cqe.getUserData();
                if (handler.reactor.pending_ops.get(user_data)) |op| {
                    const result = cqe.getResult();
                    const error_code = if (cqe.isError()) cqe.getError() else .SUCCESS;
                    op.complete(result, error_code);
                    
                    _ = handler.reactor.pending_ops.remove(user_data);
                    handler.reactor.allocator.destroy(op);
                }
            }
        };
        
        const handler = CompletionHandler{ .reactor = self };
        return self.ring.processCompletions(handler.handleCompletion);
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