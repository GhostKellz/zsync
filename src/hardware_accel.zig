const std = @import("std");
const builtin = @import("builtin");
const io_mod = @import("io_v2.zig");
const Io = io_mod.Io;

pub const CpuFeatures = struct {
    // x86_64 features
    sse2: bool = false,
    sse3: bool = false,
    ssse3: bool = false,
    sse41: bool = false,
    sse42: bool = false,
    avx: bool = false,
    avx2: bool = false,
    avx512f: bool = false,
    aes: bool = false,
    sha: bool = false,
    
    // ARM features
    neon: bool = false,
    crc32: bool = false,
    crypto: bool = false,
    
    // Cache info
    cache_line_size: usize = 64,
    l1_data_cache: usize = 32 * 1024,
    l2_cache: usize = 256 * 1024,
    l3_cache: usize = 8 * 1024 * 1024,
};

pub const HardwareAccel = struct {
    features: CpuFeatures,
    
    pub fn init() HardwareAccel {
        return .{
            .features = detectCpuFeatures(),
        };
    }
    
    pub fn detectCapabilities() CpuFeatures {
        return detectCpuFeatures();
    }
    
    fn detectCpuFeatures() CpuFeatures {
        var features = CpuFeatures{};
        
        if (builtin.cpu.arch == .x86_64) {
            detectX86Features(&features);
        } else if (builtin.cpu.arch == .aarch64) {
            detectArmFeatures(&features);
        }
        
        detectCacheInfo(&features);
        
        return features;
    }
    
    fn detectX86Features(features: *CpuFeatures) void {
        if (builtin.os.tag == .windows) {
            // Windows-specific detection
            detectX86FeaturesWindows(features);
        } else {
            // Unix-like systems
            detectX86FeaturesUnix(features);
        }
    }
    
    fn detectX86FeaturesUnix(features: *CpuFeatures) void {
        // CPUID detection for x86_64
        const cpuid = struct {
            fn leaf(eax_input: u32) struct { eax: u32, ebx: u32, ecx: u32, edx: u32 } {
                var eax: u32 = undefined;
                var ebx: u32 = undefined;
                var ecx: u32 = undefined;
                var edx: u32 = undefined;
                asm volatile (
                    \\ cpuid
                    : [eax] "={eax}" (eax),
                      [ebx] "={ebx}" (ebx),
                      [ecx] "={ecx}" (ecx),
                      [edx] "={edx}" (edx),
                    : [in_eax] "{eax}" (eax_input),
                      [in_ecx] "{ecx}" (@as(u32, 0)),
                );
                return .{ .eax = eax, .ebx = ebx, .ecx = ecx, .edx = edx };
            }
        };
        
        // Check for basic features (leaf 1)
        const leaf1 = cpuid.leaf(1);
        features.sse2 = (leaf1.edx & (1 << 26)) != 0;
        features.sse3 = (leaf1.ecx & (1 << 0)) != 0;
        features.ssse3 = (leaf1.ecx & (1 << 9)) != 0;
        features.sse41 = (leaf1.ecx & (1 << 19)) != 0;
        features.sse42 = (leaf1.ecx & (1 << 20)) != 0;
        features.aes = (leaf1.ecx & (1 << 25)) != 0;
        features.avx = (leaf1.ecx & (1 << 28)) != 0;
        
        // Check for extended features (leaf 7)
        const leaf7 = cpuid.leaf(7);
        features.avx2 = (leaf7.ebx & (1 << 5)) != 0;
        features.sha = (leaf7.ebx & (1 << 29)) != 0;
        features.avx512f = (leaf7.ebx & (1 << 16)) != 0;
    }
    
    fn detectX86FeaturesWindows(features: *CpuFeatures) void {
        // Windows requires different approach, using IsProcessorFeaturePresent
        // For now, use conservative defaults
        features.sse2 = true; // SSE2 is baseline for x86_64
        features.sse3 = @hasDecl(std.os.windows, "PF_SSE3_INSTRUCTIONS_AVAILABLE");
        features.ssse3 = false;
        features.sse41 = false;
        features.sse42 = false;
        features.aes = @hasDecl(std.os.windows, "PF_AES_INSTRUCTIONS_AVAILABLE");
        features.avx = @hasDecl(std.os.windows, "PF_AVX_INSTRUCTIONS_AVAILABLE");
        features.avx2 = @hasDecl(std.os.windows, "PF_AVX2_INSTRUCTIONS_AVAILABLE");
    }
    
    fn detectArmFeatures(features: *CpuFeatures) void {
        // ARM feature detection
        if (builtin.os.tag == .linux) {
            // Parse /proc/cpuinfo or use getauxval
            features.neon = true; // NEON is mandatory on AArch64
            features.crc32 = std.Target.aarch64.featureSetHas(builtin.cpu.features, .crc);
            features.crypto = std.Target.aarch64.featureSetHas(builtin.cpu.features, .crypto);
        } else {
            // Conservative defaults for other systems
            features.neon = true;
            features.crc32 = false;
            features.crypto = false;
        }
    }
    
    fn detectCacheInfo(features: *CpuFeatures) void {
        // Try to detect actual cache sizes
        if (builtin.os.tag == .linux) {
            // Could parse /sys/devices/system/cpu/cpu0/cache/
            // For now use reasonable defaults
        }
        
        // Platform-specific cache line sizes
        if (builtin.cpu.arch == .x86_64) {
            features.cache_line_size = 64;
        } else if (builtin.cpu.arch == .aarch64) {
            features.cache_line_size = 64;
        } else {
            features.cache_line_size = 64; // Common default
        }
    }
    
    // Optimized memory operations
    pub fn optimizedCopy(self: HardwareAccel, io: Io, dst: []u8, src: []const u8) !void {
        _ = io;
        
        if (src.len != dst.len) return error.LengthMismatch;
        if (src.len == 0) return;
        
        // Choose the best implementation based on CPU features
        if (self.features.avx2 and src.len >= 32) {
            self.copyAvx2(dst, src);
        } else if (self.features.sse2 and src.len >= 16) {
            self.copySse2(dst, src);
        } else if (self.features.neon and src.len >= 16) {
            self.copyNeon(dst, src);
        } else {
            self.copyScalar(dst, src);
        }
    }
    
    fn copyAvx2(self: HardwareAccel, dst: []u8, src: []const u8) void {
        _ = self;
        var i: usize = 0;
        
        // Process 32-byte chunks with AVX2
        while (i + 32 <= src.len) : (i += 32) {
            if (builtin.cpu.arch == .x86_64) {
                asm volatile (
                    \\ vmovdqu (%[src]), %%ymm0
                    \\ vmovdqu %%ymm0, (%[dst])
                    :
                    : [src] "r" (src.ptr + i),
                      [dst] "r" (dst.ptr + i),
                    : "ymm0", "memory"
                );
            }
        }
        
        // Handle remainder
        while (i < src.len) : (i += 1) {
            dst[i] = src[i];
        }
    }
    
    fn copySse2(self: HardwareAccel, dst: []u8, src: []const u8) void {
        _ = self;
        var i: usize = 0;
        
        // Process 16-byte chunks with SSE2
        while (i + 16 <= src.len) : (i += 16) {
            if (builtin.cpu.arch == .x86_64) {
                asm volatile (
                    \\ movdqu (%[src]), %%xmm0
                    \\ movdqu %%xmm0, (%[dst])
                    :
                    : [src] "r" (src.ptr + i),
                      [dst] "r" (dst.ptr + i),
                    : "xmm0", "memory"
                );
            }
        }
        
        // Handle remainder
        while (i < src.len) : (i += 1) {
            dst[i] = src[i];
        }
    }
    
    fn copyNeon(self: HardwareAccel, dst: []u8, src: []const u8) void {
        _ = self;
        var i: usize = 0;
        
        // Process 16-byte chunks with NEON
        while (i + 16 <= src.len) : (i += 16) {
            if (builtin.cpu.arch == .aarch64) {
                asm volatile (
                    \\ ldr q0, [%[src]]
                    \\ str q0, [%[dst]]
                    :
                    : [src] "r" (src.ptr + i),
                      [dst] "r" (dst.ptr + i),
                    : "q0", "memory"
                );
            }
        }
        
        // Handle remainder
        while (i < src.len) : (i += 1) {
            dst[i] = src[i];
        }
    }
    
    fn copyScalar(self: HardwareAccel, dst: []u8, src: []const u8) void {
        _ = self;
        @memcpy(dst, src);
    }
    
    // Optimized comparison
    pub fn optimizedCompare(self: HardwareAccel, io: Io, a: []const u8, b: []const u8) !bool {
        _ = io;
        
        if (a.len != b.len) return false;
        if (a.len == 0) return true;
        
        if (self.features.avx2 and a.len >= 32) {
            return self.compareAvx2(a, b);
        } else if (self.features.sse2 and a.len >= 16) {
            return self.compareSse2(a, b);
        } else if (self.features.neon and a.len >= 16) {
            return self.compareNeon(a, b);
        } else {
            return self.compareScalar(a, b);
        }
    }
    
    fn compareAvx2(self: HardwareAccel, a: []const u8, b: []const u8) bool {
        _ = self;
        var i: usize = 0;
        
        // Process 32-byte chunks
        while (i + 32 <= a.len) : (i += 32) {
            if (builtin.cpu.arch == .x86_64) {
                const equal = asm volatile (
                    \\ vmovdqu (%[a]), %%ymm0
                    \\ vmovdqu (%[b]), %%ymm1
                    \\ vpcmpeqb %%ymm0, %%ymm1, %%ymm2
                    \\ vpmovmskb %%ymm2, %[result]
                    : [result] "=r" (-> u32)
                    : [a] "r" (a.ptr + i),
                      [b] "r" (b.ptr + i),
                    : "ymm0", "ymm1", "ymm2"
                );
                if (equal != 0xFFFFFFFF) return false;
            }
        }
        
        // Check remainder
        while (i < a.len) : (i += 1) {
            if (a[i] != b[i]) return false;
        }
        
        return true;
    }
    
    fn compareSse2(self: HardwareAccel, a: []const u8, b: []const u8) bool {
        _ = self;
        var i: usize = 0;
        
        // Process 16-byte chunks
        while (i + 16 <= a.len) : (i += 16) {
            if (builtin.cpu.arch == .x86_64) {
                const equal = asm volatile (
                    \\ movdqu (%[a]), %%xmm0
                    \\ movdqu (%[b]), %%xmm1
                    \\ pcmpeqb %%xmm0, %%xmm1
                    \\ pmovmskb %%xmm1, %[result]
                    : [result] "=r" (-> u32)
                    : [a] "r" (a.ptr + i),
                      [b] "r" (b.ptr + i),
                    : "xmm0", "xmm1"
                );
                if (equal != 0xFFFF) return false;
            }
        }
        
        // Check remainder
        while (i < a.len) : (i += 1) {
            if (a[i] != b[i]) return false;
        }
        
        return true;
    }
    
    fn compareNeon(self: HardwareAccel, a: []const u8, b: []const u8) bool {
        _ = self;
        var i: usize = 0;
        
        // Process 16-byte chunks
        while (i + 16 <= a.len) : (i += 16) {
            if (builtin.cpu.arch == .aarch64) {
                const not_equal = asm volatile (
                    \\ ldr q0, [%[a]]
                    \\ ldr q1, [%[b]]
                    \\ cmeq v2.16b, v0.16b, v1.16b
                    \\ uminv b3, v2.16b
                    \\ umov %w[result], v3.b[0]
                    : [result] "=r" (-> u8)
                    : [a] "r" (a.ptr + i),
                      [b] "r" (b.ptr + i),
                    : "v0", "v1", "v2", "v3"
                );
                if (not_equal != 0xFF) return false;
            }
        }
        
        // Check remainder
        while (i < a.len) : (i += 1) {
            if (a[i] != b[i]) return false;
        }
        
        return true;
    }
    
    fn compareScalar(self: HardwareAccel, a: []const u8, b: []const u8) bool {
        _ = self;
        return std.mem.eql(u8, a, b);
    }
    
    // Optimized XOR operation
    pub fn optimizedXor(self: HardwareAccel, io: Io, dst: []u8, src: []const u8, key: []const u8) !void {
        _ = io;
        
        if (dst.len != src.len or dst.len != key.len) return error.LengthMismatch;
        if (dst.len == 0) return;
        
        if (self.features.avx2 and dst.len >= 32) {
            self.xorAvx2(dst, src, key);
        } else if (self.features.sse2 and dst.len >= 16) {
            self.xorSse2(dst, src, key);
        } else if (self.features.neon and dst.len >= 16) {
            self.xorNeon(dst, src, key);
        } else {
            self.xorScalar(dst, src, key);
        }
    }
    
    fn xorAvx2(self: HardwareAccel, dst: []u8, src: []const u8, key: []const u8) void {
        _ = self;
        var i: usize = 0;
        
        while (i + 32 <= src.len) : (i += 32) {
            if (builtin.cpu.arch == .x86_64) {
                asm volatile (
                    \\ vmovdqu (%[src]), %%ymm0
                    \\ vmovdqu (%[key]), %%ymm1
                    \\ vpxor %%ymm0, %%ymm1, %%ymm2
                    \\ vmovdqu %%ymm2, (%[dst])
                    :
                    : [src] "r" (src.ptr + i),
                      [key] "r" (key.ptr + i),
                      [dst] "r" (dst.ptr + i),
                    : "ymm0", "ymm1", "ymm2", "memory"
                );
            }
        }
        
        // Handle remainder
        while (i < src.len) : (i += 1) {
            dst[i] = src[i] ^ key[i];
        }
    }
    
    fn xorSse2(self: HardwareAccel, dst: []u8, src: []const u8, key: []const u8) void {
        _ = self;
        var i: usize = 0;
        
        while (i + 16 <= src.len) : (i += 16) {
            if (builtin.cpu.arch == .x86_64) {
                asm volatile (
                    \\ movdqu (%[src]), %%xmm0
                    \\ movdqu (%[key]), %%xmm1
                    \\ pxor %%xmm0, %%xmm1
                    \\ movdqu %%xmm0, (%[dst])
                    :
                    : [src] "r" (src.ptr + i),
                      [key] "r" (key.ptr + i),
                      [dst] "r" (dst.ptr + i),
                    : "xmm0", "xmm1", "memory"
                );
            }
        }
        
        // Handle remainder
        while (i < src.len) : (i += 1) {
            dst[i] = src[i] ^ key[i];
        }
    }
    
    fn xorNeon(self: HardwareAccel, dst: []u8, src: []const u8, key: []const u8) void {
        _ = self;
        var i: usize = 0;
        
        while (i + 16 <= src.len) : (i += 16) {
            if (builtin.cpu.arch == .aarch64) {
                asm volatile (
                    \\ ldr q0, [%[src]]
                    \\ ldr q1, [%[key]]
                    \\ eor v2.16b, v0.16b, v1.16b
                    \\ str q2, [%[dst]]
                    :
                    : [src] "r" (src.ptr + i),
                      [key] "r" (key.ptr + i),
                      [dst] "r" (dst.ptr + i),
                    : "v0", "v1", "v2", "memory"
                );
            }
        }
        
        // Handle remainder
        while (i < src.len) : (i += 1) {
            dst[i] = src[i] ^ key[i];
        }
    }
    
    fn xorScalar(self: HardwareAccel, dst: []u8, src: []const u8, key: []const u8) void {
        _ = self;
        for (dst, src, key) |*d, s, k| {
            d.* = s ^ k;
        }
    }
    
    // Prefetch optimization
    pub fn prefetch(self: HardwareAccel, ptr: [*]const u8, hint: PrefetchHint) void {
        _ = self;
        
        if (builtin.cpu.arch == .x86_64) {
            switch (hint) {
                .t0 => asm volatile("prefetcht0 (%[ptr])" : : [ptr] "r" (ptr) : "memory"),
                .t1 => asm volatile("prefetcht1 (%[ptr])" : : [ptr] "r" (ptr) : "memory"),
                .t2 => asm volatile("prefetcht2 (%[ptr])" : : [ptr] "r" (ptr) : "memory"),
                .nta => asm volatile("prefetchnta (%[ptr])" : : [ptr] "r" (ptr) : "memory"),
            }
        } else if (builtin.cpu.arch == .aarch64) {
            switch (hint) {
                .t0 => asm volatile("prfm pldl1keep, [%[ptr]]" : : [ptr] "r" (ptr) : "memory"),
                .t1 => asm volatile("prfm pldl2keep, [%[ptr]]" : : [ptr] "r" (ptr) : "memory"),
                .t2 => asm volatile("prfm pldl3keep, [%[ptr]]" : : [ptr] "r" (ptr) : "memory"),
                .nta => asm volatile("prfm pldl1strm, [%[ptr]]" : : [ptr] "r" (ptr) : "memory"),
            }
        }
    }
    
    pub const PrefetchHint = enum {
        t0,  // Temporal data, prefetch to all cache levels
        t1,  // Temporal data, prefetch to L2 and higher
        t2,  // Temporal data, prefetch to L3 and higher
        nta, // Non-temporal data, minimize cache pollution
    };
    
    // Cache-friendly iteration
    pub fn cacheOptimizedIterate(
        self: HardwareAccel,
        comptime T: type,
        slice: []T,
        comptime func: fn (item: *T) void,
    ) void {
        const cache_line_items = self.features.cache_line_size / @sizeOf(T);
        var i: usize = 0;
        
        // Process in cache-line-sized chunks
        while (i < slice.len) {
            // Prefetch next cache line
            if (i + cache_line_items < slice.len) {
                self.prefetch(@ptrCast(&slice[i + cache_line_items]), .t0);
            }
            
            // Process current cache line
            const end = @min(i + cache_line_items, slice.len);
            while (i < end) : (i += 1) {
                func(&slice[i]);
            }
        }
    }
};

// Async wrapper for hardware-accelerated operations
pub const AsyncHardwareOps = struct {
    hw: HardwareAccel,
    io: Io,
    
    pub fn init(io: Io) AsyncHardwareOps {
        return .{
            .hw = HardwareAccel.init(),
            .io = io,
        };
    }
    
    pub fn asyncCopy(self: *AsyncHardwareOps, dst: []u8, src: []const u8) !void {
        const future = self.io.async(self.hw.optimizedCopy, .{ self.io, dst, src });
        defer future.cancel(self.io) catch {};
        try future.await(self.io);
    }
    
    pub fn asyncCompare(self: *AsyncHardwareOps, a: []const u8, b: []const u8) !bool {
        const future = self.io.async(self.hw.optimizedCompare, .{ self.io, a, b });
        defer future.cancel(self.io) catch {};
        return try future.await(self.io);
    }
    
    pub fn asyncXor(self: *AsyncHardwareOps, dst: []u8, src: []const u8, key: []const u8) !void {
        const future = self.io.async(self.hw.optimizedXor, .{ self.io, dst, src, key });
        defer future.cancel(self.io) catch {};
        try future.await(self.io);
    }
    
    // Parallel processing using hardware features
    pub fn parallelProcess(
        self: *AsyncHardwareOps,
        comptime T: type,
        items: []T,
        comptime process_fn: fn (io: Io, item: *T) anyerror!void,
    ) !void {
        // Process in optimal cache-friendly chunks
        const chunk_size = @max(1, self.hw.features.l1_data_cache / @sizeOf(T) / 4);
        var i: usize = 0;
        
        while (i < items.len) {
            const end = @min(i + chunk_size, items.len);
            
            // Prefetch next chunk
            if (end < items.len) {
                self.hw.prefetch(@ptrCast(&items[end]), .t0);
            }
            
            // Process current chunk with hardware optimizations
            for (items[i..end]) |*item| {
                try process_fn(self.io, item);
            }
            
            i = end;
        }
    }
};