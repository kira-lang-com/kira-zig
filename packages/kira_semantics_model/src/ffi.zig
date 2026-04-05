const source_pkg = @import("kira_source");
const runtime_abi = @import("kira_runtime_abi");
const ResolvedType = @import("types.zig").ResolvedType;

pub const Ownership = enum {
    borrowed,
    owned,
    @"opaque",
};

pub const ForeignFunction = struct {
    library_name: []const u8,
    symbol_name: []const u8,
    calling_convention: runtime_abi.CallingConvention = .c,
    span: source_pkg.Span,
};

pub const StructInfo = struct {
    layout: []const u8 = "c",
    span: source_pkg.Span,
};

pub const PointerInfo = struct {
    target_name: []const u8,
    ownership: Ownership = .borrowed,
    span: source_pkg.Span,
};

pub const AliasInfo = struct {
    target: ResolvedType,
    span: source_pkg.Span,
};

pub const ArrayInfo = struct {
    element: ResolvedType,
    count: usize,
    span: source_pkg.Span,
};

pub const CallbackInfo = struct {
    calling_convention: runtime_abi.CallingConvention = .c,
    params: []const ResolvedType,
    result: ResolvedType,
    span: source_pkg.Span,
};

pub const NamedTypeInfo = union(enum) {
    ffi_struct: StructInfo,
    pointer: PointerInfo,
    alias: AliasInfo,
    array: ArrayInfo,
    callback: CallbackInfo,
};
