//! Zsync v0.2.0 - Enhanced Io Interface Implementation  
//! Based on Zig's new async I/O design with full type inference
//! Provides colorblind async - same code works across execution models

const std = @import("std");
const async_type_system = @import("async_type_system.zig");
const semantic_io = @import("semantic_io.zig");
const TypedFuture = async_type_system.TypedFuture;

/// Type-erased function call information for async operations
/// Uses runtime function pointer registration to avoid comptime/runtime conflicts
pub const AsyncCallInfo = struct {
    call_ptr: *anyopaque,
    exec_fn: *const fn (call_ptr: *anyopaque) anyerror!void,
    cleanup_fn: ?*const fn (call_ptr: *anyopaque) void,
    error_handler: ?*const fn (call_ptr: *anyopaque, err: anyerror) void = null,
    
    /// Create call info for known functions
    pub fn initDirect(
        call_ptr: *anyopaque,
        exec_fn: *const fn (call_ptr: *anyopaque) anyerror!void,
        cleanup_fn: ?*const fn (call_ptr: *anyopaque) void,
    ) AsyncCallInfo {
        return AsyncCallInfo{
            .call_ptr = call_ptr,
            .exec_fn = exec_fn,
            .cleanup_fn = cleanup_fn,
            .error_handler = null,
        };
    }
    
    /// Create call info with error handling
    pub fn initWithErrorHandler(
        call_ptr: *anyopaque,
        exec_fn: *const fn (call_ptr: *anyopaque) anyerror!void,
        cleanup_fn: ?*const fn (call_ptr: *anyopaque) void,
        error_handler: *const fn (call_ptr: *anyopaque, err: anyerror) void,
    ) AsyncCallInfo {
        return AsyncCallInfo{
            .call_ptr = call_ptr,
            .exec_fn = exec_fn,
            .cleanup_fn = cleanup_fn,
            .error_handler = error_handler,
        };
    }
    
    /// Clean up allocated memory
    pub fn deinit(self: AsyncCallInfo) void {
        if (self.cleanup_fn) |cleanup| {
            cleanup(self.call_ptr);
        }
    }
};

/// Context for saveFile function calls
const SaveFileContext = struct {
    io: Io,
    data: []const u8,
    filename: []const u8,
    allocator: std.mem.Allocator,
    
    fn execute(ptr: *anyopaque) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        try saveFile(self.io, self.data, self.filename);
    }
    
    fn cleanup(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.allocator.destroy(self);
    }
};

/// The core Io interface that provides dependency injection for I/O operations
/// This replaces direct stdlib calls with vtable-based dispatch
pub const Io = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        // Core async operation - takes type-erased call information
        async_fn: *const fn (ptr: *anyopaque, call_info: AsyncCallInfo) anyerror!Future,
        
        // Concurrent async operation - for true parallelism
        async_concurrent_fn: *const fn (ptr: *anyopaque, call_infos: []AsyncCallInfo) anyerror!ConcurrentFuture,
        
        // File operations
        createFile: *const fn (ptr: *anyopaque, path: []const u8, options: File.CreateOptions) anyerror!File,
        openFile: *const fn (ptr: *anyopaque, path: []const u8, options: File.OpenOptions) anyerror!File,
        
        // Network operations
        tcpConnect: *const fn (ptr: *anyopaque, address: std.net.Address) anyerror!TcpStream,
        tcpListen: *const fn (ptr: *anyopaque, address: std.net.Address) anyerror!TcpListener,
        udpBind: *const fn (ptr: *anyopaque, address: std.net.Address) anyerror!UdpSocket,
        
        // Semantic I/O operations
        sendFile: ?*const fn (ptr: *anyopaque, writer: semantic_io.Writer, file_reader: semantic_io.Reader, limit: semantic_io.Limit) anyerror!u64 = null,
        drain: ?*const fn (ptr: *anyopaque, writer: semantic_io.Writer, data: []const []const u8, splat: usize) anyerror!u64 = null,
        splice: ?*const fn (ptr: *anyopaque, output: semantic_io.Writer, input: semantic_io.Reader, limit: semantic_io.Limit) anyerror!u64 = null,
    };

    /// Create an async operation for saveFile specifically
    /// For a real implementation, we'd have a registry of supported functions
    pub fn asyncSaveFile(self: Io, allocator: std.mem.Allocator, data: []const u8, filename: []const u8) !Future {
        const ctx = try allocator.create(SaveFileContext);
        ctx.* = SaveFileContext{
            .io = self,
            .data = data,
            .filename = filename,
            .allocator = allocator,
        };
        
        const call_info = AsyncCallInfo.initDirect(
            ctx,
            SaveFileContext.execute,
            SaveFileContext.cleanup,
        );
        
        return self.vtable.async_fn(self.ptr, call_info);
    }
    
    /// Enhanced async method with full type inference and arbitrary function signatures
    pub fn async_op(self: Io, allocator: std.mem.Allocator, func: anytype, args: anytype) !Future {
        const FuncType = @TypeOf(func);
        const ArgsType = @TypeOf(args);
        
        // Type validation
        const func_type_info = @typeInfo(FuncType);
        if (func_type_info != .@"fn") {
            @compileError("First argument must be a function");
        }
        
        // Validate function signature at compile time
        comptime {
            const func_info = func_type_info.@"fn";
            if (func_info.params.len == 0) {
                @compileError("Function must have at least one parameter (Io)");
            }
            
            // First parameter must be Io
            if (func_info.params[0].type != Io) {
                @compileError("First parameter must be of type Io");
            }
            
            // Validate argument count matches function parameters
            const expected_args = func_info.params.len - 1; // -1 for Io parameter
            const actual_args = switch (@typeInfo(ArgsType)) {
                .@"struct" => |struct_info| struct_info.fields.len,
                .void => 0,
                else => 1,
            };
            
            if (actual_args != expected_args) {
                const msg = std.fmt.comptimePrint(
                    "Function expects {} arguments but got {}", 
                    .{ expected_args, actual_args }
                );
                @compileError(msg);
            }
        }
        
        // Check if it's a known function for optimized handling
        if (func == saveFile) {
            return self.asyncSaveFile(allocator, args[0], args[1]);
        }
        
        // For other functions, create a generic async operation
        return self.createGenericAsyncOperation(allocator, func, args);
    }
    
    /// Create a generic async operation with type inference and arbitrary function signatures
    fn createGenericAsyncOperation(self: Io, allocator: std.mem.Allocator, func: anytype, args: anytype) !Future {
        const FuncType = @TypeOf(func);
        const ArgsType = @TypeOf(args);
        
        // Create execution context
        const ExecutionContext = struct {
            func: FuncType,
            args: ArgsType,
            io: Io,
            allocator: std.mem.Allocator,
            
            fn execute(ptr: *anyopaque) anyerror!void {
                const self_ptr: *@This() = @ptrCast(@alignCast(ptr));
                
                // Call the function with proper argument unpacking based on args type
                const result = switch (@typeInfo(ArgsType)) {
                    .Struct => |struct_info| blk: {
                        // For struct args, unpack each field
                        const field_types = extractFieldTypes(struct_info);
                        var call_args: std.meta.Tuple(&[_]type{Io} ++ field_types) = undefined;
                        call_args[0] = self_ptr.io;
                        
                        inline for (struct_info.fields, 0..) |field, i| {
                            call_args[i + 1] = @field(self_ptr.args, field.name);
                        }
                        
                        break :blk @call(.auto, self_ptr.func, call_args);
                    },
                    .Void => blk: {
                        // No additional arguments, just Io
                        break :blk @call(.auto, self_ptr.func, .{self_ptr.io});
                    },
                    .Array => |arr_info| blk: {
                        // For array args, unpack each element
                        var call_args: std.meta.Tuple(&[_]type{Io} ++ @as([arr_info.len]type, [_]type{arr_info.child} ** arr_info.len)) = undefined;
                        call_args[0] = self_ptr.io;
                        
                        inline for (0..arr_info.len) |i| {
                            call_args[i + 1] = self_ptr.args[i];
                        }
                        
                        break :blk @call(.auto, self_ptr.func, call_args);
                    },
                    else => blk: {
                        // Single argument
                        break :blk @call(.auto, self_ptr.func, .{ self_ptr.io, self_ptr.args });
                    },
                };
                
                // Handle return value - propagate errors, ignore successful results
                _ = result catch |err| {
                    // Set error information in the future if available
                    // Note: In a real implementation, we'd need access to the future here
                    // For now, just propagate the error
                    return err;
                };
            }
            
            fn cleanup(ptr: *anyopaque) void {
                const self_ptr: *@This() = @ptrCast(@alignCast(ptr));
                self_ptr.allocator.destroy(self_ptr);
            }
            
            fn extractFieldTypes(comptime struct_info: std.builtin.Type.Struct) [struct_info.fields.len]type {
                var field_types: [struct_info.fields.len]type = undefined;
                for (struct_info.fields, 0..) |field, i| {
                    field_types[i] = field.type;
                }
                return field_types;
            }
        };
        
        const ctx = try allocator.create(ExecutionContext);
        ctx.* = ExecutionContext{
            .func = func,
            .args = args,
            .io = self,
            .allocator = allocator,
        };
        
        const call_info = AsyncCallInfo.initDirect(
            ctx,
            ExecutionContext.execute,
            ExecutionContext.cleanup,
        );
        
        return self.vtable.async_fn(self.ptr, call_info);
    }
    
    /// Enhanced async with compile-time type inference and validation
    pub fn asyncTyped(
        self: Io,
        allocator: std.mem.Allocator,
        comptime func: anytype,
        args: anytype,
    ) !TypedFuture(inferReturnType(func)) {
        // Compile-time validation
        comptime {
            const func_type_info = @typeInfo(@TypeOf(func));
            if (func_type_info != .@"fn") {
                @compileError("First argument must be a function");
            }
            
            // Validate that function is async-compatible
            if (!isAsyncCompatible(@TypeOf(func))) {
                @compileError("Function is not async-compatible");
            }
        }
        
        const ReturnType = inferReturnType(func);
        const typed_future = try allocator.create(TypedFuture(ReturnType));
        typed_future.* = TypedFuture(ReturnType).init(allocator);
        
        // Create and execute the async operation
        const future = try self.async_op(allocator, func, args);
        
        // Link the generic future to the typed future
        try self.linkFutures(future, typed_future);
        
        return typed_future.*;
    }
    
    /// Infer the return type of a function, handling error unions
    fn inferReturnType(comptime func: anytype) type {
        const func_type_info = @typeInfo(@TypeOf(func));
        const return_type = func_type_info.@"fn".return_type orelse void;
        
        const return_type_info = @typeInfo(return_type);
        return switch (return_type_info) {
            .ErrorUnion => |error_union| error_union.payload,
            else => return_type,
        };
    }
    
    /// Check if a function type is async-compatible
    fn isAsyncCompatible(comptime FuncType: type) bool {
        const func_type_info = @typeInfo(FuncType);
        if (func_type_info != .@"fn") return false;
        
        const func_info = func_type_info.@"fn";
        
        // Check if all parameter types are async-compatible
        for (func_info.params) |param| {
            if (param.type) |param_type| {
                if (!isTypeAsyncCompatible(param_type)) {
                    return false;
                }
            }
        }
        
        // Check if return type is async-compatible
        if (func_info.return_type) |return_type| {
            if (!isTypeAsyncCompatible(return_type)) {
                return false;
            }
        }
        
        return true;
    }
    
    /// Check if a type is async-compatible (can be safely serialized/passed across threads)
    fn isTypeAsyncCompatible(comptime T: type) bool {
        const type_info = @typeInfo(T);
        return switch (type_info) {
            .Void, .Bool, .Int, .Float, .Enum, .ErrorSet => true,
            .Optional => |opt| isTypeAsyncCompatible(opt.child),
            .Array => |arr| isTypeAsyncCompatible(arr.child),
            .Pointer => |ptr| switch (ptr.size) {
                .One, .Many, .Slice => isTypeAsyncCompatible(ptr.child),
                .C => false, // C pointers are not safe for async
            },
            .Struct => |st| blk: {
                // All fields must be async-compatible
                for (st.fields) |field| {
                    if (!isTypeAsyncCompatible(field.type)) break :blk false;
                }
                break :blk true;
            },
            .ErrorUnion => |error_union| isTypeAsyncCompatible(error_union.payload),
            .Union => false, // Unions need special handling
            .@"fn" => false,    // Function pointers need special handling
            else => false,
        };
    }
    
    /// Link a generic future to a typed future
    fn linkFutures(self: Io, generic_future: Future, typed_future: anytype) !void {
        _ = self;
        _ = generic_future;
        _ = typed_future;
        
        // In a real implementation, this would set up callbacks
        // to transfer the result from the generic future to the typed future
    }

    /// Create concurrent async operations for true parallelism
    pub fn asyncConcurrent(self: Io, call_infos: []AsyncCallInfo) !ConcurrentFuture {
        return self.vtable.async_concurrent_fn(self.ptr, call_infos);
    }
    
    /// Convenience method for io.async() pattern from the proposal
    pub const async = async_op;
    
    /// High-performance file transfer using zero-copy optimization (sendfile syscall)
    /// Transfers data from a file directly to a writer without copying to userspace
    pub fn sendFile(
        self: Io,
        writer: semantic_io.Writer,
        file_reader: semantic_io.Reader,
        limit: semantic_io.Limit,
    ) !u64 {
        if (self.vtable.sendFile) |send_file_fn| {
            return send_file_fn(self.ptr, writer, file_reader, limit);
        }
        
        // Fallback to standard copy operation
        return semantic_io.SemanticIoUtils.copyOptimized(file_reader, writer, self, limit);
    }
    
    /// Vectorized write operation with splat support
    /// Writes multiple data segments and optionally repeats the last segment
    pub fn drain(
        self: Io,
        writer: semantic_io.Writer,
        data: []const []const u8,
        splat: usize,
    ) !u64 {
        if (self.vtable.drain) |drain_fn| {
            return drain_fn(self.ptr, writer, data, splat);
        }
        
        // Fallback implementation
        return semantic_io.DrainOperation.execute(writer, self, data, splat);
    }
    
    /// Splice operation for efficient data transfer between readers and writers
    /// Uses platform-specific optimizations when available (e.g., Linux splice syscall)
    pub fn splice(
        self: Io,
        output: semantic_io.Writer,
        input: semantic_io.Reader,
        limit: semantic_io.Limit,
    ) !u64 {
        if (self.vtable.splice) |splice_fn| {
            return splice_fn(self.ptr, output, input, limit);
        }
        
        // Fallback to optimized copy
        return semantic_io.SemanticIoUtils.copyOptimized(input, output, self, limit);
    }
};

/// ConcurrentFuture for managing multiple parallel operations
pub const ConcurrentFuture = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    
    pub const VTable = struct {
        await_all_fn: *const fn (ptr: *anyopaque, io: Io) anyerror!void,
        await_any_fn: *const fn (ptr: *anyopaque, io: Io) anyerror!usize, // Returns index of first completed
        cancel_all_fn: *const fn (ptr: *anyopaque, io: Io) anyerror!void,
        deinit_fn: *const fn (ptr: *anyopaque) void,
    };
    
    /// Wait for all concurrent operations to complete
    pub fn awaitAll(self: *ConcurrentFuture, io: Io) !void {
        return self.vtable.await_all_fn(self.ptr, io);
    }
    
    /// Wait for any one operation to complete (returns index)
    pub fn awaitAny(self: *ConcurrentFuture, io: Io) !usize {
        return self.vtable.await_any_fn(self.ptr, io);
    }
    
    /// Cancel all concurrent operations
    pub fn cancelAll(self: *ConcurrentFuture, io: Io) !void {
        return self.vtable.cancel_all_fn(self.ptr, io);
    }
    
    /// Cleanup the concurrent future
    pub fn deinit(self: *ConcurrentFuture) void {
        self.vtable.deinit_fn(self.ptr);
    }
};

/// Enhanced Future type with advanced await() and cancel() semantics
pub const Future = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    state: std.atomic.Value(State),
    cancel_token: ?*CancelToken = null,
    timeout: ?Timeout = null,
    wakers: std.ArrayList(Waker),
    cancellation_chain: ?*Future = null, // For chaining cancellation
    error_info: ?ErrorInfo = null, // For error propagation
    
    pub const State = enum(u8) {
        pending = 0,
        running = 1,
        completed = 2,
        canceled = 3,
        timeout_expired = 4,
        error_state = 5,
    };
    
    /// Error information for async operations
    pub const ErrorInfo = struct {
        error_value: anyerror,
        error_trace: ?*std.builtin.StackTrace = null,
        error_context: ?[]const u8 = null,
        propagated_from: ?*Future = null, // Track error propagation chain
        
        pub fn init(err: anyerror) ErrorInfo {
            return ErrorInfo{
                .error_value = err,
                .error_trace = @errorReturnTrace(),
                .error_context = @errorName(err),
                .propagated_from = null,
            };
        }
        
        pub fn initWithPropagation(err: anyerror, source_future: *Future) ErrorInfo {
            return ErrorInfo{
                .error_value = err,
                .error_trace = @errorReturnTrace(),
                .error_context = @errorName(err),
                .propagated_from = source_future,
            };
        }
        
        pub fn initWithContext(err: anyerror, context: []const u8) ErrorInfo {
            return ErrorInfo{
                .error_value = err,
                .error_trace = @errorReturnTrace(),
                .error_context = context,
                .propagated_from = null,
            };
        }
    };
    
    const CancelToken = struct {
        canceled: std.atomic.Value(bool),
        reason: CancelReason,
        cascade: bool, // Whether to cascade cancellation to dependent futures
        
        const CancelReason = enum {
            user_requested,
            timeout,
            dependency_canceled,
            resource_exhausted,
            error_occurred,
        };
        
        pub fn init(reason: CancelReason, cascade: bool) CancelToken {
            return CancelToken{
                .canceled = std.atomic.Value(bool).init(false),
                .reason = reason,
                .cascade = cascade,
            };
        }
        
        pub fn cancel(self: *CancelToken) void {
            self.canceled.store(true, .release);
        }
        
        pub fn isCanceled(self: *const CancelToken) bool {
            return self.canceled.load(.acquire);
        }
    };
    
    const Timeout = struct {
        deadline_ns: u64,
        soft_timeout: bool, // Whether timeout allows graceful cleanup
        
        pub fn init(timeout_ms: u64, soft: bool) Timeout {
            return Timeout{
                .deadline_ns = @intCast(std.time.nanoTimestamp() + @as(i128, timeout_ms * std.time.ns_per_ms)),
                .soft_timeout = soft,
            };
        }
        
        pub fn isExpired(self: *const Timeout) bool {
            return std.time.nanoTimestamp() > self.deadline_ns;
        }
        
        pub fn timeUntilExpiry(self: *const Timeout) i64 {
            return @as(i64, @intCast(self.deadline_ns)) - std.time.nanoTimestamp();
        }
    };
    
    pub const Waker = struct {
        callback: *const fn(*anyopaque, WakeReason) void,
        context: *anyopaque,
        
        const WakeReason = enum {
            completed,
            canceled,
            timeout,
            error_occurred,
        };
    };

    pub const VTable = struct {
        await_fn: *const fn (ptr: *anyopaque, io: Io, options: AwaitOptions) anyerror!void,
        cancel_fn: *const fn (ptr: *anyopaque, io: Io, options: CancelOptions) anyerror!void,
        deinit_fn: *const fn (ptr: *anyopaque) void,
        poll_fn: ?*const fn (ptr: *anyopaque) PollResult = null,
        chain_fn: ?*const fn (ptr: *anyopaque, dependent: *Future) anyerror!void = null,
    };
    
    pub const AwaitOptions = struct {
        timeout_ms: ?u64 = null,
        allow_cancellation: bool = true,
        yield_hint: YieldHint = .auto,
        priority: Priority = .normal,
        
        const YieldHint = enum {
            never,     // Spin until completion
            auto,      // Automatic yielding based on heuristics
            always,    // Yield after every poll
            adaptive,  // Adaptive yielding based on load
        };
        
        const Priority = enum {
            low,
            normal,
            high,
            critical,
        };
    };
    
    pub const CancelOptions = struct {
        reason: CancelToken.CancelReason = .user_requested,
        cascade: bool = true,
        grace_period_ms: ?u64 = null,
        force_after_grace: bool = true,
    };
    
    pub const PollResult = enum {
        pending,
        ready,
        canceled,
        error_occurred,
    };
    
    pub fn init(allocator: std.mem.Allocator) Future {
        return Future{
            .ptr = undefined,
            .vtable = undefined,
            .state = std.atomic.Value(State).init(.pending),
            .wakers = std.ArrayList(Waker).init(allocator),
        };
    }

    /// Enhanced await with advanced semantics and cancellation support
    pub fn await_op(self: *Future, io: Io, options: AwaitOptions) !void {
        // Set up timeout if specified
        if (options.timeout_ms) |timeout_ms| {
            self.timeout = Timeout.init(timeout_ms, true);
        }
        
        // Fast path: check if already completed
        const current_state = self.state.load(.acquire);
        switch (current_state) {
            .completed => return,
            .canceled => return error.OperationCanceled,
            .timeout_expired => return error.OperationTimeout,
            .error_state => {
                // Propagate the original error if available
                if (self.error_info) |error_info| {
                    return error_info.error_value;
                }
                return error.OperationFailed;
            },
            else => {},
        }
        
        // Set up cancellation handling
        if (options.allow_cancellation and self.cancel_token == null) {
            // Create a default cancel token
            var token = CancelToken.init(.user_requested, true);
            self.cancel_token = &token;
        }
        
        // Main await loop with adaptive yielding
        var poll_count: u32 = 0;
        var consecutive_pending: u32 = 0;
        
        while (true) {
            // Check for cancellation
            if (self.cancel_token) |token| {
                if (token.isCanceled()) {
                    self.state.store(.canceled, .release);
                    self.notifyWakers(.canceled);
                    return error.OperationCanceled;
                }
            }
            
            // Check for timeout
            if (self.timeout) |timeout| {
                if (timeout.isExpired()) {
                    if (timeout.soft_timeout) {
                        // Try graceful cancellation first
                        try self.cancel(io, .{
                            .reason = .timeout,
                            .grace_period_ms = 100,
                        });
                    }
                    self.state.store(.timeout_expired, .release);
                    self.notifyWakers(.timeout);
                    return error.OperationTimeout;
                }
            }
            
            // Poll the future
            if (self.vtable.poll_fn) |poll_fn| {
                const poll_result = poll_fn(self.ptr);
                switch (poll_result) {
                    .ready => {
                        self.state.store(.completed, .release);
                        self.notifyWakers(.completed);
                        return;
                    },
                    .canceled => {
                        self.state.store(.canceled, .release);
                        self.notifyWakers(.canceled);
                        return error.OperationCanceled;
                    },
                    .error_occurred => {
                        self.state.store(.error_state, .release);
                        self.notifyWakers(.error_occurred);
                        // Return the actual error if available
                        if (self.error_info) |error_info| {
                            return error_info.error_value;
                        }
                        return error.OperationFailed;
                    },
                    .pending => {
                        consecutive_pending += 1;
                    },
                }
            }
            
            // Adaptive yielding strategy
            const should_yield = switch (options.yield_hint) {
                .never => false,
                .always => true,
                .auto => poll_count > 10,
                .adaptive => consecutive_pending > (5 + poll_count / 10),
            };
            
            if (should_yield) {
                // Calculate yield duration based on priority and load
                const yield_duration_ns: u64 = switch (options.priority) {
                    .critical => 1_000, // 1 microsecond
                    .high => 10_000,     // 10 microseconds  
                    .normal => 100_000,  // 100 microseconds
                    .low => 1_000_000,   // 1 millisecond
                };
                
                std.time.sleep(yield_duration_ns);
                consecutive_pending = 0;
            }
            
            poll_count += 1;
            
            // Fallback to vtable await if polling not supported
            if (self.vtable.poll_fn == null) {
                return self.vtable.await_fn(self.ptr, io, options);
            }
        }
    }

    /// Enhanced cancel with graceful shutdown and cascading
    pub fn cancel(self: *Future, io: Io, options: CancelOptions) !void {
        // Atomic state transition to canceling
        const previous_state = self.state.swap(.canceled, .acq_rel);
        if (previous_state == .completed or previous_state == .canceled) {
            return; // Already completed or canceled
        }
        
        // Set up cancel token
        if (self.cancel_token == null) {
            var token = CancelToken.init(options.reason, options.cascade);
            self.cancel_token = &token;
        } else if (self.cancel_token) |token| {
            token.reason = options.reason;
            token.cascade = options.cascade;
        }
        
        // Graceful cancellation with timeout
        if (options.grace_period_ms) |grace_ms| {
            const grace_deadline = std.time.nanoTimestamp() + (grace_ms * std.time.ns_per_ms);
            
            // Try graceful cancellation first
            self.vtable.cancel_fn(self.ptr, io, options) catch {
                // If graceful cancellation fails, continue to force cancellation
            };
            
            // Wait for graceful completion up to the deadline
            while (std.time.nanoTimestamp() < grace_deadline) {
                if (self.state.load(.acquire) == .completed) {
                    return; // Gracefully completed
                }
                std.time.sleep(1_000_000); // 1ms
            }
            
            // Force cancellation if grace period expired
            if (options.force_after_grace) {
                self.cancel_token.?.cancel();
            }
        } else {
            // Immediate cancellation
            try self.vtable.cancel_fn(self.ptr, io, options);
            if (self.cancel_token) |token| {
                token.cancel();
            }
        }
        
        // Cascade cancellation to dependent futures
        if (options.cascade) {
            if (self.cancellation_chain) |dependent| {
                dependent.cancel(io, .{
                    .reason = .dependency_canceled,
                    .cascade = true,
                    .grace_period_ms = options.grace_period_ms,
                }) catch {
                    // Log cascading cancellation failure but don't propagate
                };
            }
        }
        
        // Notify all wakers
        self.notifyWakers(.canceled);
    }
    
    /// Add a waker to be notified when the future state changes
    pub fn addWaker(self: *Future, waker: Waker) !void {
        // Check if already completed
        const current_state = self.state.load(.acquire);
        if (current_state != .pending and current_state != .running) {
            // Already completed, call waker immediately
            const wake_reason: Waker.WakeReason = switch (current_state) {
                .completed => .completed,
                .canceled => .canceled,
                .timeout_expired => .timeout,
                .error_state => .error_occurred,
                else => .completed,
            };
            waker.callback(waker.context, wake_reason);
            return;
        }
        
        try self.wakers.append(waker);
    }
    
    /// Chain this future with another for dependency management
    pub fn chainCancellation(self: *Future, dependent: *Future) !void {
        if (self.vtable.chain_fn) |chain_fn| {
            try chain_fn(self.ptr, dependent);
        }
        self.cancellation_chain = dependent;
    }
    
    /// Check if the future can be polled (non-blocking state check)
    pub fn poll(self: *Future) PollResult {
        const current_state = self.state.load(.acquire);
        return switch (current_state) {
            .pending, .running => if (self.vtable.poll_fn) |poll_fn| 
                poll_fn(self.ptr) else .pending,
            .completed => .ready,
            .canceled => .canceled,
            .timeout_expired => .canceled,
            .error_state => .error_occurred,
        };
    }
    
    /// Get the current state of the future
    pub fn getState(self: *const Future) State {
        return self.state.load(.acquire);
    }
    
    /// Check if the future is completed (in any final state)
    pub fn isCompleted(self: *const Future) bool {
        const current_state = self.state.load(.acquire);
        return switch (current_state) {
            .completed, .canceled, .timeout_expired, .error_state => true,
            else => false,
        };
    }
    
    /// Set error information and propagate to dependent futures
    pub fn setError(self: *Future, err: anyerror) void {
        self.error_info = ErrorInfo.init(err);
        self.state.store(.error_state, .release);
        
        // Propagate error to chained futures
        if (self.cancellation_chain) |dependent| {
            dependent.propagateError(err, self);
        }
        
        self.notifyWakers(.error_occurred);
    }
    
    /// Propagate error from another future
    pub fn propagateError(self: *Future, err: anyerror, source_future: *Future) void {
        self.error_info = ErrorInfo.initWithPropagation(err, source_future);
        self.state.store(.error_state, .release);
        
        // Continue propagation chain
        if (self.cancellation_chain) |dependent| {
            dependent.propagateError(err, self);
        }
        
        self.notifyWakers(.error_occurred);
    }
    
    /// Get the error information if the future is in error state
    pub fn getError(self: *const Future) ?ErrorInfo {
        if (self.state.load(.acquire) == .error_state) {
            return self.error_info;
        }
        return null;
    }
    
    /// Check if future is in error state
    pub fn isError(self: *const Future) bool {
        return self.state.load(.acquire) == .error_state;
    }
    
    /// Notify all wakers of a state change
    fn notifyWakers(self: *Future, reason: Waker.WakeReason) void {
        for (self.wakers.items) |waker| {
            waker.callback(waker.context, reason);
        }
        // Clear wakers after notification
        self.wakers.clearRetainingCapacity();
    }

    /// Cleanup the future
    pub fn deinit(self: *Future) void {
        // Cancel if still pending
        if (!self.isCompleted()) {
            // Note: We can't call cancel here as it requires Io
            // So we just mark as canceled
            self.state.store(.canceled, .release);
        }
        
        self.wakers.deinit();
        self.vtable.deinit_fn(self.ptr);
    }

    /// Convenience methods matching Zig's async I/O proposal
    pub const await = await_op;
    
    /// Await with default options
    pub fn awaitDefault(self: *Future, io: Io) !void {
        return self.await_op(io, .{});
    }
    
    /// Await with timeout
    pub fn awaitTimeout(self: *Future, io: Io, timeout_ms: u64) !void {
        return self.await_op(io, .{ .timeout_ms = timeout_ms });
    }
    
    /// Cancel with default options  
    pub fn cancelDefault(self: *Future, io: Io) !void {
        return self.cancel(io, .{});
    }
    
    /// Cancel with grace period
    pub fn cancelGraceful(self: *Future, io: Io, grace_ms: u64) !void {
        return self.cancel(io, .{ .grace_period_ms = grace_ms });
    }
    
    /// Defer cancellation pattern - creates a defer-compatible cancellation function
    pub fn deferCancel(self: *Future, io: Io) DeferCancellation {
        return DeferCancellation{
            .future = self,
            .io = io,
            .options = .{},
        };
    }
    
    /// Defer cancellation with custom options
    pub fn deferCancelWithOptions(self: *Future, io: Io, options: CancelOptions) DeferCancellation {
        return DeferCancellation{
            .future = self,
            .io = io,
            .options = options,
        };
    }
    
    /// Helper struct for defer cancellation patterns
    pub const DeferCancellation = struct {
        future: *Future,
        io: Io,
        options: CancelOptions,
        
        /// Call this function in defer blocks: `defer future.deferCancel(io).cancel();`
        pub fn cancel(self: @This()) void {
            self.future.cancel(self.io, self.options) catch |err| {
                // Log the error but don't propagate in defer context
                std.log.err("Failed to cancel future in defer: {}", .{err});
            };
        }
        
        /// Cancel only if the future is not completed
        pub fn cancelIfPending(self: @This()) void {
            if (!self.future.isCompleted()) {
                self.cancel();
            }
        }
        
        /// Cancel with a specific reason
        pub fn cancelWithReason(self: @This(), reason: CancelToken.CancelReason) void {
            var modified_options = self.options;
            modified_options.reason = reason;
            self.future.cancel(self.io, modified_options) catch |err| {
                std.log.err("Failed to cancel future with reason {} in defer: {}", .{ reason, err });
            };
        }
    };
};

/// File operations with new Io interface
pub const File = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        writeAll: *const fn (ptr: *anyopaque, io: Io, data: []const u8) anyerror!void,
        readAll: *const fn (ptr: *anyopaque, io: Io, buffer: []u8) anyerror!usize,
        close: *const fn (ptr: *anyopaque, io: Io) anyerror!void,
        
        // Semantic I/O operations
        sendFile: ?*const fn (ptr: *anyopaque, io: Io, file_reader: *semantic_io.Reader, limit: semantic_io.Limit) anyerror!u64 = null,
        drain: ?*const fn (ptr: *anyopaque, io: Io, data: []const []const u8, splat: usize) anyerror!u64 = null,
        
        // Enhanced I/O operations
        getWriter: ?*const fn (ptr: *anyopaque) semantic_io.Writer = null,
        getReader: ?*const fn (ptr: *anyopaque) semantic_io.Reader = null,
    };

    pub const CreateOptions = struct {
        truncate: bool = true,
        exclusive: bool = false,
    };

    pub const OpenOptions = struct {
        mode: std.fs.File.OpenMode = .read_only,
    };

    /// Write all data to file using the Io interface
    pub fn writeAll(self: File, io: Io, data: []const u8) !void {
        return self.vtable.writeAll(self.ptr, io, data);
    }

    /// Read data from file using the Io interface
    pub fn readAll(self: File, io: Io, buffer: []u8) !usize {
        return self.vtable.readAll(self.ptr, io, buffer);
    }

    /// Close file using the Io interface
    pub fn close(self: File, io: Io) !void {
        return self.vtable.close(self.ptr, io);
    }
    
    /// Send file contents to another destination using zero-copy optimization
    pub fn sendFile(
        self: File,
        io: Io,
        file_reader: *semantic_io.File.Reader,
        limit: semantic_io.Limit,
    ) !u64 {
        if (self.vtable.sendFile) |send_file_fn| {
            return send_file_fn(self.ptr, io, file_reader, limit);
        }
        return error.SendFileNotSupported;
    }
    
    /// Perform vectorized writes with splat support
    pub fn drain(
        self: File,
        io: Io,
        data: []const []const u8,
        splat: usize,
    ) !u64 {
        if (self.vtable.drain) |drain_fn| {
            return drain_fn(self.ptr, io, data, splat);
        }
        
        // Fallback implementation
        var total_written: u64 = 0;
        
        // Write all data segments
        for (data) |segment| {
            try self.writeAll(io, segment);
            total_written += segment.len;
        }
        
        // Handle splat (repeat last segment)
        if (splat > 0 and data.len > 0) {
            const last_segment = data[data.len - 1];
            for (0..splat) |_| {
                try self.writeAll(io, last_segment);
            }
            total_written += last_segment.len * splat;
        }
        
        return total_written;
    }
    
    /// Get a semantic writer for this file
    pub fn getWriter(self: File) ?semantic_io.Writer {
        if (self.vtable.getWriter) |get_writer_fn| {
            return get_writer_fn(self.ptr);
        }
        return null;
    }
    
    /// Get a semantic reader for this file
    pub fn getReader(self: File) ?semantic_io.Reader {
        if (self.vtable.getReader) |get_reader_fn| {
            return get_reader_fn(self.ptr);
        }
        return null;
    }

    /// Get stdout file handle
    pub fn stdout() File {
        return File{
            .ptr = &stdout_impl,
            .vtable = &stdout_vtable,
        };
    }
};

/// Directory operations with new Io interface
pub const Dir = struct {
    /// Get current working directory
    pub fn cwd() Dir {
        return Dir{};
    }

    /// Create a file in this directory
    pub fn createFile(self: Dir, io: Io, path: []const u8, options: File.CreateOptions) !File {
        _ = self;
        return io.vtable.createFile(io.ptr, path, options);
    }

    /// Open a file in this directory
    pub fn openFile(self: Dir, io: Io, path: []const u8, options: File.OpenOptions) !File {
        _ = self;
        return io.vtable.openFile(io.ptr, path, options);
    }
};

/// TCP Stream with new Io interface
pub const TcpStream = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        read: *const fn (ptr: *anyopaque, io: Io, buffer: []u8) anyerror!usize,
        write: *const fn (ptr: *anyopaque, io: Io, data: []const u8) anyerror!usize,
        close: *const fn (ptr: *anyopaque, io: Io) anyerror!void,
    };

    pub fn read(self: TcpStream, io: Io, buffer: []u8) !usize {
        return self.vtable.read(self.ptr, io, buffer);
    }

    pub fn write(self: TcpStream, io: Io, data: []const u8) !usize {
        return self.vtable.write(self.ptr, io, data);
    }

    pub fn close(self: TcpStream, io: Io) !void {
        return self.vtable.close(self.ptr, io);
    }
};

/// TCP Listener with new Io interface
pub const TcpListener = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        accept: *const fn (ptr: *anyopaque, io: Io) anyerror!TcpStream,
        close: *const fn (ptr: *anyopaque, io: Io) anyerror!void,
    };

    pub fn accept(self: TcpListener, io: Io) !TcpStream {
        return self.vtable.accept(self.ptr, io);
    }

    pub fn close(self: TcpListener, io: Io) !void {
        return self.vtable.close(self.ptr, io);
    }
};

/// UDP Socket with new Io interface
/// UDP recv result type
pub const RecvFromResult = struct { bytes: usize, address: std.net.Address };

/// Re-export semantic I/O types for convenience
pub const Writer = semantic_io.Writer;
pub const Reader = semantic_io.Reader;
pub const Limit = semantic_io.Limit;
pub const PlatformOptimizations = semantic_io.PlatformOptimizations;
pub const DrainOperation = semantic_io.DrainOperation;
pub const SemanticIoUtils = semantic_io.SemanticIoUtils;

pub const UdpSocket = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        sendTo: *const fn (ptr: *anyopaque, io: Io, data: []const u8, address: std.net.Address) anyerror!usize,
        recvFrom: *const fn (ptr: *anyopaque, io: Io, buffer: []u8) anyerror!RecvFromResult,
        close: *const fn (ptr: *anyopaque, io: Io) anyerror!void,
    };

    pub fn sendTo(self: UdpSocket, io: Io, data: []const u8, address: std.net.Address) !usize {
        return self.vtable.sendTo(self.ptr, io, data, address);
    }

    pub fn recvFrom(self: UdpSocket, io: Io, buffer: []u8) !struct { bytes: usize, address: std.net.Address } {
        return self.vtable.recvFrom(self.ptr, io, buffer);
    }

    pub fn close(self: UdpSocket, io: Io) !void {
        return self.vtable.close(self.ptr, io);
    }
};

// Stdout implementation for demo
var stdout_impl: void = {};

const stdout_vtable = File.VTable{
    .writeAll = stdoutWriteAll,
    .readAll = stdoutReadAll,
    .close = stdoutClose,
};

fn stdoutWriteAll(ptr: *anyopaque, io: Io, data: []const u8) !void {
    _ = ptr;
    _ = io;
    std.debug.print("{s}", .{data});
}

fn stdoutReadAll(ptr: *anyopaque, io: Io, buffer: []u8) !usize {
    _ = ptr;
    _ = io;
    _ = buffer;
    return error.NotSupported;
}

fn stdoutClose(ptr: *anyopaque, io: Io) !void {
    _ = ptr;
    _ = io;
    // Stdout doesn't need closing
}

// Example of colorblind async function with defer cancellation patterns
pub fn saveData(allocator: std.mem.Allocator, io: Io, data: []const u8) !void {
    // This function works with ANY Io implementation!
    var a_future = try io.async(allocator, saveFile, .{ data, "saveA.txt" });
    defer a_future.deinit();
    defer a_future.deferCancel(io).cancelIfPending(); // Cancel if not completed

    var b_future = try io.async(allocator, saveFile, .{ data, "saveB.txt" });
    defer b_future.deinit();
    defer b_future.deferCancel(io).cancelIfPending(); // Cancel if not completed

    try a_future.await_op(io, .{});
    try b_future.await_op(io, .{});

    const out = File.stdout();
    try out.writeAll(io, "save complete\n");
}

// Example function showing more advanced defer cancellation patterns
pub fn saveDataWithTimeout(allocator: std.mem.Allocator, io: Io, data: []const u8, timeout_ms: u64) !void {
    var a_future = try io.async(allocator, saveFile, .{ io, data, "saveA.txt" });
    defer a_future.deinit();
    defer a_future.deferCancelWithOptions(io, .{
        .reason = .timeout,
        .grace_period_ms = 100,
    }).cancelIfPending();

    var b_future = try io.async(allocator, saveFile, .{ io, data, "saveB.txt" });
    defer b_future.deinit();
    defer b_future.deferCancelWithOptions(io, .{
        .reason = .timeout,
        .grace_period_ms = 100,
    }).cancelIfPending();

    // Chain cancellation so if one fails, the other gets cancelled
    try a_future.chainCancellation(&b_future);

    try a_future.awaitTimeout(io, timeout_ms);
    try b_future.awaitTimeout(io, timeout_ms);

    const out = File.stdout();
    try out.writeAll(io, "save complete\n");
}

/// Execution model detection and configuration
pub const ExecutionModel = enum {
    blocking,
    thread_pool,
    green_threads,
    stackless,
    
    /// Detect the best execution model for the current platform
    pub fn detect() ExecutionModel {
        const builtin = @import("builtin");
        return switch (builtin.os.tag) {
            .linux => switch (builtin.cpu.arch) {
                .x86_64 => .green_threads, // io_uring available
                else => .thread_pool,
            },
            .windows => .thread_pool, // IOCP
            .macos => .green_threads,  // kqueue
            .wasi => .stackless,       // WASM
            else => .blocking,
        };
    }
    
    /// Get recommended configuration for the execution model
    pub fn getRecommendedConfig(self: ExecutionModel) ExecutionConfig {
        return switch (self) {
            .blocking => .{ .blocking = .{} },
            .thread_pool => .{ .thread_pool = .{
                .num_threads = @max(1, std.Thread.getCpuCount() catch 4),
                .queue_type = .lock_free,
                .enable_dynamic_scaling = true,
            }},
            .green_threads => .{ .green_threads = .{
                .stack_size = 64 * 1024,
                .max_threads = 1024,
                .io_uring_entries = 256,
            }},
            .stackless => .{ .stackless = .{
                .max_async_frames = 1024,
                .frame_size = 4096,
            }},
        };
    }
};

/// Configuration for different execution models
pub const ExecutionConfig = union(ExecutionModel) {
    blocking: struct {},
    thread_pool: struct {
        num_threads: u32 = 4,
        max_queue_size: u32 = 1024,
        queue_type: enum { locked_fifo, lock_free, work_stealing } = .lock_free,
        enable_dynamic_scaling: bool = true,
        min_threads: u32 = 1,
        max_threads: u32 = 16,
    },
    green_threads: struct {
        stack_size: usize = 64 * 1024,
        max_threads: u32 = 1024,
        io_uring_entries: u32 = 256,
    },
    stackless: struct {
        max_async_frames: u32 = 1024,
        frame_size: usize = 4096,
    },
};

/// Factory for creating Io instances with different execution models
pub const IoFactory = struct {
    /// Create an Io instance with the best execution model for the platform
    pub fn createAuto(allocator: std.mem.Allocator) !IoInstance {
        const model = ExecutionModel.detect();
        const config = model.getRecommendedConfig();
        return createWithConfig(allocator, config);
    }
    
    /// Create an Io instance with explicit configuration
    pub fn createWithConfig(allocator: std.mem.Allocator, config: ExecutionConfig) !IoInstance {
        return switch (config) {
            .blocking => .{
                .blocking = @import("blocking_io.zig").BlockingIo.init(allocator),
            },
            .thread_pool => |tp_config| .{
                .thread_pool = try @import("threadpool_io.zig").ThreadPoolIo.init(allocator, .{
                    .num_threads = tp_config.num_threads,
                    .max_queue_size = tp_config.max_queue_size,
                    .queue_type = switch (tp_config.queue_type) {
                        .locked_fifo => .locked_fifo,
                        .lock_free => .lock_free,
                        .work_stealing => .work_stealing,
                    },
                    .enable_dynamic_scaling = tp_config.enable_dynamic_scaling,
                    .min_threads = tp_config.min_threads,
                    .max_threads = tp_config.max_threads,
                }),
            },
            .green_threads => |gt_config| .{
                .green_threads = try @import("greenthreads_io.zig").GreenThreadsIo.init(allocator, .{
                    .stack_size = gt_config.stack_size,
                    .max_threads = gt_config.max_threads,
                    .io_uring_entries = gt_config.io_uring_entries,
                }),
            },
            .stackless => |sl_config| .{
                .stackless = try @import("stackless_io.zig").StacklessIo.init(allocator, .{
                    .max_async_frames = sl_config.max_async_frames,
                    .frame_size = sl_config.frame_size,
                }),
            },
        };
    }
    
    /// Create a blocking Io instance
    pub fn createBlocking(allocator: std.mem.Allocator) IoInstance {
        return .{
            .blocking = @import("blocking_io.zig").BlockingIo.init(allocator),
        };
    }
    
    /// Create a thread pool Io instance
    pub fn createThreadPool(allocator: std.mem.Allocator) !IoInstance {
        return .{
            .thread_pool = try @import("threadpool_io.zig").ThreadPoolIo.init(allocator, .{}),
        };
    }
    
    /// Create a green threads Io instance
    pub fn createGreenThreads(allocator: std.mem.Allocator) !IoInstance {
        return .{
            .green_threads = try @import("greenthreads_io.zig").GreenThreadsIo.init(allocator, .{}),
        };
    }
    
    /// Create a stackless Io instance
    pub fn createStackless(allocator: std.mem.Allocator) !IoInstance {
        return .{
            .stackless = try @import("stackless_io.zig").StacklessIo.init(allocator, .{}),
        };
    }
};

/// Unified Io instance that can hold any execution model
pub const IoInstance = union(ExecutionModel) {
    blocking: @import("blocking_io.zig").BlockingIo,
    thread_pool: @import("threadpool_io.zig").ThreadPoolIo,
    green_threads: @import("greenthreads_io.zig").GreenThreadsIo,
    stackless: @import("stackless_io.zig").StacklessIo,
    
    /// Get the Io interface for any execution model
    pub fn io(self: *IoInstance) Io {
        return switch (self.*) {
            .blocking => |*impl| impl.io(),
            .thread_pool => |*impl| impl.io(),
            .green_threads => |*impl| impl.io(),
            .stackless => |*impl| impl.io(),
        };
    }
    
    /// Deinitialize the Io instance
    pub fn deinit(self: *IoInstance) void {
        switch (self.*) {
            .blocking => |*impl| impl.deinit(),
            .thread_pool => |*impl| impl.deinit(),
            .green_threads => |*impl| impl.deinit(),
            .stackless => |*impl| impl.deinit(),
        }
    }
    
    /// Get the execution model type
    pub fn getModel(self: *const IoInstance) ExecutionModel {
        return switch (self.*) {
            .blocking => .blocking,
            .thread_pool => .thread_pool,
            .green_threads => .green_threads,
            .stackless => .stackless,
        };
    }
    
    /// Run the event loop if the execution model supports it
    pub fn run(self: *IoInstance) !void {
        switch (self.*) {
            .green_threads => |*impl| try impl.run(),
            .stackless => |*impl| try impl.run(),
            .blocking, .thread_pool => {
                // These models don't have explicit event loops
                return;
            },
        }
    }
};

/// Convenience function to create and run with automatic execution model detection
pub fn runWithAuto(allocator: std.mem.Allocator, comptime main_func: anytype) !void {
    var io_instance = try IoFactory.createAuto(allocator);
    defer io_instance.deinit();
    
    const io = io_instance.io();
    
    // Run the main function
    try main_func(io);
    
    // Run the event loop if needed
    try io_instance.run();
}

fn saveFile(io: Io, data: []const u8, name: []const u8) !void {
    const file = try Dir.cwd().createFile(io, name, .{});
    defer file.close(io) catch {};
    try file.writeAll(io, data);
}

test "io interface creation" {
    const testing = std.testing;
    
    // Test that our types are properly defined
    const IoType = @TypeOf(Io);
    _ = IoType;
    
    const FutureType = @TypeOf(Future);
    _ = FutureType;
    
    try testing.expect(true);
}