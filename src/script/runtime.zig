//! Zsync v0.6.0 - Script Runtime Integration
//! Helpers for integrating Ghostlang and other script engines with zsync async

const std = @import("std");
const compat = @import("../compat/thread.zig");
const Runtime = @import("../runtime.zig").Runtime;
const channels = @import("../channels.zig");

/// Script Value Types
pub const ScriptValue = union(enum) {
    nil,
    boolean: bool,
    number: f64,
    string: []const u8,
    function: *anyopaque,
    object: *anyopaque,
    array: []ScriptValue,
    userdata: *anyopaque,

    pub fn fromBool(b: bool) ScriptValue {
        return .{ .boolean = b };
    }

    pub fn fromNumber(n: f64) ScriptValue {
        return .{ .number = n };
    }

    pub fn fromString(s: []const u8) ScriptValue {
        return .{ .string = s };
    }

    pub fn isNil(self: ScriptValue) bool {
        return self == .nil;
    }

    pub fn toBool(self: ScriptValue) bool {
        return switch (self) {
            .nil => false,
            .boolean => |b| b,
            .number => |n| n != 0.0,
            .string => |s| s.len > 0,
            else => true,
        };
    }

    pub fn toNumber(self: ScriptValue) ?f64 {
        return switch (self) {
            .number => |n| n,
            .boolean => |b| if (b) 1.0 else 0.0,
            else => null,
        };
    }
};

/// Script Engine Interface
pub const ScriptEngine = struct {
    allocator: std.mem.Allocator,
    runtime: *Runtime,
    global_env: std.StringHashMap(ScriptValue),
    mutex: compat.Mutex,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, runtime: *Runtime) Self {
        return Self{
            .allocator = allocator,
            .runtime = runtime,
            .global_env = std.StringHashMap(ScriptValue).init(allocator),
            .mutex = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.global_env.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.global_env.deinit();
    }

    /// Set global variable
    pub fn setGlobal(self: *Self, name: []const u8, value: ScriptValue) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const owned_name = try self.allocator.dupe(u8, name);
        try self.global_env.put(owned_name, value);
    }

    /// Get global variable
    pub fn getGlobal(self: *Self, name: []const u8) ?ScriptValue {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.global_env.get(name);
    }

    /// Register Zig function callable from script
    pub fn registerFunction(
        self: *Self,
        name: []const u8,
        func: *const fn ([]const ScriptValue) ScriptValue,
    ) !void {
        _ = func;
        const owned_name = try self.allocator.dupe(u8, name);
        try self.global_env.put(owned_name, .{ .function = @ptrFromInt(1) });
    }
};

/// Async Script Task
pub const AsyncScriptTask = struct {
    engine: *ScriptEngine,
    code: []const u8,
    result: ?ScriptValue,
    error_msg: ?[]const u8,
    completed: std.atomic.Value(bool),

    const Self = @This();

    pub fn init(engine: *ScriptEngine, code: []const u8) Self {
        return Self{
            .engine = engine,
            .code = code,
            .result = null,
            .error_msg = null,
            .completed = std.atomic.Value(bool).init(false),
        };
    }

    /// Execute script asynchronously
    pub fn execute(self: *Self) !ScriptValue {
        // TODO: Actual script execution
        _ = self;
        return .nil;
    }

    /// Check if completed
    pub fn isCompleted(self: *const Self) bool {
        return self.completed.load(.acquire);
    }
};

/// Script Channel - bridge between Zig channels and script
pub fn ScriptChannel(comptime T: type) type {
    return struct {
        channel: channels.UnboundedChannel(T),
        allocator: std.mem.Allocator,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) !Self {
            return Self{
                .channel = try channels.unbounded(T, allocator),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.channel.deinit();
        }

        /// Send value (callable from script)
        pub fn send(self: *Self, value: T) !void {
            try self.channel.send(value);
        }

        /// Receive value (callable from script)
        pub fn recv(self: *Self) !T {
            return try self.channel.recv();
        }

        /// Try send (non-blocking, callable from script)
        pub fn trySend(self: *Self, value: T) bool {
            return self.channel.trySend(value) catch false;
        }

        /// Try receive (non-blocking, callable from script)
        pub fn tryRecv(self: *Self) ?T {
            return self.channel.tryRecv() catch null;
        }
    };
}

/// Async function wrapper for scripts
pub const AsyncFunction = struct {
    callback: *const fn ([]const ScriptValue) anyerror!ScriptValue,
    runtime: *Runtime,

    const Self = @This();

    /// Call function asynchronously
    pub fn callAsync(self: *Self, args: []const ScriptValue) !ScriptValue {
        _ = self;
        _ = args;
        // TODO: Spawn task to execute callback
        return .nil;
    }
};

/// Script-to-Zig FFI helpers
pub const FFI = struct {
    /// Call Zig function from script
    pub fn callZigFunction(
        comptime Fn: type,
        func: Fn,
        args: []const ScriptValue,
    ) !ScriptValue {
        _ = func;
        _ = args;
        // TODO: Convert script args to Zig types
        // TODO: Call function
        // TODO: Convert result back to ScriptValue
        return .nil;
    }

    /// Convert Zig value to script value
    pub fn toScriptValue(value: anytype) ScriptValue {
        const T = @TypeOf(value);
        return switch (@typeInfo(T)) {
            .Bool => ScriptValue.fromBool(value),
            .Int, .ComptimeInt, .Float, .ComptimeFloat => ScriptValue.fromNumber(@floatCast(value)),
            .Pointer => |ptr| switch (ptr.size) {
                .Slice => if (ptr.child == u8) ScriptValue.fromString(value) else .nil,
                else => .nil,
            },
            else => .nil,
        };
    }

    /// Convert script value to Zig value
    pub fn fromScriptValue(comptime T: type, value: ScriptValue) ?T {
        return switch (@typeInfo(T)) {
            .Bool => if (value == .boolean) value.boolean else null,
            .Int, .Float => if (value == .number) @as(T, @intFromFloat(value.number)) else null,
            .Pointer => |ptr| switch (ptr.size) {
                .Slice => if (ptr.child == u8 and value == .string) value.string else null,
                else => null,
            },
            else => null,
        };
    }
};

/// Script Timer - schedule callbacks
pub const ScriptTimer = struct {
    runtime: *Runtime,
    callback: *const fn () anyerror!void,
    interval_ms: u64,
    repeat: bool,
    active: std.atomic.Value(bool),

    const Self = @This();

    pub fn init(
        runtime: *Runtime,
        callback: *const fn () anyerror!void,
        interval_ms: u64,
        repeat: bool,
    ) Self {
        return Self{
            .runtime = runtime,
            .callback = callback,
            .interval_ms = interval_ms,
            .repeat = repeat,
            .active = std.atomic.Value(bool).init(true),
        };
    }

    /// Start timer
    pub fn start(self: *Self) !void {
        while (self.active.load(.acquire)) {
            std.posix.nanosleep(0, self.interval_ms * std.time.ns_per_ms);

            try self.callback();

            if (!self.repeat) break;
        }
    }

    /// Stop timer
    pub fn stop(self: *Self) void {
        self.active.store(false, .release);
    }
};

/// Script Event Emitter
pub fn ScriptEmitter(comptime T: type) type {
    return struct {
        listeners: std.ArrayList(*const fn (T) anyerror!void),
        allocator: std.mem.Allocator,
        mutex: compat.Mutex,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{
                .listeners = std.ArrayList(*const fn (T) anyerror!void){ .allocator = allocator },
                .allocator = allocator,
                .mutex = .{},
            };
        }

        pub fn deinit(self: *Self) void {
            self.listeners.deinit();
        }

        /// Register listener (callable from script)
        pub fn on(self: *Self, listener: *const fn (T) anyerror!void) !void {
            self.mutex.lock();
            defer self.mutex.unlock();
            try self.listeners.append(self.allocator, listener);
        }

        /// Remove listener (callable from script)
        pub fn off(self: *Self, listener: *const fn (T) anyerror!void) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            for (self.listeners.items, 0..) |l, i| {
                if (l == listener) {
                    _ = self.listeners.orderedRemove(i);
                    return;
                }
            }
        }

        /// Emit event (callable from script)
        pub fn emit(self: *Self, event: T) void {
            self.mutex.lock();
            const listeners = self.allocator.dupe(*const fn (T) anyerror!void, self.listeners.items) catch return;
            self.mutex.unlock();
            defer self.allocator.free(listeners);

            for (listeners) |listener| {
                listener(event) catch |err| {
                    std.debug.print("[ScriptEmitter] Error: {}\n", .{err});
                };
            }
        }
    };
}

// Tests
test "script value conversions" {
    const testing = std.testing;

    const v1 = ScriptValue.fromBool(true);
    try testing.expect(v1.toBool());

    const v2 = ScriptValue.fromNumber(42.0);
    try testing.expectEqual(42.0, v2.toNumber().?);

    const v3 = ScriptValue.fromString("hello");
    try testing.expect(std.mem.eql(u8, "hello", v3.string));
}

test "ffi type conversion" {
    const testing = std.testing;

    const sv1 = FFI.toScriptValue(true);
    try testing.expect(sv1.toBool());

    const sv2 = FFI.toScriptValue(@as(f64, 42.0));
    try testing.expectEqual(42.0, sv2.toNumber().?);

    const b = FFI.fromScriptValue(bool, ScriptValue.fromBool(true));
    try testing.expectEqual(true, b.?);
}
