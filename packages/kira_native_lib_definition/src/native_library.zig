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

pub const HeaderSpec = struct {
    entrypoint: ?[]const u8 = null,
    include_dirs: []const []const u8 = &.{},
    defines: []const []const u8 = &.{},
    frameworks: []const []const u8 = &.{},
    system_libs: []const []const u8 = &.{},
};

pub const AutobindingSpec = struct {
    module_name: []const u8,
    output_path: []const u8,
    spec_path: ?[]const u8 = null,
    headers: []const []const u8 = &.{},
};

pub const BuildRecipe = struct {
    sources: []const []const u8 = &.{},
    include_dirs: []const []const u8 = &.{},
    defines: []const []const u8 = &.{},
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
    headers: HeaderSpec = .{},
    autobinding: ?AutobindingSpec = null,
    build: BuildRecipe = .{},
    targets: []const TargetSpec,
    symbols: []const ffi.NativeSymbol = &.{},
};

pub const FfiModuleSpec = struct {
    module_name: []const u8,
    libraries: []const NativeLibrarySpec,
    symbols: []const ffi.NativeSymbol = &.{},
};
