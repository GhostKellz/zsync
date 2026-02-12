const std = @import("std");
const builtin = @import("builtin");
const compat = @import("compat/thread.zig");
const io_mod = @import("io_v2.zig");
const Io = io_mod.Io;
const zero_copy = @import("zero_copy.zig");
const hardware_accel = @import("hardware_accel.zig");

pub const StreamError = error{
    BackpressureExceeded,
    BufferOverflow,
    StreamClosed,
    RateLimitExceeded,
    DeadlineExceeded,
    SubscriberOverflow,
};

pub const BackpressureStrategy = enum {
    block,       // Block until buffer space available
    drop_oldest, // Drop oldest messages when buffer full
    drop_newest, // Drop newest messages when buffer full
    error_on_full, // Return error when buffer full
};

pub const Priority = enum(u8) {
    low = 0,
    normal = 1,
    high = 2,
    critical = 3,
};

pub const StreamConfig = struct {
    buffer_size: usize = 8192,
    max_buffer_count: usize = 16,
    backpressure_strategy: BackpressureStrategy = .block,
    enable_rate_limiting: bool = false,
    max_messages_per_second: u64 = 1000,
    enable_zero_copy: bool = true,
    enable_hardware_accel: bool = true,
    real_time_priority: bool = false,
    deadline_microseconds: ?u64 = null,
};

pub const StreamMessage = struct {
    data: []const u8,
    priority: Priority = .normal,
    timestamp: u64,
    deadline: ?u64 = null,
    metadata: std.StringHashMap([]const u8),
    
    pub fn init(allocator: std.mem.Allocator, data: []const u8) !StreamMessage {
        return StreamMessage{
            .data = data,
            .timestamp = std.time.microTimestamp(),
            .metadata = std.StringHashMap([]const u8).init(allocator),
        };
    }
    
    pub fn deinit(self: *StreamMessage) void {
        self.metadata.deinit();
    }
    
    pub fn isExpired(self: StreamMessage) bool {
        if (self.deadline) |deadline| {
            return std.time.microTimestamp() >= deadline;
        }
        return false;
    }
};

pub const StreamStats = struct {
    messages_sent: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    messages_received: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    messages_dropped: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    bytes_transferred: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    backpressure_events: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    rate_limit_events: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    avg_latency_microseconds: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    peak_buffer_usage: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    
    pub fn getSnapshot(self: *const StreamStats) StreamStatsSnapshot {
        return StreamStatsSnapshot{
            .messages_sent = self.messages_sent.load(.acquire),
            .messages_received = self.messages_received.load(.acquire),
            .messages_dropped = self.messages_dropped.load(.acquire),
            .bytes_transferred = self.bytes_transferred.load(.acquire),
            .backpressure_events = self.backpressure_events.load(.acquire),
            .rate_limit_events = self.rate_limit_events.load(.acquire),
            .avg_latency_microseconds = self.avg_latency_microseconds.load(.acquire),
            .peak_buffer_usage = self.peak_buffer_usage.load(.acquire),
        };
    }
};

pub const StreamStatsSnapshot = struct {
    messages_sent: u64,
    messages_received: u64,
    messages_dropped: u64,
    bytes_transferred: u64,
    backpressure_events: u64,
    rate_limit_events: u64,
    avg_latency_microseconds: u64,
    peak_buffer_usage: u64,
    
    pub fn getThroughputMbps(self: StreamStatsSnapshot, duration_seconds: f64) f64 {
        const bytes_per_second = @as(f64, @floatFromInt(self.bytes_transferred)) / duration_seconds;
        return (bytes_per_second * 8.0) / (1024.0 * 1024.0);
    }
    
    pub fn getMessageRate(self: StreamStatsSnapshot, duration_seconds: f64) f64 {
        return @as(f64, @floatFromInt(self.messages_sent)) / duration_seconds;
    }
    
    pub fn getDropRate(self: StreamStatsSnapshot) f64 {
        if (self.messages_sent == 0) return 0.0;
        return @as(f64, @floatFromInt(self.messages_dropped)) / @as(f64, @floatFromInt(self.messages_sent));
    }
};

const RateLimiter = struct {
    max_per_second: u64,
    window_size_microseconds: u64,
    token_bucket: std.atomic.Value(u64),
    last_refill: std.atomic.Value(u64),
    
    pub fn init(max_per_second: u64) RateLimiter {
        return .{
            .max_per_second = max_per_second,
            .window_size_microseconds = 1_000_000, // 1 second
            .token_bucket = std.atomic.Value(u64).init(max_per_second),
            .last_refill = std.atomic.Value(u64).init(std.time.microTimestamp()),
        };
    }
    
    pub fn tryAcquire(self: *RateLimiter, tokens: u64) bool {
        const now = std.time.microTimestamp();
        const last = self.last_refill.load(.acquire);
        
        // Refill tokens based on elapsed time
        if (now > last) {
            const elapsed = now - last;
            const tokens_to_add = (elapsed * self.max_per_second) / self.window_size_microseconds;
            
            if (tokens_to_add > 0) {
                const current = self.token_bucket.load(.acquire);
                const new_tokens = @min(current + tokens_to_add, self.max_per_second);
                
                _ = self.token_bucket.compareAndSwap(current, new_tokens, .acq_rel, .acquire);
                _ = self.last_refill.compareAndSwap(last, now, .acq_rel, .acquire);
            }
        }
        
        // Try to consume tokens
        while (true) {
            const current = self.token_bucket.load(.acquire);
            if (current < tokens) return false;
            
            if (self.token_bucket.compareAndSwap(current, current - tokens, .acq_rel, .acquire) == null) {
                return true;
            }
        }
    }
};

pub const RealtimeStream = struct {
    allocator: std.mem.Allocator,
    config: StreamConfig,
    buffer_pool: zero_copy.BufferPool,
    hardware_accel: hardware_accel.HardwareAccel,
    rate_limiter: ?RateLimiter,
    stats: StreamStats,
    
    // Ring buffer for messages
    message_ring: zero_copy.ZeroCopyRingBuffer,
    
    // Priority queues
    priority_queues: [4]std.PriorityQueue(StreamMessage, void, compareMessagePriority),
    
    // Subscriber management
    subscribers: std.ArrayList(Subscriber),
    subscriber_mutex: compat.Mutex,
    
    // Flow control
    backpressure_signal: std.Thread.Condition,
    flow_control_mutex: compat.Mutex,
    is_flowing: std.atomic.Value(bool),
    
    // Real-time scheduling
    rt_thread: ?std.Thread,
    should_stop: std.atomic.Value(bool),
    
    const Subscriber = struct {
        id: u32,
        callback: *const fn (message: StreamMessage) anyerror!void,
        filter: ?*const fn (message: StreamMessage) bool,
        priority_mask: u8, // Bitmask for priority levels
        max_queue_size: usize,
        queue_size: std.atomic.Value(usize),
    };
    
    pub fn init(allocator: std.mem.Allocator, config: StreamConfig) !RealtimeStream {
        var buffer_pool = try zero_copy.BufferPool.init(allocator);
        errdefer buffer_pool.deinit();
        
        var message_ring = try zero_copy.ZeroCopyRingBuffer.init(
            allocator, 
            config.buffer_size * config.max_buffer_count
        );
        errdefer message_ring.deinit(allocator);
        
        var priority_queues: [4]std.PriorityQueue(StreamMessage, void, compareMessagePriority) = undefined;
        for (&priority_queues) |*queue| {
            queue.* = std.PriorityQueue(StreamMessage, void, compareMessagePriority).init(allocator, {});
        }
        
        return RealtimeStream{
            .allocator = allocator,
            .config = config,
            .buffer_pool = buffer_pool,
            .hardware_accel = hardware_accel.HardwareAccel.init(),
            .rate_limiter = if (config.enable_rate_limiting) 
                RateLimiter.init(config.max_messages_per_second) else null,
            .stats = StreamStats{},
            .message_ring = message_ring,
            .priority_queues = priority_queues,
            .subscribers = std.ArrayList(Subscriber){ .allocator = allocator },
            .subscriber_mutex = compat.Mutex{},
            .backpressure_signal = std.Thread.Condition{},
            .flow_control_mutex = compat.Mutex{},
            .is_flowing = std.atomic.Value(bool).init(true),
            .rt_thread = null,
            .should_stop = std.atomic.Value(bool).init(false),
        };
    }
    
    pub fn deinit(self: *RealtimeStream) void {
        self.stop();
        
        self.message_ring.deinit(self.allocator);
        self.buffer_pool.deinit();
        
        for (&self.priority_queues) |*queue| {
            while (queue.removeOrNull()) |msg| {
                var message = msg;
                message.deinit();
            }
            queue.deinit();
        }
        
        self.subscribers.deinit();
    }
    
    pub fn start(self: *RealtimeStream, io: Io) !void {
        if (self.config.real_time_priority) {
            self.rt_thread = try std.Thread.spawn(.{}, realtimeWorker, .{ self, io });
            
            // Set real-time priority on supported platforms
            if (builtin.os.tag == .linux) {
                try self.setRealtimePriority();
            }
        }
    }
    
    pub fn stop(self: *RealtimeStream) void {
        self.should_stop.store(true, .release);
        
        if (self.rt_thread) |thread| {
            self.backpressure_signal.broadcast();
            thread.join();
            self.rt_thread = null;
        }
    }
    
    fn setRealtimePriority(self: *RealtimeStream) !void {
        if (builtin.os.tag == .linux) {
            const c = std.c;
            const SCHED_FIFO = 1;
            
            var param: c.sched_param = undefined;
            param.sched_priority = 50; // High but not maximum priority
            
            if (c.sched_setscheduler(0, SCHED_FIFO, &param) != 0) {
                return error.FailedToSetRealtimePriority;
            }
        }
        _ = self;
    }
    
    pub fn send(self: *RealtimeStream, io: Io, message: StreamMessage) !void {
        // Check rate limiting
        if (self.rate_limiter) |*limiter| {
            if (!limiter.tryAcquire(1)) {
                _ = self.stats.rate_limit_events.fetchAdd(1, .acq_rel);
                return StreamError.RateLimitExceeded;
            }
        }
        
        // Check deadline
        if (message.isExpired()) {
            _ = self.stats.messages_dropped.fetchAdd(1, .acq_rel);
            return StreamError.DeadlineExceeded;
        }
        
        // Handle backpressure
        try self.handleBackpressure(io);
        
        // Add to appropriate priority queue
        const priority_idx = @intFromEnum(message.priority);
        
        self.flow_control_mutex.lock();
        defer self.flow_control_mutex.unlock();
        
        try self.priority_queues[priority_idx].add(message);
        
        // Update stats
        _ = self.stats.messages_sent.fetchAdd(1, .acq_rel);
        _ = self.stats.bytes_transferred.fetchAdd(message.data.len, .acq_rel);
        
        // Signal waiting consumers
        self.backpressure_signal.signal();
    }
    
    fn handleBackpressure(self: *RealtimeStream, io: Io) !void {
        const total_queued = self.getTotalQueuedMessages();
        
        if (total_queued >= self.config.max_buffer_count) {
            _ = self.stats.backpressure_events.fetchAdd(1, .acq_rel);
            
            switch (self.config.backpressure_strategy) {
                .block => {
                    self.flow_control_mutex.lock();
                    defer self.flow_control_mutex.unlock();
                    
                    while (self.getTotalQueuedMessages() >= self.config.max_buffer_count and 
                           self.is_flowing.load(.acquire)) {
                        self.backpressure_signal.wait(&self.flow_control_mutex);
                    }
                },
                .drop_oldest => {
                    try self.dropOldestMessages(1);
                },
                .drop_newest => {
                    _ = self.stats.messages_dropped.fetchAdd(1, .acq_rel);
                    return StreamError.BackpressureExceeded;
                },
                .error_on_full => {
                    return StreamError.BufferOverflow;
                },
            }
        }
        _ = io;
    }
    
    fn getTotalQueuedMessages(self: *RealtimeStream) usize {
        var total: usize = 0;
        for (self.priority_queues) |*queue| {
            total += queue.count();
        }
        return total;
    }
    
    fn dropOldestMessages(self: *RealtimeStream, count: usize) !void {
        var dropped: usize = 0;
        
        // Drop from lowest priority first
        for (self.priority_queues, 0..) |*queue, i| {
            while (dropped < count and queue.count() > 0) {
                if (queue.removeOrNull()) |msg| {
                    var message = msg;
                    message.deinit();
                    dropped += 1;
                    _ = self.stats.messages_dropped.fetchAdd(1, .acq_rel);
                }
            }
            if (dropped >= count) break;
            _ = i;
        }
    }
    
    pub fn subscribe(
        self: *RealtimeStream,
        callback: *const fn (message: StreamMessage) anyerror!void,
        priority_mask: u8,
        max_queue_size: usize,
        filter: ?*const fn (message: StreamMessage) bool,
    ) !u32 {
        self.subscriber_mutex.lock();
        defer self.subscriber_mutex.unlock();
        
        const id = @as(u32, @intCast(self.subscribers.items.len));
        try self.subscribers.append(self.allocator, .{
            .id = id,
            .callback = callback,
            .filter = filter,
            .priority_mask = priority_mask,
            .max_queue_size = max_queue_size,
            .queue_size = std.atomic.Value(usize).init(0),
        });
        
        return id;
    }
    
    pub fn unsubscribe(self: *RealtimeStream, id: u32) void {
        self.subscriber_mutex.lock();
        defer self.subscriber_mutex.unlock();
        
        for (self.subscribers.items, 0..) |subscriber, i| {
            if (subscriber.id == id) {
                _ = self.subscribers.orderedRemove(i);
                break;
            }
        }
    }
    
    fn realtimeWorker(self: *RealtimeStream, io: Io) !void {
        const latency_samples = try self.allocator.alloc(u64, 1000);
        defer self.allocator.free(latency_samples);
        var latency_idx: usize = 0;
        
        while (!self.should_stop.load(.acquire)) {
            const process_start = std.time.microTimestamp();
            
            // Process messages by priority (highest first)
            var processed = false;
            var priority_level: i32 = 3;
            
            while (priority_level >= 0) : (priority_level -= 1) {
                const idx = @as(usize, @intCast(priority_level));
                
                self.flow_control_mutex.lock();
                const message_opt = self.priority_queues[idx].removeOrNull();
                self.flow_control_mutex.unlock();
                
                if (message_opt) |message| {
                    processed = true;
                    try self.processMessage(io, message, &latency_samples, &latency_idx);
                    
                    // Signal backpressure relief
                    self.backpressure_signal.signal();
                    
                    // Check deadline constraint
                    if (self.config.deadline_microseconds) |deadline| {
                        const elapsed = std.time.microTimestamp() - process_start;
                        if (elapsed >= deadline) {
                            break; // Yield to maintain real-time constraints
                        }
                    }
                }
            }
            
            if (!processed) {
                // No messages to process, yield CPU
                if (self.config.real_time_priority) {
                    std.Thread.yield() catch {};
                } else {
                    std.time.sleep(100); // 100 microseconds
                }
            }
        }
    }
    
    fn processMessage(
        self: *RealtimeStream,
        io: Io,
        message: StreamMessage,
        latency_samples: []u64,
        latency_idx: *usize,
    ) !void {
        const start_time = std.time.microTimestamp();
        
        // Deliver to subscribers
        self.subscriber_mutex.lock();
        const subscribers = try self.allocator.dupe(Subscriber, self.subscribers.items);
        self.subscriber_mutex.unlock();
        defer self.allocator.free(subscribers);
        
        for (subscribers) |*subscriber| {
            // Check priority mask
            const priority_bit = @as(u8, 1) << @intFromEnum(message.priority);
            if ((subscriber.priority_mask & priority_bit) == 0) continue;
            
            // Check filter
            if (subscriber.filter) |filter| {
                if (!filter(message)) continue;
            }
            
            // Check queue size
            const current_queue_size = subscriber.queue_size.load(.acquire);
            if (current_queue_size >= subscriber.max_queue_size) {
                _ = self.stats.messages_dropped.fetchAdd(1, .acq_rel);
                continue;
            }
            
            // Deliver message asynchronously
            _ = subscriber.queue_size.fetchAdd(1, .acq_rel);
            
            const future = io.async(deliverToSubscriber, .{ subscriber, message });
            // Fire and forget - don't block real-time processing
            _ = future;
        }
        
        // Update latency metrics
        const end_time = std.time.microTimestamp();
        const latency = end_time - start_time;
        
        latency_samples[latency_idx.*] = latency;
        latency_idx.* = (latency_idx.* + 1) % latency_samples.len;
        
        // Calculate rolling average
        var total_latency: u64 = 0;
        for (latency_samples) |sample| {
            total_latency += sample;
        }
        const avg_latency = total_latency / latency_samples.len;
        self.stats.avg_latency_microseconds.store(avg_latency, .release);
        
        _ = self.stats.messages_received.fetchAdd(1, .acq_rel);
    }
    
    fn deliverToSubscriber(subscriber: *Subscriber, message: StreamMessage) !void {
        defer _ = subscriber.queue_size.fetchSub(1, .acq_rel);
        try subscriber.callback(message);
    }
    
    pub fn getStats(self: *RealtimeStream) StreamStatsSnapshot {
        return self.stats.getSnapshot();
    }
    
    pub fn pause(self: *RealtimeStream) void {
        self.is_flowing.store(false, .release);
    }
    
    pub fn resumeStream(self: *RealtimeStream) void {
        self.is_flowing.store(true, .release);
        self.backpressure_signal.broadcast();
    }
    
    // Utility for priority comparison
    fn compareMessagePriority(context: void, a: StreamMessage, b: StreamMessage) std.math.Order {
        _ = context;
        
        // Higher priority first, then by timestamp (older first)
        if (@intFromEnum(a.priority) > @intFromEnum(b.priority)) return .lt;
        if (@intFromEnum(a.priority) < @intFromEnum(b.priority)) return .gt;
        
        if (a.timestamp < b.timestamp) return .lt;
        if (a.timestamp > b.timestamp) return .gt;
        
        return .eq;
    }
};

// High-level streaming API
pub const StreamBuilder = struct {
    allocator: std.mem.Allocator,
    config: StreamConfig,
    
    pub fn init(allocator: std.mem.Allocator) StreamBuilder {
        return .{
            .allocator = allocator,
            .config = StreamConfig{},
        };
    }
    
    pub fn withBufferSize(self: StreamBuilder, size: usize) StreamBuilder {
        var builder = self;
        builder.config.buffer_size = size;
        return builder;
    }
    
    pub fn withBackpressure(self: StreamBuilder, strategy: BackpressureStrategy) StreamBuilder {
        var builder = self;
        builder.config.backpressure_strategy = strategy;
        return builder;
    }
    
    pub fn withRateLimit(self: StreamBuilder, max_per_second: u64) StreamBuilder {
        var builder = self;
        builder.config.enable_rate_limiting = true;
        builder.config.max_messages_per_second = max_per_second;
        return builder;
    }
    
    pub fn withRealTimePriority(self: StreamBuilder) StreamBuilder {
        var builder = self;
        builder.config.real_time_priority = true;
        return builder;
    }
    
    pub fn withDeadline(self: StreamBuilder, microseconds: u64) StreamBuilder {
        var builder = self;
        builder.config.deadline_microseconds = microseconds;
        return builder;
    }
    
    pub fn build(self: StreamBuilder) !RealtimeStream {
        return RealtimeStream.init(self.allocator, self.config);
    }
};

// Convenience functions for common streaming patterns
pub fn createHighThroughputStream(allocator: std.mem.Allocator) !RealtimeStream {
    return StreamBuilder.init(allocator)
        .withBufferSize(64 * 1024)
        .withBackpressure(.drop_oldest)
        .withRateLimit(100_000)
        .build();
}

pub fn createLowLatencyStream(allocator: std.mem.Allocator) !RealtimeStream {
    return StreamBuilder.init(allocator)
        .withBufferSize(4 * 1024)
        .withBackpressure(.error_on_full)
        .withRealTimePriority()
        .withDeadline(100) // 100 microseconds
        .build();
}

pub fn createReliableStream(allocator: std.mem.Allocator) !RealtimeStream {
    return StreamBuilder.init(allocator)
        .withBufferSize(32 * 1024)
        .withBackpressure(.block)
        .build();
}