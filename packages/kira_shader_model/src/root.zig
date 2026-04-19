pub const types = @import("types.zig");
pub const module = @import("module.zig");
pub const reflection = @import("reflection.zig");

pub const Stage = types.Stage;
pub const InterfaceDirection = types.InterfaceDirection;
pub const ScalarType = types.ScalarType;
pub const VectorType = types.VectorType;
pub const MatrixType = types.MatrixType;
pub const TextureDimension = types.TextureDimension;
pub const SamplerKind = types.SamplerKind;
pub const AccessMode = types.AccessMode;
pub const Interpolation = types.Interpolation;
pub const Builtin = types.Builtin;
pub const Type = types.Type;
pub const builtinAllowed = types.builtinAllowed;

pub const ShaderKind = module.ShaderKind;
pub const GroupClass = module.GroupClass;
pub const ResourceKind = module.ResourceKind;
pub const OptionDecl = module.OptionDecl;
pub const InterfaceField = module.InterfaceField;
pub const Interface = module.Interface;
pub const Resource = module.Resource;
pub const ResourceGroup = module.ResourceGroup;
pub const EntryPoint = module.EntryPoint;
pub const ShaderDecl = module.ShaderDecl;
pub const classifyGroupName = module.classifyGroupName;

pub const BackendTarget = reflection.BackendTarget;
pub const BackendBinding = reflection.BackendBinding;
pub const ReflectedOption = reflection.ReflectedOption;
pub const ReflectedField = reflection.ReflectedField;
pub const ReflectedLayoutField = reflection.ReflectedLayoutField;
pub const ReflectedLayout = reflection.ReflectedLayout;
pub const ReflectedType = reflection.ReflectedType;
pub const ReflectedStage = reflection.ReflectedStage;
pub const ReflectedResource = reflection.ReflectedResource;
pub const Reflection = reflection.Reflection;

test {
    _ = @import("types.zig");
    _ = @import("module.zig");
    _ = @import("reflection.zig");
}
