//! Content hashing for per-function codegen units (CGUs).
//!
//! The native backend can cache one object file per function and, on rebuild,
//! regenerate only the functions whose inputs changed. Correctness rests entirely
//! on this hash: two builds that would produce the same `.o` for a function MUST
//! hash equal, and any change that could alter that `.o` MUST change the hash. A
//! missed input means a stale object silently ships — a miscompile a clean rebuild
//! "fixes by magic". We therefore hash the full lowered IR (not source text, so
//! semantically-irrelevant whitespace never invalidates) and deliberately
//! over-invalidate wherever precision is uncertain.
//!
//! ## Hash inputs (the complete, justified set)
//!
//! For a function `F`, `CguHasher.hashFunction(F)` folds, in order:
//!
//! 1. **Codegen-format version** (`codegen_format_version`). Bumped whenever the
//!    lowering logic changes shape, so a compiler upgrade invalidates cleanly even
//!    if the IR is byte-identical.
//! 2. **Compilation config** — target triple, optimization flag, backend mode
//!    (native vs hybrid changes the symbol scheme and trampolines), and the
//!    owned-value drop toggle. All of these change the emitted object for identical
//!    IR, so they must be in the key. (The on-disk cache is *also* partitioned by
//!    triple + opt so debug/release/cross builds never collide; folding them here
//!    too is belt-and-suspenders.)
//! 3. **F's own lowered IR** — a complete, reflection-driven hash of every field of
//!    `ir.Function`, including the entire instruction stream (immediates, register
//!    indices, labels, branch targets, ownership modes, referenced ids/names). This
//!    is the body; nothing about F's own codegen escapes it. Using reflection rather
//!    than a hand-written per-instruction walk means a newly added instruction field
//!    can never be silently omitted.
//! 4. **Every function's signature** (all of them, sorted by id) — *signature only*:
//!    symbol-affecting name, params, return, per-parameter ownership, extern-ness,
//!    and foreign binding; **not** bodies. F's module holds an external `declare`
//!    for each callee it references, and F can reach a callee by direct call,
//!    virtual/family dispatch, or callback — resolving that exact set would mean
//!    replaying virtual method resolution. Folding ALL signatures is complete by
//!    construction: a callee body change leaves it untouched (F's `.o` is
//!    unaffected), while any signature change invalidates F (its `declare` may have
//!    changed). Conservative — a signature edit rebuilds every function — but
//!    signature edits are far rarer than body edits. (Sound only because incremental
//!    codegen does not inline across CGUs; a cross-inlining release build must not
//!    use this cache.)
//! 5. **Every struct and enum layout** in the program (sorted by name), hashed in
//!    full. A struct's size/alignment/field order changes the GEPs, allocations, and
//!    ABI of every function that touches it. Rather than risk missing a transitively
//!    referenced type in an extraction walk, we conservatively fold *all* type
//!    layouts into *every* function. Type edits are far rarer than body edits, so in
//!    the common case (editing one function body) this digest is unchanged and only
//!    the edited function's own-IR hash moves — still exactly one CGU invalidated.
//!
//! ## Determinism
//!
//! Non-deterministic iteration order would silently break caching (same inputs,
//! different hash). Every map/set is materialized into a slice and sorted (types and
//! enums by name, callees by id) before hashing. Integers are folded in native byte
//! order; the cache is host-local and additionally keyed by triple, so cross-endian
//! reuse never occurs.

const std = @import("std");
const ir = @import("kira_ir");
const backend_api = @import("kira_backend_api");
// IR-only projections of what the SUPPORT CGU emits beyond type layouts: the set
// of call_value dispatcher signatures and the closure capture shapes. Both are
// pure functions of the program IR (no LLVM handles), so hashing them lets the
// support digest stay stable across body edits that don't touch either set.
const dispatch = @import("backend_capi_dispatch.zig");
const closure_dtors = @import("backend_capi_closure_dtors.zig");
const fresh_any = @import("backend_capi_fresh_any.zig");

/// Bump when codegen logic changes in a way that can alter emitted objects for
/// otherwise-identical IR (new lowering, changed ABI handling, symbol scheme, ...).
pub const codegen_format_version: u64 = 1;

pub const Digest = [32]u8;

pub const CguConfig = struct {
    triple: []const u8,
    opt_flag: []const u8,
    mode: backend_api.BackendMode,
    drop_enabled: bool,
};

/// Streaming SHA-256 with length-prefixed framing so distinct field boundaries can
/// never alias (e.g. `["a","bc"]` hashes differently from `["ab","c"]`).
const Hasher = struct {
    inner: std.crypto.hash.sha2.Sha256,

    fn init() Hasher {
        return .{ .inner = std.crypto.hash.sha2.Sha256.init(.{}) };
    }

    fn raw(self: *Hasher, data: []const u8) void {
        self.inner.update(data);
    }

    fn int(self: *Hasher, value: anytype) void {
        var v = value;
        self.raw(std.mem.asBytes(&v));
    }

    fn bytes(self: *Hasher, data: []const u8) void {
        self.int(@as(u64, data.len));
        self.raw(data);
    }

    fn final(self: *Hasher) Digest {
        var digest: Digest = undefined;
        self.inner.final(&digest);
        return digest;
    }
};

/// Reflection-driven structural hash: folds every field of `value` so no input can
/// be silently dropped when the IR types gain fields. Handles the shapes the IR
/// actually uses (ints, bools, floats, enums, optionals, slices, structs, tagged
/// unions, arrays, void); anything else is a compile error, forcing a conscious
/// decision rather than a silent miss.
fn hashReflect(h: *Hasher, comptime T: type, value: T) void {
    switch (@typeInfo(T)) {
        .bool => h.int(@as(u8, @intFromBool(value))),
        .int, .comptime_int => h.int(value),
        .float => h.raw(std.mem.asBytes(&value)),
        .@"enum" => {
            const tag_value = @intFromEnum(value);
            h.int(tag_value);
        },
        .optional => |info| {
            if (value) |payload| {
                h.int(@as(u8, 1));
                hashReflect(h, info.child, payload);
            } else {
                h.int(@as(u8, 0));
            }
        },
        .pointer => |info| switch (info.size) {
            .slice => {
                h.int(@as(u64, value.len));
                if (info.child == u8) {
                    h.raw(value);
                } else {
                    for (value) |element| hashReflect(h, info.child, element);
                }
            },
            .one => hashReflect(h, info.child, value.*),
            else => @compileError("cgu_hash: unsupported pointer kind for " ++ @typeName(T)),
        },
        .@"struct" => |info| {
            inline for (info.fields) |field| {
                hashReflect(h, field.type, @field(value, field.name));
            }
        },
        .@"union" => |info| {
            const Tag = info.tag_type orelse @compileError("cgu_hash: untagged union " ++ @typeName(T));
            const active = std.meta.activeTag(value);
            h.int(@intFromEnum(active));
            inline for (info.fields) |field| {
                if (active == @field(Tag, field.name)) {
                    hashReflect(h, field.type, @field(value, field.name));
                }
            }
        },
        .array => |info| {
            for (value) |element| hashReflect(h, info.child, element);
        },
        .void => {},
        else => @compileError("cgu_hash: unsupported type " ++ @typeName(T)),
    }
}

/// A function's signature: everything a caller's external declaration depends on,
/// and nothing about its body. Kept as an explicit projection so the body-exclusion
/// that makes cross-CGU caching sound is visible and auditable.
fn hashSignature(h: *Hasher, function: ir.Function) void {
    h.int(function.id);
    h.bytes(function.name);
    hashReflect(h, @TypeOf(function.execution), function.execution);
    h.int(@as(u8, @intFromBool(function.is_extern)));
    hashReflect(h, @TypeOf(function.foreign), function.foreign);
    hashReflect(h, @TypeOf(function.param_types), function.param_types);
    hashReflect(h, @TypeOf(function.param_ownership), function.param_ownership);
    hashReflect(h, @TypeOf(function.return_type), function.return_type);
    hashReflect(h, @TypeOf(function.return_ownership), function.return_ownership);
}

/// Precomputes the program-wide inputs (function-by-id index, the all-types/enums
/// digest) once so hashing every function in a program is linear overall rather than
/// quadratic.
pub const CguHasher = struct {
    allocator: std.mem.Allocator,
    program: *const ir.Program,
    config: CguConfig,
    fn_by_id: std.AutoHashMapUnmanaged(u32, ir.Function) = .{},
    /// Digest of every struct + enum layout in the program (sorted by name), folded
    /// into every function's hash. Precomputed once.
    types_digest: Digest = undefined,
    /// Digest of EVERY function's signature (sorted by id), folded into every
    /// function's hash. A function's module declares each callee it references as an
    /// extern whose type comes from the callee's signature; a caller can reach a
    /// callee by direct call, virtual/family dispatch, or callback, and resolving
    /// that set precisely would mean replaying virtual method resolution. Folding all
    /// signatures instead is complete by construction: any signature change
    /// invalidates every function (conservative — signature edits are far rarer than
    /// body edits, which leave this digest untouched). Precomputed once.
    signatures_digest: Digest = undefined,
    /// Digest of the set of functions PROVEN to return a fresh owned construct_any
    /// (fresh_any.compute). This is a BODY-derived, cross-CGU property: a caller of
    /// such a function tracks the result as an owned .struct_ptr drop, so a callee
    /// body edit that flips its fresh-Any status changes the caller's emitted
    /// ownership code even though the callee's signature is unchanged. Folded into
    /// every function so such a flip invalidates callers. Precomputed once.
    fresh_any_digest: Digest = undefined,
    /// Digest of construct-family membership (each ConstructImplementation's
    /// type_name + families + constraint). Family virtual-call lowering emits one
    /// dispatch case per implementation satisfying the family, so adding/removing a
    /// family member changes callers' dispatch tables without touching any signature
    /// or type layout. Folded into every function so membership changes invalidate
    /// callers. Precomputed once.
    construct_family_digest: Digest = undefined,

    pub fn init(allocator: std.mem.Allocator, program: *const ir.Program, config: CguConfig) !CguHasher {
        var self = CguHasher{ .allocator = allocator, .program = program, .config = config };
        for (program.functions) |function| {
            try self.fn_by_id.put(allocator, function.id, function);
        }
        self.types_digest = try computeTypesDigest(allocator, program);
        self.signatures_digest = try computeSignaturesDigest(allocator, program);
        self.fresh_any_digest = try computeFreshAnyDigest(allocator, program);
        self.construct_family_digest = try computeConstructFamilyDigest(allocator, program);
        return self;
    }

    pub fn deinit(self: *CguHasher) void {
        self.fn_by_id.deinit(self.allocator);
    }

    /// Content hash of the codegen unit for `function`. See the module doc comment
    /// for the exact, justified input set.
    pub fn hashFunction(self: *CguHasher, function: ir.Function) !Digest {
        var h = Hasher.init();

        // (1) format version + (2) config.
        h.int(codegen_format_version);
        h.bytes(self.config.triple);
        h.bytes(self.config.opt_flag);
        h.int(@intFromEnum(self.config.mode));
        h.int(@as(u8, @intFromBool(self.config.drop_enabled)));

        // (3) F's own lowered IR, in full.
        hashReflect(&h, ir.Function, function);

        // (4) every callee declaration F could emit: all function signatures. Complete
        // by construction (covers direct, virtual/family, and callback dispatch without
        // resolving the call graph); a callee BODY change leaves this untouched, a
        // callee SIGNATURE change invalidates F.
        h.raw(&self.signatures_digest);

        // (5) all struct + enum layouts (precomputed).
        h.raw(&self.types_digest);

        // (6) body-derived cross-CGU properties that change a CALLER's emitted code:
        // the fresh-Any return set (owned-result tracking) and construct-family
        // membership (virtual dispatch tables). Neither is captured by (3)/(4)/(5).
        h.raw(&self.fresh_any_digest);
        h.raw(&self.construct_family_digest);

        return h.final();
    }

    /// Digest for the SUPPORT CGU — the object holding every shared definition
    /// (dtor/clone helpers, call_value dispatchers, host main, hybrid trampolines)
    /// plus the extern declarations of all user functions.
    ///
    /// This folds ONLY what the support object actually emits, so a pure body edit
    /// (arithmetic, constants, control flow) that changes no function's signature,
    /// no dispatcher signature, and no closure shape leaves the digest unchanged
    /// and the support object cached. The complete set of support inputs:
    ///
    ///   1. version + config (opt/triple/mode/drop) — the object's build settings.
    ///   2. Every function SIGNATURE (not body). Covers the extern declarations of
    ///      all functions, the hybrid trampolines, and — via the entry — host main.
    ///      A body edit does not change a signature; a param/return/name/id change
    ///      does, and must rebuild support (its extern decl / trampoline changed).
    ///   3. types_digest — all struct/enum layouts. Covers the per-type dtor/clone
    ///      helper bodies, the typed enum destroy/clone, and the dynamic dispatchers
    ///      (which key on struct type ids): all are pure functions of the layouts.
    ///   4. The call_value dispatcher signature SET. Derived from call_value sites
    ///      in bodies, so a body edit that introduces/removes a distinct call_value
    ///      shape (adding a new dispatcher) rebuilds support; one that does not,
    ///      does not.
    ///   5. Closure capture shapes. Derived from const_closure sites; the closure
    ///      teardown/clone bodies depend on capture types/ownership, so a change to
    ///      any capture shape rebuilds support.
    ///
    /// Anything a support body depends on is either a signature (2), a layout (3),
    /// a dispatcher signature (4), or a closure shape (5); nothing else about a
    /// function body reaches the support object, so omitting bodies here is sound.
    pub fn hashSupport(self: *CguHasher) !Digest {
        var h = Hasher.init();
        // (1) version + config.
        h.int(codegen_format_version);
        h.bytes(self.config.triple);
        h.bytes(self.config.opt_flag);
        h.int(@intFromEnum(self.config.mode));
        h.int(@as(u8, @intFromBool(self.config.drop_enabled)));
        // A domain tag so a support digest can never collide with a single-function
        // digest that happened to fold identical bytes.
        h.bytes("kira.cgu.support");

        // (2) every function signature (bodies excluded), in id order, plus which
        // function is the entry point (host main calls it by symbol).
        h.int(self.program.entry_index);
        const fn_order = try sortedIndicesById(self.allocator, self.program.functions);
        defer self.allocator.free(fn_order);
        h.int(@as(u64, fn_order.len));
        for (fn_order) |index| hashSignature(&h, self.program.functions[index]);

        // (3) all struct + enum layouts (precomputed).
        h.raw(&self.types_digest);

        // (4) call_value dispatcher signature set, sorted by signature hash.
        const dispatchers = try dispatch.collectCallValueDispatchers(self.allocator, self.program.*);
        defer self.allocator.free(dispatchers);
        std.mem.sort(dispatch.DispatcherSig, dispatchers, {}, struct {
            fn less(_: void, a: dispatch.DispatcherSig, b: dispatch.DispatcherSig) bool {
                return a.hash < b.hash;
            }
        }.less);
        h.bytes("dispatchers");
        h.int(@as(u64, dispatchers.len));
        for (dispatchers) |sig| {
            h.int(sig.hash);
            hashReflect(&h, @TypeOf(sig.param_types), sig.param_types);
            hashReflect(&h, ir.ValueType, sig.return_type);
        }

        // (5) closure capture shapes, sorted by closure function id.
        const shapes = try closure_dtors.collectShapes(self.allocator, self.program);
        defer closure_dtors.freeShapes(self.allocator, shapes);
        std.mem.sort(closure_dtors.ClosureShape, shapes, {}, struct {
            fn less(_: void, a: closure_dtors.ClosureShape, b: closure_dtors.ClosureShape) bool {
                return a.function_id < b.function_id;
            }
        }.less);
        h.bytes("closure-shapes");
        h.int(@as(u64, shapes.len));
        for (shapes) |shape| {
            h.int(shape.function_id);
            hashReflect(&h, @TypeOf(shape.capture_types), shape.capture_types);
            hashReflect(&h, @TypeOf(shape.capture_ownership), shape.capture_ownership);
        }

        return h.final();
    }
};

/// Digest of every function's signature, sorted by id. Folded into each function's
/// hash so a callee's signature change invalidates its callers, without having to
/// resolve which functions actually call it (direct, virtual, or callback).
/// Digest of the fresh-Any return set: the ids of functions proven to return a
/// fresh owned construct_any. A caller's ownership tracking depends on this for its
/// callees, so a body edit that flips a function's status must invalidate callers.
fn computeFreshAnyDigest(allocator: std.mem.Allocator, program: *const ir.Program) !Digest {
    var h = Hasher.init();
    var fresh = try fresh_any.compute(allocator, program);
    defer fresh.deinit(allocator);

    var ids = std.array_list.Managed(u32).init(allocator);
    defer ids.deinit();
    var it = fresh.set.keyIterator();
    while (it.next()) |id_ptr| try ids.append(id_ptr.*);
    std.mem.sort(u32, ids.items, {}, std.sort.asc(u32));

    h.int(@as(u64, ids.items.len));
    for (ids.items) |id| h.int(id);
    return h.final();
}

/// Digest of construct-family membership: each ConstructImplementation's type name,
/// families, and constraint (sorted by type name). Family virtual-call dispatch
/// tables are built from this, so membership changes must invalidate callers.
fn computeConstructFamilyDigest(allocator: std.mem.Allocator, program: *const ir.Program) !Digest {
    var h = Hasher.init();
    const impls = program.construct_implementations;
    const order = try allocator.alloc(usize, impls.len);
    defer allocator.free(order);
    for (order, 0..) |*slot, i| slot.* = i;
    const Ctx = struct {
        impls: []const ir.ConstructImplementation,
        fn lessThan(ctx: @This(), a: usize, b: usize) bool {
            return std.mem.lessThan(u8, ctx.impls[a].type_name, ctx.impls[b].type_name);
        }
    };
    std.mem.sort(usize, order, Ctx{ .impls = impls }, Ctx.lessThan);

    h.int(@as(u64, order.len));
    for (order) |index| hashReflect(&h, ir.ConstructImplementation, impls[index]);
    return h.final();
}

fn computeSignaturesDigest(allocator: std.mem.Allocator, program: *const ir.Program) !Digest {
    var h = Hasher.init();
    const order = try sortedIndicesById(allocator, program.functions);
    defer allocator.free(order);
    h.int(@as(u64, order.len));
    for (order) |index| hashSignature(&h, program.functions[index]);
    return h.final();
}

fn computeTypesDigest(allocator: std.mem.Allocator, program: *const ir.Program) !Digest {
    var h = Hasher.init();

    const type_order = try sortedIndicesByName(allocator, ir.TypeDecl, program.types);
    defer allocator.free(type_order);
    h.int(@as(u64, type_order.len));
    for (type_order) |index| {
        hashReflect(&h, ir.TypeDecl, program.types[index]);
    }

    const enum_order = try sortedIndicesByName(allocator, ir.EnumTypeDecl, program.enums);
    defer allocator.free(enum_order);
    h.int(@as(u64, enum_order.len));
    for (enum_order) |index| {
        hashReflect(&h, ir.EnumTypeDecl, program.enums[index]);
    }

    return h.final();
}

fn sortedIndicesById(allocator: std.mem.Allocator, items: []const ir.Function) ![]usize {
    const indices = try allocator.alloc(usize, items.len);
    for (indices, 0..) |*slot, i| slot.* = i;
    const Ctx = struct {
        items: []const ir.Function,
        fn lessThan(ctx: @This(), a: usize, b: usize) bool {
            return ctx.items[a].id < ctx.items[b].id;
        }
    };
    std.mem.sort(usize, indices, Ctx{ .items = items }, Ctx.lessThan);
    return indices;
}

fn sortedIndicesByName(allocator: std.mem.Allocator, comptime T: type, items: []const T) ![]usize {
    const indices = try allocator.alloc(usize, items.len);
    for (indices, 0..) |*slot, i| slot.* = i;
    const Ctx = struct {
        items: []const T,
        fn lessThan(ctx: @This(), a: usize, b: usize) bool {
            return std.mem.lessThan(u8, ctx.items[a].name, ctx.items[b].name);
        }
    };
    std.mem.sort(usize, indices, Ctx{ .items = items }, Ctx.lessThan);
    return indices;
}

// ---------------------------------------------------------------------------
// Tests: the four invalidation properties the incremental cache depends on.
// ---------------------------------------------------------------------------

const testing = std.testing;
const runtime_abi = @import("kira_runtime_abi");

const test_config = CguConfig{
    .triple = "arm64-apple-macosx",
    .opt_flag = "-O2",
    .mode = .llvm_native,
    .drop_enabled = false,
};

fn testFunction(id: u32, name: []const u8, instructions: []ir.Instruction) ir.Function {
    return .{
        .id = id,
        .name = name,
        .execution = .native,
        .return_type = .{ .kind = .integer, .name = "I64" },
        .register_count = 2,
        .local_count = 0,
        .local_types = &.{},
        .instructions = instructions,
    };
}

fn hashOne(program: *const ir.Program, id: u32) !Digest {
    var hasher = try CguHasher.init(testing.allocator, program, test_config);
    defer hasher.deinit();
    for (program.functions) |function| {
        if (function.id == id) return hasher.hashFunction(function);
    }
    return error.NotFound;
}

test "editing one function body invalidates exactly that CGU" {
    var f0_body = [_]ir.Instruction{ .{ .const_int = .{ .dst = 0, .value = 1 } }, .{ .ret = .{ .src = 0 } } };
    var f1_body = [_]ir.Instruction{ .{ .const_int = .{ .dst = 0, .value = 2 } }, .{ .ret = .{ .src = 0 } } };
    var functions = [_]ir.Function{ testFunction(0, "f0", &f0_body), testFunction(1, "f1", &f1_body) };
    const program = ir.Program{ .functions = &functions, .entry_index = 0 };

    const f0_before = try hashOne(&program, 0);
    const f1_before = try hashOne(&program, 1);

    // Change only f0's body (the constant it returns).
    f0_body[0] = .{ .const_int = .{ .dst = 0, .value = 999 } };
    const f0_after = try hashOne(&program, 0);
    const f1_after = try hashOne(&program, 1);

    try testing.expect(!std.mem.eql(u8, &f0_before, &f0_after)); // edited CGU changed
    try testing.expectEqualSlices(u8, &f1_before, &f1_after); // untouched CGU stable
}

test "changing a struct layout invalidates functions that use the program's types" {
    var body = [_]ir.Instruction{.{ .ret = .{ .src = 0 } }};
    var functions = [_]ir.Function{testFunction(0, "f0", &body)};
    var fields = [_]ir.Field{.{ .name = "x", .ty = .{ .kind = .integer, .name = "I64" } }};
    var types = [_]ir.TypeDecl{.{ .name = "Point", .fields = &fields }};
    const program = ir.Program{ .functions = &functions, .types = &types, .entry_index = 0 };

    const before = try hashOne(&program, 0);

    // Change Point's field type (a layout change).
    fields[0] = .{ .name = "x", .ty = .{ .kind = .integer, .name = "I8" } };
    const after = try hashOne(&program, 0);

    try testing.expect(!std.mem.eql(u8, &before, &after));
}

test "callee signature change invalidates caller; body change does not" {
    // f0 references f1 via const_function (a direct callee).
    var caller_body = [_]ir.Instruction{
        .{ .const_function = .{ .dst = 0, .function_id = 1 } },
        .{ .ret = .{ .src = 0 } },
    };
    var callee_body = [_]ir.Instruction{ .{ .const_int = .{ .dst = 0, .value = 1 } }, .{ .ret = .{ .src = 0 } } };
    var functions = [_]ir.Function{ testFunction(0, "f0", &caller_body), testFunction(1, "f1", &callee_body) };
    const program = ir.Program{ .functions = &functions, .entry_index = 0 };

    const caller_before = try hashOne(&program, 0);

    // (a) Change f1's BODY only — caller must NOT be invalidated.
    functions[1].instructions[0] = .{ .const_int = .{ .dst = 0, .value = 42 } };
    const caller_after_body = try hashOne(&program, 0);
    try testing.expectEqualSlices(u8, &caller_before, &caller_after_body);

    // (b) Change f1's SIGNATURE (return type) — caller MUST be invalidated.
    functions[1].return_type = .{ .kind = .integer, .name = "I8" };
    const caller_after_sig = try hashOne(&program, 0);
    try testing.expect(!std.mem.eql(u8, &caller_before, &caller_after_sig));
}

test "hashing is deterministic across independent hasher instances" {
    var body = [_]ir.Instruction{ .{ .const_int = .{ .dst = 0, .value = 7 } }, .{ .ret = .{ .src = 0 } } };
    var functions = [_]ir.Function{testFunction(0, "f0", &body)};
    const program = ir.Program{ .functions = &functions, .entry_index = 0 };
    try testing.expectEqualSlices(u8, &(try hashOne(&program, 0)), &(try hashOne(&program, 0)));
}

fn hashSupportOf(program: *const ir.Program) !Digest {
    var hasher = try CguHasher.init(testing.allocator, program, test_config);
    defer hasher.deinit();
    return hasher.hashSupport();
}

test "support CGU stays cached across a pure body edit, rebuilds on signature change" {
    var f0_body = [_]ir.Instruction{ .{ .const_int = .{ .dst = 0, .value = 1 } }, .{ .ret = .{ .src = 0 } } };
    var f1_body = [_]ir.Instruction{ .{ .const_int = .{ .dst = 0, .value = 2 } }, .{ .ret = .{ .src = 0 } } };
    var functions = [_]ir.Function{ testFunction(0, "f0", &f0_body), testFunction(1, "f1", &f1_body) };
    const program = ir.Program{ .functions = &functions, .entry_index = 0 };

    const support_before = try hashSupportOf(&program);

    // (a) Pure body edit (constant f1 returns) — support has no user bodies, and
    // this changes no signature/dispatcher/closure shape, so it MUST stay cached.
    f1_body[0] = .{ .const_int = .{ .dst = 0, .value = 999 } };
    const support_after_body = try hashSupportOf(&program);
    try testing.expectEqualSlices(u8, &support_before, &support_after_body);

    // (b) Signature change (f1's return type) — the support object holds f1's
    // extern declaration, so it MUST rebuild.
    functions[1].return_type = .{ .kind = .integer, .name = "I8" };
    const support_after_sig = try hashSupportOf(&program);
    try testing.expect(!std.mem.eql(u8, &support_before, &support_after_sig));
}
