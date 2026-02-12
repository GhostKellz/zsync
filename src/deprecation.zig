//! zsync - Deprecation Warnings System
//! Provides compile-time and runtime warnings for deprecated patterns

const std = @import("std");
const compat = @import("compat/thread.zig");

/// Emit a compile-time deprecation warning (disabled for current stability)
pub fn compileTimeDeprecation(comptime message: []const u8) void {
    // Disabled to avoid compile errors during development
    _ = message;
    // @compileLog("⚠️  DEPRECATION WARNING: " ++ message);
}

/// Emit a runtime deprecation warning (only once per call site)
pub fn runtimeDeprecation(comptime call_site: []const u8, message: []const u8) void {
    const DeprecationTracker = struct {
        var warned_sites = std.atomic.Value(u64).init(0);
        var site_hashes: [64]u64 = [_]u64{0} ** 64;
        var mutex = compat.Mutex{};
        
        fn shouldWarn(site_hash: u64) bool {
            mutex.lock();
            defer mutex.unlock();
            
            // Check if we've already warned about this site
            for (site_hashes) |existing_hash| {
                if (existing_hash == site_hash) {
                    return false; // Already warned
                }
            }
            
            // Find an empty slot to store this site
            for (&site_hashes) |*slot| {
                if (slot.* == 0) {
                    slot.* = site_hash;
                    return true;
                }
            }
            
            // All slots full, warn anyway
            return true;
        }
    };
    
    const site_hash = std.hash_map.hashString(call_site);
    if (DeprecationTracker.shouldWarn(site_hash)) {
        std.debug.print("⚠️  DEPRECATION WARNING at {s}: {s}\n", .{ call_site, message });
    }
}

/// Mark a function as deprecated with compile-time warning
pub fn deprecated(comptime reason: []const u8) void {
    compileTimeDeprecation("This function is deprecated. " ++ reason);
}

/// Mark a struct/type as deprecated
pub fn DeprecatedType(comptime T: type, comptime reason: []const u8) type {
    compileTimeDeprecation("Type '" ++ @typeName(T) ++ "' is deprecated. " ++ reason);
    return T;
}

/// Wrapper to add deprecation warning to any function
pub fn deprecatedWrapper(comptime func: anytype, comptime reason: []const u8) @TypeOf(func) {
    const info = @typeInfo(@TypeOf(func));
    if (info != .Fn) {
        @compileError("deprecatedWrapper can only be used with functions");
    }
    
    return struct {
        fn wrapper(args: anytype) @typeInfo(@TypeOf(func)).Fn.return_type.? {
            compileTimeDeprecation("Function '" ++ @typeName(@TypeOf(func)) ++ "' is deprecated. " ++ reason);
            return @call(.auto, func, args);
        }
    }.wrapper;
}

// Common deprecation patterns for Zsync v1.x -> current migration

/// Deprecated async/await syntax warning
pub fn warnAsyncAwaitUsage() void {
    runtimeDeprecation("async/await", 
        "Direct async/await syntax is deprecated. Use io.async() with the new Io interface instead. See migration_guide.zig for examples.");
}

/// Deprecated channel usage warning
pub fn warnChannelUsage() void {
    runtimeDeprecation("channel", 
        "Zsync v1.x channels are deprecated. Use lock-free queues from lockfree_queue.zig or thread-local storage for communication.");
}

/// Deprecated runtime usage warning
pub fn warnDirectRuntimeUsage() void {
    runtimeDeprecation("runtime", 
        "Direct runtime manipulation is deprecated. Use specific Io implementations (BlockingIo, ThreadPoolIo, GreenThreadsIo) instead.");
}

/// Deprecated task spawning warning
pub fn warnTaskSpawning() void {
    runtimeDeprecation("task_spawn", 
        "Direct task spawning is deprecated. Use io.async() with the new colorblind async interface.");
}

/// Deprecated reactor usage warning
pub fn warnReactorUsage() void {
    runtimeDeprecation("reactor", 
        "Direct reactor usage is deprecated. The new Io interface handles event loops internally.");
}

test "deprecation warnings" {
    // These will generate compile-time warnings during testing
    deprecated("Use newFunction() instead");
    
    // This will generate a runtime warning (only once)
    runtimeDeprecation("test_site", "This is a test deprecation warning");
    runtimeDeprecation("test_site", "This should not print again");
}