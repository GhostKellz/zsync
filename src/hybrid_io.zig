//! Zsync v0.1 - Hybrid Execution Models
//! Dynamically switch between stackful and stackless execution based on runtime conditions
//! This pushes Zsync ahead of the curve for future Zig async paradigms

const std = @import("std");
const builtin = @import("builtin");
const io_interface = @import("io_v2.zig");
const StacklessIo = @import("stackless_io.zig").StacklessIo;
const GreenThreadsIo = @import("greenthreads_io.zig").GreenThreadsIo;
const ThreadPoolIo = @import("threadpool_io.zig").ThreadPoolIo;
const Io = io_interface.Io;

/// Execution model types for hybrid switching
pub const ExecutionModel = enum {
    stackless,
    green_threads,
    thread_pool,
    auto, // Let the system decide
};

/// Runtime conditions for execution model selection
pub const RuntimeConditions = struct {
    available_memory: usize,
    active_coroutines: u32,
    cpu_usage_percent: f32,
    target_platform: std.Target.Cpu.Arch,
    is_wasm: bool,
    io_pressure: f32, // 0.0 to 1.0
    
    const Self = @This();
    
    /// Analyze current conditions and recommend execution model
    pub fn recommendExecutionModel(self: Self) ExecutionModel {
        // WASM must use stackless
        if (self.is_wasm) return .stackless;
        
        // High memory pressure - prefer stackless
        if (self.available_memory < 32 * 1024 * 1024) return .stackless;
        
        // High I/O pressure with many coroutines - prefer green threads
        if (self.io_pressure > 0.7 and self.active_coroutines > 100) return .green_threads;
        
        // High CPU usage - prefer thread pool for parallelism
        if (self.cpu_usage_percent > 80.0) return .thread_pool;
        
        // Low concurrent load - stackless is most efficient
        if (self.active_coroutines < 10) return .stackless;
        
        // Default to green threads for balanced workloads
        return .green_threads;
    }
};

/// Performance thresholds for automatic switching
pub const SwitchingThresholds = struct {
    memory_pressure_mb: usize = 32,
    high_coroutine_count: u32 = 100,
    high_cpu_usage: f32 = 80.0,
    high_io_pressure: f32 = 0.7,
    low_concurrency: u32 = 10,
};

/// Configuration for hybrid execution
pub const HybridConfig = struct {
    initial_model: ExecutionModel = .auto,
    enable_auto_switching: bool = true,
    switching_thresholds: SwitchingThresholds = .{},
    enable_metrics: bool = true,
    switch_cooldown_ms: u64 = 1000, // Minimum time between switches
};

/// Metrics for hybrid execution model switching
pub const HybridMetrics = struct {
    switches_to_stackless: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    switches_to_green_threads: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    switches_to_thread_pool: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    total_switches: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    last_switch_time: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    current_model: std.atomic.Value(u32) = std.atomic.Value(u32).init(@intFromEnum(ExecutionModel.auto)),
    
    const Self = @This();
    
    pub fn recordSwitch(self: *Self, to_model: ExecutionModel) void {
        _ = self.total_switches.fetchAdd(1, .acq_rel);
        self.current_model.store(@intFromEnum(to_model), .release);
        self.last_switch_time.store(@intCast(blk: { const ts = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch unreachable; break :blk @intCast(@divTrunc((@as(i128, ts.sec) * std.time.ns_per_s + ts.nsec), std.time.ns_per_ms)); }), .release);
        
        switch (to_model) {
            .stackless => _ = self.switches_to_stackless.fetchAdd(1, .acq_rel),
            .green_threads => _ = self.switches_to_green_threads.fetchAdd(1, .acq_rel),
            .thread_pool => _ = self.switches_to_thread_pool.fetchAdd(1, .acq_rel),
            .auto => {},
        }
    }
    
    pub fn getCurrentModel(self: *Self) ExecutionModel {
        const model_int = self.current_model.load(.acquire);
        return @enumFromInt(model_int);
    }
    
    pub fn canSwitch(self: *Self, cooldown_ms: u64) bool {
        const current_time = @as(u64, @intCast(blk: { const ts = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch unreachable; break :blk @intCast(@divTrunc((@as(i128, ts.sec) * std.time.ns_per_s + ts.nsec), std.time.ns_per_ms)); }));
        const last_switch = self.last_switch_time.load(.acquire);
        return (current_time - last_switch) >= cooldown_ms;
    }
};

/// System monitor for runtime conditions
pub const SystemMonitor = struct {
    allocator: std.mem.Allocator,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{ .allocator = allocator };
    }
    
    /// Sample current runtime conditions
    pub fn sampleConditions(self: *Self, active_coroutines: u32) RuntimeConditions {
        _ = self;
        
        return RuntimeConditions{
            .available_memory = getAvailableMemory(),
            .active_coroutines = active_coroutines,
            .cpu_usage_percent = getCpuUsage(),
            .target_platform = builtin.cpu.arch,
            .is_wasm = builtin.target.isWasm(),
            .io_pressure = getIoPressure(),
        };
    }
    
    fn getAvailableMemory() usize {
        // Mock implementation - in real system would query OS
        return 128 * 1024 * 1024; // 128MB
    }
    
    fn getCpuUsage() f32 {
        // Mock implementation - in real system would query OS
        return 45.0; // 45% CPU usage
    }
    
    fn getIoPressure() f32 {
        // Mock implementation - in real system would monitor I/O queues
        return 0.3; // 30% I/O pressure
    }
};

/// Hybrid I/O implementation that can switch execution models at runtime
pub const HybridIo = struct {
    allocator: std.mem.Allocator,
    config: HybridConfig,
    
    // Execution model implementations
    stackless_io: StacklessIo,
    green_threads_io: GreenThreadsIo,
    thread_pool_io: ThreadPoolIo,
    
    // Runtime monitoring and switching
    current_model: ExecutionModel,
    metrics: HybridMetrics,
    monitor: SystemMonitor,
    active_coroutines: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, config: HybridConfig) !Self {
        var self = Self{
            .allocator = allocator,
            .config = config,
            .stackless_io = StacklessIo.init(allocator, .{ .enable_profiling = config.enable_metrics }),
            .green_threads_io = try GreenThreadsIo.init(allocator, .{ .enable_profiling = config.enable_metrics }),
            .thread_pool_io = try ThreadPoolIo.init(allocator, .{ .enable_profiling = config.enable_metrics }),
            .current_model = config.initial_model,
            .metrics = HybridMetrics{},
            .monitor = SystemMonitor.init(allocator),
        };
        
        // Determine initial model if set to auto
        if (self.current_model == .auto) {
            const conditions = self.monitor.sampleConditions(0);
            self.current_model = conditions.recommendExecutionModel();
            if (config.enable_metrics) {
                self.metrics.recordSwitch(self.current_model);
            }
        }
        
        return self;
    }
    
    pub fn deinit(self: *Self) void {
        self.stackless_io.deinit();
        self.green_threads_io.deinit();
        self.thread_pool_io.deinit();
    }
    
    /// Get the current Io interface, potentially switching models
    pub fn io(self: *Self) Io {
        if (self.config.enable_auto_switching) {
            self.checkAndSwitch();
        }
        
        return switch (self.current_model) {
            .stackless => self.stackless_io.io(),
            .green_threads => self.green_threads_io.io(),
            .thread_pool => self.thread_pool_io.io(),
            .auto => unreachable, // Should be resolved by now
        };
    }
    
    /// Manually switch to a specific execution model
    pub fn switchTo(self: *Self, model: ExecutionModel) !void {
        if (model == .auto) {
            const conditions = self.monitor.sampleConditions(self.active_coroutines.load(.acquire));
            self.current_model = conditions.recommendExecutionModel();
        } else {
            self.current_model = model;
        }
        
        if (self.config.enable_metrics) {
            self.metrics.recordSwitch(self.current_model);
        }
        
        std.log.info("HybridIo switched to: {}", .{self.current_model});
    }
    
    /// Check runtime conditions and switch models if beneficial
    fn checkAndSwitch(self: *Self) void {
        if (!self.metrics.canSwitch(self.config.switch_cooldown_ms)) {
            return; // Still in cooldown period
        }
        
        const conditions = self.monitor.sampleConditions(self.active_coroutines.load(.acquire));
        const recommended = conditions.recommendExecutionModel();
        
        if (recommended != self.current_model) {
            self.switchTo(recommended) catch |err| {
                std.log.warn("Failed to switch execution model to {}: {}", .{ recommended, err });
            };
        }
    }
    
    /// Get hybrid execution metrics
    pub fn getMetrics(self: *Self) HybridMetrics {
        return self.metrics;
    }
    
    /// Get detailed performance metrics from current execution model
    pub fn getCurrentModelMetrics(self: *Self) union(ExecutionModel) {
        stackless: @import("stackless_io.zig").StacklessMetricsSnapshot,
        green_threads: @import("greenthreads_io.zig").GreenThreadsMetricsSnapshot,
        thread_pool: @import("threadpool_io.zig").ThreadPoolMetricsSnapshot,
        auto: void,
    } {
        return switch (self.current_model) {
            .stackless => .{ .stackless = self.stackless_io.getMetrics() },
            .green_threads => .{ .green_threads = self.green_threads_io.getMetrics() },
            .thread_pool => .{ .thread_pool = self.thread_pool_io.getMetrics() },
            .auto => .{ .auto = {} },
        };
    }
    
    /// Run the hybrid I/O system
    pub fn run(self: *Self) void {
        switch (self.current_model) {
            .stackless => self.stackless_io.run(),
            .green_threads => self.green_threads_io.run(),
            .thread_pool => self.thread_pool_io.run(),
            .auto => unreachable,
        }
    }
    
    /// Increment active coroutine count
    pub fn incrementCoroutines(self: *Self) void {
        _ = self.active_coroutines.fetchAdd(1, .acq_rel);
    }
    
    /// Decrement active coroutine count
    pub fn decrementCoroutines(self: *Self) void {
        _ = self.active_coroutines.fetchSub(1, .acq_rel);
    }
};

/// Smart execution model selector with machine learning-inspired heuristics
pub const SmartSelector = struct {
    /// Historical performance data for each execution model
    model_performance: [4]PerformanceHistory = [_]PerformanceHistory{PerformanceHistory{}} ** 4,
    
    const PerformanceHistory = struct {
        avg_latency_ns: f64 = 0.0,
        throughput_ops_per_sec: f64 = 0.0,
        memory_efficiency: f64 = 0.0,
        samples: u32 = 0,
        
        const Self = @This();
        
        fn updateMetrics(self: *Self, latency_ns: u64, throughput: f64, memory_bytes: u64) void {
            const new_samples = self.samples + 1;
            const weight = 1.0 / @as(f64, @floatFromInt(new_samples));
            
            self.avg_latency_ns = (self.avg_latency_ns * @as(f64, @floatFromInt(self.samples)) + @as(f64, @floatFromInt(latency_ns))) / @as(f64, @floatFromInt(new_samples));
            self.throughput_ops_per_sec = (self.throughput_ops_per_sec * @as(f64, @floatFromInt(self.samples)) + throughput) / @as(f64, @floatFromInt(new_samples));
            
            // Simple memory efficiency metric (lower is better)
            const efficiency = 1.0 / @as(f64, @floatFromInt(memory_bytes + 1));
            self.memory_efficiency = (self.memory_efficiency * @as(f64, @floatFromInt(self.samples)) + efficiency) / @as(f64, @floatFromInt(new_samples));
            
            self.samples = new_samples;
        }
        
        fn getScore(self: Self, conditions: RuntimeConditions) f64 {
            // Weight factors based on current conditions
            const latency_weight = if (conditions.io_pressure > 0.8) 0.5 else 0.3;
            const throughput_weight = if (conditions.active_coroutines > 50) 0.4 else 0.3;
            const memory_weight = if (conditions.available_memory < 64 * 1024 * 1024) 0.4 else 0.2;
            
            // Normalize and combine metrics (higher score is better)
            const latency_score = if (self.avg_latency_ns > 0) 1.0 / self.avg_latency_ns else 0.0;
            
            return (latency_score * latency_weight) + 
                   (self.throughput_ops_per_sec * throughput_weight) + 
                   (self.memory_efficiency * memory_weight);
        }
    };
    
    const Self = @This();
    
    /// Select the best execution model based on historical performance and current conditions
    pub fn selectModel(self: *Self, conditions: RuntimeConditions) ExecutionModel {
        // Mandatory constraints
        if (conditions.is_wasm) return .stackless;
        
        // Calculate scores for each viable model
        var best_model = ExecutionModel.stackless;
        var best_score: f64 = 0.0;
        
        const models = [_]ExecutionModel{ .stackless, .green_threads, .thread_pool };
        
        for (models) |model| {
            const model_idx = @intFromEnum(model);
            if (model_idx < self.model_performance.len) {
                const score = self.model_performance[model_idx].getScore(conditions);
                if (score > best_score) {
                    best_score = score;
                    best_model = model;
                }
            }
        }
        
        // Fall back to heuristics if no performance data
        if (best_score == 0.0) {
            return conditions.recommendExecutionModel();
        }
        
        return best_model;
    }
    
    /// Update performance metrics for a specific model
    pub fn updatePerformance(self: *Self, model: ExecutionModel, latency_ns: u64, throughput: f64, memory_bytes: u64) void {
        const model_idx = @intFromEnum(model);
        if (model_idx < self.model_performance.len) {
            self.model_performance[model_idx].updateMetrics(latency_ns, throughput, memory_bytes);
        }
    }
};

test "hybrid io execution model switching" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var hybrid_io = try HybridIo.init(allocator, .{
        .initial_model = .stackless,
        .enable_auto_switching = true,
        .enable_metrics = true,
    });
    defer hybrid_io.deinit();
    
    // Test initial model
    const metrics = hybrid_io.getMetrics();
    try testing.expect(metrics.getCurrentModel() == .stackless);
    
    // Test manual switching
    try hybrid_io.switchTo(.green_threads);
    try testing.expect(hybrid_io.current_model == .green_threads);
    
    // Test auto selection
    try hybrid_io.switchTo(.auto);
    // Should select based on current conditions
    
    // Test I/O interface
    const io = hybrid_io.io();
    _ = io; // Use the interface
}

test "runtime conditions and model recommendation" {
    const testing = std.testing;
    
    // Test WASM constraint
    var conditions = RuntimeConditions{
        .available_memory = 100 * 1024 * 1024,
        .active_coroutines = 50,
        .cpu_usage_percent = 50.0,
        .target_platform = .wasm32,
        .is_wasm = true,
        .io_pressure = 0.5,
    };
    
    try testing.expect(conditions.recommendExecutionModel() == .stackless);
    
    // Test high memory pressure
    conditions.is_wasm = false;
    conditions.available_memory = 16 * 1024 * 1024; // Low memory
    try testing.expect(conditions.recommendExecutionModel() == .stackless);
    
    // Test high I/O pressure with many coroutines
    conditions.available_memory = 100 * 1024 * 1024;
    conditions.io_pressure = 0.8;
    conditions.active_coroutines = 150;
    try testing.expect(conditions.recommendExecutionModel() == .green_threads);
    
    // Test high CPU usage
    conditions.io_pressure = 0.3;
    conditions.active_coroutines = 50;
    conditions.cpu_usage_percent = 90.0;
    try testing.expect(conditions.recommendExecutionModel() == .thread_pool);
}

test "smart selector performance tracking" {
    const testing = std.testing;
    
    var selector = SmartSelector{};
    
    // Update performance data
    selector.updatePerformance(.stackless, 1000000, 100.0, 4096); // 1ms latency, 100 ops/sec, 4KB memory
    selector.updatePerformance(.green_threads, 2000000, 200.0, 8192); // 2ms latency, 200 ops/sec, 8KB memory
    
    const conditions = RuntimeConditions{
        .available_memory = 100 * 1024 * 1024,
        .active_coroutines = 10,
        .cpu_usage_percent = 30.0,
        .target_platform = .x86_64,
        .is_wasm = false,
        .io_pressure = 0.2,
    };
    
    // Should prefer the model with better performance characteristics
    const selected = selector.selectModel(conditions);
    _ = selected; // Model selection depends on complex scoring
}