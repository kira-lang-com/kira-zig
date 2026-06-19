const std = @import("std");
const macros = @import("ffi_autobind_macros.zig");

pub const Api = enum {
    generic,
    vulkan,
    directx12,
};

pub const ApiSource = struct {
    api: Api = .generic,
    headers: []const []const u8 = &.{},
    version: ?[]const u8 = null,
    extensions: []const []const u8 = &.{},
};

pub const BindingTarget = struct {
    api: Api = .generic,
    operating_system: ?[]const u8 = null,
    architecture: ?[]const u8 = null,
    abi: Abi = .c,
};

pub const Abi = enum {
    c,
    stdcall,
    win64,
    system,
};

pub const DeclarationKind = enum {
    function,
    record,
    enumeration,
    flags,
    handle,
    constant,
    callback,
    alias,
    native_pointer,
    opaque_native,
};

pub const HandleKind = enum {
    dispatchable,
    non_dispatchable,
    com_interface,
    opaque_pointer,
};

pub const PointerKind = enum {
    opaque_pointer,
    typed,
    native_buffer,
    callback,
};

pub const Ownership = enum {
    borrowed,
    transferred,
    retained,
    unknown,
};

pub const Lifetime = enum {
    static,
    caller,
    callee,
    chained,
    unknown,
};

pub const Nullability = enum {
    nonnull,
    nullable,
    unknown,
};

pub const ApiAvailability = struct {
    version: ?[]const u8 = null,
    extension: ?[]const u8 = null,
    platforms: []const []const u8 = &.{},
};

pub const TypeRef = struct {
    c_text: []const u8,
    kira_name: ?[]const u8 = null,
    declaration: DeclarationKind = .alias,
    pointer: ?PointerKind = null,
    handle: ?HandleKind = null,
    abi: Abi = .c,
    ownership: Ownership = .unknown,
    lifetime: Lifetime = .unknown,
    nullability: Nullability = .unknown,
    availability: ApiAvailability = .{},
};

pub const CParam = struct {
    name: []const u8,
    qual_type: []const u8,
    ty: ?TypeRef = null,
};

pub const CFunction = struct {
    name: []const u8,
    return_type: []const u8,
    params: []const CParam,
    abi: Abi = .c,
    result_metadata: ?[]const u8 = null,
    availability: ApiAvailability = .{},
};

pub const CField = struct {
    name: []const u8,
    qual_type: []const u8,
    ty: ?TypeRef = null,
    offset_bits: ?u32 = null,
    size_bits: ?u32 = null,
};

pub const CEnumItem = struct {
    name: []const u8,
    value: i64,
};

pub const CEnum = struct {
    name: []const u8,
    items: []const CEnumItem,
    flags: bool = false,
    backing_type: ?[]const u8 = null,
};

pub const CRecord = struct {
    name: []const u8,
    fields: []const CField,
    abi_layout: AbiLayout = .{},
    availability: ApiAvailability = .{},
};

pub const AbiLayout = struct {
    size_bits: ?u32 = null,
    alignment_bits: ?u32 = null,
    is_packed: bool = false,
    is_opaque: bool = false,
};

pub const CTypedef = struct {
    name: []const u8,
    qual_type: []const u8,
    kind: Kind,
    callback_params: []const []const u8 = &.{},
    callback_result: ?[]const u8 = null,
    array_element_type: ?[]const u8 = null,
    array_count: usize = 0,
    ty: ?TypeRef = null,

    pub const Kind = enum {
        alias,
        array,
        callback,
    };
};

pub const ArrayTypeInfo = struct {
    name: []const u8,
    element_type: []const u8,
    count: usize,
};

pub const AstIndex = struct {
    source: ApiSource = .{},
    functions: std.StringHashMapUnmanaged(CFunction) = .{},
    enums: std.StringHashMapUnmanaged(CEnum) = .{},
    records: std.StringHashMapUnmanaged(CRecord) = .{},
    typedefs: std.StringHashMapUnmanaged(CTypedef) = .{},
    macros: std.StringHashMapUnmanaged(macros.CMacro) = .{},
};

pub const BindingDiagnostic = struct {
    declaration: []const u8,
    message: []const u8,
    unsafe: bool = false,
};

pub const BindingModel = struct {
    source: ApiSource,
    target: BindingTarget,
    functions: []const CFunction = &.{},
    records: []const CRecord = &.{},
    enums: []const CEnum = &.{},
    typedefs: []const CTypedef = &.{},
    diagnostics: []const BindingDiagnostic = &.{},

    pub fn fromIndex(allocator: std.mem.Allocator, index: AstIndex, target: BindingTarget) !BindingModel {
        return .{
            .source = index.source,
            .target = target,
            .functions = try values(CFunction, allocator, index.functions),
            .records = try values(CRecord, allocator, index.records),
            .enums = try values(CEnum, allocator, index.enums),
            .typedefs = try values(CTypedef, allocator, index.typedefs),
        };
    }

    pub fn hasLargeGraphicsApiShape(self: BindingModel) bool {
        return self.target.api == .vulkan or self.target.api == .directx12;
    }
};

fn values(comptime T: type, allocator: std.mem.Allocator, map: anytype) ![]const T {
    var list = std.array_list.Managed(T).init(allocator);
    var iterator = map.iterator();
    while (iterator.next()) |entry| try list.append(entry.value_ptr.*);
    return list.toOwnedSlice();
}

test "models vulkan handles flags callbacks and chained descriptor records" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var index = AstIndex{ .source = .{ .api = .vulkan, .headers = &.{"vulkan_core.h"} } };
    try index.typedefs.put(allocator, "VkInstance", .{
        .name = "VkInstance",
        .qual_type = "struct VkInstance_T *",
        .kind = .alias,
        .ty = .{ .c_text = "struct VkInstance_T *", .declaration = .handle, .handle = .dispatchable, .ownership = .borrowed, .nullability = .nonnull },
    });
    try index.enums.put(allocator, "VkPipelineStageFlagBits", .{
        .name = "VkPipelineStageFlagBits",
        .items = &.{.{ .name = "VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT", .value = 1 }},
        .flags = true,
        .backing_type = "uint32_t",
    });
    try index.typedefs.put(allocator, "PFN_vkAllocationFunction", .{
        .name = "PFN_vkAllocationFunction",
        .qual_type = "void *(*)(void *, size_t, size_t, int)",
        .kind = .callback,
        .callback_result = "void *",
        .callback_params = &.{ "void *", "size_t", "size_t", "int" },
    });
    try index.records.put(allocator, "VkDeviceCreateInfo", .{
        .name = "VkDeviceCreateInfo",
        .fields = &.{
            .{ .name = "sType", .qual_type = "VkStructureType" },
            .{ .name = "pNext", .qual_type = "const void *", .ty = .{ .c_text = "const void *", .declaration = .native_pointer, .pointer = .opaque_pointer, .lifetime = .chained, .nullability = .nullable } },
        },
    });

    const model = try BindingModel.fromIndex(allocator, index, .{ .api = .vulkan });
    try std.testing.expect(model.hasLargeGraphicsApiShape());
    try std.testing.expectEqual(@as(usize, 1), model.records.len);
    try std.testing.expect(model.enums[0].flags);
}

test "models dx12 com pointers hresult results and platform availability" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var index = AstIndex{ .source = .{ .api = .directx12, .headers = &.{"d3d12.h"} } };
    try index.typedefs.put(allocator, "HRESULT", .{
        .name = "HRESULT",
        .qual_type = "long",
        .kind = .alias,
        .ty = .{ .c_text = "long", .kira_name = "I32", .declaration = .alias },
    });
    try index.records.put(allocator, "ID3D12Device", .{
        .name = "ID3D12Device",
        .fields = &.{.{ .name = "lpVtbl", .qual_type = "ID3D12DeviceVtbl *" }},
        .abi_layout = .{ .is_opaque = true },
        .availability = .{ .platforms = &.{"windows"} },
    });
    try index.functions.put(allocator, "D3D12CreateDevice", .{
        .name = "D3D12CreateDevice",
        .return_type = "HRESULT",
        .params = &.{
            .{ .name = "pAdapter", .qual_type = "IUnknown *", .ty = .{ .c_text = "IUnknown *", .declaration = .handle, .handle = .com_interface, .nullability = .nullable } },
            .{ .name = "ppDevice", .qual_type = "void **", .ty = .{ .c_text = "void **", .declaration = .native_pointer, .pointer = .opaque_pointer, .ownership = .transferred } },
        },
    });

    const model = try BindingModel.fromIndex(allocator, index, .{ .api = .directx12, .operating_system = "windows", .abi = .win64 });
    try std.testing.expect(model.hasLargeGraphicsApiShape());
    try std.testing.expectEqualStrings("D3D12CreateDevice", model.functions[0].name);
    try std.testing.expect(model.records[0].abi_layout.is_opaque);
}
