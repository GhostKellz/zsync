//! zsync - Windows IOCP I/O Implementation
//! Experimental Windows backend using a completion queue plus worker-submitted operations.
//!
//! This implementation keeps the public backend usable and non-hanging on current Zig
//! while the fully-overlapped socket/file paths continue to evolve.
//!
//! Native Winsock overlapped routing requires descriptor-kind registration so the
//! backend can distinguish sockets from generic file descriptors. The current
//! backend exposes registration hooks and uses worker-backed execution until the
//! socket creation/ownership paths are fully wired into that registration layer.

const std = @import("std");
const builtin = @import("builtin");
const io_interface = @import("io_interface.zig");

const Io = io_interface.Io;
const IoError = io_interface.IoError;
const Future = io_interface.Future;
const IoBuffer = io_interface.IoBuffer;

const is_windows = builtin.os.tag == .windows;
const windows = if (is_windows) std.os.windows else void;
const platform = if (is_windows) @import("platform/windows.zig") else struct {
    pub const OVERLAPPED = void;
    pub const IOCP = void;
};
const posix = std.posix;
const compat = @import("compat/thread.zig");

fn unsupportedFuture(allocator: std.mem.Allocator, err: IoError) IoError!Future {
    const UnsupportedContext = struct {
        err: IoError,

        fn poll(context: *anyopaque) Future.PollResult {
            const self: *@This() = @ptrCast(@alignCast(context));
            return .{ .err = self.err };
        }

        fn cancel(_: *anyopaque) void {}

        fn destroy(context: *anyopaque, alloc: std.mem.Allocator) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            alloc.destroy(self);
        }
    };

    const context = try allocator.create(UnsupportedContext);
    context.* = .{ .err = err };

    const unsupported_vtable = Future.FutureVTable{
        .poll = UnsupportedContext.poll,
        .cancel = UnsupportedContext.cancel,
        .destroy = UnsupportedContext.destroy,
    };

    return Future.init(allocator, &unsupported_vtable, context);
}

const PendingOperation = struct {
    op_type: OpType,
    completion_key: usize,
    completed: std.atomic.Value(bool),
    err: ?IoError,
    bytes_transferred: u32,
    fd: ?posix.fd_t = null,
    extra_fd: ?posix.fd_t = null,
    read_buffer: ?[]u8 = null,
    write_buffer: ?[]u8 = null,
    readv_buffers: ?[]IoBuffer = null,
    writev_buffers: ?[]const []const u8 = null,
    addr_storage: ?windows.ws2_32.sockaddr.storage = null,
    addr_len: posix.socklen_t = 0,
    offset: u64 = 0,
    count: u64 = 0,
    worker_thread: ?std.Thread = null,

    const OpType = enum {
        read,
        write,
        readv,
        writev,
        accept,
        connect,
        send_file,
        copy_file_range,
        close,
    };

    fn init(op_type: OpType, completion_key: usize) PendingOperation {
        return .{
            .op_type = op_type,
            .completion_key = completion_key,
            .completed = std.atomic.Value(bool).init(false),
            .err = null,
            .bytes_transferred = 0,
        };
    }

    fn markComplete(self: *PendingOperation, bytes: u32) void {
        self.bytes_transferred = bytes;
        self.completed.store(true, .release);
    }

    fn markError(self: *PendingOperation, err: IoError) void {
        self.err = err;
        self.completed.store(true, .release);
    }

    fn joinWorkerIfNeeded(self: *PendingOperation) void {
        if (self.worker_thread) |thread| {
            thread.join();
            self.worker_thread = null;
        }
    }

    fn deinit(self: *PendingOperation, allocator: std.mem.Allocator) void {
        self.joinWorkerIfNeeded();
        if (self.write_buffer) |buffer| allocator.free(buffer);
        allocator.destroy(self);
    }
};

pub const WindowsIocpIo = struct {
    const DescriptorKind = enum {
        unknown,
        file,
        socket,
    };

    allocator: std.mem.Allocator,
    iocp: if (is_windows) platform.IOCP else void,
    pending_ops: std.HashMap(usize, *PendingOperation, std.hash_map.AutoContext(usize), std.hash_map.default_max_load_percentage),
    descriptor_kinds: std.HashMap(posix.fd_t, DescriptorKind, std.hash_map.AutoContext(posix.fd_t), std.hash_map.default_max_load_percentage),
    next_key: std.atomic.Value(usize),
    mutex: compat.Mutex,
    shutdown_flag: std.atomic.Value(bool),
    poll_thread: ?std.Thread,
    read_fd: posix.fd_t,
    write_fd: posix.fd_t,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, thread_count: u32) !Self {
        if (!is_windows) return error.PlatformUnsupported;

        const read_fd = if (is_windows)
            std.os.windows.peb().ProcessParameters.hStdInput
        else
            posix.STDIN_FILENO;
        const write_fd = if (is_windows)
            std.os.windows.peb().ProcessParameters.hStdOutput
        else
            posix.STDOUT_FILENO;

        const iocp = try platform.IOCP.init(thread_count);
        var self = Self{
            .allocator = allocator,
            .iocp = iocp,
            .pending_ops = std.HashMap(usize, *PendingOperation, std.hash_map.AutoContext(usize), std.hash_map.default_max_load_percentage).init(allocator),
            .descriptor_kinds = std.HashMap(posix.fd_t, DescriptorKind, std.hash_map.AutoContext(posix.fd_t), std.hash_map.default_max_load_percentage).init(allocator),
            .next_key = std.atomic.Value(usize).init(1),
            .mutex = .{},
            .shutdown_flag = std.atomic.Value(bool).init(false),
            .poll_thread = null,
            .read_fd = read_fd,
            .write_fd = write_fd,
        };

        self.poll_thread = std.Thread.spawn(.{}, backgroundPollLoop, .{&self}) catch null;
        return self;
    }

    pub fn deinit(self: *Self) void {
        if (!is_windows) return;

        self.shutdown_flag.store(true, .release);
        self.iocp.postQueuedCompletionStatus(0, 0, null) catch {};

        if (self.poll_thread) |thread| thread.join();

        self.mutex.lock();
        var it = self.pending_ops.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit(self.allocator);
        }
        self.pending_ops.deinit();
        self.descriptor_kinds.deinit();
        self.mutex.unlock();

        self.iocp.deinit();
    }

    fn backgroundPollLoop(self: *Self) void {
        while (!self.shutdown_flag.load(.acquire)) {
            var bytes_transferred: u32 = undefined;
            var completion_key: usize = undefined;
            var overlapped_ptr: *platform.OVERLAPPED = undefined;

            const has_completion = self.iocp.getQueuedCompletionStatus(
                &bytes_transferred,
                &completion_key,
                &overlapped_ptr,
                100,
            ) catch continue;

            if (has_completion and completion_key != 0) {
                self.mutex.lock();
                if (self.pending_ops.get(completion_key)) |op| {
                    if (op.err == null) op.markComplete(bytes_transferred) else op.completed.store(true, .release);
                }
                self.mutex.unlock();
            }
        }
    }

    fn completeOperation(self: *Self, op: *PendingOperation, bytes_transferred: u32) void {
        self.iocp.postQueuedCompletionStatus(bytes_transferred, op.completion_key, null) catch {
            op.markError(IoError.SystemResources);
        };
    }

    fn mapPosixError(err: anyerror) IoError {
        return switch (err) {
            error.WouldBlock => IoError.WouldBlock,
            error.BrokenPipe => IoError.BrokenPipe,
            error.ConnectionResetByPeer => IoError.ConnectionClosed,
            error.ConnectionRefused => IoError.ConnectionRefused,
            error.NetworkUnreachable => IoError.NetworkUnreachable,
            error.PermissionDenied => IoError.AccessDenied,
            error.FileNotFound => IoError.FileNotFound,
            error.AccessDenied => IoError.AccessDenied,
            else => IoError.SystemResources,
        };
    }

    fn startWorkerOperation(self: *Self, op: *PendingOperation, comptime worker: fn (*Self, *PendingOperation) void) !void {
        self.mutex.lock();
        errdefer self.mutex.unlock();
        try self.pending_ops.put(op.completion_key, op);
        self.mutex.unlock();

        op.worker_thread = try std.Thread.spawn(.{}, worker, .{ self, op });
    }

    fn operationDescriptorKind(self: *Self, op: *const PendingOperation) DescriptorKind {
        if (op.fd) |fd| return self.descriptorKind(fd);
        return .unknown;
    }

    fn createOperationFuture(self: *Self, op: *PendingOperation) !Future {
        const OperationFuture = struct {
            op: *PendingOperation,
            parent: *Self,

            fn poll(ctx: *anyopaque) Future.PollResult {
                const fut: *@This() = @ptrCast(@alignCast(ctx));
                if (!fut.op.completed.load(.acquire)) return .pending;
                if (fut.op.err) |err| return .{ .err = err };
                return .ready;
            }

            fn cancel(ctx: *anyopaque) void {
                const fut: *@This() = @ptrCast(@alignCast(ctx));
                fut.op.markError(IoError.Cancelled);
            }

            fn destroy(ctx: *anyopaque, alloc: std.mem.Allocator) void {
                const fut: *@This() = @ptrCast(@alignCast(ctx));
                fut.parent.mutex.lock();
                _ = fut.parent.pending_ops.remove(fut.op.completion_key);
                fut.parent.mutex.unlock();
                fut.op.deinit(alloc);
                alloc.destroy(fut);
            }

            fn getResult(ctx: *anyopaque) ?io_interface.IoResult {
                const fut: *@This() = @ptrCast(@alignCast(ctx));
                if (!fut.op.completed.load(.acquire) or fut.op.err != null) return null;
                return .{ .bytes_transferred = fut.op.bytes_transferred };
            }
        };

        const future = try self.allocator.create(OperationFuture);
        future.* = .{ .op = op, .parent = self };

        const operation_vtable = Future.FutureVTable{
            .poll = OperationFuture.poll,
            .cancel = OperationFuture.cancel,
            .destroy = OperationFuture.destroy,
            .get_result = OperationFuture.getResult,
        };

        return Future.init(self.allocator, &operation_vtable, future);
    }

    pub fn registerSocket(self: *Self, fd: posix.fd_t) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.descriptor_kinds.put(fd, .socket);
    }

    pub fn registerFile(self: *Self, fd: posix.fd_t) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.descriptor_kinds.put(fd, .file);
    }

    pub fn descriptorKind(self: *Self, fd: posix.fd_t) DescriptorKind {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.descriptor_kinds.get(fd) orelse .unknown;
    }

    pub fn io(self: *Self) Io {
        return Io{ .vtable = &vtable, .context = self };
    }

    const vtable = Io.IoVTable{
        .read = read,
        .write = write,
        .readv = readv,
        .writev = writev,
        .send_file = send_file,
        .copy_file_range = copy_file_range,
        .accept = accept,
        .connect = connect,
        .close = close_fd,
        .shutdown = shutdown,
        .get_mode = getMode,
        .get_allocator = getAllocator,
        .supports_vectorized = supportsVectorized,
        .supports_zero_copy = supportsZeroCopy,
    };

    fn read(context: *anyopaque, buffer: []u8) IoError!Future {
        const self: *Self = @ptrCast(@alignCast(context));
        if (!is_windows) return IoError.NotSupported;

        const key = self.next_key.fetchAdd(1, .monotonic);
        const op = self.allocator.create(PendingOperation) catch return IoError.OutOfMemory;
        op.* = PendingOperation.init(.read, key);
        op.fd = self.read_fd;
        op.read_buffer = buffer;

        const WorkerTask = struct {
            fn run(parent: *Self, task_op: *PendingOperation) void {
                const fd = task_op.fd orelse {
                    task_op.markError(IoError.InvalidDescriptor);
                    parent.completeOperation(task_op, 0);
                    return;
                };
                _ = parent.operationDescriptorKind(task_op);
                const read_buffer = task_op.read_buffer orelse {
                    task_op.markError(IoError.Unexpected);
                    parent.completeOperation(task_op, 0);
                    return;
                };

                if (builtin.os.tag == .windows) {
                    // Native Windows I/O based on descriptor kind
                    const kind = parent.operationDescriptorKind(task_op);
                    const buffer_len: u32 = @intCast(@min(read_buffer.len, std.math.maxInt(u32)));

                    if (kind == .socket) {
                        // Socket read using recv
                        const result = platform.recv(fd, read_buffer.ptr, @intCast(buffer_len), 0);
                        if (result == platform.SOCKET_ERROR) {
                            task_op.markError(IoError.Unexpected);
                            parent.completeOperation(task_op, 0);
                            return;
                        }
                        task_op.bytes_transferred = @intCast(result);
                        parent.completeOperation(task_op, @intCast(result));
                    } else {
                        // File read using ReadFile
                        var bytes_read_win: u32 = 0;
                        const result = platform.ReadFile(fd, read_buffer.ptr, buffer_len, &bytes_read_win, null);
                        if (result == .FALSE) {
                            task_op.markError(IoError.Unexpected);
                            parent.completeOperation(task_op, 0);
                            return;
                        }
                        task_op.bytes_transferred = bytes_read_win;
                        parent.completeOperation(task_op, bytes_read_win);
                    }
                    return;
                }

                const bytes_read = std.posix.read(fd, read_buffer) catch |err| {
                    task_op.markError(mapPosixError(err));
                    parent.completeOperation(task_op, 0);
                    return;
                };

                task_op.bytes_transferred = @intCast(bytes_read);
                parent.completeOperation(task_op, @intCast(bytes_read));
            }
        };

        self.startWorkerOperation(op, WorkerTask.run) catch {
            op.deinit(self.allocator);
            return IoError.OutOfMemory;
        };

        return self.createOperationFuture(op);
    }

    fn write(context: *anyopaque, data: []const u8) IoError!Future {
        const self: *Self = @ptrCast(@alignCast(context));
        if (!is_windows) return IoError.NotSupported;

        const key = self.next_key.fetchAdd(1, .monotonic);
        const op = self.allocator.create(PendingOperation) catch return IoError.OutOfMemory;
        op.* = PendingOperation.init(.write, key);
        op.fd = self.write_fd;

        const owned_buffer = self.allocator.alloc(u8, data.len) catch {
            self.allocator.destroy(op);
            return IoError.OutOfMemory;
        };
        @memcpy(owned_buffer, data);
        op.write_buffer = owned_buffer;

        const WorkerTask = struct {
            fn run(parent: *Self, task_op: *PendingOperation) void {
                const fd = task_op.fd orelse {
                    task_op.markError(IoError.InvalidDescriptor);
                    parent.completeOperation(task_op, 0);
                    return;
                };
                _ = parent.operationDescriptorKind(task_op);
                const write_buffer = task_op.write_buffer orelse {
                    task_op.markError(IoError.Unexpected);
                    parent.completeOperation(task_op, 0);
                    return;
                };

                if (builtin.os.tag == .windows) {
                    // Native Windows I/O based on descriptor kind
                    const kind = parent.operationDescriptorKind(task_op);
                    const buffer_len: u32 = @intCast(@min(write_buffer.len, std.math.maxInt(u32)));

                    if (kind == .socket) {
                        // Socket write using send
                        const result = platform.send(fd, write_buffer.ptr, @intCast(buffer_len), 0);
                        if (result == platform.SOCKET_ERROR) {
                            task_op.markError(IoError.Unexpected);
                            parent.completeOperation(task_op, 0);
                            return;
                        }
                        task_op.bytes_transferred = @intCast(result);
                        parent.completeOperation(task_op, @intCast(result));
                    } else {
                        // File write using WriteFile
                        var bytes_written_win: u32 = 0;
                        const result = platform.WriteFile(fd, write_buffer.ptr, buffer_len, &bytes_written_win, null);
                        if (result == .FALSE) {
                            task_op.markError(IoError.Unexpected);
                            parent.completeOperation(task_op, 0);
                            return;
                        }
                        task_op.bytes_transferred = bytes_written_win;
                        parent.completeOperation(task_op, bytes_written_win);
                    }
                    return;
                }

                const bytes_written = std.posix.write(fd, write_buffer) catch |err| {
                    task_op.markError(mapPosixError(err));
                    parent.completeOperation(task_op, 0);
                    return;
                };

                task_op.bytes_transferred = @intCast(bytes_written);
                parent.completeOperation(task_op, @intCast(bytes_written));
            }
        };

        self.startWorkerOperation(op, WorkerTask.run) catch {
            op.deinit(self.allocator);
            return IoError.OutOfMemory;
        };

        return self.createOperationFuture(op);
    }

    fn readv(context: *anyopaque, buffers: []IoBuffer) IoError!Future {
        const self: *Self = @ptrCast(@alignCast(context));
        if (!is_windows) return IoError.NotSupported;

        const key = self.next_key.fetchAdd(1, .monotonic);
        const op = self.allocator.create(PendingOperation) catch return IoError.OutOfMemory;
        op.* = PendingOperation.init(.readv, key);
        op.fd = self.read_fd;
        op.readv_buffers = buffers;

        const WorkerTask = struct {
            fn run(parent: *Self, task_op: *PendingOperation) void {
                const fd = task_op.fd orelse {
                    task_op.markError(IoError.InvalidDescriptor);
                    parent.completeOperation(task_op, 0);
                    return;
                };
                _ = parent.operationDescriptorKind(task_op);
                const vec_buffers = task_op.readv_buffers orelse {
                    task_op.markError(IoError.Unexpected);
                    parent.completeOperation(task_op, 0);
                    return;
                };

                var total: usize = 0;

                if (builtin.os.tag == .windows) {
                    // Native Windows vectored read - loop through buffers
                    const kind = parent.operationDescriptorKind(task_op);

                    for (vec_buffers) |*buf| {
                        const writable = buf.available();
                        if (writable.len == 0) continue;
                        const buffer_len: u32 = @intCast(@min(writable.len, std.math.maxInt(u32)));

                        if (kind == .socket) {
                            const result = platform.recv(fd, writable.ptr, @intCast(buffer_len), 0);
                            if (result == platform.SOCKET_ERROR) break;
                            if (result == 0) break; // Connection closed
                            buf.advance(@intCast(result));
                            total += @intCast(result);
                            if (@as(usize, @intCast(result)) < writable.len) break;
                        } else {
                            var bytes_read_win: u32 = 0;
                            const result = platform.ReadFile(fd, writable.ptr, buffer_len, &bytes_read_win, null);
                            if (result == .FALSE) break;
                            if (bytes_read_win == 0) break; // EOF
                            buf.advance(bytes_read_win);
                            total += bytes_read_win;
                            if (bytes_read_win < buffer_len) break;
                        }
                    }

                    task_op.bytes_transferred = @intCast(total);
                    parent.completeOperation(task_op, @intCast(total));
                    return;
                }

                for (vec_buffers) |*buf| {
                    const writable = buf.available();
                    if (writable.len == 0) continue;

                    const bytes_read = std.posix.read(fd, writable) catch |err| {
                        task_op.markError(mapPosixError(err));
                        parent.completeOperation(task_op, @intCast(total));
                        return;
                    };

                    buf.advance(bytes_read);
                    total += bytes_read;
                    if (bytes_read < writable.len) break;
                }

                task_op.bytes_transferred = @intCast(total);
                parent.completeOperation(task_op, @intCast(total));
            }
        };

        self.startWorkerOperation(op, WorkerTask.run) catch {
            op.deinit(self.allocator);
            return IoError.OutOfMemory;
        };

        return self.createOperationFuture(op);
    }

    fn writev(context: *anyopaque, buffers: []const []const u8) IoError!Future {
        const self: *Self = @ptrCast(@alignCast(context));
        if (!is_windows) return IoError.NotSupported;

        const key = self.next_key.fetchAdd(1, .monotonic);
        const op = self.allocator.create(PendingOperation) catch return IoError.OutOfMemory;
        op.* = PendingOperation.init(.writev, key);
        op.fd = self.write_fd;
        op.writev_buffers = buffers;

        const WorkerTask = struct {
            fn run(parent: *Self, task_op: *PendingOperation) void {
                const fd = task_op.fd orelse {
                    task_op.markError(IoError.InvalidDescriptor);
                    parent.completeOperation(task_op, 0);
                    return;
                };
                _ = parent.operationDescriptorKind(task_op);
                const vec_buffers = task_op.writev_buffers orelse {
                    task_op.markError(IoError.Unexpected);
                    parent.completeOperation(task_op, 0);
                    return;
                };

                var total: usize = 0;

                if (builtin.os.tag == .windows) {
                    // Native Windows vectored write - loop through buffers
                    const kind = parent.operationDescriptorKind(task_op);

                    for (vec_buffers) |slice| {
                        if (slice.len == 0) continue;
                        const buffer_len: u32 = @intCast(@min(slice.len, std.math.maxInt(u32)));

                        if (kind == .socket) {
                            const result = platform.send(fd, slice.ptr, @intCast(buffer_len), 0);
                            if (result == platform.SOCKET_ERROR) break;
                            total += @intCast(result);
                            if (@as(usize, @intCast(result)) < slice.len) break;
                        } else {
                            var bytes_written_win: u32 = 0;
                            const result = platform.WriteFile(fd, slice.ptr, buffer_len, &bytes_written_win, null);
                            if (result == .FALSE) break;
                            total += bytes_written_win;
                            if (bytes_written_win < buffer_len) break;
                        }
                    }

                    task_op.bytes_transferred = @intCast(total);
                    parent.completeOperation(task_op, @intCast(total));
                    return;
                }

                for (vec_buffers) |slice| {
                    if (slice.len == 0) continue;
                    const bytes_written = std.posix.write(fd, slice) catch |err| {
                        task_op.markError(mapPosixError(err));
                        parent.completeOperation(task_op, @intCast(total));
                        return;
                    };

                    total += bytes_written;
                    if (bytes_written < slice.len) break;
                }

                task_op.bytes_transferred = @intCast(total);
                parent.completeOperation(task_op, @intCast(total));
            }
        };

        self.startWorkerOperation(op, WorkerTask.run) catch {
            op.deinit(self.allocator);
            return IoError.OutOfMemory;
        };

        return self.createOperationFuture(op);
    }

    fn send_file(context: *anyopaque, src_fd: posix.fd_t, offset: u64, count: u64) IoError!Future {
        const self: *Self = @ptrCast(@alignCast(context));
        if (!is_windows) return IoError.NotSupported;

        const key = self.next_key.fetchAdd(1, .monotonic);
        const op = self.allocator.create(PendingOperation) catch return IoError.OutOfMemory;
        op.* = PendingOperation.init(.send_file, key);
        op.fd = src_fd;
        op.extra_fd = self.write_fd;
        op.offset = offset;
        op.count = count;

        const WorkerTask = struct {
            fn run(parent: *Self, task_op: *PendingOperation) void {
                const src_fd_value = task_op.fd orelse {
                    task_op.markError(IoError.InvalidDescriptor);
                    parent.completeOperation(task_op, 0);
                    return;
                };
                const dst_fd_value = task_op.extra_fd orelse {
                    task_op.markError(IoError.InvalidDescriptor);
                    parent.completeOperation(task_op, 0);
                    return;
                };

                var remaining = task_op.count;
                var total: usize = 0;
                var buffer: [64 * 1024]u8 = undefined;

                if (builtin.os.tag == .windows) {
                    // Native Windows send_file using SetFilePointerEx + ReadFile + WriteFile
                    const dst_kind = parent.descriptorKind(dst_fd_value);

                    // Seek to offset in source file
                    if (platform.SetFilePointerEx(src_fd_value, @intCast(task_op.offset), null, platform.FILE_BEGIN) == .FALSE) {
                        task_op.markError(IoError.Unexpected);
                        parent.completeOperation(task_op, 0);
                        return;
                    }

                    while (remaining > 0) {
                        const to_read: u32 = @intCast(@min(remaining, buffer.len));
                        var bytes_read_win: u32 = 0;

                        if (platform.ReadFile(src_fd_value, &buffer, to_read, &bytes_read_win, null) == .FALSE) {
                            break;
                        }
                        if (bytes_read_win == 0) break;

                        var written: usize = 0;
                        while (written < bytes_read_win) {
                            const remaining_slice = buffer[written..bytes_read_win];
                            const write_len: u32 = @intCast(remaining_slice.len);

                            if (dst_kind == .socket) {
                                const result = platform.send(dst_fd_value, remaining_slice.ptr, @intCast(write_len), 0);
                                if (result == platform.SOCKET_ERROR) break;
                                written += @intCast(result);
                            } else {
                                var bytes_written_win: u32 = 0;
                                if (platform.WriteFile(dst_fd_value, remaining_slice.ptr, write_len, &bytes_written_win, null) == .FALSE) {
                                    break;
                                }
                                written += bytes_written_win;
                            }
                        }

                        total += written;
                        remaining -= written;
                        if (written < bytes_read_win) break;
                    }

                    task_op.bytes_transferred = @intCast(total);
                    parent.completeOperation(task_op, @intCast(total));
                    return;
                }

                while (remaining > 0) {
                    const to_read: usize = @intCast(@min(remaining, buffer.len));
                    const bytes_read = std.posix.pread(src_fd_value, buffer[0..to_read], task_op.offset + total) catch |err| {
                        task_op.markError(mapPosixError(err));
                        parent.completeOperation(task_op, @intCast(total));
                        return;
                    };
                    if (bytes_read == 0) break;

                    var written: usize = 0;
                    while (written < bytes_read) {
                        const bytes_written = std.posix.write(dst_fd_value, buffer[written..bytes_read]) catch |err| {
                            task_op.markError(mapPosixError(err));
                            parent.completeOperation(task_op, @intCast(total + written));
                            return;
                        };
                        if (bytes_written == 0) break;
                        written += bytes_written;
                    }

                    total += written;
                    remaining -= written;
                    if (written < bytes_read) break;
                }

                task_op.bytes_transferred = @intCast(total);
                parent.completeOperation(task_op, @intCast(total));
            }
        };

        self.startWorkerOperation(op, WorkerTask.run) catch {
            op.deinit(self.allocator);
            return IoError.OutOfMemory;
        };

        return self.createOperationFuture(op);
    }

    fn copy_file_range(context: *anyopaque, src_fd: posix.fd_t, dst_fd: posix.fd_t, count: u64) IoError!Future {
        const self: *Self = @ptrCast(@alignCast(context));
        if (!is_windows) return IoError.NotSupported;

        const key = self.next_key.fetchAdd(1, .monotonic);
        const op = self.allocator.create(PendingOperation) catch return IoError.OutOfMemory;
        op.* = PendingOperation.init(.copy_file_range, key);
        op.fd = src_fd;
        op.extra_fd = dst_fd;
        op.count = count;

        const WorkerTask = struct {
            fn run(parent: *Self, task_op: *PendingOperation) void {
                const src_fd_value = task_op.fd orelse {
                    task_op.markError(IoError.InvalidDescriptor);
                    parent.completeOperation(task_op, 0);
                    return;
                };
                const dst_fd_value = task_op.extra_fd orelse {
                    task_op.markError(IoError.InvalidDescriptor);
                    parent.completeOperation(task_op, 0);
                    return;
                };

                var remaining = task_op.count;
                var total: usize = 0;
                var buffer: [64 * 1024]u8 = undefined;

                if (builtin.os.tag == .windows) {
                    // Native Windows copy_file_range using ReadFile + WriteFile
                    while (remaining > 0) {
                        const to_read: u32 = @intCast(@min(remaining, buffer.len));
                        var bytes_read_win: u32 = 0;

                        if (platform.ReadFile(src_fd_value, &buffer, to_read, &bytes_read_win, null) == .FALSE) {
                            break;
                        }
                        if (bytes_read_win == 0) break;

                        var written: usize = 0;
                        while (written < bytes_read_win) {
                            const remaining_slice = buffer[written..bytes_read_win];
                            const write_len: u32 = @intCast(remaining_slice.len);
                            var bytes_written_win: u32 = 0;

                            if (platform.WriteFile(dst_fd_value, remaining_slice.ptr, write_len, &bytes_written_win, null) == .FALSE) {
                                break;
                            }
                            written += bytes_written_win;
                        }

                        total += written;
                        remaining -= written;
                        if (written < bytes_read_win) break;
                    }

                    task_op.bytes_transferred = @intCast(total);
                    parent.completeOperation(task_op, @intCast(total));
                    return;
                }

                while (remaining > 0) {
                    const to_read: usize = @intCast(@min(remaining, buffer.len));
                    const bytes_read = std.posix.read(src_fd_value, buffer[0..to_read]) catch |err| {
                        task_op.markError(mapPosixError(err));
                        parent.completeOperation(task_op, @intCast(total));
                        return;
                    };
                    if (bytes_read == 0) break;

                    var written: usize = 0;
                    while (written < bytes_read) {
                        const bytes_written = std.posix.write(dst_fd_value, buffer[written..bytes_read]) catch |err| {
                            task_op.markError(mapPosixError(err));
                            parent.completeOperation(task_op, @intCast(total + written));
                            return;
                        };
                        if (bytes_written == 0) break;
                        written += bytes_written;
                    }

                    total += written;
                    remaining -= written;
                    if (written < bytes_read) break;
                }

                task_op.bytes_transferred = @intCast(total);
                parent.completeOperation(task_op, @intCast(total));
            }
        };

        self.startWorkerOperation(op, WorkerTask.run) catch {
            op.deinit(self.allocator);
            return IoError.OutOfMemory;
        };

        return self.createOperationFuture(op);
    }

    fn accept(context: *anyopaque, listener_fd: posix.fd_t) IoError!Future {
        const self: *Self = @ptrCast(@alignCast(context));
        if (!is_windows) return IoError.NotSupported;

        const key = self.next_key.fetchAdd(1, .monotonic);
        const op = self.allocator.create(PendingOperation) catch return IoError.OutOfMemory;
        op.* = PendingOperation.init(.accept, key);
        op.fd = listener_fd;

        const WorkerTask = struct {
            fn run(parent: *Self, task_op: *PendingOperation) void {
                const fd = task_op.fd orelse {
                    task_op.markError(IoError.InvalidDescriptor);
                    parent.completeOperation(task_op, 0);
                    return;
                };
                _ = parent.operationDescriptorKind(task_op);

                if (builtin.os.tag == .windows) {
                    // Native Windows accept using ws2_32
                    const client_fd = platform.accept(fd, null, null);
                    if (client_fd == platform.INVALID_SOCKET) {
                        task_op.markError(IoError.Unexpected);
                        parent.completeOperation(task_op, 0);
                        return;
                    }

                    task_op.extra_fd = client_fd;
                    parent.registerSocket(client_fd) catch {};
                    parent.completeOperation(task_op, 1);
                    return;
                }

                const client_fd = std.posix.accept(fd, null, null, 0) catch |err| {
                    task_op.markError(mapPosixError(err));
                    parent.completeOperation(task_op, 0);
                    return;
                };

                task_op.extra_fd = client_fd;
                parent.registerSocket(client_fd) catch {};
                parent.completeOperation(task_op, 1);
            }
        };

        self.startWorkerOperation(op, WorkerTask.run) catch {
            op.deinit(self.allocator);
            return IoError.OutOfMemory;
        };

        return self.createOperationFuture(op);
    }

    fn connect(context: *anyopaque, fd: posix.fd_t, address: *const posix.sockaddr, addr_len: posix.socklen_t) IoError!Future {
        const self: *Self = @ptrCast(@alignCast(context));
        if (!is_windows) return IoError.NotSupported;

        const key = self.next_key.fetchAdd(1, .monotonic);
        const op = self.allocator.create(PendingOperation) catch return IoError.OutOfMemory;
        op.* = PendingOperation.init(.connect, key);
        op.fd = fd;
        op.addr_len = addr_len;

        var storage = std.mem.zeroes(windows.ws2_32.sockaddr.storage);
        const src_bytes: [*]const u8 = @ptrCast(address);
        const dst_bytes: [*]u8 = @ptrCast(&storage);
        @memcpy(dst_bytes[0..addr_len], src_bytes[0..addr_len]);
        op.addr_storage = storage;

        const WorkerTask = struct {
            fn run(parent: *Self, task_op: *PendingOperation) void {
                const socket_fd = task_op.fd orelse {
                    task_op.markError(IoError.InvalidDescriptor);
                    parent.completeOperation(task_op, 0);
                    return;
                };
                _ = parent.operationDescriptorKind(task_op);
                const addr_storage = task_op.addr_storage orelse {
                    task_op.markError(IoError.Unexpected);
                    parent.completeOperation(task_op, 0);
                    return;
                };

                if (builtin.os.tag == .windows) {
                    // Native Windows connect using ws2_32
                    const sockaddr_ptr: *const platform.sockaddr = @ptrCast(&addr_storage);
                    const result = platform.connect(socket_fd, sockaddr_ptr, @intCast(task_op.addr_len));
                    if (result == platform.SOCKET_ERROR) {
                        task_op.markError(IoError.ConnectionRefused);
                        parent.completeOperation(task_op, 0);
                        return;
                    }

                    parent.completeOperation(task_op, 0);
                    return;
                }

                const sockaddr_ptr: *const posix.sockaddr = @ptrCast(&addr_storage);
                std.posix.connect(socket_fd, sockaddr_ptr, task_op.addr_len) catch |err| {
                    task_op.markError(mapPosixError(err));
                    parent.completeOperation(task_op, 0);
                    return;
                };

                parent.completeOperation(task_op, 0);
            }
        };

        self.startWorkerOperation(op, WorkerTask.run) catch {
            op.deinit(self.allocator);
            return IoError.OutOfMemory;
        };

        return self.createOperationFuture(op);
    }

    fn close_fd(context: *anyopaque, fd: posix.fd_t) IoError!Future {
        const self: *Self = @ptrCast(@alignCast(context));
        if (!is_windows) return IoError.NotSupported;

        const key = self.next_key.fetchAdd(1, .monotonic);
        const op = self.allocator.create(PendingOperation) catch return IoError.OutOfMemory;
        op.* = PendingOperation.init(.close, key);
        op.fd = fd;

        const WorkerTask = struct {
            fn run(parent: *Self, task_op: *PendingOperation) void {
                const close_fd_value = task_op.fd orelse {
                    task_op.markError(IoError.InvalidDescriptor);
                    parent.completeOperation(task_op, 0);
                    return;
                };

                if (builtin.os.tag == .windows) {
                    // Native Windows close - use closesocket for sockets, CloseHandle for files
                    const kind = parent.descriptorKind(close_fd_value);
                    if (kind == .socket) {
                        _ = platform.closesocket(close_fd_value);
                    } else {
                        _ = platform.CloseHandle(close_fd_value);
                    }
                    parent.completeOperation(task_op, 0);
                    return;
                }

                std.Io.Threaded.closeFd(close_fd_value);
                parent.completeOperation(task_op, 0);
            }
        };

        self.startWorkerOperation(op, WorkerTask.run) catch {
            op.deinit(self.allocator);
            return IoError.OutOfMemory;
        };

        return self.createOperationFuture(op);
    }

    fn shutdown(context: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(context));
        self.shutdown_flag.store(true, .release);
        if (is_windows) self.iocp.postQueuedCompletionStatus(0, 0, null) catch {};
    }

    fn getMode(_: *anyopaque) io_interface.IoMode {
        return if (is_windows) .evented else .blocking;
    }

    fn getAllocator(context: *anyopaque) std.mem.Allocator {
        const self: *Self = @ptrCast(@alignCast(context));
        return self.allocator;
    }

    fn supportsVectorized(_: *anyopaque) bool {
        return false;
    }

    fn supportsZeroCopy(_: *anyopaque) bool {
        return false;
    }

    pub fn pollCompletions(self: *Self, timeout_ms: u32) !usize {
        if (!is_windows) return 0;

        var completed_count: usize = 0;
        var bytes_transferred: u32 = undefined;
        var completion_key: usize = undefined;
        var overlapped_ptr: *platform.OVERLAPPED = undefined;

        while (true) {
            const has_completion = self.iocp.getQueuedCompletionStatus(
                &bytes_transferred,
                &completion_key,
                &overlapped_ptr,
                timeout_ms,
            ) catch |err| {
                if (err == error.GetCompletionStatusFailed) break;
                continue;
            };

            if (!has_completion) break;

            if (completion_key != 0) {
                self.mutex.lock();
                if (self.pending_ops.get(completion_key)) |op| {
                    if (op.err == null) op.markComplete(bytes_transferred) else op.completed.store(true, .release);
                    completed_count += 1;
                }
                self.mutex.unlock();
            }
        }

        return completed_count;
    }

    pub fn pendingCount(self: *Self) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.pending_ops.count();
    }
};

pub fn createWindowsIocpIo(allocator: std.mem.Allocator, thread_count: u32) !WindowsIocpIo {
    return WindowsIocpIo.init(allocator, thread_count);
}

test "WindowsIocpIo creation" {
    if (!is_windows) return;

    const allocator = std.testing.allocator;
    var iocp_io = try WindowsIocpIo.init(allocator, 4);
    defer iocp_io.deinit();

    const io_instance = iocp_io.io();
    try std.testing.expect(io_instance.getMode() == .evented);
    try std.testing.expect(!io_instance.supportsVectorized());
    try std.testing.expect(!io_instance.supportsZeroCopy());
}

test "WindowsIocpIo pending operations" {
    if (!is_windows) return;

    const allocator = std.testing.allocator;
    var iocp_io = try WindowsIocpIo.init(allocator, 4);
    defer iocp_io.deinit();

    try std.testing.expectEqual(@as(usize, 0), iocp_io.pendingCount());
}

test "WindowsIocpIo descriptor registration" {
    if (!is_windows) return;

    const allocator = std.testing.allocator;
    var iocp_io = try WindowsIocpIo.init(allocator, 2);
    defer iocp_io.deinit();

    try std.testing.expect(iocp_io.descriptorKind(11) == .unknown);
    try iocp_io.registerSocket(11);
    try std.testing.expect(iocp_io.descriptorKind(11) == .socket);

    try iocp_io.registerFile(12);
    try std.testing.expect(iocp_io.descriptorKind(12) == .file);
}

test "WindowsIocpIo unsupported future fails immediately" {
    if (!is_windows) return;

    const allocator = std.testing.allocator;
    var iocp_io = try WindowsIocpIo.init(allocator, 2);
    defer iocp_io.deinit();

    var io = iocp_io.io();
    var future = try io.accept(0);
    defer future.destroy();

    const result = future.poll();
    try std.testing.expect(result == .pending or result == .ready or result == .err);
}
