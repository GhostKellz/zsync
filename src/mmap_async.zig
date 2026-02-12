const std = @import("std");
const compat = @import("compat/thread.zig");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const HashMap = std.HashMap;
const testing = std.testing;
const io = @import("io_v2.zig");
const syscall_async = @import("syscall_async.zig");
const linux = std.os.linux;
const builtin = @import("builtin");

pub const MmapError = error{
    InvalidAddress,
    InvalidLength,
    InvalidProtection,
    InvalidFlags,
    InsufficientMemory,
    PermissionDenied,
    FileError,
    MappingFailed,
    UnmappingFailed,
    SyncFailed,
    AdviceFailed,
    OutOfMemory,
};

pub const MemoryProtection = enum(i32) {
    none = 0,
    read = 1,
    write = 2,
    exec = 4,
    read_write = 3,
    read_exec = 5,
    write_exec = 6,
    read_write_exec = 7,
    
    pub fn toLinux(self: MemoryProtection) i32 {
        return switch (self) {
            .none => 0,
            .read => linux.PROT.READ,
            .write => linux.PROT.WRITE,
            .exec => linux.PROT.EXEC,
            .read_write => linux.PROT.READ | linux.PROT.WRITE,
            .read_exec => linux.PROT.READ | linux.PROT.EXEC,
            .write_exec => linux.PROT.WRITE | linux.PROT.EXEC,
            .read_write_exec => linux.PROT.READ | linux.PROT.WRITE | linux.PROT.EXEC,
        };
    }
};

pub const MappingFlags = enum(i32) {
    shared = 1,
    private = 2,
    fixed = 16,
    anonymous = 32,
    locked = 8192,
    noreserve = 16384,
    populate = 32768,
    nonblock = 65536,
    stack = 131072,
    hugetlb = 262144,
    sync = 524288,
    fixed_noreplace = 1048576,
    
    pub fn toLinux(self: MappingFlags) i32 {
        return switch (self) {
            .shared => linux.MAP.SHARED,
            .private => linux.MAP.PRIVATE,
            .fixed => linux.MAP.FIXED,
            .anonymous => linux.MAP.ANONYMOUS,
            .locked => linux.MAP.LOCKED,
            .noreserve => linux.MAP.NORESERVE,
            .populate => linux.MAP.POPULATE,
            .nonblock => linux.MAP.NONBLOCK,
            .stack => linux.MAP.STACK,
            .hugetlb => linux.MAP.HUGETLB,
            .sync => linux.MAP.SYNC,
            .fixed_noreplace => linux.MAP.FIXED_NOREPLACE,
        };
    }
};

pub const AdviceType = enum(i32) {
    normal = 0,
    random = 1,
    sequential = 2,
    willneed = 3,
    dontneed = 4,
    remove = 9,
    dontfork = 10,
    dofork = 11,
    hwpoison = 100,
    mergeable = 12,
    unmergeable = 13,
    hugepage = 14,
    nohugepage = 15,
    dontdump = 16,
    dodump = 17,
    
    pub fn toLinux(self: AdviceType) i32 {
        return switch (self) {
            .normal => linux.MADV.NORMAL,
            .random => linux.MADV.RANDOM,
            .sequential => linux.MADV.SEQUENTIAL,
            .willneed => linux.MADV.WILLNEED,
            .dontneed => linux.MADV.DONTNEED,
            .remove => linux.MADV.REMOVE,
            .dontfork => linux.MADV.DONTFORK,
            .dofork => linux.MADV.DOFORK,
            .hwpoison => linux.MADV.HWPOISON,
            .mergeable => linux.MADV.MERGEABLE,
            .unmergeable => linux.MADV.UNMERGEABLE,
            .hugepage => linux.MADV.HUGEPAGE,
            .nohugepage => linux.MADV.NOHUGEPAGE,
            .dontdump => linux.MADV.DONTDUMP,
            .dodump => linux.MADV.DODUMP,
        };
    }
};

pub const SyncFlags = enum(i32) {
    sync = 4,
    async_flag = 1,
    invalidate = 2,
    
    pub fn toLinux(self: SyncFlags) i32 {
        return switch (self) {
            .sync => linux.MS.SYNC,
            .async_flag => linux.MS.ASYNC,
            .invalidate => linux.MS.INVALIDATE,
        };
    }
};

pub const MmapRegion = struct {
    address: usize,
    length: usize,
    protection: MemoryProtection,
    flags: i32,
    file_descriptor: ?i32,
    offset: i64,
    creation_time: i64,
    access_count: u64,
    last_access: i64,
    is_locked: bool,
    
    const Self = @This();
    
    pub fn init(address: usize, length: usize, protection: MemoryProtection, flags: i32, fd: ?i32, offset: i64) Self {
        const now = @as(i64, std.posix.clock_gettime(.REALTIME).sec);
        return Self{
            .address = address,
            .length = length,
            .protection = protection,
            .flags = flags,
            .file_descriptor = fd,
            .offset = offset,
            .creation_time = now,
            .access_count = 0,
            .last_access = now,
            .is_locked = false,
        };
    }
    
    pub fn contains(self: *const Self, addr: usize) bool {
        return addr >= self.address and addr < self.address + self.length;
    }
    
    pub fn updateAccess(self: *Self) void {
        self.access_count += 1;
        self.last_access = @as(i64, std.posix.clock_gettime(.REALTIME).sec);
    }
    
    pub fn asSlice(self: *const Self) []u8 {
        return @as([*]u8, @ptrFromInt(self.address))[0..self.length];
    }
    
    pub fn asSliceTyped(self: *const Self, comptime T: type) []T {
        const byte_slice = self.asSlice();
        return std.mem.bytesAsSlice(T, byte_slice);
    }
};

const RegionMap = HashMap(usize, MmapRegion, std.hash_map.AutoContext(usize), std.hash_map.default_max_load_percentage);

pub const AsyncMmapManager = struct {
    allocator: Allocator,
    syscall_executor: *syscall_async.AsyncSyscallExecutor,
    regions: RegionMap,
    region_mutex: compat.Mutex,
    page_size: usize,
    total_mapped_size: usize,
    max_mapped_size: usize,
    stats: MmapStats,
    
    const Self = @This();
    
    pub fn init(allocator: Allocator, syscall_executor: *syscall_async.AsyncSyscallExecutor) Self {
        return Self{
            .allocator = allocator,
            .syscall_executor = syscall_executor,
            .regions = RegionMap.init(allocator),
            .region_mutex = compat.Mutex{},
            .page_size = std.mem.page_size,
            .total_mapped_size = 0,
            .max_mapped_size = 1024 * 1024 * 1024, // 1GB default limit
            .stats = MmapStats.init(),
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.region_mutex.lock();
        defer self.region_mutex.unlock();
        
        // Unmap all regions
        var iterator = self.regions.iterator();
        while (iterator.next()) |entry| {
            // Note: In a real implementation, we'd want to unmap these properly
            _ = entry;
        }
        
        self.regions.deinit();
    }
    
    pub fn setMaxMappedSize(self: *Self, max_size: usize) void {
        self.max_mapped_size = max_size;
    }
    
    fn alignToPageSize(self: *Self, size: usize) usize {
        const remainder = size % self.page_size;
        if (remainder == 0) {
            return size;
        }
        return size + (self.page_size - remainder);
    }
    
    pub fn mmapAsync(self: *Self, io_context: *io.Io, length: usize, protection: MemoryProtection, flags: i32, fd: ?i32, offset: i64) !*MmapRegion {
        _ = io_context;
        
        const aligned_length = self.alignToPageSize(length);
        
        // Check size limits
        if (self.total_mapped_size + aligned_length > self.max_mapped_size) {
            return MmapError.InsufficientMemory;
        }
        
        // Create syscall request
        var request = syscall_async.SyscallRequest.init(linux.SYS.mmap);
        request.addArg(0); // addr = NULL (let kernel choose)
        request.addArg(aligned_length);
        request.addArg(@bitCast(@as(usize, @intCast(protection.toLinux()))));
        request.addArg(@bitCast(@as(usize, @intCast(flags))));
        request.addArg(@bitCast(@as(usize, @intCast(fd orelse -1))));
        request.addArg(@bitCast(@as(usize, @intCast(offset))));
        
        try self.syscall_executor.submitRequest(request);
        
        // For this implementation, we'll simulate the mapping
        // In a real async implementation, we'd wait for the syscall result
        const simulated_address = 0x100000000; // Placeholder address
        
        const region = MmapRegion.init(simulated_address, aligned_length, protection, flags, fd, offset);
        
        // Register the region
        {
            self.region_mutex.lock();
            defer self.region_mutex.unlock();
            
            try self.regions.put(simulated_address, region);
            self.total_mapped_size += aligned_length;
        }
        
        self.stats.recordMapping(aligned_length);
        
        return self.regions.getPtr(simulated_address).?;
    }
    
    pub fn munmapAsync(self: *Self, io_context: *io.Io, region: *MmapRegion) !void {
        _ = io_context;
        
        // Create syscall request
        var request = syscall_async.SyscallRequest.init(linux.SYS.munmap);
        request.addArg(region.address);
        request.addArg(region.length);
        
        try self.syscall_executor.submitRequest(request);
        
        // Remove from our tracking
        {
            self.region_mutex.lock();
            defer self.region_mutex.unlock();
            
            if (self.regions.fetchRemove(region.address)) |removed| {
                self.total_mapped_size -= removed.value.length;
                self.stats.recordUnmapping(removed.value.length);
            }
        }
    }
    
    pub fn msyncAsync(self: *Self, io_context: *io.Io, region: *MmapRegion, sync_flags: SyncFlags) !void {
        _ = io_context;
        
        var request = syscall_async.SyscallRequest.init(linux.SYS.msync);
        request.addArg(region.address);
        request.addArg(region.length);
        request.addArg(@bitCast(@as(usize, @intCast(sync_flags.toLinux()))));
        
        try self.syscall_executor.submitRequest(request);
        
        self.stats.recordSync();
    }
    
    pub fn madviseAsync(self: *Self, io_context: *io.Io, region: *MmapRegion, advice: AdviceType) !void {
        _ = io_context;
        
        var request = syscall_async.SyscallRequest.init(linux.SYS.madvise);
        request.addArg(region.address);
        request.addArg(region.length);
        request.addArg(@bitCast(@as(usize, @intCast(advice.toLinux()))));
        
        try self.syscall_executor.submitRequest(request);
        
        self.stats.recordAdvice();
    }
    
    pub fn mlockAsync(self: *Self, io_context: *io.Io, region: *MmapRegion) !void {
        _ = io_context;
        
        var request = syscall_async.SyscallRequest.init(linux.SYS.mlock);
        request.addArg(region.address);
        request.addArg(region.length);
        
        try self.syscall_executor.submitRequest(request);
        
        region.is_locked = true;
        self.stats.recordLock();
    }
    
    pub fn munlockAsync(self: *Self, io_context: *io.Io, region: *MmapRegion) !void {
        _ = io_context;
        
        var request = syscall_async.SyscallRequest.init(linux.SYS.munlock);
        request.addArg(region.address);
        request.addArg(region.length);
        
        try self.syscall_executor.submitRequest(request);
        
        region.is_locked = false;
        self.stats.recordUnlock();
    }
    
    pub fn mprotectAsync(self: *Self, io_context: *io.Io, region: *MmapRegion, new_protection: MemoryProtection) !void {
        _ = io_context;
        
        var request = syscall_async.SyscallRequest.init(linux.SYS.mprotect);
        request.addArg(region.address);
        request.addArg(region.length);
        request.addArg(@bitCast(@as(usize, @intCast(new_protection.toLinux()))));
        
        try self.syscall_executor.submitRequest(request);
        
        region.protection = new_protection;
        self.stats.recordProtect();
    }
    
    pub fn findRegion(self: *Self, address: usize) ?*MmapRegion {
        self.region_mutex.lock();
        defer self.region_mutex.unlock();
        
        var iterator = self.regions.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.contains(address)) {
                entry.value_ptr.updateAccess();
                return entry.value_ptr;
            }
        }
        
        return null;
    }
    
    pub fn getAllRegions(self: *Self) ![]MmapRegion {
        self.region_mutex.lock();
        defer self.region_mutex.unlock();
        
        var regions = try self.allocator.alloc(MmapRegion, self.regions.count());
        var i: usize = 0;
        
        var iterator = self.regions.iterator();
        while (iterator.next()) |entry| {
            regions[i] = entry.value_ptr.*;
            i += 1;
        }
        
        return regions;
    }
    
    pub fn getTotalMappedSize(self: *Self) usize {
        return self.total_mapped_size;
    }
    
    pub fn getStats(self: *Self) MmapStats {
        return self.stats;
    }
};

pub const MmapStats = struct {
    total_mappings: std.atomic.Value(u64),
    total_unmappings: std.atomic.Value(u64),
    total_bytes_mapped: std.atomic.Value(u64),
    total_bytes_unmapped: std.atomic.Value(u64),
    sync_operations: std.atomic.Value(u64),
    advice_operations: std.atomic.Value(u64),
    lock_operations: std.atomic.Value(u64),
    unlock_operations: std.atomic.Value(u64),
    protect_operations: std.atomic.Value(u64),
    
    const Self = @This();
    
    pub fn init() Self {
        return Self{
            .total_mappings = std.atomic.Value(u64).init(0),
            .total_unmappings = std.atomic.Value(u64).init(0),
            .total_bytes_mapped = std.atomic.Value(u64).init(0),
            .total_bytes_unmapped = std.atomic.Value(u64).init(0),
            .sync_operations = std.atomic.Value(u64).init(0),
            .advice_operations = std.atomic.Value(u64).init(0),
            .lock_operations = std.atomic.Value(u64).init(0),
            .unlock_operations = std.atomic.Value(u64).init(0),
            .protect_operations = std.atomic.Value(u64).init(0),
        };
    }
    
    pub fn recordMapping(self: *Self, size: usize) void {
        _ = self.total_mappings.fetchAdd(1, .seq_cst);
        _ = self.total_bytes_mapped.fetchAdd(size, .seq_cst);
    }
    
    pub fn recordUnmapping(self: *Self, size: usize) void {
        _ = self.total_unmappings.fetchAdd(1, .seq_cst);
        _ = self.total_bytes_unmapped.fetchAdd(size, .seq_cst);
    }
    
    pub fn recordSync(self: *Self) void {
        _ = self.sync_operations.fetchAdd(1, .seq_cst);
    }
    
    pub fn recordAdvice(self: *Self) void {
        _ = self.advice_operations.fetchAdd(1, .seq_cst);
    }
    
    pub fn recordLock(self: *Self) void {
        _ = self.lock_operations.fetchAdd(1, .seq_cst);
    }
    
    pub fn recordUnlock(self: *Self) void {
        _ = self.unlock_operations.fetchAdd(1, .seq_cst);
    }
    
    pub fn recordProtect(self: *Self) void {
        _ = self.protect_operations.fetchAdd(1, .seq_cst);
    }
    
    pub fn getCurrentlyMappedBytes(self: *Self) u64 {
        const mapped = self.total_bytes_mapped.load(.seq_cst);
        const unmapped = self.total_bytes_unmapped.load(.seq_cst);
        return mapped - unmapped;
    }
};

// Shared memory operations
pub const AsyncSharedMemory = struct {
    mmap_manager: *AsyncMmapManager,
    shared_regions: HashMap([]const u8, *MmapRegion, std.hash_map.StringContext, std.hash_map.default_max_load_percentage),
    shared_mutex: compat.Mutex,
    
    const Self = @This();
    
    pub fn init(allocator: Allocator, mmap_manager: *AsyncMmapManager) Self {
        return Self{
            .mmap_manager = mmap_manager,
            .shared_regions = HashMap([]const u8, *MmapRegion, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator),
            .shared_mutex = compat.Mutex{},
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.shared_mutex.lock();
        defer self.shared_mutex.unlock();
        
        var iterator = self.shared_regions.iterator();
        while (iterator.next()) |entry| {
            self.mmap_manager.allocator.free(entry.key_ptr.*);
        }
        self.shared_regions.deinit();
    }
    
    pub fn createSharedRegion(self: *Self, io_context: *io.Io, name: []const u8, size: usize, protection: MemoryProtection) !*MmapRegion {
        const flags = MappingFlags.shared.toLinux() | MappingFlags.anonymous.toLinux();
        const region = try self.mmap_manager.mmapAsync(io_context, size, protection, flags, null, 0);
        
        self.shared_mutex.lock();
        defer self.shared_mutex.unlock();
        
        const owned_name = try self.mmap_manager.allocator.dupe(u8, name);
        try self.shared_regions.put(owned_name, region);
        
        return region;
    }
    
    pub fn getSharedRegion(self: *Self, name: []const u8) ?*MmapRegion {
        self.shared_mutex.lock();
        defer self.shared_mutex.unlock();
        
        return self.shared_regions.get(name);
    }
    
    pub fn removeSharedRegion(self: *Self, io_context: *io.Io, name: []const u8) !void {
        self.shared_mutex.lock();
        defer self.shared_mutex.unlock();
        
        if (self.shared_regions.fetchRemove(name)) |removed| {
            defer self.mmap_manager.allocator.free(removed.key);
            try self.mmap_manager.munmapAsync(io_context, removed.value);
        }
    }
};

// Memory-mapped file operations
pub const AsyncMmapFile = struct {
    region: *MmapRegion,
    file_path: []const u8,
    file_size: usize,
    mmap_manager: *AsyncMmapManager,
    
    const Self = @This();
    
    pub fn open(allocator: Allocator, mmap_manager: *AsyncMmapManager, io_context: *io.Io, file_path: []const u8, protection: MemoryProtection, flags: i32) !Self {
        _ = io_context;
        
        // In a real implementation, we'd open the file and get its size
        // For now, we'll simulate this
        const file_size = 4096; // Simulated file size
        const fd = 3; // Simulated file descriptor
        
        const region = try mmap_manager.mmapAsync(io_context, file_size, protection, flags, fd, 0);
        
        return Self{
            .region = region,
            .file_path = try allocator.dupe(u8, file_path),
            .file_size = file_size,
            .mmap_manager = mmap_manager,
        };
    }
    
    pub fn deinit(self: *Self, allocator: Allocator, io_context: *io.Io) void {
        self.mmap_manager.munmapAsync(io_context, self.region) catch {};
        allocator.free(self.file_path);
    }
    
    pub fn sync(self: *Self, io_context: *io.Io) !void {
        try self.mmap_manager.msyncAsync(io_context, self.region, SyncFlags.sync);
    }
    
    pub fn asyncSync(self: *Self, io_context: *io.Io) !void {
        try self.mmap_manager.msyncAsync(io_context, self.region, SyncFlags.async_flag);
    }
    
    pub fn adviseSequential(self: *Self, io_context: *io.Io) !void {
        try self.mmap_manager.madviseAsync(io_context, self.region, AdviceType.sequential);
    }
    
    pub fn adviseRandom(self: *Self, io_context: *io.Io) !void {
        try self.mmap_manager.madviseAsync(io_context, self.region, AdviceType.random);
    }
    
    pub fn adviseWillNeed(self: *Self, io_context: *io.Io) !void {
        try self.mmap_manager.madviseAsync(io_context, self.region, AdviceType.willneed);
    }
    
    pub fn adviseDontNeed(self: *Self, io_context: *io.Io) !void {
        try self.mmap_manager.madviseAsync(io_context, self.region, AdviceType.dontneed);
    }
    
    pub fn getData(self: *Self) []u8 {
        return self.region.asSlice();
    }
    
    pub fn getDataTyped(self: *Self, comptime T: type) []T {
        return self.region.asSliceTyped(T);
    }
};

// Example usage and testing
test "memory protection enum conversion" {
    try testing.expect(MemoryProtection.read.toLinux() == linux.PROT.READ);
    try testing.expect(MemoryProtection.read_write.toLinux() == (linux.PROT.READ | linux.PROT.WRITE));
}

test "mmap region creation" {
    const region = MmapRegion.init(0x1000, 4096, MemoryProtection.read_write, 0, null, 0);
    
    try testing.expect(region.address == 0x1000);
    try testing.expect(region.length == 4096);
    try testing.expect(region.protection == MemoryProtection.read_write);
    try testing.expect(region.contains(0x1500));
    try testing.expect(!region.contains(0x2000));
}

test "async mmap manager initialization" {
    var syscall_executor = syscall_async.AsyncSyscallExecutor.init(testing.allocator, 4);
    defer syscall_executor.deinit();
    
    var mmap_manager = AsyncMmapManager.init(testing.allocator, &syscall_executor);
    defer mmap_manager.deinit();
    
    try testing.expect(mmap_manager.page_size == std.mem.page_size);
    try testing.expect(mmap_manager.total_mapped_size == 0);
}

test "shared memory operations" {
    var syscall_executor = syscall_async.AsyncSyscallExecutor.init(testing.allocator, 4);
    defer syscall_executor.deinit();
    
    var mmap_manager = AsyncMmapManager.init(testing.allocator, &syscall_executor);
    defer mmap_manager.deinit();
    
    var shared_memory = AsyncSharedMemory.init(testing.allocator, &mmap_manager);
    defer shared_memory.deinit();
    
    // This would require a real I/O context in practice
    // const region = try shared_memory.createSharedRegion(&io_context, "test_region", 4096, MemoryProtection.read_write);
    // try testing.expect(region != null);
}

test "mmap stats tracking" {
    var stats = MmapStats.init();
    
    stats.recordMapping(4096);
    stats.recordSync();
    stats.recordLock();
    
    try testing.expect(stats.total_mappings.load(.seq_cst) == 1);
    try testing.expect(stats.total_bytes_mapped.load(.seq_cst) == 4096);
    try testing.expect(stats.sync_operations.load(.seq_cst) == 1);
    try testing.expect(stats.lock_operations.load(.seq_cst) == 1);
}