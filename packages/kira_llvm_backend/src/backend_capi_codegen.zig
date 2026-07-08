// Per-function instruction lowering for the LLVM C-API backend. Split out of
// backend_capi.zig (Core Law #5): the FunctionCodegen state machine that walks
// a function's IR instructions and builds LLVM basic blocks and values.
const std = @import("std");
const ir = @import("kira_ir");
const backend_api = @import("kira_backend_api");
const llvm = @import("llvm_c.zig");
const utils = @import("backend_utils.zig");
const runtime_symbols = @import("runtime_symbols.zig");
const capi = @import("backend_capi.zig");
const dispatch = @import("backend_capi_dispatch.zig");
const DispatcherDecl = dispatch.DispatcherDecl;
const hashCallValueSignature = dispatch.hashCallValueSignature;
const unpackBridgeValue = dispatch.unpackBridgeValue;

const functionExecutionById = utils.functionExecutionById;
const functionById = utils.functionById;
const resolveExecution = utils.resolveExecution;
const inferRegisterTypes = utils.inferRegisterTypes;
const allocPrintZ = utils.allocPrintZ;
const findEnumDecl = utils.findEnumDecl;
const print = @import("backend_capi_print.zig");
const value_repr = @import("backend_capi_value_repr.zig");
const drop = @import("backend_capi_drop.zig");
const aggregate = @import("backend_capi_aggregate.zig");
const native_state = @import("backend_capi_native_state.zig");
const closures = @import("backend_capi_closures.zig");
const ffi = @import("backend_capi_ffi.zig");
const calls = @import("backend_capi_calls.zig");
const returns = @import("backend_capi_returns.zig");

pub const FunctionCodegen = struct {
    allocator: std.mem.Allocator,
    api: *const llvm.Api,
    builder: llvm.c.LLVMBuilderRef,
    module_ref: llvm.c.LLVMModuleRef,
    types: capi.Types,
    runtime_decls: capi.RuntimeDecls,
    struct_types: *const std.StringHashMapUnmanaged(llvm.c.LLVMTypeRef),
    dispatchers: *const std.AutoHashMapUnmanaged(u64, DispatcherDecl),
    dtors: *const drop.Destructors,
    drop_enabled: bool,
    request: backend_api.CompileRequest,
    functions: *const std.AutoHashMapUnmanaged(u32, llvm.c.LLVMValueRef),
    function_decl: ir.Function,
    function_value: llvm.c.LLVMValueRef,

    registers: []llvm.c.LLVMValueRef = &.{},
    register_types: []ir.ValueType = &.{},
    locals: []llvm.c.LLVMValueRef = &.{},
    blocks: std.AutoHashMapUnmanaged(u32, llvm.c.LLVMBasicBlockRef) = .{},
    string_counter: usize = 0,
    terminated: bool = false,
    // Owned-value drop state (active only when drop_enabled). One cleanup slot
    // (entry-block alloca ptr, init null) per heap-allocating instruction; the
    // register/local holding the value points at its slot index.
    drop_slots: std.ArrayListUnmanaged(drop.OwnedSlot) = .empty,
    register_slot: []?u32 = &.{},
    local_slot: []?u32 = &.{},
    // register -> backing local (load_local/local_ptr) so copy_indirect can resolve
    // which local owns its destination contents.
    reg_local: []?u32 = &.{},
    // local -> struct_contents cleanup slot index for copy_indirect destinations.
    copy_dest_slot: []?u32 = &.{},
    // register -> was produced by field_ptr/subobject_ptr (addresses OWNED struct
    // field storage). A store_indirect of a string frees the field's prior buffer
    // only through such a pointer; any other target (e.g. a borrow-mut pointer to
    // a caller's local) gets clone-in without free-old (the caller's per-local
    // slot still owns the prior buffer — freeing it here would double-free).
    reg_field_ptr: []bool = &.{},
    // register -> holds a const_string literal ({static ptr, len}, NUL-terminated
    // global). The only string provenance that may be ALIASED into a CString field:
    // every other untracked string register is a view of a buffer some slot frees
    // at scope exit (a string local's clone, a parameter owned by the caller).
    reg_string_literal: []bool = &.{},
    // local -> per-local cleanup slot index for owned enum locals (`var`/`let` of enum
    // type). Mirrors copy_dest_slot for structs: one slot per enum local holding the
    // local's current live heap enum block, reused across reassignments (drop-before-
    // overwrite), freed once at exit, escaped on return. Without it each alloc_enum gets
    // its own slot and a branch-reassigned enum var's return frees the wrong (last-
    // lowered) branch's slot, freeing the live returned enum (use-after-free).
    enum_local_slot: []?u32 = &.{},
    // local -> per-local cleanup slot index for string locals. A string local owns a
    // deep CLONE of every value assigned to it (strings are deep values, Copy in the
    // language): the store_local site clones the source buffer into the local, the
    // slot drops the prior clone on reassignment (loop re-entry), and exit cleanup
    // frees the final one. Registers keep their own producer slots; a `ret` of a
    // string local clones again (the register is untracked by design — see
    // onStoreLocal's string exclusion in backend_capi_drop.zig).
    string_local_slot: []?u32 = &.{},
    // register -> produced by a move/owned load_local of an ffi_struct local. The
    // destination copy_indirect must treat such a source as a MOVE (no clone_contents;
    // ownership transfers and the source local's cleanup slot is escaped) rather than
    // as a value copy.
    reg_move_local: []?u32 = &.{},

    // Build a scratch `alloca` in the function entry block regardless of where the
    // builder is currently positioned. LLVM only reclaims (and SROA/mem2reg only
    // promotes) allocas placed in the entry block; an alloca emitted at an arbitrary
    // insertion point inside a loop body becomes a *dynamic* stack allocation whose
    // space is not released until the function returns — so a per-iteration scratch
    // slot (array op / runtime-call / FFI bridge buffer) grows the stack every
    // iteration and overflows it. These scratch slots are written and consumed
    // immediately, so hoisting the alloca to the entry block (allocated once, reused
    // each iteration) is both correct and the standard LLVM idiom. The store/use of
    // the slot stays at the caller's current position.
    pub fn entryAlloca(self: *FunctionCodegen, ty: llvm.c.LLVMTypeRef, name: [:0]const u8) llvm.c.LLVMValueRef {
        const api = self.api;
        const restore = api.LLVMGetInsertBlock(self.builder);
        const entry = api.LLVMGetEntryBasicBlock(self.function_value);
        const terminator = api.LLVMGetBasicBlockTerminator(entry);
        if (terminator != null) {
            api.LLVMPositionBuilderBefore(self.builder, terminator);
        } else {
            api.LLVMPositionBuilderAtEnd(self.builder, entry);
        }
        const slot = api.LLVMBuildAlloca(self.builder, ty, name.ptr);
        api.LLVMPositionBuilderAtEnd(self.builder, restore);
        return slot;
    }

    pub fn lower(self: *FunctionCodegen) !void {
        const api = self.api;
        const entry_block = api.LLVMAppendBasicBlockInContext(self.types.context, self.function_value, "entry");
        api.LLVMPositionBuilderAtEnd(self.builder, entry_block);

        // Register types must be inferred BEFORE drop.setup: the pre-scan needs them
        // to recognize string concatenation (`.add` with a string dst) as an owned
        // string-buffer producer.
        self.register_types = try inferRegisterTypes(self.allocator, self.request.program.programPtr().*, self.function_decl);
        defer self.allocator.free(self.register_types);

        try drop.setup(self);
        defer drop.teardown(self);
        self.registers = try self.allocator.alloc(llvm.c.LLVMValueRef, self.function_decl.register_count);
        defer self.allocator.free(self.registers);
        @memset(self.registers, null);
        self.reg_move_local = try self.allocator.alloc(?u32, self.function_decl.register_count);
        defer self.allocator.free(self.reg_move_local);
        @memset(self.reg_move_local, null);
        self.locals = try self.allocator.alloc(llvm.c.LLVMValueRef, self.function_decl.local_count);
        defer self.allocator.free(self.locals);
        @memset(self.locals, null);
        defer self.blocks.deinit(self.allocator);

        // Allocate storage for every local in the entry block. Each local slot is an
        // i64 in the register ABI. A struct (ffi_struct) local additionally needs its
        // own zero-initialized backing storage, with the slot holding a pointer to it:
        // the IR addresses such a local by value (`copy_indirect(dst = load_local)`),
        // so the slot must point at real struct-sized storage, not be left undefined.
        for (self.function_decl.local_types, 0..) |local_type, index| {
            self.locals[index] = api.LLVMBuildAlloca(self.builder, self.types.llvmType(local_type), "local");
            if (local_type.kind == .ffi_struct) {
                if (local_type.name) |name| {
                    if (self.struct_types.get(name)) |struct_ty| {
                        const storage = api.LLVMBuildAlloca(self.builder, struct_ty, "local.storage");
                        _ = api.LLVMBuildStore(self.builder, api.LLVMConstNull(struct_ty), storage);
                        const storage_int = api.LLVMBuildPtrToInt(self.builder, storage, self.types.i64, "local.storage.int");
                        _ = api.LLVMBuildStore(self.builder, storage_int, self.locals[index]);
                    }
                }
            }
        }
        // The first param_count locals are the function parameters; bind them. A struct
        // parameter's pointer overwrites the backing-storage pointer above (the callee
        // borrows the caller's struct), which is correct.
        for (self.function_decl.param_types, 0..) |_, index| {
            const param = api.LLVMGetParam(self.function_value, @intCast(index));
            _ = api.LLVMBuildStore(self.builder, param, self.locals[index]);
        }
        // Seed owned-aggregate param cleanup slots now that the params are bound.
        drop.seedOwnedParams(self);

        // Pre-create a basic block for every label target.
        for (self.function_decl.instructions) |instruction| {
            if (instruction == .label) {
                const block = api.LLVMAppendBasicBlockInContext(self.types.context, self.function_value, "blk");
                try self.blocks.put(self.allocator, instruction.label.id, block);
            }
        }

        self.terminated = false;
        for (self.function_decl.instructions) |instruction| {
            // Skip dead instructions that follow a terminator until the next label.
            if (self.terminated and instruction != .label) continue;
            try self.lowerInstruction(instruction);
        }

        if (!self.terminated) {
            drop.emitExitCleanup(self, null);
            if (self.function_decl.return_type.kind == .void) {
                _ = api.LLVMBuildRetVoid(self.builder);
            } else {
                // A non-void function that falls off the end is ill-formed Kira;
                // emit a defined zero so the module still verifies.
                _ = api.LLVMBuildRet(self.builder, self.zeroValue(self.function_decl.return_type));
            }
        }
    }

    fn zeroValue(self: *FunctionCodegen, value_type: ir.ValueType) llvm.c.LLVMValueRef {
        return value_repr.zeroValue(self, value_type);
    }

    fn isFloat(self: *FunctionCodegen, reg: u32) bool {
        return reg < self.register_types.len and self.register_types[reg].kind == .float;
    }

    fn isString(self: *FunctionCodegen, reg: u32) bool {
        return reg < self.register_types.len and self.register_types[reg].kind == .string;
    }

    // Clone-on-read for a string produced from an aggregate (struct field,
    // native-state slot, array element, enum payload): replace the borrowed
    // {ptr,len} view in dst with a deep copy and record it in dst's string_buf
    // cleanup slot. The aggregate keeps sole ownership of its buffer; the reader
    // owns an independent one (strings are Copy in the language, so a read must
    // outlive any later mutation/destruction of the aggregate). No-op when drop
    // is disabled — dst then keeps the borrowed view, the pre-drop model.
    fn cloneStringOnRead(self: *FunctionCodegen, dst: u32) void {
        if (!self.drop_enabled) return;
        if (dst >= self.register_slot.len or self.register_slot[dst] == null) return;
        self.registers[dst] = drop.cloneStringValue(self, self.registers[dst]);
        drop.trackStringRegister(self, dst);
    }

    fn lowerInstruction(self: *FunctionCodegen, instruction: ir.Instruction) !void {
        const api = self.api;
        const b = self.builder;
        switch (instruction) {
            .const_int => |v| self.registers[v.dst] = api.LLVMConstInt(self.types.i64, @bitCast(v.value), 1),
            .const_float => |v| self.registers[v.dst] = api.LLVMConstReal(self.types.llvmType(self.register_types[v.dst]), v.value),
            .const_bool => |v| self.registers[v.dst] = api.LLVMConstInt(self.types.bool_ty, if (v.value) 1 else 0, 0),
            .const_null_ptr => |v| self.registers[v.dst] = api.LLVMConstInt(self.types.i64, 0, 0),
            .const_string => |v| {
                self.registers[v.dst] = try self.buildStringConstant(v.value);
                self.string_counter += 1;
                if (v.dst < self.reg_string_literal.len) self.reg_string_literal[v.dst] = true;
            },
            .add => |v| {
                if (self.isString(v.lhs)) {
                    self.registers[v.dst] = value_repr.lowerStringConcat(self, self.registers[v.lhs], self.registers[v.rhs]);
                    // The concat buffer is a fresh malloc; record it in the dst's
                    // string_buf cleanup slot (drop-before-overwrite reclaims the
                    // previous iteration's buffer in loops).
                    drop.trackStringRegister(self, v.dst);
                } else if (self.isFloat(v.lhs)) {
                    self.registers[v.dst] = api.LLVMBuildFAdd(b, self.registers[v.lhs], self.registers[v.rhs], "fadd");
                } else {
                    self.registers[v.dst] = api.LLVMBuildAdd(b, self.registers[v.lhs], self.registers[v.rhs], "add");
                }
            },
            .subtract => |v| self.registers[v.dst] = if (self.isFloat(v.lhs)) api.LLVMBuildFSub(b, self.registers[v.lhs], self.registers[v.rhs], "fsub") else api.LLVMBuildSub(b, self.registers[v.lhs], self.registers[v.rhs], "sub"),
            .multiply => |v| self.registers[v.dst] = if (self.isFloat(v.lhs)) api.LLVMBuildFMul(b, self.registers[v.lhs], self.registers[v.rhs], "fmul") else api.LLVMBuildMul(b, self.registers[v.lhs], self.registers[v.rhs], "mul"),
            .divide => |v| self.registers[v.dst] = if (self.isFloat(v.lhs)) api.LLVMBuildFDiv(b, self.registers[v.lhs], self.registers[v.rhs], "fdiv") else if (v.unsigned) api.LLVMBuildUDiv(b, self.registers[v.lhs], self.registers[v.rhs], "udiv") else api.LLVMBuildSDiv(b, self.registers[v.lhs], self.registers[v.rhs], "sdiv"),
            .modulo => |v| self.registers[v.dst] = if (self.isFloat(v.lhs)) api.LLVMBuildFRem(b, self.registers[v.lhs], self.registers[v.rhs], "frem") else if (v.unsigned) api.LLVMBuildURem(b, self.registers[v.lhs], self.registers[v.rhs], "urem") else api.LLVMBuildSRem(b, self.registers[v.lhs], self.registers[v.rhs], "srem"),
            .convert => |v| {
                const src_is_float = self.isFloat(v.src);
                if (v.reinterpret) {
                    // Float<->bits: preserve the bit pattern, change only the type
                    // (Kira Float is f64, integers live in i64 — same width).
                    if (v.target == .float) {
                        self.registers[v.dst] = api.LLVMBuildBitCast(b, self.registers[v.src], self.types.double_ty, "bitsToFloat");
                    } else {
                        // A named F32 source is a 32-bit LLVM float; widen it to f64
                        // first so the bitcast has matching widths and the result
                        // matches the VM, which stores every float as f64. Without this
                        // floatToBits(F32(..)) would build an invalid float -> i64 cast.
                        var src = self.registers[v.src];
                        if (api.LLVMTypeOf(src) == self.types.float_ty) {
                            src = api.LLVMBuildFPExt(b, src, self.types.double_ty, "f32.widen");
                        }
                        self.registers[v.dst] = api.LLVMBuildBitCast(b, src, self.types.i64, "floatToBits");
                    }
                } else if (v.target == .float) {
                    // Int -> Float is sitofp; Float -> Float is identity.
                    self.registers[v.dst] = if (src_is_float) self.registers[v.src] else api.LLVMBuildSIToFP(b, self.registers[v.src], self.types.double_ty, "sitofp");
                } else {
                    // Float -> Int truncates toward zero; Int -> Int is identity.
                    self.registers[v.dst] = if (src_is_float) value_repr.lowerFloatToIntSaturating(self, self.registers[v.src]) else self.registers[v.src];
                }
            },
            .compare => |v| self.registers[v.dst] = try value_repr.lowerCompare(self, v),
            .bitwise => |v| self.registers[v.dst] = switch (v.op) {
                .bit_and => api.LLVMBuildAnd(b, self.registers[v.lhs], self.registers[v.rhs], "and"),
                .bit_or => api.LLVMBuildOr(b, self.registers[v.lhs], self.registers[v.rhs], "or"),
                .bit_xor => api.LLVMBuildXor(b, self.registers[v.lhs], self.registers[v.rhs], "xor"),
                .shift_left, .shift_right => shift_blk: {
                    // Kira shift amount is taken mod 64 (vm_values.zig); an LLVM
                    // shift with a count >= the bit width is poison/UB, so mask the
                    // RHS to match the VM before emitting the shift (Codex review).
                    const amt = api.LLVMBuildAnd(b, self.registers[v.rhs], api.LLVMConstInt(self.types.i64, 63, 0), "shamt");
                    break :shift_blk switch (v.op) {
                        .shift_left => api.LLVMBuildShl(b, self.registers[v.lhs], amt, "shl"),
                        .shift_right => if (v.unsigned) api.LLVMBuildLShr(b, self.registers[v.lhs], amt, "lshr") else api.LLVMBuildAShr(b, self.registers[v.lhs], amt, "ashr"),
                        else => unreachable,
                    };
                },
            },
            .unary => |v| self.registers[v.dst] = switch (v.op) {
                .negate => if (self.isFloat(v.src)) api.LLVMBuildFNeg(b, self.registers[v.src], "fneg") else api.LLVMBuildNeg(b, self.registers[v.src], "neg"),
                .not => api.LLVMBuildNot(b, self.registers[v.src], "not"),
                .bit_not => api.LLVMBuildNot(b, self.registers[v.src], "bitnot"),
            },
            .store_local => |v| {
                // A string local owns a deep CLONE of every assigned value (strings are
                // Copy in the language; aliasing the source buffer would dangle when the
                // source's producer slot drops it on loop overwrite or scope exit). The
                // per-local slot frees the prior clone on reassignment.
                if (!v.borrow and drop.hasStringLocalSlot(self, v.local)) {
                    const cloned = drop.cloneStringValue(self, self.registers[v.src]);
                    _ = api.LLVMBuildStore(b, cloned, self.locals[v.local]);
                    drop.onStoreLocalString(self, v.local, cloned);
                } else {
                    _ = api.LLVMBuildStore(b, self.registers[v.src], self.locals[v.local]);
                    drop.onStoreLocal(self, v.local, v.src, v.borrow);
                }
            },
            .load_local => |v| {
                self.registers[v.dst] = api.LLVMBuildLoad2(b, self.types.llvmType(self.function_decl.local_types[v.local]), self.locals[v.local], "load");
                if (v.dst < self.reg_move_local.len and v.local < self.function_decl.local_types.len and
                    self.function_decl.local_types[v.local].kind == .ffi_struct)
                {
                    self.reg_move_local[v.dst] = switch (v.ownership) {
                        .move, .owned => v.local,
                        else => null,
                    };
                }
                drop.onLoadLocal(self, v.dst, v.local);
                drop.recordRegLocal(self, v.dst, v.local);
            },
            .local_ptr => |v| {
                self.registers[v.dst] = api.LLVMBuildPtrToInt(b, self.locals[v.local], self.types.i64, "local.ptr");
                drop.recordRegLocal(self, v.dst, v.local);
            },
            .branch => |v| {
                const true_block = self.blocks.get(v.true_label) orelse return error.UnknownLabel;
                const false_block = self.blocks.get(v.false_label) orelse return error.UnknownLabel;
                _ = api.LLVMBuildCondBr(b, self.registers[v.condition], true_block, false_block);
                self.terminated = true;
            },
            .jump => |v| {
                const target = self.blocks.get(v.label) orelse return error.UnknownLabel;
                _ = api.LLVMBuildBr(b, target);
                self.terminated = true;
            },
            .label => |v| {
                const block = self.blocks.get(v.id) orelse return error.UnknownLabel;
                if (!self.terminated) _ = api.LLVMBuildBr(b, block);
                api.LLVMPositionBuilderAtEnd(b, block);
                self.terminated = false;
            },
            .print => |v| try print.lowerPrint(self, self.register_types[v.src], self.registers[v.src]),
            .call => |v| try calls.lowerCall(self, v),
            // Return-value ownership promotions live in backend_capi_returns.zig
            // (the call-result invariants: struct/array/enum/string/closure
            // results are always caller-owned fresh values).
            .ret => |v| returns.lowerReturn(self, v.src),
            .alloc_struct => |v| {
                const struct_ty = self.struct_types.get(v.type_name) orelse return error.UnsupportedExecutableFeature;
                const size = api.LLVMSizeOf(struct_ty);
                var args = [_]llvm.c.LLVMValueRef{
                    api.LLVMConstInt(self.types.i64, ir.nativeStateTypeId(v.type_name), 0),
                    size,
                };
                const ptr = api.LLVMBuildCall2(b, self.runtime_decls.struct_alloc.ty, self.runtime_decls.struct_alloc.fn_value, &args, args.len, "struct.alloc");
                _ = api.LLVMBuildStore(b, api.LLVMConstNull(struct_ty), ptr);
                self.registers[v.dst] = api.LLVMBuildPtrToInt(b, ptr, self.types.i64, "struct.ptr");
                drop.onAlloc(self, v.dst);
            },
            .field_ptr => |v| {
                const struct_ty = self.struct_types.get(v.base_type_name) orelse return error.UnsupportedExecutableFeature;
                const base = api.LLVMBuildIntToPtr(b, self.registers[v.base], self.types.ptr_ty, "field.base");
                var indices = [_]llvm.c.LLVMValueRef{ api.LLVMConstInt(self.types.i32, 0, 0), api.LLVMConstInt(self.types.i32, v.field_index, 0) };
                const field_ptr = api.LLVMBuildInBoundsGEP2(b, struct_ty, base, &indices, indices.len, "field.ptr");
                self.registers[v.dst] = api.LLVMBuildPtrToInt(b, field_ptr, self.types.i64, "field.ptrint");
                if (v.dst < self.reg_field_ptr.len) self.reg_field_ptr[v.dst] = true;
            },
            .subobject_ptr => |v| {
                const base_name = self.register_types[v.base].name orelse return error.UnsupportedExecutableFeature;
                const struct_ty = self.struct_types.get(base_name) orelse return error.UnsupportedExecutableFeature;
                const base = api.LLVMBuildIntToPtr(b, self.registers[v.base], self.types.ptr_ty, "sub.base");
                var indices = [_]llvm.c.LLVMValueRef{ api.LLVMConstInt(self.types.i32, 0, 0), api.LLVMConstInt(self.types.i32, v.offset, 0) };
                const sub_ptr = api.LLVMBuildInBoundsGEP2(b, struct_ty, base, &indices, indices.len, "sub.ptr");
                self.registers[v.dst] = api.LLVMBuildPtrToInt(b, sub_ptr, self.types.i64, "sub.ptrint");
                if (v.dst < self.reg_field_ptr.len) self.reg_field_ptr[v.dst] = true;
            },
            .load_indirect => |v| {
                self.registers[v.dst] = try self.lowerLoadIndirect(v);
                // A string field read clones (strings are deep values; the field keeps
                // sole ownership of its buffer, the reader owns an independent copy).
                if (v.ty.kind == .string) self.cloneStringOnRead(v.dst);
                // Checker-verified field move-out: ownership transfers to dst.
                // Track it for scope-exit cleanup and null the field storage so the
                // owner's destructor / the enforced re-init overwrite cannot free
                // the value this register now owns. construct_any fields transfer
                // the same way (Rust partial move): the base's typed destructor
                // frees Any fields (rc.anyfield), so the moved-out tree must leave
                // a nulled slot behind or the base drop frees it under the new
                // owner (the KiraUI `let root = app.content` pattern).
                if (v.moved and self.drop_enabled and (v.ty.kind == .array or v.ty.kind == .enum_instance or v.ty.kind == .construct_any)) {
                    drop.onAlloc(self, v.dst);
                    const moved_field = api.LLVMBuildIntToPtr(b, self.registers[v.ptr], self.types.ptr_ty, "load.move.field");
                    _ = api.LLVMBuildStore(b, api.LLVMConstNull(self.types.ptr_ty), moved_field);
                }
            },
            .store_indirect => |v| try aggregate.lowerStoreIndirect(self, v),
            .copy_indirect => |v| {
                const struct_ty = self.struct_types.get(v.type_name) orelse return error.UnsupportedExecutableFeature;
                const src = api.LLVMBuildIntToPtr(b, self.registers[v.src_ptr], self.types.ptr_ty, "copy.src");
                const dst = api.LLVMBuildIntToPtr(b, self.registers[v.dst_ptr], self.types.ptr_ty, "copy.dst");
                const move_local = if (v.src_ptr < self.reg_move_local.len) self.reg_move_local[v.src_ptr] else null;
                // Release any prior occupant of the destination's stack shell before the
                // shallow store discards its array pointers (loop-body reassignment).
                if (self.drop_enabled) drop.releasePriorCopyDest(self, v.dst_ptr, v.type_name);
                const value = api.LLVMBuildLoad2(b, struct_ty, src, "copy.val");
                _ = api.LLVMBuildStore(b, value, dst);
                // Deep-clone the destination's contents so it owns storage independent of
                // the source — affine value semantics (`var b = a` is a copy, not an
                // alias). This is the DEFAULT for pure-Kira value structs, matching the
                // text backend's copy_indirect; FFI/native structs keep the shallow,
                // device-validated copy. With drop on we additionally clone any tracked
                // type and reclaim the clone by tracking dst as struct_contents (aliasing
                // would double-free, since src and dst are separate drop slots).
                const clone_default = blk: {
                    const td = utils.findTypeDecl(self.request.program.programPtr(), v.type_name) orelse break :blk false;
                    break :blk td.ffi == null;
                };
                if (move_local == null and (self.drop_enabled or clone_default)) {
                    if (self.dtors.map.get(v.type_name)) |h| {
                        var cc = [_]llvm.c.LLVMValueRef{dst};
                        _ = api.LLVMBuildCall2(b, h.clone_contents.ty, h.clone_contents.fn_value, &cc, cc.len, "");
                    }
                }
                if (self.drop_enabled) drop.onCopyDest(self, v.dst_ptr, dst, v.type_name);
                if (move_local) |local| {
                    // The contents moved into dst; a heap-shell source (owned
                    // param / call result) leaves an empty shell nothing owns —
                    // free it (shell only) before the slot is nulled.
                    drop.onMoveLocalHeapShell(self, local, src);
                    drop.onMoveLocal(self, local);
                }
            },
            .c_string_to_string => |v| {
                self.registers[v.dst] = try calls.lowerCStringToString(self, v);
                // The coercion malloc'd an independent copy; dst's string_buf slot
                // owns it (this was leak class #1: every CString→String coercion).
                drop.trackStringRegister(self, v.dst);
            },
            .call_virtual => |v| try calls.lowerCallVirtual(self, v),
            .const_function => |v| {
                self.registers[v.dst] = switch (v.representation) {
                    // callable_value: the i64 is just the function id (high bit clear).
                    .callable_value => api.LLVMConstInt(self.types.i64, v.function_id, 0),
                    // native_callback: a raw function pointer.
                    .native_callback => blk: {
                        const fn_value = self.functions.get(v.function_id) orelse return error.MissingFunctionDeclaration;
                        break :blk api.LLVMBuildPtrToInt(b, fn_value, self.types.i64, "fnptr");
                    },
                };
            },
            .const_closure => |v| try closures.lowerConstClosure(self, v),
            .call_value => |v| try closures.lowerCallValue(self, v),
            .string_len => |v| self.registers[v.dst] = api.LLVMBuildExtractValue(b, self.registers[v.string], 1, "string.len"),
            .alloc_enum => |v| {
                try aggregate.lowerAllocEnum(self, v);
                drop.onAlloc(self, v.dst);
            },
            .enum_tag => |v| {
                const base = api.LLVMBuildIntToPtr(b, self.registers[v.src], self.types.ptr_ty, "enum.tag.base");
                var idx = [_]llvm.c.LLVMValueRef{api.LLVMConstInt(self.types.i64, 0, 0)};
                const slot = api.LLVMBuildInBoundsGEP2(b, self.types.i64, base, &idx, idx.len, "enum.tag.slot");
                self.registers[v.dst] = api.LLVMBuildLoad2(b, self.types.i64, slot, "enum.tag");
            },
            .enum_payload => |v| {
                self.registers[v.dst] = try aggregate.lowerEnumPayload(self, v);
                // A string payload read clones — the enum's heap box keeps its
                // buffer, the reader owns an independent copy.
                if (v.payload_ty.kind == .string) self.cloneStringOnRead(v.dst);
            },
            .alloc_native_state => |v| try native_state.lowerAllocNativeState(self, v),
            .free_native_state => |v| {
                const state = api.LLVMBuildIntToPtr(b, self.registers[v.state], self.types.ptr_ty, "state.free.in");
                var args = [_]llvm.c.LLVMValueRef{state};
                _ = api.LLVMBuildCall2(b, self.runtime_decls.state_free.ty, self.runtime_decls.state_free.fn_value, &args, args.len, "");
            },
            .recover_native_state => |v| {
                const state = api.LLVMBuildIntToPtr(b, self.registers[v.state], self.types.ptr_ty, "state.recover.in");
                var args = [_]llvm.c.LLVMValueRef{ state, api.LLVMConstInt(self.types.i64, v.type_id, 0) };
                const payload = api.LLVMBuildCall2(b, self.runtime_decls.state_recover.ty, self.runtime_decls.state_recover.fn_value, &args, args.len, "state.payload");
                self.registers[v.dst] = api.LLVMBuildPtrToInt(b, payload, self.types.i64, "state.recover.out");
            },
            .native_state_field_get => |v| {
                const payload = api.LLVMBuildIntToPtr(b, self.registers[v.state], self.types.ptr_ty, "state.get.payload");
                var idx = [_]llvm.c.LLVMValueRef{api.LLVMConstInt(self.types.i64, v.field_index, 0)};
                const slot = api.LLVMBuildInBoundsGEP2(b, self.types.bridge_ty, payload, &idx, idx.len, "state.get.slot");
                const bv = api.LLVMBuildLoad2(b, self.types.bridge_ty, slot, "state.get.bv");
                self.registers[v.dst] = try self.unpackBridge(v.field_ty, bv);
                // A string payload read clones — the state keeps its buffer, the
                // reader owns an independent copy.
                if (v.field_ty.kind == .string) self.cloneStringOnRead(v.dst);
                // Field move-out from a native-state payload: dst owns the value now;
                // zero the slot so a later field set's drop-before-overwrite (or the
                // state's teardown) cannot free it again.
                if (v.moved and self.drop_enabled and (v.field_ty.kind == .array or v.field_ty.kind == .enum_instance)) {
                    drop.onAlloc(self, v.dst);
                    _ = api.LLVMBuildStore(b, api.LLVMConstNull(self.types.bridge_ty), slot);
                }
            },
            .native_state_field_set => |v| try native_state.lowerNativeStateFieldSet(self, v),
            .alloc_array => |v| try aggregate.lowerAllocArray(self, v),
            .array_len => |v| aggregate.lowerArrayLen(self, v),
            .array_get => |v| {
                try aggregate.lowerArrayGet(self, v);
                // A string element read clones — the array element keeps its buffer
                // (freed by kira_array_release), the reader owns an independent copy.
                if (v.ty.kind == .string) self.cloneStringOnRead(v.dst);
            },
            .array_set => |v| try aggregate.lowerArraySet(self, v),
            .array_append => |v| try aggregate.lowerArrayAppend(self, v),
            // Drop elaboration / ownership scopes are no-ops for the C-API core
            // until aggregate ownership (release/clone) lands here.
            .scope_enter, .scope_exit => {},
            // No `else`: the switch is exhaustive over ir.Instruction. The C-API backend
            // now lowers every IR opcode, so a newly-added instruction must be handled
            // here explicitly rather than silently falling through to an error.
        }
    }

    pub fn storageType(self: *FunctionCodegen, value_type: ir.ValueType) !llvm.c.LLVMTypeRef {
        return value_repr.storageType(self, value_type);
    }

    // Read a value through a pointer (register i64), converting the in-memory
    // storage representation back to the register representation.
    fn lowerLoadIndirect(self: *FunctionCodegen, v: ir.LoadIndirect) !llvm.c.LLVMValueRef {
        // An ffi_struct field is stored inline; a "load" of it yields the address
        // of that inline struct, which is exactly the field pointer we were given.
        if (v.ty.kind == .ffi_struct) return self.registers[v.ptr];
        const ptr = self.api.LLVMBuildIntToPtr(self.builder, self.registers[v.ptr], self.types.ptr_ty, "load.ptr");
        return self.loadConverted(ptr, v.ty);
    }

    pub fn loadConverted(self: *FunctionCodegen, ptr: llvm.c.LLVMValueRef, value_type: ir.ValueType) !llvm.c.LLVMValueRef {
        return value_repr.loadConverted(self, ptr, value_type);
    }

    // Pack a register value into a %kira.bridge.value with the default boxing
    // (array elements own an independent heap copy of an ffi_struct).
    pub fn packBridge(self: *FunctionCodegen, value_type: ir.ValueType, value: llvm.c.LLVMValueRef) !llvm.c.LLVMValueRef {
        return value_repr.packBridgeBoxed(self, value_type, value, true);
    }

    pub fn packBridgeBoxed(self: *FunctionCodegen, value_type: ir.ValueType, value: llvm.c.LLVMValueRef, box_struct: bool) !llvm.c.LLVMValueRef {
        return value_repr.packBridgeBoxed(self, value_type, value, box_struct);
    }

    // Unpack a %kira.bridge.value back into a register value of the requested type.
    pub fn unpackBridge(self: *FunctionCodegen, value_type: ir.ValueType, bv: llvm.c.LLVMValueRef) !llvm.c.LLVMValueRef {
        return unpackBridgeValue(self.api, self.builder, self.types, value_type, bv);
    }

    pub fn buildStringConstant(self: *FunctionCodegen, value: []const u8) !llvm.c.LLVMValueRef {
        return value_repr.buildStringConstant(self, value);
    }
};
