//! Suspend/Resume State Machines for zsync
//! Implements sophisticated state management for stackless coroutines with tail call optimization

const std = @import("std");
const compat = @import("compat/thread.zig");
const stackless_coroutines = @import("stackless_coroutines.zig");
const error_management = @import("error_management.zig");
const io_v2 = @import("io_v2.zig");

/// State machine manager for suspend/resume operations
pub const StateMachineManager = struct {
    allocator: std.mem.Allocator,
    state_registry: StateRegistry,
    suspend_point_tracker: SuspendPointTracker,
    resume_scheduler: ResumeScheduler,
    tail_call_optimizer: TailCallOptimizer,
    
    const Self = @This();
    
    /// Registry of all possible states and their transitions
    const StateRegistry = struct {
        states: std.HashMap(StateId, StateDefinition, StateIdContext, std.hash_map.default_max_load_percentage),
        transitions: std.HashMap(TransitionKey, TransitionDefinition, TransitionKeyContext, std.hash_map.default_max_load_percentage),
        allocator: std.mem.Allocator,
        
        const StateId = struct {
            function_hash: u64,
            suspend_point: u32,
        };
        
        const StateIdContext = struct {
            pub fn hash(self: @This(), key: StateId) u64 {
                _ = self;
                return key.function_hash ^ (@as(u64, key.suspend_point) << 32);
            }
            
            pub fn eql(self: @This(), a: StateId, b: StateId) bool {
                _ = self;
                return a.function_hash == b.function_hash and a.suspend_point == b.suspend_point;
            }
        };
        
        const StateDefinition = struct {
            id: StateId,
            name: []const u8,
            resume_fn: *const fn(*anyopaque, *ResumeContext) anyerror!ResumeResult,
            cleanup_fn: ?*const fn(*anyopaque) void,
            local_vars_size: usize,
            can_tail_call: bool,
            is_terminal: bool,
            
            /// Execution result from a state
            const ResumeResult = struct {
                next_state: ?StateId,
                operation: ResumeOperation,
                tail_call_target: ?TailCallTarget,
                
                const ResumeOperation = enum {
                    continue_execution,
                    suspend_for_io,
                    suspend_for_timer,
                    suspend_for_future,
                    complete_success,
                    complete_error,
                    tail_call,
                };
                
                const TailCallTarget = struct {
                    function_ptr: *const fn() anyerror!void,
                    args_data: []const u8,
                };
            };
        };
        
        const TransitionKey = struct {
            from_state: StateId,
            to_state: StateId,
        };
        
        const TransitionKeyContext = struct {
            pub fn hash(self: @This(), key: TransitionKey) u64 {
                _ = self;
                const state_id_context = StateIdContext{};
                return state_id_context.hash(key.from_state) ^ state_id_context.hash(key.to_state);
            }
            
            pub fn eql(self: @This(), a: TransitionKey, b: TransitionKey) bool {
                _ = self;
                const state_id_context = StateIdContext{};
                return state_id_context.eql(a.from_state, b.from_state) and
                       state_id_context.eql(a.to_state, b.to_state);
            }
        };
        
        const TransitionDefinition = struct {
            from_state: StateId,
            to_state: StateId,
            condition_fn: ?*const fn(*const ResumeContext) bool,
            transform_fn: ?*const fn(*ResumeContext) anyerror!void,
            is_conditional: bool,
        };
        
        pub fn init(allocator: std.mem.Allocator) @This() {
            return @This(){
                .states = std.HashMap(StateId, StateDefinition, StateIdContext, std.hash_map.default_max_load_percentage).init(allocator),
                .transitions = std.HashMap(TransitionKey, TransitionDefinition, TransitionKeyContext, std.hash_map.default_max_load_percentage).init(allocator),
                .allocator = allocator,
            };
        }
        
        pub fn deinit(self: *@This()) void {
            self.states.deinit();
            self.transitions.deinit();
        }
        
        /// Register a new state in the state machine
        pub fn registerState(self: *@This(), state: StateDefinition) !void {
            try self.states.put(state.id, state);
        }
        
        /// Register a transition between states
        pub fn registerTransition(self: *@This(), transition: TransitionDefinition) !void {
            const key = TransitionKey{
                .from_state = transition.from_state,
                .to_state = transition.to_state,
            };
            try self.transitions.put(key, transition);
        }
        
        /// Get state definition by ID
        pub fn getState(self: *const @This(), state_id: StateId) ?StateDefinition {
            return self.states.get(state_id);
        }
        
        /// Get valid transitions from a given state
        pub fn getTransitionsFrom(self: *const @This(), state_id: StateId, allocator: std.mem.Allocator) ![]TransitionDefinition {
            var transitions = std.ArrayList(TransitionDefinition){ .allocator = allocator };
            
            var iterator = self.transitions.iterator();
            while (iterator.next()) |entry| {
                const transition = entry.value_ptr.*;
                const state_id_context = StateIdContext{};
                if (state_id_context.eql(transition.from_state, state_id)) {
                    try transitions.append(allocator, transition);
                }
            }
            
            return transitions.toOwnedSlice();
        }
    };
    
    /// Tracks suspend points and their resume data
    const SuspendPointTracker = struct {
        active_suspend_points: std.HashMap(SuspendPointId, SuspendPointData, SuspendPointIdContext, std.hash_map.default_max_load_percentage),
        allocator: std.mem.Allocator,
        
        const SuspendPointId = struct {
            coroutine_id: usize,
            suspend_point: u32,
        };
        
        const SuspendPointIdContext = struct {
            pub fn hash(self: @This(), key: SuspendPointId) u64 {
                _ = self;
                return (@as(u64, key.coroutine_id) << 32) ^ key.suspend_point;
            }
            
            pub fn eql(self: @This(), a: SuspendPointId, b: SuspendPointId) bool {
                _ = self;
                return a.coroutine_id == b.coroutine_id and a.suspend_point == b.suspend_point;
            }
        };
        
        const SuspendPointData = struct {
            id: SuspendPointId,
            suspend_reason: SuspendReason,
            resume_data: []u8,
            created_at: u64,
            timeout_at: ?u64,
            waker: ?Waker,
            
            const SuspendReason = enum {
                io_operation,
                timer_wait,
                future_await,
                manual_suspend,
                dependency_wait,
                resource_wait,
            };
            
            const Waker = struct {
                callback: *const fn(*anyopaque) void,
                context: *anyopaque,
            };
        };
        
        pub fn init(allocator: std.mem.Allocator) @This() {
            return @This(){
                .active_suspend_points = std.HashMap(SuspendPointId, SuspendPointData, SuspendPointIdContext, std.hash_map.default_max_load_percentage).init(allocator),
                .allocator = allocator,
            };
        }
        
        pub fn deinit(self: *@This()) void {
            // Clean up all resume data
            var iterator = self.active_suspend_points.iterator();
            while (iterator.next()) |entry| {
                self.allocator.free(entry.value_ptr.resume_data);
            }
            self.active_suspend_points.deinit();
        }
        
        /// Register a new suspend point
        pub fn registerSuspendPoint(
            self: *@This(),
            coroutine_id: usize,
            suspend_point: u32,
            reason: SuspendPointData.SuspendReason,
            resume_data: []const u8,
            timeout_ms: ?u64,
        ) !SuspendPointId {
            const id = SuspendPointId{
                .coroutine_id = coroutine_id,
                .suspend_point = suspend_point,
            };
            
            const owned_data = try self.allocator.dupe(u8, resume_data);
            
            const data = SuspendPointData{
                .id = id,
                .suspend_reason = reason,
                .resume_data = owned_data,
                .created_at = compat.Instant.now() catch unreachable,
                .timeout_at = if (timeout_ms) |ms| compat.Instant.now() catch unreachable + (ms * std.time.ns_per_ms) else null,
                .waker = null,
            };
            
            try self.active_suspend_points.put(id, data);
            return id;
        }
        
        /// Mark a suspend point as ready for resume
        pub fn markReadyForResume(self: *@This(), id: SuspendPointId) !void {
            if (self.active_suspend_points.getPtr(id)) |data| {
                if (data.waker) |waker| {
                    waker.callback(waker.context);
                }
            }
        }
        
        /// Get suspend point data
        pub fn getSuspendPointData(self: *const @This(), id: SuspendPointId) ?SuspendPointData {
            return self.active_suspend_points.get(id);
        }
        
        /// Remove a suspend point (when resumed or canceled)
        pub fn removeSuspendPoint(self: *@This(), id: SuspendPointId) !void {
            if (self.active_suspend_points.fetchRemove(id)) |entry| {
                self.allocator.free(entry.value.resume_data);
            }
        }
        
        /// Check for expired suspend points
        pub fn getExpiredSuspendPoints(self: *const @This(), allocator: std.mem.Allocator) ![]SuspendPointId {
            var expired = std.ArrayList(SuspendPointId){ .allocator = allocator };
            const now = compat.Instant.now() catch unreachable;
            
            var iterator = self.active_suspend_points.iterator();
            while (iterator.next()) |entry| {
                const data = entry.value_ptr.*;
                if (data.timeout_at) |timeout| {
                    if (now > timeout) {
                        try expired.append(allocator, data.id);
                    }
                }
            }
            
            return expired.toOwnedSlice();
        }
    };
    
    /// Scheduler for resuming suspended coroutines
    const ResumeScheduler = struct {
        ready_queue: std.PriorityQueue(ResumeItem, void, resumeItemCompare),
        scheduling_policy: SchedulingPolicy,
        allocator: std.mem.Allocator,
        
        const ResumeItem = struct {
            coroutine_id: usize,
            suspend_point_id: SuspendPointTracker.SuspendPointId,
            priority: Priority,
            scheduled_at: u64,
            
            const Priority = enum(u8) {
                low = 0,
                normal = 1,
                high = 2,
                critical = 3,
            };
        };
        
        const SchedulingPolicy = enum {
            fifo,           // First in, first out
            priority,       // Priority-based scheduling
            round_robin,    // Round-robin scheduling
            deadline,       // Earliest deadline first
        };
        
        fn resumeItemCompare(context: void, a: ResumeItem, b: ResumeItem) std.math.Order {
            _ = context;
            
            // Higher priority items come first
            const priority_order = std.math.order(@intFromEnum(a.priority), @intFromEnum(b.priority));
            if (priority_order != .eq) {
                return priority_order.invert(); // Invert because we want higher priority first
            }
            
            // For same priority, earlier scheduled items come first
            return std.math.order(a.scheduled_at, b.scheduled_at);
        }
        
        pub fn init(allocator: std.mem.Allocator, policy: SchedulingPolicy) @This() {
            return @This(){
                .ready_queue = std.PriorityQueue(ResumeItem, void, resumeItemCompare).init(allocator, {}),
                .scheduling_policy = policy,
                .allocator = allocator,
            };
        }
        
        pub fn deinit(self: *@This()) void {
            self.ready_queue.deinit();
        }
        
        /// Schedule a coroutine for resume
        pub fn scheduleResume(
            self: *@This(),
            coroutine_id: usize,
            suspend_point_id: SuspendPointTracker.SuspendPointId,
            priority: ResumeItem.Priority,
        ) !void {
            const item = ResumeItem{
                .coroutine_id = coroutine_id,
                .suspend_point_id = suspend_point_id,
                .priority = priority,
                .scheduled_at = compat.Instant.now() catch unreachable,
            };
            
            try self.ready_queue.add(item);
        }
        
        /// Get the next item to resume
        pub fn getNextResume(self: *@This()) ?ResumeItem {
            return self.ready_queue.removeOrNull();
        }
        
        /// Get queue statistics
        pub fn getStatistics(self: *const @This()) SchedulerStatistics {
            return SchedulerStatistics{
                .queued_items = self.ready_queue.count(),
                .scheduling_policy = self.scheduling_policy,
            };
        }
        
        const SchedulerStatistics = struct {
            queued_items: usize,
            scheduling_policy: SchedulingPolicy,
        };
    };
    
    /// Tail call optimization for awaiter chains
    const TailCallOptimizer = struct {
        optimization_enabled: bool,
        call_stack: std.ArrayList(TailCallFrame),
        allocator: std.mem.Allocator,
        
        const TailCallFrame = struct {
            function_ptr: *const fn() anyerror!void,
            args_data: []const u8,
            return_address: ?*anyopaque,
        };
        
        pub fn init(allocator: std.mem.Allocator) @This() {
            return @This(){
                .optimization_enabled = true,
                .call_stack = std.ArrayList(TailCallFrame){ .allocator = allocator },
                .allocator = allocator,
            };
        }
        
        pub fn deinit(self: *@This()) void {
            // Clean up any remaining frames
            for (self.call_stack.items) |frame| {
                self.allocator.free(frame.args_data);
            }
            self.call_stack.deinit();
        }
        
        /// Check if a call can be tail-call optimized
        pub fn canOptimize(
            self: *const @This(),
            current_state: StateRegistry.StateId,
            target_function: *const fn() anyerror!void,
            state_registry: *const StateRegistry,
        ) bool {
            _ = target_function;
            
            if (!self.optimization_enabled) return false;
            
            // Check if current state allows tail calls
            if (state_registry.getState(current_state)) |state| {
                return state.can_tail_call;
            }
            
            return false;
        }
        
        /// Perform tail call optimization
        pub fn optimizeTailCall(
            self: *@This(),
            function_ptr: *const fn() anyerror!void,
            args_data: []const u8,
        ) !void {
            const owned_args = try self.allocator.dupe(u8, args_data);
            
            const frame = TailCallFrame{
                .function_ptr = function_ptr,
                .args_data = owned_args,
                .return_address = null,
            };
            
            try self.call_stack.append(self.allocator, frame);
        }
        
        /// Execute accumulated tail calls
        pub fn executeTailCalls(self: *@This()) !void {
            while (self.call_stack.items.len > 0) {
                const frame = self.call_stack.pop();
                defer self.allocator.free(frame.args_data);
                
                // Execute the tail call
                try frame.function_ptr();
            }
        }
    };
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .state_registry = StateRegistry.init(allocator),
            .suspend_point_tracker = SuspendPointTracker.init(allocator),
            .resume_scheduler = ResumeScheduler.init(allocator, .priority),
            .tail_call_optimizer = TailCallOptimizer.init(allocator),
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.state_registry.deinit();
        self.suspend_point_tracker.deinit();
        self.resume_scheduler.deinit();
        self.tail_call_optimizer.deinit();
    }
    
    /// Context for resume operations
    const ResumeContext = struct {
        coroutine_id: usize,
        current_state: StateRegistry.StateId,
        local_variables: []u8,
        suspend_data: []const u8,
        io_interface: io_v2.Io,
        allocator: std.mem.Allocator,
        
        /// Get a typed pointer to local variable storage
        pub fn getLocalVar(self: *const ResumeContext, comptime T: type, offset: usize) !*T {
            if (offset + @sizeOf(T) > self.local_variables.len) {
                return error.LocalVariableOutOfBounds;
            }
            
            const aligned_offset = std.mem.alignForward(usize, offset, @alignOf(T));
            if (aligned_offset + @sizeOf(T) > self.local_variables.len) {
                return error.LocalVariableAlignment;
            }
            
            return @as(*T, @ptrCast(@alignCast(&self.local_variables[aligned_offset])));
        }
        
        /// Store a value in local variable storage
        pub fn setLocalVar(self: *ResumeContext, comptime T: type, offset: usize, value: T) !void {
            const var_ptr = try self.getLocalVar(T, offset);
            var_ptr.* = value;
        }
        
        /// Deserialize suspend data into a typed structure
        pub fn deserializeSuspendData(self: *const ResumeContext, comptime T: type) !T {
            if (self.suspend_data.len < @sizeOf(T)) {
                return error.SuspendDataTooSmall;
            }
            
            const data_ptr = @as(*const T, @ptrCast(@alignCast(self.suspend_data.ptr)));
            return data_ptr.*;
        }
    };
    
    /// Execute a state machine step
    pub fn executeStep(
        self: *Self,
        coroutine_id: usize,
        current_state: StateRegistry.StateId,
        context: *ResumeContext,
    ) !StateRegistry.StateDefinition.ResumeResult {
        const state = self.state_registry.getState(current_state) orelse {
            return error.StateNotFound;
        };
        
        // Execute the state's resume function
        const result = try state.resume_fn(@as(*anyopaque, @ptrCast(context)), context);
        
        // Handle tail call optimization
        if (result.operation == .tail_call and result.tail_call_target != null) {
            const target = result.tail_call_target.?;
            
            if (self.tail_call_optimizer.canOptimize(current_state, target.function_ptr, &self.state_registry)) {
                try self.tail_call_optimizer.optimizeTailCall(target.function_ptr, target.args_data);
            }
        }
        
        // Handle suspend operations
        if (result.operation == .suspend_for_io or 
           result.operation == .suspend_for_timer or 
           result.operation == .suspend_for_future) {
            
            const suspend_reason: SuspendPointTracker.SuspendPointData.SuspendReason = switch (result.operation) {
                .suspend_for_io => .io_operation,
                .suspend_for_timer => .timer_wait,
                .suspend_for_future => .future_await,
                else => .manual_suspend,
            };
            
            _ = try self.suspend_point_tracker.registerSuspendPoint(
                coroutine_id,
                current_state.suspend_point,
                suspend_reason,
                context.suspend_data,
                null, // No timeout for now
            );
        }
        
        return result;
    }
    
    /// Resume a suspended coroutine
    pub fn resumeCoroutine(
        self: *Self,
        coroutine_id: usize,
        suspend_point_id: SuspendPointTracker.SuspendPointId,
    ) !void {
        const suspend_data = self.suspend_point_tracker.getSuspendPointData(suspend_point_id) orelse {
            return error.SuspendPointNotFound;
        };
        
        // Create resume context
        var context = ResumeContext{
            .coroutine_id = coroutine_id,
            .current_state = StateRegistry.StateId{
                .function_hash = 0, // Would be set based on the coroutine
                .suspend_point = suspend_point_id.suspend_point,
            },
            .local_variables = undefined, // Would be loaded from frame
            .suspend_data = suspend_data.resume_data,
            .io_interface = undefined, // Would be provided by the runtime
            .allocator = self.allocator,
        };
        
        // Execute the resume step
        const result = try self.executeStep(coroutine_id, context.current_state, &context);
        
        // Handle the result
        switch (result.operation) {
            .continue_execution => {
                // Continue with the next state if specified
                if (result.next_state) |next_state| {
                    context.current_state = next_state;
                    _ = try self.executeStep(coroutine_id, next_state, &context);
                }
            },
            .complete_success, .complete_error => {
                // Clean up the suspend point
                try self.suspend_point_tracker.removeSuspendPoint(suspend_point_id);
            },
            .tail_call => {
                // Execute accumulated tail calls
                try self.tail_call_optimizer.executeTailCalls();
                try self.suspend_point_tracker.removeSuspendPoint(suspend_point_id);
            },
            else => {
                // Suspend operations are already handled in executeStep
            },
        }
    }
    
    /// Schedule a coroutine for resume
    pub fn scheduleResume(
        self: *Self,
        coroutine_id: usize,
        suspend_point_id: SuspendPointTracker.SuspendPointId,
        priority: ResumeScheduler.ResumeItem.Priority,
    ) !void {
        try self.resume_scheduler.scheduleResume(coroutine_id, suspend_point_id, priority);
    }
    
    /// Process the next scheduled resume
    pub fn processNextResume(self: *Self) !bool {
        if (self.resume_scheduler.getNextResume()) |item| {
            try self.resumeCoroutine(item.coroutine_id, item.suspend_point_id);
            return true;
        }
        return false;
    }
    
    /// Process all expired suspend points
    pub fn processExpiredSuspendPoints(self: *Self) !usize {
        const expired = try self.suspend_point_tracker.getExpiredSuspendPoints(self.allocator);
        defer self.allocator.free(expired);
        
        for (expired) |suspend_point_id| {
            // Schedule for resume with timeout error
            try self.scheduleResume(
                suspend_point_id.coroutine_id,
                suspend_point_id,
                .normal
            );
        }
        
        return expired.len;
    }
    
    /// Get comprehensive statistics
    pub fn getStatistics(self: *const Self) StateMachineStatistics {
        return StateMachineStatistics{
            .registered_states = self.state_registry.states.count(),
            .registered_transitions = self.state_registry.transitions.count(),
            .active_suspend_points = self.suspend_point_tracker.active_suspend_points.count(),
            .scheduler_stats = self.resume_scheduler.getStatistics(),
            .tail_call_stack_depth = self.tail_call_optimizer.call_stack.items.len,
        };
    }
    
    const StateMachineStatistics = struct {
        registered_states: usize,
        registered_transitions: usize,
        active_suspend_points: usize,
        scheduler_stats: ResumeScheduler.SchedulerStatistics,
        tail_call_stack_depth: usize,
        
        pub fn print(self: @This()) void {
            std.debug.print("State Machine Statistics:\n");
            std.debug.print("  Registered states: {d}\n", .{self.registered_states});
            std.debug.print("  Registered transitions: {d}\n", .{self.registered_transitions});
            std.debug.print("  Active suspend points: {d}\n", .{self.active_suspend_points});
            std.debug.print("  Scheduled resumes: {d}\n", .{self.scheduler_stats.queued_items});
            std.debug.print("  Tail call stack depth: {d}\n", .{self.tail_call_stack_depth});
            std.debug.print("  Scheduling policy: {s}\n", .{@tagName(self.scheduler_stats.scheduling_policy)});
        }
    };
};

/// High-level suspend/resume operations for coroutines
pub const SuspendResumeOps = struct {
    /// Suspend current coroutine for I/O operation
    pub fn suspendForIo(
        state_machine: *StateMachineManager,
        coroutine_id: usize,
        suspend_point: u32,
        io_data: []const u8,
    ) !void {
        _ = try state_machine.suspend_point_tracker.registerSuspendPoint(
            coroutine_id,
            suspend_point,
            .io_operation,
            io_data,
            null,
        );
    }
    
    /// Suspend current coroutine for timer
    pub fn suspendForTimer(
        state_machine: *StateMachineManager,
        coroutine_id: usize,
        suspend_point: u32,
        timer_data: []const u8,
        timeout_ms: u64,
    ) !void {
        _ = try state_machine.suspend_point_tracker.registerSuspendPoint(
            coroutine_id,
            suspend_point,
            .timer_wait,
            timer_data,
            timeout_ms,
        );
    }
    
    /// Suspend current coroutine for future await
    pub fn suspendForFuture(
        state_machine: *StateMachineManager,
        coroutine_id: usize,
        suspend_point: u32,
        future_data: []const u8,
    ) !void {
        _ = try state_machine.suspend_point_tracker.registerSuspendPoint(
            coroutine_id,
            suspend_point,
            .future_await,
            future_data,
            null,
        );
    }
    
    /// Wake up a suspended coroutine
    pub fn wakeCoroutine(
        state_machine: *StateMachineManager,
        coroutine_id: usize,
        suspend_point: u32,
    ) !void {
        const suspend_point_id = StateMachineManager.SuspendPointTracker.SuspendPointId{
            .coroutine_id = coroutine_id,
            .suspend_point = suspend_point,
        };
        
        try state_machine.suspend_point_tracker.markReadyForResume(suspend_point_id);
        try state_machine.scheduleResume(
            coroutine_id,
            suspend_point_id,
            .normal
        );
    }
};

/// Code generation helpers for state machine creation
pub const StateMachineCodegen = struct {
    /// Generate state machine from function signature
    pub fn generateFromFunction(
        comptime FuncType: type,
        allocator: std.mem.Allocator,
    ) !StateMachineManager.StateRegistry {
        var registry = StateMachineManager.StateRegistry.init(allocator);
        
        // Analyze function and generate states
        const func_info = @typeInfo(FuncType);
        if (func_info != .Fn) {
            @compileError("Expected function type");
        }
        
        // Generate basic states for the function
        const function_hash = comptime std.hash_map.hashString(@typeName(FuncType));
        
        // Entry state
        const entry_state = StateMachineManager.StateRegistry.StateDefinition{
            .id = .{ .function_hash = function_hash, .suspend_point = 0 },
            .name = "entry",
            .resume_fn = generateEntryResumeFunction(FuncType),
            .cleanup_fn = null,
            .local_vars_size = calculateLocalVarsSize(FuncType),
            .can_tail_call = true,
            .is_terminal = false,
        };
        
        try registry.registerState(entry_state);
        
        // Exit state
        const exit_state = StateMachineManager.StateRegistry.StateDefinition{
            .id = .{ .function_hash = function_hash, .suspend_point = 255 },
            .name = "exit",
            .resume_fn = generateExitResumeFunction(FuncType),
            .cleanup_fn = null,
            .local_vars_size = 0,
            .can_tail_call = false,
            .is_terminal = true,
        };
        
        try registry.registerState(exit_state);
        
        return registry;
    }
    
    /// Generate entry resume function
    fn generateEntryResumeFunction(comptime FuncType: type) *const fn(*anyopaque, *StateMachineManager.ResumeContext) anyerror!StateMachineManager.StateRegistry.StateDefinition.ResumeResult {
        return struct {
            fn resumeFn(ptr: *anyopaque, context: *StateMachineManager.ResumeContext) !StateMachineManager.StateRegistry.StateDefinition.ResumeResult {
                _ = ptr;
                _ = context;
                
                // In a real implementation, this would execute the function entry logic
                // For now, just return a completion result
                return StateMachineManager.StateRegistry.StateDefinition.ResumeResult{
                    .next_state = null,
                    .operation = .complete_success,
                    .tail_call_target = null,
                };
            }
        }.resumeFn;
    }
    
    /// Generate exit resume function
    fn generateExitResumeFunction(comptime FuncType: type) *const fn(*anyopaque, *StateMachineManager.ResumeContext) anyerror!StateMachineManager.StateRegistry.StateDefinition.ResumeResult {
        return struct {
            fn resumeFn(ptr: *anyopaque, context: *StateMachineManager.ResumeContext) !StateMachineManager.StateRegistry.StateDefinition.ResumeResult {
                _ = ptr;
                _ = context;
                
                return StateMachineManager.StateRegistry.StateDefinition.ResumeResult{
                    .next_state = null,
                    .operation = .complete_success,
                    .tail_call_target = null,
                };
            }
        }.resumeFn;
    }
    
    /// Calculate local variable storage size
    fn calculateLocalVarsSize(comptime FuncType: type) usize {
        _ = FuncType;
        // In a real implementation, this would analyze the function's local variables
        return 1024; // Default size
    }
};

test "state machine manager" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var manager = StateMachineManager.init(allocator);
    defer manager.deinit();
    
    // Test state registration
    const test_state = StateMachineManager.StateRegistry.StateDefinition{
        .id = .{ .function_hash = 12345, .suspend_point = 0 },
        .name = "test_state",
        .resume_fn = struct {
            fn resumeFn(ptr: *anyopaque, context: *StateMachineManager.ResumeContext) !StateMachineManager.StateRegistry.StateDefinition.ResumeResult {
                _ = ptr;
                _ = context;
                return StateMachineManager.StateRegistry.StateDefinition.ResumeResult{
                    .next_state = null,
                    .operation = .complete_success,
                    .tail_call_target = null,
                };
            }
        }.resumeFn,
        .cleanup_fn = null,
        .local_vars_size = 256,
        .can_tail_call = true,
        .is_terminal = false,
    };
    
    try manager.state_registry.registerState(test_state);
    
    const retrieved_state = manager.state_registry.getState(test_state.id);
    try testing.expect(retrieved_state != null);
    try testing.expect(std.mem.eql(u8, retrieved_state.?.name, "test_state"));
}

test "suspend point tracker" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var tracker = StateMachineManager.SuspendPointTracker.init(allocator);
    defer tracker.deinit();
    
    // Test suspend point registration
    const test_data = "test suspend data";
    const suspend_id = try tracker.registerSuspendPoint(
        1, // coroutine_id
        0, // suspend_point
        .io_operation,
        test_data,
        1000, // timeout_ms
    );
    
    const retrieved_data = tracker.getSuspendPointData(suspend_id);
    try testing.expect(retrieved_data != null);
    try testing.expect(retrieved_data.?.suspend_reason == .io_operation);
    try testing.expect(std.mem.eql(u8, retrieved_data.?.resume_data, test_data));
    
    // Test cleanup
    try tracker.removeSuspendPoint(suspend_id);
    const after_removal = tracker.getSuspendPointData(suspend_id);
    try testing.expect(after_removal == null);
}

test "resume scheduler" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var scheduler = StateMachineManager.ResumeScheduler.init(allocator, .priority);
    defer scheduler.deinit();
    
    // Test scheduling
    const suspend_id = StateMachineManager.SuspendPointTracker.SuspendPointId{
        .coroutine_id = 1,
        .suspend_point = 0,
    };
    
    try scheduler.scheduleResume(1, suspend_id, .high);
    try scheduler.scheduleResume(2, suspend_id, .low);
    
    // High priority should come first
    const first = scheduler.getNextResume();
    try testing.expect(first != null);
    try testing.expect(first.?.priority == .high);
    
    const second = scheduler.getNextResume();
    try testing.expect(second != null);
    try testing.expect(second.?.priority == .low);
}

test "state machine codegen" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    // Test function type
    const TestFunc = fn() void;
    
    var registry = try StateMachineCodegen.generateFromFunction(TestFunc, allocator);
    defer registry.deinit();
    
    // Check that entry and exit states were generated
    const entry_state = registry.getState(.{ .function_hash = comptime std.hash_map.hashString(@typeName(TestFunc)), .suspend_point = 0 });
    try testing.expect(entry_state != null);
    try testing.expect(std.mem.eql(u8, entry_state.?.name, "entry"));
    
    const exit_state = registry.getState(.{ .function_hash = comptime std.hash_map.hashString(@typeName(TestFunc)), .suspend_point = 255 });
    try testing.expect(exit_state != null);
    try testing.expect(std.mem.eql(u8, exit_state.?.name, "exit"));
    try testing.expect(exit_state.?.is_terminal);
}