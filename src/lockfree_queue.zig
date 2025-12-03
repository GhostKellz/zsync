//! zsync - Lock-Free Task Queue Implementation
//! Based on Michael & Scott algorithm for lock-free queue
//! Provides high-performance concurrent access for thread pools

const std = @import("std");

/// Lock-free queue node
fn QueueNode(comptime T: type) type {
    return struct {
        data: ?T = null,
        next: std.atomic.Value(?*QueueNode(T)) = std.atomic.Value(?*QueueNode(T)).init(null),
        
        const Self = @This();
        
        fn init(data: ?T) Self {
            return Self{
                .data = data,
            };
        }
    };
}

/// Lock-free queue implementation using Michael & Scott algorithm
pub fn LockFreeQueue(comptime T: type) type {
    return struct {
        head: std.atomic.Value(?*Node),
        tail: std.atomic.Value(?*Node),
        allocator: std.mem.Allocator,
        size: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        
        const Self = @This();
        const Node = QueueNode(T);
        
        /// Initialize empty queue
        pub fn init(allocator: std.mem.Allocator) !Self {
            // Create dummy node
            const dummy = try allocator.create(Node);
            dummy.* = Node.init(null);
            
            return Self{
                .head = std.atomic.Value(?*Node).init(dummy),
                .tail = std.atomic.Value(?*Node).init(dummy),
                .allocator = allocator,
            };
        }
        
        /// Deinitialize queue and free all nodes
        pub fn deinit(self: *Self) void {
            // Drain all remaining items
            while (self.dequeue()) |_| {}
            
            // Free the dummy node
            if (self.head.load(.acquire)) |head| {
                self.allocator.destroy(head);
            }
        }
        
        /// Enqueue an item (producer operation)
        pub fn enqueue(self: *Self, data: T) !void {
            const new_node = try self.allocator.create(Node);
            new_node.* = Node.init(data);
            
            while (true) {
                const tail = self.tail.load(.acquire);
                const next = tail.?.next.load(.acquire);
                
                // Check if tail is still the last node
                if (tail == self.tail.load(.acquire)) {
                    if (next == null) {
                        // Try to link new node at the end of the list
                        if (tail.?.next.cmpxchgWeak(null, new_node, .acq_rel, .acquire) == null) {
                            // Enqueue is done, try to swing tail to the new node
                            _ = self.tail.cmpxchgWeak(tail, new_node, .acq_rel, .monotonic);
                            break;
                        }
                    } else {
                        // Try to swing tail to the next node
                        _ = self.tail.cmpxchgWeak(tail, next, .acq_rel, .monotonic);
                    }
                }
            }
            
            _ = self.size.fetchAdd(1, .acq_rel);
        }
        
        /// Dequeue an item (consumer operation)
        pub fn dequeue(self: *Self) ?T {
            while (true) {
                const head = self.head.load(.acquire);
                const tail = self.tail.load(.acquire);
                const next = head.?.next.load(.acquire);
                
                // Check if head is still the first node
                if (head == self.head.load(.acquire)) {
                    if (head == tail) {
                        if (next == null) {
                            // Queue is empty
                            return null;
                        }
                        // Try to swing tail to the next node
                        _ = self.tail.cmpxchgWeak(tail, next, .acq_rel, .monotonic);
                    } else {
                        if (next == null) {
                            // Inconsistent state, retry
                            continue;
                        }
                        
                        // Read data before potentially freeing the node
                        const data = next.?.data;
                        
                        // Try to swing head to the next node
                        if (self.head.cmpxchgWeak(head, next, .acq_rel, .acquire) == null) {
                            // Free the old dummy node
                            self.allocator.destroy(head.?);
                            _ = self.size.fetchSub(1, .acq_rel);
                            return data;
                        }
                    }
                }
            }
        }
        
        /// Get current queue size (approximate)
        pub fn count(self: *const Self) usize {
            return self.size.load(.acquire);
        }
        
        /// Check if queue is empty (approximate)
        pub fn isEmpty(self: *const Self) bool {
            return self.count() == 0;
        }
        
        /// Try to dequeue without blocking (returns null if empty)
        pub fn tryDequeue(self: *Self) ?T {
            return self.dequeue();
        }
    };
}

/// Work-stealing deque for better load balancing
/// Based on Chase-Lev algorithm
pub fn WorkStealingDeque(comptime T: type) type {
    return struct {
        buffer: []std.atomic.Value(T),
        mask: usize,
        top: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        bottom: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        allocator: std.mem.Allocator,
        
        const Self = @This();
        const INITIAL_SIZE = 256;
        
        /// Initialize work-stealing deque
        pub fn init(allocator: std.mem.Allocator) !Self {
            const buffer = try allocator.alloc(std.atomic.Value(T), INITIAL_SIZE);
            for (buffer) |*slot| {
                slot.* = std.atomic.Value(T).init(undefined);
            }
            
            return Self{
                .buffer = buffer,
                .mask = INITIAL_SIZE - 1,
                .allocator = allocator,
            };
        }
        
        /// Deinitialize deque
        pub fn deinit(self: *Self) void {
            self.allocator.free(self.buffer);
        }
        
        /// Push item to bottom (owner thread only)
        pub fn pushBottom(self: *Self, data: T) !void {
            const b = self.bottom.load(.acquire);
            const t = self.top.load(.acquire);
            
            // Check if we need to resize
            if (b - t >= self.buffer.len) {
                return error.DequeFull;
            }
            
            self.buffer[b & self.mask].store(data, .release);
            self.bottom.store(b + 1, .release);
        }
        
        /// Pop item from bottom (owner thread only)
        pub fn popBottom(self: *Self) ?T {
            const b = self.bottom.load(.acquire);
            if (b == 0) return null;
            
            const new_b = b - 1;
            self.bottom.store(new_b, .release);
            
            const t = self.top.load(.acquire);
            if (new_b < t) {
                // Deque is empty
                self.bottom.store(b, .release);
                return null;
            }
            
            const data = self.buffer[new_b & self.mask].load(.acquire);
            if (new_b > t) {
                // More than one element
                return data;
            }
            
            // Last element, might race with steal
            if (self.top.cmpxchgWeak(t, t + 1, .acq_rel, .monotonic) != null) {
                // Lost race to stealer
                self.bottom.store(b, .release);
                return null;
            }
            
            self.bottom.store(b, .release);
            return data;
        }
        
        /// Steal item from top (worker threads)
        pub fn steal(self: *Self) ?T {
            const t = self.top.load(.acquire);
            const b = self.bottom.load(.acquire);
            
            if (t >= b) {
                // Deque is empty
                return null;
            }
            
            const data = self.buffer[t & self.mask].load(.acquire);
            
            if (self.top.cmpxchgWeak(t, t + 1, .acq_rel, .monotonic) != null) {
                // Lost race
                return null;
            }
            
            return data;
        }
        
        /// Get approximate size
        pub fn count(self: *const Self) usize {
            const b = self.bottom.load(.acquire);
            const t = self.top.load(.acquire);
            return if (b >= t) b - t else 0;
        }
        
        /// Check if deque is empty
        pub fn isEmpty(self: *const Self) bool {
            return self.count() == 0;
        }
    };
}

/// High-performance MPMC (Multi-Producer Multi-Consumer) queue
/// Uses a ring buffer with atomic operations
pub fn MPMCQueue(comptime T: type) type {
    return struct {
        buffer: []Cell,
        mask: usize,
        enqueue_pos: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        dequeue_pos: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        allocator: std.mem.Allocator,
        
        const Self = @This();
        const Cell = struct {
            sequence: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
            data: T = undefined,
        };
        
        /// Initialize MPMC queue with given capacity (must be power of 2)
        pub fn init(allocator: std.mem.Allocator, cap: usize) !Self {
            if (cap == 0 or (cap & (cap - 1)) != 0) {
                return error.InvalidCapacity; // Must be power of 2
            }
            
            const buffer = try allocator.alloc(Cell, cap);
            for (buffer, 0..) |*cell, i| {
                cell.sequence = std.atomic.Value(usize).init(i);
            }
            
            return Self{
                .buffer = buffer,
                .mask = cap - 1,
                .allocator = allocator,
            };
        }
        
        /// Deinitialize queue
        pub fn deinit(self: *Self) void {
            self.allocator.free(self.buffer);
        }
        
        /// Enqueue item (blocking)
        pub fn enqueue(self: *Self, data: T) !void {
            var pos = self.enqueue_pos.load(.monotonic);
            
            while (true) {
                const cell = &self.buffer[pos & self.mask];
                const seq = cell.sequence.load(.acquire);
                const diff = @as(isize, @bitCast(seq)) - @as(isize, @bitCast(pos));
                
                if (diff == 0) {
                    if (self.enqueue_pos.cmpxchgWeak(pos, pos + 1, .acq_rel, .monotonic) == null) {
                        cell.data = data;
                        cell.sequence.store(pos + 1, .release);
                        return;
                    }
                } else if (diff < 0) {
                    return error.QueueFull;
                } else {
                    pos = self.enqueue_pos.load(.monotonic);
                }
            }
        }
        
        /// Try to enqueue item (non-blocking)
        pub fn tryEnqueue(self: *Self, data: T) bool {
            self.enqueue(data) catch return false;
            return true;
        }
        
        /// Dequeue item (blocking)
        pub fn dequeue(self: *Self) ?T {
            var pos = self.dequeue_pos.load(.monotonic);
            
            while (true) {
                const cell = &self.buffer[pos & self.mask];
                const seq = cell.sequence.load(.acquire);
                const diff = @as(isize, @bitCast(seq)) - @as(isize, @bitCast(pos + 1));
                
                if (diff == 0) {
                    if (self.dequeue_pos.cmpxchgWeak(pos, pos + 1, .acq_rel, .monotonic) == null) {
                        const data = cell.data;
                        cell.sequence.store(pos + self.mask + 1, .release);
                        return data;
                    }
                } else if (diff < 0) {
                    return null; // Queue empty
                } else {
                    pos = self.dequeue_pos.load(.monotonic);
                }
            }
        }
        
        /// Try to dequeue item (non-blocking)
        pub fn tryDequeue(self: *Self) ?T {
            return self.dequeue();
        }
        
        /// Get approximate queue size
        pub fn count(self: *const Self) usize {
            const enq = self.enqueue_pos.load(.monotonic);
            const deq = self.dequeue_pos.load(.monotonic);
            return enq - deq;
        }
        
        /// Check if queue is empty
        pub fn isEmpty(self: *const Self) bool {
            return self.count() == 0;
        }
        
        /// Get queue capacity
        pub fn capacity(self: *const Self) usize {
            return self.buffer.len;
        }
    };
}

test "lock-free queue basic operations" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var queue = try LockFreeQueue(i32).init(allocator);
    defer queue.deinit();
    
    // Test enqueue/dequeue
    try queue.enqueue(1);
    try queue.enqueue(2);
    try queue.enqueue(3);
    
    try std.testing.expectEqual(@as(usize, 3), queue.count());
    try std.testing.expectEqual(@as(i32, 1), queue.dequeue().?);
    try std.testing.expectEqual(@as(i32, 2), queue.dequeue().?);
    try std.testing.expectEqual(@as(i32, 3), queue.dequeue().?);
    try std.testing.expect(queue.dequeue() == null);
}

test "MPMC queue basic operations" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var queue = try MPMCQueue(i32).init(allocator, 8);
    defer queue.deinit();
    
    // Test enqueue/dequeue
    try queue.enqueue(1);
    try queue.enqueue(2);
    
    try std.testing.expectEqual(@as(i32, 1), queue.dequeue().?);
    try std.testing.expectEqual(@as(i32, 2), queue.dequeue().?);
    try std.testing.expect(queue.dequeue() == null);
}

test "work stealing deque operations" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var deque = try WorkStealingDeque(i32).init(allocator);
    defer deque.deinit();
    
    // Test push/pop from bottom
    try deque.pushBottom(1);
    try deque.pushBottom(2);
    
    try std.testing.expectEqual(@as(i32, 2), deque.popBottom().?);
    try std.testing.expectEqual(@as(i32, 1), deque.steal().?);
    try std.testing.expect(deque.popBottom() == null);
}