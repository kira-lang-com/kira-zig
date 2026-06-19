const std = @import("std");
const names = @import("ffi_autobind_names.zig");
const sdk = @import("ffi_autobind_sdk.zig");
const type_text = @import("ffi_autobind_type_text.zig");

const sanitizeIdentifier = names.sanitizeIdentifier;
const cleanCType = type_text.cleanCType;
const isUnsupportedAnonymousAggregate = type_text.isUnsupportedAnonymousAggregate;
const trimPointerTarget = type_text.trimPointerTarget;

const ArrayTypeInfo = sdk.ArrayTypeInfo;
const AstIndex = sdk.AstIndex;
const CField = sdk.CField;
const CRecord = sdk.CRecord;
const CTypedef = sdk.CTypedef;

pub const ParsedType = union(enum) {
    plain,
    struct_name: []const u8,
    callback_name: []const u8,
    alias_name: []const u8,
    enum_name: []const u8,
    array_name: ArrayTypeInfo,
    pointer_to_named: struct {
        pointer_name: []const u8,
        target_name: []const u8,
    },
};

pub fn fieldTypeName(
    allocator: std.mem.Allocator,
    owner_name: []const u8,
    field: CField,
    inline_callbacks: *const std.StringHashMapUnmanaged(CTypedef),
    index: *const AstIndex,
) ![]const u8 {
    const callback_name = try syntheticFieldCallbackName(allocator, owner_name, field.name);
    if (inline_callbacks.contains(callback_name)) return callback_name;
    return kiraTypeName(allocator, field.qual_type, index);
}

pub fn kiraTypeName(allocator: std.mem.Allocator, qual_type: []const u8, maybe_index: ?*const AstIndex) ![]const u8 {
    const text = cleanCType(qual_type);
    if (isUnsupportedAnonymousAggregate(text)) return allocator.dupe(u8, "RawPtr");
    if (primitiveKiraTypeName(text)) |name| return allocator.dupe(u8, name);
    if (std.mem.startsWith(u8, text, "enum ")) return allocator.dupe(u8, "U32");
    if (maybe_index) |index| {
        if (index.enums.contains(text)) return allocator.dupe(u8, "U32");
        if (index.typedefs.get(text)) |typedef_decl| {
            if (typedef_decl.kind == .alias) {
                const target = cleanCType(typedef_decl.qual_type);
                if (primitiveKiraTypeName(target)) |name| return allocator.dupe(u8, name);
                if (std.mem.startsWith(u8, target, "enum ")) return allocator.dupe(u8, "U32");
                if (index.enums.contains(target)) return allocator.dupe(u8, "U32");
            }
        }
    }
    if (try parseArrayType(allocator, text)) |array_info| {
        defer allocator.free(array_info.name);
        defer allocator.free(array_info.element_type);
        return allocator.dupe(u8, array_info.name);
    }
    if (std.mem.endsWith(u8, text, "*")) {
        const base = trimPointerTarget(text);
        if (std.mem.eql(u8, base, "void")) return allocator.dupe(u8, "RawPtr");
        return std.fmt.allocPrint(allocator, "{s}_ptr", .{base});
    }
    if (std.mem.startsWith(u8, text, "struct ")) return allocator.dupe(u8, text["struct ".len..]);
    return allocator.dupe(u8, text);
}

pub fn parseCType(allocator: std.mem.Allocator, qual_type: []const u8, index: *const AstIndex) !ParsedType {
    const text = cleanCType(qual_type);
    if (isUnsupportedAnonymousAggregate(text)) return .plain;
    if (isPrimitiveType(text)) return .plain;
    if (try parseArrayType(allocator, text)) |array_info| return .{ .array_name = array_info };
    if (std.mem.endsWith(u8, text, "*")) {
        const base = trimPointerTarget(text);
        if (std.mem.eql(u8, base, "void")) return .plain;
        return .{ .pointer_to_named = .{
            .pointer_name = try std.fmt.allocPrint(allocator, "{s}_ptr", .{base}),
            .target_name = try allocator.dupe(u8, base),
        } };
    }
    if (std.mem.startsWith(u8, text, "struct ")) {
        return .{ .struct_name = try allocator.dupe(u8, text["struct ".len..]) };
    }
    if (index.enums.contains(text)) return .{ .enum_name = try allocator.dupe(u8, text) };
    if (index.typedefs.get(text)) |typedef_decl| {
        return switch (typedef_decl.kind) {
            .callback => .{ .callback_name = try allocator.dupe(u8, text) },
            .array => .{ .alias_name = try allocator.dupe(u8, text) },
            .alias => {
                if (typedefResolvesToPrimitiveAlias(typedef_decl) or typedefResolvesToEnumAlias(typedef_decl, index)) return .plain;
                return .{ .alias_name = try allocator.dupe(u8, text) };
            },
        };
    }
    if (resolveRecord(text, index) != null) return .{ .struct_name = try allocator.dupe(u8, text) };
    return .plain;
}

pub fn resolveRecord(name: []const u8, index: *const AstIndex) ?CRecord {
    if (index.records.get(name)) |record| return record;
    if (index.typedefs.get(name)) |typedef_decl| {
        const target = trimStructPrefix(typedef_decl.qual_type);
        return index.records.get(target);
    }
    return null;
}

pub fn typedefResolvesToSelfRecordOrEnum(name: []const u8, typedef_decl: CTypedef, index: *const AstIndex) bool {
    if (resolveRecord(name, index) != null) {
        const target = trimStructPrefix(typedef_decl.qual_type);
        if (std.mem.eql(u8, target, name)) return true;
    }
    const trimmed = cleanCType(typedef_decl.qual_type);
    if (std.mem.startsWith(u8, trimmed, "enum ")) {
        const target = trimmed["enum ".len..];
        if (std.mem.eql(u8, target, name) and index.enums.contains(name)) return true;
    }
    return false;
}

pub fn syntheticFieldCallbackName(allocator: std.mem.Allocator, owner_name: []const u8, field_name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}_{s}_callback", .{ owner_name, sanitizeIdentifier(field_name) });
}

pub fn parseInlineCallbackFromQualType(
    allocator: std.mem.Allocator,
    callback_name: []const u8,
    qual_type: []const u8,
) !?CTypedef {
    const text = cleanCType(qual_type);
    const marker = std.mem.indexOf(u8, text, "(*)") orelse return null;
    const result_text = std.mem.trimEnd(u8, text[0..marker], " ");
    const params_start = std.mem.indexOfScalarPos(u8, text, marker + 3, '(') orelse return null;
    const params_end = std.mem.lastIndexOfScalar(u8, text, ')') orelse return null;
    if (params_end <= params_start) return null;
    const params_text = std.mem.trim(u8, text[params_start + 1 .. params_end], " ");

    var params = std.array_list.Managed([]const u8).init(allocator);
    if (!(std.mem.eql(u8, params_text, "void") or params_text.len == 0)) {
        var parts = std.mem.splitScalar(u8, params_text, ',');
        while (parts.next()) |part| {
            try params.append(try allocator.dupe(u8, std.mem.trim(u8, part, " ")));
        }
    }

    return .{
        .name = callback_name,
        .qual_type = try allocator.dupe(u8, text),
        .kind = .callback,
        .callback_params = try params.toOwnedSlice(),
        .callback_result = try allocator.dupe(u8, result_text),
    };
}

pub fn typedefResolvesToPrimitiveAlias(typedef_decl: CTypedef) bool {
    if (typedef_decl.kind != .alias) return false;
    return primitiveKiraTypeName(cleanCType(typedef_decl.qual_type)) != null;
}

pub fn typedefResolvesToEnumAlias(typedef_decl: CTypedef, index: *const AstIndex) bool {
    if (typedef_decl.kind != .alias) return false;
    const target = cleanCType(typedef_decl.qual_type);
    if (std.mem.startsWith(u8, target, "enum ")) return true;
    return index.enums.contains(target);
}

fn isPrimitiveType(text: []const u8) bool {
    return primitiveKiraTypeName(text) != null;
}

fn primitiveKiraTypeName(text: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, text, "void")) return "Void";
    if (std.mem.eql(u8, text, "char") or std.mem.eql(u8, text, "signed char") or std.mem.eql(u8, text, "int8_t")) return "I8";
    if (std.mem.eql(u8, text, "unsigned char") or std.mem.eql(u8, text, "uint8_t")) return "U8";
    if (std.mem.eql(u8, text, "short") or std.mem.eql(u8, text, "short int") or std.mem.eql(u8, text, "signed short") or std.mem.eql(u8, text, "int16_t")) return "I16";
    if (std.mem.eql(u8, text, "unsigned short") or std.mem.eql(u8, text, "unsigned short int") or std.mem.eql(u8, text, "uint16_t")) return "U16";
    if (std.mem.eql(u8, text, "int") or std.mem.eql(u8, text, "int32_t")) return "I32";
    if (std.mem.eql(u8, text, "unsigned int") or std.mem.eql(u8, text, "uint32_t")) return "U32";
    if (std.mem.eql(u8, text, "long")) return "I32";
    if (std.mem.eql(u8, text, "unsigned long")) return "U32";
    if (std.mem.eql(u8, text, "long long") or std.mem.eql(u8, text, "int64_t") or std.mem.eql(u8, text, "intptr_t") or std.mem.eql(u8, text, "ptrdiff_t")) return "I64";
    if (std.mem.eql(u8, text, "unsigned long long") or std.mem.eql(u8, text, "uint64_t") or std.mem.eql(u8, text, "uintptr_t") or std.mem.eql(u8, text, "size_t")) return "U64";
    if (std.mem.eql(u8, text, "float")) return "F32";
    if (std.mem.eql(u8, text, "double")) return "F64";
    if (std.mem.eql(u8, text, "_Bool") or std.mem.eql(u8, text, "bool")) return "CBool";
    if (std.mem.eql(u8, text, "const char *") or std.mem.eql(u8, text, "char *")) return "CString";
    if (std.mem.eql(u8, text, "const void *") or std.mem.eql(u8, text, "void *")) return "RawPtr";
    return null;
}

fn parseArrayType(allocator: std.mem.Allocator, text: []const u8) anyerror!?ArrayTypeInfo {
    const open = std.mem.lastIndexOfScalar(u8, text, '[') orelse return null;
    const close = std.mem.lastIndexOfScalar(u8, text, ']') orelse return null;
    if (close <= open) return null;
    const count_text = std.mem.trim(u8, text[open + 1 .. close], " ");
    const count = std.fmt.parseInt(usize, count_text, 10) catch return null;
    const element_text = std.mem.trim(u8, text[0..open], " ");
    const name = try syntheticArrayTypeName(allocator, element_text, count);
    return .{
        .name = name,
        .element_type = try allocator.dupe(u8, element_text),
        .count = count,
    };
}

fn syntheticArrayTypeName(allocator: std.mem.Allocator, element_text: []const u8, count: usize) anyerror![]const u8 {
    if (primitiveKiraTypeName(element_text)) |name| {
        return std.fmt.allocPrint(allocator, "{s}_array_{d}", .{ name, count });
    }
    if (std.mem.endsWith(u8, element_text, "*")) {
        return std.fmt.allocPrint(allocator, "{s}_ptr_array_{d}", .{ trimPointerTarget(element_text), count });
    }
    if (try parseArrayType(allocator, element_text)) |nested| {
        defer allocator.free(nested.name);
        defer allocator.free(nested.element_type);
        return std.fmt.allocPrint(allocator, "{s}_array_{d}", .{ nested.name, count });
    }
    return std.fmt.allocPrint(allocator, "{s}_array_{d}", .{ trimStructPrefix(element_text), count });
}

fn trimStructPrefix(text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " ");
    if (std.mem.startsWith(u8, trimmed, "struct ")) return trimmed["struct ".len..];
    return trimmed;
}

test "nested C arrays lower to valid Kira array type names" {
    const name = try kiraTypeName(std.testing.allocator, "FLOAT[3][4]", null);
    defer std.testing.allocator.free(name);

    try std.testing.expectEqualStrings("FLOAT_array_3_array_4", name);
}
