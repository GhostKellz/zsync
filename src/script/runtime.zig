//! zsync Script Runtime Integration
//! Helpers for integrating Ghostlang and other script engines with zsync async

const std = @import("std");
const compat = @import("../compat/thread.zig");
const Runtime = @import("../std_runtime.zig").Runtime;
const channels = @import("../channels.zig");

/// Script Value Types
pub const ScriptValue = union(enum) {
    nil,
    boolean: bool,
    number: f64,
    string: []const u8,
    function: *anyopaque,
    object: *anyopaque,
    array: []ScriptValue,
    userdata: *anyopaque,

    pub fn fromBool(b: bool) ScriptValue {
        return .{ .boolean = b };
    }

    pub fn fromNumber(n: f64) ScriptValue {
        return .{ .number = n };
    }

    pub fn fromString(s: []const u8) ScriptValue {
        return .{ .string = s };
    }

    pub fn isNil(self: ScriptValue) bool {
        return self == .nil;
    }

    pub fn toBool(self: ScriptValue) bool {
        return switch (self) {
            .nil => false,
            .boolean => |b| b,
            .number => |n| n != 0.0,
            .string => |s| s.len > 0,
            else => true,
        };
    }

    pub fn toNumber(self: ScriptValue) ?f64 {
        return switch (self) {
            .number => |n| n,
            .boolean => |b| if (b) 1.0 else 0.0,
            else => null,
        };
    }
};

/// Script Engine Interface
pub const ScriptEngine = struct {
    allocator: std.mem.Allocator,
    runtime: *Runtime,
    global_env: std.StringHashMap(ScriptValue),
    /// Backing storage for string values produced by scripts (e.g. assigned
    /// to globals). Freed wholesale on `deinit`.
    value_arena: std.heap.ArenaAllocator,
    mutex: compat.Mutex,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, runtime: *Runtime) Self {
        return Self{
            .allocator = allocator,
            .runtime = runtime,
            .global_env = std.StringHashMap(ScriptValue).init(allocator),
            .value_arena = std.heap.ArenaAllocator.init(allocator),
            .mutex = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.global_env.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.global_env.deinit();
        self.value_arena.deinit();
    }

    /// Evaluate `code` and return the value of its final expression. Globals
    /// referenced or assigned by the script are read from and written to this
    /// engine's environment. String results are owned by `task`'s arena.
    pub fn eval(self: *Self, task: *AsyncScriptTask) !ScriptValue {
        var interp = Interpreter{
            .src = task.code,
            .engine = self,
            .scratch = task.arena.allocator(),
        };
        return interp.run();
    }

    /// Set global variable
    pub fn setGlobal(self: *Self, name: []const u8, value: ScriptValue) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const owned_name = try self.allocator.dupe(u8, name);
        try self.global_env.put(owned_name, value);
    }

    /// Get global variable
    pub fn getGlobal(self: *Self, name: []const u8) ?ScriptValue {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.global_env.get(name);
    }

    /// Register Zig function callable from script
    pub fn registerFunction(
        self: *Self,
        name: []const u8,
        func: *const fn ([]const ScriptValue) ScriptValue,
    ) !void {
        _ = func;
        const owned_name = try self.allocator.dupe(u8, name);
        try self.global_env.put(owned_name, .{ .function = @ptrFromInt(1) });
    }
};

/// A small tree-walking interpreter for a self-contained expression language.
///
/// Supported syntax:
///   - Literals: numbers, double-quoted strings, `true`, `false`, `nil`
///   - Variables: identifiers resolve against the engine's global environment
///   - Assignment: `let x = expr` or `x = expr`
///   - Arithmetic: `+ - * / %` (with `+` concatenating two strings)
///   - Comparison: `== != < <= > >=`
///   - Logic: `and`/`&&`, `or`/`||`, `not`/`!`
///   - Grouping: `( ... )`
///   - Statements separated by `;`; the final statement's value is returned.
///   - Line comments begin with `#`.
const Interpreter = struct {
    src: []const u8,
    engine: *ScriptEngine,
    /// Arena for temporary and returned string allocations.
    scratch: std.mem.Allocator,
    tokens: []const Token = &.{},
    tp: usize = 0,

    const Error = error{
        SyntaxError,
        UnknownVariable,
        TypeError,
        DivisionByZero,
        OutOfMemory,
        InvalidNumber,
    };

    const Token = union(enum) {
        number: f64,
        string: []const u8,
        identifier: []const u8,
        kw_true,
        kw_false,
        kw_nil,
        kw_let,
        kw_and,
        kw_or,
        kw_not,
        plus,
        minus,
        star,
        slash,
        percent,
        eq,
        neq,
        lt,
        lte,
        gt,
        gte,
        assign,
        lparen,
        rparen,
        semicolon,
        eof,

        fn tag(self: Token) std.meta.Tag(Token) {
            return std.meta.activeTag(self);
        }
    };

    fn run(self: *Interpreter) Error!ScriptValue {
        self.tokens = try self.tokenize();
        self.tp = 0;

        var last: ScriptValue = .nil;
        while (self.peek().tag() != .eof) {
            last = try self.statement();
            while (self.peek().tag() == .semicolon) _ = self.advance();
        }
        return last;
    }

    // --- Lexer ---

    fn tokenize(self: *Interpreter) Error![]const Token {
        var list: std.ArrayList(Token) = .empty;
        var i: usize = 0;
        const s = self.src;

        while (i < s.len) {
            const c = s[i];

            // Whitespace
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
                i += 1;
                continue;
            }
            // Line comment
            if (c == '#') {
                while (i < s.len and s[i] != '\n') i += 1;
                continue;
            }
            // Number
            if (std.ascii.isDigit(c) or (c == '.' and i + 1 < s.len and std.ascii.isDigit(s[i + 1]))) {
                const start = i;
                while (i < s.len and (std.ascii.isDigit(s[i]) or s[i] == '.')) i += 1;
                const n = std.fmt.parseFloat(f64, s[start..i]) catch return error.InvalidNumber;
                try list.append(self.scratch, .{ .number = n });
                continue;
            }
            // String literal
            if (c == '"') {
                i += 1;
                const start = i;
                while (i < s.len and s[i] != '"') i += 1;
                if (i >= s.len) return error.SyntaxError;
                try list.append(self.scratch, .{ .string = s[start..i] });
                i += 1; // closing quote
                continue;
            }
            // Identifier or keyword
            if (std.ascii.isAlphabetic(c) or c == '_') {
                const start = i;
                while (i < s.len and (std.ascii.isAlphanumeric(s[i]) or s[i] == '_')) i += 1;
                const word = s[start..i];
                try list.append(self.scratch, keywordOrIdent(word));
                continue;
            }
            // Operators
            const two: ?Token = if (i + 1 < s.len) twoCharOp(s[i], s[i + 1]) else null;
            if (two) |tok| {
                try list.append(self.scratch, tok);
                i += 2;
                continue;
            }
            const one = oneCharOp(c) orelse return error.SyntaxError;
            try list.append(self.scratch, one);
            i += 1;
        }

        try list.append(self.scratch, .eof);
        return list.toOwnedSlice(self.scratch);
    }

    fn keywordOrIdent(word: []const u8) Token {
        const map = .{
            .{ "true", Token.kw_true },
            .{ "false", Token.kw_false },
            .{ "nil", Token.kw_nil },
            .{ "let", Token.kw_let },
            .{ "and", Token.kw_and },
            .{ "or", Token.kw_or },
            .{ "not", Token.kw_not },
        };
        inline for (map) |entry| {
            if (std.mem.eql(u8, word, entry[0])) return entry[1];
        }
        return .{ .identifier = word };
    }

    fn twoCharOp(a: u8, b: u8) ?Token {
        return switch (a) {
            '=' => if (b == '=') .eq else null,
            '!' => if (b == '=') .neq else null,
            '<' => if (b == '=') .lte else null,
            '>' => if (b == '=') .gte else null,
            '&' => if (b == '&') .kw_and else null,
            '|' => if (b == '|') .kw_or else null,
            else => null,
        };
    }

    fn oneCharOp(c: u8) ?Token {
        return switch (c) {
            '+' => .plus,
            '-' => .minus,
            '*' => .star,
            '/' => .slash,
            '%' => .percent,
            '<' => .lt,
            '>' => .gt,
            '=' => .assign,
            '!' => .kw_not,
            '(' => .lparen,
            ')' => .rparen,
            ';' => .semicolon,
            else => null,
        };
    }

    // --- Parser / evaluator ---

    fn peek(self: *Interpreter) Token {
        return self.tokens[self.tp];
    }

    fn peekAt(self: *Interpreter, n: usize) Token {
        const idx = self.tp + n;
        if (idx >= self.tokens.len) return .eof;
        return self.tokens[idx];
    }

    fn advance(self: *Interpreter) Token {
        const t = self.tokens[self.tp];
        if (t.tag() != .eof) self.tp += 1;
        return t;
    }

    fn statement(self: *Interpreter) Error!ScriptValue {
        // `let name = expr`
        if (self.peek().tag() == .kw_let) {
            _ = self.advance();
            const name_tok = self.advance();
            if (name_tok.tag() != .identifier) return error.SyntaxError;
            if (self.advance().tag() != .assign) return error.SyntaxError;
            const value = try self.expression();
            try self.storeGlobal(name_tok.identifier, value);
            return value;
        }
        // `name = expr`
        if (self.peek().tag() == .identifier and self.peekAt(1).tag() == .assign) {
            const name_tok = self.advance();
            _ = self.advance(); // `=`
            const value = try self.expression();
            try self.storeGlobal(name_tok.identifier, value);
            return value;
        }
        return self.expression();
    }

    fn storeGlobal(self: *Interpreter, name: []const u8, value: ScriptValue) Error!void {
        // String values must outlive the task arena, so copy them into the
        // engine's value arena before storing.
        const stored = switch (value) {
            .string => |str| ScriptValue{ .string = try self.engine.value_arena.allocator().dupe(u8, str) },
            else => value,
        };
        self.engine.setGlobal(name, stored) catch return error.OutOfMemory;
    }

    fn expression(self: *Interpreter) Error!ScriptValue {
        return self.logicalOr();
    }

    fn logicalOr(self: *Interpreter) Error!ScriptValue {
        var left = try self.logicalAnd();
        while (self.peek().tag() == .kw_or) {
            _ = self.advance();
            const right = try self.logicalAnd();
            left = ScriptValue.fromBool(left.toBool() or right.toBool());
        }
        return left;
    }

    fn logicalAnd(self: *Interpreter) Error!ScriptValue {
        var left = try self.equality();
        while (self.peek().tag() == .kw_and) {
            _ = self.advance();
            const right = try self.equality();
            left = ScriptValue.fromBool(left.toBool() and right.toBool());
        }
        return left;
    }

    fn equality(self: *Interpreter) Error!ScriptValue {
        var left = try self.comparison();
        while (true) {
            const op = self.peek().tag();
            if (op != .eq and op != .neq) break;
            _ = self.advance();
            const right = try self.comparison();
            const equal = valuesEqual(left, right);
            left = ScriptValue.fromBool(if (op == .eq) equal else !equal);
        }
        return left;
    }

    fn comparison(self: *Interpreter) Error!ScriptValue {
        var left = try self.term();
        while (true) {
            const op = self.peek().tag();
            if (op != .lt and op != .lte and op != .gt and op != .gte) break;
            _ = self.advance();
            const right = try self.term();
            const a = try asNumber(left);
            const b = try asNumber(right);
            left = ScriptValue.fromBool(switch (op) {
                .lt => a < b,
                .lte => a <= b,
                .gt => a > b,
                .gte => a >= b,
                else => unreachable,
            });
        }
        return left;
    }

    fn term(self: *Interpreter) Error!ScriptValue {
        var left = try self.factor();
        while (true) {
            const op = self.peek().tag();
            if (op != .plus and op != .minus) break;
            _ = self.advance();
            const right = try self.factor();
            if (op == .plus and left == .string and right == .string) {
                left = .{ .string = try std.mem.concat(self.scratch, u8, &.{ left.string, right.string }) };
            } else {
                const a = try asNumber(left);
                const b = try asNumber(right);
                left = ScriptValue.fromNumber(if (op == .plus) a + b else a - b);
            }
        }
        return left;
    }

    fn factor(self: *Interpreter) Error!ScriptValue {
        var left = try self.unary();
        while (true) {
            const op = self.peek().tag();
            if (op != .star and op != .slash and op != .percent) break;
            _ = self.advance();
            const right = try self.unary();
            const a = try asNumber(left);
            const b = try asNumber(right);
            switch (op) {
                .star => left = ScriptValue.fromNumber(a * b),
                .slash => {
                    if (b == 0) return error.DivisionByZero;
                    left = ScriptValue.fromNumber(a / b);
                },
                .percent => {
                    if (b == 0) return error.DivisionByZero;
                    left = ScriptValue.fromNumber(@rem(a, b));
                },
                else => unreachable,
            }
        }
        return left;
    }

    fn unary(self: *Interpreter) Error!ScriptValue {
        const op = self.peek().tag();
        if (op == .minus) {
            _ = self.advance();
            const operand = try self.unary();
            return ScriptValue.fromNumber(-(try asNumber(operand)));
        }
        if (op == .kw_not) {
            _ = self.advance();
            const operand = try self.unary();
            return ScriptValue.fromBool(!operand.toBool());
        }
        return self.primary();
    }

    fn primary(self: *Interpreter) Error!ScriptValue {
        const tok = self.advance();
        return switch (tok) {
            .number => |n| ScriptValue.fromNumber(n),
            .string => |str| ScriptValue.fromString(str),
            .kw_true => ScriptValue.fromBool(true),
            .kw_false => ScriptValue.fromBool(false),
            .kw_nil => .nil,
            .identifier => |name| self.engine.getGlobal(name) orelse error.UnknownVariable,
            .lparen => blk: {
                const inner = try self.expression();
                if (self.advance().tag() != .rparen) return error.SyntaxError;
                break :blk inner;
            },
            else => error.SyntaxError,
        };
    }

    fn asNumber(value: ScriptValue) Error!f64 {
        return value.toNumber() orelse error.TypeError;
    }

    fn valuesEqual(a: ScriptValue, b: ScriptValue) bool {
        return switch (a) {
            .nil => b == .nil,
            .boolean => |x| b == .boolean and b.boolean == x,
            .number => |x| b == .number and b.number == x,
            .string => |x| b == .string and std.mem.eql(u8, x, b.string),
            else => false,
        };
    }
};

/// Async Script Task
pub const AsyncScriptTask = struct {
    engine: *ScriptEngine,
    code: []const u8,
    /// Owns string allocations produced while evaluating `code`, including the
    /// returned result. Lives until `deinit`.
    arena: std.heap.ArenaAllocator,
    result: ?ScriptValue,
    error_msg: ?[]const u8,
    completed: std.atomic.Value(bool),

    const Self = @This();

    pub fn init(engine: *ScriptEngine, code: []const u8) Self {
        return Self{
            .engine = engine,
            .code = code,
            .arena = std.heap.ArenaAllocator.init(engine.allocator),
            .result = null,
            .error_msg = null,
            .completed = std.atomic.Value(bool).init(false),
        };
    }

    pub fn deinit(self: *Self) void {
        self.arena.deinit();
    }

    /// Execute the script and return the value of its final expression.
    /// On failure, `error_msg` is set and the error is propagated.
    pub fn execute(self: *Self) !ScriptValue {
        const value = self.engine.eval(self) catch |err| {
            self.error_msg = @errorName(err);
            self.completed.store(true, .release);
            return err;
        };
        self.result = value;
        self.completed.store(true, .release);
        return value;
    }

    /// Check if completed
    pub fn isCompleted(self: *const Self) bool {
        return self.completed.load(.acquire);
    }
};

/// Script Channel - bridge between Zig channels and script
pub fn ScriptChannel(comptime T: type) type {
    return struct {
        channel: channels.UnboundedChannel(T),
        allocator: std.mem.Allocator,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) !Self {
            return Self{
                .channel = try channels.unbounded(T, allocator),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.channel.deinit();
        }

        /// Send value (callable from script)
        pub fn send(self: *Self, value: T) !void {
            try self.channel.send(value);
        }

        /// Receive value (callable from script)
        pub fn recv(self: *Self) !T {
            return try self.channel.recv();
        }

        /// Try send (non-blocking, callable from script)
        pub fn trySend(self: *Self, value: T) bool {
            return self.channel.trySend(value) catch false;
        }

        /// Try receive (non-blocking, callable from script)
        pub fn tryRecv(self: *Self) ?T {
            return self.channel.tryRecv() catch null;
        }
    };
}

/// Async function wrapper for scripts
pub const AsyncFunction = struct {
    callback: *const fn ([]const ScriptValue) anyerror!ScriptValue,
    runtime: *Runtime,

    const Self = @This();

    /// Invoke the wrapped callback and return its result. The callback itself
    /// may use `runtime` to perform asynchronous work before returning.
    pub fn callAsync(self: *Self, args: []const ScriptValue) !ScriptValue {
        return self.callback(args);
    }
};

/// Script-to-Zig FFI helpers
pub const FFI = struct {
    /// Call a Zig function with arguments supplied as script values.
    ///
    /// Each parameter is converted from the corresponding `ScriptValue`; a
    /// mismatch in arity or type is reported as an error. The function's return
    /// value (or the payload of its error union) is converted back to a
    /// `ScriptValue`.
    pub fn callZigFunction(
        comptime Fn: type,
        func: Fn,
        args: []const ScriptValue,
    ) !ScriptValue {
        const fn_info = switch (@typeInfo(Fn)) {
            .@"fn" => |f| f,
            .pointer => |p| switch (@typeInfo(p.child)) {
                .@"fn" => |f| f,
                else => @compileError("callZigFunction expects a function or function pointer"),
            },
            else => @compileError("callZigFunction expects a function or function pointer"),
        };

        if (args.len < fn_info.param_types.len) return error.NotEnoughArguments;

        var call_args: std.meta.ArgsTuple(@TypeOf(func)) = undefined;
        inline for (fn_info.param_types, 0..) |maybe_type, idx| {
            const ParamType = maybe_type orelse return error.UnsupportedParameter;
            call_args[idx] = fromScriptValue(ParamType, args[idx]) orelse return error.TypeMismatch;
        }

        const result = @call(.auto, func, call_args);
        const value = switch (@typeInfo(@TypeOf(result))) {
            .error_union => try result,
            else => result,
        };
        return toScriptValue(value);
    }

    /// Convert Zig value to script value
    pub fn toScriptValue(value: anytype) ScriptValue {
        const T = @TypeOf(value);
        return switch (@typeInfo(T)) {
            .bool => ScriptValue.fromBool(value),
            .int, .comptime_int, .float, .comptime_float => ScriptValue.fromNumber(@floatCast(value)),
            .pointer => |ptr| switch (ptr.size) {
                .slice => if (ptr.child == u8) ScriptValue.fromString(value) else .nil,
                else => .nil,
            },
            else => .nil,
        };
    }

    /// Convert script value to Zig value
    pub fn fromScriptValue(comptime T: type, value: ScriptValue) ?T {
        return switch (@typeInfo(T)) {
            .bool => if (value == .boolean) value.boolean else null,
            .int => if (value == .number) @as(T, @intFromFloat(value.number)) else null,
            .float => if (value == .number) @as(T, @floatCast(value.number)) else null,
            .pointer => |ptr| switch (ptr.size) {
                .slice => if (ptr.child == u8 and value == .string) value.string else null,
                else => null,
            },
            else => null,
        };
    }
};

/// Script Timer - schedule callbacks
pub const ScriptTimer = struct {
    runtime: *Runtime,
    callback: *const fn () anyerror!void,
    interval_ms: u64,
    repeat: bool,
    active: std.atomic.Value(bool),

    const Self = @This();

    pub fn init(
        runtime: *Runtime,
        callback: *const fn () anyerror!void,
        interval_ms: u64,
        repeat: bool,
    ) Self {
        return Self{
            .runtime = runtime,
            .callback = callback,
            .interval_ms = interval_ms,
            .repeat = repeat,
            .active = std.atomic.Value(bool).init(true),
        };
    }

    /// Start timer
    pub fn start(self: *Self) !void {
        while (self.active.load(.acquire)) {
            compat.sleepNanos(self.interval_ms * std.time.ns_per_ms);

            try self.callback();

            if (!self.repeat) break;
        }
    }

    /// Stop timer
    pub fn stop(self: *Self) void {
        self.active.store(false, .release);
    }
};

/// Script Event Emitter
pub fn ScriptEmitter(comptime T: type) type {
    return struct {
        listeners: std.ArrayList(*const fn (T) anyerror!void),
        allocator: std.mem.Allocator,
        mutex: compat.Mutex,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{
                .listeners = .empty,
                .allocator = allocator,
                .mutex = .{},
            };
        }

        pub fn deinit(self: *Self) void {
            self.listeners.deinit(self.allocator);
        }

        /// Register listener (callable from script)
        pub fn on(self: *Self, listener: *const fn (T) anyerror!void) !void {
            self.mutex.lock();
            defer self.mutex.unlock();
            try self.listeners.append(self.allocator, listener);
        }

        /// Remove listener (callable from script)
        pub fn off(self: *Self, listener: *const fn (T) anyerror!void) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            for (self.listeners.items, 0..) |l, i| {
                if (l == listener) {
                    _ = self.listeners.orderedRemove(i);
                    return;
                }
            }
        }

        /// Emit event (callable from script)
        pub fn emit(self: *Self, event: T) void {
            self.mutex.lock();
            const listeners = self.allocator.dupe(*const fn (T) anyerror!void, self.listeners.items) catch return;
            self.mutex.unlock();
            defer self.allocator.free(listeners);

            for (listeners) |listener| {
                listener(event) catch |err| {
                    std.debug.print("[ScriptEmitter] Error: {}\n", .{err});
                };
            }
        }
    };
}

// Tests
test "script value conversions" {
    const testing = std.testing;

    const v1 = ScriptValue.fromBool(true);
    try testing.expect(v1.toBool());

    const v2 = ScriptValue.fromNumber(42.0);
    try testing.expectEqual(42.0, v2.toNumber().?);

    const v3 = ScriptValue.fromString("hello");
    try testing.expect(std.mem.eql(u8, "hello", v3.string));
}

test "ffi type conversion" {
    const testing = std.testing;

    const sv1 = FFI.toScriptValue(true);
    try testing.expect(sv1.toBool());

    const sv2 = FFI.toScriptValue(@as(f64, 42.0));
    try testing.expectEqual(42.0, sv2.toNumber().?);

    const b = FFI.fromScriptValue(bool, ScriptValue.fromBool(true));
    try testing.expectEqual(true, b.?);
}

test "interpreter evaluates arithmetic and precedence" {
    const testing = std.testing;

    var runtime = Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var engine = ScriptEngine.init(testing.allocator, &runtime);
    defer engine.deinit();

    var task = AsyncScriptTask.init(&engine, "1 + 2 * 3 - (4 - 1)");
    defer task.deinit();

    const result = try task.execute();
    try testing.expectEqual(@as(f64, 4.0), result.toNumber().?);
    try testing.expect(task.isCompleted());
}

test "interpreter handles variables, comparison and logic" {
    const testing = std.testing;

    var runtime = Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var engine = ScriptEngine.init(testing.allocator, &runtime);
    defer engine.deinit();

    try engine.setGlobal("base", ScriptValue.fromNumber(10));

    var task = AsyncScriptTask.init(&engine,
        \\let x = base * 2;
        \\let ok = x >= 20 and x < 100;
        \\ok
    );
    defer task.deinit();

    const result = try task.execute();
    try testing.expect(result.toBool());

    // Assigned globals persist in the engine environment.
    try testing.expectEqual(@as(f64, 20.0), engine.getGlobal("x").?.toNumber().?);
}

test "interpreter concatenates strings" {
    const testing = std.testing;

    var runtime = Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var engine = ScriptEngine.init(testing.allocator, &runtime);
    defer engine.deinit();

    var task = AsyncScriptTask.init(&engine,
        \\"hello, " + "world"
    );
    defer task.deinit();

    const result = try task.execute();
    try testing.expect(std.mem.eql(u8, "hello, world", result.string));
}

test "interpreter reports errors" {
    const testing = std.testing;

    var runtime = Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var engine = ScriptEngine.init(testing.allocator, &runtime);
    defer engine.deinit();

    var task = AsyncScriptTask.init(&engine, "1 / 0");
    defer task.deinit();

    try testing.expectError(error.DivisionByZero, task.execute());
    try testing.expect(task.error_msg != null);
}

test "interpreter reports syntax and type errors" {
    const testing = std.testing;

    var runtime = Runtime.init(testing.allocator, .{});
    defer runtime.deinit();

    var engine = ScriptEngine.init(testing.allocator, &runtime);
    defer engine.deinit();

    var syntax_task = AsyncScriptTask.init(&engine, "let = 1");
    defer syntax_task.deinit();
    try testing.expectError(error.SyntaxError, syntax_task.execute());

    var type_task = AsyncScriptTask.init(&engine, "\"x\" * 2");
    defer type_task.deinit();
    try testing.expectError(error.TypeError, type_task.execute());
}

test "ffi calls zig function with script args" {
    const testing = std.testing;

    const Math = struct {
        fn add(a: f64, b: f64) f64 {
            return a + b;
        }
    };

    const args = [_]ScriptValue{
        ScriptValue.fromNumber(3),
        ScriptValue.fromNumber(4),
    };
    const result = try FFI.callZigFunction(@TypeOf(Math.add), Math.add, &args);
    try testing.expectEqual(@as(f64, 7.0), result.toNumber().?);
}

test "ffi reports arity and type mismatches" {
    const testing = std.testing;

    const Math = struct {
        fn add(a: f64, b: f64) f64 {
            return a + b;
        }
    };

    const too_few = [_]ScriptValue{ScriptValue.fromNumber(1)};
    try testing.expectError(error.NotEnoughArguments, FFI.callZigFunction(@TypeOf(Math.add), Math.add, &too_few));

    const wrong_type = [_]ScriptValue{
        ScriptValue.fromNumber(1),
        ScriptValue.fromBool(true),
    };
    try testing.expectError(error.TypeMismatch, FFI.callZigFunction(@TypeOf(Math.add), Math.add, &wrong_type));
}
