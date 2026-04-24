const std = @import("std");
const builtin = @import("builtin");
const ir = @import("kira_ir");
const runtime_abi = @import("kira_runtime_abi");
const backend_api = @import("kira_backend_api");
const build_options = @import("kira_llvm_build_options");
const llvm = @import("llvm_c.zig");
const runtime_symbols = @import("runtime_symbols.zig");
const parent = @import("backend.zig");
const collectCallValueDispatchers = parent.collectCallValueDispatchers;
const freeStringList = parent.freeStringList;
const freeSymbolNames = parent.freeSymbolNames;
const shouldLowerFunction = parent.shouldLowerFunction;
const functionSymbolName = parent.functionSymbolName;
const buildTextExternDecl = parent.buildTextExternDecl;
const countStringConstants = parent.countStringConstants;
const appendTypeDefinitions = parent.appendTypeDefinitions;
const buildCallValueDispatcher = parent.buildCallValueDispatcher;
const buildHybridBridgeWrapper = parent.buildHybridBridgeWrapper;
const llvmValueTypeText = parent.llvmValueTypeText;
const llvmLocalStorageTypeText = parent.llvmLocalStorageTypeText;
const writeLlvmSymbol = parent.writeLlvmSymbol;
const inferRegisterTypes = parent.inferRegisterTypes;
const functionById = parent.functionById;
const findTypeDecl = parent.findTypeDecl;
const typeRefName = parent.typeRefName;
const appendStringGlobals = parent.appendStringGlobals;
const writePrintInstruction = parent.writePrintInstruction;
const writeCallInstruction = parent.writeCallInstruction;
const writeIndirectCallInstruction = parent.writeIndirectCallInstruction;
const writeLlvmStringLiteral = parent.writeLlvmStringLiteral;
const writeLlvmEscapedBytes = parent.writeLlvmEscapedBytes;
const writeLlvmFloatLiteral = parent.writeLlvmFloatLiteral;
const llvmComparePredicate = parent.llvmComparePredicate;
const llvmCompareValueTypeText = parent.llvmCompareValueTypeText;
const llvmIndirectLoadTypeText = parent.llvmIndirectLoadTypeText;
const llvmFieldStoreValuePrefix = parent.llvmFieldStoreValuePrefix;
const fieldIndex = parent.fieldIndex;
const fieldType = parent.fieldType;
const isPointerLikeValueType = parent.isPointerLikeValueType;
const bridgeTagValue = parent.bridgeTagValue;
const integerAbiTypeName = parent.integerAbiTypeName;
const floatAbiTypeName = parent.floatAbiTypeName;
const writeLlvmLabelName = parent.writeLlvmLabelName;
pub fn buildTextLlvmIr(
    allocator: std.mem.Allocator,
    request: backend_api.CompileRequest,
    triple: []const u8,
) ![]u8 {
    const dispatchers = try collectCallValueDispatchers(allocator, request.program.*);
    defer allocator.free(dispatchers);

    var globals = std.array_list.Managed([]const u8).init(allocator);
    defer freeStringList(allocator, &globals);

    var symbol_names = std.AutoHashMapUnmanaged(u32, []const u8){};
    defer freeSymbolNames(allocator, &symbol_names);

    for (request.program.functions) |function_decl| {
        if (!shouldLowerFunction(function_decl.execution, request.mode)) continue;
        const name = try functionSymbolName(allocator, function_decl, request.mode);
        try symbol_names.put(allocator, function_decl.id, name);
    }

    var function_bodies = std.array_list.Managed([]const u8).init(allocator);
    defer freeStringList(allocator, &function_bodies);
    var function_decls = std.array_list.Managed([]const u8).init(allocator);
    defer freeStringList(allocator, &function_decls);

    var string_counter: usize = 0;
    for (request.program.functions) |function_decl| {
        if (!shouldLowerFunction(function_decl.execution, request.mode)) continue;
        if (function_decl.is_extern) {
            try function_decls.append(try buildTextExternDecl(allocator, request, &symbol_names, function_decl));
        } else {
            const body = try buildTextFunctionBody(allocator, request, &symbol_names, &globals, function_decl, string_counter);
            string_counter += countStringConstants(function_decl);
            try function_bodies.append(body);
        }
    }

    if (request.mode == .llvm_native) {
        const entry_decl = request.program.functions[request.program.entry_index];
        if (!shouldLowerFunction(entry_decl.execution, request.mode)) return error.RuntimeEntrypointInNativeBuild;
        const entry_function_name = symbol_names.get(entry_decl.id) orelse return error.MissingFunctionDeclaration;
        const main_body = try buildTextMainBody(allocator, entry_function_name);
        try function_bodies.append(main_body);
    }

    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();

    var writer = &output.writer;
    try writer.print("; ModuleID = \"{s}\"\n", .{request.module_name});
    try writer.print("source_filename = \"{s}\"\n", .{request.module_name});
    try writer.print("target triple = \"{s}\"\n\n", .{triple});
    try appendTypeDefinitions(allocator, writer, request.program);
    try writer.writeAll("%kira.string = type { ptr, i64 }\n\n");
    try writer.writeAll("%kira.bridge.value = type { i8, [7 x i8], i64, i64 }\n\n");

    try writer.writeAll("@kira_bool_true_data = private unnamed_addr constant [5 x i8] c\"true\\00\"\n");
    try writer.writeAll("@kira_bool_true = private unnamed_addr constant %kira.string { ptr getelementptr inbounds ([5 x i8], ptr @kira_bool_true_data, i64 0, i64 0), i64 4 }\n");
    try writer.writeAll("@kira_bool_false_data = private unnamed_addr constant [6 x i8] c\"false\\00\"\n");
    try writer.writeAll("@kira_bool_false = private unnamed_addr constant %kira.string { ptr getelementptr inbounds ([6 x i8], ptr @kira_bool_false_data, i64 0, i64 0), i64 5 }\n\n");

    try writer.writeAll("declare void @\"kira_native_write_i64\"(i64)\n");
    try writer.writeAll("declare void @\"kira_native_write_f64\"(double)\n");
    try writer.writeAll("declare void @\"kira_native_write_string\"(ptr, i64)\n");
    try writer.writeAll("declare void @\"kira_native_write_ptr\"(i64)\n");
    try writer.writeAll("declare void @\"kira_native_write_newline\"()\n");
    try writer.writeAll("declare void @\"kira_native_print_i64\"(i64)\n");
    try writer.writeAll("declare void @\"kira_native_print_f64\"(double)\n");
    try writer.writeAll("declare void @\"kira_native_print_string\"(ptr, i64)\n");
    try writer.writeAll("declare ptr @\"kira_array_alloc\"(i64)\n");
    try writer.writeAll("declare i64 @\"kira_array_len\"(ptr)\n");
    try writer.writeAll("declare void @\"kira_array_store\"(ptr, i64, ptr)\n");
    try writer.writeAll("declare void @\"kira_array_load\"(ptr, i64, ptr)\n");
    try writer.writeAll("declare ptr @\"kira_native_state_alloc\"(i64, i64)\n");
    try writer.writeAll("declare ptr @\"kira_native_state_payload\"(ptr)\n");
    try writer.writeAll("declare ptr @\"kira_native_state_recover\"(ptr, i64)\n");
    try writer.writeAll("declare ptr @malloc(i64)\n");
    if (request.mode == .hybrid) {
        try writer.writeAll("declare void @\"kira_hybrid_call_runtime\"(i32, ptr, i32, ptr)\n");
    }
    for (function_decls.items) |decl| {
        try writer.writeAll(decl);
        try writer.writeByte('\n');
    }
    try writer.writeByte('\n');

    if (function_bodies.items.len > 0) try writer.writeByte('\n');

    for (globals.items) |global_def| {
        try writer.writeAll(global_def);
        try writer.writeByte('\n');
    }

    if (globals.items.len > 0 and function_bodies.items.len > 0) {
        try writer.writeByte('\n');
    }

    for (function_bodies.items) |body| {
        try writer.writeAll(body);
        try writer.writeByte('\n');
    }

    for (dispatchers) |dispatcher| {
        try writer.writeAll(try buildCallValueDispatcher(allocator, request, &symbol_names, dispatcher));
        try writer.writeByte('\n');
    }

    if (request.mode == .hybrid) {
        for (request.program.functions) |function_decl| {
            if (!shouldLowerFunction(function_decl.execution, request.mode) or function_decl.is_extern) continue;
            try writer.writeAll(try buildHybridBridgeWrapper(allocator, &symbol_names, function_decl));
            try writer.writeByte('\n');
        }
    }

    return output.toOwnedSlice();
}

pub fn buildTextFunctionBody(
    allocator: std.mem.Allocator,
    request: backend_api.CompileRequest,
    symbol_names: *const std.AutoHashMapUnmanaged(u32, []const u8),
    globals: *std.array_list.Managed([]const u8),
    function_decl: ir.Function,
    string_counter: usize,
) ![]const u8 {
    var body: std.Io.Writer.Allocating = .init(allocator);
    errdefer body.deinit();

    var writer = &body.writer;
    const function_name = symbol_names.get(function_decl.id) orelse return error.MissingFunctionDeclaration;
    try writer.writeAll("define ");
    try writer.writeAll(llvmValueTypeText(function_decl.return_type));
    try writer.writeByte(' ');
    try writeLlvmSymbol(writer, function_name);
    try writer.writeByte('(');
    for (function_decl.param_types, 0..) |param_type, index| {
        if (index != 0) try writer.writeAll(", ");
        try writer.writeAll(llvmValueTypeText(param_type));
        try writer.writeAll(" %arg");
        try writer.print("{d}", .{index});
    }
    try writer.writeAll(") {\nentry:\n");

    const register_types = try inferRegisterTypes(allocator, request.program.*, function_decl);
    defer allocator.free(register_types);

    const string_state = try allocator.alloc(usize, 1);
    defer allocator.free(string_state);
    string_state[0] = string_counter;
    var temp_counter: usize = 0;
    var block_terminated = false;

    for (function_decl.local_types, 0..) |local_type, index| {
        const storage_type = try llvmLocalStorageTypeText(allocator, request.program, local_type);
        try writer.writeAll("  %local");
        try writer.print("{d}", .{index});
        try writer.writeAll(" = alloca ");
        try writer.writeAll(storage_type);
        try writer.writeAll("\n");
        if (local_type.kind == .ffi_struct) {
            const struct_type_name = typeRefName(local_type.name orelse return error.UnsupportedExecutableFeature);
            try writer.print("  %local.size.ptr.{d} = getelementptr inbounds {s}, ptr null, i32 1\n", .{ index, struct_type_name });
            try writer.print("  %local.size.{d} = ptrtoint ptr %local.size.ptr.{d} to i64\n", .{ index, index });
            try writer.print("  %local.heap.{d} = call ptr @malloc(i64 %local.size.{d})\n", .{ index, index });
            try writer.print("  store {s} zeroinitializer, ptr %local.heap.{d}\n", .{ struct_type_name, index });
            try writer.print("  %local.heap.int.{d} = ptrtoint ptr %local.heap.{d} to i64\n", .{ index, index });
            try writer.print("  store i64 %local.heap.int.{d}, ptr %local{d}\n", .{ index, index });
        }
    }
    for (function_decl.param_types, 0..) |param_type, index| {
        try writer.writeAll("  store ");
        try writer.writeAll(llvmValueTypeText(param_type));
        try writer.writeAll(" %arg");
        try writer.print("{d}", .{index});
        try writer.writeAll(", ptr %local");
        try writer.print("{d}\n", .{index});
    }

    for (function_decl.instructions) |instruction| {
        switch (instruction) {
            .const_int => |value| {
                try writer.writeAll("  %r");
                try writer.print("{d}", .{value.dst});
                try writer.writeAll(" = add i64 0, ");
                try writer.print("{d}\n", .{value.value});
            },
            .const_float => |value| {
                try writer.writeAll("  %r");
                try writer.print("{d}", .{value.dst});
                try writer.writeAll(" = fadd double 0.0, ");
                try writeLlvmFloatLiteral(writer, value.value);
                try writer.writeAll("\n");
            },
            .const_string => |value| {
                const string_index = string_state[0];
                string_state[0] += 1;
                try appendStringGlobals(allocator, globals, string_index, value.value);

                try writer.writeAll("  %r");
                try writer.print("{d}", .{value.dst});
                try writer.writeAll(" = load %kira.string, ptr @kira_str_");
                try writer.print("{d}", .{string_index});
                try writer.writeAll("\n");
            },
            .const_bool => |value| {
                try writer.writeAll("  %r");
                try writer.print("{d}", .{value.dst});
                try writer.writeAll(" = add i1 0, ");
                try writer.writeAll(if (value.value) "1\n" else "0\n");
            },
            .const_null_ptr => |value| {
                try writer.writeAll("  %r");
                try writer.print("{d}", .{value.dst});
                try writer.writeAll(" = add i64 0, 0\n");
            },
            .alloc_struct => |value| {
                const struct_type_name = typeRefName(value.type_name);
                try writer.print("  %alloc.size.ptr.{d} = getelementptr inbounds {s}, ptr null, i32 1\n", .{ value.dst, struct_type_name });
                try writer.print("  %alloc.size.{d} = ptrtoint ptr %alloc.size.ptr.{d} to i64\n", .{ value.dst, value.dst });
                try writer.print("  %alloc.ptr.{d} = call ptr @malloc(i64 %alloc.size.{d})\n", .{ value.dst, value.dst });
                try writer.print("  store {s} zeroinitializer, ptr %alloc.ptr.{d}\n", .{ struct_type_name, value.dst });
                try writer.writeAll("  %r");
                try writer.print("{d}", .{value.dst});
                try writer.writeAll(" = ptrtoint ptr %alloc.ptr.");
                try writer.print("{d}", .{value.dst});
                try writer.writeAll(" to i64\n");
            },
            .alloc_native_state => |value| {
                const type_decl = findTypeDecl(request.program, value.type_name) orelse return error.UnsupportedExecutableFeature;
                const struct_type_name = typeRefName(value.type_name);
                try writer.print("  %native.state.size.ptr.{d} = getelementptr inbounds [{d} x %kira.bridge.value], ptr null, i32 1\n", .{
                    value.dst,
                    type_decl.fields.len,
                });
                try writer.print("  %native.state.size.{d} = ptrtoint ptr %native.state.size.ptr.{d} to i64\n", .{ value.dst, value.dst });
                try writer.print("  %native.state.box.{d} = call ptr @\"kira_native_state_alloc\"(i64 {d}, i64 %native.state.size.{d})\n", .{
                    value.dst,
                    value.type_id,
                    value.dst,
                });
                try writer.print("  %native.state.payload.{d} = call ptr @\"kira_native_state_payload\"(ptr %native.state.box.{d})\n", .{ value.dst, value.dst });
                try writer.print("  %native.state.src.{d} = inttoptr i64 %r{d} to ptr\n", .{ value.dst, value.src });
                for (type_decl.fields, 0..) |field_decl, index| {
                    const field_abi = try llvmIndirectLoadTypeText(allocator, request.program, field_decl.ty);
                    try writer.print("  %native.state.src.field.ptr.{d}.{d} = getelementptr inbounds {s}, ptr %native.state.src.{d}, i32 0, i32 {d}\n", .{
                        value.dst, index, struct_type_name, value.dst, index,
                    });
                    try writer.print("  %native.state.slot.ptr.{d}.{d} = getelementptr inbounds %kira.bridge.value, ptr %native.state.payload.{d}, i64 {d}\n", .{
                        value.dst, index, value.dst, index,
                    });
                    try writer.print("  %native.state.pack.{d}.{d}.0 = insertvalue %kira.bridge.value zeroinitializer, i8 {d}, 0\n", .{
                        value.dst, index, bridgeTagValue(field_decl.ty),
                    });
                    switch (field_decl.ty.kind) {
                        .integer => {
                            try writer.print("  %native.state.load.int.{d}.{d} = load {s}, ptr %native.state.src.field.ptr.{d}.{d}\n", .{
                                value.dst, index, field_abi, value.dst, index,
                            });
                            if (std.mem.eql(u8, field_abi, "i64")) {
                                try writer.print("  %native.state.pack.{d}.{d} = insertvalue %kira.bridge.value %native.state.pack.{d}.{d}.0, i64 %native.state.load.int.{d}.{d}, 2\n", .{
                                    value.dst, index, value.dst, index, value.dst, index,
                                });
                            } else {
                                try writer.print("  %native.state.load.int.ext.{d}.{d} = sext {s} %native.state.load.int.{d}.{d} to i64\n", .{
                                    value.dst, index, field_abi, value.dst, index,
                                });
                                try writer.print("  %native.state.pack.{d}.{d} = insertvalue %kira.bridge.value %native.state.pack.{d}.{d}.0, i64 %native.state.load.int.ext.{d}.{d}, 2\n", .{
                                    value.dst, index, value.dst, index, value.dst, index,
                                });
                            }
                        },
                        .float => {
                            try writer.print("  %native.state.load.float.{d}.{d} = load {s}, ptr %native.state.src.field.ptr.{d}.{d}\n", .{
                                value.dst, index, field_abi, value.dst, index,
                            });
                            if (std.mem.eql(u8, field_abi, "float")) {
                                try writer.print("  %native.state.load.float64.{d}.{d} = fpext float %native.state.load.float.{d}.{d} to double\n", .{
                                    value.dst, index, value.dst, index,
                                });
                                try writer.print("  %native.state.load.float.bits.{d}.{d} = bitcast double %native.state.load.float64.{d}.{d} to i64\n", .{
                                    value.dst, index, value.dst, index,
                                });
                            } else {
                                try writer.print("  %native.state.load.float.bits.{d}.{d} = bitcast double %native.state.load.float.{d}.{d} to i64\n", .{
                                    value.dst, index, value.dst, index,
                                });
                            }
                            try writer.print("  %native.state.pack.{d}.{d} = insertvalue %kira.bridge.value %native.state.pack.{d}.{d}.0, i64 %native.state.load.float.bits.{d}.{d}, 2\n", .{
                                value.dst, index, value.dst, index, value.dst, index,
                            });
                        },
                        .boolean => {
                            try writer.print("  %native.state.load.bool.{d}.{d} = load i8, ptr %native.state.src.field.ptr.{d}.{d}\n", .{
                                value.dst, index, value.dst, index,
                            });
                            try writer.print("  %native.state.load.bool.word.{d}.{d} = zext i8 %native.state.load.bool.{d}.{d} to i64\n", .{
                                value.dst, index, value.dst, index,
                            });
                            try writer.print("  %native.state.pack.{d}.{d} = insertvalue %kira.bridge.value %native.state.pack.{d}.{d}.0, i64 %native.state.load.bool.word.{d}.{d}, 2\n", .{
                                value.dst, index, value.dst, index, value.dst, index,
                            });
                        },
                        .raw_ptr, .array => {
                            try writer.print("  %native.state.load.ptr.{d}.{d} = load ptr, ptr %native.state.src.field.ptr.{d}.{d}\n", .{
                                value.dst, index, value.dst, index,
                            });
                            try writer.print("  %native.state.load.ptrint.{d}.{d} = ptrtoint ptr %native.state.load.ptr.{d}.{d} to i64\n", .{
                                value.dst, index, value.dst, index,
                            });
                            try writer.print("  %native.state.pack.{d}.{d} = insertvalue %kira.bridge.value %native.state.pack.{d}.{d}.0, i64 %native.state.load.ptrint.{d}.{d}, 2\n", .{
                                value.dst, index, value.dst, index, value.dst, index,
                            });
                        },
                        .string => {
                            try writer.print("  %native.state.load.str.{d}.{d} = load %kira.string, ptr %native.state.src.field.ptr.{d}.{d}\n", .{
                                value.dst, index, value.dst, index,
                            });
                            try writer.print("  %native.state.load.str.ptr.{d}.{d} = extractvalue %kira.string %native.state.load.str.{d}.{d}, 0\n", .{
                                value.dst, index, value.dst, index,
                            });
                            try writer.print("  %native.state.load.str.ptrint.{d}.{d} = ptrtoint ptr %native.state.load.str.ptr.{d}.{d} to i64\n", .{
                                value.dst, index, value.dst, index,
                            });
                            try writer.print("  %native.state.load.str.len.{d}.{d} = extractvalue %kira.string %native.state.load.str.{d}.{d}, 1\n", .{
                                value.dst, index, value.dst, index,
                            });
                            try writer.print("  %native.state.pack.{d}.{d}.1 = insertvalue %kira.bridge.value %native.state.pack.{d}.{d}.0, i64 %native.state.load.str.ptrint.{d}.{d}, 2\n", .{
                                value.dst, index, value.dst, index, value.dst, index,
                            });
                            try writer.print("  %native.state.pack.{d}.{d} = insertvalue %kira.bridge.value %native.state.pack.{d}.{d}.1, i64 %native.state.load.str.len.{d}.{d}, 3\n", .{
                                value.dst, index, value.dst, index, value.dst, index,
                            });
                        },
                        .ffi_struct => {
                            const field_struct_name = typeRefName(field_decl.ty.name orelse return error.UnsupportedExecutableFeature);
                            try writer.print("  %native.state.load.struct.{d}.{d} = load {s}, ptr %native.state.src.field.ptr.{d}.{d}\n", .{
                                value.dst, index, field_struct_name, value.dst, index,
                            });
                            try writer.print("  %native.state.load.struct.size.ptr.{d}.{d} = getelementptr inbounds {s}, ptr null, i32 1\n", .{
                                value.dst, index, field_struct_name,
                            });
                            try writer.print("  %native.state.load.struct.size.{d}.{d} = ptrtoint ptr %native.state.load.struct.size.ptr.{d}.{d} to i64\n", .{
                                value.dst, index, value.dst, index,
                            });
                            try writer.print("  %native.state.load.struct.copy.{d}.{d} = call ptr @malloc(i64 %native.state.load.struct.size.{d}.{d})\n", .{
                                value.dst, index, value.dst, index,
                            });
                            try writer.print("  store {s} %native.state.load.struct.{d}.{d}, ptr %native.state.load.struct.copy.{d}.{d}\n", .{
                                field_struct_name, value.dst, index, value.dst, index,
                            });
                            try writer.print("  %native.state.load.struct.ptrint.{d}.{d} = ptrtoint ptr %native.state.load.struct.copy.{d}.{d} to i64\n", .{
                                value.dst, index, value.dst, index,
                            });
                            try writer.print("  %native.state.pack.{d}.{d} = insertvalue %kira.bridge.value %native.state.pack.{d}.{d}.0, i64 %native.state.load.struct.ptrint.{d}.{d}, 2\n", .{
                                value.dst, index, value.dst, index, value.dst, index,
                            });
                        },
                        .void => return error.UnsupportedExecutableFeature,
                    }
                    try writer.print("  store %kira.bridge.value %native.state.pack.{d}.{d}, ptr %native.state.slot.ptr.{d}.{d}\n", .{
                        value.dst, index, value.dst, index,
                    });
                }
                try writer.writeAll("  %r");
                try writer.print("{d}", .{value.dst});
                try writer.writeAll(" = ptrtoint ptr %native.state.box.");
                try writer.print("{d}", .{value.dst});
                try writer.writeAll(" to i64\n");
            },
            .alloc_array => |value| {
                try writer.print("  %alloc.array.ptr.{d} = call ptr @\"kira_array_alloc\"(i64 %r{d})\n", .{ value.dst, value.len });
                try writer.print("  %r{d} = ptrtoint ptr %alloc.array.ptr.{d} to i64\n", .{ value.dst, value.dst });
            },
            .const_function => |value| {
                try writer.writeAll("  %r");
                try writer.print("{d}", .{value.dst});
                switch (value.representation) {
                    .callable_value => {
                        try writer.writeAll(" = add i64 0, ");
                        try writer.print("{d}\n", .{value.function_id});
                    },
                    .native_callback => {
                        const callee_decl = functionById(request.program.*, value.function_id) orelse return error.UnknownFunction;
                        const callee_name = symbol_names.get(callee_decl.id) orelse return error.MissingFunctionDeclaration;
                        try writer.writeAll(" = ptrtoint ptr ");
                        try writeLlvmSymbol(writer, callee_name);
                        try writer.writeAll(" to i64\n");
                    },
                }
            },
            .add => |value| {
                const arithmetic_type = register_types[value.lhs];
                try writer.writeAll("  %r");
                try writer.print("{d}", .{value.dst});
                try writer.writeAll(if (arithmetic_type.kind == .float) " = fadd " else " = add ");
                try writer.writeAll(llvmValueTypeText(arithmetic_type));
                try writer.writeAll(" %r");
                try writer.print("{d}", .{value.lhs});
                try writer.writeAll(", %r");
                try writer.print("{d}\n", .{value.rhs});
            },
            .subtract => |value| {
                const arithmetic_type = register_types[value.lhs];
                try writer.writeAll("  %r");
                try writer.print("{d}", .{value.dst});
                try writer.writeAll(if (arithmetic_type.kind == .float) " = fsub " else " = sub ");
                try writer.writeAll(llvmValueTypeText(arithmetic_type));
                try writer.writeAll(" %r");
                try writer.print("{d}", .{value.lhs});
                try writer.writeAll(", %r");
                try writer.print("{d}\n", .{value.rhs});
            },
            .multiply => |value| {
                const arithmetic_type = register_types[value.lhs];
                try writer.writeAll("  %r");
                try writer.print("{d}", .{value.dst});
                try writer.writeAll(if (arithmetic_type.kind == .float) " = fmul " else " = mul ");
                try writer.writeAll(llvmValueTypeText(arithmetic_type));
                try writer.writeAll(" %r");
                try writer.print("{d}", .{value.lhs});
                try writer.writeAll(", %r");
                try writer.print("{d}\n", .{value.rhs});
            },
            .divide => |value| {
                const arithmetic_type = register_types[value.lhs];
                try writer.writeAll("  %r");
                try writer.print("{d}", .{value.dst});
                try writer.writeAll(if (arithmetic_type.kind == .float) " = fdiv " else " = sdiv ");
                try writer.writeAll(llvmValueTypeText(arithmetic_type));
                try writer.writeAll(" %r");
                try writer.print("{d}", .{value.lhs});
                try writer.writeAll(", %r");
                try writer.print("{d}\n", .{value.rhs});
            },
            .modulo => |value| {
                const arithmetic_type = register_types[value.lhs];
                try writer.writeAll("  %r");
                try writer.print("{d}", .{value.dst});
                try writer.writeAll(if (arithmetic_type.kind == .float) " = frem " else " = srem ");
                try writer.writeAll(llvmValueTypeText(arithmetic_type));
                try writer.writeAll(" %r");
                try writer.print("{d}", .{value.lhs});
                try writer.writeAll(", %r");
                try writer.print("{d}\n", .{value.rhs});
            },
            .compare => |value| {
                const operand_type = register_types[value.lhs];
                try writer.writeAll("  %r");
                try writer.print("{d}", .{value.dst});
                try writer.writeAll(if (operand_type.kind == .float) " = fcmp " else " = icmp ");
                try writer.writeAll(try llvmComparePredicate(operand_type, value.op));
                try writer.writeByte(' ');
                try writer.writeAll(llvmCompareValueTypeText(operand_type));
                try writer.writeAll(" %r");
                try writer.print("{d}", .{value.lhs});
                try writer.writeAll(", %r");
                try writer.print("{d}\n", .{value.rhs});
            },
            .unary => |value| switch (value.op) {
                .negate => {
                    const unary_type = register_types[value.src];
                    try writer.writeAll("  %r");
                    try writer.print("{d}", .{value.dst});
                    if (unary_type.kind == .float) {
                        try writer.writeAll(" = fsub double 0.0, %r");
                        try writer.print("{d}\n", .{value.src});
                    } else {
                        try writer.writeAll(" = sub i64 0, %r");
                        try writer.print("{d}\n", .{value.src});
                    }
                },
                .not => {
                    try writer.writeAll("  %r");
                    try writer.print("{d}", .{value.dst});
                    try writer.writeAll(" = xor i1 %r");
                    try writer.print("{d}", .{value.src});
                    try writer.writeAll(", true\n");
                },
            },
            .store_local => |value| {
                try writer.writeAll("  store ");
                try writer.writeAll(llvmValueTypeText(register_types[value.src]));
                try writer.writeAll(" %r");
                try writer.print("{d}", .{value.src});
                try writer.writeAll(", ptr %local");
                try writer.print("{d}\n", .{value.local});
            },
            .load_local => |value| {
                try writer.writeAll("  %r");
                try writer.print("{d}", .{value.dst});
                if (function_decl.local_types[value.local].kind == .ffi_struct) {
                    try writer.writeAll(" = load i64, ptr %local");
                    try writer.print("{d}\n", .{value.local});
                } else {
                    try writer.writeAll(" = load ");
                    try writer.writeAll(llvmValueTypeText(function_decl.local_types[value.local]));
                    try writer.writeAll(", ptr %local");
                    try writer.print("{d}\n", .{value.local});
                }
            },
            .subobject_ptr => |value| {
                const base_type_name = register_types[value.base].name orelse return error.UnsupportedExecutableFeature;
                const struct_type_name = typeRefName(base_type_name);
                try writer.print("  %subobject.base.{d} = inttoptr i64 %r{d} to ptr\n", .{ value.dst, value.base });
                try writer.print("  %subobject.ptr.{d} = getelementptr inbounds {s}, ptr %subobject.base.{d}, i32 0, i32 {d}\n", .{ value.dst, struct_type_name, value.dst, value.offset });
                try writer.print("  %r{d} = ptrtoint ptr %subobject.ptr.{d} to i64\n", .{ value.dst, value.dst });
            },
            .field_ptr => |value| {
                const struct_type_name = typeRefName(value.base_type_name);
                try writer.print("  %field.base.{d} = inttoptr i64 %r{d} to ptr\n", .{ value.dst, value.base });
                try writer.writeAll("  %field.ptr.");
                try writer.print("{d}", .{value.dst});
                try writer.print(" = getelementptr inbounds {s}, ptr %field.base.{d}, i32 0, i32 {d}\n", .{ struct_type_name, value.dst, value.field_index });
                try writer.writeAll("  %r");
                try writer.print("{d}", .{value.dst});
                try writer.writeAll(" = ptrtoint ptr %field.ptr.");
                try writer.print("{d}", .{value.dst});
                try writer.writeAll(" to i64\n");
            },
            .recover_native_state => |value| {
                try writer.print("  %native.recover.state.{d} = inttoptr i64 %r{d} to ptr\n", .{ value.dst, value.state });
                try writer.print("  %native.recover.payload.{d} = call ptr @\"kira_native_state_recover\"(ptr %native.recover.state.{d}, i64 {d})\n", .{
                    value.dst,
                    value.dst,
                    value.type_id,
                });
                try writer.print("  %r{d} = ptrtoint ptr %native.recover.payload.{d} to i64\n", .{ value.dst, value.dst });
            },
            .native_state_field_get => |value| {
                const temp_index = temp_counter;
                temp_counter += 1;
                try writer.print("  %native.state.get.ptr.{d} = inttoptr i64 %r{d} to ptr\n", .{ value.dst, value.state });
                try writer.print("  %native.state.get.slot.{d} = getelementptr inbounds %kira.bridge.value, ptr %native.state.get.ptr.{d}, i64 {d}\n", .{
                    value.dst,
                    value.dst,
                    value.field_index,
                });
                try writer.print("  %native.state.get.val.{d} = load %kira.bridge.value, ptr %native.state.get.slot.{d}\n", .{ temp_index, value.dst });
                switch (value.field_ty.kind) {
                    .integer, .raw_ptr, .ffi_struct, .array => {
                        try writer.writeAll("  %r");
                        try writer.print("{d}", .{value.dst});
                        try writer.print(" = extractvalue %kira.bridge.value %native.state.get.val.{d}, 2\n", .{temp_index});
                    },
                    .float => {
                        try writer.print("  %native.state.get.bits.{d} = extractvalue %kira.bridge.value %native.state.get.val.{d}, 2\n", .{ temp_index, temp_index });
                        if (value.field_ty.name != null and std.mem.eql(u8, value.field_ty.name.?, "F32")) {
                            try writer.print("  %native.state.get.float64.{d} = bitcast i64 %native.state.get.bits.{d} to double\n", .{ temp_index, temp_index });
                            try writer.writeAll("  %r");
                            try writer.print("{d}", .{value.dst});
                            try writer.print(" = fptrunc double %native.state.get.float64.{d} to float\n", .{temp_index});
                        } else {
                            try writer.writeAll("  %r");
                            try writer.print("{d}", .{value.dst});
                            try writer.print(" = bitcast i64 %native.state.get.bits.{d} to double\n", .{temp_index});
                        }
                    },
                    .boolean => {
                        try writer.print("  %native.state.get.word.{d} = extractvalue %kira.bridge.value %native.state.get.val.{d}, 2\n", .{ temp_index, temp_index });
                        try writer.writeAll("  %r");
                        try writer.print("{d}", .{value.dst});
                        try writer.print(" = trunc i64 %native.state.get.word.{d} to i1\n", .{temp_index});
                    },
                    .string => {
                        try writer.print("  %native.state.get.ptrint.{d} = extractvalue %kira.bridge.value %native.state.get.val.{d}, 2\n", .{ temp_index, temp_index });
                        try writer.print("  %native.state.get.len.{d} = extractvalue %kira.bridge.value %native.state.get.val.{d}, 3\n", .{ temp_index, temp_index });
                        try writer.print("  %native.state.get.ptrcast.{d} = inttoptr i64 %native.state.get.ptrint.{d} to ptr\n", .{ temp_index, temp_index });
                        try writer.writeAll("  %r");
                        try writer.print("{d}", .{value.dst});
                        try writer.print(".0 = insertvalue %kira.string zeroinitializer, ptr %native.state.get.ptrcast.{d}, 0\n", .{temp_index});
                        try writer.writeAll("  %r");
                        try writer.print("{d}", .{value.dst});
                        try writer.print(" = insertvalue %kira.string %r{d}.0, i64 %native.state.get.len.{d}, 1\n", .{ value.dst, temp_index });
                    },
                    .void => return error.UnsupportedExecutableFeature,
                }
            },
            .native_state_field_set => |value| {
                const temp_index = temp_counter;
                temp_counter += 1;
                try writer.print("  %native.state.set.ptr.{d} = inttoptr i64 %r{d} to ptr\n", .{ value.src, value.state });
                try writer.print("  %native.state.set.slot.{d} = getelementptr inbounds %kira.bridge.value, ptr %native.state.set.ptr.{d}, i64 {d}\n", .{
                    value.src,
                    value.src,
                    value.field_index,
                });
                try writer.print("  %native.state.set.pack.{d}.0 = insertvalue %kira.bridge.value zeroinitializer, i8 {d}, 0\n", .{
                    temp_index,
                    bridgeTagValue(register_types[value.src]),
                });
                switch (register_types[value.src].kind) {
                    .integer, .raw_ptr, .array => {
                        try writer.print("  %native.state.set.pack.{d} = insertvalue %kira.bridge.value %native.state.set.pack.{d}.0, i64 %r{d}, 2\n", .{
                            temp_index, temp_index, value.src,
                        });
                    },
                    .ffi_struct => {
                        const field_struct_name = typeRefName(register_types[value.src].name orelse return error.UnsupportedExecutableFeature);
                        try writer.print("  %native.state.set.struct.src.{d} = inttoptr i64 %r{d} to ptr\n", .{ temp_index, value.src });
                        try writer.print("  %native.state.set.struct.value.{d} = load {s}, ptr %native.state.set.struct.src.{d}\n", .{
                            temp_index, field_struct_name, temp_index,
                        });
                        try writer.print("  %native.state.set.struct.size.ptr.{d} = getelementptr inbounds {s}, ptr null, i32 1\n", .{
                            temp_index, field_struct_name,
                        });
                        try writer.print("  %native.state.set.struct.size.{d} = ptrtoint ptr %native.state.set.struct.size.ptr.{d} to i64\n", .{
                            temp_index, temp_index,
                        });
                        try writer.print("  %native.state.set.struct.copy.{d} = call ptr @malloc(i64 %native.state.set.struct.size.{d})\n", .{
                            temp_index, temp_index,
                        });
                        try writer.print("  store {s} %native.state.set.struct.value.{d}, ptr %native.state.set.struct.copy.{d}\n", .{
                            field_struct_name, temp_index, temp_index,
                        });
                        try writer.print("  %native.state.set.struct.ptrint.{d} = ptrtoint ptr %native.state.set.struct.copy.{d} to i64\n", .{
                            temp_index, temp_index,
                        });
                        try writer.print("  %native.state.set.pack.{d} = insertvalue %kira.bridge.value %native.state.set.pack.{d}.0, i64 %native.state.set.struct.ptrint.{d}, 2\n", .{
                            temp_index, temp_index, temp_index,
                        });
                    },
                    .float => {
                        if (register_types[value.src].name != null and std.mem.eql(u8, register_types[value.src].name.?, "F32")) {
                            try writer.print("  %native.state.set.float.ext.{d} = fpext float %r{d} to double\n", .{ temp_index, value.src });
                            try writer.print("  %native.state.set.float.bits.{d} = bitcast double %native.state.set.float.ext.{d} to i64\n", .{ temp_index, temp_index });
                        } else {
                            try writer.print("  %native.state.set.float.bits.{d} = bitcast double %r{d} to i64\n", .{ temp_index, value.src });
                        }
                        try writer.print("  %native.state.set.pack.{d} = insertvalue %kira.bridge.value %native.state.set.pack.{d}.0, i64 %native.state.set.float.bits.{d}, 2\n", .{
                            temp_index, temp_index, temp_index,
                        });
                    },
                    .boolean => {
                        try writer.print("  %native.state.set.bool.{d} = zext i1 %r{d} to i64\n", .{ temp_index, value.src });
                        try writer.print("  %native.state.set.pack.{d} = insertvalue %kira.bridge.value %native.state.set.pack.{d}.0, i64 %native.state.set.bool.{d}, 2\n", .{
                            temp_index, temp_index, temp_index,
                        });
                    },
                    .string => {
                        try writer.print("  %native.state.set.str.ptr.{d} = extractvalue %kira.string %r{d}, 0\n", .{ temp_index, value.src });
                        try writer.print("  %native.state.set.str.ptrint.{d} = ptrtoint ptr %native.state.set.str.ptr.{d} to i64\n", .{ temp_index, temp_index });
                        try writer.print("  %native.state.set.str.len.{d} = extractvalue %kira.string %r{d}, 1\n", .{ temp_index, value.src });
                        try writer.print("  %native.state.set.pack.{d}.1 = insertvalue %kira.bridge.value %native.state.set.pack.{d}.0, i64 %native.state.set.str.ptrint.{d}, 2\n", .{
                            temp_index, temp_index, temp_index,
                        });
                        try writer.print("  %native.state.set.pack.{d} = insertvalue %kira.bridge.value %native.state.set.pack.{d}.1, i64 %native.state.set.str.len.{d}, 3\n", .{
                            temp_index, temp_index, temp_index,
                        });
                    },
                    .void => return error.UnsupportedExecutableFeature,
                }
                try writer.print("  store %kira.bridge.value %native.state.set.pack.{d}, ptr %native.state.set.slot.{d}\n", .{
                    temp_index,
                    value.src,
                });
            },
            .array_len => |value| {
                try writer.print("  %array.ptr.{d} = inttoptr i64 %r{d} to ptr\n", .{ value.dst, value.array });
                try writer.print("  %r{d} = call i64 @\"kira_array_len\"(ptr %array.ptr.{d})\n", .{ value.dst, value.dst });
            },
            .array_get => |value| {
                const temp_index = temp_counter;
                temp_counter += 1;
                try writer.print("  %array.get.ptr.{d} = inttoptr i64 %r{d} to ptr\n", .{ value.dst, value.array });
                try writer.print("  %array.get.val.ptr.{d} = alloca %kira.bridge.value\n", .{temp_index});
                try writer.print("  call void @\"kira_array_load\"(ptr %array.get.ptr.{d}, i64 %r{d}, ptr %array.get.val.ptr.{d})\n", .{
                    value.dst, value.index, temp_index,
                });
                try writer.print("  %array.get.val.{d} = load %kira.bridge.value, ptr %array.get.val.ptr.{d}\n", .{ temp_index, temp_index });
                switch (value.ty.kind) {
                    .integer, .raw_ptr, .ffi_struct, .array => {
                        try writer.writeAll("  %r");
                        try writer.print("{d}", .{value.dst});
                        try writer.print(" = extractvalue %kira.bridge.value %array.get.val.{d}, 2\n", .{temp_index});
                    },
                    .float => {
                        try writer.print("  %array.get.bits.{d} = extractvalue %kira.bridge.value %array.get.val.{d}, 2\n", .{ temp_index, temp_index });
                        if (value.ty.name != null and std.mem.eql(u8, value.ty.name.?, "F32")) {
                            try writer.print("  %array.get.float64.{d} = bitcast i64 %array.get.bits.{d} to double\n", .{ temp_index, temp_index });
                            try writer.writeAll("  %r");
                            try writer.print("{d}", .{value.dst});
                            try writer.print(" = fptrunc double %array.get.float64.{d} to float\n", .{temp_index});
                        } else {
                            try writer.writeAll("  %r");
                            try writer.print("{d}", .{value.dst});
                            try writer.print(" = bitcast i64 %array.get.bits.{d} to double\n", .{temp_index});
                        }
                    },
                    .boolean => {
                        try writer.print("  %array.get.word.{d} = extractvalue %kira.bridge.value %array.get.val.{d}, 2\n", .{ temp_index, temp_index });
                        try writer.writeAll("  %r");
                        try writer.print("{d}", .{value.dst});
                        try writer.print(" = trunc i64 %array.get.word.{d} to i1\n", .{temp_index});
                    },
                    .string => {
                        try writer.print("  %array.get.ptrint.{d} = extractvalue %kira.bridge.value %array.get.val.{d}, 2\n", .{ temp_index, temp_index });
                        try writer.print("  %array.get.len.{d} = extractvalue %kira.bridge.value %array.get.val.{d}, 3\n", .{ temp_index, temp_index });
                        try writer.print("  %array.get.ptrcast.{d} = inttoptr i64 %array.get.ptrint.{d} to ptr\n", .{ temp_index, temp_index });
                        try writer.writeAll("  %r");
                        try writer.print("{d}", .{value.dst});
                        try writer.print(".0 = insertvalue %kira.string zeroinitializer, ptr %array.get.ptrcast.{d}, 0\n", .{temp_index});
                        try writer.writeAll("  %r");
                        try writer.print("{d}", .{value.dst});
                        try writer.print(" = insertvalue %kira.string %r{d}.0, i64 %array.get.len.{d}, 1\n", .{ value.dst, temp_index });
                    },
                    .void => return error.UnsupportedExecutableFeature,
                }
            },
            .array_set => |value| {
                const temp_index = temp_counter;
                temp_counter += 1;
                try writer.print("  %array.set.ptr.{d} = inttoptr i64 %r{d} to ptr\n", .{ value.src, value.array });
                try writer.print("  %array.set.pack.{d}.0 = insertvalue %kira.bridge.value zeroinitializer, i8 {d}, 0\n", .{
                    temp_index, bridgeTagValue(register_types[value.src]),
                });
                switch (register_types[value.src].kind) {
                    .integer, .raw_ptr, .ffi_struct, .array => {
                        try writer.print("  %array.set.pack.{d} = insertvalue %kira.bridge.value %array.set.pack.{d}.0, i64 %r{d}, 2\n", .{
                            temp_index, temp_index, value.src,
                        });
                    },
                    .float => {
                        if (register_types[value.src].name != null and std.mem.eql(u8, register_types[value.src].name.?, "F32")) {
                            try writer.print("  %array.set.float.ext.{d} = fpext float %r{d} to double\n", .{ temp_index, value.src });
                            try writer.print("  %array.set.float.bits.{d} = bitcast double %array.set.float.ext.{d} to i64\n", .{ temp_index, temp_index });
                        } else {
                            try writer.print("  %array.set.float.bits.{d} = bitcast double %r{d} to i64\n", .{ temp_index, value.src });
                        }
                        try writer.print("  %array.set.pack.{d} = insertvalue %kira.bridge.value %array.set.pack.{d}.0, i64 %array.set.float.bits.{d}, 2\n", .{
                            temp_index, temp_index, temp_index,
                        });
                    },
                    .boolean => {
                        try writer.print("  %array.set.bool.{d} = zext i1 %r{d} to i64\n", .{ temp_index, value.src });
                        try writer.print("  %array.set.pack.{d} = insertvalue %kira.bridge.value %array.set.pack.{d}.0, i64 %array.set.bool.{d}, 2\n", .{
                            temp_index, temp_index, temp_index,
                        });
                    },
                    .string => {
                        try writer.print("  %array.set.str.ptr.{d} = extractvalue %kira.string %r{d}, 0\n", .{ temp_index, value.src });
                        try writer.print("  %array.set.str.ptrint.{d} = ptrtoint ptr %array.set.str.ptr.{d} to i64\n", .{ temp_index, temp_index });
                        try writer.print("  %array.set.str.len.{d} = extractvalue %kira.string %r{d}, 1\n", .{ temp_index, value.src });
                        try writer.print("  %array.set.pack.{d}.1 = insertvalue %kira.bridge.value %array.set.pack.{d}.0, i64 %array.set.str.ptrint.{d}, 2\n", .{
                            temp_index, temp_index, temp_index,
                        });
                        try writer.print("  %array.set.pack.{d} = insertvalue %kira.bridge.value %array.set.pack.{d}.1, i64 %array.set.str.len.{d}, 3\n", .{
                            temp_index, temp_index, temp_index,
                        });
                    },
                    .void => return error.UnsupportedExecutableFeature,
                }
                try writer.print("  %array.set.pack.ptr.{d} = alloca %kira.bridge.value\n", .{temp_index});
                try writer.print("  store %kira.bridge.value %array.set.pack.{d}, ptr %array.set.pack.ptr.{d}\n", .{ temp_index, temp_index });
                try writer.print("  call void @\"kira_array_store\"(ptr %array.set.ptr.{d}, i64 %r{d}, ptr %array.set.pack.ptr.{d})\n", .{
                    value.src, value.index, temp_index,
                });
            },
            .load_indirect => |value| {
                const abi_type = try llvmIndirectLoadTypeText(allocator, request.program, value.ty);
                try writer.print("  %load.ptr.{d} = inttoptr i64 %r{d} to ptr\n", .{ value.dst, value.ptr });
                switch (value.ty.kind) {
                    .integer => {
                        try writer.print("  %load.raw.{d} = load {s}, ptr %load.ptr.{d}\n", .{ value.dst, abi_type, value.dst });
                        try writer.writeAll("  %r");
                        try writer.print("{d}", .{value.dst});
                        if (std.mem.eql(u8, abi_type, "i8") or std.mem.eql(u8, abi_type, "i16") or std.mem.eql(u8, abi_type, "i32")) {
                            try writer.print(" = sext {s} %load.raw.{d} to i64\n", .{ abi_type, value.dst });
                        } else {
                            try writer.print(" = load i64, ptr %load.ptr.{d}\n", .{value.dst});
                        }
                    },
                    .boolean => {
                        try writer.print("  %load.raw.{d} = load i8, ptr %load.ptr.{d}\n", .{ value.dst, value.dst });
                        try writer.writeAll("  %r");
                        try writer.print("{d}", .{value.dst});
                        try writer.print(" = trunc i8 %load.raw.{d} to i1\n", .{value.dst});
                    },
                    .raw_ptr => {
                        try writer.print("  %load.rawptr.{d} = load ptr, ptr %load.ptr.{d}\n", .{ value.dst, value.dst });
                        try writer.writeAll("  %r");
                        try writer.print("{d}", .{value.dst});
                        try writer.print(" = ptrtoint ptr %load.rawptr.{d} to i64\n", .{value.dst});
                    },
                    .array => {
                        try writer.print("  %load.arrayptr.{d} = load ptr, ptr %load.ptr.{d}\n", .{ value.dst, value.dst });
                        try writer.writeAll("  %r");
                        try writer.print("{d}", .{value.dst});
                        try writer.print(" = ptrtoint ptr %load.arrayptr.{d} to i64\n", .{value.dst});
                    },
                    .float => {
                        try writer.print("  %load.raw.float.{d} = load {s}, ptr %load.ptr.{d}\n", .{ value.dst, abi_type, value.dst });
                        try writer.writeAll("  %r");
                        try writer.print("{d}", .{value.dst});
                        if (std.mem.eql(u8, abi_type, "float")) {
                            try writer.print(" = fpext float %load.raw.float.{d} to double\n", .{value.dst});
                        } else {
                            try writer.print(" = fadd double %load.raw.float.{d}, 0.0\n", .{value.dst});
                        }
                    },
                    .string => {
                        try writer.writeAll("  %r");
                        try writer.print("{d}", .{value.dst});
                        try writer.print(" = load {s}, ptr %load.ptr.{d}\n", .{ abi_type, value.dst });
                    },
                    .ffi_struct => {
                        try writer.writeAll("  %r");
                        try writer.print("{d}", .{value.dst});
                        try writer.print(" = add i64 %r{d}, 0\n", .{value.ptr});
                    },
                    else => return error.UnsupportedExecutableFeature,
                }
            },
            .store_indirect => |value| {
                const abi_type = try llvmIndirectLoadTypeText(allocator, request.program, value.ty);
                try writer.print("  %store.ptr.{d} = inttoptr i64 %r{d} to ptr\n", .{ value.src, value.ptr });
                switch (value.ty.kind) {
                    .integer => {
                        if (std.mem.eql(u8, abi_type, "i64")) {
                            try writer.print("  store i64 %r{d}, ptr %store.ptr.{d}\n", .{ value.src, value.src });
                        } else {
                            try writer.print("  %store.cast.{d} = trunc i64 %r{d} to {s}\n", .{ value.src, value.src, abi_type });
                            try writer.print("  store {s} %store.cast.{d}, ptr %store.ptr.{d}\n", .{ abi_type, value.src, value.src });
                        }
                    },
                    .boolean => {
                        try writer.print("  %store.bool.{d} = zext i1 %r{d} to i8\n", .{ value.src, value.src });
                        try writer.print("  store i8 %store.bool.{d}, ptr %store.ptr.{d}\n", .{ value.src, value.src });
                    },
                    .raw_ptr => {
                        if (value.ty.name != null and std.mem.eql(u8, value.ty.name.?, "CString") and register_types[value.src].kind == .string) {
                            try writer.print("  %store.cstr.{d} = extractvalue %kira.string %r{d}, 0\n", .{ value.src, value.src });
                            try writer.print("  store ptr %store.cstr.{d}, ptr %store.ptr.{d}\n", .{ value.src, value.src });
                        } else {
                            try writer.print("  %store.rawptr.{d} = inttoptr i64 %r{d} to ptr\n", .{ value.src, value.src });
                            try writer.print("  store ptr %store.rawptr.{d}, ptr %store.ptr.{d}\n", .{ value.src, value.src });
                        }
                    },
                    .array => {
                        try writer.print("  %store.arrayptr.{d} = inttoptr i64 %r{d} to ptr\n", .{ value.src, value.src });
                        try writer.print("  store ptr %store.arrayptr.{d}, ptr %store.ptr.{d}\n", .{ value.src, value.src });
                    },
                    .float => {
                        if (std.mem.eql(u8, abi_type, "float")) {
                            try writer.print("  %store.float.{d} = fptrunc double %r{d} to float\n", .{ value.src, value.src });
                            try writer.print("  store float %store.float.{d}, ptr %store.ptr.{d}\n", .{ value.src, value.src });
                        } else {
                            try writer.print("  store double %r{d}, ptr %store.ptr.{d}\n", .{ value.src, value.src });
                        }
                    },
                    .string => {
                        try writer.print("  store {s} %r{d}, ptr %store.ptr.{d}\n", .{ abi_type, value.src, value.src });
                    },
                    else => return error.UnsupportedExecutableFeature,
                }
            },
            .copy_indirect => |value| {
                const struct_type_name = typeRefName(value.type_name);
                try writer.print("  %copy.dst.{d} = inttoptr i64 %r{d} to ptr\n", .{ value.dst_ptr, value.dst_ptr });
                try writer.print("  %copy.src.{d} = inttoptr i64 %r{d} to ptr\n", .{ value.src_ptr, value.src_ptr });
                try writer.print("  %copy.val.{d} = load {s}, ptr %copy.src.{d}\n", .{ value.dst_ptr, struct_type_name, value.src_ptr });
                try writer.print("  store {s} %copy.val.{d}, ptr %copy.dst.{d}\n", .{ struct_type_name, value.dst_ptr, value.dst_ptr });
            },
            .branch => |value| {
                try writer.writeAll("  br i1 %r");
                try writer.print("{d}", .{value.condition});
                try writer.writeAll(", label %");
                try writeLlvmLabelName(writer, value.true_label);
                try writer.writeAll(", label %");
                try writeLlvmLabelName(writer, value.false_label);
                try writer.writeAll("\n");
                block_terminated = true;
            },
            .jump => |value| {
                try writer.writeAll("  br label %");
                try writeLlvmLabelName(writer, value.label);
                try writer.writeAll("\n");
                block_terminated = true;
            },
            .label => |value| {
                if (!block_terminated) {
                    try writer.writeAll("  br label %");
                    try writeLlvmLabelName(writer, value.id);
                    try writer.writeAll("\n");
                }
                try writeLlvmLabelName(writer, value.id);
                try writer.writeAll(":\n");
                block_terminated = false;
            },
            .print => |value| {
                try writePrintInstruction(
                    allocator,
                    writer,
                    request.program,
                    globals,
                    register_types[value.src],
                    value.src,
                    &string_state[0],
                    &temp_counter,
                );
            },
            .call => |value| {
                try writeCallInstruction(writer, request, symbol_names, request.program, register_types, value);
            },
            .call_value => |value| {
                try writeIndirectCallInstruction(writer, request, symbol_names, request.program, register_types, value);
            },
            .ret => |value| {
                if (value.src) |src| {
                    try writer.writeAll("  ret ");
                    try writer.writeAll(llvmValueTypeText(function_decl.return_type));
                    try writer.writeAll(" %r");
                    try writer.print("{d}", .{src});
                    try writer.writeAll("\n");
                } else {
                    try writer.writeAll("  ret void\n");
                }
                block_terminated = true;
            },
        }
    }

    if (!block_terminated) {
        try writer.writeAll("  ret void\n");
    }
    try writer.writeAll("}\n");
    return body.toOwnedSlice();
}

pub fn buildTextMainBody(
    allocator: std.mem.Allocator,
    entry_function_name: []const u8,
) ![]const u8 {
    var body: std.Io.Writer.Allocating = .init(allocator);
    errdefer body.deinit();

    var writer = &body.writer;
    try writer.writeAll("define i32 @main() {\nentry:\n");
    try writer.writeAll("  call void ");
    try writeLlvmSymbol(writer, entry_function_name);
    try writer.writeAll("()\n  ret i32 0\n}\n");
    return body.toOwnedSlice();
}

test "emits native state helper calls in text llvm ir" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    var program = ir.Program{
        .types = &.{.{
            .name = "CounterState",
            .fields = &.{.{ .name = "count", .ty = .{ .kind = .integer, .name = "I64" } }},
        }},
        .functions = &.{.{
            .id = 0,
            .name = "main",
            .execution = .native,
            .param_types = &.{},
            .return_type = .{ .kind = .void },
            .register_count = 3,
            .local_count = 0,
            .local_types = &.{},
            .instructions = &.{
                .{ .alloc_struct = .{ .dst = 0, .type_name = "CounterState" } },
                .{ .alloc_native_state = .{ .dst = 1, .src = 0, .type_name = "CounterState", .type_id = 77 } },
                .{ .recover_native_state = .{ .dst = 2, .state = 1, .type_name = "CounterState", .type_id = 77 } },
                .{ .ret = .{ .src = null } },
            },
        }},
        .entry_index = 0,
    };
    const request = backend_api.CompileRequest{
        .mode = .llvm_native,
        .program = &program,
        .module_name = "native_state_test",
        .emit = .{
            .object_path = "dummy.obj",
        },
    };

    const text = try buildTextLlvmIr(allocator, request, "x86_64-pc-windows-msvc");
    try std.testing.expect(std.mem.indexOf(u8, text, "kira_native_state_alloc") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "kira_native_state_recover") != null);
}

test "native state ffi struct field writes copy assigned values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    var program = ir.Program{
        .types = &.{
            .{
                .name = "Handle",
                .fields = &.{.{ .name = "id", .ty = .{ .kind = .integer, .name = "I32" } }},
                .ffi = .ffi_struct,
            },
            .{
                .name = "AppState",
                .fields = &.{.{ .name = "handle", .ty = .{ .kind = .ffi_struct, .name = "Handle" } }},
            },
        },
        .functions = &.{.{
            .id = 0,
            .name = "main",
            .execution = .native,
            .param_types = &.{},
            .return_type = .{ .kind = .void },
            .register_count = 4,
            .local_count = 0,
            .local_types = &.{},
            .instructions = &.{
                .{ .alloc_struct = .{ .dst = 0, .type_name = "AppState" } },
                .{ .alloc_native_state = .{ .dst = 1, .src = 0, .type_name = "AppState", .type_id = 77 } },
                .{ .recover_native_state = .{ .dst = 2, .state = 1, .type_name = "AppState", .type_id = 77 } },
                .{ .alloc_struct = .{ .dst = 3, .type_name = "Handle" } },
                .{ .native_state_field_set = .{
                    .state = 2,
                    .field_index = 0,
                    .src = 3,
                    .field_ty = .{ .kind = .ffi_struct, .name = "Handle" },
                } },
                .{ .ret = .{ .src = null } },
            },
        }},
        .entry_index = 0,
    };
    const request = backend_api.CompileRequest{
        .mode = .llvm_native,
        .program = &program,
        .module_name = "native_state_ffi_set_test",
        .emit = .{
            .object_path = "dummy.obj",
        },
    };

    const text = try buildTextLlvmIr(allocator, request, "x86_64-pc-windows-msvc");
    try std.testing.expect(std.mem.indexOf(u8, text, "native.state.set.struct.copy") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "native.state.set.struct.ptrint") != null);
}
