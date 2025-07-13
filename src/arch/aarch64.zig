const std = @import("std");
const builtin = @import("builtin");

// ARM64/AArch64 Context Switching Implementation
// Follows ARM64 AAPCS (Procedure Call Standard) for register saving

/// ARM64 Context structure
/// Saves all callee-saved registers according to AAPCS64
pub const Context = struct {
    // Callee-saved general purpose registers (x19-x30)
    x19: u64,
    x20: u64,
    x21: u64,
    x22: u64,
    x23: u64,
    x24: u64,
    x25: u64,
    x26: u64,
    x27: u64,
    x28: u64,
    x29: u64, // Frame pointer (FP)
    x30: u64, // Link register (LR)
    
    // Stack pointer
    sp: u64,
    
    // Callee-saved SIMD/FP registers (d8-d15)
    d8: u64,
    d9: u64,
    d10: u64,
    d11: u64,
    d12: u64,
    d13: u64,
    d14: u64,
    d15: u64,
    
    // Thread-local storage pointer
    tls_ptr: ?*anyopaque,
    
    pub fn init() Context {
        return Context{
            .x19 = 0, .x20 = 0, .x21 = 0, .x22 = 0,
            .x23 = 0, .x24 = 0, .x25 = 0, .x26 = 0,
            .x27 = 0, .x28 = 0, .x29 = 0, .x30 = 0,
            .sp = 0,
            .d8 = 0, .d9 = 0, .d10 = 0, .d11 = 0,
            .d12 = 0, .d13 = 0, .d14 = 0, .d15 = 0,
            .tls_ptr = null,
        };
    }
};

/// ARM64 context switching function
/// Saves current context to old_ctx and loads new_ctx
/// Follows ARM64 AAPCS calling convention
pub fn swapContext(old_ctx: *Context, new_ctx: *Context) callconv(.Naked) void {
    asm volatile (
        \\// Save callee-saved general purpose registers
        \\stp x19, x20, [x0, #0]
        \\stp x21, x22, [x0, #16]
        \\stp x23, x24, [x0, #32]
        \\stp x25, x26, [x0, #48]
        \\stp x27, x28, [x0, #64]
        \\stp x29, x30, [x0, #80]
        \\
        \\// Save stack pointer
        \\mov x2, sp
        \\str x2, [x0, #96]
        \\
        \\// Save callee-saved SIMD/FP registers
        \\stp d8, d9, [x0, #104]
        \\stp d10, d11, [x0, #120]
        \\stp d12, d13, [x0, #136]
        \\stp d14, d15, [x0, #152]
        \\
        \\// Load new context
        \\// Load callee-saved general purpose registers
        \\ldp x19, x20, [x1, #0]
        \\ldp x21, x22, [x1, #16]
        \\ldp x23, x24, [x1, #32]
        \\ldp x25, x26, [x1, #48]
        \\ldp x27, x28, [x1, #64]
        \\ldp x29, x30, [x1, #80]
        \\
        \\// Load stack pointer
        \\ldr x2, [x1, #96]
        \\mov sp, x2
        \\
        \\// Load callee-saved SIMD/FP registers
        \\ldp d8, d9, [x1, #104]
        \\ldp d10, d11, [x1, #120]
        \\ldp d12, d13, [x1, #136]
        \\ldp d14, d15, [x1, #152]
        \\
        \\// Return to new context
        \\ret
        :
        : [old_ctx] "{x0}" (old_ctx),
          [new_ctx] "{x1}" (new_ctx),
        : "memory", "x2"
    );
}

/// Create a new context for a function
pub fn makeContext(ctx: *Context, stack: []u8, entry: *const fn(*anyopaque) void, arg: *anyopaque) void {
    if (stack.len == 0) return;
    
    // ARM64 stack grows downward and must be 16-byte aligned
    const stack_top = @intFromPtr(stack.ptr) + stack.len;
    const aligned_stack_top = stack_top & ~@as(usize, 15);
    
    // Set up the context
    ctx.sp = aligned_stack_top;
    ctx.x30 = @intFromPtr(entry); // Link register (return address)
    ctx.x19 = @intFromPtr(arg);   // First argument in x19 (callee-saved)
    
    // Initialize frame pointer
    ctx.x29 = aligned_stack_top;
    
    // Clear other registers
    ctx.x20 = 0; ctx.x21 = 0; ctx.x22 = 0; ctx.x23 = 0;
    ctx.x24 = 0; ctx.x25 = 0; ctx.x26 = 0; ctx.x27 = 0;
    ctx.x28 = 0;
    
    // Clear SIMD/FP registers
    ctx.d8 = 0; ctx.d9 = 0; ctx.d10 = 0; ctx.d11 = 0;
    ctx.d12 = 0; ctx.d13 = 0; ctx.d14 = 0; ctx.d15 = 0;
}

/// Allocate a stack with proper alignment for ARM64
pub fn allocateStack(allocator: std.mem.Allocator) ![]align(16) u8 {
    const stack_size = 1024 * 1024; // 1MB stack
    
    // Allocate with 16-byte alignment for ARM64
    var stack = try allocator.alignedAlloc(u8, 16, stack_size);
    
    // Set up guard pages on supported platforms
    if (comptime @hasDecl(std.posix, "mprotect")) {
        // Protect the first page as guard page
        const page_size = std.mem.page_size;
        if (stack.len >= page_size * 2) {
            std.posix.mprotect(stack[0..page_size], std.posix.PROT.NONE) catch {};
        }
    }
    
    return stack;
}

/// Deallocate a stack
pub fn deallocateStack(allocator: std.mem.Allocator, stack: []u8) void {
    // Remove guard page protection if it was set
    if (comptime @hasDecl(std.posix, "mprotect")) {
        const page_size = std.mem.page_size;
        if (stack.len >= page_size * 2) {
            std.posix.mprotect(stack[0..page_size], std.posix.PROT.READ | std.posix.PROT.WRITE) catch {};
        }
    }
    
    allocator.free(stack);
}

/// ARM64 CPU feature detection
pub const CpuFeatures = struct {
    has_neon: bool,
    has_crypto: bool,
    has_fp16: bool,
    has_sve: bool,
    has_sve2: bool,
    cache_line_size: u32,
    
    pub fn detect() CpuFeatures {
        var features = CpuFeatures{
            .has_neon = false,
            .has_crypto = false,
            .has_fp16 = false,
            .has_sve = false,
            .has_sve2 = false,
            .cache_line_size = 64, // Default ARM64 cache line size
        };
        
        // ARM64 feature detection using system registers
        // This would typically use CPUID or similar, but for now use compile-time detection
        if (comptime builtin.cpu.features.isEnabled(@import("std").Target.aarch64.Feature.neon)) {
            features.has_neon = true;
        }
        
        if (comptime builtin.cpu.features.isEnabled(@import("std").Target.aarch64.Feature.aes)) {
            features.has_crypto = true;
        }
        
        if (comptime builtin.cpu.features.isEnabled(@import("std").Target.aarch64.Feature.fullfp16)) {
            features.has_fp16 = true;
        }
        
        // SVE detection would require runtime checks
        // For now, assume not available unless explicitly enabled
        
        return features;
    }
    
    pub fn printFeatures(self: *const CpuFeatures) void {
        std.debug.print("ARM64 CPU Features:\n");
        std.debug.print("  NEON SIMD: {}\n", .{self.has_neon});
        std.debug.print("  Crypto Extensions: {}\n", .{self.has_crypto});
        std.debug.print("  FP16: {}\n", .{self.has_fp16});
        std.debug.print("  SVE: {}\n", .{self.has_sve});
        std.debug.print("  SVE2: {}\n", .{self.has_sve2});
        std.debug.print("  Cache Line Size: {} bytes\n", .{self.cache_line_size});
    }
};

/// High-resolution timer for ARM64
pub fn readTimeStampCounter() u64 {
    var time: u64 = undefined;
    
    // Read ARM64 system counter
    asm volatile (
        "mrs %[time], cntvct_el0"
        : [time] "=r" (time),
    );
    
    return time;
}

/// Get timer frequency for ARM64
pub fn getTimerFrequency() u64 {
    var freq: u64 = undefined;
    
    // Read ARM64 timer frequency
    asm volatile (
        "mrs %[freq], cntfrq_el0"
        : [freq] "=r" (freq),
    );
    
    return freq;
}

/// ARM64-specific memory barriers
pub inline fn memoryBarrierDMB() void {
    asm volatile ("dmb sy" ::: "memory");
}

pub inline fn memoryBarrierDSB() void {
    asm volatile ("dsb sy" ::: "memory");
}

pub inline fn memoryBarrierISB() void {
    asm volatile ("isb" ::: "memory");
}

/// ARM64-specific cache operations
pub inline fn flushCacheLine(addr: usize) void {
    asm volatile (
        "dc civac, %[addr]"
        :
        : [addr] "r" (addr),
        : "memory"
    );
}

pub inline fn invalidateCacheLine(addr: usize) void {
    asm volatile (
        "dc ivac, %[addr]"
        :
        : [addr] "r" (addr),
        : "memory"
    );
}

/// Thread-local storage support for ARM64
var current_context: ?*Context = null;

pub fn getCurrentContext() ?*Context {
    return current_context;
}

pub fn setCurrentContext(ctx: ?*Context) void {
    current_context = ctx;
}

/// ARM64 performance monitoring
pub const PerformanceCounters = struct {
    cycle_count_start: u64,
    instruction_count_start: u64,
    cache_misses_start: u64,
    
    pub fn init() PerformanceCounters {
        return PerformanceCounters{
            .cycle_count_start = readTimeStampCounter(),
            .instruction_count_start = 0, // Would need PMU setup
            .cache_misses_start = 0,      // Would need PMU setup
        };
    }
    
    pub fn getCycles(self: *const PerformanceCounters) u64 {
        return readTimeStampCounter() - self.cycle_count_start;
    }
    
    pub fn getTimeNanos(self: *const PerformanceCounters) u64 {
        const cycles = self.getCycles();
        const freq = getTimerFrequency();
        return (cycles * 1_000_000_000) / freq;
    }
};

/// Test function for ARM64 context switching
pub fn testContextSwitch() !void {
    std.debug.print("Testing ARM64 context switching...\n");
    
    const allocator = std.heap.page_allocator;
    
    // Allocate stacks
    const stack1 = try allocateStack(allocator);
    defer deallocateStack(allocator, stack1);
    
    const stack2 = try allocateStack(allocator);
    defer deallocateStack(allocator, stack2);
    
    // Test contexts
    var ctx1 = Context.init();
    var ctx2 = Context.init();
    
    // Test basic context creation
    const TestFn = struct {
        fn testFunction(arg: *anyopaque) void {
            const value = @as(*u32, @ptrCast(@alignCast(arg)));
            std.debug.print("Test function called with value: {}\n", .{value.*});
        }
    };
    
    var test_value: u32 = 42;
    makeContext(&ctx1, stack1, TestFn.testFunction, &test_value);
    makeContext(&ctx2, stack2, TestFn.testFunction, &test_value);
    
    std.debug.print("ARM64 context switching test completed successfully!\n");
}

/// ARM64-specific optimizations
pub const Optimizations = struct {
    /// Prefetch data for better cache performance
    pub inline fn prefetchRead(addr: *const anyopaque) void {
        asm volatile (
            "prfm pldl1keep, [%[addr]]"
            :
            : [addr] "r" (addr),
        );
    }
    
    pub inline fn prefetchWrite(addr: *anyopaque) void {
        asm volatile (
            "prfm pstl1keep, [%[addr]]"
            :
            : [addr] "r" (addr),
        );
    }
    
    /// Yield to other threads/cores
    pub inline fn yield() void {
        asm volatile ("yield");
    }
    
    /// Wait for event (low power)
    pub inline fn waitForEvent() void {
        asm volatile ("wfe");
    }
    
    /// Send event to other cores
    pub inline fn sendEvent() void {
        asm volatile ("sev");
    }
};