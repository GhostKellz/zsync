const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const HashMap = std.HashMap;
const net = std.net;
const testing = std.testing;
const io = @import("io_v2.zig");
const crypto_async = @import("crypto_async.zig");

pub const TlsError = error{
    InvalidHandshake,
    UnsupportedVersion,
    InvalidCertificate,
    HandshakeTimeout,
    NetworkError,
    CryptoError,
    ProtocolError,
    SessionError,
    OutOfMemory,
};

pub const TlsVersion = enum(u16) {
    tls_1_2 = 0x0303,
    tls_1_3 = 0x0304,
};

pub const HandshakeType = enum(u8) {
    client_hello = 1,
    server_hello = 2,
    new_session_ticket = 4,
    end_of_early_data = 5,
    encrypted_extensions = 8,
    certificate = 11,
    certificate_request = 13,
    certificate_verify = 15,
    finished = 20,
    key_update = 24,
    message_hash = 254,
};

pub const ContentType = enum(u8) {
    change_cipher_spec = 20,
    alert = 21,
    handshake = 22,
    application_data = 23,
};

pub const CipherSuite = enum(u16) {
    tls_aes_128_gcm_sha256 = 0x1301,
    tls_aes_256_gcm_sha384 = 0x1302,
    tls_chacha20_poly1305_sha256 = 0x1303,
    tls_aes_128_ccm_sha256 = 0x1304,
    tls_aes_128_ccm_8_sha256 = 0x1305,
};

pub const NamedGroup = enum(u16) {
    secp256r1 = 0x0017,
    secp384r1 = 0x0018,
    secp521r1 = 0x0019,
    x25519 = 0x001D,
    x448 = 0x001E,
    ffdhe2048 = 0x0100,
    ffdhe3072 = 0x0101,
    ffdhe4096 = 0x0102,
    ffdhe6144 = 0x0103,
    ffdhe8192 = 0x0104,
};

pub const TlsExtension = struct {
    extension_type: u16,
    data: []const u8,
    
    pub fn deinit(self: *TlsExtension, allocator: Allocator) void {
        allocator.free(self.data);
    }
};

pub const TlsCertificate = struct {
    cert_data: []const u8,
    extensions: ArrayList(TlsExtension),
    
    pub fn init(allocator: Allocator) TlsCertificate {
        return TlsCertificate{
            .cert_data = &[_]u8{},
            .extensions = ArrayList(TlsExtension){ .allocator = allocator },
        };
    }
    
    pub fn deinit(self: *TlsCertificate, allocator: Allocator) void {
        allocator.free(self.cert_data);
        for (self.extensions.items) |*ext| {
            ext.deinit(allocator);
        }
        self.extensions.deinit();
    }
};

pub const TlsHandshakeKeys = struct {
    client_random: [32]u8,
    server_random: [32]u8,
    early_secret: [32]u8,
    handshake_secret: [32]u8,
    master_secret: [32]u8,
    client_handshake_traffic_secret: [32]u8,
    server_handshake_traffic_secret: [32]u8,
    client_application_traffic_secret: [32]u8,
    server_application_traffic_secret: [32]u8,
    exporter_master_secret: [32]u8,
    resumption_master_secret: [32]u8,
    
    pub fn init() TlsHandshakeKeys {
        return TlsHandshakeKeys{
            .client_random = [_]u8{0} ** 32,
            .server_random = [_]u8{0} ** 32,
            .early_secret = [_]u8{0} ** 32,
            .handshake_secret = [_]u8{0} ** 32,
            .master_secret = [_]u8{0} ** 32,
            .client_handshake_traffic_secret = [_]u8{0} ** 32,
            .server_handshake_traffic_secret = [_]u8{0} ** 32,
            .client_application_traffic_secret = [_]u8{0} ** 32,
            .server_application_traffic_secret = [_]u8{0} ** 32,
            .exporter_master_secret = [_]u8{0} ** 32,
            .resumption_master_secret = [_]u8{0} ** 32,
        };
    }
};

pub const TlsSession = struct {
    session_id: [32]u8,
    cipher_suite: CipherSuite,
    keys: TlsHandshakeKeys,
    certificates: ArrayList(TlsCertificate),
    peer_public_key: [32]u8,
    own_private_key: [32]u8,
    is_client: bool,
    handshake_complete: bool,
    
    pub fn init(allocator: Allocator, is_client: bool) TlsSession {
        return TlsSession{
            .session_id = [_]u8{0} ** 32,
            .cipher_suite = CipherSuite.tls_aes_256_gcm_sha384,
            .keys = TlsHandshakeKeys.init(),
            .certificates = ArrayList(TlsCertificate){ .allocator = allocator },
            .peer_public_key = [_]u8{0} ** 32,
            .own_private_key = [_]u8{0} ** 32,
            .is_client = is_client,
            .handshake_complete = false,
        };
    }
    
    pub fn deinit(self: *TlsSession, allocator: Allocator) void {
        for (self.certificates.items) |*cert| {
            cert.deinit(allocator);
        }
        self.certificates.deinit();
    }
};

const SessionCache = HashMap([32]u8, TlsSession, std.hash_map.AutoContext([32]u8), std.hash_map.default_max_load_percentage);

pub const AsyncTlsContext = struct {
    allocator: Allocator,
    session_cache: SessionCache,
    cache_mutex: std.Thread.Mutex,
    supported_cipher_suites: ArrayList(CipherSuite),
    supported_groups: ArrayList(NamedGroup),
    certificates: ArrayList(TlsCertificate),
    private_key: [32]u8,
    verify_peer: bool,
    session_timeout_seconds: u64,
    
    const Self = @This();
    
    pub fn init(allocator: Allocator) Self {
        var supported_cipher_suites = ArrayList(CipherSuite){ .allocator = allocator };
        supported_cipher_suites.append(allocator, CipherSuite.tls_aes_256_gcm_sha384) catch {};
        supported_cipher_suites.append(allocator, CipherSuite.tls_aes_128_gcm_sha256) catch {};
        supported_cipher_suites.append(allocator, CipherSuite.tls_chacha20_poly1305_sha256) catch {};
        
        var supported_groups = ArrayList(NamedGroup){ .allocator = allocator };
        supported_groups.append(allocator, NamedGroup.x25519) catch {};
        supported_groups.append(allocator, NamedGroup.secp256r1) catch {};
        supported_groups.append(allocator, NamedGroup.secp384r1) catch {};
        
        return Self{
            .allocator = allocator,
            .session_cache = SessionCache.init(allocator),
            .cache_mutex = std.Thread.Mutex{},
            .supported_cipher_suites = supported_cipher_suites,
            .supported_groups = supported_groups,
            .certificates = ArrayList(TlsCertificate){ .allocator = allocator },
            .private_key = [_]u8{0} ** 32,
            .verify_peer = true,
            .session_timeout_seconds = 3600,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.cache_mutex.lock();
        defer self.cache_mutex.unlock();
        
        var iterator = self.session_cache.iterator();
        while (iterator.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.session_cache.deinit();
        
        self.supported_cipher_suites.deinit();
        self.supported_groups.deinit();
        
        for (self.certificates.items) |*cert| {
            cert.deinit(self.allocator);
        }
        self.certificates.deinit();
    }
    
    pub fn generateKeyPair(self: *Self) !void {
        // Generate X25519 key pair
        var seed: [32]u8 = undefined;
        std.crypto.random.bytes(&seed);
        
        const private_key = std.crypto.dh.X25519.KeyPair.create(seed) catch return TlsError.CryptoError;
        self.private_key = private_key.secret_key;
    }
    
    pub fn loadCertificate(self: *Self, cert_data: []const u8) !void {
        var certificate = TlsCertificate.init(self.allocator);
        certificate.cert_data = try self.allocator.dupe(u8, cert_data);
        try self.certificates.append(self.allocator, certificate);
    }
    
    fn buildClientHello(self: *Self, buffer: []u8, server_name: []const u8) !usize {
        var offset: usize = 0;
        
        // TLS Record Header
        buffer[offset] = @intFromEnum(ContentType.handshake);
        offset += 1;
        
        // TLS Version (TLS 1.2 for compatibility)
        std.mem.writeInt(u16, buffer[offset..offset + 2], @intFromEnum(TlsVersion.tls_1_2), .big);
        offset += 2;
        
        const length_offset = offset;
        offset += 2; // Skip length for now
        
        // Handshake Header
        buffer[offset] = @intFromEnum(HandshakeType.client_hello);
        offset += 1;
        
        const handshake_length_offset = offset;
        offset += 3; // Skip handshake length for now
        
        // Client Hello content
        // Version (TLS 1.3)
        std.mem.writeInt(u16, buffer[offset..offset + 2], @intFromEnum(TlsVersion.tls_1_3), .big);
        offset += 2;
        
        // Random (32 bytes)
        std.crypto.random.bytes(buffer[offset..offset + 32]);
        offset += 32;
        
        // Session ID length (0 for TLS 1.3)
        buffer[offset] = 0;
        offset += 1;
        
        // Cipher Suites
        const cipher_suites_length = @as(u16, @truncate(self.supported_cipher_suites.items.len * 2));
        std.mem.writeInt(u16, buffer[offset..offset + 2], cipher_suites_length, .big);
        offset += 2;
        
        for (self.supported_cipher_suites.items) |suite| {
            std.mem.writeInt(u16, buffer[offset..offset + 2], @intFromEnum(suite), .big);
            offset += 2;
        }
        
        // Compression Methods (none)
        buffer[offset] = 1; // Length
        offset += 1;
        buffer[offset] = 0; // No compression
        offset += 1;
        
        // Extensions
        const extensions_length_offset = offset;
        offset += 2; // Skip extensions length for now
        
        const extensions_start = offset;
        
        // Server Name Indication (SNI)
        if (server_name.len > 0) {
            offset += try self.addSniExtension(buffer[offset..], server_name);
        }
        
        // Supported Groups
        offset += try self.addSupportedGroupsExtension(buffer[offset..]);
        
        // Key Share
        offset += try self.addKeyShareExtension(buffer[offset..]);
        
        // Supported Versions (TLS 1.3)
        offset += try self.addSupportedVersionsExtension(buffer[offset..]);
        
        // Signature Algorithms
        offset += try self.addSignatureAlgorithmsExtension(buffer[offset..]);
        
        // Calculate and fill in lengths
        const extensions_length = offset - extensions_start;
        std.mem.writeInt(u16, buffer[extensions_length_offset..extensions_length_offset + 2], @truncate(extensions_length), .big);
        
        const handshake_length = offset - handshake_length_offset - 3;
        buffer[handshake_length_offset] = @truncate(handshake_length >> 16);
        buffer[handshake_length_offset + 1] = @truncate(handshake_length >> 8);
        buffer[handshake_length_offset + 2] = @truncate(handshake_length);
        
        const record_length = offset - length_offset - 2;
        std.mem.writeInt(u16, buffer[length_offset..length_offset + 2], @truncate(record_length), .big);
        
        return offset;
    }
    
    fn addSniExtension(self: *Self, buffer: []u8, server_name: []const u8) !usize {
        _ = self;
        var offset: usize = 0;
        
        // Extension Type (SNI = 0)
        std.mem.writeInt(u16, buffer[offset..offset + 2], 0, .big);
        offset += 2;
        
        // Extension Length
        const ext_length = 5 + server_name.len;
        std.mem.writeInt(u16, buffer[offset..offset + 2], @truncate(ext_length), .big);
        offset += 2;
        
        // Server Name List Length
        std.mem.writeInt(u16, buffer[offset..offset + 2], @truncate(ext_length - 2), .big);
        offset += 2;
        
        // Name Type (hostname = 0)
        buffer[offset] = 0;
        offset += 1;
        
        // Name Length
        std.mem.writeInt(u16, buffer[offset..offset + 2], @truncate(server_name.len), .big);
        offset += 2;
        
        // Name
        @memcpy(buffer[offset..offset + server_name.len], server_name);
        offset += server_name.len;
        
        return offset;
    }
    
    fn addSupportedGroupsExtension(self: *Self, buffer: []u8) !usize {
        var offset: usize = 0;
        
        // Extension Type (Supported Groups = 10)
        std.mem.writeInt(u16, buffer[offset..offset + 2], 10, .big);
        offset += 2;
        
        // Extension Length
        const ext_length = 2 + self.supported_groups.items.len * 2;
        std.mem.writeInt(u16, buffer[offset..offset + 2], @truncate(ext_length), .big);
        offset += 2;
        
        // Named Group List Length
        std.mem.writeInt(u16, buffer[offset..offset + 2], @truncate(self.supported_groups.items.len * 2), .big);
        offset += 2;
        
        // Named Groups
        for (self.supported_groups.items) |group| {
            std.mem.writeInt(u16, buffer[offset..offset + 2], @intFromEnum(group), .big);
            offset += 2;
        }
        
        return offset;
    }
    
    fn addKeyShareExtension(self: *Self, buffer: []u8) !usize {
        var offset: usize = 0;
        
        // Extension Type (Key Share = 51)
        std.mem.writeInt(u16, buffer[offset..offset + 2], 51, .big);
        offset += 2;
        
        // Extension Length
        const ext_length = 2 + 4 + 32; // List length + group + key length + key
        std.mem.writeInt(u16, buffer[offset..offset + 2], ext_length, .big);
        offset += 2;
        
        // Key Share List Length
        std.mem.writeInt(u16, buffer[offset..offset + 2], 4 + 32, .big);
        offset += 2;
        
        // Key Share Entry
        // Group (X25519)
        std.mem.writeInt(u16, buffer[offset..offset + 2], @intFromEnum(NamedGroup.x25519), .big);
        offset += 2;
        
        // Key Exchange Length
        std.mem.writeInt(u16, buffer[offset..offset + 2], 32, .big);
        offset += 2;
        
        // Public Key (X25519)
        const public_key = std.crypto.dh.X25519.scalarmultBase(self.private_key) catch return TlsError.CryptoError;
        @memcpy(buffer[offset..offset + 32], &public_key);
        offset += 32;
        
        return offset;
    }
    
    fn addSupportedVersionsExtension(self: *Self, buffer: []u8) !usize {
        _ = self;
        var offset: usize = 0;
        
        // Extension Type (Supported Versions = 43)
        std.mem.writeInt(u16, buffer[offset..offset + 2], 43, .big);
        offset += 2;
        
        // Extension Length
        std.mem.writeInt(u16, buffer[offset..offset + 2], 3, .big);
        offset += 2;
        
        // Supported Versions Length
        buffer[offset] = 2;
        offset += 1;
        
        // TLS 1.3
        std.mem.writeInt(u16, buffer[offset..offset + 2], @intFromEnum(TlsVersion.tls_1_3), .big);
        offset += 2;
        
        return offset;
    }
    
    fn addSignatureAlgorithmsExtension(self: *Self, buffer: []u8) !usize {
        _ = self;
        var offset: usize = 0;
        
        // Extension Type (Signature Algorithms = 13)
        std.mem.writeInt(u16, buffer[offset..offset + 2], 13, .big);
        offset += 2;
        
        // Extension Length
        std.mem.writeInt(u16, buffer[offset..offset + 2], 8, .big);
        offset += 2;
        
        // Signature Hash Algorithms Length
        std.mem.writeInt(u16, buffer[offset..offset + 2], 6, .big);
        offset += 2;
        
        // Signature Algorithms
        // ECDSA with SHA-256
        std.mem.writeInt(u16, buffer[offset..offset + 2], 0x0403, .big);
        offset += 2;
        
        // ECDSA with SHA-384
        std.mem.writeInt(u16, buffer[offset..offset + 2], 0x0503, .big);
        offset += 2;
        
        // Ed25519
        std.mem.writeInt(u16, buffer[offset..offset + 2], 0x0807, .big);
        offset += 2;
        
        return offset;
    }
    
    fn parseServerHello(self: *Self, data: []const u8, session: *TlsSession) !void {
        if (data.len < 38) return TlsError.InvalidHandshake;
        
        var offset: usize = 0;
        
        // Skip record header (5 bytes)
        offset += 5;
        
        // Skip handshake header (4 bytes)
        offset += 4;
        
        // Version
        const version = std.mem.readInt(u16, data[offset..offset + 2], .big);
        if (version != @intFromEnum(TlsVersion.tls_1_3)) {
            return TlsError.UnsupportedVersion;
        }
        offset += 2;
        
        // Server Random
        @memcpy(&session.keys.server_random, data[offset..offset + 32]);
        offset += 32;
        
        // Session ID
        const session_id_length = data[offset];
        offset += 1 + session_id_length;
        
        // Cipher Suite
        const cipher_suite_raw = std.mem.readInt(u16, data[offset..offset + 2], .big);
        session.cipher_suite = @enumFromInt(cipher_suite_raw);
        offset += 2;
        
        // Compression Method
        offset += 1;
        
        // Parse extensions
        if (offset + 2 <= data.len) {
            const extensions_length = std.mem.readInt(u16, data[offset..offset + 2], .big);
            offset += 2;
            
            try self.parseServerExtensions(data[offset..offset + extensions_length], session);
        }
    }
    
    fn parseServerExtensions(self: *Self, extensions_data: []const u8, session: *TlsSession) !void {
        _ = self;
        var offset: usize = 0;
        
        while (offset + 4 <= extensions_data.len) {
            const ext_type = std.mem.readInt(u16, extensions_data[offset..offset + 2], .big);
            offset += 2;
            
            const ext_length = std.mem.readInt(u16, extensions_data[offset..offset + 2], .big);
            offset += 2;
            
            if (offset + ext_length > extensions_data.len) break;
            
            const ext_data = extensions_data[offset..offset + ext_length];
            
            switch (ext_type) {
                51 => { // Key Share
                    if (ext_data.len >= 36) {
                        // Parse server's public key
                        const group = std.mem.readInt(u16, ext_data[0..2], .big);
                        if (group == @intFromEnum(NamedGroup.x25519)) {
                            const key_length = std.mem.readInt(u16, ext_data[2..4], .big);
                            if (key_length == 32 and ext_data.len >= 4 + key_length) {
                                @memcpy(&session.peer_public_key, ext_data[4..4 + key_length]);
                            }
                        }
                    }
                },
                43 => { // Supported Versions
                    // Verify TLS 1.3 is selected
                    if (ext_data.len >= 2) {
                        const version = std.mem.readInt(u16, ext_data[0..2], .big);
                        if (version != @intFromEnum(TlsVersion.tls_1_3)) {
                            return TlsError.UnsupportedVersion;
                        }
                    }
                },
                else => {
                    // Skip unknown extensions
                },
            }
            
            offset += ext_length;
        }
    }
    
    fn deriveHandshakeSecrets(self: *Self, session: *TlsSession) !void {
        // Compute shared secret using X25519
        const shared_secret = std.crypto.dh.X25519.scalarmult(session.own_private_key, session.peer_public_key) catch return TlsError.CryptoError;
        
        // Derive early secret (empty PSK for now)
        const empty_hash = [_]u8{0} ** 32;
        var early_secret: [32]u8 = undefined;
        try self.hkdfExtract(&empty_hash, &empty_hash, &early_secret);
        session.keys.early_secret = early_secret;
        
        // Derive handshake secret
        try self.hkdfExtract(&early_secret, &shared_secret, &session.keys.handshake_secret);
        
        // Derive traffic secrets
        const client_handshake_context = try self.buildHandshakeContext(session, true);
        defer self.allocator.free(client_handshake_context);
        
        const server_handshake_context = try self.buildHandshakeContext(session, false);
        defer self.allocator.free(server_handshake_context);
        
        try self.hkdfExpandLabel(&session.keys.handshake_secret, "c hs traffic", client_handshake_context, &session.keys.client_handshake_traffic_secret);
        try self.hkdfExpandLabel(&session.keys.handshake_secret, "s hs traffic", server_handshake_context, &session.keys.server_handshake_traffic_secret);
    }
    
    fn hkdfExtract(self: *Self, salt: []const u8, ikm: []const u8, prk: *[32]u8) !void {
        _ = self;
        var hmac = std.crypto.auth.hmac.HmacSha256.init(salt);
        hmac.update(ikm);
        hmac.final(prk);
    }
    
    fn hkdfExpandLabel(self: *Self, prk: []const u8, label: []const u8, context: []const u8, output: *[32]u8) !void {
        const full_label = try std.fmt.allocPrint(self.allocator, "tls13 {s}", .{label});
        defer self.allocator.free(full_label);
        
        // Build HKDF-Expand-Label structure
        var hkdf_label = ArrayList(u8){ .allocator = self.allocator };
        defer hkdf_label.deinit();
        
        // Length (2 bytes)
        try hkdf_label.append(allocator, 0);
        try hkdf_label.append(allocator, 32);
        
        // Label length + label
        try hkdf_label.append(allocator, @truncate(full_label.len));
        try hkdf_label.appendSlice(full_label);
        
        // Context length + context
        try hkdf_label.append(allocator, @truncate(context.len));
        try hkdf_label.appendSlice(context);
        
        var hmac = std.crypto.auth.hmac.HmacSha256.init(prk);
        hmac.update(hkdf_label.items);
        hmac.final(output);
    }
    
    fn buildHandshakeContext(self: *Self, session: *TlsSession, is_client: bool) ![]u8 {
        _ = session;
        _ = is_client;
        
        // Build transcript hash of handshake messages
        // This is a simplified version - in practice, would hash all handshake messages
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update("simplified handshake context");
        
        var context: [32]u8 = undefined;
        hasher.final(&context);
        
        return try self.allocator.dupe(u8, &context);
    }
    
    pub fn connectAsync(self: *Self, io_context: *io.Io, address: net.Address, server_name: []const u8) !std.posix.socket_t {
        const socket = try io_context.socket(address.any.family, std.posix.SOCK.STREAM, 0);
        
        // Connect to server
        io_context.connect(socket, &address.any, address.getOsSockLen()) catch |err| {
            io_context.close(socket) catch {};
            return err;
        };
        
        // Perform TLS handshake
        try self.performHandshakeAsync(io_context, socket, server_name, true);
        
        return socket;
    }
    
    pub fn acceptAsync(self: *Self, io_context: *io.Io, listen_socket: std.posix.socket_t) !std.posix.socket_t {
        var client_addr: std.posix.sockaddr = undefined;
        var addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);
        
        const client_socket = try io_context.accept(listen_socket, &client_addr, &addr_len);
        
        // Perform TLS handshake as server
        self.performHandshakeAsync(io_context, client_socket, "", false) catch |err| {
            io_context.close(client_socket) catch {};
            return err;
        };
        
        return client_socket;
    }
    
    fn performHandshakeAsync(self: *Self, io_context: *io.Io, socket: std.posix.socket_t, server_name: []const u8, is_client: bool) !void {
        var session = TlsSession.init(self.allocator, is_client);
        defer session.deinit(self.allocator);
        
        session.own_private_key = self.private_key;
        
        if (is_client) {
            // Send Client Hello
            var client_hello_buffer: [4096]u8 = undefined;
            const client_hello_length = try self.buildClientHello(&client_hello_buffer, server_name);
            
            _ = try io_context.send(socket, client_hello_buffer[0..client_hello_length], 0);
            
            // Receive Server Hello
            var server_hello_buffer: [4096]u8 = undefined;
            const server_hello_length = try io_context.recv(socket, &server_hello_buffer, 0);
            
            try self.parseServerHello(server_hello_buffer[0..server_hello_length], &session);
            
            // Derive handshake secrets
            try self.deriveHandshakeSecrets(&session);
            
            // Continue with handshake (simplified)
            session.handshake_complete = true;
        } else {
            // Server-side handshake implementation would go here
            return TlsError.ProtocolError;
        }
        
        // Cache session
        try self.cacheSession(&session);
    }
    
    fn cacheSession(self: *Self, session: *TlsSession) !void {
        self.cache_mutex.lock();
        defer self.cache_mutex.unlock();
        
        // Clone session for caching
        var cached_session = TlsSession.init(self.allocator, session.is_client);
        cached_session.session_id = session.session_id;
        cached_session.cipher_suite = session.cipher_suite;
        cached_session.keys = session.keys;
        cached_session.peer_public_key = session.peer_public_key;
        cached_session.own_private_key = session.own_private_key;
        cached_session.handshake_complete = session.handshake_complete;
        
        try self.session_cache.put(session.session_id, cached_session);
    }
    
    pub fn sendAsync(self: *Self, io_context: *io.Io, socket: std.posix.socket_t, data: []const u8) !usize {
        // In a full implementation, this would encrypt the data using the session keys
        // For now, we'll just send plain data (simplified)
        _ = self;
        return io_context.send(socket, data, 0);
    }
    
    pub fn recvAsync(self: *Self, io_context: *io.Io, socket: std.posix.socket_t, buffer: []u8) !usize {
        // In a full implementation, this would decrypt the received data
        // For now, we'll just receive plain data (simplified)
        _ = self;
        return io_context.recv(socket, buffer, 0);
    }
    
    pub fn closeAsync(self: *Self, io_context: *io.Io, socket: std.posix.socket_t) !void {
        // Send close_notify alert (simplified)
        _ = self;
        try io_context.close(socket);
    }
};

// Example usage and testing
test "TLS context initialization" {
    var tls_ctx = AsyncTlsContext.init(testing.allocator);
    defer tls_ctx.deinit();
    
    try tls_ctx.generateKeyPair();
    try testing.expect(tls_ctx.supported_cipher_suites.items.len > 0);
    try testing.expect(tls_ctx.supported_groups.items.len > 0);
}

test "TLS certificate loading" {
    var tls_ctx = AsyncTlsContext.init(testing.allocator);
    defer tls_ctx.deinit();
    
    const test_cert = "-----BEGIN CERTIFICATE-----\ntest\n-----END CERTIFICATE-----";
    try tls_ctx.loadCertificate(test_cert);
    
    try testing.expect(tls_ctx.certificates.items.len == 1);
}

test "Client Hello generation" {
    var tls_ctx = AsyncTlsContext.init(testing.allocator);
    defer tls_ctx.deinit();
    
    try tls_ctx.generateKeyPair();
    
    var buffer: [4096]u8 = undefined;
    const length = try tls_ctx.buildClientHello(&buffer, "example.com");
    
    try testing.expect(length > 0);
    try testing.expect(buffer[0] == @intFromEnum(ContentType.handshake));
}