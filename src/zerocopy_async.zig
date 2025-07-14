//! Zero-Copy Packet Processing with Kernel Bypass
//! Ultra-high performance async networking with DPDK-style operations
//! Designed for maximum throughput and minimal latency

const std = @import("std");
const io_v2 = @import("io_v2.zig");
const linux = std.os.linux;

/// Zero-Copy Configuration
pub const ZeroCopyConfig = struct {
    ring_buffer_size: u32 = 2048,
    batch_size: u32 = 64,
    worker_threads: u32 = 4,
    memory_pool_size: u64 = 64 * 1024 * 1024, // 64MB
    huge_pages_enabled: bool = true,
    numa_aware: bool = true,
    cpu_affinity_enabled: bool = true,
};

/// Memory Pool for zero-copy operations
pub const MemoryPool = struct {
    base_addr: [*]u8,
    size: u64,
    free_blocks: std.ArrayList(MemoryBlock),
    allocated_blocks: std.hash_map.HashMap(usize, MemoryBlock, std.hash_map.AutoContext(usize), 80),
    block_size: u32,
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, size: u64, block_size: u32, use_huge_pages: bool) !Self {
        const aligned_size = std.mem.alignForward(u64, size, std.mem.page_size);
        
        // Allocate memory with huge pages if enabled
        const base_addr = if (use_huge_pages) blk: {
            // In production, would use mmap with MAP_HUGETLB
            const mem = try allocator.alignedAlloc(u8, std.mem.page_size, aligned_size);
            break :blk mem.ptr;
        } else blk: {
            const mem = try allocator.alignedAlloc(u8, std.mem.page_size, aligned_size);
            break :blk mem.ptr;
        };
        
        var pool = Self{
            .base_addr = base_addr,
            .size = aligned_size,
            .free_blocks = std.ArrayList(MemoryBlock).init(allocator),
            .allocated_blocks = std.hash_map.HashMap(usize, MemoryBlock, std.hash_map.AutoContext(usize), 80).init(allocator),
            .block_size = block_size,
            .allocator = allocator,
            .mutex = .{},
        };
        
        // Initialize free blocks
        const num_blocks = aligned_size / block_size;
        for (0..num_blocks) |i| {
            const block = MemoryBlock{
                .addr = @intFromPtr(base_addr) + (i * block_size),
                .size = block_size,
                .index = @intCast(i),
                .in_use = false,
            };
            try pool.free_blocks.append(block);
        }
        
        return pool;
    }
    
    pub fn deinit(self: *Self) void {
        // In production, would call munmap for huge pages
        const slice = @as([*]u8, @ptrFromInt(@intFromPtr(self.base_addr)))[0..self.size];
        self.allocator.free(slice);
        
        self.free_blocks.deinit();
        self.allocated_blocks.deinit();
    }
    
    pub fn allocateBlock(self: *Self) ?MemoryBlock {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (self.free_blocks.items.len == 0) return null;
        
        var block = self.free_blocks.pop();
        block.in_use = true;
        
        self.allocated_blocks.put(block.index, block) catch return null;
        
        return block;
    }
    
    pub fn freeBlock(self: *Self, block: MemoryBlock) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (self.allocated_blocks.remove(block.index)) {
            var freed_block = block;
            freed_block.in_use = false;
            self.free_blocks.append(freed_block) catch {};
        }
    }
    
    pub fn getUtilization(self: *Self) f64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        const total_blocks = self.free_blocks.items.len + self.allocated_blocks.count();
        if (total_blocks == 0) return 0.0;
        
        return @as(f64, @floatFromInt(self.allocated_blocks.count())) / @as(f64, @floatFromInt(total_blocks));
    }
};

/// Memory block representation
pub const MemoryBlock = struct {
    addr: usize,
    size: u32,
    index: u32,
    in_use: bool,
    
    pub fn asSlice(self: MemoryBlock) []u8 {
        return @as([*]u8, @ptrFromInt(self.addr))[0..self.size];
    }
};

/// High-performance ring buffer for packet processing
pub const PacketRingBuffer = struct {
    packets: []PacketDescriptor,
    head: std.atomic.Value(u32),
    tail: std.atomic.Value(u32),
    size: u32,
    mask: u32,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, size: u32) !Self {
        // Ensure size is power of 2
        const actual_size = std.math.ceilPowerOfTwo(u32, size) catch return error.InvalidSize;
        
        return Self{
            .packets = try allocator.alloc(PacketDescriptor, actual_size),
            .head = std.atomic.Value(u32).init(0),
            .tail = std.atomic.Value(u32).init(0),
            .size = actual_size,
            .mask = actual_size - 1,
        };
    }
    
    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.packets);
    }
    
    pub fn push(self: *Self, packet: PacketDescriptor) bool {
        const current_tail = self.tail.load(.acquire);
        const next_tail = (current_tail + 1) & self.mask;
        
        // Check if ring is full
        if (next_tail == self.head.load(.acquire)) {
            return false;
        }
        
        self.packets[current_tail] = packet;
        self.tail.store(next_tail, .release);
        
        return true;
    }
    
    pub fn pop(self: *Self) ?PacketDescriptor {
        const current_head = self.head.load(.acquire);
        
        // Check if ring is empty
        if (current_head == self.tail.load(.acquire)) {
            return null;
        }
        
        const packet = self.packets[current_head];
        const next_head = (current_head + 1) & self.mask;
        self.head.store(next_head, .release);
        
        return packet;
    }
    
    pub fn batchPop(self: *Self, packets: []PacketDescriptor) u32 {
        var count: u32 = 0;
        
        while (count < packets.len) {
            if (self.pop()) |packet| {
                packets[count] = packet;
                count += 1;
            } else {
                break;
            }
        }
        
        return count;
    }
    
    pub fn getUtilization(self: *Self) f64 {
        const head = self.head.load(.acquire);
        const tail = self.tail.load(.acquire);
        
        const used = if (tail >= head) tail - head else self.size - head + tail;
        
        return @as(f64, @floatFromInt(used)) / @as(f64, @floatFromInt(self.size));
    }
};

/// Packet descriptor for zero-copy operations
pub const PacketDescriptor = struct {
    memory_block: MemoryBlock,
    data_offset: u32,
    data_length: u32,
    packet_type: PacketType,
    timestamp: u64,
    metadata: PacketMetadata,
    
    pub fn getData(self: PacketDescriptor) []u8 {
        const slice = self.memory_block.asSlice();
        return slice[self.data_offset..self.data_offset + self.data_length];
    }
    
    pub fn setData(self: *PacketDescriptor, data: []const u8) void {
        const slice = self.memory_block.asSlice();
        const max_len = @min(data.len, slice.len - self.data_offset);
        
        @memcpy(slice[self.data_offset..self.data_offset + max_len], data[0..max_len]);
        self.data_length = @intCast(max_len);
    }
};

/// Packet types for classification
pub const PacketType = enum(u8) {
    ethernet = 0,
    ipv4 = 1,
    ipv6 = 2,
    tcp = 3,
    udp = 4,
    icmp = 5,
    arp = 6,
    unknown = 255,
};

/// Packet metadata for processing
pub const PacketMetadata = struct {
    source_port: u16 = 0,
    dest_port: u16 = 0,
    protocol: u8 = 0,
    vlan_id: u16 = 0,
    queue_id: u8 = 0,
    priority: u8 = 0,
    flags: PacketFlags = .{},
};

/// Packet processing flags
pub const PacketFlags = packed struct {
    fragmented: bool = false,
    checksummed: bool = false,
    encrypted: bool = false,
    compressed: bool = false,
    _reserved: u4 = 0,
};

/// Zero-copy async network interface
pub const ZeroCopyNetworkInterface = struct {
    allocator: std.mem.Allocator,
    io: io_v2.Io,
    
    // Memory management
    memory_pool: MemoryPool,
    
    // Packet processing
    rx_ring: PacketRingBuffer,
    tx_ring: PacketRingBuffer,
    
    // Worker management
    rx_workers: []std.Thread,
    tx_workers: []std.Thread,
    worker_active: std.atomic.Value(bool),
    
    // Statistics
    stats: NetworkStats,
    stats_mutex: std.Thread.Mutex,
    
    // Configuration
    config: ZeroCopyConfig,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, io: io_v2.Io, config: ZeroCopyConfig) !Self {
        return Self{
            .allocator = allocator,
            .io = io,
            .memory_pool = try MemoryPool.init(allocator, config.memory_pool_size, 2048, config.huge_pages_enabled),
            .rx_ring = try PacketRingBuffer.init(allocator, config.ring_buffer_size),
            .tx_ring = try PacketRingBuffer.init(allocator, config.ring_buffer_size),
            .rx_workers = try allocator.alloc(std.Thread, config.worker_threads),
            .tx_workers = try allocator.alloc(std.Thread, config.worker_threads),
            .worker_active = std.atomic.Value(bool).init(false),
            .stats = NetworkStats{},
            .stats_mutex = .{},
            .config = config,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.stopWorkers();
        
        self.memory_pool.deinit();
        self.rx_ring.deinit(self.allocator);
        self.tx_ring.deinit(self.allocator);
        self.allocator.free(self.rx_workers);
        self.allocator.free(self.tx_workers);
    }
    
    /// Start zero-copy packet processing workers
    pub fn startWorkers(self: *Self) !void {
        if (self.worker_active.swap(true, .acquire)) return;
        
        // Start RX workers
        for (self.rx_workers, 0..) |*thread, i| {
            thread.* = try std.Thread.spawn(.{}, rxWorker, .{ self, i });
        }
        
        // Start TX workers
        for (self.tx_workers, 0..) |*thread, i| {
            thread.* = try std.Thread.spawn(.{}, txWorker, .{ self, i });
        }
    }
    
    /// Stop packet processing workers
    pub fn stopWorkers(self: *Self) void {
        if (!self.worker_active.swap(false, .release)) return;
        
        for (self.rx_workers) |thread| {
            thread.join();
        }
        
        for (self.tx_workers) |thread| {
            thread.join();
        }
    }
    
    /// Receive packet with zero-copy
    pub fn receivePacketAsync(self: *Self, allocator: std.mem.Allocator) !io_v2.Future {
        const ctx = try allocator.create(ReceivePacketContext);
        ctx.* = .{
            .interface = self,
            .allocator = allocator,
            .packet = undefined,
        };
        
        return io_v2.Future{
            .impl = .{
                .callback = .{
                    .context = @ptrCast(ctx),
                    .poll_fn = receivePacketPoll,
                    .deinit_fn = receivePacketDeinit,
                },
            },
        };
    }
    
    /// Send packet with zero-copy
    pub fn sendPacketAsync(self: *Self, allocator: std.mem.Allocator, packet: PacketDescriptor) !io_v2.Future {
        const ctx = try allocator.create(SendPacketContext);
        ctx.* = .{
            .interface = self,
            .packet = packet,
            .allocator = allocator,
            .sent = false,
        };
        
        return io_v2.Future{
            .impl = .{
                .callback = .{
                    .context = @ptrCast(ctx),
                    .poll_fn = sendPacketPoll,
                    .deinit_fn = sendPacketDeinit,
                },
            },
        };
    }
    
    /// Batch receive packets for high throughput
    pub fn batchReceiveAsync(self: *Self, allocator: std.mem.Allocator, max_packets: u32) !io_v2.Future {
        const ctx = try allocator.create(BatchReceiveContext);
        ctx.* = .{
            .interface = self,
            .max_packets = max_packets,
            .allocator = allocator,
            .packets = std.ArrayList(PacketDescriptor).init(allocator),
        };
        
        return io_v2.Future{
            .impl = .{
                .callback = .{
                    .context = @ptrCast(ctx),
                    .poll_fn = batchReceivePoll,
                    .deinit_fn = batchReceiveDeinit,
                },
            },
        };
    }
    
    /// Batch send packets for high throughput
    pub fn batchSendAsync(self: *Self, allocator: std.mem.Allocator, packets: []const PacketDescriptor) !io_v2.Future {
        const ctx = try allocator.create(BatchSendContext);
        ctx.* = .{
            .interface = self,
            .packets = try allocator.dupe(PacketDescriptor, packets),
            .allocator = allocator,
            .sent_count = 0,
        };
        
        return io_v2.Future{
            .impl = .{
                .callback = .{
                    .context = @ptrCast(ctx),
                    .poll_fn = batchSendPoll,
                    .deinit_fn = batchSendDeinit,
                },
            },
        };
    }
    
    fn rxWorker(self: *Self, worker_id: usize) void {
        _ = worker_id;
        
        while (self.worker_active.load(.acquire)) {
            self.processRxQueue() catch |err| {
                std.log.err("RX worker error: {}", .{err});
            };
            
            // Brief yield to prevent busy waiting
            std.time.sleep(1000);
        }
    }
    
    fn txWorker(self: *Self, worker_id: usize) void {
        _ = worker_id;
        
        while (self.worker_active.load(.acquire)) {
            self.processTxQueue() catch |err| {
                std.log.err("TX worker error: {}", .{err});
            };
            
            // Brief yield to prevent busy waiting
            std.time.sleep(1000);
        }
    }
    
    fn processRxQueue(self: *Self) !void {
        // Simulate packet reception from hardware
        var batch_packets: [64]PacketDescriptor = undefined;
        const received_count = self.simulateHardwareRx(batch_packets[0..]);
        
        // Add received packets to RX ring
        for (batch_packets[0..received_count]) |packet| {
            if (!self.rx_ring.push(packet)) {
                // Ring full, drop packet
                self.updateStats(.{ .rx_dropped = 1 });
                self.memory_pool.freeBlock(packet.memory_block);
            } else {
                self.updateStats(.{ .rx_packets = 1, .rx_bytes = packet.data_length });
            }
        }
    }
    
    fn processTxQueue(self: *Self) !void {
        // Process packets from TX ring
        var batch_packets: [64]PacketDescriptor = undefined;
        const count = self.tx_ring.batchPop(batch_packets[0..]);
        
        if (count > 0) {
            // Simulate hardware transmission
            const sent_count = self.simulateHardwareTx(batch_packets[0..count]);
            
            // Update statistics
            for (batch_packets[0..sent_count]) |packet| {
                self.updateStats(.{ .tx_packets = 1, .tx_bytes = packet.data_length });
                self.memory_pool.freeBlock(packet.memory_block);
            }
            
            // Handle unsent packets (errors)
            for (batch_packets[sent_count..count]) |packet| {
                self.updateStats(.{ .tx_errors = 1 });
                self.memory_pool.freeBlock(packet.memory_block);
            }
        }
    }
    
    fn simulateHardwareRx(self: *Self, packets: []PacketDescriptor) u32 {
        // Simulate receiving packets from network hardware
        const max_packets = @min(packets.len, 16); // Simulate burst
        var count: u32 = 0;
        
        for (0..max_packets) |i| {
            _ = i;
            if (self.memory_pool.allocateBlock()) |block| {
                // Simulate packet data
                const data = "Hello, Zero-Copy World!";
                const packet = PacketDescriptor{
                    .memory_block = block,
                    .data_offset = 0,
                    .data_length = @intCast(data.len),
                    .packet_type = .ethernet,
                    .timestamp = @intCast(std.time.nanoTimestamp()),
                    .metadata = PacketMetadata{},
                };
                
                // Copy simulated data
                const slice = block.asSlice();
                @memcpy(slice[0..data.len], data);
                
                packets[count] = packet;
                count += 1;
            } else {
                break; // No more memory blocks
            }
        }
        
        return count;
    }
    
    fn simulateHardwareTx(self: *Self, packets: []const PacketDescriptor) u32 {
        _ = self;
        // Simulate transmitting packets to network hardware
        // In real implementation, would use DMA to hardware queues
        return @intCast(packets.len); // Assume all packets sent successfully
    }
    
    fn updateStats(self: *Self, delta: NetworkStatsDelta) void {
        self.stats_mutex.lock();
        defer self.stats_mutex.unlock();
        
        self.stats.rx_packets += delta.rx_packets;
        self.stats.rx_bytes += delta.rx_bytes;
        self.stats.rx_dropped += delta.rx_dropped;
        self.stats.tx_packets += delta.tx_packets;
        self.stats.tx_bytes += delta.tx_bytes;
        self.stats.tx_errors += delta.tx_errors;
    }
    
    pub fn getStats(self: *Self) NetworkStats {
        self.stats_mutex.lock();
        defer self.stats_mutex.unlock();
        return self.stats;
    }
};

/// Network statistics
pub const NetworkStats = struct {
    rx_packets: u64 = 0,
    rx_bytes: u64 = 0,
    rx_dropped: u64 = 0,
    tx_packets: u64 = 0,
    tx_bytes: u64 = 0,
    tx_errors: u64 = 0,
    
    pub fn getRxRate(self: NetworkStats, duration_seconds: f64) f64 {
        return @as(f64, @floatFromInt(self.rx_packets)) / duration_seconds;
    }
    
    pub fn getTxRate(self: NetworkStats, duration_seconds: f64) f64 {
        return @as(f64, @floatFromInt(self.tx_packets)) / duration_seconds;
    }
    
    pub fn getBandwidthMbps(self: NetworkStats, duration_seconds: f64) f64 {
        const total_bytes = self.rx_bytes + self.tx_bytes;
        const bytes_per_second = @as(f64, @floatFromInt(total_bytes)) / duration_seconds;
        return (bytes_per_second * 8.0) / (1024.0 * 1024.0); // Convert to Mbps
    }
};

/// Statistics delta for atomic updates
pub const NetworkStatsDelta = struct {
    rx_packets: u64 = 0,
    rx_bytes: u64 = 0,
    rx_dropped: u64 = 0,
    tx_packets: u64 = 0,
    tx_bytes: u64 = 0,
    tx_errors: u64 = 0,
};

/// Kernel bypass driver interface
pub const KernelBypassDriver = struct {
    allocator: std.mem.Allocator,
    device_name: []const u8,
    queue_count: u32,
    rx_queues: []DriverQueue,
    tx_queues: []DriverQueue,
    memory_pool: MemoryPool,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, device_name: []const u8, queue_count: u32) !Self {
        return Self{
            .allocator = allocator,
            .device_name = try allocator.dupe(u8, device_name),
            .queue_count = queue_count,
            .rx_queues = try allocator.alloc(DriverQueue, queue_count),
            .tx_queues = try allocator.alloc(DriverQueue, queue_count),
            .memory_pool = try MemoryPool.init(allocator, 128 * 1024 * 1024, 2048, true),
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.device_name);
        self.allocator.free(self.rx_queues);
        self.allocator.free(self.tx_queues);
        self.memory_pool.deinit();
    }
    
    pub fn bindToNuma(self: *Self, numa_node: u32) !void {
        _ = self;
        _ = numa_node;
        // In production, would set NUMA affinity for memory and queues
    }
    
    pub fn setCpuAffinity(self: *Self, queue_id: u32, cpu_core: u32) !void {
        _ = self;
        _ = queue_id;
        _ = cpu_core;
        // In production, would set CPU affinity for queue processing
    }
};

/// Driver queue for kernel bypass
pub const DriverQueue = struct {
    id: u32,
    descriptors: []QueueDescriptor,
    head: u32,
    tail: u32,
    size: u32,
    
    pub fn init(allocator: std.mem.Allocator, id: u32, size: u32) !DriverQueue {
        return DriverQueue{
            .id = id,
            .descriptors = try allocator.alloc(QueueDescriptor, size),
            .head = 0,
            .tail = 0,
            .size = size,
        };
    }
    
    pub fn deinit(self: *DriverQueue, allocator: std.mem.Allocator) void {
        allocator.free(self.descriptors);
    }
};

/// Queue descriptor for hardware interaction
pub const QueueDescriptor = struct {
    address: u64,
    length: u32,
    status: u32,
    metadata: u32,
};

// Context structures for async operations
const ReceivePacketContext = struct {
    interface: *ZeroCopyNetworkInterface,
    allocator: std.mem.Allocator,
    packet: PacketDescriptor,
};

const SendPacketContext = struct {
    interface: *ZeroCopyNetworkInterface,
    packet: PacketDescriptor,
    allocator: std.mem.Allocator,
    sent: bool,
};

const BatchReceiveContext = struct {
    interface: *ZeroCopyNetworkInterface,
    max_packets: u32,
    allocator: std.mem.Allocator,
    packets: std.ArrayList(PacketDescriptor),
};

const BatchSendContext = struct {
    interface: *ZeroCopyNetworkInterface,
    packets: []const PacketDescriptor,
    allocator: std.mem.Allocator,
    sent_count: u32,
};

// Poll functions for async operations
fn receivePacketPoll(context: *anyopaque, io: io_v2.Io) io_v2.Future.PollResult {
    _ = io;
    const ctx = @as(*ReceivePacketContext, @ptrCast(@alignCast(context)));
    
    if (ctx.interface.rx_ring.pop()) |packet| {
        ctx.packet = packet;
        return .{ .ready = packet };
    }
    
    return .{ .pending = {} };
}

fn receivePacketDeinit(context: *anyopaque, allocator: std.mem.Allocator) void {
    const ctx = @as(*ReceivePacketContext, @ptrCast(@alignCast(context)));
    allocator.destroy(ctx);
}

fn sendPacketPoll(context: *anyopaque, io: io_v2.Io) io_v2.Future.PollResult {
    _ = io;
    const ctx = @as(*SendPacketContext, @ptrCast(@alignCast(context)));
    
    if (ctx.interface.tx_ring.push(ctx.packet)) {
        ctx.sent = true;
        return .{ .ready = true };
    }
    
    return .{ .pending = {} };
}

fn sendPacketDeinit(context: *anyopaque, allocator: std.mem.Allocator) void {
    const ctx = @as(*SendPacketContext, @ptrCast(@alignCast(context)));
    allocator.destroy(ctx);
}

fn batchReceivePoll(context: *anyopaque, io: io_v2.Io) io_v2.Future.PollResult {
    _ = io;
    const ctx = @as(*BatchReceiveContext, @ptrCast(@alignCast(context)));
    
    var batch_packets: [64]PacketDescriptor = undefined;
    const count = ctx.interface.rx_ring.batchPop(batch_packets[0..@min(64, ctx.max_packets)]);
    
    if (count > 0) {
        for (batch_packets[0..count]) |packet| {
            ctx.packets.append(packet) catch break;
        }
        
        return .{ .ready = ctx.packets.items.len };
    }
    
    return .{ .pending = {} };
}

fn batchReceiveDeinit(context: *anyopaque, allocator: std.mem.Allocator) void {
    const ctx = @as(*BatchReceiveContext, @ptrCast(@alignCast(context)));
    ctx.packets.deinit();
    allocator.destroy(ctx);
}

fn batchSendPoll(context: *anyopaque, io: io_v2.Io) io_v2.Future.PollResult {
    _ = io;
    const ctx = @as(*BatchSendContext, @ptrCast(@alignCast(context)));
    
    for (ctx.packets[ctx.sent_count..]) |packet| {
        if (ctx.interface.tx_ring.push(packet)) {
            ctx.sent_count += 1;
        } else {
            break; // TX ring full
        }
    }
    
    if (ctx.sent_count >= ctx.packets.len) {
        return .{ .ready = ctx.sent_count };
    }
    
    return .{ .pending = {} };
}

fn batchSendDeinit(context: *anyopaque, allocator: std.mem.Allocator) void {
    const ctx = @as(*BatchSendContext, @ptrCast(@alignCast(context)));
    allocator.free(ctx.packets);
    allocator.destroy(ctx);
}

test "zero-copy memory pool" {
    const allocator = std.testing.allocator;
    
    var pool = try MemoryPool.init(allocator, 8192, 1024, false);
    defer pool.deinit();
    
    const block1 = pool.allocateBlock().?;
    const block2 = pool.allocateBlock().?;
    
    try std.testing.expect(block1.size == 1024);
    try std.testing.expect(block2.size == 1024);
    try std.testing.expect(block1.index != block2.index);
    
    pool.freeBlock(block1);
    
    const block3 = pool.allocateBlock().?;
    try std.testing.expect(block3.index == block1.index);
}

test "packet ring buffer" {
    const allocator = std.testing.allocator;
    
    var ring = try PacketRingBuffer.init(allocator, 8);
    defer ring.deinit(allocator);
    
    const packet = PacketDescriptor{
        .memory_block = MemoryBlock{ .addr = 0, .size = 1024, .index = 0, .in_use = true },
        .data_offset = 0,
        .data_length = 64,
        .packet_type = .ethernet,
        .timestamp = 12345,
        .metadata = PacketMetadata{},
    };
    
    try std.testing.expect(ring.push(packet));
    
    const popped = ring.pop().?;
    try std.testing.expect(popped.data_length == 64);
    try std.testing.expect(popped.timestamp == 12345);
}