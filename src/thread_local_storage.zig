//! zsync - Thread-Local Storage Management
//! Provides efficient per-thread storage with automatic cleanup

const std = @import("std");

/// Thread-local storage key
pub const TlsKey = struct {
    key: u32,
    destructor: ?*const fn (*anyopaque) void = null,
    
    const Self = @This();
    
    /// Create a new TLS key with optional destructor
    pub fn create(destructor: ?*const fn (*anyopaque) void) !Self {
        const key = TlsRegistry.instance.allocateKey(destructor);
        return Self{
            .key = key,
            .destructor = destructor,
        };
    }
    
    /// Set value for current thread
    pub fn set(self: Self, value: *anyopaque) !void {
        return TlsRegistry.instance.setValue(self.key, value);
    }
    
    /// Get value for current thread
    pub fn get(self: Self) ?*anyopaque {
        return TlsRegistry.instance.getValue(self.key);
    }
    
    /// Get typed value for current thread
    pub fn getTyped(self: Self, comptime T: type) ?*T {
        if (self.get()) |ptr| {
            return @ptrCast(@alignCast(ptr));
        }
        return null;
    }
    
    /// Set typed value for current thread  
    pub fn setTyped(self: Self, value: anytype) !void {
        return self.set(@ptrCast(value));
    }
    
    /// Destroy the TLS key
    pub fn destroy(self: *Self) void {
        TlsRegistry.instance.deallocateKey(self.key);
        self.* = undefined;
    }
};

/// Per-thread storage entry
const TlsEntry = struct {
    value: ?*anyopaque = null,
    destructor: ?*const fn (*anyopaque) void = null,
};

/// Per-thread storage table
const ThreadStorage = struct {
    entries: std.ArrayList(TlsEntry),
    allocator: std.mem.Allocator,
    thread_id: std.Thread.Id,
    
    const Self = @This();
    
    fn init(allocator: std.mem.Allocator, thread_id: std.Thread.Id) Self {
        return Self{
            .entries = std.ArrayList(TlsEntry){ .allocator = allocator },
            .allocator = allocator,
            .thread_id = thread_id,
        };
    }
    
    fn deinit(self: *Self) void {
        // Run destructors for non-null values
        for (self.entries.items) |entry| {
            if (entry.value) |value| {
                if (entry.destructor) |destructor| {
                    destructor(value);
                }
            }
        }
        self.entries.deinit();
    }
    
    fn setValue(self: *Self, key: u32, value: *anyopaque, destructor: ?*const fn (*anyopaque) void) !void {
        // Ensure we have enough slots
        if (key >= self.entries.items.len) {
            try self.entries.resize(key + 1);
        }
        
        // Call destructor for existing value if present
        if (self.entries.items[key].value) |old_value| {
            if (self.entries.items[key].destructor) |old_destructor| {
                old_destructor(old_value);
            }
        }
        
        self.entries.items[key] = TlsEntry{
            .value = value,
            .destructor = destructor,
        };
    }
    
    fn getValue(self: *Self, key: u32) ?*anyopaque {
        if (key >= self.entries.items.len) return null;
        return self.entries.items[key].value;
    }
};

/// Global TLS registry - manages keys and per-thread storage
const TlsRegistry = struct {
    allocator: std.mem.Allocator,
    thread_storage: std.HashMap(std.Thread.Id, *ThreadStorage, ThreadIdContext, std.hash_map.default_max_load_percentage),
    storage_mutex: std.Thread.Mutex = .{},
    next_key: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    key_destructors: std.ArrayList(?*const fn (*anyopaque) void),
    destructors_mutex: std.Thread.Mutex = .{},
    
    // Thread-local to avoid hash map lookup on every access
    threadlocal var current_thread_storage: ?*ThreadStorage = null;
    
    const Self = @This();
    
    // Singleton instance
    var instance: Self = undefined;
    var instance_initialized: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
    
    /// Initialize the global TLS registry
    pub fn init(allocator: std.mem.Allocator) !void {
        if (instance_initialized.cmpxchgWeak(false, true, .acq_rel, .monotonic) == null) {
            instance = Self{
                .allocator = allocator,
                .thread_storage = std.HashMap(std.Thread.Id, *ThreadStorage, ThreadIdContext, std.hash_map.default_max_load_percentage).init(allocator),
                .key_destructors = std.ArrayList(?*const fn (*anyopaque) void){ .allocator = allocator },
            };
        }
    }
    
    /// Deinitialize the global TLS registry
    pub fn deinit() void {
        if (instance_initialized.cmpxchgWeak(true, false, .acq_rel, .monotonic) == null) {
            instance.storage_mutex.lock();
            defer instance.storage_mutex.unlock();
            
            // Clean up all thread storage
            var iterator = instance.thread_storage.iterator();
            while (iterator.next()) |entry| {
                entry.value_ptr.*.deinit();
                instance.allocator.destroy(entry.value_ptr.*);
            }
            instance.thread_storage.deinit();
            instance.key_destructors.deinit();
        }
    }
    
    /// Register current thread for TLS (called automatically)
    fn registerCurrentThread(self: *Self) !*ThreadStorage {
        const thread_id = std.Thread.getCurrentId();
        
        self.storage_mutex.lock();
        defer self.storage_mutex.unlock();
        
        if (self.thread_storage.get(thread_id)) |storage| {
            current_thread_storage = storage;
            return storage;
        }
        
        const storage = try self.allocator.create(ThreadStorage);
        storage.* = ThreadStorage.init(self.allocator, thread_id);
        try self.thread_storage.put(thread_id, storage);
        current_thread_storage = storage;
        return storage;
    }
    
    /// Get current thread storage (creates if doesn't exist)
    fn getCurrentThreadStorage(self: *Self) !*ThreadStorage {
        if (current_thread_storage) |storage| {
            return storage;
        }
        return self.registerCurrentThread();
    }
    
    /// Allocate a new TLS key
    fn allocateKey(self: *Self, destructor: ?*const fn (*anyopaque) void) u32 {
        const key = self.next_key.fetchAdd(1, .acq_rel);
        
        self.destructors_mutex.lock();
        defer self.destructors_mutex.unlock();
        
        // Ensure we have space for this key
        if (key >= self.key_destructors.items.len) {
            self.key_destructors.resize(key + 1) catch {
                // If we can't resize, just don't store the destructor
                return key;
            };
        }
        
        self.key_destructors.items[key] = destructor;
        return key;
    }
    
    /// Deallocate a TLS key (mark as unused)
    fn deallocateKey(self: *Self, key: u32) void {
        self.destructors_mutex.lock();
        defer self.destructors_mutex.unlock();
        
        if (key < self.key_destructors.items.len) {
            self.key_destructors.items[key] = null;
        }
    }
    
    /// Set value for key in current thread
    fn setValue(self: *Self, key: u32, value: *anyopaque) !void {
        const storage = try self.getCurrentThreadStorage();
        
        // Get destructor for this key
        self.destructors_mutex.lock();
        const destructor = if (key < self.key_destructors.items.len) 
            self.key_destructors.items[key] else null;
        self.destructors_mutex.unlock();
        
        try storage.setValue(key, value, destructor);
    }
    
    /// Get value for key in current thread
    fn getValue(self: *Self, key: u32) ?*anyopaque {
        const storage = self.getCurrentThreadStorage() catch return null;
        return storage.getValue(key);
    }
    
    /// Cleanup current thread's TLS data (called when thread exits)
    pub fn cleanupCurrentThread() void {
        if (!instance_initialized.load(.acquire)) return;
        
        const thread_id = std.Thread.getCurrentId();
        
        instance.storage_mutex.lock();
        defer instance.storage_mutex.unlock();
        
        if (instance.thread_storage.fetchRemove(thread_id)) |kv| {
            kv.value.deinit();
            instance.allocator.destroy(kv.value);
        }
        
        current_thread_storage = null;
    }
};

/// Context for thread ID hash map
const ThreadIdContext = struct {
    pub fn hash(self: @This(), thread_id: std.Thread.Id) u64 {
        return std.hash_map.getAutoHashFn(std.Thread.Id, @This())(self, thread_id);
    }
    
    pub fn eql(self: @This(), a: std.Thread.Id, b: std.Thread.Id) bool {
        _ = self;
        return a == b;
    }
};

/// Convenience wrapper for typed thread-local storage
pub fn ThreadLocal(comptime T: type) type {
    return struct {
        key: TlsKey,
        
        const Self = @This();
        
        /// Initialize thread-local storage for type T
        pub fn init() !Self {
            return Self{
                .key = try TlsKey.create(if (std.meta.hasMethod(T, "deinit")) deinitValue else null),
            };
        }
        
        /// Deinitialize thread-local storage
        pub fn deinit(self: *Self) void {
            self.key.destroy();
        }
        
        /// Get current thread's value
        pub fn get(self: *Self) ?*T {
            return self.key.getTyped(T);
        }
        
        /// Set current thread's value
        pub fn set(self: *Self, value: *T) !void {
            try self.key.setTyped(value);
        }
        
        /// Get or create current thread's value
        pub fn getOrInit(self: *Self, allocator: std.mem.Allocator) !*T {
            if (self.get()) |value| {
                return value;
            }
            
            const value = try allocator.create(T);
            // Call init method (all types used with TLS must have init)
            value.* = T.init(allocator);
            
            try self.set(value);
            return value;
        }
        
        fn deinitValue(ptr: *anyopaque) void {
            const value: *T = @ptrCast(@alignCast(ptr));
            if (std.meta.hasMethod(T, "deinit")) {
                value.deinit();
            }
            // Note: We can't free the memory here without knowing the allocator
            // Users should call deinitAndFree explicitly if needed
        }
    };
}

/// Initialize global TLS system
pub fn init(allocator: std.mem.Allocator) !void {
    try TlsRegistry.init(allocator);
}

/// Cleanup global TLS system
pub fn deinit() void {
    TlsRegistry.deinit();
}

/// Cleanup current thread's TLS data (should be called before thread exit)
pub fn cleanupCurrentThread() void {
    TlsRegistry.cleanupCurrentThread();
}

test "thread local storage basic operations" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    try init(allocator);
    defer deinit();
    
    // Test basic TLS key operations
    var key = try TlsKey.create(null);
    defer key.destroy();
    
    var value: i32 = 42;
    try key.set(@ptrCast(&value));
    
    const retrieved = key.getTyped(i32);
    try std.testing.expect(retrieved != null);
    try std.testing.expectEqual(@as(i32, 42), retrieved.?.*);
}

test "typed thread local storage" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    try init(allocator);
    defer deinit();
    
    var tls = try ThreadLocal(i32).init();
    defer tls.deinit();
    
    var value: i32 = 123;
    try tls.set(&value);
    
    const retrieved = tls.get();
    try std.testing.expect(retrieved != null);
    try std.testing.expectEqual(@as(i32, 123), retrieved.?.*);
}