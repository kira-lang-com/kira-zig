const std = @import("std");
const native = @import("kira_native_lib_definition");
const build_options = @import("kira_llvm_build_options");

pub const AutobindingSpec = struct {
    mode: Mode = .listed,
    functions: []const []const u8 = &.{},
    structs: []const []const u8 = &.{},
    callbacks: []const []const u8 = &.{},

    const Mode = enum {
        listed,
        all_public,
    };
};

const CParam = struct {
    name: []const u8,
    qual_type: []const u8,
};

const CFunction = struct {
    name: []const u8,
    return_type: []const u8,
    params: []const CParam,
};

const CField = struct {
    name: []const u8,
    qual_type: []const u8,
};

const CEnumItem = struct {
    name: []const u8,
    value: i64,
};

const CEnum = struct {
    name: []const u8,
    items: []const CEnumItem,
};

const CRecord = struct {
    name: []const u8,
    fields: []const CField,
};

const CTypedef = struct {
    name: []const u8,
    qual_type: []const u8,
    kind: Kind,
    callback_params: []const []const u8 = &.{},
    callback_result: ?[]const u8 = null,
    array_element_type: ?[]const u8 = null,
    array_count: usize = 0,

    const Kind = enum {
        alias,
        array,
        callback,
    };
};

const CMacro = struct {
    name: []const u8,
    value: []const u8,
};

const ArrayTypeInfo = struct {
    name: []const u8,
    element_type: []const u8,
    count: usize,
};

const AstIndex = struct {
    functions: std.StringHashMapUnmanaged(CFunction) = .{},
    enums: std.StringHashMapUnmanaged(CEnum) = .{},
    records: std.StringHashMapUnmanaged(CRecord) = .{},
    typedefs: std.StringHashMapUnmanaged(CTypedef) = .{},
    macros: std.StringHashMapUnmanaged(CMacro) = .{},
};

pub fn ensureGeneratedBindings(allocator: std.mem.Allocator, library: native.ResolvedNativeLibrary) !void {
    const autobinding = library.autobinding orelse return;
    const spec_path = autobinding.spec_path orelse return error.MissingAutobindingSpec;
    const spec = try parseAutobindingSpecFile(allocator, spec_path);
    const ast_json = try runClangAstDump(allocator, library, autobinding.headers);
    defer allocator.free(ast_json);

    var index = try buildAstIndex(allocator, ast_json, autobinding.headers);
    try collectMacroConstants(allocator, autobinding.headers, &index);
    const rendered = try renderBindings(allocator, library, spec, index);
    defer allocator.free(rendered);

    const maybe_dir = std.fs.path.dirname(autobinding.output_path) orelse ".";
    try makePath(maybe_dir);
    if (std.fs.path.isAbsolute(autobinding.output_path)) {
        const file = try std.fs.createFileAbsolute(autobinding.output_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(rendered);
    } else {
        try std.fs.cwd().writeFile(.{
            .sub_path = autobinding.output_path,
            .data = rendered,
        });
    }
}

pub fn parseAutobindingSpecFile(allocator: std.mem.Allocator, path: []const u8) !AutobindingSpec {
    const text = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
    return parseAutobindingSpec(allocator, text);
}

pub fn parseAutobindingSpec(allocator: std.mem.Allocator, text: []const u8) !AutobindingSpec {
    var mode: AutobindingSpec.Mode = .listed;
    var functions = std.array_list.Managed([]const u8).init(allocator);
    var structs = std.array_list.Managed([]const u8).init(allocator);
    var callbacks = std.array_list.Managed([]const u8).init(allocator);
    var section: []const u8 = "";

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = trimComment(raw_line);
        if (line.len == 0) continue;
        if (line[0] == '[' and line[line.len - 1] == ']') {
            section = line[1 .. line.len - 1];
            continue;
        }

        if (!std.mem.eql(u8, section, "bindings")) continue;
        if (assignString(line, "mode")) |value| {
            if (std.mem.eql(u8, value, "all_public")) {
                mode = .all_public;
            } else {
                mode = .listed;
            }
        } else if (std.mem.startsWith(u8, line, "functions")) {
            for (try parseStringArray(allocator, line)) |value| try functions.append(value);
        } else if (std.mem.startsWith(u8, line, "structs")) {
            for (try parseStringArray(allocator, line)) |value| try structs.append(value);
        } else if (std.mem.startsWith(u8, line, "callbacks")) {
            for (try parseStringArray(allocator, line)) |value| try callbacks.append(value);
        }
    }

    return .{
        .mode = mode,
        .functions = try functions.toOwnedSlice(),
        .structs = try structs.toOwnedSlice(),
        .callbacks = try callbacks.toOwnedSlice(),
    };
}

fn runClangAstDump(allocator: std.mem.Allocator, library: native.ResolvedNativeLibrary, headers: []const []const u8) ![]const u8 {
    var argv = std.array_list.Managed([]const u8).init(allocator);
    try argv.appendSlice(&.{ "clang", "-Xclang", "-ast-dump=json", "-fsyntax-only" });

    if (library.headers.entrypoint) |entrypoint| {
        try argv.append(entrypoint);
    } else if (headers.len > 0) {
        try argv.append(headers[0]);
    } else {
        return error.MissingAutobindingHeader;
    }
    for (library.headers.include_dirs) |include_dir| {
        try argv.append(try std.fmt.allocPrint(allocator, "-I{s}", .{include_dir}));
    }
    for (library.headers.defines) |define| {
        try argv.append(try std.fmt.allocPrint(allocator, "-D{s}", .{define}));
    }

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv.items,
        .max_output_bytes = 16 * 1024 * 1024,
    });
    defer allocator.free(result.stderr);

    if (result.term != .Exited or result.term.Exited != 0) {
        allocator.free(result.stdout);
        return error.ClangAutobindingFailed;
    }

    return result.stdout;
}

fn buildAstIndex(allocator: std.mem.Allocator, ast_json: []const u8, headers: []const []const u8) !AstIndex {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, ast_json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    var index = AstIndex{};
    try walkNode(allocator, parsed.value, headers, &index);
    return index;
}

fn walkNode(
    allocator: std.mem.Allocator,
    node: std.json.Value,
    headers: []const []const u8,
    index: *AstIndex,
) !void {
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
        if (objectString(object, "name")) |name| {
            return !std.mem.startsWith(u8, name, "__");
        }
        return false;
    };
    for (headers) |header| {
        if (std.mem.eql(u8, file, header)) return true;
    }
    return false;
}

fn extractFunctionDecl(allocator: std.mem.Allocator, object: std.json.ObjectMap) !CFunction {
    var params = std.array_list.Managed(CParam).init(allocator);
    if (object.get("inner")) |inner| {
        if (inner == .array) {
            for (inner.array.items) |child| {
                if (child != .object) continue;
                if (!std.mem.eql(u8, objectString(child.object, "kind") orelse "", "ParmVarDecl")) continue;
                try params.append(.{
                    .name = try allocator.dupe(u8, objectString(child.object, "name") orelse "arg"),
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

fn extractRecordDecl(allocator: std.mem.Allocator, object: std.json.ObjectMap) !CRecord {
    var fields = std.array_list.Managed(CField).init(allocator);
    if (object.get("inner")) |inner| {
        if (inner == .array) {
            for (inner.array.items) |child| {
                if (child != .object) continue;
                if (!std.mem.eql(u8, objectString(child.object, "kind") orelse "", "FieldDecl")) continue;
                try fields.append(.{
                    .name = try allocator.dupe(u8, objectString(child.object, "name") orelse return error.InvalidAutobindingDecl),
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

fn extractEnumDecl(allocator: std.mem.Allocator, object: std.json.ObjectMap) !CEnum {
    var items = std.array_list.Managed(CEnumItem).init(allocator);
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

fn extractTypedefDecl(allocator: std.mem.Allocator, object: std.json.ObjectMap) !CTypedef {
    var result = CTypedef{
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

fn renderBindings(allocator: std.mem.Allocator, library: native.ResolvedNativeLibrary, spec: AutobindingSpec, index: AstIndex) ![]u8 {
    var required_structs = std.StringHashMapUnmanaged(void){};
    var required_callbacks = std.StringHashMapUnmanaged(void){};
    var required_pointers = std.StringHashMapUnmanaged([]const u8){};
    var required_aliases = std.StringHashMapUnmanaged(void){};
    var required_enums = std.StringHashMapUnmanaged(void){};
    var required_arrays = std.StringHashMapUnmanaged(ArrayTypeInfo){};
    var required_inline_callbacks = std.StringHashMapUnmanaged(CTypedef){};

    var function_names = std.array_list.Managed([]const u8).init(allocator);
    if (spec.mode == .all_public) {
        var function_iter = index.functions.iterator();
        while (function_iter.next()) |entry| try function_names.append(entry.key_ptr.*);

        var struct_iter_all = index.records.iterator();
        while (struct_iter_all.next()) |entry| try required_structs.put(allocator, entry.key_ptr.*, {});

        var typedef_iter_all = index.typedefs.iterator();
        while (typedef_iter_all.next()) |entry| {
            switch (entry.value_ptr.kind) {
                .callback => try required_callbacks.put(allocator, entry.key_ptr.*, {}),
                .array, .alias => try required_aliases.put(allocator, entry.key_ptr.*, {}),
            }
        }

        var enum_iter_all = index.enums.iterator();
        while (enum_iter_all.next()) |entry| try required_enums.put(allocator, entry.key_ptr.*, {});
    } else {
        for (spec.structs) |name| try required_structs.put(allocator, name, {});
        for (spec.callbacks) |name| try required_callbacks.put(allocator, name, {});

        for (spec.functions) |name| {
            const function_decl = index.functions.get(name) orelse return error.MissingAutobindFunction;
            try function_names.append(function_decl.name);
            try collectTypeDependencies(allocator, function_decl.return_type, &required_structs, &required_callbacks, &required_pointers, &required_aliases, &required_enums, &required_arrays, &index);
            for (function_decl.params) |param| {
                try collectTypeDependencies(allocator, param.qual_type, &required_structs, &required_callbacks, &required_pointers, &required_aliases, &required_enums, &required_arrays, &index);
            }
        }
    }

    for (function_names.items) |name| {
        const function_decl = index.functions.get(name) orelse continue;
        try collectTypeDependencies(allocator, function_decl.return_type, &required_structs, &required_callbacks, &required_pointers, &required_aliases, &required_enums, &required_arrays, &index);
        for (function_decl.params) |param| {
            try collectTypeDependencies(allocator, param.qual_type, &required_structs, &required_callbacks, &required_pointers, &required_aliases, &required_enums, &required_arrays, &index);
        }
    }

    try collectSelectedTypeDependencies(allocator, required_structs, required_aliases, &required_structs, &required_callbacks, &required_pointers, &required_aliases, &required_enums, &required_arrays, &index);
    var callback_dep_iter = required_callbacks.iterator();
    while (callback_dep_iter.next()) |entry| {
        const typedef_decl = index.typedefs.get(entry.key_ptr.*) orelse continue;
        for (typedef_decl.callback_params) |param| {
            try collectTypeDependencies(allocator, param, &required_structs, &required_callbacks, &required_pointers, &required_aliases, &required_enums, &required_arrays, &index);
        }
        if (typedef_decl.callback_result) |result_type| {
            try collectTypeDependencies(allocator, result_type, &required_structs, &required_callbacks, &required_pointers, &required_aliases, &required_enums, &required_arrays, &index);
        }
    }
    var array_dep_iter = required_arrays.iterator();
    while (array_dep_iter.next()) |entry| {
        try collectTypeDependencies(allocator, entry.value_ptr.element_type, &required_structs, &required_callbacks, &required_pointers, &required_aliases, &required_enums, &required_arrays, &index);
    }
    var inline_callback_struct_iter = required_structs.iterator();
    while (inline_callback_struct_iter.next()) |entry| {
        const name = entry.key_ptr.*;
        const record = resolveRecord(name, &index) orelse continue;
        for (record.fields) |field| {
            if (try parseInlineCallbackFromQualType(allocator, try syntheticFieldCallbackName(allocator, name, field.name), field.qual_type)) |callback_decl| {
                try required_inline_callbacks.put(allocator, callback_decl.name, callback_decl);
                for (callback_decl.callback_params) |param| {
                    try collectTypeDependencies(allocator, param, &required_structs, &required_callbacks, &required_pointers, &required_aliases, &required_enums, &required_arrays, &index);
                }
                if (callback_decl.callback_result) |result_type| {
                    try collectTypeDependencies(allocator, result_type, &required_structs, &required_callbacks, &required_pointers, &required_aliases, &required_enums, &required_arrays, &index);
                }
            }
        }
    }

    const sorted_aliases = try sortedMapKeys(allocator, required_aliases);
    const sorted_enums = try sortedMapKeys(allocator, required_enums);
    const sorted_callbacks = try sortedMapKeys(allocator, required_callbacks);
    const sorted_inline_callbacks = try sortedMapKeys(allocator, required_inline_callbacks);
    const sorted_arrays = try sortedMapKeys(allocator, required_arrays);
    const sorted_structs = try sortedMapKeys(allocator, required_structs);
    const sorted_pointers = try sortedMapKeys(allocator, required_pointers);
    sortStrings(function_names.items);

    var output = std.array_list.Managed(u8).init(allocator);
    errdefer output.deinit();
    var writer = output.writer();

    try writer.print("// generated by kira FFI autobinding for {s}\n\n", .{library.name});

    for (sorted_aliases) |name| {
        const typedef_decl = index.typedefs.get(name) orelse return error.MissingAutobindType;
        if (typedefResolvesToSelfRecordOrEnum(name, typedef_decl, &index)) continue;
        try writeAliasType(allocator, &writer, typedef_decl);
    }

    for (sorted_enums) |name| {
        const enum_decl = index.enums.get(name) orelse return error.MissingAutobindType;
        try writeEnumType(allocator, &writer, enum_decl);
    }

    for (sorted_callbacks) |name| {
        const typedef_decl = index.typedefs.get(name) orelse return error.MissingAutobindCallback;
        try writeCallbackType(allocator, &writer, typedef_decl);
    }

    for (sorted_inline_callbacks) |name| {
        const callback_decl = required_inline_callbacks.get(name) orelse continue;
        try writeCallbackType(allocator, &writer, callback_decl);
    }

    for (sorted_arrays) |name| {
        const array_info = required_arrays.get(name) orelse continue;
        try writeSyntheticArrayType(allocator, &writer, array_info);
    }

    for (sorted_structs) |name| {
        if (resolveRecord(name, &index) == null) continue;
        try writeStructType(allocator, &writer, name, &required_inline_callbacks, &index);
    }

    for (sorted_pointers) |name| {
        const target_name = required_pointers.get(name) orelse continue;
        try writer.print("@FFI.Pointer {{ target: {s}; ownership: borrowed; }}\n", .{target_name});
        try writer.print("type {s} {{}}\n\n", .{name});
    }

    if (spec.mode == .all_public and index.macros.count() > 0) {
        const macro_names = try sortedMapKeys(allocator, index.macros);
        try writeMacroConstantsType(&writer, library.name, macro_names, &index);
    }

    for (function_names.items) |name| {
        const function_decl = index.functions.get(name) orelse return error.MissingAutobindFunction;
        try writeFunctionDecl(allocator, &writer, library.name, function_decl);
    }

    return output.toOwnedSlice();
}

fn writeAliasType(allocator: std.mem.Allocator, writer: anytype, typedef_decl: CTypedef) !void {
    switch (typedef_decl.kind) {
        .callback => return writeCallbackType(allocator, writer, typedef_decl),
        .array => {
            try writer.print("@FFI.Array {{ element: {s}; count: {d}; }}\n", .{
                try kiraTypeName(allocator, typedef_decl.array_element_type orelse return error.InvalidAutobindingDecl),
                typedef_decl.array_count,
            });
            try writer.print("type {s} {{}}\n\n", .{typedef_decl.name});
        },
        .alias => {
            try writer.print("@FFI.Alias {{ target: {s}; }}\n", .{try kiraTypeName(allocator, typedef_decl.qual_type)});
            try writer.print("type {s} {{}}\n\n", .{typedef_decl.name});
        },
    }
}

fn writeSyntheticArrayType(allocator: std.mem.Allocator, writer: anytype, array_info: ArrayTypeInfo) !void {
    try writer.print("@FFI.Array {{ element: {s}; count: {d}; }}\n", .{
        try kiraTypeName(allocator, array_info.element_type),
        array_info.count,
    });
    try writer.print("type {s} {{}}\n\n", .{array_info.name});
}

fn writeEnumType(allocator: std.mem.Allocator, writer: anytype, enum_decl: CEnum) !void {
    _ = allocator;
    try writer.writeAll("@FFI.Alias { target: U32; }\n");
    try writer.print("type {s} {{\n", .{enum_decl.name});
    for (enum_decl.items) |item| {
        try writer.print("    static let {s}: U32 = {d}\n", .{ item.name, item.value });
    }
    try writer.writeAll("}\n\n");
}

fn writeCallbackType(allocator: std.mem.Allocator, writer: anytype, typedef_decl: CTypedef) !void {
    try writer.print("@FFI.Callback {{ abi: c; params: [", .{});
    for (typedef_decl.callback_params, 0..) |param, index| {
        if (index != 0) try writer.writeAll(", ");
        try writer.writeAll(try kiraTypeName(allocator, param));
    }
    try writer.writeAll("]; result: ");
    try writer.writeAll(try kiraTypeName(allocator, typedef_decl.callback_result orelse "void"));
    try writer.writeAll("; }\n");
    try writer.print("type {s} {{}}\n\n", .{typedef_decl.name});
}

fn writeStructType(
    allocator: std.mem.Allocator,
    writer: anytype,
    name: []const u8,
    inline_callbacks: *const std.StringHashMapUnmanaged(CTypedef),
    index: *const AstIndex,
) !void {
    const record = resolveRecord(name, index) orelse return error.MissingAutobindStruct;
    try writer.writeAll("@FFI.Struct { layout: c; }\n");
    try writer.print("type {s} {{\n", .{name});
    for (record.fields) |field| {
        const type_name = try fieldTypeName(allocator, name, field, inline_callbacks);
        try writer.print("    let {s}: {s}\n", .{ sanitizeIdentifier(field.name), type_name });
    }
    try writer.writeAll("}\n\n");
}

fn writeMacroConstantsType(writer: anytype, library_name: []const u8, macro_names: []const []const u8, index: *const AstIndex) !void {
    try writer.print("type {s}_constants {{\n", .{library_name});
    for (macro_names) |name| {
        const macro = index.macros.get(name) orelse continue;
        try writer.print("    static let {s}: U64 = {s}\n", .{ macro.name, macro.value });
    }
    try writer.writeAll("}\n\n");
}

fn writeFunctionDecl(allocator: std.mem.Allocator, writer: anytype, library_name: []const u8, function_decl: CFunction) !void {
    try writer.print("@FFI.Extern {{ library: {s}; symbol: {s}; abi: c; }}\n", .{ library_name, function_decl.name });
    try writer.print("function {s}(", .{function_decl.name});
    for (function_decl.params, 0..) |param, index| {
        if (index != 0) try writer.writeAll(", ");
        const type_name = try kiraTypeName(allocator, param.qual_type);
        try writer.print("{s}: {s}", .{ sanitizeIdentifier(param.name), type_name });
    }
    const result_type = try kiraTypeName(allocator, function_decl.return_type);
    try writer.print("): {s};\n\n", .{result_type});
}

fn fieldTypeName(
    allocator: std.mem.Allocator,
    owner_name: []const u8,
    field: CField,
    inline_callbacks: *const std.StringHashMapUnmanaged(CTypedef),
) ![]const u8 {
    const callback_name = try syntheticFieldCallbackName(allocator, owner_name, field.name);
    if (inline_callbacks.contains(callback_name)) return callback_name;
    return kiraTypeName(allocator, field.qual_type);
}

fn collectTypeDependencies(
    allocator: std.mem.Allocator,
    qual_type: []const u8,
    required_structs: *std.StringHashMapUnmanaged(void),
    required_callbacks: *std.StringHashMapUnmanaged(void),
    required_pointers: *std.StringHashMapUnmanaged([]const u8),
    required_aliases: *std.StringHashMapUnmanaged(void),
    required_enums: *std.StringHashMapUnmanaged(void),
    required_arrays: *std.StringHashMapUnmanaged(ArrayTypeInfo),
    index: *const AstIndex,
) !void {
    const parsed = try parseCType(allocator, qual_type, index);
    switch (parsed) {
        .plain => {},
        .struct_name => |name| try required_structs.put(allocator, name, {}),
        .callback_name => |name| try required_callbacks.put(allocator, name, {}),
        .alias_name => |name| try required_aliases.put(allocator, name, {}),
        .enum_name => |name| try required_enums.put(allocator, name, {}),
        .array_name => |value| try required_arrays.put(allocator, value.name, value),
        .pointer_to_named => |value| {
            if (index.enums.contains(value.target_name)) {
                try required_enums.put(allocator, value.target_name, {});
            } else if (index.typedefs.contains(value.target_name) and resolveRecord(value.target_name, index) == null and index.typedefs.get(value.target_name).?.kind != .callback) {
                try required_aliases.put(allocator, value.target_name, {});
            } else {
                try required_structs.put(allocator, value.target_name, {});
            }
            try required_pointers.put(allocator, value.pointer_name, value.target_name);
        },
    }
}

fn collectSelectedTypeDependencies(
    allocator: std.mem.Allocator,
    selected_structs: std.StringHashMapUnmanaged(void),
    selected_aliases: std.StringHashMapUnmanaged(void),
    required_structs: *std.StringHashMapUnmanaged(void),
    required_callbacks: *std.StringHashMapUnmanaged(void),
    required_pointers: *std.StringHashMapUnmanaged([]const u8),
    required_aliases: *std.StringHashMapUnmanaged(void),
    required_enums: *std.StringHashMapUnmanaged(void),
    required_arrays: *std.StringHashMapUnmanaged(ArrayTypeInfo),
    index: *const AstIndex,
) !void {
    var struct_iter = selected_structs.iterator();
    while (struct_iter.next()) |entry| {
        const record = resolveRecord(entry.key_ptr.*, index) orelse continue;
        for (record.fields) |field| {
            try collectTypeDependencies(allocator, field.qual_type, required_structs, required_callbacks, required_pointers, required_aliases, required_enums, required_arrays, index);
        }
    }

    var alias_iter = selected_aliases.iterator();
    while (alias_iter.next()) |entry| {
        const typedef_decl = index.typedefs.get(entry.key_ptr.*) orelse continue;
        switch (typedef_decl.kind) {
            .alias => try collectTypeDependencies(allocator, typedef_decl.qual_type, required_structs, required_callbacks, required_pointers, required_aliases, required_enums, required_arrays, index),
            .array => try collectTypeDependencies(allocator, typedef_decl.array_element_type orelse continue, required_structs, required_callbacks, required_pointers, required_aliases, required_enums, required_arrays, index),
            .callback => {
                for (typedef_decl.callback_params) |param| {
                    try collectTypeDependencies(allocator, param, required_structs, required_callbacks, required_pointers, required_aliases, required_enums, required_arrays, index);
                }
                if (typedef_decl.callback_result) |result_type| {
                    try collectTypeDependencies(allocator, result_type, required_structs, required_callbacks, required_pointers, required_aliases, required_enums, required_arrays, index);
                }
            },
        }
    }
}

const ParsedType = union(enum) {
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

fn kiraTypeName(allocator: std.mem.Allocator, qual_type: []const u8) ![]const u8 {
    const text = std.mem.trim(u8, qual_type, " ");
    if (primitiveKiraTypeName(text)) |name| return allocator.dupe(u8, name);
    if (std.mem.startsWith(u8, text, "enum ")) return allocator.dupe(u8, text["enum ".len..]);
    if (try parseArrayType(allocator, text)) |array_info| {
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

fn parseCType(allocator: std.mem.Allocator, qual_type: []const u8, index: *const AstIndex) !ParsedType {
    const text = std.mem.trim(u8, qual_type, " ");
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
            .array, .alias => .{ .alias_name = try allocator.dupe(u8, text) },
        };
    }
    if (resolveRecord(text, index) != null) return .{ .struct_name = try allocator.dupe(u8, text) };
    return .plain;
}

fn resolveRecord(name: []const u8, index: *const AstIndex) ?CRecord {
    if (index.records.get(name)) |record| return record;
    if (index.typedefs.get(name)) |typedef_decl| {
        const target = trimStructPrefix(typedef_decl.qual_type);
        return index.records.get(target);
    }
    return null;
}

fn trimStructPrefix(text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " ");
    if (std.mem.startsWith(u8, trimmed, "struct ")) return trimmed["struct ".len..];
    return trimmed;
}

fn typedefResolvesToSelfRecordOrEnum(name: []const u8, typedef_decl: CTypedef, index: *const AstIndex) bool {
    if (resolveRecord(name, index) != null) {
        const target = trimStructPrefix(typedef_decl.qual_type);
        if (std.mem.eql(u8, target, name)) return true;
    }
    const trimmed = std.mem.trim(u8, typedef_decl.qual_type, " ");
    if (std.mem.startsWith(u8, trimmed, "enum ")) {
        const target = trimmed["enum ".len..];
        if (std.mem.eql(u8, target, name) and index.enums.contains(name)) return true;
    }
    return false;
}

fn trimPointerTarget(text: []const u8) []const u8 {
    var trimmed = std.mem.trim(u8, text, " ");
    while (std.mem.endsWith(u8, trimmed, "*")) {
        trimmed = std.mem.trimRight(u8, trimmed[0 .. trimmed.len - 1], " ");
    }
    if (std.mem.startsWith(u8, trimmed, "const ")) trimmed = trimmed["const ".len..];
    if (std.mem.startsWith(u8, trimmed, "struct ")) trimmed = trimmed["struct ".len..];
    return trimmed;
}

fn isPrimitiveType(text: []const u8) bool {
    return primitiveKiraTypeName(text) != null;
}

fn functionResultType(object: std.json.ObjectMap) ?[]const u8 {
    const type_value = object.get("type") orelse return null;
    if (type_value != .object) return null;
    const qual_type = objectString(type_value.object, "qualType") orelse return null;
    const open = std.mem.indexOfScalar(u8, qual_type, '(') orelse return qual_type;
    return std.mem.trimRight(u8, qual_type[0..open], " ");
}

fn extractEnumValue(object: std.json.ObjectMap) i64 {
    if (findIntegerValue(.{ .object = object })) |value| return value;
    return 0;
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

fn primitiveKiraTypeName(text: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, text, "void")) return "Void";
    if (std.mem.eql(u8, text, "char") or std.mem.eql(u8, text, "signed char") or std.mem.eql(u8, text, "int8_t")) return "I8";
    if (std.mem.eql(u8, text, "unsigned char") or std.mem.eql(u8, text, "uint8_t")) return "U8";
    if (std.mem.eql(u8, text, "short") or std.mem.eql(u8, text, "short int") or std.mem.eql(u8, text, "signed short") or std.mem.eql(u8, text, "int16_t")) return "I16";
    if (std.mem.eql(u8, text, "unsigned short") or std.mem.eql(u8, text, "unsigned short int") or std.mem.eql(u8, text, "uint16_t")) return "U16";
    if (std.mem.eql(u8, text, "int") or std.mem.eql(u8, text, "int32_t")) return "I32";
    if (std.mem.eql(u8, text, "unsigned int") or std.mem.eql(u8, text, "uint32_t")) return "U32";
    if (std.mem.eql(u8, text, "long long") or std.mem.eql(u8, text, "int64_t") or std.mem.eql(u8, text, "intptr_t") or std.mem.eql(u8, text, "ptrdiff_t")) return "I64";
    if (std.mem.eql(u8, text, "unsigned long long") or std.mem.eql(u8, text, "uint64_t") or std.mem.eql(u8, text, "uintptr_t") or std.mem.eql(u8, text, "size_t")) return "U64";
    if (std.mem.eql(u8, text, "float")) return "F32";
    if (std.mem.eql(u8, text, "double")) return "F64";
    if (std.mem.eql(u8, text, "_Bool") or std.mem.eql(u8, text, "bool")) return "CBool";
    if (std.mem.eql(u8, text, "const char *") or std.mem.eql(u8, text, "char *")) return "CString";
    if (std.mem.eql(u8, text, "const void *") or std.mem.eql(u8, text, "void *")) return "RawPtr";
    return null;
}

fn syntheticFieldCallbackName(allocator: std.mem.Allocator, owner_name: []const u8, field_name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}_{s}_callback", .{ owner_name, sanitizeIdentifier(field_name) });
}

fn parseInlineCallbackFromQualType(
    allocator: std.mem.Allocator,
    callback_name: []const u8,
    qual_type: []const u8,
) !?CTypedef {
    const text = std.mem.trim(u8, qual_type, " ");
    const marker = std.mem.indexOf(u8, text, "(*)") orelse return null;
    const result_text = std.mem.trimRight(u8, text[0..marker], " ");
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

fn parseArrayType(allocator: std.mem.Allocator, text: []const u8) !?ArrayTypeInfo {
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

fn syntheticArrayTypeName(allocator: std.mem.Allocator, element_text: []const u8, count: usize) ![]const u8 {
    const base_name = if (primitiveKiraTypeName(element_text)) |name|
        name
    else if (std.mem.endsWith(u8, element_text, "*"))
        try std.fmt.allocPrint(allocator, "{s}_ptr", .{trimPointerTarget(element_text)})
    else
        trimStructPrefix(element_text);
    return std.fmt.allocPrint(allocator, "{s}_array_{d}", .{ base_name, count });
}

fn sanitizeIdentifier(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "type")) return "type_value";
    if (std.mem.eql(u8, name, "function")) return "function_value";
    if (std.mem.eql(u8, name, "return")) return "return_value";
    if (std.mem.eql(u8, name, "switch")) return "switch_value";
    if (std.mem.eql(u8, name, "for")) return "for_value";
    if (std.mem.eql(u8, name, "if")) return "if_value";
    if (std.mem.eql(u8, name, "else")) return "else_value";
    if (std.mem.eql(u8, name, "let")) return "let_value";
    if (std.mem.eql(u8, name, "var")) return "var_value";
    if (std.mem.eql(u8, name, "import")) return "import_value";
    if (std.mem.eql(u8, name, "construct")) return "construct_value";
    return name;
}

fn sortStrings(values: [][]const u8) void {
    std.mem.sort([]const u8, values, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.order(u8, lhs, rhs) == .lt;
        }
    }.lessThan);
}

fn sortedMapKeys(allocator: std.mem.Allocator, map: anytype) ![]const []const u8 {
    var keys = std.array_list.Managed([]const u8).init(allocator);
    var iter = map.iterator();
    while (iter.next()) |entry| try keys.append(entry.key_ptr.*);
    sortStrings(keys.items);
    return keys.toOwnedSlice();
}

fn collectMacroConstants(allocator: std.mem.Allocator, headers: []const []const u8, index: *AstIndex) !void {
    for (headers) |header_path| {
        const text = try std.fs.cwd().readFileAlloc(allocator, header_path, 4 * 1024 * 1024);
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (!std.mem.startsWith(u8, line, "#define ")) continue;
            const rest = std.mem.trimLeft(u8, line["#define ".len..], " \t");
            var parts = std.mem.tokenizeAny(u8, rest, " \t");
            const name = parts.next() orelse continue;
            if (name.len == 0 or name[0] == '_' or std.mem.indexOfScalar(u8, name, '(') != null) continue;
            const value_text = std.mem.trim(u8, rest[name.len..], " \t");
            if (normalizeIntegerMacroValue(allocator, value_text)) |value| {
                try index.macros.put(allocator, try allocator.dupe(u8, name), .{
                    .name = try allocator.dupe(u8, name),
                    .value = value,
                });
            }
        }
    }
}

fn normalizeIntegerMacroValue(allocator: std.mem.Allocator, text: []const u8) ?[]const u8 {
    if (text.len == 0) return null;
    const trimmed = std.mem.trim(u8, text, " \t()");
    if (trimmed.len == 0) return null;
    var end = trimmed.len;
    while (end > 0) {
        const ch = trimmed[end - 1];
        if (ch == 'u' or ch == 'U' or ch == 'l' or ch == 'L') {
            end -= 1;
            continue;
        }
        break;
    }
    const candidate = trimmed[0..end];
    const signed_value = std.fmt.parseInt(i64, candidate, 0) catch {
        const unsigned_value = std.fmt.parseInt(u64, candidate, 0) catch return null;
        return std.fmt.allocPrint(allocator, "{d}", .{unsigned_value}) catch null;
    };
    return std.fmt.allocPrint(allocator, "{d}", .{signed_value}) catch null;
}

fn objectString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn objectBool(object: std.json.ObjectMap, key: []const u8) bool {
    const value = object.get(key) orelse return false;
    return value == .bool and value.bool;
}

fn objectQualType(object: std.json.ObjectMap) ?[]const u8 {
    const type_value = object.get("type") orelse return null;
    if (type_value != .object) return null;
    return objectString(type_value.object, "qualType");
}

fn cloneStrings(allocator: std.mem.Allocator, values: []const []const u8) ![]const []const u8 {
    var list = std.array_list.Managed([]const u8).init(allocator);
    for (values) |value| {
        try list.append(try allocator.dupe(u8, value));
    }
    return list.toOwnedSlice();
}

fn trimComment(line: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0 or trimmed[0] == '#') return "";
    return trimmed;
}

fn assignString(line: []const u8, key: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, key)) return null;
    const equal_index = std.mem.indexOfScalar(u8, line, '=') orelse return null;
    return unquote(std.mem.trim(u8, line[equal_index + 1 ..], " \t"));
}

fn unquote(value: []const u8) []const u8 {
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
        return value[1 .. value.len - 1];
    }
    return value;
}

fn parseStringArray(allocator: std.mem.Allocator, line: []const u8) ![]const []const u8 {
    const start = std.mem.indexOfScalar(u8, line, '[') orelse return error.InvalidManifest;
    const end = std.mem.lastIndexOfScalar(u8, line, ']') orelse return error.InvalidManifest;
    var items = std.array_list.Managed([]const u8).init(allocator);
    var parts = std.mem.splitScalar(u8, line[start + 1 .. end], ',');
    while (parts.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        if (trimmed.len == 0) continue;
        try items.append(try allocator.dupe(u8, unquote(trimmed)));
    }
    return items.toOwnedSlice();
}

fn makePath(path: []const u8) !void {
    if (!std.fs.path.isAbsolute(path)) {
        try std.fs.cwd().makePath(path);
        return;
    }
    var root = try std.fs.openDirAbsolute("/", .{});
    defer root.close();
    try root.makePath(path[1..]);
}

test "parses a simple autobinding spec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const spec = try parseAutobindingSpec(arena.allocator(),
        \\[bindings]
        \\functions = ["add"]
        \\structs = ["foo"]
        \\callbacks = ["log_fn"]
    );

    try std.testing.expectEqual(@as(usize, 1), spec.functions.len);
    try std.testing.expectEqual(@as(usize, 1), spec.structs.len);
    try std.testing.expectEqual(@as(usize, 1), spec.callbacks.len);
}
