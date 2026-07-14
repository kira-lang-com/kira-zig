// Typed array-of-array wrapper teardown/deep-clone for the LLVM C-API backend
// (the nested-array element leak). Array elements are packed as tag-5 RAW_PTR
// bridge values (backend_utils.bridgeTagValue), so kira_array_release runs the
// per-element destructor on each RAW_PTR element. For a `[[T]]` the elements are
// boxed inner `[T]` arrays the outer array owns; without a per-element wrapper
// they fell through to the tag-safe kira_destroy_closure no-op and every inner
// array (box + storage + its own owned contents) leaked. elementClone mirrored
// the gap (closure_clone pass-through), so a deep-cloned outer array would ALIAS
// its inner arrays.
//
// The wrappers generated here are the missing element callbacks. For an inner
// array type K (its bracketed text, e.g. "[Int]", "[Message]"):
//   kira_destroy_arr_<mangled K>(ptr)      — kira_array_release(ptr, D) where D
//                                            is the destructor for K's OWN
//                                            elements (elementDestroy of K).
//   kira_clone_arr_<mangled K>(ptr) -> ptr — kira_array_clone(ptr, C) where C is
//                                            elementClone of K.
// K's element destructor/clone resolve back through the SAME
// Destructors.elementDestroy / elementClone logic (struct typed pair, enum typed
// pair, construct_any dynamic dispatch, or a deeper array wrapper by peeling one
// bracket level), so arbitrary nesting and `[[MyStruct]]` / `[[MessageEnum]]`
// compose. Native only: on hybrid the array_map is empty and every element
// callback falls back to today's behavior (kira_array_release itself defers).
//
// A type is deep-cloned everywhere iff deep-destroyed everywhere
// (.codex/KIRA_MEMORY_MODEL.md §7): elementDestroy and elementClone consult the same
// array_map, so the pairing invariant holds by construction.
const std = @import("std");
const ir = @import("kira_ir");
const llvm = @import("llvm_c.zig");
const capi = @import("backend_capi.zig");
const destructors = @import("backend_capi_destructors.zig");

const Destructors = destructors.Destructors;

// The array type an inner-array wrapper key `K` names: `K` is the bracketed text
// of an array type ("[Int]" -> `[Int]`), whose ValueType has kind=.array and
// name = the ELEMENT text (lower_shared.zig strips the outer brackets). So the
// array named "[Int]" is {kind=.array, name="Int"}; peeling one bracket level off
// `K` yields that element text.
pub fn arrayTypeFromKey(key: []const u8) ir.ValueType {
    return .{ .kind = .array, .name = key[1 .. key.len - 1] };
}

// Deterministic, collision-free, symbol-safe mangling: identifier bytes pass
// through, everything else (brackets, spaces, the "any " prefix's space) becomes
// "_" + two lowercase hex digits. Caller owns the returned buffer.
pub fn mangle(allocator: std.mem.Allocator, key: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    for (key) |ch| {
        const ident = (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or
            (ch >= '0' and ch <= '9') or ch == '_';
        if (ident) {
            try out.append(allocator, ch);
        } else {
            const hex = "0123456789abcdef";
            try out.append(allocator, '_');
            try out.append(allocator, hex[ch >> 4]);
            try out.append(allocator, hex[ch & 0x0f]);
        }
    }
    return out.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Collection: the set of inner-array wrapper keys reachable in the program.
// ---------------------------------------------------------------------------

// An array-of-array element name is a bracketed name ("[...]"): the outer array's
// ValueType carries the inner array's text as its `name`. Collect every such name
// anywhere in the program (struct/class/construct fields, enum variant payloads,
// FFI array/alias/callback element types, and every ValueType in the function IR
// — params, returns, locals, and instructions), then close the set transitively:
// a "[[X]]" wrapper's body needs the "[X]" wrapper, and so on down to the leaf.
//
// Returns a name-sorted slice (deterministic LLVM declaration order, and a stable
// input to cgu_hash). Keys alias ir-owned strings; only the slice is allocated.
pub fn collectKeys(allocator: std.mem.Allocator, program: *const ir.Program) ![][]const u8 {
    var set = std.StringHashMapUnmanaged(void){};
    defer set.deinit(allocator);

    for (program.types) |type_decl| try walk(ir.TypeDecl, type_decl, allocator, &set);
    for (program.enums) |enum_decl| try walk(ir.EnumTypeDecl, enum_decl, allocator, &set);
    for (program.construct_implementations) |impl| try walk(ir.ConstructImplementation, impl, allocator, &set);
    for (program.functions) |function| try walk(ir.Function, function, allocator, &set);

    var keys = try allocator.alloc([]const u8, set.count());
    var i: usize = 0;
    var it = set.keyIterator();
    while (it.next()) |k| : (i += 1) keys[i] = k.*;
    std.mem.sort([]const u8, keys, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    return keys;
}

fn addKey(allocator: std.mem.Allocator, set: *std.StringHashMapUnmanaged(void), name: []const u8) !void {
    var cur = name;
    while (isBracketed(cur)) {
        const gop = try set.getOrPut(allocator, cur);
        if (gop.found_existing) return; // its closure is already recorded
        cur = cur[1 .. cur.len - 1];
    }
}

fn isBracketed(name: []const u8) bool {
    return name.len >= 2 and name[0] == '[' and name[name.len - 1] == ']';
}

fn consider(allocator: std.mem.Allocator, set: *std.StringHashMapUnmanaged(void), vt: ir.ValueType) !void {
    if (vt.kind != .array) return;
    const name = vt.name orelse return;
    // The element is itself an array iff the array's element-text name is
    // bracketed; that bracketed name is the inner-array wrapper key.
    if (isBracketed(name)) try addKey(allocator, set, name);
}

// Reflection-driven ValueType visitor — mirrors cgu_hash.hashReflect's type
// handling so a newly added IR field can never silently hide a ValueType. Any
// unhandled type is a compile error (a conscious decision, not a silent miss).
fn walk(comptime T: type, value: T, allocator: std.mem.Allocator, set: *std.StringHashMapUnmanaged(void)) !void {
    if (T == ir.ValueType) try consider(allocator, set, value);
    switch (@typeInfo(T)) {
        .bool, .int, .comptime_int, .float, .@"enum", .void => {},
        .optional => |info| {
            if (value) |payload| try walk(info.child, payload, allocator, set);
        },
        .pointer => |info| switch (info.size) {
            .slice => {
                if (info.child != u8) {
                    for (value) |element| try walk(info.child, element, allocator, set);
                }
            },
            .one => try walk(info.child, value.*, allocator, set),
            else => @compileError("array_dtors.walk: unsupported pointer kind for " ++ @typeName(T)),
        },
        .@"struct" => |info| {
            inline for (info.fields) |field| {
                try walk(field.type, @field(value, field.name), allocator, set);
            }
        },
        .@"union" => |info| {
            const Tag = info.tag_type orelse @compileError("array_dtors.walk: untagged union " ++ @typeName(T));
            const active = std.meta.activeTag(value);
            inline for (info.fields) |field| {
                if (active == @field(Tag, field.name)) {
                    try walk(field.type, @field(value, field.name), allocator, set);
                }
            }
        },
        .array => |info| {
            for (value) |element| try walk(info.child, element, allocator, set);
        },
        else => @compileError("array_dtors.walk: unsupported type " ++ @typeName(T)),
    }
}

// ---------------------------------------------------------------------------
// Body generation (support CGU only; per-function CGUs just declare the pair).
// ---------------------------------------------------------------------------

pub fn build(
    api: *const llvm.Api,
    types: capi.Types,
    program: *const ir.Program,
    runtime: capi.RuntimeDecls,
    dtors: *const Destructors,
) !void {
    const builder = api.LLVMCreateBuilderInContext(types.context);
    defer api.LLVMDisposeBuilder(builder);

    var it = dtors.array_map.iterator();
    while (it.next()) |entry| {
        const inner = arrayTypeFromKey(entry.key_ptr.*);
        buildDestroy(api, builder, types, runtime, dtors, program, inner, entry.value_ptr.destroy.fn_value);
        buildClone(api, builder, types, runtime, dtors, program, inner, entry.value_ptr.clone.fn_value);
    }
}

fn buildDestroy(
    api: *const llvm.Api,
    b: llvm.c.LLVMBuilderRef,
    types: capi.Types,
    runtime: capi.RuntimeDecls,
    dtors: *const Destructors,
    program: *const ir.Program,
    inner_array_ty: ir.ValueType,
    fn_value: llvm.c.LLVMValueRef,
) void {
    const entry = api.LLVMAppendBasicBlockInContext(types.context, fn_value, "entry");
    api.LLVMPositionBuilderAtEnd(b, entry);
    const ptr = api.LLVMGetParam(fn_value, 0);
    // kira_array_release is null/inactive-safe, so no guard is needed. The
    // per-element callback is the destructor for the INNER array's OWN elements
    // (a deeper array wrapper, a struct/enum typed destroy, or the tag-safe
    // closure no-op for primitives — invoked only on RAW_PTR elements).
    const elem = dtors.elementDestroy(program, inner_array_ty) orelse api.LLVMConstNull(types.ptr_ty);
    var args = [_]llvm.c.LLVMValueRef{ ptr, elem };
    _ = api.LLVMBuildCall2(b, runtime.array_release.ty, runtime.array_release.fn_value, &args, args.len, "");
    _ = api.LLVMBuildRetVoid(b);
}

fn buildClone(
    api: *const llvm.Api,
    b: llvm.c.LLVMBuilderRef,
    types: capi.Types,
    runtime: capi.RuntimeDecls,
    dtors: *const Destructors,
    program: *const ir.Program,
    inner_array_ty: ir.ValueType,
    fn_value: llvm.c.LLVMValueRef,
) void {
    const entry = api.LLVMAppendBasicBlockInContext(types.context, fn_value, "entry");
    api.LLVMPositionBuilderAtEnd(b, entry);
    const ptr = api.LLVMGetParam(fn_value, 0);
    // kira_array_clone is null/inactive-safe (returns NULL). The element clone
    // deep-copies each RAW_PTR element (deeper array, struct, or enum) so the
    // cloned inner array owns independent storage — never aliases the source.
    const elem = dtors.elementClone(program, inner_array_ty) orelse api.LLVMConstNull(types.ptr_ty);
    var args = [_]llvm.c.LLVMValueRef{ ptr, elem };
    const result = api.LLVMBuildCall2(b, runtime.array_clone.ty, runtime.array_clone.fn_value, &args, args.len, "arr.clone");
    _ = api.LLVMBuildRet(b, result);
}
