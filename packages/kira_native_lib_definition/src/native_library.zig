const ffi = @import("ffi_symbol.zig");
const LinkExtras = @import("link_extras.zig").LinkExtras;
const TargetSelector = @import("target_resolution.zig").TargetSelector;

pub const LinkMode = enum {
    static,
    dynamic,
};

pub const LibraryAbi = enum {
    c,
};

pub const TargetSpec = struct {
    selector: TargetSelector,
    static_lib: ?[]const u8 = null,
    dynamic_lib: ?[]const u8 = null,
    link: LinkExtras = .{},
};

pub const NativeLibrarySpec = struct {
    name: []const u8,
    link_mode: LinkMode,
    abi: LibraryAbi,
    headers: LinkExtras = .{},
    targets: []const TargetSpec,
    symbols: []const ffi.NativeSymbol = &.{},
};

pub const FfiModuleSpec = struct {
    module_name: []const u8,
    libraries: []const NativeLibrarySpec,
    symbols: []const ffi.NativeSymbol = &.{},
};
