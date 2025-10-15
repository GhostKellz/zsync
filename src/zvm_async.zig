const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const HashMap = std.HashMap;
const testing = std.testing;
const io = @import("io_v2.zig");
const crypto_async = @import("crypto_async.zig");

pub const VmError = error{
    InvalidBytecode,
    StackOverflow,
    StackUnderflow,
    InvalidOpcode,
    OutOfGas,
    InvalidJump,
    InvalidMemoryAccess,
    ExecutionReverted,
    ContractNotFound,
    InsufficientBalance,
    OutOfMemory,
    ExecutionTimeout,
};

pub const OpCode = enum(u8) {
    // Arithmetic operations
    STOP = 0x00,
    ADD = 0x01,
    MUL = 0x02,
    SUB = 0x03,
    DIV = 0x04,
    SDIV = 0x05,
    MOD = 0x06,
    SMOD = 0x07,
    ADDMOD = 0x08,
    MULMOD = 0x09,
    EXP = 0x0a,
    SIGNEXTEND = 0x0b,
    
    // Comparison operations
    LT = 0x10,
    GT = 0x11,
    SLT = 0x12,
    SGT = 0x13,
    EQ = 0x14,
    ISZERO = 0x15,
    AND = 0x16,
    OR = 0x17,
    XOR = 0x18,
    NOT = 0x19,
    BYTE = 0x1a,
    SHL = 0x1b,
    SHR = 0x1c,
    SAR = 0x1d,
    
    // SHA3
    SHA3 = 0x20,
    
    // Environment information
    ADDRESS = 0x30,
    BALANCE = 0x31,
    ORIGIN = 0x32,
    CALLER = 0x33,
    CALLVALUE = 0x34,
    CALLDATALOAD = 0x35,
    CALLDATASIZE = 0x36,
    CALLDATACOPY = 0x37,
    CODESIZE = 0x38,
    CODECOPY = 0x39,
    GASPRICE = 0x3a,
    EXTCODESIZE = 0x3b,
    EXTCODECOPY = 0x3c,
    RETURNDATASIZE = 0x3d,
    RETURNDATACOPY = 0x3e,
    EXTCODEHASH = 0x3f,
    
    // Block information
    BLOCKHASH = 0x40,
    COINBASE = 0x41,
    TIMESTAMP = 0x42,
    NUMBER = 0x43,
    DIFFICULTY = 0x44,
    GASLIMIT = 0x45,
    CHAINID = 0x46,
    SELFBALANCE = 0x47,
    BASEFEE = 0x48,
    
    // Stack, Memory, Storage and Flow operations
    POP = 0x50,
    MLOAD = 0x51,
    MSTORE = 0x52,
    MSTORE8 = 0x53,
    SLOAD = 0x54,
    SSTORE = 0x55,
    JUMP = 0x56,
    JUMPI = 0x57,
    PC = 0x58,
    MSIZE = 0x59,
    GAS = 0x5a,
    JUMPDEST = 0x5b,
    
    // Push operations
    PUSH1 = 0x60,
    PUSH2 = 0x61,
    PUSH3 = 0x62,
    PUSH4 = 0x63,
    PUSH5 = 0x64,
    PUSH6 = 0x65,
    PUSH7 = 0x66,
    PUSH8 = 0x67,
    PUSH9 = 0x68,
    PUSH10 = 0x69,
    PUSH11 = 0x6a,
    PUSH12 = 0x6b,
    PUSH13 = 0x6c,
    PUSH14 = 0x6d,
    PUSH15 = 0x6e,
    PUSH16 = 0x6f,
    PUSH17 = 0x70,
    PUSH18 = 0x71,
    PUSH19 = 0x72,
    PUSH20 = 0x73,
    PUSH21 = 0x74,
    PUSH22 = 0x75,
    PUSH23 = 0x76,
    PUSH24 = 0x77,
    PUSH25 = 0x78,
    PUSH26 = 0x79,
    PUSH27 = 0x7a,
    PUSH28 = 0x7b,
    PUSH29 = 0x7c,
    PUSH30 = 0x7d,
    PUSH31 = 0x7e,
    PUSH32 = 0x7f,
    
    // Duplicate operations
    DUP1 = 0x80,
    DUP2 = 0x81,
    DUP3 = 0x82,
    DUP4 = 0x83,
    DUP5 = 0x84,
    DUP6 = 0x85,
    DUP7 = 0x86,
    DUP8 = 0x87,
    DUP9 = 0x88,
    DUP10 = 0x89,
    DUP11 = 0x8a,
    DUP12 = 0x8b,
    DUP13 = 0x8c,
    DUP14 = 0x8d,
    DUP15 = 0x8e,
    DUP16 = 0x8f,
    
    // Exchange operations
    SWAP1 = 0x90,
    SWAP2 = 0x91,
    SWAP3 = 0x92,
    SWAP4 = 0x93,
    SWAP5 = 0x94,
    SWAP6 = 0x95,
    SWAP7 = 0x96,
    SWAP8 = 0x97,
    SWAP9 = 0x98,
    SWAP10 = 0x99,
    SWAP11 = 0x9a,
    SWAP12 = 0x9b,
    SWAP13 = 0x9c,
    SWAP14 = 0x9d,
    SWAP15 = 0x9e,
    SWAP16 = 0x9f,
    
    // Logging operations
    LOG0 = 0xa0,
    LOG1 = 0xa1,
    LOG2 = 0xa2,
    LOG3 = 0xa3,
    LOG4 = 0xa4,
    
    // System operations
    CREATE = 0xf0,
    CALL = 0xf1,
    CALLCODE = 0xf2,
    RETURN = 0xf3,
    DELEGATECALL = 0xf4,
    CREATE2 = 0xf5,
    STATICCALL = 0xfa,
    REVERT = 0xfd,
    INVALID = 0xfe,
    SELFDESTRUCT = 0xff,
};

pub const ExecutionState = enum {
    running,
    suspended,
    completed,
    reverted,
    error_state,
};

pub const VmStack = struct {
    items: ArrayList(u256),
    max_size: usize,
    
    const Self = @This();
    
    pub fn init(allocator: Allocator, max_size: usize) Self {
        return Self{
            .items = ArrayList(u256){ .allocator = allocator },
            .max_size = max_size,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.items.deinit();
    }
    
    pub fn push(self: *Self, value: u256) !void {
        if (self.items.items.len >= self.max_size) {
            return VmError.StackOverflow;
        }
        try self.items.append(self.allocator, value);
    }
    
    pub fn pop(self: *Self) !u256 {
        return self.items.popOrNull() orelse VmError.StackUnderflow;
    }
    
    pub fn peek(self: *Self, index: usize) !u256 {
        if (index >= self.items.items.len) {
            return VmError.StackUnderflow;
        }
        return self.items.items[self.items.items.len - 1 - index];
    }
    
    pub fn set(self: *Self, index: usize, value: u256) !void {
        if (index >= self.items.items.len) {
            return VmError.StackUnderflow;
        }
        self.items.items[self.items.items.len - 1 - index] = value;
    }
    
    pub fn size(self: *Self) usize {
        return self.items.items.len;
    }
    
    pub fn dup(self: *Self, index: usize) !void {
        const value = try self.peek(index);
        try self.push(value);
    }
    
    pub fn swap(self: *Self, index: usize) !void {
        if (index >= self.items.items.len or self.items.items.len == 0) {
            return VmError.StackUnderflow;
        }
        
        const top_index = self.items.items.len - 1;
        const swap_index = top_index - index;
        
        const temp = self.items.items[top_index];
        self.items.items[top_index] = self.items.items[swap_index];
        self.items.items[swap_index] = temp;
    }
};

pub const VmMemory = struct {
    data: ArrayList(u8),
    
    const Self = @This();
    
    pub fn init(allocator: Allocator) Self {
        return Self{
            .data = ArrayList(u8){ .allocator = allocator },
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.data.deinit();
    }
    
    pub fn expand(self: *Self, size: usize) !void {
        if (size > self.data.items.len) {
            try self.data.resize(size);
            // Zero out new memory
            @memset(self.data.items[self.data.items.len..size], 0);
        }
    }
    
    pub fn store(self: *Self, offset: usize, value: u256) !void {
        const required_size = offset + 32;
        try self.expand(required_size);
        
        // Store value in big-endian format
        var bytes: [32]u8 = undefined;
        std.mem.writeInt(u256, &bytes, value, .big);
        @memcpy(self.data.items[offset..offset + 32], &bytes);
    }
    
    pub fn store8(self: *Self, offset: usize, value: u8) !void {
        const required_size = offset + 1;
        try self.expand(required_size);
        self.data.items[offset] = value;
    }
    
    pub fn load(self: *Self, offset: usize) !u256 {
        const required_size = offset + 32;
        try self.expand(required_size);
        
        var bytes: [32]u8 = undefined;
        @memcpy(&bytes, self.data.items[offset..offset + 32]);
        return std.mem.readInt(u256, &bytes, .big);
    }
    
    pub fn size(self: *Self) usize {
        return self.data.items.len;
    }
    
    pub fn copy(self: *Self, dest_offset: usize, src_offset: usize, length: usize) !void {
        const required_size = @max(dest_offset + length, src_offset + length);
        try self.expand(required_size);
        
        std.mem.copyForwards(u8, self.data.items[dest_offset..dest_offset + length], self.data.items[src_offset..src_offset + length]);
    }
    
    pub fn copyFrom(self: *Self, dest_offset: usize, src: []const u8) !void {
        const required_size = dest_offset + src.len;
        try self.expand(required_size);
        @memcpy(self.data.items[dest_offset..dest_offset + src.len], src);
    }
};

pub const VmStorage = struct {
    data: HashMap(u256, u256, std.hash_map.AutoContext(u256), std.hash_map.default_max_load_percentage),
    
    const Self = @This();
    
    pub fn init(allocator: Allocator) Self {
        return Self{
            .data = HashMap(u256, u256, std.hash_map.AutoContext(u256), std.hash_map.default_max_load_percentage).init(allocator),
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.data.deinit();
    }
    
    pub fn store(self: *Self, key: u256, value: u256) !void {
        try self.data.put(key, value);
    }
    
    pub fn load(self: *Self, key: u256) u256 {
        return self.data.get(key) orelse 0;
    }
};

pub const ExecutionContext = struct {
    address: [20]u8,
    caller: [20]u8,
    origin: [20]u8,
    gas_price: u256,
    call_value: u256,
    call_data: []const u8,
    block_number: u64,
    block_timestamp: u64,
    block_hash: [32]u8,
    chain_id: u64,
    gas_limit: u64,
    base_fee: u256,
    
    pub fn init() ExecutionContext {
        return ExecutionContext{
            .address = [_]u8{0} ** 20,
            .caller = [_]u8{0} ** 20,
            .origin = [_]u8{0} ** 20,
            .gas_price = 0,
            .call_value = 0,
            .call_data = &[_]u8{},
            .block_number = 0,
            .block_timestamp = 0,
            .block_hash = [_]u8{0} ** 32,
            .chain_id = 1,
            .gas_limit = 30000000,
            .base_fee = 0,
        };
    }
};

pub const GasTracker = struct {
    gas_used: u64,
    gas_limit: u64,
    gas_refund: u64,
    
    const Self = @This();
    
    pub fn init(gas_limit: u64) Self {
        return Self{
            .gas_used = 0,
            .gas_limit = gas_limit,
            .gas_refund = 0,
        };
    }
    
    pub fn consumeGas(self: *Self, amount: u64) !void {
        if (self.gas_used + amount > self.gas_limit) {
            return VmError.OutOfGas;
        }
        self.gas_used += amount;
    }
    
    pub fn refundGas(self: *Self, amount: u64) void {
        self.gas_refund += amount;
    }
    
    pub fn remainingGas(self: *Self) u64 {
        return self.gas_limit - self.gas_used;
    }
    
    pub fn totalRefund(self: *Self) u64 {
        // EIP-3529: Maximum refund is gas_used / 5
        return @min(self.gas_refund, self.gas_used / 5);
    }
};

pub const AsyncVmExecutor = struct {
    allocator: Allocator,
    bytecode: []const u8,
    pc: usize,
    stack: VmStack,
    memory: VmMemory,
    storage: VmStorage,
    context: ExecutionContext,
    gas_tracker: GasTracker,
    return_data: ArrayList(u8),
    state: ExecutionState,
    suspend_points: ArrayList(usize),
    execution_limit: usize,
    instructions_executed: usize,
    
    const Self = @This();
    
    pub fn init(allocator: Allocator, bytecode: []const u8, context: ExecutionContext, gas_limit: u64) Self {
        return Self{
            .allocator = allocator,
            .bytecode = bytecode,
            .pc = 0,
            .stack = VmStack.init(allocator, 1024),
            .memory = VmMemory.init(allocator),
            .storage = VmStorage.init(allocator),
            .context = context,
            .gas_tracker = GasTracker.init(gas_limit),
            .return_data = ArrayList(u8){ .allocator = allocator },
            .state = ExecutionState.running,
            .suspend_points = ArrayList(usize){ .allocator = allocator },
            .execution_limit = 10000, // Instructions per execution slice
            .instructions_executed = 0,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.stack.deinit();
        self.memory.deinit();
        self.storage.deinit();
        self.return_data.deinit();
        self.suspend_points.deinit();
    }
    
    pub fn executeAsync(self: *Self, io_context: *io.Io) !ExecutionState {
        _ = io_context; // Will be used for async operations
        
        self.state = ExecutionState.running;
        self.instructions_executed = 0;
        
        while (self.state == ExecutionState.running and self.pc < self.bytecode.len and self.instructions_executed < self.execution_limit) {
            try self.executeInstruction();
            self.instructions_executed += 1;
            
            // Check for async suspend point
            if (self.shouldSuspend()) {
                self.state = ExecutionState.suspended;
                try self.suspend_points.append(self.allocator, self.pc);
                break;
            }
        }
        
        if (self.pc >= self.bytecode.len and self.state == ExecutionState.running) {
            self.state = ExecutionState.completed;
        }
        
        return self.state;
    }
    
    fn shouldSuspend(self: *Self) bool {
        // Suspend execution at regular intervals to allow async I/O
        return self.instructions_executed >= self.execution_limit;
    }
    
    pub fn resume(self: *Self) void {
        if (self.state == ExecutionState.suspended) {
            self.state = ExecutionState.running;
            self.instructions_executed = 0;
        }
    }
    
    fn executeInstruction(self: *Self) !void {
        if (self.pc >= self.bytecode.len) {
            return VmError.InvalidBytecode;
        }
        
        const opcode_byte = self.bytecode[self.pc];
        const opcode = @as(OpCode, @enumFromInt(opcode_byte));
        
        // Basic gas cost (simplified)
        try self.gas_tracker.consumeGas(3);
        
        switch (opcode) {
            .STOP => {
                self.state = ExecutionState.completed;
                return;
            },
            .ADD => {
                const a = try self.stack.pop();
                const b = try self.stack.pop();
                const result = a +% b; // Wrapping add for overflow
                try self.stack.push(result);
                self.pc += 1;
            },
            .MUL => {
                const a = try self.stack.pop();
                const b = try self.stack.pop();
                const result = a *% b; // Wrapping mul for overflow
                try self.stack.push(result);
                self.pc += 1;
            },
            .SUB => {
                const a = try self.stack.pop();
                const b = try self.stack.pop();
                const result = a -% b; // Wrapping sub for underflow
                try self.stack.push(result);
                self.pc += 1;
            },
            .DIV => {
                const a = try self.stack.pop();
                const b = try self.stack.pop();
                const result = if (b == 0) 0 else a / b;
                try self.stack.push(result);
                self.pc += 1;
            },
            .MOD => {
                const a = try self.stack.pop();
                const b = try self.stack.pop();
                const result = if (b == 0) 0 else a % b;
                try self.stack.push(result);
                self.pc += 1;
            },
            .LT => {
                const a = try self.stack.pop();
                const b = try self.stack.pop();
                const result: u256 = if (a < b) 1 else 0;
                try self.stack.push(result);
                self.pc += 1;
            },
            .GT => {
                const a = try self.stack.pop();
                const b = try self.stack.pop();
                const result: u256 = if (a > b) 1 else 0;
                try self.stack.push(result);
                self.pc += 1;
            },
            .EQ => {
                const a = try self.stack.pop();
                const b = try self.stack.pop();
                const result: u256 = if (a == b) 1 else 0;
                try self.stack.push(result);
                self.pc += 1;
            },
            .ISZERO => {
                const a = try self.stack.pop();
                const result: u256 = if (a == 0) 1 else 0;
                try self.stack.push(result);
                self.pc += 1;
            },
            .AND => {
                const a = try self.stack.pop();
                const b = try self.stack.pop();
                try self.stack.push(a & b);
                self.pc += 1;
            },
            .OR => {
                const a = try self.stack.pop();
                const b = try self.stack.pop();
                try self.stack.push(a | b);
                self.pc += 1;
            },
            .XOR => {
                const a = try self.stack.pop();
                const b = try self.stack.pop();
                try self.stack.push(a ^ b);
                self.pc += 1;
            },
            .NOT => {
                const a = try self.stack.pop();
                try self.stack.push(~a);
                self.pc += 1;
            },
            .POP => {
                _ = try self.stack.pop();
                self.pc += 1;
            },
            .MLOAD => {
                const offset = try self.stack.pop();
                if (offset > std.math.maxInt(usize)) return VmError.InvalidMemoryAccess;
                const value = try self.memory.load(@truncate(offset));
                try self.stack.push(value);
                self.pc += 1;
            },
            .MSTORE => {
                const offset = try self.stack.pop();
                const value = try self.stack.pop();
                if (offset > std.math.maxInt(usize)) return VmError.InvalidMemoryAccess;
                try self.memory.store(@truncate(offset), value);
                self.pc += 1;
            },
            .MSTORE8 => {
                const offset = try self.stack.pop();
                const value = try self.stack.pop();
                if (offset > std.math.maxInt(usize)) return VmError.InvalidMemoryAccess;
                try self.memory.store8(@truncate(offset), @truncate(value));
                self.pc += 1;
            },
            .SLOAD => {
                const key = try self.stack.pop();
                const value = self.storage.load(key);
                try self.stack.push(value);
                self.pc += 1;
            },
            .SSTORE => {
                const key = try self.stack.pop();
                const value = try self.stack.pop();
                try self.storage.store(key, value);
                self.pc += 1;
            },
            .JUMP => {
                const dest = try self.stack.pop();
                if (dest > std.math.maxInt(usize)) return VmError.InvalidJump;
                const dest_pc = @as(usize, @truncate(dest));
                if (dest_pc >= self.bytecode.len) return VmError.InvalidJump;
                if (self.bytecode[dest_pc] != @intFromEnum(OpCode.JUMPDEST)) return VmError.InvalidJump;
                self.pc = dest_pc;
            },
            .JUMPI => {
                const dest = try self.stack.pop();
                const condition = try self.stack.pop();
                if (condition != 0) {
                    if (dest > std.math.maxInt(usize)) return VmError.InvalidJump;
                    const dest_pc = @as(usize, @truncate(dest));
                    if (dest_pc >= self.bytecode.len) return VmError.InvalidJump;
                    if (self.bytecode[dest_pc] != @intFromEnum(OpCode.JUMPDEST)) return VmError.InvalidJump;
                    self.pc = dest_pc;
                } else {
                    self.pc += 1;
                }
            },
            .PC => {
                try self.stack.push(self.pc);
                self.pc += 1;
            },
            .MSIZE => {
                try self.stack.push(self.memory.size());
                self.pc += 1;
            },
            .GAS => {
                try self.stack.push(self.gas_tracker.remainingGas());
                self.pc += 1;
            },
            .JUMPDEST => {
                // Valid jump destination, just continue
                self.pc += 1;
            },
            .PUSH1...PUSH32 => {
                const push_size = (@intFromEnum(opcode) - @intFromEnum(OpCode.PUSH1)) + 1;
                if (self.pc + push_size >= self.bytecode.len) return VmError.InvalidBytecode;
                
                var value: u256 = 0;
                for (0..push_size) |i| {
                    value = (value << 8) | self.bytecode[self.pc + 1 + i];
                }
                
                try self.stack.push(value);
                self.pc += 1 + push_size;
            },
            .DUP1...DUP16 => {
                const dup_index = (@intFromEnum(opcode) - @intFromEnum(OpCode.DUP1));
                try self.stack.dup(dup_index);
                self.pc += 1;
            },
            .SWAP1...SWAP16 => {
                const swap_index = (@intFromEnum(opcode) - @intFromEnum(OpCode.SWAP1)) + 1;
                try self.stack.swap(swap_index);
                self.pc += 1;
            },
            .RETURN => {
                const offset = try self.stack.pop();
                const length = try self.stack.pop();
                
                if (offset > std.math.maxInt(usize) or length > std.math.maxInt(usize)) {
                    return VmError.InvalidMemoryAccess;
                }
                
                const offset_usize = @as(usize, @truncate(offset));
                const length_usize = @as(usize, @truncate(length));
                
                try self.memory.expand(offset_usize + length_usize);
                
                self.return_data.clearRetainingCapacity();
                try self.return_data.appendSlice(self.memory.data.items[offset_usize..offset_usize + length_usize]);
                
                self.state = ExecutionState.completed;
                return;
            },
            .REVERT => {
                const offset = try self.stack.pop();
                const length = try self.stack.pop();
                
                if (offset > std.math.maxInt(usize) or length > std.math.maxInt(usize)) {
                    return VmError.InvalidMemoryAccess;
                }
                
                const offset_usize = @as(usize, @truncate(offset));
                const length_usize = @as(usize, @truncate(length));
                
                try self.memory.expand(offset_usize + length_usize);
                
                self.return_data.clearRetainingCapacity();
                try self.return_data.appendSlice(self.memory.data.items[offset_usize..offset_usize + length_usize]);
                
                self.state = ExecutionState.reverted;
                return;
            },
            .ADDRESS => {
                var address_u256: u256 = 0;
                for (self.context.address) |byte| {
                    address_u256 = (address_u256 << 8) | byte;
                }
                try self.stack.push(address_u256);
                self.pc += 1;
            },
            .CALLER => {
                var caller_u256: u256 = 0;
                for (self.context.caller) |byte| {
                    caller_u256 = (caller_u256 << 8) | byte;
                }
                try self.stack.push(caller_u256);
                self.pc += 1;
            },
            .CALLVALUE => {
                try self.stack.push(self.context.call_value);
                self.pc += 1;
            },
            .CALLDATASIZE => {
                try self.stack.push(self.context.call_data.len);
                self.pc += 1;
            },
            .GASPRICE => {
                try self.stack.push(self.context.gas_price);
                self.pc += 1;
            },
            .TIMESTAMP => {
                try self.stack.push(self.context.block_timestamp);
                self.pc += 1;
            },
            .NUMBER => {
                try self.stack.push(self.context.block_number);
                self.pc += 1;
            },
            .GASLIMIT => {
                try self.stack.push(self.context.gas_limit);
                self.pc += 1;
            },
            .CHAINID => {
                try self.stack.push(self.context.chain_id);
                self.pc += 1;
            },
            else => {
                // Unsupported opcode
                return VmError.InvalidOpcode;
            },
        }
    }
    
    pub fn getReturnData(self: *Self) []const u8 {
        return self.return_data.items;
    }
    
    pub fn getState(self: *Self) ExecutionState {
        return self.state;
    }
    
    pub fn getGasUsed(self: *Self) u64 {
        return self.gas_tracker.gas_used;
    }
    
    pub fn getRemainingGas(self: *Self) u64 {
        return self.gas_tracker.remainingGas();
    }
};

// Async execution coordinator
pub const AsyncVmCoordinator = struct {
    allocator: Allocator,
    executors: ArrayList(*AsyncVmExecutor),
    execution_queue: ArrayList(*AsyncVmExecutor),
    completed_executions: ArrayList(*AsyncVmExecutor),
    max_concurrent_executions: usize,
    
    const Self = @This();
    
    pub fn init(allocator: Allocator, max_concurrent: usize) Self {
        return Self{
            .allocator = allocator,
            .executors = ArrayList(*AsyncVmExecutor){ .allocator = allocator },
            .execution_queue = ArrayList(*AsyncVmExecutor){ .allocator = allocator },
            .completed_executions = ArrayList(*AsyncVmExecutor){ .allocator = allocator },
            .max_concurrent_executions = max_concurrent,
        };
    }
    
    pub fn deinit(self: *Self) void {
        for (self.executors.items) |executor| {
            executor.deinit();
            self.allocator.destroy(executor);
        }
        self.executors.deinit();
        self.execution_queue.deinit();
        self.completed_executions.deinit();
    }
    
    pub fn submitExecution(self: *Self, bytecode: []const u8, context: ExecutionContext, gas_limit: u64) !*AsyncVmExecutor {
        const executor = try self.allocator.create(AsyncVmExecutor);
        executor.* = AsyncVmExecutor.init(self.allocator, bytecode, context, gas_limit);
        
        try self.executors.append(self.allocator, executor);
        try self.execution_queue.append(self.allocator, executor);
        
        return executor;
    }
    
    pub fn processExecutionsAsync(self: *Self, io_context: *io.Io) !usize {
        var processed: usize = 0;
        var concurrent_count: usize = 0;
        
        var i: usize = 0;
        while (i < self.execution_queue.items.len and concurrent_count < self.max_concurrent_executions) {
            const executor = self.execution_queue.items[i];
            
            const result = try executor.executeAsync(io_context);
            
            switch (result) {
                .completed, .reverted, .error_state => {
                    try self.completed_executions.append(self.allocator, executor);
                    _ = self.execution_queue.swapRemove(i);
                    processed += 1;
                },
                .suspended => {
                    // Resume on next iteration
                    executor.resume();
                    i += 1;
                    concurrent_count += 1;
                },
                .running => {
                    i += 1;
                    concurrent_count += 1;
                },
            }
        }
        
        return processed;
    }
    
    pub fn getCompletedExecutions(self: *Self) []const *AsyncVmExecutor {
        return self.completed_executions.items;
    }
    
    pub fn getPendingExecutions(self: *Self) []const *AsyncVmExecutor {
        return self.execution_queue.items;
    }
};

// Example usage and testing
test "VM stack operations" {
    var stack = VmStack.init(testing.allocator, 1024);
    defer stack.deinit();
    
    try stack.push(42);
    try stack.push(100);
    
    try testing.expect(stack.size() == 2);
    
    const value = try stack.pop();
    try testing.expect(value == 100);
    
    const peeked = try stack.peek(0);
    try testing.expect(peeked == 42);
}

test "VM memory operations" {
    var memory = VmMemory.init(testing.allocator);
    defer memory.deinit();
    
    try memory.store(0, 0x1234567890abcdef);
    const loaded = try memory.load(0);
    
    try testing.expect(loaded == 0x1234567890abcdef);
}

test "Basic bytecode execution" {
    var context = ExecutionContext.init();
    
    // Simple bytecode: PUSH1 42, PUSH1 10, ADD, RETURN
    const bytecode = [_]u8{ 0x60, 42, 0x60, 10, 0x01, 0x60, 0, 0x60, 32, 0xf3 };
    
    var executor = AsyncVmExecutor.init(testing.allocator, &bytecode, context, 1000000);
    defer executor.deinit();
    
    // This would require a real I/O context in practice
    // const state = try executor.executeAsync(&io_context);
    // try testing.expect(state == ExecutionState.completed);
}

test "VM coordinator" {
    var coordinator = AsyncVmCoordinator.init(testing.allocator, 4);
    defer coordinator.deinit();
    
    var context = ExecutionContext.init();
    const bytecode = [_]u8{ 0x60, 42, 0x00 }; // PUSH1 42, STOP
    
    const executor = try coordinator.submitExecution(&bytecode, context, 1000000);
    
    try testing.expect(coordinator.getPendingExecutions().len == 1);
    try testing.expect(executor.getState() == ExecutionState.running);
}