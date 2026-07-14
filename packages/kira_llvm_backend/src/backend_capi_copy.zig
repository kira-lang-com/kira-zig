// Struct copy/move lowering for the LLVM C-API backend.
const ir = @import("kira_ir");
const llvm = @import("llvm_c.zig");
const utils = @import("backend_utils.zig");
const drop = @import("backend_capi_drop.zig");
const FunctionCodegen = @import("backend_capi_codegen.zig").FunctionCodegen;

pub fn lower(fc: *FunctionCodegen, v: ir.CopyIndirect) !void {
    const api = fc.api;
    const b = fc.builder;
    const struct_ty = fc.struct_types.get(v.type_name) orelse return error.UnsupportedExecutableFeature;
    const src = api.LLVMBuildIntToPtr(b, fc.registers[v.src_ptr], fc.types.ptr_ty, "copy.src");
    const dst = api.LLVMBuildIntToPtr(b, fc.registers[v.dst_ptr], fc.types.ptr_ty, "copy.dst");
    const move_local = if (v.src_ptr < fc.reg_move_local.len) fc.reg_move_local[v.src_ptr] else null;
    const move_owned = move_local != null or
        (v.src_ptr < fc.reg_fresh_struct.len and fc.reg_fresh_struct[v.src_ptr]);

    // Release the destination's prior contents before its shallow overwrite.
    if (fc.drop_enabled) drop.releasePriorCopyDest(fc, v.dst_ptr, v.type_name);
    const value = api.LLVMBuildLoad2(b, struct_ty, src, "copy.val");
    _ = api.LLVMBuildStore(b, value, dst);

    // Borrowed pure-Kira values preserve deep value semantics. Fresh rvalues and
    // explicit moved locals transfer their contents, which is required for types
    // containing move-only construct_any payloads.
    const clone_default = blk: {
        const td = utils.findTypeDecl(fc.request.program.programPtr(), v.type_name) orelse break :blk false;
        break :blk td.ffi == null;
    };
    if (!move_owned and (fc.drop_enabled or clone_default)) {
        if (fc.dtors.map.get(v.type_name)) |h| {
            var args = [_]llvm.c.LLVMValueRef{dst};
            _ = api.LLVMBuildCall2(b, h.clone_contents.ty, h.clone_contents.fn_value, &args, args.len, "");
        }
    }
    if (fc.drop_enabled) drop.onCopyDest(fc, v.dst_ptr, dst, v.type_name);

    if (move_local) |local| {
        drop.onMoveLocalHeapShell(fc, local, src);
        drop.onMoveLocal(fc, local);
    } else if (move_owned) {
        drop.onMoveRegisterHeapShell(fc, v.src_ptr, src);
    }
}
