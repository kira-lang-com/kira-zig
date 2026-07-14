//! Enforces the opt-in `@Derive(Copy)` copyability assertion (the Rust `derive(Copy)`
//! lang-item analog). Kira's `Copy` classification is automatic and structural — adding a
//! heap field silently flips a type from copy to move at every call site. `@Derive(Copy)`
//! makes that contract explicit: this whole-program pass verifies that every type carrying
//! the marker is structurally copyable, and emits KIR005 naming the first offending
//! field/payload otherwise. It never changes the classification of unannotated types.
//!
//! The marker is transported here from the `@Derive(Copy)` annotation site: the macro
//! expander records it on the AST decl (past annotation stripping), semantics copies it onto
//! the HIR `TypeDecl`/`EnumDecl`, and this pass reads `source_program.{types,enums}`.
const std = @import("std");
const diagnostics = @import("kira_diagnostics");
const model = @import("kira_semantics_model");
const mid = @import("mid_ir.zig");
const copyable = @import("mid_ir_copyable.zig");

/// Verify every `@Derive(Copy)` type/enum is structurally copyable. Returns true when an
/// assertion failed (a KIR005 diagnostic was emitted), so the caller can fail the program.
pub fn checkDeriveCopy(
    program: mid.Program,
    type_class: *copyable.TypeClass,
    out_diagnostics: *std.array_list.Managed(diagnostics.Diagnostic),
    allocator: std.mem.Allocator,
) !bool {
    var classifier = copyable.Classifier{ .program = program, .type_class = type_class };
    var failed = false;

    for (program.source_program.types) |type_decl| {
        if (!type_decl.derive_copy) continue;
        for (type_decl.fields) |field| {
            if (copyable.isCopyableType(&classifier, field.ty)) continue;
            try emitNotCopyable(
                out_diagnostics,
                allocator,
                type_decl.name,
                "struct",
                "field",
                field.name,
                field.ty,
                type_decl.span,
            );
            failed = true;
            break; // one diagnostic per type: the first non-copyable member is the root cause.
        }
    }

    for (program.source_program.enums) |enum_decl| {
        if (!enum_decl.derive_copy) continue;
        for (enum_decl.variants) |variant| {
            const payload = variant.payload_ty orelse continue;
            if (copyable.isCopyableType(&classifier, payload)) continue;
            try emitNotCopyable(
                out_diagnostics,
                allocator,
                enum_decl.name,
                "enum",
                "variant",
                variant.name,
                payload,
                enum_decl.span,
            );
            failed = true;
            break;
        }
    }

    return failed;
}

fn emitNotCopyable(
    out_diagnostics: *std.array_list.Managed(diagnostics.Diagnostic),
    allocator: std.mem.Allocator,
    type_name: []const u8,
    type_kind: []const u8,
    member_kind: []const u8,
    member_name: []const u8,
    member_ty: model.ResolvedType,
    span: @import("kira_source").Span,
) !void {
    const message = try std.fmt.allocPrint(
        allocator,
        "The {s} `{s}` derives `Copy`, but its {s} `{s}` has type `{s}`, which is not copyable (it owns heap storage or an opaque payload), so `{s}` moves rather than copies.",
        .{ type_kind, type_name, member_kind, member_name, typeLabel(member_ty), type_name },
    );
    try diagnostics.appendOwned(allocator, out_diagnostics, .{
        .severity = .@"error",
        .code = "KIR005",
        .domain = "lowering",
        .phase = "lowering",
        .title = "type is not copyable",
        .message = message,
        .labels = &.{diagnostics.primaryLabel(span, "`@Derive(Copy)` requires every member to be copyable")},
        .help = "Remove `@Derive(Copy)` and let this type move, borrow the value instead of passing it by value, or give it a `Clone`-style explicit duplication.",
    });
}

/// A human-readable name for a resolved type, for the KIR005 message. Local to the mid-IR
/// layer to avoid an upward import of the semantics lowering package.
fn typeLabel(ty: model.ResolvedType) []const u8 {
    if (ty.kind == .construct_any) return ty.name orelse "any Unknown";
    if (ty.kind == .array) return ty.name orelse "[]";
    if (ty.name) |name| return name;
    return switch (ty.kind) {
        .void => "Void",
        .integer => "Int",
        .float => "Float",
        .boolean => "Bool",
        .string => "String",
        .c_string => "CString",
        .raw_ptr => "RawPtr",
        .construct_any => "any Unknown",
        .native_state => "NativeState",
        .native_state_view => "NativeStateView",
        .callback => "Callback",
        .ffi_struct, .named, .enum_instance => "Unknown",
        .array => "[]",
        .unknown => "Unknown",
    };
}

test {
    std.testing.refAllDecls(@This());
}
