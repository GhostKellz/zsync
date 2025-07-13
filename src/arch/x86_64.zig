const std = @import("std");
const builtin = @import("builtin");

// x86_64 context structure for green threads
pub const Context = extern struct {
    // Callee-saved registers (System V ABI)
    rsp: u64,    // Stack pointer
    rbp: u64,    // Base pointer
    rbx: u64,    // Base register
    r12: u64,    // Register 12
    r13: u64,    // Register 13
    r14: u64,    // Register 14
    r15: u64,    // Register 15
    
    // Additional state
    rip: u64,    // Instruction pointer (return address)
    rflags: u64, // CPU flags
    
    // Stack boundaries for safety checks
    stack_top: u64,
    stack_bottom: u64,
    
    pub fn init(stack: []u8, entry_point: *const fn(*anyopaque) void, _: *anyopaque) Context {
        // Align stack to 16 bytes (required by System V ABI)
        const stack_top = @intFromPtr(stack.ptr + stack.len) & ~@as(usize, 15);
        
        // Reserve space for initial frame
        const rsp = stack_top - 16;
        
        return Context{
            .rsp = rsp,
            .rbp = rsp,
            .rbx = 0,
            .r12 = 0,
            .r13 = 0,
            .r14 = 0,
            .r15 = 0,
            .rip = @intFromPtr(entry_point),
            .rflags = 0x202, // Standard x86_64 flags (interrupts enabled)
            .stack_top = stack_top,
            .stack_bottom = @intFromPtr(stack.ptr),
        };
    }
    
    pub fn isValid(self: *const Context) bool {
        return self.rsp >= self.stack_bottom and self.rsp <= self.stack_top;
    }
};

// Assembly context switching function
pub fn swapContext(old_ctx: *Context, new_ctx: *Context) void {
    // Simple context switching using direct assignment
    // In a real implementation, this would use proper assembly
    
    // Save current context (simplified)
    asm volatile ("" ::: "memory"); // Memory barrier
    
    // Swap the contexts
    const temp = old_ctx.*;
    old_ctx.* = new_ctx.*;
    new_ctx.* = temp;
    
    asm volatile ("" ::: "memory"); // Memory barrier
}

// Initialize a new context for first run
pub fn makeContext(ctx: *Context, stack: []u8, entry: *const fn(*anyopaque) void, arg: *anyopaque) void {
    // Ensure 16-byte alignment
    const stack_top = (@intFromPtr(stack.ptr) + stack.len) & ~@as(usize, 15);
    
    // Setup initial stack frame
    const rsp = stack_top - 128; // Reserve space for red zone and initial frame
    
    ctx.* = Context{
        .rsp = rsp,
        .rbp = rsp,
        .rbx = @intFromPtr(arg),    // Pass argument in rbx
        .r12 = 0,
        .r13 = 0,
        .r14 = 0,
        .r15 = 0,
        .rip = @intFromPtr(&contextEntryPoint),
        .rflags = 0x202,
        .stack_top = stack_top,
        .stack_bottom = @intFromPtr(stack.ptr),
    };
    
    // Store entry point and cleanup function on stack
    const stack_ptr = @as([*]u64, @ptrFromInt(rsp));
    stack_ptr[0] = @intFromPtr(entry);     // Function to call
    stack_ptr[1] = @intFromPtr(&contextCleanup); // Return address for cleanup
}

// Entry point for new contexts
fn contextEntryPoint() callconv(.C) void {
    asm volatile (
        "movq 0(%%rsp), %%rax"
        :
        :
        : "rax", "memory"
    );
    asm volatile (
        "movq %%rbx, %%rdi"
        :
        :
        : "rdi", "memory"
    );
    asm volatile (
        "addq $8, %%rsp"
        :
        :
        : "memory"
    );
    asm volatile (
        "callq *%%rax"
        :
        :
        : "rax", "memory"
    );
    contextCleanup();
}

// Cleanup function for when context exits
fn contextCleanup() callconv(.C) noreturn {
    // This should trigger a return to scheduler
    @panic("Green thread exited without yielding to scheduler");
}

// Stack allocation helpers
pub const STACK_SIZE = 2 * 1024 * 1024; // 2MB default stack
pub const GUARD_SIZE = 4096; // 4KB guard page

pub fn allocateStack(allocator: std.mem.Allocator) ![]align(4096) u8 {
    const total_size = STACK_SIZE + GUARD_SIZE;
    const memory = try allocator.alignedAlloc(u8, @enumFromInt(12), total_size); // 2^12 = 4096
    
    // Setup guard page (if supported)
    if (comptime builtin.os.tag == .linux) {
        const mprotect = std.os.linux.mprotect;
        _ = mprotect(
            memory.ptr,
            GUARD_SIZE,
            std.os.linux.PROT.NONE,
        );
    }
    
    // Return usable stack (skip guard page)
    return memory[GUARD_SIZE..];
}

pub fn deallocateStack(allocator: std.mem.Allocator, stack: []u8) void {
    // Calculate original allocation including guard page
    const full_memory = @as([*]u8, @ptrCast(stack.ptr))[-GUARD_SIZE..stack.len];
    allocator.free(full_memory);
}

// CPU feature detection
pub const CpuFeatures = struct {
    has_avx: bool,
    has_avx2: bool,
    has_avx512: bool,
    
    pub fn detect() CpuFeatures {
        // Basic CPUID detection
        var result = CpuFeatures{
            .has_avx = false,
            .has_avx2 = false,
            .has_avx512 = false,
        };
        
        // Check for AVX support
        const cpuid_result = cpuid(1);
        result.has_avx = (cpuid_result.ecx & (1 << 28)) != 0;
        
        if (result.has_avx) {
            // Check for AVX2
            const extended = cpuid(7);
            result.has_avx2 = (extended.ebx & (1 << 5)) != 0;
            result.has_avx512 = (extended.ebx & (1 << 16)) != 0;
        }
        
        return result;
    }
};

// CPUID instruction wrapper
fn cpuid(leaf: u32) struct { eax: u32, ebx: u32, ecx: u32, edx: u32 } {
    var eax: u32 = leaf;
    var ebx: u32 = 0;
    var ecx: u32 = 0;
    var edx: u32 = 0;
    
    asm volatile (
        \\cpuid
        : [eax] "={eax}" (eax),
          [ebx] "={ebx}" (ebx),
          [ecx] "={ecx}" (ecx),
          [edx] "={edx}" (edx),
        : [leaf] "{eax}" (leaf),
          [subleaf] "{ecx}" (0),
    );
    
    return .{ .eax = eax, .ebx = ebx, .ecx = ecx, .edx = edx };
}

// Performance monitoring helpers
pub const PerfCounters = struct {
    context_switches: u64,
    cycles: u64,
    instructions: u64,
    
    pub fn read() PerfCounters {
        return .{
            .context_switches = 0, // TODO: Implement perf counter reading
            .cycles = rdtsc(),
            .instructions = 0,
        };
    }
};

// Read Time Stamp Counter
pub fn rdtsc() u64 {
    var low: u32 = undefined;
    var high: u32 = undefined;
    
    asm volatile (
        \\rdtsc
        : [low] "={eax}" (low),
          [high] "={edx}" (high),
    );
    
    return (@as(u64, high) << 32) | low;
}

// Thread-local storage for current context
threadlocal var current_context: ?*Context = null;

pub fn getCurrentContext() ?*Context {
    return current_context;
}

pub fn setCurrentContext(ctx: ?*Context) void {
    current_context = ctx;
}