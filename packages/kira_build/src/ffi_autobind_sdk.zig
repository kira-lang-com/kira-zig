pub const model = @import("ffi_autobind_sdk_model.zig");
pub const clang_ast = @import("ffi_autobind_sdk_clang_ast.zig");

pub const Abi = model.Abi;
pub const Api = model.Api;
pub const ApiAvailability = model.ApiAvailability;
pub const ApiSource = model.ApiSource;
pub const ArrayTypeInfo = model.ArrayTypeInfo;
pub const AstIndex = model.AstIndex;
pub const BindingDiagnostic = model.BindingDiagnostic;
pub const BindingModel = model.BindingModel;
pub const BindingTarget = model.BindingTarget;
pub const CEnum = model.CEnum;
pub const CEnumItem = model.CEnumItem;
pub const CField = model.CField;
pub const CFunction = model.CFunction;
pub const CParam = model.CParam;
pub const CRecord = model.CRecord;
pub const CTypedef = model.CTypedef;
pub const DeclarationKind = model.DeclarationKind;
pub const HandleKind = model.HandleKind;
pub const Lifetime = model.Lifetime;
pub const Nullability = model.Nullability;
pub const Ownership = model.Ownership;
pub const PointerKind = model.PointerKind;
pub const TypeRef = model.TypeRef;

test {
    _ = model;
}
