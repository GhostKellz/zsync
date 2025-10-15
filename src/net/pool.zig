//! Zsync v0.6.0 - Connection Pool
//! Generic connection pool with health checks and auto-reconnect

const std = @import("std");
const sync_mod = @import("../sync.zig");

/// Connection pool configuration
pub const PoolConfig = struct {
    min_connections: u32 = 1,
    max_connections: u32 = 10,
    idle_timeout_ms: u64 = 30000, // 30 seconds
    connection_timeout_ms: u64 = 5000, // 5 seconds
    health_check_interval_ms: u64 = 60000, // 1 minute
};

/// Generic connection pool
pub fn ConnectionPool(comptime T: type) type {
    return struct {
        allocator: std.mem.Allocator,
        config: PoolConfig,
        connections: std.ArrayList(PooledConnection),
        available: sync_mod.Semaphore,
        mutex: std.Thread.Mutex,
        factory: *const fn (std.mem.Allocator) anyerror!T,
        destroyer: *const fn (T) void,
        health_check: ?*const fn (T) bool,

        const Self = @This();

        const PooledConnection = struct {
            connection: T,
            created_at: i64,
            last_used: i64,
            in_use: bool,
            healthy: bool,
        };

        /// Initialize connection pool
        pub fn init(
            allocator: std.mem.Allocator,
            config: PoolConfig,
            factory: *const fn (std.mem.Allocator) anyerror!T,
            destroyer: *const fn (T) void,
            health_check: ?*const fn (T) bool,
        ) !Self {
            var self = Self{
                .allocator = allocator,
                .config = config,
                .connections = std.ArrayList(PooledConnection).init(allocator),
                .available = sync_mod.Semaphore.init(config.max_connections),
                .mutex = .{},
                .factory = factory,
                .destroyer = destroyer,
                .health_check = health_check,
            };

            // Pre-create minimum connections
            try self.ensureMinConnections();

            return self;
        }

        pub fn deinit(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            for (self.connections.items) |conn| {
                self.destroyer(conn.connection);
            }
            self.connections.deinit();
        }

        /// Acquire a connection from the pool
        pub fn acquire(self: *Self) !T {
            self.available.acquire();
            errdefer self.available.release();

            self.mutex.lock();
            defer self.mutex.unlock();

            // Try to find available healthy connection
            for (self.connections.items) |*conn| {
                if (!conn.in_use and conn.healthy) {
                    // Check if still healthy
                    if (self.health_check) |check| {
                        if (!check(conn.connection)) {
                            conn.healthy = false;
                            continue;
                        }
                    }

                    conn.in_use = true;
                    conn.last_used = std.time.milliTimestamp();
                    return conn.connection;
                }
            }

            // Create new connection if below max
            if (self.connections.items.len < self.config.max_connections) {
                const conn = try self.factory(self.allocator);
                const now = std.time.milliTimestamp();

                try self.connections.append(PooledConnection{
                    .connection = conn,
                    .created_at = now,
                    .last_used = now,
                    .in_use = true,
                    .healthy = true,
                });

                return conn;
            }

            return error.NoConnectionsAvailable;
        }

        /// Release a connection back to the pool
        pub fn release(self: *Self, connection: T) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            for (self.connections.items) |*conn| {
                if (conn.connection == connection) {
                    conn.in_use = false;
                    conn.last_used = std.time.milliTimestamp();
                    self.available.release();
                    return;
                }
            }
        }

        /// Ensure minimum number of connections exist
        fn ensureMinConnections(self: *Self) !void {
            const now = std.time.milliTimestamp();

            while (self.connections.items.len < self.config.min_connections) {
                const conn = try self.factory(self.allocator);
                try self.connections.append(PooledConnection{
                    .connection = conn,
                    .created_at = now,
                    .last_used = now,
                    .in_use = false,
                    .healthy = true,
                });
            }
        }

        /// Clean up idle connections
        pub fn cleanupIdle(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            const now = std.time.milliTimestamp();
            const timeout = @as(i64, @intCast(self.config.idle_timeout_ms));

            var i: usize = 0;
            while (i < self.connections.items.len) {
                const conn = &self.connections.items[i];

                if (!conn.in_use and (now - conn.last_used > timeout)) {
                    // Remove idle connection
                    self.destroyer(conn.connection);
                    _ = self.connections.swapRemove(i);
                    continue;
                }

                i += 1;
            }
        }

        /// Get pool statistics
        pub fn getStats(self: *Self) PoolStats {
            self.mutex.lock();
            defer self.mutex.unlock();

            var in_use: u32 = 0;
            var healthy: u32 = 0;

            for (self.connections.items) |conn| {
                if (conn.in_use) in_use += 1;
                if (conn.healthy) healthy += 1;
            }

            return PoolStats{
                .total = @as(u32, @intCast(self.connections.items.len)),
                .in_use = in_use,
                .available = @as(u32, @intCast(self.connections.items.len)) - in_use,
                .healthy = healthy,
            };
        }
    };
}

/// Pool statistics
pub const PoolStats = struct {
    total: u32,
    in_use: u32,
    available: u32,
    healthy: u32,
};

// Tests
test "connection pool basic" {
    const testing = std.testing;

    // Mock connection type
    const MockConn = struct {
        id: u32,
    };

    // Wrapper to hold mutable state
    const TestState = struct {
        var next_id: u32 = 1;
    };

    const factory = struct {
        fn create(allocator: std.mem.Allocator) !MockConn {
            _ = allocator;
            const id = TestState.next_id;
            TestState.next_id += 1;
            return MockConn{ .id = id };
        }
    }.create;

    const destroyer = struct {
        fn destroy(conn: MockConn) void {
            _ = conn;
        }
    }.destroy;

    const config = PoolConfig{
        .min_connections = 2,
        .max_connections = 5,
    };

    var pool = try ConnectionPool(MockConn).init(
        testing.allocator,
        config,
        factory,
        destroyer,
        null,
    );
    defer pool.deinit();

    const stats = pool.getStats();
    try testing.expectEqual(2, stats.total); // min_connections created

    const conn1 = try pool.acquire();
    try testing.expect(conn1.id > 0);

    pool.release(conn1);

    const stats2 = pool.getStats();
    try testing.expectEqual(0, stats2.in_use);
}
