//! Enhanced Error Handling and Resource Management for zsync v0.2.0
//! Provides comprehensive error propagation, recovery, and resource cleanup

const std = @import("std");
const builtin = @import("builtin");

/// Comprehensive error set for async operations
pub const AsyncError = error{
    // Resource management errors
    ResourceExhausted,
    ResourceLeaked,
    ResourceCorrupted,
    
    // Async operation errors
    OperationCanceled,
    OperationTimeout,
    OperationAborted,
    
    // I/O specific errors
    IoTimeout,
    IoInterrupted,
    IoCanceled,
    
    // Platform specific errors
    PlatformUnsupported,
    PlatformLimitExceeded,
    
    // Memory management errors
    OutOfMemory,
    StackOverflow,
    MemoryCorruption,
    
    // Concurrency errors
    Deadlock,
    RaceCondition,
    ContentionTimeout,
    
    // Network errors
    NetworkUnreachable,
    ConnectionReset,
    ConnectionRefused,
    DnsResolutionFailed,
    
    // File system errors
    FileNotFound,
    PermissionDenied,
    DiskFull,
    FilesystemCorrupted,
};

/// Error context for tracking error origins and stack traces
pub const ErrorContext = struct {
    error_code: AsyncError,
    source_location: std.builtin.SourceLocation,
    message: []const u8,
    timestamp: u64,
    thread_id: std.Thread.Id,
    stack_trace: ?[]usize,
    recovery_hint: ?RecoveryHint,
    
    const Self = @This();
    
    pub fn init(
        error_code: AsyncError, 
        source_location: std.builtin.SourceLocation,
        message: []const u8,
        recovery_hint: ?RecoveryHint
    ) Self {
        return Self{
            .error_code = error_code,
            .source_location = source_location,
            .message = message,
            .timestamp = blk: { const ts = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch unreachable; break :blk @intCast(@divTrunc((@as(i128, ts.sec) * std.time.ns_per_s + ts.nsec), std.time.ns_per_ms)); },
            .thread_id = std.Thread.getCurrentId(),
            .stack_trace = captureStackTrace(),
            .recovery_hint = recovery_hint,
        };
    }
    
    pub fn format(
        self: Self,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("AsyncError.{s} at {s}:{d}:{d}\n", .{
            @errorName(self.error_code),
            self.source_location.file,
            self.source_location.line,
            self.source_location.column,
        });
        try writer.print("  Message: {s}\n", .{self.message});
        try writer.print("  Timestamp: {d}\n", .{self.timestamp});
        try writer.print("  Thread: {}\n", .{self.thread_id});
        
        if (self.recovery_hint) |hint| {
            try writer.print("  Recovery: {s}\n", .{hint.description});
        }
        
        if (self.stack_trace) |trace| {
            try writer.print("  Stack trace:\n");
            for (trace, 0..) |addr, i| {
                try writer.print("    {d}: 0x{x}\n", .{ i, addr });
            }
        }
    }
    
    fn captureStackTrace() ?[]usize {
        // In a real implementation, we'd capture actual stack traces
        return null;
    }
};

/// Recovery hints for automated error recovery
pub const RecoveryHint = struct {
    strategy: RecoveryStrategy,
    description: []const u8,
    retry_count: u32,
    backoff_ms: u32,
    
    pub const RecoveryStrategy = enum {
        retry_immediate,
        retry_with_backoff,
        fallback_to_blocking,
        fallback_to_sync,
        escalate_to_parent,
        terminate_gracefully,
        ignore_and_continue,
    };
    
    pub fn retryImmediate(description: []const u8) RecoveryHint {
        return RecoveryHint{
            .strategy = .retry_immediate,
            .description = description,
            .retry_count = 3,
            .backoff_ms = 0,
        };
    }
    
    pub fn retryWithBackoff(description: []const u8, retry_count: u32, backoff_ms: u32) RecoveryHint {
        return RecoveryHint{
            .strategy = .retry_with_backoff,
            .description = description,
            .retry_count = retry_count,
            .backoff_ms = backoff_ms,
        };
    }
    
    pub fn fallbackToBlocking(description: []const u8) RecoveryHint {
        return RecoveryHint{
            .strategy = .fallback_to_blocking,
            .description = description,
            .retry_count = 0,
            .backoff_ms = 0,
        };
    }
};

/// Resource tracker for automatic cleanup
pub const ResourceTracker = struct {
    resources: std.ArrayList(Resource),
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,
    
    const Self = @This();
    
    const Resource = struct {
        id: u64,
        type: ResourceType,
        ptr: *anyopaque,
        cleanup_fn: *const fn(*anyopaque) void,
        allocated_at: std.builtin.SourceLocation,
        timestamp: u64,
        
        pub const ResourceType = enum {
            memory,
            file,
            socket,
            thread,
            future,
            timer,
            custom,
        };
    };
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .resources = std.ArrayList(Resource){ .allocator = allocator },
            .allocator = allocator,
            .mutex = std.Thread.Mutex{},
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // Clean up any remaining resources
        for (self.resources.items) |resource| {
            resource.cleanup_fn(resource.ptr);
        }
        
        self.resources.deinit();
    }
    
    pub fn register(
        self: *Self,
        resource_type: Resource.ResourceType,
        ptr: *anyopaque,
        cleanup_fn: *const fn(*anyopaque) void,
        source_location: std.builtin.SourceLocation,
    ) !u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        const id = @as(u64, @intCast(self.resources.items.len)) + 1;
        const resource = Resource{
            .id = id,
            .type = resource_type,
            .ptr = ptr,
            .cleanup_fn = cleanup_fn,
            .allocated_at = source_location,
            .timestamp = blk: { const ts = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch unreachable; break :blk @intCast(@divTrunc((@as(i128, ts.sec) * std.time.ns_per_s + ts.nsec), std.time.ns_per_ms)); },
        };
        
        try self.resources.append(self.allocator, resource);
        return id;
    }
    
    pub fn unregister(self: *Self, id: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        for (self.resources.items, 0..) |resource, i| {
            if (resource.id == id) {
                _ = self.resources.swapRemove(i);
                return;
            }
        }
    }
    
    pub fn cleanup(self: *Self, id: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        for (self.resources.items, 0..) |resource, i| {
            if (resource.id == id) {
                resource.cleanup_fn(resource.ptr);
                _ = self.resources.swapRemove(i);
                return;
            }
        }
    }
    
    pub fn getReport(self: *Self, writer: anytype) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        try writer.print("Resource Tracker Report:\n");
        try writer.print("  Active resources: {d}\n", .{self.resources.items.len});
        
        for (self.resources.items) |resource| {
            try writer.print("  Resource {d}: {s} at {s}:{d}\n", .{
                resource.id,
                @tagName(resource.type),
                resource.allocated_at.file,
                resource.allocated_at.line,
            });
        }
    }
};

/// RAII resource guard for automatic cleanup
pub fn ResourceGuard(comptime T: type) type {
    return struct {
        resource: T,
        cleanup_fn: *const fn(T) void,
        tracker: ?*ResourceTracker,
        resource_id: ?u64,
        
        const Self = @This();
        
        pub fn init(
            resource: T,
            cleanup_fn: *const fn(T) void,
            tracker: ?*ResourceTracker,
            source_location: std.builtin.SourceLocation,
        ) !Self {
            var resource_id: ?u64 = null;
            
            if (tracker) |t| {
                const resource_ptr = @as(*anyopaque, @ptrCast(&resource));
                const cleanup_wrapper = struct {
                    fn cleanup(ptr: *anyopaque) void {
                        const r: *T = @ptrCast(@alignCast(ptr));
                        cleanup_fn(r.*);
                    }
                }.cleanup;
                
                resource_id = try t.register(
                    .custom,
                    resource_ptr,
                    cleanup_wrapper,
                    source_location,
                );
            }
            
            return Self{
                .resource = resource,
                .cleanup_fn = cleanup_fn,
                .tracker = tracker,
                .resource_id = resource_id,
            };
        }
        
        pub fn deinit(self: *Self) void {
            if (self.tracker) |tracker| {
                if (self.resource_id) |id| {
                    tracker.unregister(id);
                }
            }
            self.cleanup_fn(self.resource);
        }
        
        pub fn get(self: *const Self) T {
            return self.resource;
        }
        
        pub fn release(self: *Self) T {
            if (self.tracker) |tracker| {
                if (self.resource_id) |id| {
                    tracker.unregister(id);
                    self.resource_id = null;
                }
            }
            return self.resource;
        }
    };
}

/// Error recovery manager for automated error handling
pub const ErrorRecoveryManager = struct {
    recovery_strategies: std.HashMap(AsyncError, RecoveryHint, std.hash_map.AutoContext(AsyncError), std.hash_map.default_max_load_percentage),
    allocator: std.mem.Allocator,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .recovery_strategies = std.HashMap(AsyncError, RecoveryHint, std.hash_map.AutoContext(AsyncError), std.hash_map.default_max_load_percentage).init(allocator),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.recovery_strategies.deinit();
    }
    
    pub fn registerStrategy(self: *Self, error_code: AsyncError, hint: RecoveryHint) !void {
        try self.recovery_strategies.put(error_code, hint);
    }
    
    pub fn handleError(self: *Self, error_context: ErrorContext) !RecoveryHint {
        if (self.recovery_strategies.get(error_context.error_code)) |hint| {
            return hint;
        }
        
        // Default recovery strategies based on error type
        return switch (error_context.error_code) {
            AsyncError.IoTimeout, AsyncError.NetworkUnreachable => 
                RecoveryHint.retryWithBackoff("Network operation retry", 3, 1000),
            AsyncError.ResourceExhausted => 
                RecoveryHint.fallbackToBlocking("Fallback to blocking I/O"),
            AsyncError.OperationCanceled => 
                RecoveryHint{ .strategy = .terminate_gracefully, .description = "Operation was canceled", .retry_count = 0, .backoff_ms = 0 },
            else => 
                RecoveryHint{ .strategy = .escalate_to_parent, .description = "Unhandled error", .retry_count = 0, .backoff_ms = 0 },
        };
    }
};

/// Stack overflow detection and handling
pub const StackGuard = struct {
    stack_start: usize,
    stack_size: usize,
    warning_threshold: usize,
    
    const Self = @This();
    
    pub fn init(stack_size: usize) Self {
        const stack_start = @returnAddress();
        return Self{
            .stack_start = stack_start,
            .stack_size = stack_size,
            .warning_threshold = stack_size * 80 / 100, // 80% threshold
        };
    }
    
    pub fn checkUsage(self: Self) !void {
        const current_pos = @returnAddress();
        const usage = if (current_pos < self.stack_start) 
            self.stack_start - current_pos 
        else 
            current_pos - self.stack_start;
            
        if (usage > self.stack_size) {
            return AsyncError.StackOverflow;
        }
        
        if (usage > self.warning_threshold) {
            std.log.warn("Stack usage at {d}% ({d}/{d} bytes)", .{
                usage * 100 / self.stack_size,
                usage,
                self.stack_size,
            });
        }
    }
};

/// Memory safety validator for async operations
pub const MemorySafetyValidator = struct {
    allocations: std.HashMap(usize, AllocationInfo, std.hash_map.AutoContext(usize), std.hash_map.default_max_load_percentage),
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,
    
    const Self = @This();
    
    const AllocationInfo = struct {
        size: usize,
        alignment: u29,
        allocated_at: std.builtin.SourceLocation,
        timestamp: u64,
        thread_id: std.Thread.Id,
    };
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocations = std.HashMap(usize, AllocationInfo, std.hash_map.AutoContext(usize), std.hash_map.default_max_load_percentage).init(allocator),
            .allocator = allocator,
            .mutex = std.Thread.Mutex{},
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // Report any leaked allocations
        if (self.allocations.count() > 0) {
            std.log.err("Memory leaks detected: {d} allocations not freed", .{self.allocations.count()});
            
            var iterator = self.allocations.iterator();
            while (iterator.next()) |entry| {
                const info = entry.value_ptr.*;
                std.log.err("  Leak: {d} bytes at {s}:{d}", .{
                    info.size,
                    info.allocated_at.file,
                    info.allocated_at.line,
                });
            }
        }
        
        self.allocations.deinit();
    }
    
    pub fn trackAllocation(
        self: *Self,
        ptr: *anyopaque,
        size: usize,
        alignment: u29,
        source_location: std.builtin.SourceLocation,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        const addr = @intFromPtr(ptr);
        const info = AllocationInfo{
            .size = size,
            .alignment = alignment,
            .allocated_at = source_location,
            .timestamp = blk: { const ts = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch unreachable; break :blk @intCast(@divTrunc((@as(i128, ts.sec) * std.time.ns_per_s + ts.nsec), std.time.ns_per_ms)); },
            .thread_id = std.Thread.getCurrentId(),
        };
        
        try self.allocations.put(addr, info);
    }
    
    pub fn trackDeallocation(self: *Self, ptr: *anyopaque) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        const addr = @intFromPtr(ptr);
        if (!self.allocations.remove(addr)) {
            std.log.err("Double free or invalid free detected at address 0x{x}", .{addr});
            return AsyncError.MemoryCorruption;
        }
    }
    
    pub fn validatePointer(self: *Self, ptr: *anyopaque) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        const addr = @intFromPtr(ptr);
        if (!self.allocations.contains(addr)) {
            std.log.err("Invalid pointer access at address 0x{x}", .{addr});
            return AsyncError.MemoryCorruption;
        }
    }
};

/// Graceful degradation manager for platform limitations
pub const GracefulDegradationManager = struct {
    platform_capabilities: std.HashMap([]const u8, bool, std.hash_map.StringContext, std.hash_map.default_max_load_percentage),
    fallback_strategies: std.HashMap([]const u8, FallbackStrategy, std.hash_map.StringContext, std.hash_map.default_max_load_percentage),
    allocator: std.mem.Allocator,
    
    const Self = @This();
    
    const FallbackStrategy = struct {
        description: []const u8,
        fallback_fn: *const fn() anyerror!void,
    };
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .platform_capabilities = std.HashMap([]const u8, bool, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator),
            .fallback_strategies = std.HashMap([]const u8, FallbackStrategy, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.platform_capabilities.deinit();
        self.fallback_strategies.deinit();
    }
    
    pub fn detectPlatformCapabilities(self: *Self) !void {
        // Detect io_uring support
        try self.platform_capabilities.put("io_uring", detectIoUring());
        
        // Detect kqueue support
        try self.platform_capabilities.put("kqueue", detectKqueue());
        
        // Detect IOCP support
        try self.platform_capabilities.put("iocp", detectIocp());
        
        // Detect stack swapping support
        try self.platform_capabilities.put("stack_swap", detectStackSwap());
    }
    
    pub fn registerFallback(self: *Self, feature: []const u8, strategy: FallbackStrategy) !void {
        try self.fallback_strategies.put(feature, strategy);
    }
    
    pub fn checkCapabilityOrFallback(self: *Self, feature: []const u8) !void {
        if (self.platform_capabilities.get(feature)) |available| {
            if (available) return;
        }
        
        if (self.fallback_strategies.get(feature)) |strategy| {
            std.log.warn("Feature '{s}' not available, using fallback: {s}", .{ feature, strategy.description });
            try strategy.fallback_fn();
        } else {
            std.log.err("Feature '{s}' not available and no fallback registered", .{feature});
            return AsyncError.PlatformUnsupported;
        }
    }
    
    fn detectIoUring() bool {
        return builtin.target.os.tag == .linux;
    }
    
    fn detectKqueue() bool {
        return builtin.target.os.tag == .macos or builtin.target.os.tag == .freebsd;
    }
    
    fn detectIocp() bool {
        return builtin.target.os.tag == .windows;
    }
    
    fn detectStackSwap() bool {
        return !builtin.target.cpu.arch.isWasm();
    }
};

// Convenience macros for error handling
pub fn createError(
    error_code: AsyncError,
    message: []const u8,
    recovery_hint: ?RecoveryHint,
    source_location: std.builtin.SourceLocation,
) ErrorContext {
    return ErrorContext.init(error_code, source_location, message, recovery_hint);
}

pub fn tryWithRecovery(
    operation: anytype,
    error_manager: *ErrorRecoveryManager,
    max_retries: u32,
) !@TypeOf(operation()) {
    var retries: u32 = 0;
    
    while (retries <= max_retries) {
        const result = operation() catch |err| {
            if (@TypeOf(err) == AsyncError) {
                const error_context = createError(
                    err,
                    "Operation failed",
                    null,
                    @src(),
                );
                
                const recovery_hint = try error_manager.handleError(error_context);
                
                switch (recovery_hint.strategy) {
                    .retry_immediate => {
                        retries += 1;
                        continue;
                    },
                    .retry_with_backoff => {
                        if (retries < recovery_hint.retry_count) {
                            std.time.sleep(recovery_hint.backoff_ms * std.time.ns_per_ms);
                            retries += 1;
                            continue;
                        }
                    },
                    else => return err,
                }
            }
            return err;
        };
        
        return result;
    }
    
    return AsyncError.OperationAborted;
}

test "error handling" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    // Test error context creation
    const error_context = createError(
        AsyncError.ResourceExhausted,
        "Test error",
        RecoveryHint.retryImmediate("Test retry"),
        @src(),
    );
    
    try testing.expect(error_context.error_code == AsyncError.ResourceExhausted);
    
    // Test resource tracker
    var tracker = ResourceTracker.init(allocator);
    defer tracker.deinit();
    
    // Test resource guard
    const TestResource = struct {
        value: i32,
        
        fn cleanup(resource: @This()) void {
            _ = resource;
            // Cleanup logic here
        }
    };
    
    var guard = try ResourceGuard(TestResource).init(
        TestResource{ .value = 42 },
        TestResource.cleanup,
        &tracker,
        @src(),
    );
    defer guard.deinit();
    
    try testing.expect(guard.get().value == 42);
}