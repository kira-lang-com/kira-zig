const std = @import("std");
const builtin = @import("builtin");
const ir = @import("kira_ir");
const runtime_abi = @import("kira_runtime_abi");
const backend_api = @import("kira_backend_api");
const build_options = @import("kira_llvm_build_options");
const llvm = @import("llvm_c.zig");
const runtime_symbols = @import("runtime_symbols.zig");
const parent = @import("backend.zig");
const shouldLowerFunction = parent.shouldLowerFunction;
pub fn writePrintInstruction(writer: anytype, value_type: ir.ValueType, src: u32, temp_counter: *usize) !void {
    switch (value_type.kind) {
        .integer => {
            try writer.writeAll("  call void @\"kira_native_print_i64\"(i64 %r");
            try writer.print("{d}", .{src});
            try writer.writeAll(")\n");
        },
        .float => {
            const temp_index = temp_counter.*;
            temp_counter.* += 1;
            if (value_type.name != null and std.mem.eql(u8, value_type.name.?, "F32")) {
                try writer.writeAll("  %float.ext.");
                try writer.print("{d}", .{temp_index});
                try writer.writeAll(" = fpext float %r");
                try writer.print("{d}", .{src});
                try writer.writeAll(" to double\n");
                try writer.writeAll("  call void @\"kira_native_print_f64\"(double %float.ext.");
                try writer.print("{d}", .{temp_index});
                try writer.writeAll(")\n");
            } else {
                try writer.writeAll("  call void @\"kira_native_print_f64\"(double %r");
                try writer.print("{d}", .{src});
                try writer.writeAll(")\n");
            }
        },
        .string => {
            const temp_index = temp_counter.*;
            temp_counter.* += 1;

            try writer.writeAll("  %str.ptr.");
            try writer.print("{d}", .{temp_index});
            try writer.writeAll(" = extractvalue %kira.string %r");
            try writer.print("{d}", .{src});
            try writer.writeAll(", 0\n");
            try writer.writeAll("  %str.len.");
            try writer.print("{d}", .{temp_index});
            try writer.writeAll(" = extractvalue %kira.string %r");
            try writer.print("{d}", .{src});
            try writer.writeAll(", 1\n");
            try writer.writeAll("  call void @\"kira_native_print_string\"(ptr %str.ptr.");
            try writer.print("{d}", .{temp_index});
            try writer.writeAll(", i64 %str.len.");
            try writer.print("{d}", .{temp_index});
            try writer.writeAll(")\n");
        },
        .boolean => {
            const temp_index = temp_counter.*;
            temp_counter.* += 1;

            try writer.writeAll("  %bool.ptr.");
            try writer.print("{d}", .{temp_index});
            try writer.writeAll(" = select i1 %r");
            try writer.print("{d}", .{src});
            try writer.writeAll(", ptr @kira_bool_true, ptr @kira_bool_false\n");
            try writer.writeAll("  %bool.val.");
            try writer.print("{d}", .{temp_index});
            try writer.writeAll(" = load %kira.string, ptr %bool.ptr.");
            try writer.print("{d}\n", .{temp_index});
            try writer.writeAll("  %bool.str.ptr.");
            try writer.print("{d}", .{temp_index});
            try writer.writeAll(" = extractvalue %kira.string %bool.val.");
            try writer.print("{d}", .{temp_index});
            try writer.writeAll(", 0\n");
            try writer.writeAll("  %bool.str.len.");
            try writer.print("{d}", .{temp_index});
            try writer.writeAll(" = extractvalue %kira.string %bool.val.");
            try writer.print("{d}", .{temp_index});
            try writer.writeAll(", 1\n");
            try writer.writeAll("  call void @\"kira_native_print_string\"(ptr %bool.str.ptr.");
            try writer.print("{d}", .{temp_index});
            try writer.writeAll(", i64 %bool.str.len.");
            try writer.print("{d}", .{temp_index});
            try writer.writeAll(")\n");
        },
        .void, .array, .raw_ptr, .ffi_struct => return error.UnsupportedExecutableFeature,
    }
}

pub fn appendStringGlobals(
    allocator: std.mem.Allocator,
    globals: *std.array_list.Managed([]const u8),
    index: usize,
    value: []const u8,
) !void {
    const data_name = try std.fmt.allocPrint(allocator, "kira_str_{d}_data", .{index});
    defer allocator.free(data_name);
    const struct_name = try std.fmt.allocPrint(allocator, "kira_str_{d}", .{index});
    defer allocator.free(struct_name);

    var data_line = std.array_list.Managed(u8).init(allocator);
    errdefer data_line.deinit();
    var data_writer = data_line.writer();
    try data_writer.print("@{s} = private unnamed_addr constant [{d} x i8] c\"", .{ data_name, value.len + 1 });
    try writeLlvmStringLiteral(data_writer, value);
    try data_writer.writeAll("\\00\"\n");
    try globals.append(try data_line.toOwnedSlice());

    var struct_line = std.array_list.Managed(u8).init(allocator);
    errdefer struct_line.deinit();
    var struct_writer = struct_line.writer();
    try struct_writer.print("@{s} = private unnamed_addr constant %kira.string {{ ptr getelementptr inbounds ([{d} x i8], ptr @{s}, i64 0, i64 0), i64 {d} }}\n", .{
        struct_name,
        value.len + 1,
        data_name,
        value.len,
    });
    try globals.append(try struct_line.toOwnedSlice());
}

pub fn writeLlvmSymbol(writer: anytype, symbol: []const u8) !void {
    try writer.writeAll("@\"");
    try writeLlvmEscapedBytes(writer, symbol);
    try writer.writeByte('"');
}

pub fn writeLlvmStringLiteral(writer: anytype, bytes: []const u8) !void {
    try writeLlvmEscapedBytes(writer, bytes);
}

pub fn writeLlvmEscapedBytes(writer: anytype, bytes: []const u8) !void {
    for (bytes) |byte| {
        if (byte >= 0x20 and byte <= 0x7e and byte != '\\' and byte != '"') {
            try writer.writeByte(byte);
        } else {
            try writer.writeByte('\\');
            try writer.writeByte(hexDigit(byte >> 4));
            try writer.writeByte(hexDigit(byte & 0x0f));
        }
    }
}

pub fn writeLlvmFloatLiteral(writer: anytype, value: f64) !void {
    const truncated = @trunc(value);
    if (truncated == value and value >= @as(f64, @floatFromInt(std.math.minInt(i64))) and value <= @as(f64, @floatFromInt(std.math.maxInt(i64)))) {
        try writer.print("{d}.0", .{@as(i64, @intFromFloat(value))});
        return;
    }
    try writer.print("{d}", .{value});
}

pub fn hexDigit(value: u8) u8 {
    const index: usize = @intCast(value & 0x0f);
    return "0123456789ABCDEF"[index];
}

pub fn appendTypeDefinitions(allocator: std.mem.Allocator, writer: anytype, program: *const ir.Program) !void {
    for (program.types) |type_decl| {
        if (type_decl.ffi) |ffi_info| {
            if (ffi_info != .ffi_struct) continue;
        }
        try writer.writeAll(typeRefName(type_decl.name));
        try writer.writeAll(" = type { ");
        for (type_decl.fields, 0..) |field_decl, index| {
            if (index != 0) try writer.writeAll(", ");
            try writer.writeAll(try llvmFieldAbiTypeText(allocator, program, field_decl.ty));
        }
        try writer.writeAll(" }\n");
    }
    if (program.types.len > 0) try writer.writeByte('\n');
}

pub fn typeRefName(name: []const u8) []const u8 {
    return switch (name.len) {
        0 => "%t.anon",
        else => std.fmt.allocPrint(std.heap.page_allocator, "%t.{s}", .{name}) catch "%t.invalid",
    };
}

pub fn findTypeDecl(program: *const ir.Program, name: []const u8) ?ir.TypeDecl {
    for (program.types) |type_decl| {
        if (std.mem.eql(u8, type_decl.name, name)) return type_decl;
    }
    return null;
}

pub fn llvmFieldAbiTypeText(allocator: std.mem.Allocator, program: *const ir.Program, value_type: ir.ValueType) ![]const u8 {
    switch (value_type.kind) {
        .void => return allocator.dupe(u8, "void"),
        .string => return allocator.dupe(u8, "%kira.string"),
        .boolean => return allocator.dupe(u8, "i8"),
        .raw_ptr => {
            if (value_type.name) |name| {
                if (findTypeDecl(program, name)) |type_decl| {
                    if (type_decl.ffi) |ffi_info| {
                        return switch (ffi_info) {
                            .array => |info| std.fmt.allocPrint(allocator, "[{d} x {s}]", .{ info.count, try llvmFieldAbiTypeText(allocator, program, info.element) }),
                            .alias => |info| llvmFieldAbiTypeText(allocator, program, info.target),
                            else => allocator.dupe(u8, "ptr"),
                        };
                    }
                }
            }
            return allocator.dupe(u8, "ptr");
        },
        .integer => return allocator.dupe(u8, integerAbiTypeName(value_type.name)),
        .float => return allocator.dupe(u8, floatAbiTypeName(value_type.name)),
        .array => return allocator.dupe(u8, "ptr"),
        .ffi_struct => return allocator.dupe(u8, typeRefName(value_type.name orelse return error.UnsupportedExecutableFeature)),
    }
}

pub fn integerAbiTypeName(name: ?[]const u8) []const u8 {
    const value = name orelse "I64";
    if (std.mem.eql(u8, value, "I8") or std.mem.eql(u8, value, "U8")) return "i8";
    if (std.mem.eql(u8, value, "I16") or std.mem.eql(u8, value, "U16")) return "i16";
    if (std.mem.eql(u8, value, "I32") or std.mem.eql(u8, value, "U32")) return "i32";
    return "i64";
}

pub fn floatAbiTypeName(name: ?[]const u8) []const u8 {
    if (name) |value| {
        if (std.mem.eql(u8, value, "F32")) return "float";
        if (std.mem.eql(u8, value, "F64")) return "double";
    }
    return "double";
}

pub fn llvmValueTypeText(value_type: ir.ValueType) []const u8 {
    return switch (value_type.kind) {
        .void => "void",
        .integer => "i64",
        .float => floatAbiTypeName(value_type.name),
        .string => "%kira.string",
        .boolean => "i1",
        .array, .raw_ptr, .ffi_struct => "i64",
    };
}

pub fn llvmCompareValueTypeText(value_type: ir.ValueType) []const u8 {
    return switch (value_type.kind) {
        .integer, .array, .raw_ptr, .ffi_struct => "i64",
        .float => floatAbiTypeName(value_type.name),
        .boolean => "i1",
        else => unreachable,
    };
}

pub fn llvmComparePredicate(value_type: ir.ValueType, op: ir.CompareOp) ![]const u8 {
    return switch (value_type.kind) {
        .integer => switch (op) {
            .equal => "eq",
            .not_equal => "ne",
            .less => "slt",
            .less_equal => "sle",
            .greater => "sgt",
            .greater_equal => "sge",
        },
        .float => switch (op) {
            .equal => "oeq",
            .not_equal => "one",
            .less => "olt",
            .less_equal => "ole",
            .greater => "ogt",
            .greater_equal => "oge",
        },
        .boolean, .array, .raw_ptr, .ffi_struct => switch (op) {
            .equal => "eq",
            .not_equal => "ne",
            else => error.UnsupportedExecutableFeature,
        },
        else => error.UnsupportedExecutableFeature,
    };
}

pub fn llvmCallTypeText(value_type: ir.ValueType, is_extern: bool) []const u8 {
    if (!is_extern) return llvmValueTypeText(value_type);
    return switch (value_type.kind) {
        .array, .raw_ptr => "ptr",
        .integer => integerAbiTypeName(value_type.name),
        .float => floatAbiTypeName(value_type.name),
        .boolean => "i1",
        .ffi_struct => typeRefName(value_type.name orelse "anon"),
        else => llvmValueTypeText(value_type),
    };
}

pub fn llvmLocalStorageTypeText(allocator: std.mem.Allocator, program: *const ir.Program, value_type: ir.ValueType) ![]const u8 {
    _ = program;
    return switch (value_type.kind) {
        .array, .ffi_struct => allocator.dupe(u8, "i64"),
        else => allocator.dupe(u8, llvmValueTypeText(value_type)),
    };
}

pub fn isPointerLikeValueType(value_type: ir.ValueType) bool {
    return value_type.kind == .array or value_type.kind == .raw_ptr or value_type.kind == .ffi_struct;
}

pub fn fieldIndex(program: *const ir.Program, owner_type_name: []const u8, field_name: []const u8) ?usize {
    const type_decl = findTypeDecl(program, owner_type_name) orelse return null;
    for (type_decl.fields, 0..) |field_decl, index| {
        if (std.mem.eql(u8, field_decl.name, field_name)) return index;
    }
    return null;
}

pub fn fieldType(program: *const ir.Program, owner_type_name: []const u8, field_name: []const u8) ?ir.ValueType {
    const type_decl = findTypeDecl(program, owner_type_name) orelse return null;
    for (type_decl.fields) |field_decl| {
        if (std.mem.eql(u8, field_decl.name, field_name)) return field_decl.ty;
    }
    return null;
}

pub fn llvmIndirectLoadTypeText(allocator: std.mem.Allocator, program: *const ir.Program, value_type: ir.ValueType) ![]const u8 {
    return switch (value_type.kind) {
        .integer, .float, .boolean, .raw_ptr, .ffi_struct => llvmFieldAbiTypeText(allocator, program, value_type),
        else => allocator.dupe(u8, llvmValueTypeText(value_type)),
    };
}

pub fn llvmFieldStoreValuePrefix(writer: anytype, dst_reg: u32) !void {
    try writer.writeAll("  %r");
    try writer.print("{d}", .{dst_reg});
    try writer.writeAll(" = ");
}

pub fn writeLlvmLabelName(writer: anytype, label: u32) !void {
    try writer.print("kira_label_{d}", .{label});
}

pub fn countStringConstants(function_decl: ir.Function) usize {
    var count: usize = 0;
    for (function_decl.instructions) |instruction| {
        switch (instruction) {
            .const_string => count += 1,
            else => {},
        }
    }
    return count;
}

pub fn freeStringList(allocator: std.mem.Allocator, list: *std.array_list.Managed([]const u8)) void {
    for (list.items) |item| allocator.free(item);
    list.deinit();
}

pub fn freeSymbolNames(allocator: std.mem.Allocator, symbols: *std.AutoHashMapUnmanaged(u32, []const u8)) void {
    var iterator = symbols.iterator();
    while (iterator.next()) |entry| {
        allocator.free(entry.value_ptr.*);
    }
    symbols.deinit(allocator);
}

pub fn writeTextFile(path: []const u8, data: []const u8) !void {
    if (std.fs.path.isAbsolute(path)) {
        const file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(data);
        return;
    }
    try std.fs.cwd().writeFile(.{
        .sub_path = path,
        .data = data,
    });
}

pub fn emitObjectFileViaZigCc(
    allocator: std.mem.Allocator,
    api: *const llvm.Api,
    module_ref: llvm.c.LLVMModuleRef,
    object_path: []const u8,
) !void {
    const ir_text_z = api.LLVMPrintModuleToString(module_ref);
    defer api.LLVMDisposeMessage(ir_text_z);

    const ir_text = std.mem.span(ir_text_z);
    const ir_path = try std.fmt.allocPrint(allocator, "{s}.ll", .{object_path});
    defer allocator.free(ir_path);
    defer std.fs.cwd().deleteFile(ir_path) catch {};

    try std.fs.cwd().writeFile(.{
        .sub_path = ir_path,
        .data = ir_text,
    });

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ build_options.zig_exe, "cc", "-c", "-x", "ir", "-o", object_path, ir_path },
        .max_output_bytes = 512 * 1024,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term != .Exited or result.term.Exited != 0) {
        return error.ObjectEmissionFailed;
    }
}

pub fn inferRegisterTypes(allocator: std.mem.Allocator, program: ir.Program, function_decl: ir.Function) ![]ir.ValueType {
    const register_types = try allocator.alloc(ir.ValueType, function_decl.register_count);
    for (function_decl.instructions) |instruction| {
        switch (instruction) {
            .const_int => |value| register_types[value.dst] = .{ .kind = .integer, .name = "I64" },
            .const_float => |value| register_types[value.dst] = .{ .kind = .float, .name = "F64" },
            .const_string => |value| register_types[value.dst] = .{ .kind = .string },
            .const_bool => |value| register_types[value.dst] = .{ .kind = .boolean },
            .const_null_ptr => |value| register_types[value.dst] = .{ .kind = .raw_ptr, .name = "RawPtr" },
            .alloc_struct => |value| register_types[value.dst] = .{ .kind = .ffi_struct, .name = value.type_name },
            .alloc_native_state => |value| register_types[value.dst] = .{ .kind = .raw_ptr, .name = value.type_name },
            .alloc_array => |value| register_types[value.dst] = .{ .kind = .array },
            .const_function => |value| register_types[value.dst] = .{ .kind = .raw_ptr, .name = if (value.representation == .callable_value) "Callable" else "RawPtr" },
            .add => |value| register_types[value.dst] = register_types[value.lhs],
            .subtract => |value| register_types[value.dst] = register_types[value.lhs],
            .multiply => |value| register_types[value.dst] = register_types[value.lhs],
            .divide => |value| register_types[value.dst] = register_types[value.lhs],
            .modulo => |value| register_types[value.dst] = register_types[value.lhs],
            .compare => |value| register_types[value.dst] = .{ .kind = .boolean },
            .unary => |value| register_types[value.dst] = switch (value.op) {
                .negate => register_types[value.src],
                .not => .{ .kind = .boolean },
            },
            .store_local => {},
            .load_local => |value| register_types[value.dst] = function_decl.local_types[value.local],
            .subobject_ptr => |value| register_types[value.dst] = register_types[value.base],
            .field_ptr => |value| register_types[value.dst] = .{ .kind = .raw_ptr, .name = value.field_ty.name },
            .recover_native_state => |value| register_types[value.dst] = .{ .kind = .raw_ptr, .name = value.type_name },
            .native_state_field_get => |value| register_types[value.dst] = value.field_ty,
            .array_len => |value| register_types[value.dst] = .{ .kind = .integer, .name = "I64" },
            .array_get => |value| register_types[value.dst] = value.ty,
            .array_set, .native_state_field_set => {},
            .load_indirect => |value| register_types[value.dst] = value.ty,
            .store_indirect, .copy_indirect, .branch, .jump, .label => {},
            .print => {},
            .call => |value| if (value.dst) |dst| {
                const callee_decl = functionById(program, value.callee) orelse return error.UnknownFunction;
                register_types[dst] = callee_decl.return_type;
            },
            .call_value => |value| if (value.dst) |dst| {
                register_types[dst] = value.return_type;
            },
            .ret => {},
        }
    }
    return register_types;
}

pub fn functionExecutionById(program: ir.Program, function_id: u32) ?runtime_abi.FunctionExecution {
    for (program.functions) |function_decl| {
        if (function_decl.id == function_id) return function_decl.execution;
    }
    return null;
}

pub fn functionById(program: ir.Program, function_id: u32) ?ir.Function {
    for (program.functions) |function_decl| {
        if (function_decl.id == function_id) return function_decl;
    }
    return null;
}

pub fn buildTextExternDecl(
    allocator: std.mem.Allocator,
    request: backend_api.CompileRequest,
    symbol_names: *const std.AutoHashMapUnmanaged(u32, []const u8),
    function_decl: ir.Function,
) ![]const u8 {
    _ = request;
    var output = std.array_list.Managed(u8).init(allocator);
    errdefer output.deinit();
    var writer = output.writer();
    try writer.writeAll("declare ");
    try writer.writeAll(llvmCallTypeText(function_decl.return_type, true));
    try writer.writeByte(' ');
    try writeLlvmSymbol(writer, symbol_names.get(function_decl.id) orelse return error.MissingFunctionDeclaration);
    try writer.writeByte('(');
    for (function_decl.param_types, 0..) |param_type, index| {
        if (index != 0) try writer.writeAll(", ");
        try writer.writeAll(llvmCallTypeText(param_type, true));
    }
    try writer.writeAll(")\n");
    return output.toOwnedSlice();
}

pub fn buildHybridBridgeWrapper(
    allocator: std.mem.Allocator,
    symbol_names: *const std.AutoHashMapUnmanaged(u32, []const u8),
    function_decl: ir.Function,
) ![]const u8 {
    var output = std.array_list.Managed(u8).init(allocator);
    errdefer output.deinit();
    var writer = output.writer();

    const export_name = try std.fmt.allocPrint(allocator, "kira_native_fn_{d}", .{function_decl.id});
    defer allocator.free(export_name);
    const impl_name = symbol_names.get(function_decl.id) orelse return error.MissingFunctionDeclaration;

    try writer.writeAll("define ");
    if (builtin.os.tag == .windows) {
        try writer.writeAll("dllexport ");
    }
    try writer.writeAll("void ");
    try writeLlvmSymbol(writer, export_name);
    try writer.writeAll("(ptr %args, i32 %arg_count, ptr %out_result) {\nentry:\n");

    for (function_decl.param_types, 0..) |param_type, index| {
        try writer.writeAll("  %bridge.slot.");
        try writer.print("{d}", .{index});
        try writer.print(" = getelementptr inbounds %kira.bridge.value, ptr %args, i64 {d}\n", .{index});
        try writer.writeAll("  %bridge.load.");
        try writer.print("{d}", .{index});
        try writer.writeAll(" = load %kira.bridge.value, ptr %bridge.slot.");
        try writer.print("{d}\n", .{index});
        switch (param_type.kind) {
            .integer, .raw_ptr, .ffi_struct, .array => {
                try writer.writeAll("  %bridge.word0.");
                try writer.print("{d}", .{index});
                try writer.writeAll(" = extractvalue %kira.bridge.value %bridge.load.");
                try writer.print("{d}", .{index});
                try writer.writeAll(", 2\n");
            },
            .float => {
                try writer.writeAll("  %bridge.word0.");
                try writer.print("{d}", .{index});
                try writer.writeAll(" = extractvalue %kira.bridge.value %bridge.load.");
                try writer.print("{d}", .{index});
                try writer.writeAll(", 2\n");
                try writer.writeAll("  %bridge.float64.");
                try writer.print("{d}", .{index});
                try writer.writeAll(" = bitcast i64 %bridge.word0.");
                try writer.print("{d}", .{index});
                try writer.writeAll(" to double\n");
                if (param_type.name != null and std.mem.eql(u8, param_type.name.?, "F32")) {
                    try writer.writeAll("  %bridge.float.");
                    try writer.print("{d}", .{index});
                    try writer.writeAll(" = fptrunc double %bridge.float64.");
                    try writer.print("{d}", .{index});
                    try writer.writeAll(" to float\n");
                } else {
                    try writer.writeAll("  %bridge.float.");
                    try writer.print("{d}", .{index});
                    try writer.writeAll(" = fadd double %bridge.float64.");
                    try writer.print("{d}", .{index});
                    try writer.writeAll(", 0.0\n");
                }
            },
            .boolean => {
                try writer.writeAll("  %bridge.word0.");
                try writer.print("{d}", .{index});
                try writer.writeAll(" = extractvalue %kira.bridge.value %bridge.load.");
                try writer.print("{d}", .{index});
                try writer.writeAll(", 2\n");
                try writer.writeAll("  %bridge.bool.");
                try writer.print("{d}", .{index});
                try writer.writeAll(" = trunc i64 %bridge.word0.");
                try writer.print("{d}", .{index});
                try writer.writeAll(" to i1\n");
            },
            .string => {
                try writer.writeAll("  %bridge.ptrint.");
                try writer.print("{d}", .{index});
                try writer.writeAll(" = extractvalue %kira.bridge.value %bridge.load.");
                try writer.print("{d}", .{index});
                try writer.writeAll(", 2\n");
                try writer.writeAll("  %bridge.len.");
                try writer.print("{d}", .{index});
                try writer.writeAll(" = extractvalue %kira.bridge.value %bridge.load.");
                try writer.print("{d}", .{index});
                try writer.writeAll(", 3\n");
                try writer.writeAll("  %bridge.ptr.");
                try writer.print("{d}", .{index});
                try writer.writeAll(" = inttoptr i64 %bridge.ptrint.");
                try writer.print("{d}", .{index});
                try writer.writeAll(" to ptr\n");
                try writer.writeAll("  %bridge.str.init.");
                try writer.print("{d}", .{index});
                try writer.writeAll(" = insertvalue %kira.string zeroinitializer, ptr %bridge.ptr.");
                try writer.print("{d}", .{index});
                try writer.writeAll(", 0\n");
                try writer.writeAll("  %bridge.str.");
                try writer.print("{d}", .{index});
                try writer.writeAll(" = insertvalue %kira.string %bridge.str.init.");
                try writer.print("{d}", .{index});
                try writer.writeAll(", i64 %bridge.len.");
                try writer.print("{d}", .{index});
                try writer.writeAll(", 1\n");
            },
            .void => {},
        }
    }

    if (function_decl.return_type.kind == .void) {
        try writer.writeAll("  call void ");
    } else {
        try writer.writeAll("  %bridge.call = call ");
        try writer.writeAll(llvmValueTypeText(function_decl.return_type));
        try writer.writeByte(' ');
    }
    try writeLlvmSymbol(writer, impl_name);
    try writer.writeByte('(');
    for (function_decl.param_types, 0..) |param_type, index| {
        if (index != 0) try writer.writeAll(", ");
        try writer.writeAll(llvmValueTypeText(param_type));
        try writer.writeByte(' ');
        switch (param_type.kind) {
            .integer, .raw_ptr, .ffi_struct, .array => {
                try writer.writeAll("%bridge.word0.");
                try writer.print("{d}", .{index});
            },
            .float => {
                try writer.writeAll("%bridge.float.");
                try writer.print("{d}", .{index});
            },
            .boolean => {
                try writer.writeAll("%bridge.bool.");
                try writer.print("{d}", .{index});
            },
            .string => {
                try writer.writeAll("%bridge.str.");
                try writer.print("{d}", .{index});
            },
            .void => try writer.writeAll("undef"),
        }
    }
    try writer.writeAll(")\n");

    try writer.writeAll("  %bridge.out.0 = insertvalue %kira.bridge.value zeroinitializer, i8 ");
    try writer.print("{d}", .{bridgeTagValue(function_decl.return_type)});
    try writer.writeAll(", 0\n");
    switch (function_decl.return_type.kind) {
        .void => {
            try writer.writeAll("  store %kira.bridge.value %bridge.out.0, ptr %out_result\n");
        },
        .integer, .raw_ptr, .ffi_struct, .array => {
            try writer.writeAll("  %bridge.out.1 = insertvalue %kira.bridge.value %bridge.out.0, i64 %bridge.call, 2\n");
            try writer.writeAll("  store %kira.bridge.value %bridge.out.1, ptr %out_result\n");
        },
        .boolean => {
            try writer.writeAll("  %bridge.ret.bool = zext i1 %bridge.call to i64\n");
            try writer.writeAll("  %bridge.out.1 = insertvalue %kira.bridge.value %bridge.out.0, i64 %bridge.ret.bool, 2\n");
            try writer.writeAll("  store %kira.bridge.value %bridge.out.1, ptr %out_result\n");
        },
        .float => {
            if (function_decl.return_type.name != null and std.mem.eql(u8, function_decl.return_type.name.?, "F32")) {
                try writer.writeAll("  %bridge.ret.float64 = fpext float %bridge.call to double\n");
                try writer.writeAll("  %bridge.ret.float = bitcast double %bridge.ret.float64 to i64\n");
            } else {
                try writer.writeAll("  %bridge.ret.float = bitcast double %bridge.call to i64\n");
            }
            try writer.writeAll("  %bridge.out.1 = insertvalue %kira.bridge.value %bridge.out.0, i64 %bridge.ret.float, 2\n");
            try writer.writeAll("  store %kira.bridge.value %bridge.out.1, ptr %out_result\n");
        },
        .string => {
            try writer.writeAll("  %bridge.ret.ptr = extractvalue %kira.string %bridge.call, 0\n");
            try writer.writeAll("  %bridge.ret.ptrint = ptrtoint ptr %bridge.ret.ptr to i64\n");
            try writer.writeAll("  %bridge.ret.len = extractvalue %kira.string %bridge.call, 1\n");
            try writer.writeAll("  %bridge.out.1 = insertvalue %kira.bridge.value %bridge.out.0, i64 %bridge.ret.ptrint, 2\n");
            try writer.writeAll("  %bridge.out.2 = insertvalue %kira.bridge.value %bridge.out.1, i64 %bridge.ret.len, 3\n");
            try writer.writeAll("  store %kira.bridge.value %bridge.out.2, ptr %out_result\n");
        },
    }
    try writer.writeAll("  ret void\n}\n");
    return output.toOwnedSlice();
}

pub fn bridgeTagValue(value_type: ir.ValueType) u8 {
    return switch (value_type.kind) {
        .void => 0,
        .integer => 1,
        .float => 2,
        .string => 3,
        .boolean => 4,
        .array, .raw_ptr, .ffi_struct => 5,
    };
}

pub fn resolveExecution(execution: runtime_abi.FunctionExecution, mode: backend_api.BackendMode) runtime_abi.FunctionExecution {
    return switch (execution) {
        .inherited => switch (mode) {
            .llvm_native => .native,
            .hybrid => .runtime,
            .vm_bytecode => .runtime,
        },
        else => execution,
    };
}

pub fn requiresTextIrFallback(program: ir.Program, mode: backend_api.BackendMode) bool {
    if (mode == .vm_bytecode) return false;

    for (program.functions) |function_decl| {
        if (!shouldLowerFunction(function_decl.execution, mode)) continue;
        if (functionDeclNeedsTextIrFallback(program, function_decl, mode)) return true;
    }
    return false;
}

pub fn functionDeclNeedsTextIrFallback(program: ir.Program, function_decl: ir.Function, mode: backend_api.BackendMode) bool {
    if (function_decl.is_extern) return true;
    if (function_decl.param_types.len != 0) return true;
    if (function_decl.return_type.kind != .void) return true;

    for (function_decl.local_types) |local_type| {
        if (local_type.kind == .ffi_struct or local_type.kind == .array) return true;
    }

    for (function_decl.instructions) |instruction| {
        switch (instruction) {
            .const_int, .const_string, .const_bool, .const_null_ptr, .add, .subtract, .multiply, .divide, .modulo, .unary, .store_local, .load_local => {},
            .const_float => return true,
            .compare, .branch, .jump, .label => return true,
            .alloc_struct, .alloc_native_state, .alloc_array, .const_function, .subobject_ptr, .field_ptr, .recover_native_state, .native_state_field_get, .native_state_field_set, .array_len, .array_get, .array_set, .load_indirect, .store_indirect, .copy_indirect => return true,
            .print => |value| if (value.ty.kind != .integer and value.ty.kind != .string and value.ty.kind != .float) return true,
            .call => |value| {
                if (value.args.len != 0 or value.dst != null) return true;
                const callee_execution = functionExecutionById(program, value.callee) orelse return true;
                if (resolveExecution(callee_execution, mode) == .runtime and mode != .hybrid) return true;
            },
            .call_value => return true,
            .ret => |value| if (value.src != null) return true,
        }
    }

    return false;
}

test "detects fallback features for llvm c api lowering" {
    const program = ir.Program{
        .types = &.{},
        .functions = &.{
            .{
                .id = 0,
                .name = "main",
                .execution = .native,
                .param_types = &.{},
                .return_type = .{ .kind = .void },
                .register_count = 1,
                .local_count = 0,
                .local_types = &.{},
                .instructions = &.{
                    .{ .const_function = .{ .dst = 0, .function_id = 1 } },
                    .{ .ret = .{ .src = null } },
                },
            },
            .{
                .id = 1,
                .name = "callback",
                .execution = .native,
                .param_types = &.{},
                .return_type = .{ .kind = .void },
                .register_count = 0,
                .local_count = 0,
                .local_types = &.{},
                .instructions = &.{.{ .ret = .{ .src = null } }},
            },
        },
        .entry_index = 0,
    };

    try std.testing.expect(requiresTextIrFallback(program, .llvm_native));
}

pub fn hostTargetTriple(allocator: std.mem.Allocator) ![]const u8 {
    return switch (builtin.os.tag) {
        .windows => switch (builtin.cpu.arch) {
            .x86_64 => allocator.dupe(u8, if (builtin.abi == .gnu) "x86_64-pc-windows-gnu" else "x86_64-pc-windows-msvc"),
            else => error.UnsupportedTarget,
        },
        .linux => switch (builtin.cpu.arch) {
            .x86_64 => allocator.dupe(u8, "x86_64-pc-linux-gnu"),
            else => error.UnsupportedTarget,
        },
        .macos => switch (builtin.cpu.arch) {
            .aarch64 => allocator.dupe(u8, "arm64-apple-macosx"),
            else => error.UnsupportedTarget,
        },
        else => error.UnsupportedTarget,
    };
}

pub fn ensureParentDir(path: []const u8) !void {
    const maybe_dir = std.fs.path.dirname(path) orelse return;
    try std.fs.cwd().makePath(maybe_dir);
}

pub fn allocPrintZ(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![:0]u8 {
    const rendered = try std.fmt.allocPrint(allocator, fmt, args);
    return allocator.dupeZ(u8, rendered);
}
