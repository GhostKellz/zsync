const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const HashMap = std.HashMap;
const net = std.net;
const testing = std.testing;
const io = @import("io_v2.zig");

pub const DnsError = error{
    InvalidQuery,
    ResolverTimeout,
    NetworkError,
    InvalidResponse,
    CacheError,
    ServerError,
    OutOfMemory,
};

pub const RecordType = enum(u16) {
    A = 1,
    AAAA = 28,
    CNAME = 5,
    MX = 15,
    TXT = 16,
    NS = 2,
    PTR = 12,
    SOA = 6,
    SRV = 33,
};

pub const DnsRecord = struct {
    name: []const u8,
    record_type: RecordType,
    ttl: u32,
    data: []const u8,
    
    pub fn deinit(self: *DnsRecord, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.data);
    }
};

pub const DnsResponse = struct {
    records: ArrayList(DnsRecord),
    authority_records: ArrayList(DnsRecord),
    additional_records: ArrayList(DnsRecord),
    rcode: u8,
    
    pub fn init(allocator: Allocator) DnsResponse {
        return DnsResponse{
            .records = ArrayList(DnsRecord).init(allocator),
            .authority_records = ArrayList(DnsRecord).init(allocator),
            .additional_records = ArrayList(DnsRecord).init(allocator),
            .rcode = 0,
        };
    }
    
    pub fn deinit(self: *DnsResponse) void {
        for (self.records.items) |*record| {
            record.deinit(self.records.allocator);
        }
        self.records.deinit();
        
        for (self.authority_records.items) |*record| {
            record.deinit(self.authority_records.allocator);
        }
        self.authority_records.deinit();
        
        for (self.additional_records.items) |*record| {
            record.deinit(self.additional_records.allocator);
        }
        self.additional_records.deinit();
    }
};

const CacheEntry = struct {
    response: DnsResponse,
    expires_at: i64,
    access_count: u64,
    
    pub fn isExpired(self: *const CacheEntry, now: i64) bool {
        return now >= self.expires_at;
    }
};

const CacheMap = HashMap([]const u8, CacheEntry, std.hash_map.StringContext, std.hash_map.default_max_load_percentage);

pub const AsyncDnsResolver = struct {
    allocator: Allocator,
    cache: CacheMap,
    cache_mutex: std.Thread.Mutex,
    servers: ArrayList(net.Address),
    timeout_ms: u64,
    max_cache_entries: usize,
    use_ipv6: bool,
    
    const Self = @This();
    
    pub fn init(allocator: Allocator) Self {
        return Self{
            .allocator = allocator,
            .cache = CacheMap.init(allocator),
            .cache_mutex = std.Thread.Mutex{},
            .servers = ArrayList(net.Address).init(allocator),
            .timeout_ms = 5000,
            .max_cache_entries = 10000,
            .use_ipv6 = true,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.cache_mutex.lock();
        defer self.cache_mutex.unlock();
        
        var iterator = self.cache.iterator();
        while (iterator.next()) |entry| {
            entry.value_ptr.response.deinit();
            self.allocator.free(entry.key_ptr.*);
        }
        self.cache.deinit();
        self.servers.deinit();
    }
    
    pub fn addServer(self: *Self, address: net.Address) !void {
        try self.servers.append(address);
    }
    
    pub fn addDefaultServers(self: *Self) !void {
        // Cloudflare DNS (IPv4 and IPv6)
        try self.addServer(net.Address.parseIp4("1.1.1.1", 53) catch unreachable);
        try self.addServer(net.Address.parseIp4("1.0.0.1", 53) catch unreachable);
        
        if (self.use_ipv6) {
            try self.addServer(net.Address.parseIp6("2606:4700:4700::1111", 53) catch unreachable);
            try self.addServer(net.Address.parseIp6("2606:4700:4700::1001", 53) catch unreachable);
        }
        
        // Google DNS (IPv4 and IPv6)
        try self.addServer(net.Address.parseIp4("8.8.8.8", 53) catch unreachable);
        try self.addServer(net.Address.parseIp4("8.8.4.4", 53) catch unreachable);
        
        if (self.use_ipv6) {
            try self.addServer(net.Address.parseIp6("2001:4860:4860::8888", 53) catch unreachable);
            try self.addServer(net.Address.parseIp6("2001:4860:4860::8844", 53) catch unreachable);
        }
        
        // Quad9 DNS (IPv4 and IPv6)
        try self.addServer(net.Address.parseIp4("9.9.9.9", 53) catch unreachable);
        
        if (self.use_ipv6) {
            try self.addServer(net.Address.parseIp6("2620:fe::fe", 53) catch unreachable);
        }
    }
    
    fn getCacheKey(self: *Self, hostname: []const u8, record_type: RecordType) ![]u8 {
        return try std.fmt.allocPrint(self.allocator, "{s}:{d}", .{ hostname, @intFromEnum(record_type) });
    }
    
    fn getCachedResponse(self: *Self, cache_key: []const u8) ?DnsResponse {
        self.cache_mutex.lock();
        defer self.cache_mutex.unlock();
        
        const now = std.time.timestamp();
        
        if (self.cache.get(cache_key)) |entry| {
            if (!entry.isExpired(now)) {
                // Clone the response for return
                var cloned_response = DnsResponse.init(self.allocator);
                
                for (entry.response.records.items) |record| {
                    const cloned_record = DnsRecord{
                        .name = self.allocator.dupe(u8, record.name) catch return null,
                        .record_type = record.record_type,
                        .ttl = record.ttl,
                        .data = self.allocator.dupe(u8, record.data) catch return null,
                    };
                    cloned_response.records.append(cloned_record) catch return null;
                }
                
                cloned_response.rcode = entry.response.rcode;
                return cloned_response;
            } else {
                // Remove expired entry
                var mutable_entry = self.cache.fetchRemove(cache_key);
                if (mutable_entry) |removed| {
                    removed.value.response.deinit();
                    self.allocator.free(removed.key);
                }
            }
        }
        
        return null;
    }
    
    fn cacheResponse(self: *Self, cache_key: []const u8, response: DnsResponse, ttl: u32) !void {
        self.cache_mutex.lock();
        defer self.cache_mutex.unlock();
        
        // Check cache size and evict if necessary
        if (self.cache.count() >= self.max_cache_entries) {
            try self.evictOldestEntry();
        }
        
        const now = std.time.timestamp();
        const expires_at = now + @as(i64, ttl);
        
        const owned_key = try self.allocator.dupe(u8, cache_key);
        
        // Clone response for caching
        var cached_response = DnsResponse.init(self.allocator);
        
        for (response.records.items) |record| {
            const cloned_record = DnsRecord{
                .name = try self.allocator.dupe(u8, record.name),
                .record_type = record.record_type,
                .ttl = record.ttl,
                .data = try self.allocator.dupe(u8, record.data),
            };
            try cached_response.records.append(cloned_record);
        }
        
        cached_response.rcode = response.rcode;
        
        const cache_entry = CacheEntry{
            .response = cached_response,
            .expires_at = expires_at,
            .access_count = 1,
        };
        
        try self.cache.put(owned_key, cache_entry);
    }
    
    fn evictOldestEntry(self: *Self) !void {
        var oldest_key: ?[]const u8 = null;
        var oldest_expires: i64 = std.math.maxInt(i64);
        
        var iterator = self.cache.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.expires_at < oldest_expires) {
                oldest_expires = entry.value_ptr.expires_at;
                oldest_key = entry.key_ptr.*;
            }
        }
        
        if (oldest_key) |key| {
            var removed = self.cache.fetchRemove(key);
            if (removed) |entry| {
                entry.value.response.deinit();
                self.allocator.free(entry.key);
            }
        }
    }
    
    fn buildDnsQuery(self: *Self, hostname: []const u8, record_type: RecordType, buffer: []u8) !usize {
        var offset: usize = 0;
        
        // DNS Header (12 bytes)
        const transaction_id: u16 = @truncate(std.crypto.random.int(u32));
        std.mem.writeInt(u16, buffer[offset..offset + 2], transaction_id, .big);
        offset += 2;
        
        // Flags: standard query
        std.mem.writeInt(u16, buffer[offset..offset + 2], 0x0100, .big);
        offset += 2;
        
        // Question count
        std.mem.writeInt(u16, buffer[offset..offset + 2], 1, .big);
        offset += 2;
        
        // Answer count
        std.mem.writeInt(u16, buffer[offset..offset + 2], 0, .big);
        offset += 2;
        
        // Authority count
        std.mem.writeInt(u16, buffer[offset..offset + 2], 0, .big);
        offset += 2;
        
        // Additional count
        std.mem.writeInt(u16, buffer[offset..offset + 2], 0, .big);
        offset += 2;
        
        // Question section
        // Encode hostname as labels
        var part_start: usize = 0;
        for (hostname, 0..) |char, i| {
            if (char == '.' or i == hostname.len - 1) {
                const part_end = if (char == '.') i else i + 1;
                const part_len = part_end - part_start;
                
                if (part_len > 63) return DnsError.InvalidQuery;
                
                buffer[offset] = @truncate(part_len);
                offset += 1;
                
                @memcpy(buffer[offset..offset + part_len], hostname[part_start..part_end]);
                offset += part_len;
                
                part_start = i + 1;
            }
        }
        
        // Null terminator for hostname
        buffer[offset] = 0;
        offset += 1;
        
        // Query type
        std.mem.writeInt(u16, buffer[offset..offset + 2], @intFromEnum(record_type), .big);
        offset += 2;
        
        // Query class (IN = 1)
        std.mem.writeInt(u16, buffer[offset..offset + 2], 1, .big);
        offset += 2;
        
        return offset;
    }
    
    fn parseDnsResponse(self: *Self, buffer: []const u8) !DnsResponse {
        if (buffer.len < 12) return DnsError.InvalidResponse;
        
        var response = DnsResponse.init(self.allocator);
        var offset: usize = 0;
        
        // Parse header
        offset += 2; // Transaction ID
        
        const flags = std.mem.readInt(u16, buffer[offset..offset + 2], .big);
        offset += 2;
        
        response.rcode = @truncate(flags & 0x000F);
        
        const question_count = std.mem.readInt(u16, buffer[offset..offset + 2], .big);
        offset += 2;
        
        const answer_count = std.mem.readInt(u16, buffer[offset..offset + 2], .big);
        offset += 2;
        
        const authority_count = std.mem.readInt(u16, buffer[offset..offset + 2], .big);
        offset += 2;
        
        const additional_count = std.mem.readInt(u16, buffer[offset..offset + 2], .big);
        offset += 2;
        
        // Skip questions
        for (0..question_count) |_| {
            offset = try self.skipDnsName(buffer, offset);
            offset += 4; // Type and Class
        }
        
        // Parse answer records
        for (0..answer_count) |_| {
            const record = try self.parseDnsRecord(buffer, &offset);
            try response.records.append(record);
        }
        
        // Parse authority records
        for (0..authority_count) |_| {
            const record = try self.parseDnsRecord(buffer, &offset);
            try response.authority_records.append(record);
        }
        
        // Parse additional records
        for (0..additional_count) |_| {
            const record = try self.parseDnsRecord(buffer, &offset);
            try response.additional_records.append(record);
        }
        
        return response;
    }
    
    fn skipDnsName(self: *Self, buffer: []const u8, start_offset: usize) !usize {
        _ = self;
        var offset = start_offset;
        
        while (offset < buffer.len) {
            const len = buffer[offset];
            
            if (len == 0) {
                return offset + 1;
            } else if (len >= 0xC0) {
                // Compression pointer
                return offset + 2;
            } else {
                offset += 1 + len;
            }
        }
        
        return DnsError.InvalidResponse;
    }
    
    fn parseDnsRecord(self: *Self, buffer: []const u8, offset: *usize) !DnsRecord {
        const name = try self.parseDnsName(buffer, offset);
        
        if (offset.* + 10 > buffer.len) return DnsError.InvalidResponse;
        
        const record_type_raw = std.mem.readInt(u16, buffer[offset.*..offset.* + 2], .big);
        offset.* += 2;
        
        const record_type = @as(RecordType, @enumFromInt(record_type_raw));
        
        offset.* += 2; // Skip class
        
        const ttl = std.mem.readInt(u32, buffer[offset.*..offset.* + 4], .big);
        offset.* += 4;
        
        const data_len = std.mem.readInt(u16, buffer[offset.*..offset.* + 2], .big);
        offset.* += 2;
        
        if (offset.* + data_len > buffer.len) return DnsError.InvalidResponse;
        
        const data = try self.allocator.dupe(u8, buffer[offset.*..offset.* + data_len]);
        offset.* += data_len;
        
        return DnsRecord{
            .name = name,
            .record_type = record_type,
            .ttl = ttl,
            .data = data,
        };
    }
    
    fn parseDnsName(self: *Self, buffer: []const u8, offset: *usize) ![]u8 {
        var name_parts = ArrayList([]const u8).init(self.allocator);
        defer name_parts.deinit();
        
        var current_offset = offset.*;
        var jumped = false;
        
        while (current_offset < buffer.len) {
            const len = buffer[current_offset];
            
            if (len == 0) {
                if (!jumped) offset.* = current_offset + 1;
                break;
            } else if (len >= 0xC0) {
                // Compression pointer
                if (!jumped) offset.* = current_offset + 2;
                
                const pointer = ((len & 0x3F) << 8) | buffer[current_offset + 1];
                current_offset = pointer;
                jumped = true;
            } else {
                current_offset += 1;
                if (current_offset + len > buffer.len) return DnsError.InvalidResponse;
                
                const part = buffer[current_offset..current_offset + len];
                try name_parts.append(part);
                current_offset += len;
            }
        }
        
        // Join name parts with dots
        var total_len: usize = 0;
        for (name_parts.items) |part| {
            total_len += part.len;
        }
        if (name_parts.items.len > 0) {
            total_len += name_parts.items.len - 1; // For dots
        }
        
        const name = try self.allocator.alloc(u8, total_len);
        var name_offset: usize = 0;
        
        for (name_parts.items, 0..) |part, i| {
            if (i > 0) {
                name[name_offset] = '.';
                name_offset += 1;
            }
            @memcpy(name[name_offset..name_offset + part.len], part);
            name_offset += part.len;
        }
        
        return name;
    }
    
    pub fn resolveAsync(self: *Self, io_context: *io.Io, hostname: []const u8, record_type: RecordType) !DnsResponse {
        const cache_key = try self.getCacheKey(hostname, record_type);
        defer self.allocator.free(cache_key);
        
        // Check cache first
        if (self.getCachedResponse(cache_key)) |cached_response| {
            return cached_response;
        }
        
        // Prepare query
        var query_buffer: [512]u8 = undefined;
        const query_len = try self.buildDnsQuery(hostname, record_type, &query_buffer);
        
        // Try each DNS server asynchronously
        var last_error: DnsError = DnsError.NetworkError;
        
        for (self.servers.items) |server_addr| {
            const result = self.queryServerAsync(io_context, server_addr, query_buffer[0..query_len]) catch |err| {
                last_error = switch (err) {
                    error.ConnectionRefused, error.NetworkUnreachable => DnsError.NetworkError,
                    error.Timeout => DnsError.ResolverTimeout,
                    else => DnsError.ServerError,
                };
                continue;
            };
            
            const response = self.parseDnsResponse(result) catch |err| {
                last_error = switch (err) {
                    error.InvalidResponse => DnsError.InvalidResponse,
                    else => DnsError.ServerError,
                };
                continue;
            };
            
            // Cache successful response
            if (response.rcode == 0 and response.records.items.len > 0) {
                const min_ttl = blk: {
                    var min: u32 = std.math.maxInt(u32);
                    for (response.records.items) |record| {
                        min = @min(min, record.ttl);
                    }
                    break :blk min;
                };
                
                self.cacheResponse(cache_key, response, min_ttl) catch {};
            }
            
            return response;
        }
        
        return last_error;
    }
    
    fn queryServerAsync(self: *Self, io_context: *io.Io, server_addr: net.Address, query: []const u8) ![]u8 {
        const socket = try io_context.socket(server_addr.any.family, std.posix.SOCK.DGRAM, 0);
        defer io_context.close(socket) catch {};
        
        // Set timeout
        const timeout = std.posix.timeval{
            .tv_sec = @intCast(self.timeout_ms / 1000),
            .tv_usec = @intCast((self.timeout_ms % 1000) * 1000),
        };
        
        try std.posix.setsockopt(socket, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout));
        try std.posix.setsockopt(socket, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&timeout));
        
        // Send query
        _ = try io_context.sendto(socket, query, 0, &server_addr.any, server_addr.getOsSockLen());
        
        // Receive response
        var response_buffer: [4096]u8 = undefined;
        var from_addr: std.posix.sockaddr = undefined;
        var from_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);
        
        const bytes_received = try io_context.recvfrom(socket, &response_buffer, 0, &from_addr, &from_len);
        
        return try self.allocator.dupe(u8, response_buffer[0..bytes_received]);
    }
    
    // IPv6-specific resolution methods
    pub fn resolveIPv6Async(self: *Self, io_context: *io.Io, hostname: []const u8) !DnsResponse {
        return self.resolveAsync(io_context, hostname, RecordType.AAAA);
    }
    
    pub fn resolveIPv4Async(self: *Self, io_context: *io.Io, hostname: []const u8) !DnsResponse {
        return self.resolveAsync(io_context, hostname, RecordType.A);
    }
    
    pub fn resolveBothAsync(self: *Self, io_context: *io.Io, hostname: []const u8) !struct { ipv4: ?DnsResponse, ipv6: ?DnsResponse } {
        var ipv4_result: ?DnsResponse = null;
        var ipv6_result: ?DnsResponse = null;
        
        // Try IPv4 resolution
        ipv4_result = self.resolveIPv4Async(io_context, hostname) catch null;
        
        // Try IPv6 resolution if enabled
        if (self.use_ipv6) {
            ipv6_result = self.resolveIPv6Async(io_context, hostname) catch null;
        }
        
        return .{ .ipv4 = ipv4_result, .ipv6 = ipv6_result };
    }
    
    // Decentralized DNS support placeholders
    pub fn enableDecentralizedResolvers(self: *Self) !void {
        // Add decentralized DNS resolvers (ENS, Handshake, etc.)
        // This is a placeholder for future ENS integration
        _ = self;
    }
    
    pub fn resolveDecentralizedAsync(self: *Self, io_context: *io.Io, domain: []const u8) !DnsResponse {
        // Placeholder for decentralized DNS resolution
        // Will integrate with ENS compatibility layer
        _ = io_context;
        _ = domain;
        return self.resolveAsync(io_context, domain, RecordType.A);
    }
};

// Example usage and testing
test "DNS async resolver IPv4" {
    var resolver = AsyncDnsResolver.init(testing.allocator);
    defer resolver.deinit();
    
    try resolver.addDefaultServers();
    
    // This would require a real I/O context in practice
    // const response = try resolver.resolveIPv4Async(&io_context, "example.com");
    // defer response.deinit();
}

test "DNS async resolver IPv6" {
    var resolver = AsyncDnsResolver.init(testing.allocator);
    defer resolver.deinit();
    
    try resolver.addDefaultServers();
    
    // This would require a real I/O context in practice
    // const response = try resolver.resolveIPv6Async(&io_context, "example.com");
    // defer response.deinit();
}

test "DNS cache functionality" {
    var resolver = AsyncDnsResolver.init(testing.allocator);
    defer resolver.deinit();
    
    const cache_key = try resolver.getCacheKey("example.com", RecordType.A);
    defer testing.allocator.free(cache_key);
    
    // Test cache miss
    const cached_response = resolver.getCachedResponse(cache_key);
    try testing.expect(cached_response == null);
}