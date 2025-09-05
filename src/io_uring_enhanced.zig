//! Zsync v0.5.3 - Enhanced Linux io_uring Implementation
//! Advanced features: SQPOLL, buffer rings, FAST_POLL, operation linking, registered files/buffers

const std = @import("std");
const linux = std.os.linux;
const builtin = @import("builtin");

/// Enhanced io_uring configuration with advanced features
pub const EnhancedIoUringConfig = struct {
    // Basic configuration
    entries: u32 = 128,
    flags: u32 = 0,
    
    // SQPOLL configuration
    sq_poll: bool = false,
    sq_thread_cpu: u32 = 0,
    sq_thread_idle: u32 = 1000, // 1 second idle time
    
    // Advanced features
    enable_fast_poll: bool = true,
    enable_buffer_rings: bool = true,
    enable_registered_files: bool = true,
    enable_fixed_buffers: bool = true,
    
    // Performance tuning
    cq_entries_multiplier: u32 = 2, // CQ size = SQ size * multiplier
    buffer_ring_size: u32 = 1024,   // Number of buffers in ring
    buffer_size: u32 = 8192,        // Size of each buffer
    max_registered_files: u32 = 256, // Max file descriptors to register
    max_fixed_buffers: u32 = 128,   // Max buffers to register
};

/// Advanced io_uring setup flags (latest kernel features)
pub const IoUringSetupFlags = struct {
    pub const IOPOLL: u32 = 1 << 0;     // Use kernel polling for I/O
    pub const SQPOLL: u32 = 1 << 1;     // Use kernel thread for SQ polling
    pub const SQ_AFF: u32 = 1 << 2;     // Set SQ thread CPU affinity
    pub const CQSIZE: u32 = 1 << 3;     // Custom CQ size
    pub const CLAMP: u32 = 1 << 4;      // Clamp SQ/CQ sizes to power of 2
    pub const ATTACH_WQ: u32 = 1 << 5;  // Attach to existing work queue
    pub const R_DISABLED: u32 = 1 << 6; // Start disabled, enable with IORING_REGISTER_ENABLE_RINGS
    pub const SUBMIT_ALL: u32 = 1 << 7; // Submit all entries, even if CQ is full
    pub const COOP_TASKRUN: u32 = 1 << 8;  // Cooperative task running
    pub const TASKRUN_FLAG: u32 = 1 << 9;  // Task run flag
    pub const SQE128: u32 = 1 << 10;    // Use 128-byte SQEs
    pub const CQE32: u32 = 1 << 11;     // Use 32-byte CQEs
    pub const SINGLE_MMAP: u32 = 1 << 12; // Use single mmap for rings
    pub const DEFER_TASKRUN: u32 = 1 << 13; // Defer task runs
};

/// Advanced SQE flags for operation control
pub const IoSqeFlags = struct {
    pub const FIXED_FILE: u8 = 1 << 0;    // Use registered file descriptor
    pub const IO_DRAIN: u8 = 1 << 1;      // Drain previous operations
    pub const IO_LINK: u8 = 1 << 2;       // Link with next operation
    pub const IO_HARDLINK: u8 = 1 << 3;   // Hard link (don't break on error)
    pub const ASYNC: u8 = 1 << 4;         // Force async execution
    pub const BUFFER_SELECT: u8 = 1 << 5; // Select buffer from buffer ring
    pub const CQE_SKIP_SUCCESS: u8 = 1 << 6; // Don't generate CQE on success
};

/// Buffer ring management for zero-copy operations
pub const BufferRing = struct {
    buffers: [][]u8,
    ring_entries: []BufferRingEntry,
    head: std.atomic.Value(u32),
    tail: std.atomic.Value(u32),
    ring_mask: u32,
    allocator: std.mem.Allocator,
    buffer_size: u32,
    
    const BufferRingEntry = struct {
        addr: u64,
        len: u32,
        bid: u16, // Buffer ID
        resv: u16 = 0,
    };
    
    pub fn init(allocator: std.mem.Allocator, ring_size: u32, buffer_size: u32) !BufferRing {
        const ring_mask = ring_size - 1;
        
        // Allocate buffers
        var buffers = try allocator.alloc([]u8, ring_size);
        for (buffers, 0..) |*buffer, i| {
            buffer.* = try allocator.alignedAlloc(u8, std.mem.page_size, buffer_size);
            // Initialize buffer data for debugging
            @memset(buffer.*, @intCast(i % 256));
        }
        
        // Allocate ring entries
        var ring_entries = try allocator.alloc(BufferRingEntry, ring_size);
        for (ring_entries, 0..) |*entry, i| {
            entry.* = BufferRingEntry{
                .addr = @intFromPtr(buffers[i].ptr),
                .len = buffer_size,
                .bid = @intCast(i),
            };
        }
        
        return BufferRing{
            .buffers = buffers,
            .ring_entries = ring_entries,
            .head = std.atomic.Value(u32).init(0),
            .tail = std.atomic.Value(u32).init(ring_size),
            .ring_mask = ring_mask,
            .allocator = allocator,
            .buffer_size = buffer_size,
        };
    }
    
    pub fn deinit(self: *BufferRing) void {
        for (self.buffers) |buffer| {
            self.allocator.free(buffer);
        }
        self.allocator.free(self.buffers);
        self.allocator.free(self.ring_entries);
    }
    
    pub fn getBuffer(self: *BufferRing, bid: u16) ?[]u8 {
        if (bid >= self.buffers.len) return null;
        return self.buffers[bid];
    }
    
    pub fn returnBuffer(self: *BufferRing, bid: u16) void {
        const tail = self.tail.load(.monotonic);
        const new_tail = (tail + 1) & self.ring_mask;
        
        if (new_tail != self.head.load(.monotonic)) {
            self.ring_entries[tail & self.ring_mask] = BufferRingEntry{
                .addr = @intFromPtr(self.buffers[bid].ptr),
                .len = self.buffer_size,
                .bid = bid,
            };
            self.tail.store(new_tail, .release);
        }
    }
};

/// Registered file descriptor manager
pub const RegisteredFiles = struct {
    files: []std.posix.fd_t,
    free_indices: std.ArrayList(u32),
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator, max_files: u32) !RegisteredFiles {
        const files = try allocator.alloc(std.posix.fd_t, max_files);
        @memset(files, -1); // Initialize with invalid FDs
        
        var free_indices = std.ArrayList(u32).init(allocator);
        for (0..max_files) |i| {
            try free_indices.append(@intCast(i));
        }
        
        return RegisteredFiles{
            .files = files,
            .free_indices = free_indices,
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *RegisteredFiles) void {
        self.free_indices.deinit();
        self.allocator.free(self.files);
    }
    
    pub fn register(self: *RegisteredFiles, fd: std.posix.fd_t) !u32 {
        if (self.free_indices.items.len == 0) return error.NoFreeSlots;
        
        const index = self.free_indices.pop();
        self.files[index] = fd;
        return index;
    }
    
    pub fn unregister(self: *RegisteredFiles, index: u32) void {
        if (index >= self.files.len) return;
        self.files[index] = -1;
        self.free_indices.append(index) catch {}; // Ignore allocation failure for cleanup
    }
};

/// Enhanced io_uring implementation with advanced features
pub const EnhancedIoUring = struct {
    ring_fd: std.posix.fd_t,
    params: linux.io_uring_params,
    sq: SubmissionQueue,
    cq: CompletionQueue,
    allocator: std.mem.Allocator,
    config: EnhancedIoUringConfig,
    
    // Advanced features
    buffer_ring: ?BufferRing,
    registered_files: ?RegisteredFiles,
    fixed_buffers: ?[][]u8,
    
    // Performance tracking
    metrics: Metrics,
    
    const Self = @This();
    
    const Metrics = struct {
        operations_submitted: std.atomic.Value(u64),
        operations_completed: std.atomic.Value(u64),
        sqpoll_wakeups: std.atomic.Value(u64),
        buffer_ring_hits: std.atomic.Value(u64),
        fast_poll_hits: std.atomic.Value(u64),
        
        pub fn init() Metrics {
            return Metrics{
                .operations_submitted = std.atomic.Value(u64).init(0),
                .operations_completed = std.atomic.Value(u64).init(0),
                .sqpoll_wakeups = std.atomic.Value(u64).init(0),
                .buffer_ring_hits = std.atomic.Value(u64).init(0),
                .fast_poll_hits = std.atomic.Value(u64).init(0),
            };
        }
    };
    
    const SubmissionQueue = struct {
        head: *u32,
        tail: *u32,
        ring_mask: u32,
        ring_entries: u32,
        flags: *u32,
        dropped: *u32,
        array: [*]u32,
        sqes: [*]linux.io_uring_sqe,
        mmap_ptr: []align(std.mem.page_size) u8,
        sqe_mmap_ptr: []align(std.mem.page_size) u8,
    };
    
    const CompletionQueue = struct {
        head: *u32,
        tail: *u32,
        ring_mask: u32,
        ring_entries: u32,
        overflow: *u32,
        cqes: [*]linux.io_uring_cqe,
        mmap_ptr: []align(std.mem.page_size) u8,
    };
    
    /// Initialize enhanced io_uring with advanced features
    pub fn init(allocator: std.mem.Allocator, config: EnhancedIoUringConfig) !Self {
        if (builtin.os.tag != .linux) {
            return error.PlatformNotSupported;
        }
        
        // Build setup flags with advanced features
        var flags: u32 = 0;
        if (config.sq_poll) {
            flags |= IoUringSetupFlags.SQPOLL;
            if (config.sq_thread_cpu > 0) {
                flags |= IoUringSetupFlags.SQ_AFF;
            }
        }
        if (config.cq_entries_multiplier > 1) {
            flags |= IoUringSetupFlags.CQSIZE;
        }
        if (config.enable_fast_poll) {
            flags |= IoUringSetupFlags.COOP_TASKRUN;
        }
        
        var params = linux.io_uring_params{
            .sq_entries = 0,
            .cq_entries = config.entries * config.cq_entries_multiplier,
            .flags = flags,
            .sq_thread_cpu = config.sq_thread_cpu,
            .sq_thread_idle = config.sq_thread_idle,
            .features = 0,
            .wq_fd = 0,
            .resv = [_]u32{0} ** 3,
            .sq_off = std.mem.zeroes(linux.io_uring_params.SqRingOffsets),
            .cq_off = std.mem.zeroes(linux.io_uring_params.CqRingOffsets),
        };
        
        // Setup io_uring
        const ring_fd = linux.io_uring_setup(config.entries, &params);
        if (linux.getErrno(ring_fd) != .SUCCESS) {
            return switch (linux.getErrno(ring_fd)) {
                .NOSYS => error.IoUringNotSupported,
                .NOMEM => error.OutOfMemory,
                .PERM => error.PermissionDenied,
                .INVAL => error.InvalidParameters,
                else => error.SetupFailed,
            };
        }
        
        // Map submission queue
        const sq_size = params.sq_off.array + params.sq_entries * @sizeOf(u32);
        const sq_mmap = try std.posix.mmap(
            null,
            sq_size,
            std.posix.PROT.READ | std.posix.PROT.WRITE,
            .{ .TYPE = .SHARED, .POPULATE = true },
            ring_fd,
            linux.IORING_OFF_SQ_RING,
        );
        
        // Map submission queue entries
        const sqe_size = params.sq_entries * @sizeOf(linux.io_uring_sqe);
        const sqe_mmap = try std.posix.mmap(
            null,
            sqe_size,
            std.posix.PROT.READ | std.posix.PROT.WRITE,
            .{ .TYPE = .SHARED, .POPULATE = true },
            ring_fd,
            linux.IORING_OFF_SQES,
        );
        
        // Map completion queue
        const cq_size = params.cq_off.cqes + params.cq_entries * @sizeOf(linux.io_uring_cqe);
        const cq_mmap = try std.posix.mmap(
            null,
            cq_size,
            std.posix.PROT.READ | std.posix.PROT.WRITE,
            .{ .TYPE = .SHARED, .POPULATE = true },
            ring_fd,
            linux.IORING_OFF_CQ_RING,
        );
        
        // Initialize submission queue
        const sq = SubmissionQueue{
            .head = @ptrFromInt(@intFromPtr(sq_mmap.ptr) + params.sq_off.head),
            .tail = @ptrFromInt(@intFromPtr(sq_mmap.ptr) + params.sq_off.tail),
            .ring_mask = params.sq_entries - 1,
            .ring_entries = params.sq_entries,
            .flags = @ptrFromInt(@intFromPtr(sq_mmap.ptr) + params.sq_off.flags),
            .dropped = @ptrFromInt(@intFromPtr(sq_mmap.ptr) + params.sq_off.dropped),
            .array = @ptrFromInt(@intFromPtr(sq_mmap.ptr) + params.sq_off.array),
            .sqes = @ptrCast(sqe_mmap.ptr),
            .mmap_ptr = @alignCast(sq_mmap),
            .sqe_mmap_ptr = @alignCast(sqe_mmap),
        };
        
        // Initialize completion queue
        const cq = CompletionQueue{
            .head = @ptrFromInt(@intFromPtr(cq_mmap.ptr) + params.cq_off.head),
            .tail = @ptrFromInt(@intFromPtr(cq_mmap.ptr) + params.cq_off.tail),
            .ring_mask = params.cq_entries - 1,
            .ring_entries = params.cq_entries,
            .overflow = @ptrFromInt(@intFromPtr(cq_mmap.ptr) + params.cq_off.overflow),
            .cqes = @ptrFromInt(@intFromPtr(cq_mmap.ptr) + params.cq_off.cqes),
            .mmap_ptr = @alignCast(cq_mmap),
        };
        
        var self = Self{
            .ring_fd = ring_fd,
            .params = params,
            .sq = sq,
            .cq = cq,
            .allocator = allocator,
            .config = config,
            .buffer_ring = null,
            .registered_files = null,
            .fixed_buffers = null,
            .metrics = Metrics.init(),
        };
        
        // Initialize advanced features
        if (config.enable_buffer_rings) {
            self.buffer_ring = BufferRing.init(
                allocator,
                config.buffer_ring_size,
                config.buffer_size,
            ) catch null; // Don't fail if buffer rings can't be created
        }
        
        if (config.enable_registered_files) {
            self.registered_files = RegisteredFiles.init(
                allocator,
                config.max_registered_files,
            ) catch null;
        }
        
        return self;
    }
    
    pub fn deinit(self: *Self) void {
        // Clean up advanced features
        if (self.buffer_ring) |*ring| {
            ring.deinit();
        }
        
        if (self.registered_files) |*files| {
            files.deinit();
        }
        
        if (self.fixed_buffers) |buffers| {
            for (buffers) |buffer| {
                self.allocator.free(buffer);
            }
            self.allocator.free(buffers);
        }
        
        // Unmap memory regions
        std.posix.munmap(self.sq.mmap_ptr);
        std.posix.munmap(self.sq.sqe_mmap_ptr);
        std.posix.munmap(self.cq.mmap_ptr);
        
        // Close ring file descriptor
        std.posix.close(self.ring_fd);
    }
    
    /// Get next available SQE with advanced features support
    pub fn getSqe(self: *Self) ?*linux.io_uring_sqe {
        const head = @atomicLoad(u32, self.sq.head, .acquire);
        const tail = @atomicLoad(u32, self.sq.tail, .monotonic);
        
        if (tail - head >= self.sq.ring_entries) {
            return null; // Queue full
        }
        
        const sqe = &self.sq.sqes[tail & self.sq.ring_mask];
        @memset(@as([*]u8, @ptrCast(sqe))[0..@sizeOf(linux.io_uring_sqe)], 0);
        return sqe;
    }
    
    /// Prepare read operation with buffer selection
    pub fn prepReadBuffer(self: *Self, fd: std.posix.fd_t, len: u32, offset: u64, buf_group: u16, user_data: u64) ?*linux.io_uring_sqe {
        const sqe = self.getSqe() orelse return null;
        
        sqe.opcode = linux.IORING_OP.READ;
        sqe.flags = IoSqeFlags.BUFFER_SELECT;
        sqe.ioprio = 0;
        sqe.fd = fd;
        sqe.off = offset;
        sqe.addr = 0; // Will be set by kernel from buffer ring
        sqe.len = len;
        sqe.rw_flags = 0;
        sqe.user_data = user_data;
        sqe.buf_index = buf_group;
        
        return sqe;
    }
    
    /// Prepare write operation with registered file
    pub fn prepWriteFixed(self: *Self, fd_index: u32, buffer: []const u8, offset: u64, user_data: u64) ?*linux.io_uring_sqe {
        const sqe = self.getSqe() orelse return null;
        
        sqe.opcode = linux.IORING_OP.WRITE;
        sqe.flags = IoSqeFlags.FIXED_FILE;
        sqe.ioprio = 0;
        sqe.fd = @intCast(fd_index);
        sqe.off = offset;
        sqe.addr = @intFromPtr(buffer.ptr);
        sqe.len = @intCast(buffer.len);
        sqe.rw_flags = 0;
        sqe.user_data = user_data;
        
        return sqe;
    }
    
    /// Prepare linked operations (chain multiple operations)
    pub fn prepLinkedOp(self: *Self, sqe: *linux.io_uring_sqe) void {
        sqe.flags |= IoSqeFlags.IO_LINK;
    }
    
    /// Prepare drain operation (wait for previous operations)
    pub fn prepDrainOp(self: *Self, sqe: *linux.io_uring_sqe) void {
        sqe.flags |= IoSqeFlags.IO_DRAIN;
    }
    
    /// Submit operations with advanced SQPOLL support
    pub fn submit(self: *Self) !u32 {
        return self.submitBatch(0);
    }
    
    /// High-throughput batch submission with optimal batching
    pub fn submitBatch(self: *Self, min_batch: u32) !u32 {
        const tail = @atomicLoad(u32, self.sq.tail, .monotonic);
        const head = @atomicLoad(u32, self.sq.head, .acquire);
        const to_submit = tail - head;
        
        if (to_submit == 0) return 0;
        if (min_batch > 0 and to_submit < min_batch) return 0; // Wait for larger batch
        
        // Update submission queue array efficiently
        var i: u32 = head;
        const end = head + to_submit;
        
        // Unrolled loop for better throughput - process 4 entries at a time
        while (i + 4 <= end) {
            self.sq.array[i & self.sq.ring_mask] = i & self.sq.ring_mask;
            self.sq.array[(i+1) & self.sq.ring_mask] = (i+1) & self.sq.ring_mask;
            self.sq.array[(i+2) & self.sq.ring_mask] = (i+2) & self.sq.ring_mask;
            self.sq.array[(i+3) & self.sq.ring_mask] = (i+3) & self.sq.ring_mask;
            i += 4;
        }
        
        // Handle remaining entries
        while (i < end) : (i += 1) {
            self.sq.array[i & self.sq.ring_mask] = i & self.sq.ring_mask;
        }
        
        // Memory barrier for visibility
        std.atomic.fence(.release);
        
        // Update tail
        @atomicStore(u32, self.sq.tail, tail, .release);
        
        // Update metrics
        _ = self.metrics.operations_submitted.fetchAdd(to_submit, .monotonic);
        
        // For SQPOLL mode, kernel polls automatically
        if (self.config.sq_poll) {
            // Check if kernel thread needs wakeup
            const flags = @atomicLoad(u32, self.sq.flags, .acquire);
            if (flags & linux.IORING_SQ_NEED_WAKEUP != 0) {
                _ = self.metrics.sqpoll_wakeups.fetchAdd(1, .monotonic);
                const result = linux.io_uring_enter(self.ring_fd, 0, 0, linux.IORING_ENTER_SQ_WAKEUP, null);
                return if (linux.getErrno(result) == .SUCCESS) to_submit else error.SubmitFailed;
            }
            return to_submit;
        }
        
        // Regular mode - submit to kernel with throughput optimizations
        var flags: u32 = 0;
        if (to_submit >= 8) { // For decent batches, use advanced flags
            flags |= linux.IORING_ENTER_SUBMIT_ALL;
        }
        
        const result = linux.io_uring_enter(self.ring_fd, to_submit, 0, flags, null);
        return if (linux.getErrno(result) == .SUCCESS) @intCast(result) else error.SubmitFailed;
    }
    
    /// Poll for completions with high-throughput batch processing
    pub fn poll(self: *Self, wait_nr: u32) !u32 {
        return self.pollBatch(wait_nr, false);
    }
    
    /// High-throughput batch completion processing
    pub fn pollBatch(self: *Self, wait_nr: u32, spin_wait: bool) !u32 {
        var completed: u32 = 0;
        var spin_count: u32 = 0;
        const max_spin = if (spin_wait) 1000 else 0;
        
        while (completed < wait_nr) {
            const head = @atomicLoad(u32, self.cq.head, .acquire);
            const tail = @atomicLoad(u32, self.cq.tail, .acquire);
            
            if (head == tail) {
                // No completions available
                if (completed > 0) break; // Return what we have
                
                // Spin-wait optimization for low latency
                if (spin_count < max_spin) {
                    spin_count += 1;
                    // Use CPU pause instruction for efficient spinning
                    asm volatile ("pause" ::: "memory");
                    continue;
                }
                
                // Use FAST_POLL for efficient blocking wait
                if (self.config.enable_fast_poll) {
                    _ = self.metrics.fast_poll_hits.fetchAdd(1, .monotonic);
                    const result = linux.io_uring_enter(
                        self.ring_fd,
                        0,
                        1,
                        linux.IORING_ENTER_GETEVENTS,
                        null,
                    );
                    if (linux.getErrno(result) != .SUCCESS) break;
                    spin_count = 0; // Reset spin count after kernel wait
                    continue;
                }
                break;
            }
            
            // Process completions in batches for better cache performance
            const available = tail - head;
            const to_process = @min(available, wait_nr - completed);
            const batch_size = @min(to_process, 16); // Process up to 16 at a time
            
            completed += batch_size;
            _ = self.metrics.operations_completed.fetchAdd(batch_size, .monotonic);
            
            // Advance head by the batch size
            @atomicStore(u32, self.cq.head, head + batch_size, .release);
            
            spin_count = 0; // Reset spin count on successful processing
        }
        
        return completed;
    }
    
    /// Get completion queue entry
    pub fn getCqe(self: *Self) ?*linux.io_uring_cqe {
        const head = @atomicLoad(u32, self.cq.head, .acquire);
        const tail = @atomicLoad(u32, self.cq.tail, .acquire);
        
        if (head == tail) return null;
        
        return &self.cq.cqes[head & self.cq.ring_mask];
    }
    
    /// Mark CQE as seen and handle buffer ring returns
    pub fn cqeSeen(self: *Self, cqe: *linux.io_uring_cqe) void {
        // Handle buffer ring return
        if (self.buffer_ring != null and cqe.flags & linux.IORING_CQE_F_BUFFER != 0) {
            const buf_id = (cqe.flags >> 16) & 0xFFFF;
            if (self.buffer_ring) |*ring| {
                ring.returnBuffer(@intCast(buf_id));
                _ = self.metrics.buffer_ring_hits.fetchAdd(1, .monotonic);
            }
        }
        
        const head = @atomicLoad(u32, self.cq.head, .acquire);
        @atomicStore(u32, self.cq.head, head + 1, .release);
        _ = self.metrics.operations_completed.fetchAdd(1, .monotonic);
    }
    
    /// Get performance metrics
    pub fn getMetrics(self: *const Self) *const Metrics {
        return &self.metrics;
    }
    
    /// High-throughput vector I/O operations
    pub fn submitReadVector(self: *Self, fd: i32, iovecs: []const std.posix.iovec, offset: u64, user_data: u64) !void {
        const sqe = try self.getSqe();
        sqe.opcode = linux.IORING_OP_READV;
        sqe.fd = fd;
        sqe.addr = @intFromPtr(iovecs.ptr);
        sqe.len = @intCast(iovecs.len);
        sqe.off = offset;
        sqe.user_data = user_data;
        sqe.flags |= IoSqeFlags.ASYNC; // Use async workers for better throughput
    }
    
    pub fn submitWriteVector(self: *Self, fd: i32, iovecs: []const std.posix.iovec, offset: u64, user_data: u64) !void {
        const sqe = try self.getSqe();
        sqe.opcode = linux.IORING_OP_WRITEV;
        sqe.fd = fd;
        sqe.addr = @intFromPtr(iovecs.ptr);
        sqe.len = @intCast(iovecs.len);
        sqe.off = offset;
        sqe.user_data = user_data;
        sqe.flags |= IoSqeFlags.ASYNC; // Use async workers for better throughput
    }
    
    /// High-throughput fixed buffer operations (zero-copy)
    pub fn submitReadFixed(self: *Self, fd: i32, buf_index: u16, len: u32, offset: u64, user_data: u64) !void {
        const sqe = try self.getSqe();
        sqe.opcode = linux.IORING_OP_READ_FIXED;
        sqe.fd = fd;
        sqe.len = len;
        sqe.off = offset;
        sqe.user_data = user_data;
        sqe.buf_index = buf_index;
        sqe.flags |= IoSqeFlags.FIXED_FILE; // Use registered file for better performance
    }
    
    pub fn submitWriteFixed(self: *Self, fd: i32, buf_index: u16, len: u32, offset: u64, user_data: u64) !void {
        const sqe = try self.getSqe();
        sqe.opcode = linux.IORING_OP_WRITE_FIXED;
        sqe.fd = fd;
        sqe.len = len;
        sqe.off = offset;
        sqe.user_data = user_data;
        sqe.buf_index = buf_index;
        sqe.flags |= IoSqeFlags.FIXED_FILE; // Use registered file for better performance
    }
    
    /// Batched submission for maximum throughput
    pub fn submitAndWait(self: *Self, wait_nr: u32) !u32 {
        const submitted = try self.submit();
        if (submitted == 0) return 0;
        
        // For high throughput, don't wait if we submitted a large batch
        if (submitted >= 32) {
            // Just return submitted count, completions will be available soon
            return submitted;
        }
        
        // For smaller batches, wait for some completions
        return try self.poll(wait_nr);
    }
    
    /// Drain all pending completions for maximum throughput
    pub fn drainCompletions(self: *Self, max_drain: u32) !u32 {
        return try self.pollBatch(max_drain, true); // Enable spin-wait for low latency
    }
    
    /// Register file descriptors for zero-copy operations
    pub fn registerFiles(self: *Self, files: []const std.posix.fd_t) !void {
        const result = linux.io_uring_register(
            self.ring_fd,
            linux.IORING_REGISTER_FILES,
            @ptrCast(files.ptr),
            @intCast(files.len),
        );
        if (linux.getErrno(result) != .SUCCESS) {
            return error.RegisterFilesFailed;
        }
    }
    
    /// Register buffers for zero-copy operations  
    pub fn registerBuffers(self: *Self, buffers: []const []const u8) !void {
        var iovecs = try self.allocator.alloc(std.posix.iovec_const, buffers.len);
        defer self.allocator.free(iovecs);
        
        for (buffers, iovecs) |buffer, *iovec| {
            iovec.* = .{
                .base = buffer.ptr,
                .len = buffer.len,
            };
        }
        
        const result = linux.io_uring_register(
            self.ring_fd,
            linux.IORING_REGISTER_BUFFERS,
            @ptrCast(iovecs.ptr),
            @intCast(iovecs.len),
        );
        if (linux.getErrno(result) != .SUCCESS) {
            return error.RegisterBuffersFailed;
        }
    }
};

/// Create enhanced io_uring instance with optimal configuration
/// High-throughput io_uring configuration optimized for maximum performance
pub fn createHighThroughputIoUring(allocator: std.mem.Allocator, entries: u32) !EnhancedIoUring {
    const config = EnhancedIoUringConfig{
        .entries = entries,
        .sq_poll = true,  // Enable kernel polling for best performance
        .sq_thread_idle = 500, // Shorter idle time for high throughput
        .sq_thread_cpu = 0,    // Pin to specific CPU for cache locality
        .enable_fast_poll = true,
        .enable_buffer_rings = true,
        .enable_registered_files = true,
        .enable_fixed_buffers = true,
        .cq_entries_multiplier = 8, // Very large completion queue for batching
        .buffer_ring_size = 4096,   // Large buffer ring for zero-copy
        .buffer_size = 65536,       // 64KB buffers for better bandwidth
        .max_registered_files = 1024, // Support many file descriptors
        .max_fixed_buffers = 512,   // Many fixed buffers for zero-copy
    };
    
    return try EnhancedIoUring.init(allocator, config);
}

pub fn createEnhancedIoUring(allocator: std.mem.Allocator, entries: u32) !EnhancedIoUring {
    const config = EnhancedIoUringConfig{
        .entries = entries,
        .sq_poll = true,  // Enable kernel polling for best performance
        .sq_thread_idle = 1000, // 1 second idle time
        .enable_fast_poll = true,
        .enable_buffer_rings = true,
        .enable_registered_files = true,
        .enable_fixed_buffers = true,
        .cq_entries_multiplier = 4, // Larger completion queue for high throughput
        .buffer_ring_size = 2048,   // Large buffer ring
        .buffer_size = 16384,       // 16KB buffers
        .max_registered_files = 512,
        .max_fixed_buffers = 256,
    };
    
    return EnhancedIoUring.init(allocator, config);
}