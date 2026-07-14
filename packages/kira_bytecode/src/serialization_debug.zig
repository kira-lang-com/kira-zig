//! Optional trailing KBC debug section (KBCD and later). Emits, after every
//! function record, the module's dedup source-file string table followed by
//! each function's compact PC->source location table and positional local
//! names. Pre-KBCD containers omit the section entirely; readers default all
//! three fields to empty, so old `.kbc` files keep loading unchanged.
//!
//! Layout (all little-endian, appended after the last function):
//!   u32 source_file_count
//!   source_file_count * length-prefixed string
//!   per function, in serialized order:
//!     u32 location_count
//!     location_count * { u32 file_id, u32 start, u32 end }
//!     u32 local_name_count
//!     local_name_count * length-prefixed string

const std = @import("std");
const bytecode = @import("bytecode.zig");
const primitives = @import("serialization_primitives.zig");

const Module = bytecode.Module;
const Function = bytecode.Function;
const SourceLoc = bytecode.SourceLoc;

const writeString = primitives.writeString;
const readString = primitives.readString;

/// Emit the trailing debug section: the module source-file table followed by
/// each function's location table and local-name table, in function order.
pub fn writeDebugSection(writer: anytype, module: Module) !void {
    try writer.writeInt(u32, @as(u32, @intCast(module.source_files.len)), .little);
    for (module.source_files) |file_path| try writeString(writer, file_path);

    for (module.functions) |function_decl| {
        try writer.writeInt(u32, @as(u32, @intCast(function_decl.debug_locations.len)), .little);
        for (function_decl.debug_locations) |loc| {
            try writer.writeInt(u32, loc.file_id, .little);
            try writer.writeInt(u32, loc.start, .little);
            try writer.writeInt(u32, loc.end, .little);
        }
        try writer.writeInt(u32, @as(u32, @intCast(function_decl.local_names.len)), .little);
        for (function_decl.local_names) |local_name| try writeString(writer, local_name);
    }
}

/// Read the trailing debug section, patching each already-decoded function's
/// `debug_locations`/`local_names` in place (functions must be in serialized
/// order). Returns the module source-file string table. Only called for
/// KBCD-and-later containers; earlier ones skip it and leave everything empty.
pub fn readDebugSection(
    allocator: std.mem.Allocator,
    reader: anytype,
    functions: []Function,
) ![]const []const u8 {
    const file_count = try reader.takeInt(u32, .little);
    const source_files = try allocator.alloc([]const u8, file_count);
    for (0..file_count) |index| source_files[index] = try readString(allocator, reader);

    for (functions) |*function_decl| {
        const location_count = try reader.takeInt(u32, .little);
        const locations = try allocator.alloc(SourceLoc, location_count);
        for (0..location_count) |index| locations[index] = .{
            .file_id = try reader.takeInt(u32, .little),
            .start = try reader.takeInt(u32, .little),
            .end = try reader.takeInt(u32, .little),
        };
        function_decl.debug_locations = locations;

        const name_count = try reader.takeInt(u32, .little);
        const local_names = try allocator.alloc([]const u8, name_count);
        for (0..name_count) |index| local_names[index] = try readString(allocator, reader);
        function_decl.local_names = local_names;
    }

    return source_files;
}
