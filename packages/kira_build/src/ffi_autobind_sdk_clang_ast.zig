const std = @import("std");
const json_helpers = @import("ffi_autobind_json.zig");
const sdk = @import("ffi_autobind_sdk.zig");
const type_text = @import("ffi_autobind_type_text.zig");

const objectString = json_helpers.objectString;
const objectBool = json_helpers.objectBool;
const objectQualType = json_helpers.objectQualType;
const cloneStrings = json_helpers.cloneStrings;
const cleanCType = type_text.cleanCType;
const trimPointerTarget = type_text.trimPointerTarget;

pub fn buildAstIndexInto(allocator: std.mem.Allocator, ast_json: []const u8, headers: []const []const u8, index: *sdk.AstIndex) !void {
    if (std.mem.trim(u8, ast_json, " \t\r\n").len == 0) return;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, ast_json, .{
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.SyntaxError => return buildFilteredAstIndexInto(allocator, ast_json, headers, index),
        else => return err,
    };
    defer parsed.deinit();

    const normalized_headers = try normalizePaths(allocator, headers);
    try walkNode(allocator, parsed.value, normalized_headers, index);
}

fn buildFilteredAstIndexInto(allocator: std.mem.Allocator, ast_json: []const u8, headers: []const []const u8, index: *sdk.AstIndex) !void {
    const normalized_headers = try normalizePaths(allocator, headers);
    var start: ?usize = null;
    var depth: usize = 0;
    var in_string = false;
    var escaped = false;
    var saw_document = false;

    for (ast_json, 0..) |ch, offset| {
        if (start == null) {
            if (std.ascii.isWhitespace(ch)) continue;
            if (ch != '{') return error.SyntaxError;
            start = offset;
            depth = 1;
            continue;
        }

        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (ch == '\\') {
                escaped = true;
            } else if (ch == '"') {
                in_string = false;
            }
            continue;
        }

        if (ch == '"') {
            in_string = true;
        } else if (ch == '{') {
            depth += 1;
        } else if (ch == '}') {
            depth -= 1;
            if (depth == 0) {
                const slice = ast_json[start.? .. offset + 1];
                var parsed = try std.json.parseFromSlice(std.json.Value, allocator, slice, .{
                    .ignore_unknown_fields = true,
                });
                defer parsed.deinit();
                try walkNode(allocator, parsed.value, normalized_headers, index);
                start = null;
                saw_document = true;
            }
        }
    }

    if (start != null or !saw_document) return error.SyntaxError;
}

fn walkNode(allocator: std.mem.Allocator, node: std.json.Value, headers: []const []const u8, index: *sdk.AstIndex) !void {
    if (node != .object) return;
    const object = node.object;
    const kind = objectString(object, "kind") orelse "";

    if (isHeaderNode(object, headers)) {
        if (std.mem.eql(u8, kind, "FunctionDecl")) {
            if (objectString(object, "name")) |name| {
                try index.functions.put(allocator, try allocator.dupe(u8, name), try extractFunctionDecl(allocator, object));
            }
        } else if (std.mem.eql(u8, kind, "EnumDecl")) {
            if (objectString(object, "name")) |name| {
                try index.enums.put(allocator, try allocator.dupe(u8, name), try extractEnumDecl(allocator, object));
            }
        } else if (std.mem.eql(u8, kind, "RecordDecl")) {
            if (objectString(object, "name")) |name| {
                if (objectBool(object, "completeDefinition")) {
                    try index.records.put(allocator, try allocator.dupe(u8, name), try extractRecordDecl(allocator, object));
                }
            }
        } else if (std.mem.eql(u8, kind, "TypedefDecl")) {
            if (objectString(object, "name")) |name| {
                try index.typedefs.put(allocator, try allocator.dupe(u8, name), try extractTypedefDecl(allocator, object));
            }
        }
    }

    if (object.get("inner")) |inner| {
        if (inner == .array) {
            for (inner.array.items) |child| try walkNode(allocator, child, headers, index);
        }
    }
}

fn isHeaderNode(object: std.json.ObjectMap, headers: []const []const u8) bool {
    const loc = object.get("loc") orelse return false;
    if (loc != .object) return false;
    const file = objectString(loc.object, "file") orelse {
        if (objectBool(object, "isImplicit")) return false;
        if (objectString(object, "name")) |name| return !std.mem.startsWith(u8, name, "__");
        return false;
    };
    const normalized_file = normalizePath(std.heap.page_allocator, file) catch file;
    defer if (normalized_file.ptr != file.ptr) std.heap.page_allocator.free(normalized_file);
    for (headers) |header| {
        if (std.mem.eql(u8, normalized_file, header)) return true;
    }
    return false;
}

fn normalizePaths(allocator: std.mem.Allocator, values: []const []const u8) ![]const []const u8 {
    var list = std.array_list.Managed([]const u8).init(allocator);
    for (values) |value| try list.append(try normalizePath(allocator, value));
    return list.toOwnedSlice();
}

fn normalizePath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    return std.fs.path.resolve(allocator, &.{path});
}

fn extractFunctionDecl(allocator: std.mem.Allocator, object: std.json.ObjectMap) !sdk.CFunction {
    var params = std.array_list.Managed(sdk.CParam).init(allocator);
    if (object.get("inner")) |inner| {
        if (inner == .array) {
            for (inner.array.items, 0..) |child, index| {
                if (child != .object) continue;
                if (!std.mem.eql(u8, objectString(child.object, "kind") orelse "", "ParmVarDecl")) continue;
                try params.append(.{
                    .name = try namedOrIndexed(allocator, objectString(child.object, "name"), "arg", index),
                    .qual_type = try allocator.dupe(u8, objectQualType(child.object) orelse return error.InvalidAutobindingDecl),
                });
            }
        }
    }

    return .{
        .name = try allocator.dupe(u8, objectString(object, "name") orelse return error.InvalidAutobindingDecl),
        .return_type = try allocator.dupe(u8, functionResultType(object) orelse return error.InvalidAutobindingDecl),
        .params = try params.toOwnedSlice(),
    };
}

fn extractRecordDecl(allocator: std.mem.Allocator, object: std.json.ObjectMap) !sdk.CRecord {
    var fields = std.array_list.Managed(sdk.CField).init(allocator);
    if (object.get("inner")) |inner| {
        if (inner == .array) {
            for (inner.array.items, 0..) |child, index| {
                if (child != .object) continue;
                if (!std.mem.eql(u8, objectString(child.object, "kind") orelse "", "FieldDecl")) continue;
                try fields.append(.{
                    .name = try namedOrIndexed(allocator, objectString(child.object, "name"), "field", index),
                    .qual_type = try allocator.dupe(u8, objectQualType(child.object) orelse return error.InvalidAutobindingDecl),
                });
            }
        }
    }

    return .{
        .name = try allocator.dupe(u8, objectString(object, "name") orelse return error.InvalidAutobindingDecl),
        .fields = try fields.toOwnedSlice(),
    };
}

fn namedOrIndexed(allocator: std.mem.Allocator, maybe_name: ?[]const u8, prefix: []const u8, index: usize) ![]const u8 {
    if (maybe_name) |name| {
        if (name.len > 0) return allocator.dupe(u8, name);
    }
    return std.fmt.allocPrint(allocator, "{s}{d}", .{ prefix, index });
}

fn extractEnumDecl(allocator: std.mem.Allocator, object: std.json.ObjectMap) !sdk.CEnum {
    var items = std.array_list.Managed(sdk.CEnumItem).init(allocator);
    var next_value: i64 = 0;
    if (object.get("inner")) |inner| {
        if (inner == .array) {
            for (inner.array.items) |child| {
                if (child != .object) continue;
                if (!std.mem.eql(u8, objectString(child.object, "kind") orelse "", "EnumConstantDecl")) continue;
                const value = findIntegerValue(child) orelse next_value;
                try items.append(.{
                    .name = try allocator.dupe(u8, objectString(child.object, "name") orelse return error.InvalidAutobindingDecl),
                    .value = value,
                });
                next_value = value + 1;
            }
        }
    }
    return .{
        .name = try allocator.dupe(u8, objectString(object, "name") orelse return error.InvalidAutobindingDecl),
        .items = try items.toOwnedSlice(),
    };
}

fn extractTypedefDecl(allocator: std.mem.Allocator, object: std.json.ObjectMap) !sdk.CTypedef {
    var result = sdk.CTypedef{
        .name = try allocator.dupe(u8, objectString(object, "name") orelse return error.InvalidAutobindingDecl),
        .qual_type = try allocator.dupe(u8, objectQualType(object) orelse return error.InvalidAutobindingDecl),
        .kind = .alias,
    };

    if (result.qual_type.len > 0 and std.mem.indexOf(u8, result.qual_type, "(*)") != null) {
        result.kind = .callback;
        if (findFunctionProto(object)) |proto| {
            result.callback_result = try allocator.dupe(u8, proto.result_type);
            result.callback_params = try cloneStrings(allocator, proto.params);
        }
    } else if (try parseArrayType(allocator, result.qual_type)) |array_info| {
        result.kind = .array;
        result.array_element_type = array_info.element_type;
        result.array_count = array_info.count;
    }

    return result;
}

const FunctionProto = struct {
    result_type: []const u8,
    params: []const []const u8,
};

fn findFunctionProto(object: std.json.ObjectMap) ?FunctionProto {
    const inner = object.get("inner") orelse return null;
    return findFunctionProtoInValue(inner);
}

fn findFunctionProtoInValue(value: std.json.Value) ?FunctionProto {
    if (value == .object) {
        const kind = objectString(value.object, "kind") orelse "";
        if (std.mem.eql(u8, kind, "FunctionProtoType")) {
            var params = std.array_list.Managed([]const u8).init(std.heap.page_allocator);
            if (value.object.get("inner")) |inner| {
                if (inner == .array and inner.array.items.len > 0) {
                    const result_type = objectQualType(inner.array.items[0].object) orelse return null;
                    for (inner.array.items[1..]) |child| {
                        if (child != .object) continue;
                        const qual_type = objectQualType(child.object) orelse continue;
                        params.append(qual_type) catch return null;
                    }
                    return .{
                        .result_type = result_type,
                        .params = params.toOwnedSlice() catch return null,
                    };
                }
            }
        }
        if (value.object.get("inner")) |inner| return findFunctionProtoInValue(inner);
        return null;
    }
    if (value == .array) {
        for (value.array.items) |child| {
            if (findFunctionProtoInValue(child)) |proto| return proto;
        }
    }
    return null;
}

fn functionResultType(object: std.json.ObjectMap) ?[]const u8 {
    const type_value = object.get("type") orelse return null;
    if (type_value != .object) return null;
    const qual_type = objectString(type_value.object, "qualType") orelse return null;
    const open = std.mem.indexOfScalar(u8, qual_type, '(') orelse return qual_type;
    return std.mem.trimEnd(u8, qual_type[0..open], " ");
}

fn findIntegerValue(value: std.json.Value) ?i64 {
    switch (value) {
        .object => |object| {
            if (object.get("value")) |field| {
                switch (field) {
                    .string => return std.fmt.parseInt(i64, field.string, 0) catch null,
                    .integer => return @intCast(field.integer),
                    else => {},
                }
            }
            if (object.get("inner")) |inner| return findIntegerValue(inner);
            return null;
        },
        .array => |array| {
            for (array.items) |item| {
                if (findIntegerValue(item)) |found| return found;
            }
            return null;
        },
        .integer => |raw| return @intCast(raw),
        else => return null,
    }
}

fn parseArrayType(allocator: std.mem.Allocator, text: []const u8) !?sdk.ArrayTypeInfo {
    const clean = cleanCType(text);
    const open = std.mem.lastIndexOfScalar(u8, clean, '[') orelse return null;
    const close = std.mem.lastIndexOfScalar(u8, clean, ']') orelse return null;
    if (close <= open) return null;
    const count_text = std.mem.trim(u8, clean[open + 1 .. close], " ");
    const count = std.fmt.parseInt(usize, count_text, 10) catch return null;
    const element_text = std.mem.trim(u8, clean[0..open], " ");
    return .{
        .name = try syntheticArrayTypeName(allocator, element_text, count),
        .element_type = try allocator.dupe(u8, element_text),
        .count = count,
    };
}

fn syntheticArrayTypeName(allocator: std.mem.Allocator, element_text: []const u8, count: usize) ![]const u8 {
    const base_name = if (primitiveKiraTypeName(element_text)) |name|
        name
    else if (std.mem.endsWith(u8, element_text, "*"))
        try std.fmt.allocPrint(allocator, "{s}_ptr", .{trimPointerTarget(element_text)})
    else
        trimStructPrefix(element_text);
    return std.fmt.allocPrint(allocator, "{s}_array_{d}", .{ base_name, count });
}

fn primitiveKiraTypeName(text: []const u8) ?[]const u8 {
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
    return null;
}

fn trimStructPrefix(text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " ");
    if (std.mem.startsWith(u8, trimmed, "struct ")) return trimmed["struct ".len..];
    return trimmed;
}
