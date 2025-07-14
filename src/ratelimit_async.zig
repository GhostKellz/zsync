//! Advanced Rate Limiting Async Operations
//! Traffic shaping and bandwidth management with async coordination
//! High-performance rate limiting for network and system resources

const std = @import("std");
const io_v2 = @import("io_v2.zig");
const time = std.time;

/// Rate limiting algorithm types
pub const RateLimitAlgorithm = enum {
    token_bucket,
    leaky_bucket,
    sliding_window,
    fixed_window,
    adaptive,
};

/// Rate limit configuration
pub const RateLimitConfig = struct {
    algorithm: RateLimitAlgorithm = .token_bucket,
    rate_per_second: f64 = 100.0,
    burst_capacity: u64 = 1000,
    window_size_ms: u64 = 1000,
    max_queue_size: u32 = 10000,
    backoff_strategy: BackoffStrategy = .exponential,
    adaptive_threshold: f64 = 0.8,
    grace_period_ms: u64 = 5000,
    enforce_strict_ordering: bool = false,
};

/// Backoff strategy for rate limiting
pub const BackoffStrategy = enum {
    none,
    linear,
    exponential,
    fibonacci,
    adaptive,
};

/// Rate limit result
pub const RateLimitResult = enum {
    allowed,
    denied,
    delayed,
    queued,
};

/// Rate limit statistics
pub const RateLimitStats = struct {
    requests_allowed: u64 = 0,
    requests_denied: u64 = 0,
    requests_delayed: u64 = 0,
    requests_queued: u64 = 0,
    average_wait_time_ms: f64 = 0.0,
    current_queue_size: u32 = 0,
    tokens_available: f64 = 0.0,
    last_refill_time: i64 = 0,
    burst_events: u64 = 0,
    
    pub fn getTotalRequests(self: RateLimitStats) u64 {
        return self.requests_allowed + self.requests_denied + self.requests_delayed + self.requests_queued;
    }
    
    pub fn getSuccessRate(self: RateLimitStats) f64 {
        const total = self.getTotalRequests();
        if (total == 0) return 0.0;
        return @as(f64, @floatFromInt(self.requests_allowed)) / @as(f64, @floatFromInt(total));
    }
    
    pub fn getUtilization(self: RateLimitStats) f64 {
        return 1.0 - (self.tokens_available / 1000.0); // Assuming max 1000 tokens
    }
};

/// Rate limiter request
pub const RateLimitRequest = struct {
    id: u64,
    timestamp: i64,
    priority: RequestPriority,
    tokens_required: u64,
    source_id: ?[]const u8,
    metadata: ?std.json.Value,
    
    pub fn deinit(self: *RateLimitRequest, allocator: std.mem.Allocator) void {
        if (self.source_id) |source| {
            allocator.free(source);
        }
    }
};

/// Request priority levels
pub const RequestPriority = enum(u8) {
    low = 0,
    normal = 1,
    high = 2,
    urgent = 3,
};

/// Queued request with timing information
pub const QueuedRequest = struct {
    request: RateLimitRequest,
    queued_at: i64,
    estimated_wait_time_ms: u64,
    retry_count: u32,
    
    pub fn getWaitTime(self: QueuedRequest) i64 {
        return time.nanoTimestamp() - self.queued_at;
    }
};

/// Token bucket implementation
pub const TokenBucket = struct {
    capacity: f64,
    tokens: std.atomic.Value(f64),
    refill_rate: f64,
    last_refill: std.atomic.Value(i64),
    mutex: std.Thread.Mutex,
    
    pub fn init(capacity: f64, refill_rate: f64) TokenBucket {
        return TokenBucket{
            .capacity = capacity,
            .tokens = std.atomic.Value(f64).init(capacity),
            .refill_rate = refill_rate,
            .last_refill = std.atomic.Value(i64).init(time.nanoTimestamp()),
            .mutex = .{},
        };
    }
    
    pub fn tryConsume(self: *TokenBucket, tokens: f64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        self.refill();
        
        const current_tokens = self.tokens.load(.acquire);
        if (current_tokens >= tokens) {
            self.tokens.store(current_tokens - tokens, .release);
            return true;
        }
        
        return false;
    }
    
    pub fn getTokens(self: *TokenBucket) f64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        self.refill();
        return self.tokens.load(.acquire);
    }
    
    fn refill(self: *TokenBucket) void {
        const now = time.nanoTimestamp();
        const last_refill = self.last_refill.load(.acquire);
        const time_elapsed = @as(f64, @floatFromInt(now - last_refill)) / 1_000_000_000.0; // Convert to seconds
        
        if (time_elapsed > 0) {
            const tokens_to_add = self.refill_rate * time_elapsed;
            const current_tokens = self.tokens.load(.acquire);
            const new_tokens = @min(self.capacity, current_tokens + tokens_to_add);
            
            self.tokens.store(new_tokens, .release);
            self.last_refill.store(now, .release);
        }
    }
};

/// Leaky bucket implementation
pub const LeakyBucket = struct {
    capacity: f64,
    current_volume: std.atomic.Value(f64),
    leak_rate: f64,
    last_leak: std.atomic.Value(i64),
    mutex: std.Thread.Mutex,
    
    pub fn init(capacity: f64, leak_rate: f64) LeakyBucket {
        return LeakyBucket{
            .capacity = capacity,
            .current_volume = std.atomic.Value(f64).init(0.0),
            .leak_rate = leak_rate,
            .last_leak = std.atomic.Value(i64).init(time.nanoTimestamp()),
            .mutex = .{},
        };
    }
    
    pub fn tryAdd(self: *LeakyBucket, volume: f64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        self.leak();
        
        const current_volume = self.current_volume.load(.acquire);
        if (current_volume + volume <= self.capacity) {
            self.current_volume.store(current_volume + volume, .release);
            return true;
        }
        
        return false;
    }
    
    pub fn getCurrentVolume(self: *LeakyBucket) f64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        self.leak();
        return self.current_volume.load(.acquire);
    }
    
    fn leak(self: *LeakyBucket) void {
        const now = time.nanoTimestamp();
        const last_leak = self.last_leak.load(.acquire);
        const time_elapsed = @as(f64, @floatFromInt(now - last_leak)) / 1_000_000_000.0; // Convert to seconds
        
        if (time_elapsed > 0) {
            const volume_to_leak = self.leak_rate * time_elapsed;
            const current_volume = self.current_volume.load(.acquire);
            const new_volume = @max(0.0, current_volume - volume_to_leak);
            
            self.current_volume.store(new_volume, .release);
            self.last_leak.store(now, .release);
        }
    }
};

/// Sliding window counter
pub const SlidingWindow = struct {
    window_size_ms: u64,
    slots: []std.atomic.Value(u64),
    slot_duration_ms: u64,
    current_slot: std.atomic.Value(u64),
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator, window_size_ms: u64, num_slots: u32) !SlidingWindow {
        const slots = try allocator.alloc(std.atomic.Value(u64), num_slots);
        for (slots) |*slot| {
            slot.* = std.atomic.Value(u64).init(0);
        }
        
        return SlidingWindow{
            .window_size_ms = window_size_ms,
            .slots = slots,
            .slot_duration_ms = window_size_ms / num_slots,
            .current_slot = std.atomic.Value(u64).init(0),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *SlidingWindow) void {
        self.allocator.free(self.slots);
    }
    
    pub fn increment(self: *SlidingWindow, count: u64) void {
        const slot_index = self.getCurrentSlot();
        _ = self.slots[slot_index].fetchAdd(count, .acq_rel);
    }
    
    pub fn getCount(self: *SlidingWindow) u64 {
        var total: u64 = 0;
        for (self.slots) |*slot| {
            total += slot.load(.acquire);
        }
        return total;
    }
    
    fn getCurrentSlot(self: *SlidingWindow) usize {
        const now = @as(u64, @intCast(time.milliTimestamp()));
        const slot_index = (now / self.slot_duration_ms) % self.slots.len;
        
        const old_slot = self.current_slot.swap(slot_index, .acq_rel);
        if (old_slot != slot_index) {
            // Clear old slot
            self.slots[slot_index].store(0, .release);
        }
        
        return slot_index;
    }
};

/// Adaptive rate limiter
pub const AdaptiveRateLimiter = struct {
    base_rate: f64,
    current_rate: std.atomic.Value(f64),
    success_rate: std.atomic.Value(f64),
    adjustment_factor: f64,
    min_rate: f64,
    max_rate: f64,
    last_adjustment: std.atomic.Value(i64),
    adjustment_interval_ms: u64,
    
    pub fn init(base_rate: f64, adjustment_factor: f64, min_rate: f64, max_rate: f64) AdaptiveRateLimiter {
        return AdaptiveRateLimiter{
            .base_rate = base_rate,
            .current_rate = std.atomic.Value(f64).init(base_rate),
            .success_rate = std.atomic.Value(f64).init(1.0),
            .adjustment_factor = adjustment_factor,
            .min_rate = min_rate,
            .max_rate = max_rate,
            .last_adjustment = std.atomic.Value(i64).init(time.nanoTimestamp()),
            .adjustment_interval_ms = 1000, // 1 second
        };
    }
    
    pub fn updateSuccessRate(self: *AdaptiveRateLimiter, success_rate: f64) void {
        self.success_rate.store(success_rate, .release);
        self.adjustRate();
    }
    
    pub fn getCurrentRate(self: *AdaptiveRateLimiter) f64 {
        return self.current_rate.load(.acquire);
    }
    
    fn adjustRate(self: *AdaptiveRateLimiter) void {
        const now = time.nanoTimestamp();
        const last_adjustment = self.last_adjustment.load(.acquire);
        const time_since_adjustment = @as(u64, @intCast(now - last_adjustment)) / 1_000_000; // Convert to milliseconds
        
        if (time_since_adjustment < self.adjustment_interval_ms) {
            return;
        }
        
        const success_rate = self.success_rate.load(.acquire);
        const current_rate = self.current_rate.load(.acquire);
        
        var new_rate = current_rate;
        
        if (success_rate > 0.9) {
            // High success rate, increase rate
            new_rate = @min(self.max_rate, current_rate * (1.0 + self.adjustment_factor));
        } else if (success_rate < 0.7) {
            // Low success rate, decrease rate
            new_rate = @max(self.min_rate, current_rate * (1.0 - self.adjustment_factor));
        }
        
        self.current_rate.store(new_rate, .release);
        self.last_adjustment.store(now, .release);
    }
};

/// Main async rate limiter
pub const AsyncRateLimiter = struct {
    allocator: std.mem.Allocator,
    io: io_v2.Io,
    config: RateLimitConfig,
    
    // Rate limiting implementations
    token_bucket: ?TokenBucket,
    leaky_bucket: ?LeakyBucket,
    sliding_window: ?SlidingWindow,
    adaptive_limiter: ?AdaptiveRateLimiter,
    
    // Request management
    request_queue: std.ArrayList(QueuedRequest),
    request_id_counter: std.atomic.Value(u64),
    
    // Worker management
    worker_thread: ?std.Thread,
    worker_active: std.atomic.Value(bool),
    
    // Statistics
    stats: RateLimitStats,
    stats_mutex: std.Thread.Mutex,
    
    // Synchronization
    mutex: std.Thread.Mutex,
    queue_condition: std.Thread.Condition,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, io: io_v2.Io, config: RateLimitConfig) !Self {
        var limiter = Self{
            .allocator = allocator,
            .io = io,
            .config = config,
            .token_bucket = null,
            .leaky_bucket = null,
            .sliding_window = null,
            .adaptive_limiter = null,
            .request_queue = std.ArrayList(QueuedRequest).init(allocator),
            .request_id_counter = std.atomic.Value(u64).init(1),
            .worker_thread = null,
            .worker_active = std.atomic.Value(bool).init(false),
            .stats = RateLimitStats{},
            .stats_mutex = .{},
            .mutex = .{},
            .queue_condition = .{},
        };
        
        // Initialize rate limiting algorithm
        switch (config.algorithm) {
            .token_bucket => {
                limiter.token_bucket = TokenBucket.init(
                    @as(f64, @floatFromInt(config.burst_capacity)),
                    config.rate_per_second
                );
            },
            .leaky_bucket => {
                limiter.leaky_bucket = LeakyBucket.init(
                    @as(f64, @floatFromInt(config.burst_capacity)),
                    config.rate_per_second
                );
            },
            .sliding_window => {
                limiter.sliding_window = try SlidingWindow.init(
                    allocator,
                    config.window_size_ms,
                    60 // 60 slots for 1-second granularity
                );
            },
            .adaptive => {
                limiter.adaptive_limiter = AdaptiveRateLimiter.init(
                    config.rate_per_second,
                    0.1, // 10% adjustment factor
                    config.rate_per_second * 0.1, // Min 10% of base rate
                    config.rate_per_second * 10.0 // Max 10x base rate
                );
            },
            .fixed_window => {
                limiter.sliding_window = try SlidingWindow.init(
                    allocator,
                    config.window_size_ms,
                    1 // Single slot for fixed window
                );
            },
        }
        
        return limiter;
    }
    
    pub fn deinit(self: *Self) void {
        self.stopWorker();
        
        if (self.sliding_window) |*window| {
            window.deinit();
        }
        
        for (self.request_queue.items) |*queued| {
            queued.request.deinit(self.allocator);
        }
        self.request_queue.deinit();
    }
    
    /// Start rate limiter worker
    pub fn startWorker(self: *Self) !void {
        if (self.worker_active.swap(true, .acquire)) return;
        
        self.worker_thread = try std.Thread.spawn(.{}, rateLimitWorker, .{self});
    }
    
    /// Stop rate limiter worker
    pub fn stopWorker(self: *Self) void {
        if (!self.worker_active.swap(false, .release)) return;
        
        self.mutex.lock();
        self.queue_condition.broadcast();
        self.mutex.unlock();
        
        if (self.worker_thread) |thread| {
            thread.join();
            self.worker_thread = null;
        }
    }
    
    /// Check if request is allowed
    pub fn checkRateAsync(self: *Self, allocator: std.mem.Allocator, request: RateLimitRequest) !io_v2.Future {
        const ctx = try allocator.create(RateLimitContext);
        ctx.* = .{
            .limiter = self,
            .request = request,
            .allocator = allocator,
            .result = .denied,
        };
        
        return io_v2.Future{
            .impl = .{
                .callback = .{
                    .context = @ptrCast(ctx),
                    .poll_fn = rateLimitPoll,
                    .deinit_fn = rateLimitDeinit,
                },
            },
        };
    }
    
    /// Wait for rate limit with backoff
    pub fn waitForRateAsync(self: *Self, allocator: std.mem.Allocator, request: RateLimitRequest) !io_v2.Future {
        const ctx = try allocator.create(WaitRateLimitContext);
        ctx.* = .{
            .limiter = self,
            .request = request,
            .allocator = allocator,
            .start_time = time.nanoTimestamp(),
            .wait_complete = false,
        };
        
        return io_v2.Future{
            .impl = .{
                .callback = .{
                    .context = @ptrCast(ctx),
                    .poll_fn = waitRateLimitPoll,
                    .deinit_fn = waitRateLimitDeinit,
                },
            },
        };
    }
    
    /// Batch rate limit check
    pub fn batchCheckRateAsync(self: *Self, allocator: std.mem.Allocator, requests: []const RateLimitRequest) !io_v2.Future {
        const ctx = try allocator.create(BatchRateLimitContext);
        ctx.* = .{
            .limiter = self,
            .requests = try allocator.dupe(RateLimitRequest, requests),
            .allocator = allocator,
            .results = std.ArrayList(RateLimitResult).init(allocator),
        };
        
        return io_v2.Future{
            .impl = .{
                .callback = .{
                    .context = @ptrCast(ctx),
                    .poll_fn = batchRateLimitPoll,
                    .deinit_fn = batchRateLimitDeinit,
                },
            },
        };
    }
    
    /// Update rate limiter configuration
    pub fn updateConfigAsync(self: *Self, allocator: std.mem.Allocator, new_config: RateLimitConfig) !io_v2.Future {
        const ctx = try allocator.create(UpdateConfigContext);
        ctx.* = .{
            .limiter = self,
            .new_config = new_config,
            .allocator = allocator,
            .updated = false,
        };
        
        return io_v2.Future{
            .impl = .{
                .callback = .{
                    .context = @ptrCast(ctx),
                    .poll_fn = updateConfigPoll,
                    .deinit_fn = updateConfigDeinit,
                },
            },
        };
    }
    
    fn rateLimitWorker(self: *Self) void {
        while (self.worker_active.load(.acquire)) {
            self.processRequestQueue() catch |err| {
                std.log.err("Rate limiter worker error: {}", .{err});
            };
            
            std.time.sleep(1_000_000); // 1ms
        }
    }
    
    fn processRequestQueue(self: *Self) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (self.request_queue.items.len == 0) {
            self.queue_condition.wait(&self.mutex);
            return;
        }
        
        // Process requests in priority order
        std.sort.insertion(QueuedRequest, self.request_queue.items, {}, compareQueuedRequests);
        
        var i: usize = 0;
        while (i < self.request_queue.items.len) {
            const queued_request = &self.request_queue.items[i];
            
            if (self.checkRateLimit(queued_request.request)) {
                // Request allowed, remove from queue
                _ = self.request_queue.orderedRemove(i);
                self.updateStats(.{ .requests_allowed = 1 });
            } else {
                // Request still rate limited
                i += 1;
            }
        }
    }
    
    fn compareQueuedRequests(context: void, a: QueuedRequest, b: QueuedRequest) bool {
        _ = context;
        // Higher priority first, then older requests
        if (a.request.priority != b.request.priority) {
            return @intFromEnum(a.request.priority) > @intFromEnum(b.request.priority);
        }
        return a.queued_at < b.queued_at;
    }
    
    fn checkRateLimit(self: *Self, request: RateLimitRequest) bool {
        return switch (self.config.algorithm) {
            .token_bucket => {
                if (self.token_bucket) |*bucket| {
                    return bucket.tryConsume(@as(f64, @floatFromInt(request.tokens_required)));
                }
                return false;
            },
            .leaky_bucket => {
                if (self.leaky_bucket) |*bucket| {
                    return bucket.tryAdd(@as(f64, @floatFromInt(request.tokens_required)));
                }
                return false;
            },
            .sliding_window, .fixed_window => {
                if (self.sliding_window) |*window| {
                    const current_count = window.getCount();
                    const rate_limit = @as(u64, @intFromFloat(self.config.rate_per_second * (@as(f64, @floatFromInt(self.config.window_size_ms)) / 1000.0)));
                    
                    if (current_count + request.tokens_required <= rate_limit) {
                        window.increment(request.tokens_required);
                        return true;
                    }
                }
                return false;
            },
            .adaptive => {
                if (self.adaptive_limiter) |*limiter| {
                    const current_rate = limiter.getCurrentRate();
                    // Simplified adaptive check
                    const random_threshold = @as(f64, @floatFromInt(std.crypto.random.int(u32))) / @as(f64, @floatFromInt(std.math.maxInt(u32)));
                    return random_threshold < (current_rate / 1000.0);
                }
                return false;
            },
        };
    }
    
    fn updateStats(self: *Self, delta: RateLimitStatsDelta) void {
        self.stats_mutex.lock();
        defer self.stats_mutex.unlock();
        
        self.stats.requests_allowed += delta.requests_allowed;
        self.stats.requests_denied += delta.requests_denied;
        self.stats.requests_delayed += delta.requests_delayed;
        self.stats.requests_queued += delta.requests_queued;
        
        if (delta.wait_time_ms > 0) {
            const total_requests = self.stats.requests_allowed + self.stats.requests_delayed;
            if (total_requests > 0) {
                self.stats.average_wait_time_ms = (self.stats.average_wait_time_ms * @as(f64, @floatFromInt(total_requests - 1)) + delta.wait_time_ms) / @as(f64, @floatFromInt(total_requests));
            }
        }
        
        self.stats.current_queue_size = @intCast(self.request_queue.items.len);
        
        // Update token information
        if (self.token_bucket) |*bucket| {
            self.stats.tokens_available = bucket.getTokens();
            self.stats.last_refill_time = bucket.last_refill.load(.acquire);
        }
    }
    
    pub fn getStats(self: *Self) RateLimitStats {
        self.stats_mutex.lock();
        defer self.stats_mutex.unlock();
        return self.stats;
    }
    
    pub fn getNextRequestId(self: *Self) u64 {
        return self.request_id_counter.fetchAdd(1, .acq_rel);
    }
};

/// Rate limit statistics delta
pub const RateLimitStatsDelta = struct {
    requests_allowed: u64 = 0,
    requests_denied: u64 = 0,
    requests_delayed: u64 = 0,
    requests_queued: u64 = 0,
    wait_time_ms: f64 = 0.0,
};

/// Traffic shaper for bandwidth management
pub const TrafficShaper = struct {
    allocator: std.mem.Allocator,
    rate_limiter: AsyncRateLimiter,
    bandwidth_bps: u64,
    current_usage: std.atomic.Value(u64),
    measurement_window_ms: u64,
    last_measurement: std.atomic.Value(i64),
    
    pub fn init(allocator: std.mem.Allocator, io: io_v2.Io, bandwidth_bps: u64) !TrafficShaper {
        const config = RateLimitConfig{
            .algorithm = .token_bucket,
            .rate_per_second = @as(f64, @floatFromInt(bandwidth_bps / 8)), // Convert bps to bytes per second
            .burst_capacity = bandwidth_bps / 8, // 1 second burst
        };
        
        return TrafficShaper{
            .allocator = allocator,
            .rate_limiter = try AsyncRateLimiter.init(allocator, io, config),
            .bandwidth_bps = bandwidth_bps,
            .current_usage = std.atomic.Value(u64).init(0),
            .measurement_window_ms = 1000,
            .last_measurement = std.atomic.Value(i64).init(time.nanoTimestamp()),
        };
    }
    
    pub fn deinit(self: *TrafficShaper) void {
        self.rate_limiter.deinit();
    }
    
    pub fn shapeTrafficAsync(self: *TrafficShaper, allocator: std.mem.Allocator, bytes: u64) !io_v2.Future {
        const request = RateLimitRequest{
            .id = self.rate_limiter.getNextRequestId(),
            .timestamp = time.nanoTimestamp(),
            .priority = .normal,
            .tokens_required = bytes,
            .source_id = null,
            .metadata = null,
        };
        
        return self.rate_limiter.waitForRateAsync(allocator, request);
    }
    
    pub fn getBandwidthUtilization(self: *TrafficShaper) f64 {
        self.updateMeasurement();
        const usage = self.current_usage.load(.acquire);
        return @as(f64, @floatFromInt(usage * 8)) / @as(f64, @floatFromInt(self.bandwidth_bps));
    }
    
    fn updateMeasurement(self: *TrafficShaper) void {
        const now = time.nanoTimestamp();
        const last_measurement = self.last_measurement.load(.acquire);
        const time_elapsed_ms = @as(u64, @intCast(now - last_measurement)) / 1_000_000;
        
        if (time_elapsed_ms >= self.measurement_window_ms) {
            self.current_usage.store(0, .release);
            self.last_measurement.store(now, .release);
        }
    }
};

// Context structures for async operations
const RateLimitContext = struct {
    limiter: *AsyncRateLimiter,
    request: RateLimitRequest,
    allocator: std.mem.Allocator,
    result: RateLimitResult,
};

const WaitRateLimitContext = struct {
    limiter: *AsyncRateLimiter,
    request: RateLimitRequest,
    allocator: std.mem.Allocator,
    start_time: i64,
    wait_complete: bool,
};

const BatchRateLimitContext = struct {
    limiter: *AsyncRateLimiter,
    requests: []const RateLimitRequest,
    allocator: std.mem.Allocator,
    results: std.ArrayList(RateLimitResult),
};

const UpdateConfigContext = struct {
    limiter: *AsyncRateLimiter,
    new_config: RateLimitConfig,
    allocator: std.mem.Allocator,
    updated: bool,
};

// Poll functions for async operations
fn rateLimitPoll(context: *anyopaque, io: io_v2.Io) io_v2.Future.PollResult {
    _ = io;
    const ctx = @as(*RateLimitContext, @ptrCast(@alignCast(context)));
    
    if (ctx.limiter.checkRateLimit(ctx.request)) {
        ctx.result = .allowed;
        ctx.limiter.updateStats(.{ .requests_allowed = 1 });
    } else {
        ctx.result = .denied;
        ctx.limiter.updateStats(.{ .requests_denied = 1 });
    }
    
    return .{ .ready = ctx.result };
}

fn rateLimitDeinit(context: *anyopaque, allocator: std.mem.Allocator) void {
    const ctx = @as(*RateLimitContext, @ptrCast(@alignCast(context)));
    ctx.request.deinit(allocator);
    allocator.destroy(ctx);
}

fn waitRateLimitPoll(context: *anyopaque, io: io_v2.Io) io_v2.Future.PollResult {
    _ = io;
    const ctx = @as(*WaitRateLimitContext, @ptrCast(@alignCast(context)));
    
    if (ctx.limiter.checkRateLimit(ctx.request)) {
        ctx.wait_complete = true;
        const wait_time = @as(f64, @floatFromInt(time.nanoTimestamp() - ctx.start_time)) / 1_000_000.0;
        ctx.limiter.updateStats(.{ .requests_allowed = 1, .wait_time_ms = wait_time });
        return .{ .ready = true };
    }
    
    // Queue request if not already queued
    ctx.limiter.mutex.lock();
    const queued_request = QueuedRequest{
        .request = ctx.request,
        .queued_at = time.nanoTimestamp(),
        .estimated_wait_time_ms = 1000, // Estimate 1 second
        .retry_count = 0,
    };
    ctx.limiter.request_queue.append(queued_request) catch {};
    ctx.limiter.queue_condition.signal();
    ctx.limiter.mutex.unlock();
    
    ctx.limiter.updateStats(.{ .requests_queued = 1 });
    
    return .{ .pending = {} };
}

fn waitRateLimitDeinit(context: *anyopaque, allocator: std.mem.Allocator) void {
    const ctx = @as(*WaitRateLimitContext, @ptrCast(@alignCast(context)));
    ctx.request.deinit(allocator);
    allocator.destroy(ctx);
}

fn batchRateLimitPoll(context: *anyopaque, io: io_v2.Io) io_v2.Future.PollResult {
    _ = io;
    const ctx = @as(*BatchRateLimitContext, @ptrCast(@alignCast(context)));
    
    for (ctx.requests) |request| {
        const result = if (ctx.limiter.checkRateLimit(request)) .allowed else .denied;
        ctx.results.append(result) catch return .{ .ready = error.OutOfMemory };
    }
    
    return .{ .ready = ctx.results.items.len };
}

fn batchRateLimitDeinit(context: *anyopaque, allocator: std.mem.Allocator) void {
    const ctx = @as(*BatchRateLimitContext, @ptrCast(@alignCast(context)));
    
    for (ctx.requests) |*request| {
        request.deinit(allocator);
    }
    allocator.free(ctx.requests);
    
    ctx.results.deinit();
    allocator.destroy(ctx);
}

fn updateConfigPoll(context: *anyopaque, io: io_v2.Io) io_v2.Future.PollResult {
    _ = io;
    const ctx = @as(*UpdateConfigContext, @ptrCast(@alignCast(context)));
    
    // Update configuration (simplified)
    ctx.limiter.config = ctx.new_config;
    ctx.updated = true;
    
    return .{ .ready = true };
}

fn updateConfigDeinit(context: *anyopaque, allocator: std.mem.Allocator) void {
    const ctx = @as(*UpdateConfigContext, @ptrCast(@alignCast(context)));
    allocator.destroy(ctx);
}

test "token bucket rate limiting" {
    const allocator = std.testing.allocator;
    
    var bucket = TokenBucket.init(10.0, 5.0); // 10 tokens, 5 per second
    
    // Should be able to consume tokens
    try std.testing.expect(bucket.tryConsume(5.0));
    try std.testing.expect(bucket.tryConsume(5.0));
    
    // Should be out of tokens
    try std.testing.expect(!bucket.tryConsume(1.0));
    
    // Wait for refill (simplified test)
    std.time.sleep(200_000_000); // 200ms
    try std.testing.expect(bucket.tryConsume(1.0));
}

test "async rate limiter" {
    const allocator = std.testing.allocator;
    const io = io_v2.Io.init();
    
    const config = RateLimitConfig{
        .algorithm = .token_bucket,
        .rate_per_second = 10.0,
        .burst_capacity = 10,
    };
    
    var limiter = try AsyncRateLimiter.init(allocator, io, config);
    defer limiter.deinit();
    
    try limiter.startWorker();
    defer limiter.stopWorker();
    
    const request = RateLimitRequest{
        .id = 1,
        .timestamp = time.nanoTimestamp(),
        .priority = .normal,
        .tokens_required = 1,
        .source_id = null,
        .metadata = null,
    };
    
    var rate_future = try limiter.checkRateAsync(allocator, request);
    defer rate_future.deinit();
    
    const result = try rate_future.await_op(io, .{});
    try std.testing.expect(result == .allowed);
}

test "traffic shaper" {
    const allocator = std.testing.allocator;
    const io = io_v2.Io.init();
    
    var shaper = try TrafficShaper.init(allocator, io, 1000000); // 1 Mbps
    defer shaper.deinit();
    
    try shaper.rate_limiter.startWorker();
    defer shaper.rate_limiter.stopWorker();
    
    var shape_future = try shaper.shapeTrafficAsync(allocator, 1000); // 1000 bytes
    defer shape_future.deinit();
    
    const result = try shape_future.await_op(io, .{});
    try std.testing.expect(result == true);
}