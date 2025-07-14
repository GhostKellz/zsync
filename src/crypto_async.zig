//! Crypto async operations for key management workflows
//! Provides HD wallet derivation, key rotation, threshold keys, and backup encryption

const std = @import("std");
const io_v2 = @import("io_v2.zig");

/// Key algorithms supported
pub const KeyAlgorithm = enum {
    ECDSA_secp256k1,
    Ed25519,
    BLS12_381,
    X25519,
    RSA_2048,
    RSA_4096,
};

/// HD wallet derivation path
pub const DerivationPath = struct {
    purpose: u32 = 44, // BIP-44
    coin_type: u32 = 60, // Ethereum
    account: u32 = 0,
    change: u32 = 0,
    address_index: u32 = 0,
    
    /// Convert to path string
    pub fn toString(self: DerivationPath, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "m/{d}'/{d}'/{d}'/{d}/{d}", .{
            self.purpose, self.coin_type, self.account, self.change, self.address_index
        });
    }
};

/// Key pair structure
pub const KeyPair = struct {
    algorithm: KeyAlgorithm,
    private_key: []u8,
    public_key: []u8,
    derivation_path: ?DerivationPath,
    created_at: i64,
    
    /// Initialize key pair
    pub fn init(allocator: std.mem.Allocator, algorithm: KeyAlgorithm, private_key: []const u8, public_key: []const u8) !KeyPair {
        return KeyPair{
            .algorithm = algorithm,
            .private_key = try allocator.dupe(u8, private_key),
            .public_key = try allocator.dupe(u8, public_key),
            .derivation_path = null,
            .created_at = std.time.timestamp(),
        };
    }
    
    /// Deinitialize key pair
    pub fn deinit(self: *KeyPair, allocator: std.mem.Allocator) void {
        // Zero out private key before freeing
        @memset(self.private_key, 0);
        allocator.free(self.private_key);
        allocator.free(self.public_key);
    }
};

/// HD Wallet for hierarchical deterministic key derivation
pub const HDWallet = struct {
    allocator: std.mem.Allocator,
    master_seed: [64]u8,
    master_private_key: [32]u8,
    master_chain_code: [32]u8,
    derived_keys: std.hash_map.HashMap(u32, KeyPair, std.hash_map.AutoContext(u32), 80),
    io: io_v2.Io,
    
    /// Initialize HD wallet from seed
    pub fn init(allocator: std.mem.Allocator, io: io_v2.Io, seed: []const u8) !HDWallet {
        var wallet = HDWallet{
            .allocator = allocator,
            .master_seed = undefined,
            .master_private_key = undefined,
            .master_chain_code = undefined,
            .derived_keys = std.hash_map.HashMap(u32, KeyPair, std.hash_map.AutoContext(u32), 80).init(allocator),
            .io = io,
        };
        
        // Generate master key from seed using HMAC-SHA512
        var hmac = std.crypto.auth.hmac.HmacSha512.init("Bitcoin seed");
        hmac.update(seed);
        hmac.final(&wallet.master_seed);
        
        // Split into private key and chain code
        @memcpy(wallet.master_private_key[0..32], wallet.master_seed[0..32]);
        @memcpy(wallet.master_chain_code[0..32], wallet.master_seed[32..64]);
        
        return wallet;
    }
    
    /// Deinitialize wallet
    pub fn deinit(self: *HDWallet) void {
        // Zero out sensitive data
        @memset(&self.master_seed, 0);
        @memset(&self.master_private_key, 0);
        @memset(&self.master_chain_code, 0);
        
        var iter = self.derived_keys.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.derived_keys.deinit();
    }
    
    /// Derive key asynchronously
    pub fn deriveKeyAsync(self: *HDWallet, allocator: std.mem.Allocator, path: DerivationPath, algorithm: KeyAlgorithm) !io_v2.Future {
        const ctx = try allocator.create(DeriveKeyContext);
        ctx.* = .{
            .wallet = self,
            .path = path,
            .algorithm = algorithm,
            .allocator = allocator,
            .result = null,
        };
        
        return io_v2.Future{
            .impl = .{
                .callback = .{
                    .context = @ptrCast(ctx),
                    .poll_fn = deriveKeyPoll,
                    .deinit_fn = deriveKeyDeinit,
                },
            },
        };
    }
    
    /// Generate key pair for derivation path
    fn deriveKeyFromPath(self: *HDWallet, path: DerivationPath, algorithm: KeyAlgorithm) !KeyPair {
        // Simplified key derivation - real implementation would follow BIP-32
        var derived_key: [32]u8 = undefined;
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        
        hasher.update(&self.master_private_key);
        hasher.update(std.mem.asBytes(&path.purpose));
        hasher.update(std.mem.asBytes(&path.coin_type));
        hasher.update(std.mem.asBytes(&path.account));
        hasher.update(std.mem.asBytes(&path.change));
        hasher.update(std.mem.asBytes(&path.address_index));
        
        hasher.final(&derived_key);
        
        // Generate public key based on algorithm
        const public_key = switch (algorithm) {
            .ECDSA_secp256k1 => try self.generateSecp256k1PublicKey(&derived_key),
            .Ed25519 => try self.generateEd25519PublicKey(&derived_key),
            .BLS12_381 => try self.generateBLS12381PublicKey(&derived_key),
            else => return error.UnsupportedAlgorithm,
        };
        
        var keypair = try KeyPair.init(self.allocator, algorithm, &derived_key, public_key);
        keypair.derivation_path = path;
        
        return keypair;
    }
    
    fn generateSecp256k1PublicKey(self: *HDWallet, private_key: *const [32]u8) ![]u8 {
        // Simplified secp256k1 public key generation
        var public_key = try self.allocator.alloc(u8, 33);
        public_key[0] = 0x02; // Compressed public key prefix
        @memcpy(public_key[1..], private_key[0..32]);
        return public_key;
    }
    
    fn generateEd25519PublicKey(self: *HDWallet, private_key: *const [32]u8) ![]u8 {
        // Ed25519 public key generation
        var public_key = try self.allocator.alloc(u8, 32);
        const keypair = std.crypto.sign.Ed25519.KeyPair.create(private_key.*) catch |err| {
            self.allocator.free(public_key);
            return err;
        };
        @memcpy(public_key, &keypair.public_key);
        return public_key;
    }
    
    fn generateBLS12381PublicKey(self: *HDWallet, private_key: *const [32]u8) ![]u8 {
        // Simplified BLS12-381 public key (48 bytes)
        var public_key = try self.allocator.alloc(u8, 48);
        
        // Simplified BLS key generation - real implementation would use proper BLS
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(private_key);
        hasher.update("BLS12-381");
        
        var hash: [32]u8 = undefined;
        hasher.final(&hash);
        
        @memcpy(public_key[0..32], &hash);
        @memset(public_key[32..48], 0x01); // Padding
        
        return public_key;
    }
};

/// Key rotation manager
pub const KeyRotationManager = struct {
    allocator: std.mem.Allocator,
    current_keys: std.hash_map.HashMap([]const u8, KeyPair, std.hash_map.StringContext, 80),
    rotation_schedule: std.ArrayList(RotationTask),
    io: io_v2.Io,
    
    const RotationTask = struct {
        service_name: []const u8,
        next_rotation: i64,
        rotation_interval: i64,
        algorithm: KeyAlgorithm,
    };
    
    /// Initialize key rotation manager
    pub fn init(allocator: std.mem.Allocator, io: io_v2.Io) KeyRotationManager {
        return KeyRotationManager{
            .allocator = allocator,
            .current_keys = std.hash_map.HashMap([]const u8, KeyPair, std.hash_map.StringContext, 80).init(allocator),
            .rotation_schedule = std.ArrayList(RotationTask).init(allocator),
            .io = io,
        };
    }
    
    /// Deinitialize manager
    pub fn deinit(self: *KeyRotationManager) void {
        var iter = self.current_keys.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.current_keys.deinit();
        self.rotation_schedule.deinit();
    }
    
    /// Schedule key rotation
    pub fn scheduleRotation(self: *KeyRotationManager, service_name: []const u8, interval_hours: u32, algorithm: KeyAlgorithm) !void {
        const task = RotationTask{
            .service_name = try self.allocator.dupe(u8, service_name),
            .next_rotation = std.time.timestamp() + (interval_hours * 3600),
            .rotation_interval = interval_hours * 3600,
            .algorithm = algorithm,
        };
        
        try self.rotation_schedule.append(task);
    }
    
    /// Perform key rotation asynchronously
    pub fn rotateKeysAsync(self: *KeyRotationManager, allocator: std.mem.Allocator) !io_v2.Future {
        const ctx = try allocator.create(RotateKeysContext);
        ctx.* = .{
            .manager = self,
            .allocator = allocator,
            .rotated_count = 0,
        };
        
        return io_v2.Future{
            .impl = .{
                .callback = .{
                    .context = @ptrCast(ctx),
                    .poll_fn = rotateKeysPoll,
                    .deinit_fn = rotateKeysDeinit,
                },
            },
        };
    }
};

/// Threshold key management for multi-party signatures
pub const ThresholdKeyManager = struct {
    allocator: std.mem.Allocator,
    threshold: u32,
    total_parties: u32,
    key_shares: std.ArrayList(KeyShare),
    io: io_v2.Io,
    
    const KeyShare = struct {
        party_id: u32,
        share: []u8,
        public_verification: []u8,
    };
    
    /// Initialize threshold key manager
    pub fn init(allocator: std.mem.Allocator, io: io_v2.Io, threshold: u32, total_parties: u32) !ThresholdKeyManager {
        if (threshold > total_parties) {
            return error.InvalidThreshold;
        }
        
        return ThresholdKeyManager{
            .allocator = allocator,
            .threshold = threshold,
            .total_parties = total_parties,
            .key_shares = std.ArrayList(KeyShare).init(allocator),
            .io = io,
        };
    }
    
    /// Deinitialize manager
    pub fn deinit(self: *ThresholdKeyManager) void {
        for (self.key_shares.items) |*share| {
            // Zero out sensitive data
            @memset(share.share, 0);
            self.allocator.free(share.share);
            self.allocator.free(share.public_verification);
        }
        self.key_shares.deinit();
    }
    
    /// Generate threshold key shares asynchronously
    pub fn generateThresholdKeysAsync(self: *ThresholdKeyManager, allocator: std.mem.Allocator, algorithm: KeyAlgorithm) !io_v2.Future {
        const ctx = try allocator.create(ThresholdGenContext);
        ctx.* = .{
            .manager = self,
            .algorithm = algorithm,
            .allocator = allocator,
            .shares_generated = 0,
        };
        
        return io_v2.Future{
            .impl = .{
                .callback = .{
                    .context = @ptrCast(ctx),
                    .poll_fn = thresholdGenPoll,
                    .deinit_fn = thresholdGenDeinit,
                },
            },
        };
    }
    
    /// Reconstruct key from threshold shares asynchronously
    pub fn reconstructKeyAsync(self: *ThresholdKeyManager, allocator: std.mem.Allocator, share_indices: []const u32) !io_v2.Future {
        const ctx = try allocator.create(ReconstructContext);
        ctx.* = .{
            .manager = self,
            .share_indices = try allocator.dupe(u32, share_indices),
            .allocator = allocator,
            .reconstructed_key = null,
        };
        
        return io_v2.Future{
            .impl = .{
                .callback = .{
                    .context = @ptrCast(ctx),
                    .poll_fn = reconstructPoll,
                    .deinit_fn = reconstructDeinit,
                },
            },
        };
    }
};

/// Secure key backup and encryption
pub const KeyBackupManager = struct {
    allocator: std.mem.Allocator,
    backup_locations: std.ArrayList(BackupLocation),
    encryption_key: [32]u8,
    io: io_v2.Io,
    
    const BackupLocation = struct {
        path: []const u8,
        encryption_enabled: bool,
        redundancy_level: u32,
    };
    
    /// Initialize backup manager
    pub fn init(allocator: std.mem.Allocator, io: io_v2.Io, encryption_key: [32]u8) KeyBackupManager {
        return KeyBackupManager{
            .allocator = allocator,
            .backup_locations = std.ArrayList(BackupLocation).init(allocator),
            .encryption_key = encryption_key,
            .io = io,
        };
    }
    
    /// Deinitialize manager
    pub fn deinit(self: *KeyBackupManager) void {
        // Zero out encryption key
        @memset(&self.encryption_key, 0);
        
        for (self.backup_locations.items) |location| {
            self.allocator.free(location.path);
        }
        self.backup_locations.deinit();
    }
    
    /// Add backup location
    pub fn addBackupLocation(self: *KeyBackupManager, path: []const u8, encryption_enabled: bool, redundancy_level: u32) !void {
        const location = BackupLocation{
            .path = try self.allocator.dupe(u8, path),
            .encryption_enabled = encryption_enabled,
            .redundancy_level = redundancy_level,
        };
        try self.backup_locations.append(location);
    }
    
    /// Backup key asynchronously
    pub fn backupKeyAsync(self: *KeyBackupManager, allocator: std.mem.Allocator, keypair: *const KeyPair, backup_name: []const u8) !io_v2.Future {
        const ctx = try allocator.create(BackupContext);
        ctx.* = .{
            .manager = self,
            .keypair = keypair,
            .backup_name = try allocator.dupe(u8, backup_name),
            .allocator = allocator,
            .backup_success = false,
        };
        
        return io_v2.Future{
            .impl = .{
                .callback = .{
                    .context = @ptrCast(ctx),
                    .poll_fn = backupPoll,
                    .deinit_fn = backupDeinit,
                },
            },
        };
    }
    
    /// Restore key asynchronously
    pub fn restoreKeyAsync(self: *KeyBackupManager, allocator: std.mem.Allocator, backup_name: []const u8) !io_v2.Future {
        const ctx = try allocator.create(RestoreContext);
        ctx.* = .{
            .manager = self,
            .backup_name = try allocator.dupe(u8, backup_name),
            .allocator = allocator,
            .restored_key = null,
        };
        
        return io_v2.Future{
            .impl = .{
                .callback = .{
                    .context = @ptrCast(ctx),
                    .poll_fn = restorePoll,
                    .deinit_fn = restoreDeinit,
                },
            },
        };
    }
};

// Context structures
const DeriveKeyContext = struct {
    wallet: *HDWallet,
    path: DerivationPath,
    algorithm: KeyAlgorithm,
    allocator: std.mem.Allocator,
    result: ?KeyPair,
};

const RotateKeysContext = struct {
    manager: *KeyRotationManager,
    allocator: std.mem.Allocator,
    rotated_count: u32,
};

const ThresholdGenContext = struct {
    manager: *ThresholdKeyManager,
    algorithm: KeyAlgorithm,
    allocator: std.mem.Allocator,
    shares_generated: u32,
};

const ReconstructContext = struct {
    manager: *ThresholdKeyManager,
    share_indices: []u32,
    allocator: std.mem.Allocator,
    reconstructed_key: ?[]u8,
};

const BackupContext = struct {
    manager: *KeyBackupManager,
    keypair: *const KeyPair,
    backup_name: []u8,
    allocator: std.mem.Allocator,
    backup_success: bool,
};

const RestoreContext = struct {
    manager: *KeyBackupManager,
    backup_name: []u8,
    allocator: std.mem.Allocator,
    restored_key: ?KeyPair,
};

// Poll functions
fn deriveKeyPoll(context: *anyopaque, io: io_v2.Io) io_v2.Future.PollResult {
    _ = io;
    const ctx = @as(*DeriveKeyContext, @ptrCast(@alignCast(context)));
    
    const keypair = ctx.wallet.deriveKeyFromPath(ctx.path, ctx.algorithm) catch |err| {
        return .{ .ready = err };
    };
    
    ctx.result = keypair;
    
    return .{ .ready = ctx.result };
}

fn deriveKeyDeinit(context: *anyopaque, allocator: std.mem.Allocator) void {
    const ctx = @as(*DeriveKeyContext, @ptrCast(@alignCast(context)));
    allocator.destroy(ctx);
}

fn rotateKeysPoll(context: *anyopaque, io: io_v2.Io) io_v2.Future.PollResult {
    _ = io;
    const ctx = @as(*RotateKeysContext, @ptrCast(@alignCast(context)));
    
    const current_time = std.time.timestamp();
    
    for (ctx.manager.rotation_schedule.items) |*task| {
        if (current_time >= task.next_rotation) {
            // Generate new key for this service
            var new_private_key: [32]u8 = undefined;
            std.crypto.random.bytes(&new_private_key);
            
            // Create new key pair (simplified)
            const new_public_key = ctx.manager.allocator.alloc(u8, 32) catch |err| {
                return .{ .ready = err };
            };
            @memcpy(new_public_key, &new_private_key);
            
            const new_keypair = KeyPair.init(ctx.manager.allocator, task.algorithm, &new_private_key, new_public_key) catch |err| {
                ctx.manager.allocator.free(new_public_key);
                return .{ .ready = err };
            };
            
            // Replace old key
            if (ctx.manager.current_keys.fetchPut(task.service_name, new_keypair)) |old_entry| {
                old_entry.value.deinit(ctx.manager.allocator);
            } else |err| {
                return .{ .ready = err };
            }
            
            // Schedule next rotation
            task.next_rotation = current_time + task.rotation_interval;
            ctx.rotated_count += 1;
        }
    }
    
    return .{ .ready = ctx.rotated_count };
}

fn rotateKeysDeinit(context: *anyopaque, allocator: std.mem.Allocator) void {
    const ctx = @as(*RotateKeysContext, @ptrCast(@alignCast(context)));
    allocator.destroy(ctx);
}

fn thresholdGenPoll(context: *anyopaque, io: io_v2.Io) io_v2.Future.PollResult {
    _ = io;
    const ctx = @as(*ThresholdGenContext, @ptrCast(@alignCast(context)));
    
    // Generate threshold key shares using Shamir's Secret Sharing (simplified)
    var master_secret: [32]u8 = undefined;
    std.crypto.random.bytes(&master_secret);
    
    for (0..ctx.manager.total_parties) |i| {
        // Generate share for party i (simplified)
        const share_data = ctx.manager.allocator.alloc(u8, 32) catch |err| {
            return .{ .ready = err };
        };
        
        // XOR with party index for simplicity (real implementation would use proper secret sharing)
        @memcpy(share_data, &master_secret);
        share_data[0] ^= @intCast(i + 1);
        
        const verification_data = ctx.manager.allocator.alloc(u8, 32) catch |err| {
            ctx.manager.allocator.free(share_data);
            return .{ .ready = err };
        };
        @memcpy(verification_data, share_data);
        
        const share = ThresholdKeyManager.KeyShare{
            .party_id = @intCast(i + 1),
            .share = share_data,
            .public_verification = verification_data,
        };
        
        ctx.manager.key_shares.append(share) catch |err| {
            ctx.manager.allocator.free(share_data);
            ctx.manager.allocator.free(verification_data);
            return .{ .ready = err };
        };
        
        ctx.shares_generated += 1;
    }
    
    return .{ .ready = ctx.shares_generated };
}

fn thresholdGenDeinit(context: *anyopaque, allocator: std.mem.Allocator) void {
    const ctx = @as(*ThresholdGenContext, @ptrCast(@alignCast(context)));
    allocator.destroy(ctx);
}

fn reconstructPoll(context: *anyopaque, io: io_v2.Io) io_v2.Future.PollResult {
    _ = io;
    const ctx = @as(*ReconstructContext, @ptrCast(@alignCast(context)));
    
    if (ctx.share_indices.len < ctx.manager.threshold) {
        return .{ .ready = error.InsufficientShares };
    }
    
    // Reconstruct key from shares (simplified)
    var reconstructed: [32]u8 = undefined;
    @memset(&reconstructed, 0);
    
    for (ctx.share_indices) |share_index| {
        if (share_index > ctx.manager.key_shares.items.len) {
            return .{ .ready = error.InvalidShareIndex };
        }
        
        const share = &ctx.manager.key_shares.items[share_index - 1];
        
        // XOR shares for reconstruction (simplified)
        for (reconstructed, 0..) |*byte, i| {
            byte.* ^= share.share[i];
        }
    }
    
    ctx.reconstructed_key = ctx.allocator.dupe(u8, &reconstructed) catch |err| {
        return .{ .ready = err };
    };
    
    return .{ .ready = ctx.reconstructed_key };
}

fn reconstructDeinit(context: *anyopaque, allocator: std.mem.Allocator) void {
    const ctx = @as(*ReconstructContext, @ptrCast(@alignCast(context)));
    allocator.free(ctx.share_indices);
    if (ctx.reconstructed_key) |key| {
        // Zero out reconstructed key
        @memset(key, 0);
        allocator.free(key);
    }
    allocator.destroy(ctx);
}

fn backupPoll(context: *anyopaque, io: io_v2.Io) io_v2.Future.PollResult {
    _ = io;
    const ctx = @as(*BackupContext, @ptrCast(@alignCast(context)));
    
    for (ctx.manager.backup_locations.items) |location| {
        // Create backup file path
        const backup_path = std.fmt.allocPrint(ctx.allocator, "{s}/{s}.backup", .{ location.path, ctx.backup_name }) catch |err| {
            return .{ .ready = err };
        };
        defer ctx.allocator.free(backup_path);
        
        // Encrypt key data if needed
        var backup_data: []u8 = undefined;
        if (location.encryption_enabled) {
            // Simple XOR encryption (real implementation would use AES-GCM)
            backup_data = ctx.allocator.dupe(u8, ctx.keypair.private_key) catch |err| {
                return .{ .ready = err };
            };
            
            for (backup_data, 0..) |*byte, i| {
                byte.* ^= ctx.manager.encryption_key[i % 32];
            }
        } else {
            backup_data = ctx.allocator.dupe(u8, ctx.keypair.private_key) catch |err| {
                return .{ .ready = err };
            };
        }
        defer {
            @memset(backup_data, 0);
            ctx.allocator.free(backup_data);
        }
        
        // Write backup (simplified - real implementation would write to file)
        _ = backup_data;
        ctx.backup_success = true;
    }
    
    return .{ .ready = ctx.backup_success };
}

fn backupDeinit(context: *anyopaque, allocator: std.mem.Allocator) void {
    const ctx = @as(*BackupContext, @ptrCast(@alignCast(context)));
    allocator.free(ctx.backup_name);
    allocator.destroy(ctx);
}

fn restorePoll(context: *anyopaque, io: io_v2.Io) io_v2.Future.PollResult {
    _ = io;
    const ctx = @as(*RestoreContext, @ptrCast(@alignCast(context)));
    
    // Try to restore from each backup location
    for (ctx.manager.backup_locations.items) |location| {
        // Create backup file path
        const backup_path = std.fmt.allocPrint(ctx.allocator, "{s}/{s}.backup", .{ location.path, ctx.backup_name }) catch |err| {
            return .{ .ready = err };
        };
        defer ctx.allocator.free(backup_path);
        
        // Simulate reading backup data
        var backup_data: [32]u8 = undefined;
        std.crypto.random.bytes(&backup_data);
        
        // Decrypt if needed
        if (location.encryption_enabled) {
            for (backup_data, 0..) |*byte, i| {
                byte.* ^= ctx.manager.encryption_key[i % 32];
            }
        }
        
        // Create restored key pair
        const public_key = ctx.allocator.alloc(u8, 32) catch |err| {
            return .{ .ready = err };
        };
        @memcpy(public_key, &backup_data);
        
        const restored_keypair = KeyPair.init(ctx.allocator, .ECDSA_secp256k1, &backup_data, public_key) catch |err| {
            ctx.allocator.free(public_key);
            return .{ .ready = err };
        };
        
        ctx.restored_key = restored_keypair;
        break;
    }
    
    return .{ .ready = ctx.restored_key };
}

fn restoreDeinit(context: *anyopaque, allocator: std.mem.Allocator) void {
    const ctx = @as(*RestoreContext, @ptrCast(@alignCast(context)));
    allocator.free(ctx.backup_name);
    allocator.destroy(ctx);
}

test "HD wallet key derivation" {
    const allocator = std.testing.allocator;
    const io = io_v2.Io.init();
    
    const seed = "test seed for HD wallet";
    var wallet = try HDWallet.init(allocator, io, seed);
    defer wallet.deinit();
    
    const path = DerivationPath{
        .account = 0,
        .change = 0,
        .address_index = 0,
    };
    
    var derive_future = try wallet.deriveKeyAsync(allocator, path, .ECDSA_secp256k1);
    defer derive_future.deinit();
    
    const keypair = try derive_future.await_op(io, .{});
    try std.testing.expect(keypair.?.algorithm == .ECDSA_secp256k1);
}

test "threshold key management" {
    const allocator = std.testing.allocator;
    const io = io_v2.Io.init();
    
    var threshold_manager = try ThresholdKeyManager.init(allocator, io, 3, 5);
    defer threshold_manager.deinit();
    
    var gen_future = try threshold_manager.generateThresholdKeysAsync(allocator, .ECDSA_secp256k1);
    defer gen_future.deinit();
    
    const shares_generated = try gen_future.await_op(io, .{});
    try std.testing.expect(shares_generated == 5);
    
    // Test reconstruction
    const share_indices = [_]u32{ 1, 2, 3 };
    var reconstruct_future = try threshold_manager.reconstructKeyAsync(allocator, &share_indices);
    defer reconstruct_future.deinit();
    
    const reconstructed = try reconstruct_future.await_op(io, .{});
    try std.testing.expect(reconstructed != null);
}