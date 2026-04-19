const std = @import("std");
const builtin = @import("builtin");
const ir = @import("kira_ir");
const runtime_abi = @import("kira_runtime_abi");
const backend_api = @import("kira_backend_api");
const build_options = @import("kira_llvm_build_options");
const llvm = @import("llvm_c.zig");
const runtime_symbols = @import("runtime_symbols.zig");
const parent = @import("backend.zig");
const functionById = parent.functionById;
const functionExecutionById = parent.functionExecutionById;
const resolveExecution = parent.resolveExecution;
const llvmCallTypeText = parent.llvmCallTypeText;
const integerAbiTypeName = parent.integerAbiTypeName;
const floatAbiTypeName = parent.floatAbiTypeName;
const typeRefName = parent.typeRefName;
const bridgeTagValue = parent.bridgeTagValue;
const llvmValueTypeText = parent.llvmValueTypeText;
const writeLlvmSymbol = parent.writeLlvmSymbol;
const hashCallValueSignature = parent.hashCallValueSignature;
const CallValueDispatcher = parent.CallValueDispatcher;
const sameCallValueSignature = parent.sameCallValueSignature;
pub fn writeCallInstruction(
    writer: anytype,
    request: backend_api.CompileRequest,
    symbol_names: *const std.AutoHashMapUnmanaged(u32, []const u8),
    program: *const ir.Program,
    register_types: []const ir.ValueType,
    call_inst: ir.Call,
) !void {
    const callee_id = call_inst.callee;
    const callee_decl = functionById(program.*, callee_id) orelse return error.UnknownFunction;
    const callee_execution = functionExecutionById(request.program.*, callee_id) orelse return error.UnknownFunction;
    switch (resolveExecution(callee_execution, request.mode)) {
        .native => {
            const callee_name = symbol_names.get(callee_id) orelse return error.MissingFunctionDeclaration;
            if (callee_decl.is_extern) {
                for (call_inst.args, 0..) |arg, index| {
                    const param_type = callee_decl.param_types[index];
                    switch (param_type.kind) {
                        .array, .raw_ptr => {
                            if (register_types[arg].kind == .string and param_type.name != null and std.mem.eql(u8, param_type.name.?, "CString")) {
                                try writer.print("  %call.arg.{d}.{d} = extractvalue %kira.string %r{d}, 0\n", .{ callee_id, index, arg });
                            } else {
                                try writer.print("  %call.arg.{d}.{d} = inttoptr i64 %r{d} to ptr\n", .{ callee_id, index, arg });
                            }
                        },
                        .integer => {
                            const abi_type = integerAbiTypeName(param_type.name);
                            if (!std.mem.eql(u8, abi_type, "i64")) {
                                try writer.print("  %call.arg.{d}.{d} = trunc i64 %r{d} to {s}\n", .{ callee_id, index, arg, abi_type });
                            }
                        },
                        .float => {
                            const abi_type = floatAbiTypeName(param_type.name);
                            if (std.mem.eql(u8, abi_type, "float")) {
                                try writer.print("  %call.arg.{d}.{d} = fptrunc double %r{d} to float\n", .{ callee_id, index, arg });
                            }
                        },
                        .ffi_struct => {
                            const struct_type_name = typeRefName(param_type.name orelse return error.UnsupportedExecutableFeature);
                            try writer.print("  %call.arg.ptr.{d}.{d} = inttoptr i64 %r{d} to ptr\n", .{ callee_id, index, arg });
                            try writer.print("  %call.arg.{d}.{d} = load {s}, ptr %call.arg.ptr.{d}.{d}\n", .{
                                callee_id, index, struct_type_name, callee_id, index,
                            });
                        },
                        else => {},
                    }
                }
            }
            if (call_inst.dst) |dst| {
                if (callee_decl.is_extern and (callee_decl.return_type.kind == .raw_ptr or callee_decl.return_type.kind == .array)) {
                    try writer.writeAll("  %call.ptr.");
                    try writer.print("{d}", .{dst});
                    try writer.writeAll(" = call ptr ");
                } else if (callee_decl.is_extern and callee_decl.return_type.kind == .ffi_struct) {
                    try writer.writeAll("  %call.struct.");
                    try writer.print("{d}", .{dst});
                    try writer.writeAll(" = call ");
                } else if (callee_decl.is_extern and callee_decl.return_type.kind == .integer and !std.mem.eql(u8, integerAbiTypeName(callee_decl.return_type.name), "i64")) {
                    try writer.writeAll("  %call.int.");
                    try writer.print("{d}", .{dst});
                    try writer.writeAll(" = call ");
                } else {
                    try writer.writeAll("  %r");
                    try writer.print("{d}", .{dst});
                    try writer.writeAll(" = call ");
                }
            } else {
                try writer.writeAll("  call ");
            }
            if (!(callee_decl.is_extern and (callee_decl.return_type.kind == .raw_ptr or callee_decl.return_type.kind == .array) and call_inst.dst != null)) {
                try writer.writeAll(llvmCallTypeText(callee_decl.return_type, callee_decl.is_extern));
                try writer.writeByte(' ');
            }
            try writeLlvmSymbol(writer, callee_name);
            try writer.writeByte('(');
            for (call_inst.args, 0..) |arg, index| {
                if (index != 0) try writer.writeAll(", ");
                const param_type = callee_decl.param_types[index];
                try writer.writeAll(llvmCallTypeText(param_type, callee_decl.is_extern));
                try writer.writeByte(' ');
                if (callee_decl.is_extern) {
                    switch (param_type.kind) {
                        .array, .raw_ptr, .ffi_struct => {
                            try writer.writeAll("%call.arg.");
                            try writer.print("{d}.{d}", .{ callee_id, index });
                        },
                        .integer => {
                            const abi_type = integerAbiTypeName(param_type.name);
                            if (std.mem.eql(u8, abi_type, "i64")) {
                                try writer.writeAll("%r");
                                try writer.print("{d}", .{arg});
                            } else {
                                try writer.writeAll("%call.arg.");
                                try writer.print("{d}.{d}", .{ callee_id, index });
                            }
                        },
                        .float => {
                            const abi_type = floatAbiTypeName(param_type.name);
                            if (std.mem.eql(u8, abi_type, "double")) {
                                try writer.writeAll("%r");
                                try writer.print("{d}", .{arg});
                            } else {
                                try writer.writeAll("%call.arg.");
                                try writer.print("{d}.{d}", .{ callee_id, index });
                            }
                        },
                        else => {
                            try writer.writeAll("%r");
                            try writer.print("{d}", .{arg});
                        },
                    }
                } else {
                    try writer.writeAll("%r");
                    try writer.print("{d}", .{arg});
                }
            }
            try writer.writeAll(")\n");
            if (callee_decl.is_extern and (callee_decl.return_type.kind == .raw_ptr or callee_decl.return_type.kind == .array)) {
                if (call_inst.dst) |dst| {
                    try writer.writeAll("  %r");
                    try writer.print("{d}", .{dst});
                    try writer.writeAll(" = ptrtoint ptr %call.ptr.");
                    try writer.print("{d}", .{dst});
                    try writer.writeAll(" to i64\n");
                }
            } else if (callee_decl.is_extern and callee_decl.return_type.kind == .ffi_struct) {
                if (call_inst.dst) |dst| {
                    const struct_type_name = typeRefName(callee_decl.return_type.name orelse return error.UnsupportedExecutableFeature);
                    try writer.print("  %call.ret.ptr.{d} = alloca {s}\n", .{ dst, struct_type_name });
                    try writer.print("  store {s} %call.struct.{d}, ptr %call.ret.ptr.{d}\n", .{ struct_type_name, dst, dst });
                    try writer.writeAll("  %r");
                    try writer.print("{d}", .{dst});
                    try writer.writeAll(" = ptrtoint ptr %call.ret.ptr.");
                    try writer.print("{d}", .{dst});
                    try writer.writeAll(" to i64\n");
                }
            } else if (callee_decl.is_extern and callee_decl.return_type.kind == .integer and call_inst.dst != null) {
                const abi_type = integerAbiTypeName(callee_decl.return_type.name);
                if (!std.mem.eql(u8, abi_type, "i64")) {
                    const dst = call_inst.dst.?;
                    try writer.print("  %r{d}.sext = sext {s} %call.int.{d} to i64\n", .{ dst, abi_type, dst });
                    try writer.print("  %r{d} = add i64 %r{d}.sext, 0\n", .{ dst, dst });
                }
            } else if (callee_decl.is_extern and callee_decl.return_type.kind == .float and call_inst.dst != null) {
                const abi_type = floatAbiTypeName(callee_decl.return_type.name);
                if (std.mem.eql(u8, abi_type, "float")) {
                    const dst = call_inst.dst.?;
                    try writer.print("  %r{d}.ext = fpext float %r{d} to double\n", .{ dst, dst });
                    try writer.print("  %r{d} = fadd double %r{d}.ext, 0.0\n", .{ dst, dst });
                }
            }
        },
        .runtime => {
            if (request.mode != .hybrid) return error.RuntimeCallInNativeBuild;
            if (call_inst.args.len > 0) {
                try writer.print("  %rt.args.{d} = alloca [{d} x %kira.bridge.value]\n", .{ callee_id, call_inst.args.len });
                for (call_inst.args, 0..) |arg, index| {
                    try writer.print("  %rt.slot.{d}.{d} = getelementptr inbounds [{d} x %kira.bridge.value], ptr %rt.args.{d}, i64 0, i64 {d}\n", .{
                        callee_id, index, call_inst.args.len, callee_id, index,
                    });
                    try writer.print("  %rt.pack.{d}.{d}.0 = insertvalue %kira.bridge.value zeroinitializer, i8 {d}, 0\n", .{
                        callee_id, index, bridgeTagValue(register_types[arg]),
                    });
                    switch (register_types[arg].kind) {
                        .integer, .raw_ptr, .ffi_struct => {
                            try writer.print("  %rt.pack.{d}.{d}.1 = insertvalue %kira.bridge.value %rt.pack.{d}.{d}.0, i64 %r{d}, 2\n", .{
                                callee_id, index, callee_id, index, arg,
                            });
                            try writer.print("  store %kira.bridge.value %rt.pack.{d}.{d}.1, ptr %rt.slot.{d}.{d}\n", .{
                                callee_id, index, callee_id, index,
                            });
                        },
                        .array => {
                            try writer.print("  %rt.pack.{d}.{d}.1 = insertvalue %kira.bridge.value %rt.pack.{d}.{d}.0, i64 %r{d}, 2\n", .{
                                callee_id, index, callee_id, index, arg,
                            });
                            try writer.print("  store %kira.bridge.value %rt.pack.{d}.{d}.1, ptr %rt.slot.{d}.{d}\n", .{
                                callee_id, index, callee_id, index,
                            });
                        },
                        .boolean => {
                            try writer.print("  %rt.bool.{d}.{d} = zext i1 %r{d} to i64\n", .{ callee_id, index, arg });
                            try writer.print("  %rt.pack.{d}.{d}.1 = insertvalue %kira.bridge.value %rt.pack.{d}.{d}.0, i64 %rt.bool.{d}.{d}, 2\n", .{
                                callee_id, index, callee_id, index, callee_id, index,
                            });
                            try writer.print("  store %kira.bridge.value %rt.pack.{d}.{d}.1, ptr %rt.slot.{d}.{d}\n", .{
                                callee_id, index, callee_id, index,
                            });
                        },
                        .string => {
                            try writer.print("  %rt.str.ptr.{d}.{d} = extractvalue %kira.string %r{d}, 0\n", .{ callee_id, index, arg });
                            try writer.print("  %rt.str.ptrint.{d}.{d} = ptrtoint ptr %rt.str.ptr.{d}.{d} to i64\n", .{
                                callee_id, index, callee_id, index,
                            });
                            try writer.print("  %rt.str.len.{d}.{d} = extractvalue %kira.string %r{d}, 1\n", .{ callee_id, index, arg });
                            try writer.print("  %rt.pack.{d}.{d}.1 = insertvalue %kira.bridge.value %rt.pack.{d}.{d}.0, i64 %rt.str.ptrint.{d}.{d}, 2\n", .{
                                callee_id, index, callee_id, index, callee_id, index,
                            });
                            try writer.print("  %rt.pack.{d}.{d}.2 = insertvalue %kira.bridge.value %rt.pack.{d}.{d}.1, i64 %rt.str.len.{d}.{d}, 3\n", .{
                                callee_id, index, callee_id, index, callee_id, index,
                            });
                            try writer.print("  store %kira.bridge.value %rt.pack.{d}.{d}.2, ptr %rt.slot.{d}.{d}\n", .{
                                callee_id, index, callee_id, index,
                            });
                        },
                        .float => {
                            if (register_types[arg].name != null and std.mem.eql(u8, register_types[arg].name.?, "F32")) {
                                try writer.print("  %rt.float.ext.{d}.{d} = fpext float %r{d} to double\n", .{ callee_id, index, arg });
                                try writer.print("  %rt.float.bits.{d}.{d} = bitcast double %rt.float.ext.{d}.{d} to i64\n", .{
                                    callee_id, index, callee_id, index,
                                });
                            } else {
                                try writer.print("  %rt.float.bits.{d}.{d} = bitcast double %r{d} to i64\n", .{ callee_id, index, arg });
                            }
                            try writer.print("  %rt.pack.{d}.{d}.1 = insertvalue %kira.bridge.value %rt.pack.{d}.{d}.0, i64 %rt.float.bits.{d}.{d}, 2\n", .{
                                callee_id, index, callee_id, index, callee_id, index,
                            });
                            try writer.print("  store %kira.bridge.value %rt.pack.{d}.{d}.1, ptr %rt.slot.{d}.{d}\n", .{
                                callee_id, index, callee_id, index,
                            });
                        },
                        .void => return error.UnsupportedExecutableFeature,
                    }
                }
            }
            try writer.print("  %rt.result.{d} = alloca %kira.bridge.value\n", .{callee_id});
            try writer.writeAll("  call void @\"kira_hybrid_call_runtime\"(i32 ");
            try writer.print("{d}", .{callee_id});
            try writer.writeAll(", ptr ");
            if (call_inst.args.len == 0) {
                try writer.writeAll("null");
            } else {
                try writer.print("%rt.args.{d}", .{callee_id});
            }
            try writer.writeAll(", i32 ");
            try writer.print("{d}", .{call_inst.args.len});
            try writer.writeAll(", ptr ");
            try writer.print("%rt.result.{d}", .{callee_id});
            try writer.writeAll(")\n");
            if (call_inst.dst) |dst| {
                try writer.print("  %rt.result.load.{d} = load %kira.bridge.value, ptr %rt.result.{d}\n", .{ callee_id, callee_id });
                switch (callee_decl.return_type.kind) {
                    .integer, .raw_ptr, .ffi_struct, .array => {
                        try writer.writeAll("  %r");
                        try writer.print("{d}", .{dst});
                        try writer.print(" = extractvalue %kira.bridge.value %rt.result.load.{d}, 2\n", .{callee_id});
                    },
                    .boolean => {
                        try writer.print("  %rt.result.word.{d} = extractvalue %kira.bridge.value %rt.result.load.{d}, 2\n", .{ callee_id, callee_id });
                        try writer.writeAll("  %r");
                        try writer.print("{d}", .{dst});
                        try writer.print(" = trunc i64 %rt.result.word.{d} to i1\n", .{callee_id});
                    },
                    .float => {
                        try writer.print("  %rt.result.bits.{d} = extractvalue %kira.bridge.value %rt.result.load.{d}, 2\n", .{ callee_id, callee_id });
                        if (callee_decl.return_type.name != null and std.mem.eql(u8, callee_decl.return_type.name.?, "F32")) {
                            try writer.print("  %rt.result.float64.{d} = bitcast i64 %rt.result.bits.{d} to double\n", .{ callee_id, callee_id });
                            try writer.writeAll("  %r");
                            try writer.print("{d}", .{dst});
                            try writer.print(" = fptrunc double %rt.result.float64.{d} to float\n", .{callee_id});
                        } else {
                            try writer.writeAll("  %r");
                            try writer.print("{d}", .{dst});
                            try writer.print(" = bitcast i64 %rt.result.bits.{d} to double\n", .{callee_id});
                        }
                    },
                    .string => {
                        try writer.print("  %rt.result.ptrint.{d} = extractvalue %kira.bridge.value %rt.result.load.{d}, 2\n", .{ callee_id, callee_id });
                        try writer.print("  %rt.result.len.{d} = extractvalue %kira.bridge.value %rt.result.load.{d}, 3\n", .{ callee_id, callee_id });
                        try writer.print("  %rt.result.ptr.{d} = inttoptr i64 %rt.result.ptrint.{d} to ptr\n", .{ callee_id, callee_id });
                        try writer.writeAll("  %r");
                        try writer.print("{d}", .{dst});
                        try writer.print(".0 = insertvalue %kira.string zeroinitializer, ptr %rt.result.ptr.{d}, 0\n", .{callee_id});
                        try writer.writeAll("  %r");
                        try writer.print("{d}", .{dst});
                        try writer.print(" = insertvalue %kira.string %r{d}.0, i64 %rt.result.len.{d}, 1\n", .{ dst, callee_id });
                    },
                    .void => {},
                }
            }
        },
        .inherited => unreachable,
    }
}

pub fn writeIndirectCallInstruction(
    writer: anytype,
    request: backend_api.CompileRequest,
    symbol_names: *const std.AutoHashMapUnmanaged(u32, []const u8),
    program: *const ir.Program,
    register_types: []const ir.ValueType,
    call_inst: ir.CallValue,
) !void {
    _ = request;
    _ = symbol_names;
    _ = program;
    _ = register_types;

    const dispatcher_name = try dispatcherSymbolName(std.heap.page_allocator, hashCallValueSignature(call_inst.param_types, call_inst.return_type));
    defer std.heap.page_allocator.free(dispatcher_name);

    if (call_inst.dst) |dst| {
        try writer.writeAll("  %r");
        try writer.print("{d}", .{dst});
        try writer.writeAll(" = call ");
        try writer.writeAll(llvmValueTypeText(call_inst.return_type));
        try writer.writeByte(' ');
    } else {
        try writer.writeAll("  call void ");
    }
    try writeLlvmSymbol(writer, dispatcher_name);
    try writer.writeAll("(i64 %r");
    try writer.print("{d}", .{call_inst.callee});
    for (call_inst.args, 0..) |arg, index| {
        try writer.writeAll(", ");
        try writer.writeAll(llvmValueTypeText(call_inst.param_types[index]));
        try writer.writeAll(" %r");
        try writer.print("{d}", .{arg});
    }
    try writer.writeAll(")\n");
}

pub fn buildCallValueDispatcher(
    allocator: std.mem.Allocator,
    request: backend_api.CompileRequest,
    symbol_names: *const std.AutoHashMapUnmanaged(u32, []const u8),
    dispatcher: CallValueDispatcher,
) ![]const u8 {
    var output = std.array_list.Managed(u8).init(allocator);
    errdefer output.deinit();
    var writer = output.writer();

    const dispatcher_name = try dispatcherSymbolName(allocator, dispatcher.hash);
    defer allocator.free(dispatcher_name);

    try writer.writeAll("define ");
    try writer.writeAll(llvmValueTypeText(dispatcher.return_type));
    try writer.writeByte(' ');
    try writeLlvmSymbol(writer, dispatcher_name);
    try writer.writeAll("(i64 %function_id");
    for (dispatcher.param_types, 0..) |param_type, index| {
        try writer.writeAll(", ");
        try writer.writeAll(llvmValueTypeText(param_type));
        try writer.writeAll(" %arg");
        try writer.print("{d}", .{index});
    }
    try writer.writeAll(") {\nentry:\n");
    try writer.writeAll("  switch i64 %function_id, label %dispatch.default [\n");

    var matching_functions = std.array_list.Managed(ir.Function).init(allocator);
    defer matching_functions.deinit();
    for (request.program.functions) |function_decl| {
        if (!sameCallValueSignature(dispatcher.param_types, dispatcher.return_type, function_decl.param_types, function_decl.return_type)) continue;
        try matching_functions.append(function_decl);
        try writer.writeAll("    i64 ");
        try writer.print("{d}", .{function_decl.id});
        try writer.writeAll(", label %dispatch.case.");
        try writer.print("{d}\n", .{matching_functions.items.len - 1});
    }
    try writer.writeAll("  ]\n");

    for (matching_functions.items, 0..) |function_decl, case_index| {
        try writer.writeAll("dispatch.case.");
        try writer.print("{d}", .{case_index});
        try writer.writeAll(":\n");

        switch (resolveExecution(function_decl.execution, request.mode)) {
            .native => {
                const callee_name = symbol_names.get(function_decl.id) orelse return error.MissingFunctionDeclaration;
                if (function_decl.is_extern) {
                    for (function_decl.param_types, 0..) |param_type, index| {
                        switch (param_type.kind) {
                            .array, .raw_ptr => {
                                try writer.print("  %dispatch.arg.{d}.{d} = inttoptr i64 %arg{d} to ptr\n", .{ case_index, index, index });
                            },
                            .integer => {
                                const abi_type = integerAbiTypeName(param_type.name);
                                if (!std.mem.eql(u8, abi_type, "i64")) {
                                    try writer.print("  %dispatch.arg.{d}.{d} = trunc i64 %arg{d} to {s}\n", .{ case_index, index, index, abi_type });
                                }
                            },
                            .float => {
                                const abi_type = floatAbiTypeName(param_type.name);
                                if (std.mem.eql(u8, abi_type, "float")) {
                                    try writer.print("  %dispatch.arg.{d}.{d} = fptrunc double %arg{d} to float\n", .{ case_index, index, index });
                                }
                            },
                            .ffi_struct => {
                                const struct_type_name = typeRefName(param_type.name orelse return error.UnsupportedExecutableFeature);
                                try writer.print("  %dispatch.arg.ptr.{d}.{d} = inttoptr i64 %arg{d} to ptr\n", .{ case_index, index, index });
                                try writer.print("  %dispatch.arg.{d}.{d} = load {s}, ptr %dispatch.arg.ptr.{d}.{d}\n", .{
                                    case_index, index, struct_type_name, case_index, index,
                                });
                            },
                            else => {},
                        }
                    }
                }

                if (dispatcher.return_type.kind == .void) {
                    try writer.writeAll("  call void ");
                } else if (function_decl.is_extern and (dispatcher.return_type.kind == .raw_ptr or dispatcher.return_type.kind == .array)) {
                    try writer.writeAll("  %dispatch.call.ptr.");
                    try writer.print("{d}", .{case_index});
                    try writer.writeAll(" = call ptr ");
                } else if (function_decl.is_extern and dispatcher.return_type.kind == .ffi_struct) {
                    try writer.writeAll("  %dispatch.call.struct.");
                    try writer.print("{d}", .{case_index});
                    try writer.writeAll(" = call ");
                    try writer.writeAll(llvmCallTypeText(dispatcher.return_type, true));
                    try writer.writeByte(' ');
                } else if (function_decl.is_extern and dispatcher.return_type.kind == .integer and !std.mem.eql(u8, integerAbiTypeName(dispatcher.return_type.name), "i64")) {
                    try writer.writeAll("  %dispatch.call.int.");
                    try writer.print("{d}", .{case_index});
                    try writer.writeAll(" = call ");
                    try writer.writeAll(integerAbiTypeName(dispatcher.return_type.name));
                    try writer.writeByte(' ');
                } else if (function_decl.is_extern and dispatcher.return_type.kind == .float and std.mem.eql(u8, floatAbiTypeName(dispatcher.return_type.name), "float")) {
                    try writer.writeAll("  %dispatch.call.float.");
                    try writer.print("{d}", .{case_index});
                    try writer.writeAll(" = call float ");
                } else {
                    try writer.writeAll("  %dispatch.call.");
                    try writer.print("{d}", .{case_index});
                    try writer.writeAll(" = call ");
                    try writer.writeAll(llvmValueTypeText(dispatcher.return_type));
                    try writer.writeByte(' ');
                }
                try writeLlvmSymbol(writer, callee_name);
                try writer.writeByte('(');
                for (function_decl.param_types, 0..) |param_type, index| {
                    if (index != 0) try writer.writeAll(", ");
                    try writer.writeAll(llvmCallTypeText(param_type, function_decl.is_extern));
                    try writer.writeByte(' ');
                    if (function_decl.is_extern) {
                        switch (param_type.kind) {
                            .array, .raw_ptr, .ffi_struct => {
                                try writer.writeAll("%dispatch.arg.");
                                try writer.print("{d}.{d}", .{ case_index, index });
                            },
                            .integer => {
                                const abi_type = integerAbiTypeName(param_type.name);
                                if (std.mem.eql(u8, abi_type, "i64")) {
                                    try writer.writeAll("%arg");
                                    try writer.print("{d}", .{index});
                                } else {
                                    try writer.writeAll("%dispatch.arg.");
                                    try writer.print("{d}.{d}", .{ case_index, index });
                                }
                            },
                            .float => {
                                const abi_type = floatAbiTypeName(param_type.name);
                                if (std.mem.eql(u8, abi_type, "double")) {
                                    try writer.writeAll("%arg");
                                    try writer.print("{d}", .{index});
                                } else {
                                    try writer.writeAll("%dispatch.arg.");
                                    try writer.print("{d}.{d}", .{ case_index, index });
                                }
                            },
                            else => {
                                try writer.writeAll("%arg");
                                try writer.print("{d}", .{index});
                            },
                        }
                    } else {
                        try writer.writeAll("%arg");
                        try writer.print("{d}", .{index});
                    }
                }
                try writer.writeAll(")\n");

                switch (dispatcher.return_type.kind) {
                    .void => try writer.writeAll("  ret void\n"),
                    .raw_ptr, .array => if (function_decl.is_extern) {
                        try writer.print("  %dispatch.ret.{d} = ptrtoint ptr %dispatch.call.ptr.{d} to i64\n", .{ case_index, case_index });
                        try writer.print("  ret i64 %dispatch.ret.{d}\n", .{case_index});
                    } else {
                        try writer.print("  ret i64 %dispatch.call.{d}\n", .{case_index});
                    },
                    .ffi_struct => if (function_decl.is_extern) {
                        const struct_type_name = typeRefName(dispatcher.return_type.name orelse return error.UnsupportedExecutableFeature);
                        try writer.print("  %dispatch.ret.ptr.{d} = alloca {s}\n", .{ case_index, struct_type_name });
                        try writer.print("  store {s} %dispatch.call.struct.{d}, ptr %dispatch.ret.ptr.{d}\n", .{ struct_type_name, case_index, case_index });
                        try writer.print("  %dispatch.ret.{d} = ptrtoint ptr %dispatch.ret.ptr.{d} to i64\n", .{ case_index, case_index });
                        try writer.print("  ret i64 %dispatch.ret.{d}\n", .{case_index});
                    } else {
                        try writer.print("  ret i64 %dispatch.call.{d}\n", .{case_index});
                    },
                    .integer => if (function_decl.is_extern and !std.mem.eql(u8, integerAbiTypeName(dispatcher.return_type.name), "i64")) {
                        try writer.print("  %dispatch.ret.{d} = sext {s} %dispatch.call.int.{d} to i64\n", .{
                            case_index, integerAbiTypeName(dispatcher.return_type.name), case_index,
                        });
                        try writer.print("  ret i64 %dispatch.ret.{d}\n", .{case_index});
                    } else {
                        try writer.print("  ret i64 %dispatch.call.{d}\n", .{case_index});
                    },
                    .float => if (function_decl.is_extern and std.mem.eql(u8, floatAbiTypeName(dispatcher.return_type.name), "float")) {
                        try writer.print("  %dispatch.ret.{d} = fpext float %dispatch.call.float.{d} to double\n", .{ case_index, case_index });
                        try writer.print("  ret double %dispatch.ret.{d}\n", .{case_index});
                    } else {
                        try writer.print("  ret {s} %dispatch.call.{d}\n", .{ llvmValueTypeText(dispatcher.return_type), case_index });
                    },
                    .boolean => try writer.print("  ret i1 %dispatch.call.{d}\n", .{case_index}),
                    .string => try writer.print("  ret %kira.string %dispatch.call.{d}\n", .{case_index}),
                }
            },
            .runtime => {
                if (request.mode != .hybrid) return error.RuntimeCallInNativeBuild;
                if (dispatcher.param_types.len > 0) {
                    try writer.print("  %dispatch.rt.args.{d} = alloca [{d} x %kira.bridge.value]\n", .{ case_index, dispatcher.param_types.len });
                    for (dispatcher.param_types, 0..) |param_type, index| {
                        try writer.print("  %dispatch.rt.slot.{d}.{d} = getelementptr inbounds [{d} x %kira.bridge.value], ptr %dispatch.rt.args.{d}, i64 0, i64 {d}\n", .{
                            case_index, index, dispatcher.param_types.len, case_index, index,
                        });
                        try writer.print("  %dispatch.rt.pack.{d}.{d}.0 = insertvalue %kira.bridge.value zeroinitializer, i8 {d}, 0\n", .{
                            case_index, index, bridgeTagValue(param_type),
                        });
                        switch (param_type.kind) {
                            .integer, .raw_ptr, .ffi_struct, .array => {
                                try writer.print("  %dispatch.rt.pack.{d}.{d}.1 = insertvalue %kira.bridge.value %dispatch.rt.pack.{d}.{d}.0, i64 %arg{d}, 2\n", .{
                                    case_index, index, case_index, index, index,
                                });
                                try writer.print("  store %kira.bridge.value %dispatch.rt.pack.{d}.{d}.1, ptr %dispatch.rt.slot.{d}.{d}\n", .{
                                    case_index, index, case_index, index,
                                });
                            },
                            .boolean => {
                                try writer.print("  %dispatch.rt.bool.{d}.{d} = zext i1 %arg{d} to i64\n", .{ case_index, index, index });
                                try writer.print("  %dispatch.rt.pack.{d}.{d}.1 = insertvalue %kira.bridge.value %dispatch.rt.pack.{d}.{d}.0, i64 %dispatch.rt.bool.{d}.{d}, 2\n", .{
                                    case_index, index, case_index, index, case_index, index,
                                });
                                try writer.print("  store %kira.bridge.value %dispatch.rt.pack.{d}.{d}.1, ptr %dispatch.rt.slot.{d}.{d}\n", .{
                                    case_index, index, case_index, index,
                                });
                            },
                            .string => {
                                try writer.print("  %dispatch.rt.str.ptr.{d}.{d} = extractvalue %kira.string %arg{d}, 0\n", .{ case_index, index, index });
                                try writer.print("  %dispatch.rt.str.ptrint.{d}.{d} = ptrtoint ptr %dispatch.rt.str.ptr.{d}.{d} to i64\n", .{
                                    case_index, index, case_index, index,
                                });
                                try writer.print("  %dispatch.rt.str.len.{d}.{d} = extractvalue %kira.string %arg{d}, 1\n", .{ case_index, index, index });
                                try writer.print("  %dispatch.rt.pack.{d}.{d}.1 = insertvalue %kira.bridge.value %dispatch.rt.pack.{d}.{d}.0, i64 %dispatch.rt.str.ptrint.{d}.{d}, 2\n", .{
                                    case_index, index, case_index, index, case_index, index,
                                });
                                try writer.print("  %dispatch.rt.pack.{d}.{d}.2 = insertvalue %kira.bridge.value %dispatch.rt.pack.{d}.{d}.1, i64 %dispatch.rt.str.len.{d}.{d}, 3\n", .{
                                    case_index, index, case_index, index, case_index, index,
                                });
                                try writer.print("  store %kira.bridge.value %dispatch.rt.pack.{d}.{d}.2, ptr %dispatch.rt.slot.{d}.{d}\n", .{
                                    case_index, index, case_index, index,
                                });
                            },
                            .float => {
                                if (param_type.name != null and std.mem.eql(u8, param_type.name.?, "F32")) {
                                    try writer.print("  %dispatch.rt.float.ext.{d}.{d} = fpext float %arg{d} to double\n", .{ case_index, index, index });
                                    try writer.print("  %dispatch.rt.float.bits.{d}.{d} = bitcast double %dispatch.rt.float.ext.{d}.{d} to i64\n", .{
                                        case_index, index, case_index, index,
                                    });
                                } else {
                                    try writer.print("  %dispatch.rt.float.bits.{d}.{d} = bitcast double %arg{d} to i64\n", .{ case_index, index, index });
                                }
                                try writer.print("  %dispatch.rt.pack.{d}.{d}.1 = insertvalue %kira.bridge.value %dispatch.rt.pack.{d}.{d}.0, i64 %dispatch.rt.float.bits.{d}.{d}, 2\n", .{
                                    case_index, index, case_index, index, case_index, index,
                                });
                                try writer.print("  store %kira.bridge.value %dispatch.rt.pack.{d}.{d}.1, ptr %dispatch.rt.slot.{d}.{d}\n", .{
                                    case_index, index, case_index, index,
                                });
                            },
                            .void => return error.UnsupportedExecutableFeature,
                        }
                    }
                }
                try writer.print("  %dispatch.rt.result.{d} = alloca %kira.bridge.value\n", .{case_index});
                try writer.writeAll("  call void @\"kira_hybrid_call_runtime\"(i32 ");
                try writer.print("{d}", .{function_decl.id});
                try writer.writeAll(", ptr ");
                if (dispatcher.param_types.len == 0) {
                    try writer.writeAll("null");
                } else {
                    try writer.print("%dispatch.rt.args.{d}", .{case_index});
                }
                try writer.writeAll(", i32 ");
                try writer.print("{d}", .{dispatcher.param_types.len});
                try writer.writeAll(", ptr ");
                try writer.print("%dispatch.rt.result.{d}", .{case_index});
                try writer.writeAll(")\n");
                switch (dispatcher.return_type.kind) {
                    .void => try writer.writeAll("  ret void\n"),
                    .integer, .raw_ptr, .ffi_struct, .array => {
                        try writer.print("  %dispatch.rt.result.load.{d} = load %kira.bridge.value, ptr %dispatch.rt.result.{d}\n", .{ case_index, case_index });
                        try writer.print("  %dispatch.rt.ret.{d} = extractvalue %kira.bridge.value %dispatch.rt.result.load.{d}, 2\n", .{ case_index, case_index });
                        try writer.print("  ret i64 %dispatch.rt.ret.{d}\n", .{case_index});
                    },
                    .boolean => {
                        try writer.print("  %dispatch.rt.result.load.{d} = load %kira.bridge.value, ptr %dispatch.rt.result.{d}\n", .{ case_index, case_index });
                        try writer.print("  %dispatch.rt.ret.word.{d} = extractvalue %kira.bridge.value %dispatch.rt.result.load.{d}, 2\n", .{ case_index, case_index });
                        try writer.print("  %dispatch.rt.ret.{d} = trunc i64 %dispatch.rt.ret.word.{d} to i1\n", .{ case_index, case_index });
                        try writer.print("  ret i1 %dispatch.rt.ret.{d}\n", .{case_index});
                    },
                    .float => {
                        try writer.print("  %dispatch.rt.result.load.{d} = load %kira.bridge.value, ptr %dispatch.rt.result.{d}\n", .{ case_index, case_index });
                        try writer.print("  %dispatch.rt.ret.bits.{d} = extractvalue %kira.bridge.value %dispatch.rt.result.load.{d}, 2\n", .{ case_index, case_index });
                        if (dispatcher.return_type.name != null and std.mem.eql(u8, dispatcher.return_type.name.?, "F32")) {
                            try writer.print("  %dispatch.rt.ret.float64.{d} = bitcast i64 %dispatch.rt.ret.bits.{d} to double\n", .{ case_index, case_index });
                            try writer.print("  %dispatch.rt.ret.{d} = fptrunc double %dispatch.rt.ret.float64.{d} to float\n", .{ case_index, case_index });
                            try writer.print("  ret float %dispatch.rt.ret.{d}\n", .{case_index});
                        } else {
                            try writer.print("  %dispatch.rt.ret.{d} = bitcast i64 %dispatch.rt.ret.bits.{d} to double\n", .{ case_index, case_index });
                            try writer.print("  ret double %dispatch.rt.ret.{d}\n", .{case_index});
                        }
                    },
                    .string => {
                        try writer.print("  %dispatch.rt.result.load.{d} = load %kira.bridge.value, ptr %dispatch.rt.result.{d}\n", .{ case_index, case_index });
                        try writer.print("  %dispatch.rt.ret.ptrint.{d} = extractvalue %kira.bridge.value %dispatch.rt.result.load.{d}, 2\n", .{ case_index, case_index });
                        try writer.print("  %dispatch.rt.ret.len.{d} = extractvalue %kira.bridge.value %dispatch.rt.result.load.{d}, 3\n", .{ case_index, case_index });
                        try writer.print("  %dispatch.rt.ret.ptr.{d} = inttoptr i64 %dispatch.rt.ret.ptrint.{d} to ptr\n", .{ case_index, case_index });
                        try writer.print("  %dispatch.rt.ret.init.{d} = insertvalue %kira.string zeroinitializer, ptr %dispatch.rt.ret.ptr.{d}, 0\n", .{ case_index, case_index });
                        try writer.print("  %dispatch.rt.ret.{d} = insertvalue %kira.string %dispatch.rt.ret.init.{d}, i64 %dispatch.rt.ret.len.{d}, 1\n", .{
                            case_index, case_index, case_index,
                        });
                        try writer.print("  ret %kira.string %dispatch.rt.ret.{d}\n", .{case_index});
                    },
                }
            },
            .inherited => unreachable,
        }
    }

    try writer.writeAll("dispatch.default:\n  unreachable\n}\n");
    return output.toOwnedSlice();
}

pub fn dispatcherSymbolName(allocator: std.mem.Allocator, hash: u64) ![]const u8 {
    return std.fmt.allocPrint(allocator, "kira_callable_dispatch_{x}", .{hash});
}
