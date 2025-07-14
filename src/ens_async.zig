const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const HashMap = std.HashMap;
const net = std.net;
const testing = std.testing;
const io = @import("io_v2.zig");
const dns_async = @import("dns_async.zig");
const crypto_async = @import("crypto_async.zig");

pub const EnsError = error{
    InvalidName,
    ResolverNotFound,
    ChainError,
    ContractError,
    NetworkError,
    DecodeError,
    InvalidAddress,
    OutOfMemory,
};

pub const EnsRecordType = enum {
    address,
    content_hash,
    text_record,
    public_key,
    interface_id,
    name,
    abi,
    addr_multicoin,
};

pub const EnsRecord = struct {
    record_type: EnsRecordType,
    key: []const u8,
    value: []const u8,
    
    pub fn deinit(self: *EnsRecord, allocator: Allocator) void {
        allocator.free(self.key);
        allocator.free(self.value);
    }
};

pub const EnsResolver = struct {
    address: [20]u8,
    supports_interface: HashMap(u32, bool, std.hash_map.AutoContext(u32), std.hash_map.default_max_load_percentage),
    
    pub fn init(allocator: Allocator, address: [20]u8) EnsResolver {
        return EnsResolver{
            .address = address,
            .supports_interface = HashMap(u32, bool, std.hash_map.AutoContext(u32), std.hash_map.default_max_load_percentage).init(allocator),
        };
    }
    
    pub fn deinit(self: *EnsResolver) void {
        self.supports_interface.deinit();
    }
};

pub const AsyncEnsClient = struct {
    allocator: Allocator,
    dns_resolver: *dns_async.AsyncDnsResolver,
    ethereum_rpc_endpoints: ArrayList([]const u8),
    contract_abi_cache: HashMap([]const u8, []const u8, std.hash_map.StringContext, std.hash_map.default_max_load_percentage),
    resolver_cache: HashMap([]const u8, EnsResolver, std.hash_map.StringContext, std.hash_map.default_max_load_percentage),
    cache_mutex: std.Thread.Mutex,
    
    // ENS contract addresses
    ens_registry_address: [20]u8,
    public_resolver_address: [20]u8,
    reverse_registrar_address: [20]u8,
    
    const Self = @This();
    
    // Standard ENS interface IDs
    const ADDR_INTERFACE_ID: u32 = 0x3b3b57de;
    const NAME_INTERFACE_ID: u32 = 0x691f3431;
    const ABI_INTERFACE_ID: u32 = 0x2203ab56;
    const PUBKEY_INTERFACE_ID: u32 = 0xc8690233;
    const TEXT_INTERFACE_ID: u32 = 0x59d1d43c;
    const CONTENTHASH_INTERFACE_ID: u32 = 0xbc1c58d1;
    const MULTICOIN_ADDR_INTERFACE_ID: u32 = 0xf1cb7e06;
    
    pub fn init(allocator: Allocator, dns_resolver: *dns_async.AsyncDnsResolver) Self {
        return Self{
            .allocator = allocator,
            .dns_resolver = dns_resolver,
            .ethereum_rpc_endpoints = ArrayList([]const u8).init(allocator),
            .contract_abi_cache = HashMap([]const u8, []const u8, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator),
            .resolver_cache = HashMap([]const u8, EnsResolver, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator),
            .cache_mutex = std.Thread.Mutex{},
            
            // Mainnet ENS contract addresses
            .ens_registry_address = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x31, 0x4e, 0x59, 0x73, 0x45, 0x42, 0x31, 0xeB },
            .public_resolver_address = [_]u8{ 0x23, 0x1b, 0x0E, 0xe1, 0x4f, 0x68, 0x84, 0x80, 0x01, 0x86, 0x73, 0x7c, 0x0A, 0x7E, 0x1E, 0x3f, 0x78, 0xCd, 0xB2, 0xCa },
            .reverse_registrar_address = [_]u8{ 0x08, 0x4b, 0x1c, 0x3C, 0x81, 0x54, 0x53, 0x56, 0x94, 0x81, 0x2E, 0x73, 0x78, 0xc5, 0x73, 0x82, 0x67, 0x11, 0x9C, 0x52 },
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.cache_mutex.lock();
        defer self.cache_mutex.unlock();
        
        var contract_iterator = self.contract_abi_cache.iterator();
        while (contract_iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.contract_abi_cache.deinit();
        
        var resolver_iterator = self.resolver_cache.iterator();
        while (resolver_iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.resolver_cache.deinit();
        
        for (self.ethereum_rpc_endpoints.items) |endpoint| {
            self.allocator.free(endpoint);
        }
        self.ethereum_rpc_endpoints.deinit();
    }
    
    pub fn addRpcEndpoint(self: *Self, endpoint: []const u8) !void {
        const owned_endpoint = try self.allocator.dupe(u8, endpoint);
        try self.ethereum_rpc_endpoints.append(owned_endpoint);
    }
    
    pub fn addDefaultRpcEndpoints(self: *Self) !void {
        // Add popular Ethereum RPC endpoints
        try self.addRpcEndpoint("https://mainnet.infura.io/v3/");
        try self.addRpcEndpoint("https://eth-mainnet.alchemyapi.io/v2/");
        try self.addRpcEndpoint("https://cloudflare-eth.com");
        try self.addRpcEndpoint("https://rpc.ankr.com/eth");
        try self.addRpcEndpoint("https://ethereum.publicnode.com");
    }
    
    fn normalizeEnsName(self: *Self, name: []const u8) ![]u8 {
        // Convert to lowercase and validate ENS name format
        var normalized = try self.allocator.alloc(u8, name.len);
        
        for (name, 0..) |char, i| {
            if (char >= 'A' and char <= 'Z') {
                normalized[i] = char + 32; // Convert to lowercase
            } else if ((char >= 'a' and char <= 'z') or (char >= '0' and char <= '9') or char == '.' or char == '-') {
                normalized[i] = char;
            } else {
                self.allocator.free(normalized);
                return EnsError.InvalidName;
            }
        }
        
        // Validate ENS name ends with .eth or other valid TLD
        if (!std.mem.endsWith(u8, normalized, ".eth") and
            !std.mem.endsWith(u8, normalized, ".xyz") and
            !std.mem.endsWith(u8, normalized, ".luxe") and
            !std.mem.endsWith(u8, normalized, ".kred") and
            !std.mem.endsWith(u8, normalized, ".addr.reverse"))
        {
            self.allocator.free(normalized);
            return EnsError.InvalidName;
        }
        
        return normalized;
    }
    
    fn namehash(self: *Self, name: []const u8) ![32]u8 {
        var node = [_]u8{0} ** 32;
        
        if (name.len == 0) return node;
        
        var labels = std.mem.split(u8, name, ".");
        var label_stack = ArrayList([]const u8).init(self.allocator);
        defer label_stack.deinit();
        
        // Collect labels in reverse order
        while (labels.next()) |label| {
            try label_stack.append(label);
        }
        
        // Process labels from TLD to subdomain
        var i = label_stack.items.len;
        while (i > 0) {
            i -= 1;
            const label = label_stack.items[i];
            
            // Hash the label
            var label_hash: [32]u8 = undefined;
            var hasher = std.crypto.hash.sha3.Keccak256.init(.{});
            hasher.update(label);
            hasher.final(&label_hash);
            
            // Hash the current node + label hash
            var combined_hasher = std.crypto.hash.sha3.Keccak256.init(.{});
            combined_hasher.update(&node);
            combined_hasher.update(&label_hash);
            combined_hasher.final(&node);
        }
        
        return node;
    }
    
    fn buildEthereumCall(self: *Self, to: [20]u8, data: []const u8, buffer: []u8) ![]u8 {
        // Build JSON-RPC call for eth_call
        const call_data = try std.fmt.allocPrint(self.allocator, 
            \\{{"jsonrpc":"2.0","method":"eth_call","params":[{{"to":"0x{x}","data":"0x{s}"}}, "latest"],"id":1}}
        , .{ std.fmt.fmtSliceHexLower(&to), std.fmt.fmtSliceHexLower(data) });
        
        defer self.allocator.free(call_data);
        
        if (call_data.len > buffer.len) return EnsError.OutOfMemory;
        @memcpy(buffer[0..call_data.len], call_data);
        
        return buffer[0..call_data.len];
    }
    
    fn executeEthereumCallAsync(self: *Self, io_context: *io.Io, call_data: []const u8) ![]u8 {
        // Try each RPC endpoint
        var last_error: EnsError = EnsError.NetworkError;
        
        for (self.ethereum_rpc_endpoints.items) |endpoint| {
            const result = self.makeHttpPostAsync(io_context, endpoint, call_data) catch |err| {
                last_error = switch (err) {
                    error.ConnectionRefused, error.NetworkUnreachable => EnsError.NetworkError,
                    else => EnsError.ChainError,
                };
                continue;
            };
            
            return result;
        }
        
        return last_error;
    }
    
    fn makeHttpPostAsync(self: *Self, io_context: *io.Io, endpoint: []const u8, data: []const u8) ![]u8 {
        // Parse endpoint URL
        var url_parts = std.mem.split(u8, endpoint, "://");
        _ = url_parts.next() orelse return EnsError.NetworkError; // protocol
        const host_and_path = url_parts.next() orelse return EnsError.NetworkError;
        
        var host_path_split = std.mem.split(u8, host_and_path, "/");
        const host = host_path_split.next() orelse return EnsError.NetworkError;
        
        // Resolve host to IP
        const dns_response = try self.dns_resolver.resolveAsync(io_context, host, dns_async.RecordType.A);
        defer dns_response.deinit();
        
        if (dns_response.records.items.len == 0) return EnsError.NetworkError;
        
        // Connect to server
        const addr = net.Address.parseIp4(dns_response.records.items[0].data, 443) catch return EnsError.NetworkError;
        const socket = try io_context.socket(addr.any.family, std.posix.SOCK.STREAM, 0);
        defer io_context.close(socket) catch {};
        
        try io_context.connect(socket, &addr.any, addr.getOsSockLen());
        
        // Build HTTP request
        const http_request = try std.fmt.allocPrint(self.allocator,
            \\POST / HTTP/1.1\r
            \\Host: {s}\r
            \\Content-Type: application/json\r
            \\Content-Length: {d}\r
            \\Connection: close\r
            \\\r
            \\{s}
        , .{ host, data.len, data });
        defer self.allocator.free(http_request);
        
        // Send request
        _ = try io_context.send(socket, http_request, 0);
        
        // Receive response
        var response_buffer: [8192]u8 = undefined;
        const bytes_received = try io_context.recv(socket, &response_buffer, 0);
        
        // Parse HTTP response to extract JSON body
        const response = response_buffer[0..bytes_received];
        const body_start = std.mem.indexOf(u8, response, "\r\n\r\n") orelse return EnsError.NetworkError;
        const json_body = response[body_start + 4 ..];
        
        return try self.allocator.dupe(u8, json_body);
    }
    
    pub fn resolveAddressAsync(self: *Self, io_context: *io.Io, ens_name: []const u8) ![]u8 {
        const normalized_name = try self.normalizeEnsName(ens_name);
        defer self.allocator.free(normalized_name);
        
        const name_hash = try self.namehash(normalized_name);
        
        // Get resolver address from ENS registry
        const resolver_address = try self.getResolverAsync(io_context, name_hash);
        
        // Call addr(bytes32) on resolver
        var call_data: [36]u8 = undefined;
        
        // Function selector for addr(bytes32)
        call_data[0] = 0x3b;
        call_data[1] = 0x3b;
        call_data[2] = 0x57;
        call_data[3] = 0xde;
        
        // Name hash parameter
        @memcpy(call_data[4..36], &name_hash);
        
        var buffer: [1024]u8 = undefined;
        const eth_call = try self.buildEthereumCall(resolver_address, &call_data, &buffer);
        
        const response = try self.executeEthereumCallAsync(io_context, eth_call);
        defer self.allocator.free(response);
        
        // Parse JSON response and extract address
        return self.parseAddressFromResponse(response);
    }
    
    fn getResolverAsync(self: *Self, io_context: *io.Io, name_hash: [32]u8) ![20]u8 {
        // Call resolver(bytes32) on ENS registry
        var call_data: [36]u8 = undefined;
        
        // Function selector for resolver(bytes32)
        call_data[0] = 0x01;
        call_data[1] = 0x78;
        call_data[2] = 0x5f;
        call_data[3] = 0x53;
        
        // Name hash parameter
        @memcpy(call_data[4..36], &name_hash);
        
        var buffer: [1024]u8 = undefined;
        const eth_call = try self.buildEthereumCall(self.ens_registry_address, &call_data, &buffer);
        
        const response = try self.executeEthereumCallAsync(io_context, eth_call);
        defer self.allocator.free(response);
        
        return self.parseAddressFromResponse(response);
    }
    
    fn parseAddressFromResponse(self: *Self, response: []const u8) ![20]u8 {
        // Parse JSON response to extract hex address
        var parser = std.json.Parser.init(self.allocator, .alloc_if_needed);
        defer parser.deinit();
        
        var tree = try parser.parse(response);
        defer tree.deinit();
        
        const result = tree.root.Object.get("result") orelse return EnsError.DecodeError;
        const result_str = result.String;
        
        if (result_str.len < 42 or !std.mem.startsWith(u8, result_str, "0x")) {
            return EnsError.DecodeError;
        }
        
        // Parse hex address (skip 0x prefix)
        var address: [20]u8 = undefined;
        const hex_bytes = result_str[2..42];
        
        for (0..20) |i| {
            const hex_pair = hex_bytes[i * 2 .. i * 2 + 2];
            address[i] = std.fmt.parseInt(u8, hex_pair, 16) catch return EnsError.DecodeError;
        }
        
        return address;
    }
    
    pub fn resolveTextRecordAsync(self: *Self, io_context: *io.Io, ens_name: []const u8, key: []const u8) ![]u8 {
        const normalized_name = try self.normalizeEnsName(ens_name);
        defer self.allocator.free(normalized_name);
        
        const name_hash = try self.namehash(normalized_name);
        const resolver_address = try self.getResolverAsync(io_context, name_hash);
        
        // Call text(bytes32,string) on resolver
        // This is a simplified implementation - full ABI encoding would be more complex
        var call_data = ArrayList(u8).init(self.allocator);
        defer call_data.deinit();
        
        // Function selector for text(bytes32,string)
        try call_data.appendSlice(&[_]u8{ 0x59, 0xd1, 0xd4, 0x3c });
        
        // Name hash parameter
        try call_data.appendSlice(&name_hash);
        
        // String offset (0x40)
        try call_data.appendSlice(&[_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x40 });
        
        // String length
        const key_len_bytes = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, @truncate(key.len) };
        try call_data.appendSlice(&key_len_bytes);
        
        // String data (padded to 32 bytes)
        try call_data.appendSlice(key);
        const padding_needed = 32 - (key.len % 32);
        if (padding_needed != 32) {
            const padding = [_]u8{0} ** 32;
            try call_data.appendSlice(padding[0..padding_needed]);
        }
        
        var buffer: [2048]u8 = undefined;
        const eth_call = try self.buildEthereumCall(resolver_address, call_data.items, &buffer);
        
        const response = try self.executeEthereumCallAsync(io_context, eth_call);
        defer self.allocator.free(response);
        
        return self.parseStringFromResponse(response);
    }
    
    fn parseStringFromResponse(self: *Self, response: []const u8) ![]u8 {
        // Parse JSON response to extract string result
        var parser = std.json.Parser.init(self.allocator, .alloc_if_needed);
        defer parser.deinit();
        
        var tree = try parser.parse(response);
        defer tree.deinit();
        
        const result = tree.root.Object.get("result") orelse return EnsError.DecodeError;
        const result_str = result.String;
        
        if (result_str.len < 2 or !std.mem.startsWith(u8, result_str, "0x")) {
            return EnsError.DecodeError;
        }
        
        // Decode hex string
        const hex_data = result_str[2..];
        if (hex_data.len < 128) return EnsError.DecodeError; // Minimum for string response
        
        // Extract string length (at offset 0x40 in response)
        const length_hex = hex_data[64..128];
        const string_length = std.fmt.parseInt(u32, length_hex, 16) catch return EnsError.DecodeError;
        
        if (hex_data.len < 128 + string_length * 2) return EnsError.DecodeError;
        
        // Extract string data
        const string_hex = hex_data[128 .. 128 + string_length * 2];
        var string_data = try self.allocator.alloc(u8, string_length);
        
        for (0..string_length) |i| {
            const hex_pair = string_hex[i * 2 .. i * 2 + 2];
            string_data[i] = std.fmt.parseInt(u8, hex_pair, 16) catch return EnsError.DecodeError;
        }
        
        return string_data;
    }
    
    pub fn reverseResolveAsync(self: *Self, io_context: *io.Io, address: [20]u8) ![]u8 {
        // Build reverse DNS name: {hex_address}.addr.reverse
        const hex_address = try std.fmt.allocPrint(self.allocator, "{x}", .{std.fmt.fmtSliceHexLower(&address)});
        defer self.allocator.free(hex_address);
        
        const reverse_name = try std.fmt.allocPrint(self.allocator, "{s}.addr.reverse", .{hex_address});
        defer self.allocator.free(reverse_name);
        
        const name_hash = try self.namehash(reverse_name);
        const resolver_address = try self.getResolverAsync(io_context, name_hash);
        
        // Call name(bytes32) on resolver
        var call_data: [36]u8 = undefined;
        
        // Function selector for name(bytes32)
        call_data[0] = 0x69;
        call_data[1] = 0x1f;
        call_data[2] = 0x34;
        call_data[3] = 0x31;
        
        // Name hash parameter
        @memcpy(call_data[4..36], &name_hash);
        
        var buffer: [1024]u8 = undefined;
        const eth_call = try self.buildEthereumCall(resolver_address, &call_data, &buffer);
        
        const response = try self.executeEthereumCallAsync(io_context, eth_call);
        defer self.allocator.free(response);
        
        return self.parseStringFromResponse(response);
    }
    
    // Bridge to traditional DNS
    pub fn resolveViaDnsAsync(self: *Self, io_context: *io.Io, ens_name: []const u8) !dns_async.DnsResponse {
        // For .eth domains, try ENS first, then fall back to DNS-over-HTTPS
        if (std.mem.endsWith(u8, ens_name, ".eth")) {
            const address = self.resolveAddressAsync(io_context, ens_name) catch {
                // If ENS resolution fails, return empty DNS response
                return dns_async.DnsResponse.init(self.allocator);
            };
            defer self.allocator.free(address);
            
            // Convert Ethereum address to A record format
            var dns_response = dns_async.DnsResponse.init(self.allocator);
            
            // Create synthetic A record pointing to a gateway
            const record = dns_async.DnsRecord{
                .name = try self.allocator.dupe(u8, ens_name),
                .record_type = dns_async.RecordType.TXT,
                .ttl = 300,
                .data = try std.fmt.allocPrint(self.allocator, "ethereum-address={x}", .{std.fmt.fmtSliceHexLower(&address)}),
            };
            
            try dns_response.records.append(record);
            return dns_response;
        } else {
            // For non-ENS domains, use regular DNS resolution
            return self.dns_resolver.resolveAsync(io_context, ens_name, dns_async.RecordType.A);
        }
    }
    
    // Multicoin address support
    pub fn resolveMulticoinAddressAsync(self: *Self, io_context: *io.Io, ens_name: []const u8, coin_type: u32) ![]u8 {
        const normalized_name = try self.normalizeEnsName(ens_name);
        defer self.allocator.free(normalized_name);
        
        const name_hash = try self.namehash(normalized_name);
        const resolver_address = try self.getResolverAsync(io_context, name_hash);
        
        // Call addr(bytes32,uint256) on resolver
        var call_data: [68]u8 = undefined;
        
        // Function selector for addr(bytes32,uint256)
        call_data[0] = 0xf1;
        call_data[1] = 0xcb;
        call_data[2] = 0x7e;
        call_data[3] = 0x06;
        
        // Name hash parameter
        @memcpy(call_data[4..36], &name_hash);
        
        // Coin type parameter (uint256)
        @memset(call_data[36..68], 0);
        std.mem.writeInt(u32, call_data[64..68], coin_type, .big);
        
        var buffer: [1024]u8 = undefined;
        const eth_call = try self.buildEthereumCall(resolver_address, &call_data, &buffer);
        
        const response = try self.executeEthereumCallAsync(io_context, eth_call);
        defer self.allocator.free(response);
        
        return self.parseStringFromResponse(response);
    }
};

// Example usage and testing
test "ENS name normalization" {
    var ens_client = AsyncEnsClient.init(testing.allocator, undefined);
    defer ens_client.deinit();
    
    const normalized = try ens_client.normalizeEnsName("Example.ETH");
    defer testing.allocator.free(normalized);
    
    try testing.expectEqualStrings("example.eth", normalized);
}

test "ENS namehash calculation" {
    var ens_client = AsyncEnsClient.init(testing.allocator, undefined);
    defer ens_client.deinit();
    
    const hash = try ens_client.namehash("example.eth");
    
    // The namehash should be deterministic
    const expected_hash = try ens_client.namehash("example.eth");
    try testing.expectEqual(hash, expected_hash);
}

test "ENS RPC endpoint management" {
    var ens_client = AsyncEnsClient.init(testing.allocator, undefined);
    defer ens_client.deinit();
    
    try ens_client.addRpcEndpoint("https://test.example.com");
    try testing.expect(ens_client.ethereum_rpc_endpoints.items.len == 1);
    
    try ens_client.addDefaultRpcEndpoints();
    try testing.expect(ens_client.ethereum_rpc_endpoints.items.len > 1);
}