//! Re-export hub for the type/construct lowering surface that historically lived in
//! this file. The implementations are split by concern:
//!   - lower_program_imports.zig — import lowering + per-file alias registration and
//!     annotation/capability generated-function composition
//!   - lower_program_construct_decl.zig — `construct C { ... }` declaration lowering
//!   - lower_program_construct_validation.zig — construct inheritance/property/content
//!     validation across the construct graph
//!   - lower_program_type_headers.zig — struct/class type-header resolution
//!   - lower_program_type_members.zig — local type member application and method lowering
//! Import sites keep using this hub (or lower_program.zig, which re-exports it).
const imports_impl = @import("lower_program_imports.zig");
const construct_decl_impl = @import("lower_program_construct_decl.zig");
const construct_validation_impl = @import("lower_program_construct_validation.zig");
const type_headers_impl = @import("lower_program_type_headers.zig");
const type_members_impl = @import("lower_program_type_members.zig");

pub const lowerImports = imports_impl.lowerImports;
pub const composeAnnotationGeneratedFunctions = imports_impl.composeAnnotationGeneratedFunctions;
pub const appendGeneratedFunctionUnique = imports_impl.appendGeneratedFunctionUnique;
pub const registerImportAliases = imports_impl.registerImportAliases;

pub const lowerConstructDecl = construct_decl_impl.lowerConstructDecl;

pub const validateConstructInheritance = construct_validation_impl.validateConstructInheritance;
pub const collectConstructPropertySchema = construct_validation_impl.collectConstructPropertySchema;
pub const validateFormProperties = construct_validation_impl.validateFormProperties;
pub const collectConstructContentChannels = construct_validation_impl.collectConstructContentChannels;
pub const validateFormContentChannels = construct_validation_impl.validateFormContentChannels;

pub const registerImportedFunctionHeaders = type_headers_impl.registerImportedFunctionHeaders;
pub const resolveTypeHeader = type_headers_impl.resolveTypeHeader;
pub const resolveLocalTypeHeader = type_headers_impl.resolveLocalTypeHeader;
pub const resolveImportedTypeHeader = type_headers_impl.resolveImportedTypeHeader;
pub const typeSourceSpan = type_headers_impl.typeSourceSpan;
pub const findTypeSource = type_headers_impl.findTypeSource;
pub const appendResolvedParents = type_headers_impl.appendResolvedParents;
pub const appendImportedParents = type_headers_impl.appendImportedParents;
pub const appendDeclaredImportedMethods = type_headers_impl.appendDeclaredImportedMethods;
pub const appendGeneratedAnnotationMethods = type_headers_impl.appendGeneratedAnnotationMethods;

pub const applyLocalTypeMembers = type_members_impl.applyLocalTypeMembers;
pub const emitInvalidFieldOverride = type_members_impl.emitInvalidFieldOverride;
pub const findSingleInheritedField = type_members_impl.findSingleInheritedField;
pub const fieldNameExists = type_members_impl.fieldNameExists;
pub const methodNameExists = type_members_impl.methodNameExists;
pub const countMethodsByName = type_members_impl.countMethodsByName;
pub const countExactMethodMatches = type_members_impl.countExactMethodMatches;
pub const hasNonOverridableExactMethod = type_members_impl.hasNonOverridableExactMethod;
pub const sameMethodSignature = type_members_impl.sameMethodSignature;
pub const makeDeclaredMethodMember = type_members_impl.makeDeclaredMethodMember;
pub const registerTypeMethodHeaders = type_members_impl.registerTypeMethodHeaders;
pub const lowerTypeMethods = type_members_impl.lowerTypeMethods;
pub const lowerMethodFunction = type_members_impl.lowerMethodFunction;
