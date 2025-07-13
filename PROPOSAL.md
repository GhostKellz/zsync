https://github.com/ziglang/zig/issues/2344

Proposal: stackless coroutines as low-level primitives #23446
Open
@mlugg
Description
mlugg
opened on Apr 2, 2025 · edited by mlugg
Member

This proposal assumes the existence of #23367.
Background

At the time of writing, @andrewrk and @jacobly0 are exploring the idea of implementing async/await in userland, based on the new Io interface. This allows using different approaches to implement async, such as single-threaded blocking, thread pool blocking, or green threads / fibers. The latter approach is likely to become the preferred method, because it is fairly performant and conceptually simple. At this point it seems incredibly likely that this will become the path forward for async/await in Zig; it has a lot of advantages!

However, stackful coroutines via green threads do have some flaws. One of the most significant is that they simply aren't supported on some targets, such as Wasm and SPIR-V. Wasm is a particularly interesting example, because using stackless async in Wasm can be desirable in order to integrate with the JavaScript event loop -- for instance, expensive work in Wasm ought to periodically yield to the browser to allow other work to happen. The only way we can really do that is through stackless coroutines, which require language-level support. In general, stackless coroutines will have broader support than stackful coroutines, because all of the suspend/resume machinery is lowered by the compiler to synchronous constructs.

#6025 proposes re-introducing stackless coroutines, as in stage1, to the self-hosted compiler. This proposal competes with #6025 by taking the alternative approach to provide simpler primitives upon which a stackless std.Io implementation can be built, forgoing nice syntax and type safety in favour of a simpler language specification and compiler implementation. This proposal assumes that language features pertaining to "old" async (e.g. the async, await, and anyframe keywords) are removed.
Proposal

Add the following declaration to std.builtin:

pub const AsyncFrame = opaque {};

Implement the following builtins:

/// Returns the required size of the async frame buffer for the given function or function pointer.
/// Function pointers must be restricted (#23367).
/// The result is always comptime-known.
@asyncFrameSize(func: anytype) usize;

/// Initializes an async frame in `frame_buf`, such that calling `@asyncResume` on the
/// returned frame pointer will begin executing the function.
/// `func` may be a function or function pointer.
/// Asserts that `frame_buf.len` matches `@asyncFrameSize(func)`.
/// The parameter to `func` is given at the call to `@asyncResume`.
/// "Frame buffer" and "frame pointer" mean different things. The returned frame pointer
/// is somewhere within `frame_buf`, but its exact address is arbitrary. 
@asyncInit(frame_buf: []u8, func: *const fn (*anyopaque) void) *std.builtin.AsyncFrame;

/// Given a function's frame pointer, resumes that function.
/// Despite the name, this is also how you first start running an async function after calling `@asyncInit`.
/// If this is the first time resuming (i.e. this frame was just initialized), `arg` is passed to the `func`
/// given in `@asyncInit`. Otherwise, `arg` is returned by the `@asyncSuspend` we are resuming from.
/// Returns the argument to the `@asyncSuspend` call, or `null` if the function completed without suspending.
/// If the call completed, it is Safety-Checked Illegal Behavior to call `@asyncResume` on this frame again.
@asyncResume(frame: *std.builtin.AsyncFrame, arg: *anyopaque) ?*anyopaque;

/// Suspends the current function. All live values are spilled to its async frame buffer if necessary.
/// After the function is suspended, control flow returns to the nearest `@asyncResume` site.
/// The `data` argument is returned from `@asyncResume`.
@asyncSuspend(data: *anyopaque) *anyopaque;

/// Retrieve the current function's async frame pointer.
/// If this is not an async function (i.e. it has no suspension points), `null` is returned.
@asyncFrame() ?*std.builtin.AsyncFrame;

// EDIT: this last builtin is unnecessary! Disregard it...
// /// Like `@call` with `std.builtin.CallModifier.auto`, but asserts that the call never suspends, even
// /// if it is an async function. In other words, the callee having suspension points does not give the
// /// caller a suspension point. If the callee suspends, Safety-Checked Illegal Behavior is invoked.
// @asyncNoSuspendCall(func: anytype, args: anytype) anytype

All relevant builtins begin @async, making the scope of this language feature very clear.

Mapping concepts from #6025 to this proposal:

    @Frame() and anyframe types do not exist; raw byte buffers and opaque pointers are used.
    @frame() is called @asyncFrame().
    async foo() is equivalent to @asyncInit followed by @asyncResume.
    await frame is equivalent to repeated @asyncResume calls until one returns null.
    nosuspend foo(arg) is equivalent to @asyncNoSuspendCall(foo, .{arg}).
        Actually, nosuspend foo(arg) is just @asyncInit followed by @asyncResume but asserting that the latter returns null!
    suspend is @asyncSuspend(). There is no longer a "suspend block"; I elaborate on this below.
    resume is @asyncResume(). I elaborate on the argument and return value of this builtin below.

A function is async if it has any "suspension point". A suspension point is:

    a usage of @asyncSuspend, or
    a call of another async function (including through @call)

An async function must have callconv(.auto).
Suspending and Resuming

Under #6025, when a function suspends, control flow moves to its "suspend block" before being passed to the resume or async site. This block is generally responsible for actually queuing the asynchronous operation, and storing the @frame() somewhere ready to be resumed when the operation completes. The crucial thing is that once in the suspend { ... } block, the function is already considered suspended, so it is safe for another thread to resume it.

This proposal takes a different approach for simplicitly. The @asyncSuspend builtin takes a value of type *anyopaque, which is returned by the corresponding @asyncResume() call. That @asyncResume() call can then use that arbitrary data to queue the operation and store the async frame somewhere. The code which calls @asyncSuspend would include in that pointer the current @asyncFrame(), so that the event loop knows which frame pointer to resume later, and information about the reason for suspension, so that the event loop can schedule the appropriate action. Later, when the function is resumed, an argument (again of type *anyopaque) is passed to @asyncResume, and this value is returned from the @asyncSuspend we are resuming from to act as a kind of "result".

This approach wasn't possible under the old design, because writing var frame = async foo(); needed to queue the asynchronous operation without requiring the user to put extra code after that async invocation. However, the equivalent for this code is now var future = io.async(foo, .{});, so the async implementation is free to implement this machinery.
Implementation Notes

The implementation still internally has the concept of "awaiters", due to function calls. When a function directly calls another async function, the caller creates a frame buffer nested in its own frame, initializes it, marks itself as the "awaiter" inside that frame, and then calls the callee. However, this internal "awaiter" field would only be for direct function calls; it wouldn't apply to io.await, which would be implemented in the event loop by (very vaguely, ignoring parallelism/atomic issues):

    Storing, in the event loop, that the awaiter is waiting for the awaitee
    @asyncSuspend()ing the awaiter
    Allowing the event loop to repeatedly resume the awaitee until it finishes
    Once the awaitee finishes, resuming the awaiter again, based on the event loop's own state

I'm not sure if this point is novel (I wasn't deeply familiar with the legacy async implementation), but: this call (one async function directly calling another) can actually be a tail call, because the callee will then tail call the caller again once it returns (due to the caller being marked as its "awaiter" in this internal field). This decreases stack usage, and also speeds up suspension, because there's no need to unwind the whole stack.

One nice thing about async and await being implemented in userland is that the @async builtins do not need to be aware of threads. In the legacy async implementation, each frame included one or two atomic fields to deal with an await racing with frame completion. In contrast, this proposal offloads that work into the Io implementation, which can choose how to handle it. This could be a performance advantage; LLVM struggles to optimize around those atomics, so a stackless-coroutine-based event loop which knows it's single threaded (even if the application as a whole is not -fsingle-threaded) could choose not to use an atomic flag, helping the optimizer.
Closing Notes

There are details of this proposal that need to be hashed out; coroutines are complicated! There are also probably things I need to specify which I haven't (like clarifying how this interacts with function pointers). Nonetheless, I wanted to put this proposal up to invite discussion on this potential path forward which I, for one, am quite excited by.
::
