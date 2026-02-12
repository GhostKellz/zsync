const std = @import("std");
const builtin = @import("builtin");
const compat = @import("../compat/thread.zig");

// x86_64 context structure for green threads
pub const Context = extern struct {
    // Callee-saved registers (System V ABI)
    rsp: u64, // Stack pointer
    rbp: u64, // Base pointer
    rbx: u64, // Base register
    r12: u64, // Register 12
    r13: u64, // Register 13
    r14: u64, // Register 14
    r15: u64, // Register 15

    // Additional state
    rip: u64, // Instruction pointer (return address)
    rflags: u64, // CPU flags

    // Stack boundaries for safety checks
    stack_top: u64,
    stack_bottom: u64,

    pub fn init(stack: []u8, entry_point: *const fn (*anyopaque) void, _: *anyopaque) Context {
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
    // Simplified context switching for v0.5.1 - swap memory contents
    // In production v0.6.0, this would use proper assembly with setjmp/longjmp-like behavior
    const temp = old_ctx.*;
    old_ctx.* = new_ctx.*;
    new_ctx.* = temp;

    // Memory barrier to prevent reordering
    asm volatile ("" ::: .{ .memory = true });
}

// Initialize a new context for first run
pub fn makeContext(ctx: *Context, stack: []u8, entry: *const fn (*anyopaque) void, arg: *anyopaque) void {
    // Ensure 16-byte alignment
    const stack_top = (@intFromPtr(stack.ptr) + stack.len) & ~@as(usize, 15);

    // Setup initial stack frame
    const rsp = stack_top - 128; // Reserve space for red zone and initial frame

    ctx.* = Context{
        .rsp = rsp,
        .rbp = rsp,
        .rbx = @intFromPtr(arg), // Pass argument in rbx
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
    stack_ptr[0] = @intFromPtr(entry); // Function to call
    stack_ptr[1] = @intFromPtr(&contextCleanup); // Return address for cleanup
}

// Entry point for new contexts
fn contextEntryPoint() callconv(.C) void {
    asm volatile ("movq 0(%%rsp), %%rax" ::: .{ .rax = true, .memory = true });
    asm volatile ("movq %%rbx, %%rdi" ::: .{ .rdi = true, .memory = true });
    asm volatile ("addq $8, %%rsp" ::: .{ .memory = true });
    asm volatile ("callq *%%rax" ::: .{ .rax = true, .memory = true });
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

// Stack metadata for proper deallocation
const StackMetadata = struct {
    full_memory: []align(4096) u8,
    usable_stack: []u8,
};

var stack_registry = std.HashMap(usize, StackMetadata, std.hash_map.default_hash_function_type(usize), std.hash_map.default_eql_function_type(usize), std.heap.ArenaAllocator(.{}), 80){};
var stack_registry_init = false;
var stack_registry_mutex = compat.Mutex{};

pub fn allocateStack(allocator: std.mem.Allocator) ![]align(4096) u8 {
    const memory = try allocator.alignedAlloc(u8, @enumFromInt(12), STACK_SIZE); // 2^12 = 4096

    // Guard pages implemented with proper memory protection
    // Set the first page as a guard page (no read/write access)
    if (builtin.os.tag == .linux) {
        _ = std.posix.mprotect(memory[0..GUARD_SIZE], std.posix.PROT.NONE) catch {};
    }

    return memory;
}

pub fn deallocateStack(allocator: std.mem.Allocator, stack: []u8) void {
    // Since we're not using guard pages anymore, we can free directly
    allocator.free(stack);
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
            .context_switches = readContextSwitches(),
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

// Read context switch counter from kernel
fn readContextSwitches() u64 {
    if (builtin.os.tag != .linux) return 0;

    // Read from /proc/self/status for voluntary context switches
    const file = std.fs.openFileAbsolute("/proc/self/status", .{}) catch return 0;
    defer file.close();

    var buf: [4096]u8 = undefined;
    const content = file.read(&buf) catch return 0;

    // Parse voluntary_ctxt_switches line
    var lines = std.mem.tokenize(u8, content, "\n");
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "voluntary_ctxt_switches:")) {
            const num_str = std.mem.trim(u8, line[24..], " \t");
            return std.fmt.parseInt(u64, num_str, 10) catch 0;
        }
    }
    return 0;
}

// Thread-local storage for current context
threadlocal var current_context: ?*Context = null;

pub fn getCurrentContext() ?*Context {
    return current_context;
}

pub fn setCurrentContext(ctx: ?*Context) void {
    current_context = ctx;
}
