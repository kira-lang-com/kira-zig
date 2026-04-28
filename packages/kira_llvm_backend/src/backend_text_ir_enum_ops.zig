const std = @import("std");
const ir = @import("kira_ir");

pub fn emitAllocEnum(
    writer: anytype,
    register_types: []const ir.ValueType,
    value: ir.AllocEnum,
) !void {
    try writer.print("  %enum.alloc.ptr.{d} = call ptr @malloc(i64 16)\n", .{value.dst});
    try writer.print("  %enum.tag.ptr.{d} = getelementptr inbounds i64, ptr %enum.alloc.ptr.{d}, i64 0\n", .{ value.dst, value.dst });
    try writer.print("  store i64 {d}, ptr %enum.tag.ptr.{d}\n", .{ value.discriminant, value.dst });
    try writer.print("  %enum.payload.ptr.{d} = getelementptr inbounds i64, ptr %enum.alloc.ptr.{d}, i64 1\n", .{ value.dst, value.dst });
    if (value.payload_src) |payload_src| {
        switch (register_types[payload_src].kind) {
            .integer, .construct_any, .array, .raw_ptr, .ffi_struct, .enum_instance => {
                try writer.print("  store i64 %r{d}, ptr %enum.payload.ptr.{d}\n", .{ payload_src, value.dst });
            },
            .boolean => {
                try writer.print("  %enum.payload.bool.{d} = zext i1 %r{d} to i64\n", .{ value.dst, payload_src });
                try writer.print("  store i64 %enum.payload.bool.{d}, ptr %enum.payload.ptr.{d}\n", .{ value.dst, value.dst });
            },
            .float => {
                if (register_types[payload_src].name != null and std.mem.eql(u8, register_types[payload_src].name.?, "F32")) {
                    try writer.print("  %enum.payload.float64.{d} = fpext float %r{d} to double\n", .{ value.dst, payload_src });
                    try writer.print("  %enum.payload.float.bits.{d} = bitcast double %enum.payload.float64.{d} to i64\n", .{ value.dst, value.dst });
                } else {
                    try writer.print("  %enum.payload.float.bits.{d} = bitcast double %r{d} to i64\n", .{ value.dst, payload_src });
                }
                try writer.print("  store i64 %enum.payload.float.bits.{d}, ptr %enum.payload.ptr.{d}\n", .{ value.dst, value.dst });
            },
            .string => {
                try writer.print("  %enum.payload.string.heap.{d} = call ptr @malloc(i64 16)\n", .{value.dst});
                try writer.print("  store %kira.string %r{d}, ptr %enum.payload.string.heap.{d}\n", .{ payload_src, value.dst });
                try writer.print("  %enum.payload.string.int.{d} = ptrtoint ptr %enum.payload.string.heap.{d} to i64\n", .{ value.dst, value.dst });
                try writer.print("  store i64 %enum.payload.string.int.{d}, ptr %enum.payload.ptr.{d}\n", .{ value.dst, value.dst });
            },
            .void => try writer.print("  store i64 0, ptr %enum.payload.ptr.{d}\n", .{value.dst}),
        }
    } else {
        try writer.print("  store i64 0, ptr %enum.payload.ptr.{d}\n", .{value.dst});
    }
    try writer.writeAll("  %r");
    try writer.print("{d}", .{value.dst});
    try writer.writeAll(" = ptrtoint ptr %enum.alloc.ptr.");
    try writer.print("{d}", .{value.dst});
    try writer.writeAll(" to i64\n");
}

pub fn emitEnumTag(writer: anytype, value: ir.EnumTag) !void {
    try writer.print("  %enum.tag.base.{d} = inttoptr i64 %r{d} to ptr\n", .{ value.dst, value.src });
    try writer.print("  %enum.tag.slot.{d} = getelementptr inbounds i64, ptr %enum.tag.base.{d}, i64 0\n", .{ value.dst, value.dst });
    try writer.writeAll("  %r");
    try writer.print("{d}", .{value.dst});
    try writer.print(" = load i64, ptr %enum.tag.slot.{d}\n", .{value.dst});
}

pub fn emitEnumPayload(writer: anytype, value: ir.EnumPayload) !void {
    try writer.print("  %enum.payload.base.{d} = inttoptr i64 %r{d} to ptr\n", .{ value.dst, value.src });
    try writer.print("  %enum.payload.slot.{d} = getelementptr inbounds i64, ptr %enum.payload.base.{d}, i64 1\n", .{ value.dst, value.dst });
    try writer.print("  %enum.payload.raw.{d} = load i64, ptr %enum.payload.slot.{d}\n", .{ value.dst, value.dst });
    switch (value.payload_ty.kind) {
        .integer, .construct_any, .array, .raw_ptr, .ffi_struct, .enum_instance => {
            try writer.writeAll("  %r");
            try writer.print("{d}", .{value.dst});
            try writer.print(" = add i64 %enum.payload.raw.{d}, 0\n", .{value.dst});
        },
        .boolean => {
            try writer.writeAll("  %r");
            try writer.print("{d}", .{value.dst});
            try writer.print(" = trunc i64 %enum.payload.raw.{d} to i1\n", .{value.dst});
        },
        .float => {
            try writer.print("  %enum.payload.float64.{d} = bitcast i64 %enum.payload.raw.{d} to double\n", .{ value.dst, value.dst });
            try writer.writeAll("  %r");
            try writer.print("{d}", .{value.dst});
            if (value.payload_ty.name != null and std.mem.eql(u8, value.payload_ty.name.?, "F32")) {
                try writer.print(" = fptrunc double %enum.payload.float64.{d} to float\n", .{value.dst});
            } else {
                try writer.print(" = fadd double %enum.payload.float64.{d}, 0.0\n", .{value.dst});
            }
        },
        .string => {
            try writer.print("  %enum.payload.string.ptr.{d} = inttoptr i64 %enum.payload.raw.{d} to ptr\n", .{ value.dst, value.dst });
            try writer.writeAll("  %r");
            try writer.print("{d}", .{value.dst});
            try writer.print(" = load %kira.string, ptr %enum.payload.string.ptr.{d}\n", .{value.dst});
        },
        .void => return error.UnsupportedExecutableFeature,
    }
}
