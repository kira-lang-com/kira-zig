const std = @import("std");
const builtin = @import("builtin");

const NativeLibrary = if (builtin.os.tag == .windows) WindowsNativeLibrary else std.DynLib;

pub const DynamicLibrary = struct {
    inner: Backend,

    const Backend = union(enum) {
        library: NativeLibrary,
        // Resolves symbols from the current process image, so statically-linked
        // native libraries (e.g. the in-process `kira_main` developer API) are
        // reachable without a standalone shared object.
        process,
    };

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !DynamicLibrary {
        if (builtin.os.tag == .windows) return .{ .inner = .{ .library = try WindowsNativeLibrary.open(allocator, path) } };
        // Normalize POSIX `std.DynLib.open` failures to the same error the Windows path
        // returns, so `DynamicLibrary.open` has one error set across platforms. Without this,
        // callers that switch on `error.NativeLibraryLoadFailed` (e.g. libffi tests) fail to
        // compile on POSIX because the error is not in std.DynLib's set.
        return .{ .inner = .{ .library = std.DynLib.open(path) catch return error.NativeLibraryLoadFailed } };
    }

    /// Opens a handle that resolves symbols from the current process image
    /// instead of a separate shared object. This lets statically-linked native
    /// libraries (such as the in-process `kira_main` developer/compiler API) be
    /// reached from VM FFI without shipping a standalone `.dylib`/`.so`/`.dll`.
    pub fn openProcess(allocator: std.mem.Allocator) !DynamicLibrary {
        _ = allocator;
        return .{ .inner = .process };
    }

    pub fn close(self: *DynamicLibrary) void {
        switch (self.inner) {
            .library => |*lib| lib.close(),
            .process => {},
        }
    }

    pub fn lookup(self: *DynamicLibrary, comptime T: type, name: []const u8) !T {
        var buffer: [256]u8 = undefined;
        if (name.len >= buffer.len) return error.SymbolNameTooLong;
        const symbol_name = try std.fmt.bufPrintZ(&buffer, "{s}", .{name});
        return switch (self.inner) {
            .library => |*lib| lib.lookup(T, symbol_name) orelse error.MissingNativeSymbol,
            .process => lookupProcess(T, symbol_name) orelse error.MissingNativeSymbol,
        };
    }

    pub fn lookupOptional(self: *DynamicLibrary, comptime T: type, name: []const u8) ?T {
        var buffer: [256]u8 = undefined;
        if (name.len >= buffer.len) return null;
        const symbol_name = std.fmt.bufPrintZ(&buffer, "{s}", .{name}) catch return null;
        return switch (self.inner) {
            .library => |*lib| lib.lookup(T, symbol_name),
            .process => lookupProcess(T, symbol_name),
        };
    }
};

/// Resolves a symbol from the current process image (statically-linked code).
fn lookupProcess(comptime T: type, name: [:0]const u8) ?T {
    if (builtin.os.tag == .windows) return WindowsNativeLibrary.lookupSelf(T, name);
    const c = @cImport({
        @cInclude("dlfcn.h");
    });
    const address = c.dlsym(c.RTLD_DEFAULT, name.ptr) orelse return null;
    return @ptrCast(@alignCast(address));
}

const WindowsNativeLibrary = struct {
    handle: std.os.windows.HMODULE,

    const LOAD_WITH_ALTERED_SEARCH_PATH = 0x00000008;
    extern "kernel32" fn LoadLibraryExW([*:0]const u16, ?std.os.windows.HANDLE, u32) callconv(.winapi) ?std.os.windows.HMODULE;
    extern "kernel32" fn FreeLibrary(std.os.windows.HMODULE) callconv(.winapi) std.os.windows.BOOL;
    extern "kernel32" fn GetProcAddress(std.os.windows.HMODULE, [*:0]const u8) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GetModuleHandleW(?[*:0]const u16) callconv(.winapi) ?std.os.windows.HMODULE;

    fn open(allocator: std.mem.Allocator, path: []const u8) !WindowsNativeLibrary {
        const path_w = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, path);
        defer allocator.free(path_w);
        const handle = LoadLibraryExW(path_w.ptr, null, LOAD_WITH_ALTERED_SEARCH_PATH) orelse return error.NativeLibraryLoadFailed;
        return .{ .handle = handle };
    }

    fn close(self: *WindowsNativeLibrary) void {
        _ = FreeLibrary(self.handle);
    }

    fn lookup(self: *WindowsNativeLibrary, comptime T: type, name: [:0]const u8) ?T {
        const address = GetProcAddress(self.handle, name.ptr) orelse return null;
        return @ptrCast(address);
    }

    fn lookupSelf(comptime T: type, name: [:0]const u8) ?T {
        const handle = GetModuleHandleW(null) orelse return null;
        const address = GetProcAddress(handle, name.ptr) orelse return null;
        return @ptrCast(address);
    }
};

test "lookup reports a missing symbol precisely" {
    const missing_path = "definitely-missing-kira-dynamic-ffi-library";
    try std.testing.expectError(error.NativeLibraryLoadFailed, DynamicLibrary.open(std.testing.allocator, missing_path));
}
