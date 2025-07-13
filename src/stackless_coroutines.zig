//! Frame Buffer Management System for Stackless Coroutines - Zsync v0.2.0
//! Implements WASM-compatible stackless execution with efficient frame management

const std = @import("std");
const builtin = @import("builtin");
const error_management = @import("error_management.zig");
const platform = @import("platform.zig");

/// Frame buffer management for stackless coroutines
pub const FrameBufferManager = struct {
    allocator: std.mem.Allocator,
    frame_pool: FramePool,
    size_calculator: FrameSizeCalculator,
    alignment_manager: AlignmentManager,
    
    const Self = @This();
    
    /// Pool of reusable frame buffers for efficiency
    const FramePool = struct {
        available_frames: std.ArrayList(FrameBuffer),
        active_frames: std.HashMap(usize, FrameBuffer, std.hash_map.AutoContext(usize), std.hash_map.default_max_load_percentage),
        total_allocated: std.atomic.Value(usize),
        peak_usage: std.atomic.Value(usize),
        recycle_count: std.atomic.Value(usize),
        allocator: std.mem.Allocator,
        
        const FrameBuffer = struct {
            data: []align(16) u8,
            size: usize,
            frame_id: usize,
            generation: u64, // For detecting stale references
            last_used: u64,  // For LRU eviction
            is_active: bool,
            
            pub fn init(allocator: std.mem.Allocator, size: usize, frame_id: usize) !FrameBuffer {
                const aligned_size = std.mem.alignForward(usize, size, 16);
                const data = try allocator.alignedAlloc(u8, 16, aligned_size);
                
                return FrameBuffer{
                    .data = data,
                    .size = aligned_size,
                    .frame_id = frame_id,
                    .generation = std.time.nanoTimestamp(),
                    .last_used = std.time.nanoTimestamp(),
                    .is_active = false,
                };
            }
            
            pub fn deinit(self: FrameBuffer, allocator: std.mem.Allocator) void {
                allocator.free(self.data);
            }
            
            pub fn reset(self: *FrameBuffer) void {
                @memset(self.data, 0);
                self.last_used = std.time.nanoTimestamp();
                self.is_active = false;
            }
            
            pub fn isStale(self: FrameBuffer, max_age_ns: u64) bool {
                return (std.time.nanoTimestamp() - self.last_used) > max_age_ns;
            }
        };
        
        pub fn init(allocator: std.mem.Allocator) @This() {
            return @This(){
                .available_frames = std.ArrayList(FrameBuffer).init(allocator),
                .active_frames = std.HashMap(usize, FrameBuffer, std.hash_map.AutoContext(usize), std.hash_map.default_max_load_percentage).init(allocator),
                .total_allocated = std.atomic.Value(usize).init(0),
                .peak_usage = std.atomic.Value(usize).init(0),
                .recycle_count = std.atomic.Value(usize).init(0),
                .allocator = allocator,
            };
        }
        
        pub fn deinit(self: *@This()) void {
            // Free all available frames
            for (self.available_frames.items) |frame| {
                frame.deinit(self.allocator);
            }
            self.available_frames.deinit();
            
            // Free all active frames
            var active_iterator = self.active_frames.iterator();
            while (active_iterator.next()) |entry| {
                entry.value_ptr.deinit(self.allocator);
            }
            self.active_frames.deinit();
        }
        
        /// Acquire a frame buffer of the specified size
        pub fn acquire(self: *@This(), size: usize, frame_id: usize) !FrameBuffer {
            // Try to find a suitable frame in the available pool
            for (self.available_frames.items, 0..) |*frame, i| {
                if (frame.size >= size and !frame.is_active) {
                    const acquired_frame = self.available_frames.swapRemove(i);
                    var mutable_frame = acquired_frame;
                    mutable_frame.frame_id = frame_id;
                    mutable_frame.is_active = true;
                    mutable_frame.last_used = std.time.nanoTimestamp();
                    
                    try self.active_frames.put(frame_id, mutable_frame);
                    _ = self.recycle_count.fetchAdd(1, .monotonic);
                    
                    return mutable_frame;
                }
            }
            
            // No suitable frame found, allocate a new one
            const new_frame = try FrameBuffer.init(self.allocator, size, frame_id);
            var mutable_frame = new_frame;
            mutable_frame.is_active = true;
            
            try self.active_frames.put(frame_id, mutable_frame);
            
            const current_total = self.total_allocated.fetchAdd(size, .monotonic) + size;
            const current_peak = self.peak_usage.load(.monotonic);
            if (current_total > current_peak) {
                _ = self.peak_usage.compareAndSwap(current_peak, current_total, .monotonic, .monotonic);
            }
            
            return mutable_frame;
        }
        
        /// Release a frame buffer back to the pool
        pub fn release(self: *@This(), frame_id: usize) !void {
            if (self.active_frames.fetchRemove(frame_id)) |entry| {
                var frame = entry.value;
                frame.reset();
                try self.available_frames.append(frame);
            }
        }
        
        /// Perform garbage collection of stale frames
        pub fn collectGarbage(self: *@This(), max_age_ns: u64) !void {
            var i: usize = 0;
            while (i < self.available_frames.items.len) {
                const frame = self.available_frames.items[i];
                if (frame.isStale(max_age_ns)) {
                    const stale_frame = self.available_frames.swapRemove(i);
                    stale_frame.deinit(self.allocator);
                    _ = self.total_allocated.fetchSub(stale_frame.size, .monotonic);
                } else {
                    i += 1;
                }
            }
        }
        
        /// Get statistics about frame pool usage
        pub fn getStatistics(self: *const @This()) PoolStatistics {
            return PoolStatistics{
                .available_frames = self.available_frames.items.len,
                .active_frames = self.active_frames.count(),
                .total_allocated_bytes = self.total_allocated.load(.monotonic),
                .peak_usage_bytes = self.peak_usage.load(.monotonic),
                .recycle_count = self.recycle_count.load(.monotonic),
            };
        }
        
        const PoolStatistics = struct {
            available_frames: usize,
            active_frames: usize,
            total_allocated_bytes: usize,
            peak_usage_bytes: usize,
            recycle_count: usize,
        };
    };
    
    /// Calculates frame sizes based on function signatures and local variables
    const FrameSizeCalculator = struct {
        size_cache: std.HashMap(TypeId, usize, TypeIdContext, std.hash_map.default_max_load_percentage),
        allocator: std.mem.Allocator,
        
        const TypeId = struct {
            hash: u64,
            name: []const u8,
        };
        
        const TypeIdContext = struct {
            pub fn hash(self: @This(), key: TypeId) u64 {
                _ = self;
                return key.hash;
            }
            
            pub fn eql(self: @This(), a: TypeId, b: TypeId) bool {
                _ = self;
                return a.hash == b.hash and std.mem.eql(u8, a.name, b.name);
            }
        };
        
        pub fn init(allocator: std.mem.Allocator) @This() {
            return @This(){
                .size_cache = std.HashMap(TypeId, usize, TypeIdContext, std.hash_map.default_max_load_percentage).init(allocator),
                .allocator = allocator,
            };
        }
        
        pub fn deinit(self: *@This()) void {
            self.size_cache.deinit();
        }
        
        /// Calculate frame size for a given function type
        pub fn calculateFrameSize(self: *@This(), comptime FuncType: type) !usize {
            const type_id = TypeId{
                .hash = comptime std.hash_map.hashString(@typeName(FuncType)),
                .name = @typeName(FuncType),
            };
            
            if (self.size_cache.get(type_id)) |cached_size| {
                return cached_size;
            }
            
            const calculated_size = comptime calculateSizeComptime(FuncType);
            try self.size_cache.put(type_id, calculated_size);
            
            return calculated_size;
        }
        
        /// Compile-time frame size calculation
        fn calculateSizeComptime(comptime FuncType: type) usize {
            const func_info = @typeInfo(FuncType);
            if (func_info != .Fn) {
                @compileError("Expected function type");
            }
            
            var total_size: usize = 0;
            
            // Add space for function parameters
            for (func_info.Fn.params) |param| {
                if (param.type) |param_type| {
                    total_size += @sizeOf(param_type);
                    total_size = std.mem.alignForward(usize, total_size, @alignOf(param_type));
                }
            }
            
            // Add space for return value
            if (func_info.Fn.return_type) |return_type| {
                const return_info = @typeInfo(return_type);
                if (return_info == .ErrorUnion) {
                    total_size += @sizeOf(return_info.ErrorUnion.payload);
                    total_size = std.mem.alignForward(usize, total_size, @alignOf(return_info.ErrorUnion.payload));
                } else {
                    total_size += @sizeOf(return_type);
                    total_size = std.mem.alignForward(usize, total_size, @alignOf(return_type));
                }
            }
            
            // Add overhead for coroutine state (suspend points, etc.)
            const coroutine_overhead = 256; // Estimated overhead
            total_size += coroutine_overhead;
            
            // Round up to next cache line boundary for performance
            const cache_line_size = 64;
            total_size = std.mem.alignForward(usize, total_size, cache_line_size);
            
            // Ensure minimum frame size
            const min_frame_size = 1024; // 1KB minimum
            return @max(total_size, min_frame_size);
        }
        
        /// Calculate frame size with runtime type information
        pub fn calculateFrameSizeRuntime(self: *@This(), param_types: []const type, return_type: ?type) usize {
            var total_size: usize = 0;
            
            // Add space for parameters
            for (param_types) |param_type| {
                total_size += @sizeOf(param_type);
                total_size = std.mem.alignForward(usize, total_size, @alignOf(param_type));
            }
            
            // Add space for return value
            if (return_type) |ret_type| {
                total_size += @sizeOf(ret_type);
                total_size = std.mem.alignForward(usize, total_size, @alignOf(ret_type));
            }
            
            // Add coroutine overhead
            total_size += 256;
            
            // Align to cache line
            total_size = std.mem.alignForward(usize, total_size, 64);
            
            return @max(total_size, 1024);
        }
    };
    
    /// Manages memory alignment requirements for different platforms
    const AlignmentManager = struct {
        platform_alignment: usize,
        vector_alignment: usize,
        cache_line_size: usize,
        
        pub fn init() @This() {
            return @This(){
                .platform_alignment = detectPlatformAlignment(),
                .vector_alignment = detectVectorAlignment(),
                .cache_line_size = detectCacheLineSize(),
            };
        }
        
        /// Ensure proper alignment for frame data
        pub fn alignFrameSize(self: @This(), size: usize) usize {
            var aligned_size = std.mem.alignForward(usize, size, self.platform_alignment);
            aligned_size = std.mem.alignForward(usize, aligned_size, self.vector_alignment);
            return std.mem.alignForward(usize, aligned_size, self.cache_line_size);
        }
        
        /// Get alignment offset for a specific type within a frame
        pub fn getAlignmentOffset(self: @This(), current_offset: usize, comptime T: type) usize {
            _ = self;
            return std.mem.alignForward(usize, current_offset, @alignOf(T));
        }
        
        fn detectPlatformAlignment() usize {
            return switch (builtin.target.cpu.arch) {
                .x86_64, .aarch64 => 16,
                .x86, .arm => 8,
                .wasm32, .wasm64 => 8,
                else => 8,
            };
        }
        
        fn detectVectorAlignment() usize {
            return switch (builtin.target.cpu.arch) {
                .x86_64 => if (std.Target.x86.featureSetHas(builtin.target.cpu.features, .avx512f)) 64
                          else if (std.Target.x86.featureSetHas(builtin.target.cpu.features, .avx)) 32
                          else 16,
                .aarch64 => 16,
                else => 8,
            };
        }
        
        fn detectCacheLineSize() usize {
            return switch (builtin.target.cpu.arch) {
                .x86_64, .aarch64 => 64,
                else => 32,
            };
        }
    };
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .frame_pool = FramePool.init(allocator),
            .size_calculator = FrameSizeCalculator.init(allocator),
            .alignment_manager = AlignmentManager.init(),
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.frame_pool.deinit();
        self.size_calculator.deinit();
    }
    
    /// Allocate a frame for a stackless coroutine
    pub fn allocateFrame(
        self: *Self,
        comptime FuncType: type,
        frame_id: usize,
    ) !StacklessFrame(FuncType) {
        const raw_size = try self.size_calculator.calculateFrameSize(FuncType);
        const aligned_size = self.alignment_manager.alignFrameSize(raw_size);
        
        const frame_buffer = try self.frame_pool.acquire(aligned_size, frame_id);
        
        return StacklessFrame(FuncType){
            .buffer = frame_buffer,
            .manager = self,
            .func_type = FuncType,
        };
    }
    
    /// Release a frame back to the pool
    pub fn releaseFrame(self: *Self, frame_id: usize) !void {
        try self.frame_pool.release(frame_id);
    }
    
    /// Perform maintenance tasks (garbage collection, etc.)
    pub fn performMaintenance(self: *Self) !void {
        const max_age_ns = 60 * std.time.ns_per_s; // 60 seconds
        try self.frame_pool.collectGarbage(max_age_ns);
    }
    
    /// Get comprehensive statistics
    pub fn getStatistics(self: *const Self) ManagerStatistics {
        return ManagerStatistics{
            .pool_stats = self.frame_pool.getStatistics(),
            .total_size_calculations = self.size_calculator.size_cache.count(),
            .platform_alignment = self.alignment_manager.platform_alignment,
            .cache_line_size = self.alignment_manager.cache_line_size,
        };
    }
    
    const ManagerStatistics = struct {
        pool_stats: FramePool.PoolStatistics,
        total_size_calculations: usize,
        platform_alignment: usize,
        cache_line_size: usize,
        
        pub fn print(self: @This()) void {
            std.debug.print("Frame Buffer Manager Statistics:\n");
            std.debug.print("  Pool:\n");
            std.debug.print("    Available frames: {d}\n", .{self.pool_stats.available_frames});
            std.debug.print("    Active frames: {d}\n", .{self.pool_stats.active_frames});
            std.debug.print("    Total allocated: {d} bytes\n", .{self.pool_stats.total_allocated_bytes});
            std.debug.print("    Peak usage: {d} bytes\n", .{self.pool_stats.peak_usage_bytes});
            std.debug.print("    Recycle count: {d}\n", .{self.pool_stats.recycle_count});
            std.debug.print("  Calculator:\n");
            std.debug.print("    Cached size calculations: {d}\n", .{self.total_size_calculations});
            std.debug.print("  Alignment:\n");
            std.debug.print("    Platform alignment: {d} bytes\n", .{self.platform_alignment});
            std.debug.print("    Cache line size: {d} bytes\n", .{self.cache_line_size});
        }
    };
};

/// Type-safe frame for stackless coroutines
pub fn StacklessFrame(comptime FuncType: type) type {
    return struct {
        buffer: FrameBufferManager.FramePool.FrameBuffer,
        manager: *FrameBufferManager,
        func_type: type,
        suspend_point: SuspendPoint = .start,
        locals: LocalStorage = LocalStorage{},
        
        const Self = @This();
        
        /// Enumeration of all possible suspend points in the coroutine
        const SuspendPoint = enum(u8) {
            start = 0,
            await_point_1 = 1,
            await_point_2 = 2,
            await_point_3 = 3,
            // ... more suspend points as needed
            completed = 255,
        };
        
        /// Storage for local variables that need to persist across suspend points
        const LocalStorage = struct {
            // This would be generated based on the actual function's local variables
            // For now, we use a generic storage approach
            data: [1024]u8 = [_]u8{0} ** 1024,
            offsets: [32]usize = [_]usize{0} ** 32,
            used_slots: usize = 0,
            
            /// Store a value in local storage
            pub fn store(self: *LocalStorage, comptime T: type, value: T) !usize {
                if (self.used_slots >= self.offsets.len) {
                    return error.LocalStorageFull;
                }
                
                const required_size = @sizeOf(T);
                const current_offset = if (self.used_slots == 0) 0 else self.offsets[self.used_slots - 1] + @sizeOf(T);
                
                if (current_offset + required_size > self.data.len) {
                    return error.LocalStorageOverflow;
                }
                
                const aligned_offset = std.mem.alignForward(usize, current_offset, @alignOf(T));
                if (aligned_offset + required_size > self.data.len) {
                    return error.LocalStorageOverflow;
                }
                
                const slot = self.used_slots;
                self.offsets[slot] = aligned_offset;
                self.used_slots += 1;
                
                // Store the value
                const storage_ptr = @as(*T, @ptrCast(@alignCast(&self.data[aligned_offset])));
                storage_ptr.* = value;
                
                return slot;
            }
            
            /// Load a value from local storage
            pub fn load(self: *const LocalStorage, comptime T: type, slot: usize) !T {
                if (slot >= self.used_slots) {
                    return error.InvalidSlot;
                }
                
                const offset = self.offsets[slot];
                const storage_ptr = @as(*const T, @ptrCast(@alignCast(&self.data[offset])));
                return storage_ptr.*;
            }
            
            /// Clear all local storage
            pub fn clear(self: *LocalStorage) void {
                @memset(&self.data, 0);
                @memset(&self.offsets, 0);
                self.used_slots = 0;
            }
        };
        
        /// Get a pointer to the frame data for a specific type
        pub fn getDataPtr(self: *Self, comptime T: type) *T {
            const offset = std.mem.alignForward(usize, 0, @alignOf(T));
            return @as(*T, @ptrCast(@alignCast(&self.buffer.data[offset])));
        }
        
        /// Store the current suspend point
        pub fn setSuspendPoint(self: *Self, point: SuspendPoint) void {
            self.suspend_point = point;
        }
        
        /// Get the current suspend point
        pub fn getSuspendPoint(self: *const Self) SuspendPoint {
            return self.suspend_point;
        }
        
        /// Check if the coroutine is completed
        pub fn isCompleted(self: *const Self) bool {
            return self.suspend_point == .completed;
        }
        
        /// Store a local variable that persists across suspend points
        pub fn storeLocal(self: *Self, comptime T: type, value: T) !usize {
            return self.locals.store(T, value);
        }
        
        /// Load a local variable
        pub fn loadLocal(self: *const Self, comptime T: type, slot: usize) !T {
            return self.locals.load(T, slot);
        }
        
        /// Reset the frame for reuse
        pub fn reset(self: *Self) void {
            self.suspend_point = .start;
            self.locals.clear();
            self.buffer.reset();
        }
        
        /// Release the frame back to the manager
        pub fn deinit(self: *Self) !void {
            try self.manager.releaseFrame(self.buffer.frame_id);
        }
    };
}

/// Stackless coroutine executor
pub const StacklessExecutor = struct {
    frame_manager: FrameBufferManager,
    running_coroutines: std.HashMap(usize, *anyopaque, std.hash_map.AutoContext(usize), std.hash_map.default_max_load_percentage),
    next_frame_id: std.atomic.Value(usize),
    allocator: std.mem.Allocator,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .frame_manager = FrameBufferManager.init(allocator),
            .running_coroutines = std.HashMap(usize, *anyopaque, std.hash_map.AutoContext(usize), std.hash_map.default_max_load_percentage).init(allocator),
            .next_frame_id = std.atomic.Value(usize).init(1),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.frame_manager.deinit();
        self.running_coroutines.deinit();
    }
    
    /// Start a new stackless coroutine
    pub fn startCoroutine(
        self: *Self,
        comptime FuncType: type,
        func: FuncType,
        args: anytype,
    ) !usize {
        const frame_id = self.next_frame_id.fetchAdd(1, .monotonic);
        var frame = try self.frame_manager.allocateFrame(FuncType, frame_id);
        
        // Store initial arguments in the frame
        _ = func;
        _ = args;
        // In a real implementation, we'd serialize the arguments into the frame
        
        const frame_ptr = try self.allocator.create(@TypeOf(frame));
        frame_ptr.* = frame;
        
        try self.running_coroutines.put(frame_id, frame_ptr);
        
        return frame_id;
    }
    
    /// Resume a suspended coroutine
    pub fn resumeCoroutine(self: *Self, frame_id: usize) !CoroutineResult {
        const frame_ptr = self.running_coroutines.get(frame_id) orelse {
            return error.CoroutineNotFound;
        };
        
        // In a real implementation, we'd dispatch based on the suspend point
        // and continue execution from where it left off
        
        return CoroutineResult.suspended;
    }
    
    /// Cancel a running coroutine
    pub fn cancelCoroutine(self: *Self, frame_id: usize) !void {
        if (self.running_coroutines.fetchRemove(frame_id)) |entry| {
            const frame_ptr = @as(*StacklessFrame(void), @ptrCast(@alignCast(entry.value)));
            try frame_ptr.deinit();
            self.allocator.destroy(frame_ptr);
        }
    }
    
    /// Poll all running coroutines
    pub fn pollAll(self: *Self) !usize {
        var completed_count: usize = 0;
        var to_remove = std.ArrayList(usize).init(self.allocator);
        defer to_remove.deinit();
        
        var iterator = self.running_coroutines.iterator();
        while (iterator.next()) |entry| {
            const frame_id = entry.key_ptr.*;
            const result = try self.resumeCoroutine(frame_id);
            
            if (result == .completed) {
                try to_remove.append(frame_id);
                completed_count += 1;
            }
        }
        
        // Remove completed coroutines
        for (to_remove.items) |frame_id| {
            try self.cancelCoroutine(frame_id);
        }
        
        return completed_count;
    }
    
    /// Get executor statistics
    pub fn getStatistics(self: *const Self) ExecutorStatistics {
        return ExecutorStatistics{
            .running_coroutines = self.running_coroutines.count(),
            .next_frame_id = self.next_frame_id.load(.monotonic),
            .frame_manager_stats = self.frame_manager.getStatistics(),
        };
    }
    
    const ExecutorStatistics = struct {
        running_coroutines: usize,
        next_frame_id: usize,
        frame_manager_stats: FrameBufferManager.ManagerStatistics,
        
        pub fn print(self: @This()) void {
            std.debug.print("Stackless Executor Statistics:\n");
            std.debug.print("  Running coroutines: {d}\n", .{self.running_coroutines});
            std.debug.print("  Next frame ID: {d}\n", .{self.next_frame_id});
            self.frame_manager_stats.print();
        }
    };
    
    const CoroutineResult = enum {
        suspended,
        completed,
        error_occurred,
    };
};

/// WASM-compatible stackless coroutine interface
pub const WasmStacklessInterface = struct {
    executor: StacklessExecutor,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .executor = StacklessExecutor.init(allocator),
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.executor.deinit();
    }
    
    /// WASM-compatible async function wrapper
    pub fn asyncCall(
        self: *Self,
        comptime func: anytype,
        args: anytype,
    ) !usize {
        return self.executor.startCoroutine(@TypeOf(func), func, args);
    }
    
    /// WASM-compatible polling interface
    pub fn poll(self: *Self, frame_id: usize) !bool {
        const result = try self.executor.resumeCoroutine(frame_id);
        return result == .completed;
    }
    
    /// WASM-compatible cancellation
    pub fn cancel(self: *Self, frame_id: usize) !void {
        try self.executor.cancelCoroutine(frame_id);
    }
};

test "frame buffer management" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var manager = FrameBufferManager.init(allocator);
    defer manager.deinit();
    
    // Test frame allocation
    const TestFunc = fn() void;
    var frame = try manager.allocateFrame(TestFunc, 1);
    defer frame.deinit() catch {};
    
    try testing.expect(frame.buffer.size >= 1024);
    try testing.expect(frame.getSuspendPoint() == .start);
    
    // Test local storage
    const test_value: u32 = 42;
    const slot = try frame.storeLocal(u32, test_value);
    const loaded_value = try frame.loadLocal(u32, slot);
    try testing.expect(loaded_value == test_value);
}

test "stackless executor" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var executor = StacklessExecutor.init(allocator);
    defer executor.deinit();
    
    // Test coroutine creation
    const TestFunc = fn() void;
    const test_func = struct {
        fn func() void {}
    }.func;
    
    const frame_id = try executor.startCoroutine(TestFunc, test_func, .{});
    try testing.expect(frame_id > 0);
    
    // Test cancellation
    try executor.cancelCoroutine(frame_id);
}

test "wasm interface" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var wasm_interface = WasmStacklessInterface.init(allocator);
    defer wasm_interface.deinit();
    
    const test_func = struct {
        fn func() void {}
    }.func;
    
    const frame_id = try wasm_interface.asyncCall(test_func, .{});
    try testing.expect(frame_id > 0);
    
    // Test polling
    const completed = try wasm_interface.poll(frame_id);
    _ = completed;
    
    try wasm_interface.cancel(frame_id);
}