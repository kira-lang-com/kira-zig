const std = @import("std");
const model = @import("kira_semantics_model");
const runtime_abi = @import("kira_runtime_abi");

pub const ImportedFunction = struct {
    name: []const u8,
    params: []const model.ResolvedType = &.{},
    return_type: model.ResolvedType = .{ .kind = .unknown },
    execution: runtime_abi.FunctionExecution = .inherited,
    is_extern: bool = false,
    foreign: ?model.ForeignFunction = null,
};

pub const ImportedType = struct {
    name: []const u8,
    fields: []const ImportedField = &.{},
    ffi: ?model.NamedTypeInfo = null,
};

pub const ImportedField = struct {
    name: []const u8,
    ty: model.ResolvedType,
};

pub const ImportedGlobals = struct {
    constructs: []const []const u8 = &.{},
    callables: []const []const u8 = &.{},
    functions: []const ImportedFunction = &.{},
    types: []const ImportedType = &.{},

    pub fn hasConstruct(self: ImportedGlobals, name: []const u8) bool {
        return contains(self.constructs, name);
    }

    pub fn hasCallable(self: ImportedGlobals, name: []const u8) bool {
        return contains(self.callables, name);
    }

    pub fn findFunction(self: ImportedGlobals, name: []const u8) ?ImportedFunction {
        for (self.functions) |function_decl| {
            if (std.mem.eql(u8, function_decl.name, name)) return function_decl;
        }
        return null;
    }

    pub fn findType(self: ImportedGlobals, name: []const u8) ?ImportedType {
        for (self.types) |type_decl| {
            if (std.mem.eql(u8, type_decl.name, name)) return type_decl;
        }
        return null;
    }

    fn contains(values: []const []const u8, name: []const u8) bool {
        for (values) |value| {
            if (std.mem.eql(u8, value, name)) return true;
        }
        return false;
    }
};
