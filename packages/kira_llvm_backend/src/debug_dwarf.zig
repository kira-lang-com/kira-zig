//! Real DWARF debug-info emission for the LLVM C-API backend.
//!
//! This drives LLVM's DIBuilder to attach a compile unit, per-source DIFiles, a
//! DISubprogram per lowered function, per-instruction `!dbg` source locations
//! (byte offset -> line:column via an on-disk `kira_source.LineMap`), and
//! `dbg.declare` records for entry-block local allocas. The result is genuine
//! DWARF in the emitted object/executable (verifiable with `llvm-dwarfdump`),
//! not a stub.
//!
//! Everything here is best-effort and degradable: if the loaded LLVM-C runtime
//! is missing part of the DIBuilder surface (see `llvm_c.Api.hasDebugInfo` /
//! `hasDbgDeclare`), `tryInit` returns null (whole feature off) or the
//! individual helper no-ops (that feature off), always with a diagnostic, so a
//! trimmed toolchain degrades debug info instead of breaking the native build.

const std = @import("std");
const ir = @import("kira_ir");
const source = @import("kira_source");
const llvm = @import("llvm_c.zig");

// DWARF attribute encoding for a signed integer (DW_ATE_signed). Used for the
// single synthetic `i64` basic type every local/subprogram references — line
// tables and `dbg.declare` need a type, and Kira's register ABI is i64-wide.
const DW_ATE_signed: c_uint = 0x05;

// Cap on a source file we read to build a line map. Matches
// kira_source.max_source_file_bytes.
const max_source_bytes = source.max_source_file_bytes;

// Key used for spans that carry no source path (synthesized functions, async
// rewrites). A single placeholder DIFile absorbs them.
const unknown_path = "<kira-unknown>";

pub const DwarfBuilder = struct {
    allocator: std.mem.Allocator,
    api: *const llvm.Api,
    context: llvm.c.LLVMContextRef,
    module_ref: llvm.c.LLVMModuleRef,
    di: llvm.c.LLVMDIBuilderRef,
    compile_unit: llvm.c.LLVMMetadataRef,

    // source_path (owned dupe) -> DIFile + optional on-disk line map.
    files: std.StringHashMapUnmanaged(FileEntry) = .{},
    // Lazily-created shared `i64` basic type.
    int_type: ?llvm.c.LLVMMetadataRef = null,

    const FileEntry = struct {
        di_file: llvm.c.LLVMMetadataRef,
        // Present only when the source file was readable at codegen time; used to
        // map a byte offset to line:column. Null => unreadable, lines report 0.
        line_map: ?source.LineMap = null,
        text: ?[]u8 = null,
    };

    /// What `attachFunction` produced: the DISubprogram scope for the function's
    /// instructions/locals, its DIFile, its declaration line, and the source
    /// path that file came from (used to resolve later per-instruction spans).
    pub const Attached = struct {
        scope: llvm.c.LLVMMetadataRef,
        file: llvm.c.LLVMMetadataRef,
        line: c_uint,
        source_path: ?[]const u8,
    };

    /// Create the DIBuilder, compile unit, and module flags for `program`, or
    /// return null (with a diagnostic) if the toolchain can't emit DWARF.
    pub fn tryInit(
        allocator: std.mem.Allocator,
        api: *const llvm.Api,
        module_ref: llvm.c.LLVMModuleRef,
        context: llvm.c.LLVMContextRef,
        program: *const ir.Program,
    ) ?DwarfBuilder {
        if (!api.hasDebugInfo()) {
            std.debug.print("kira llvm backend: DWARF surface unavailable in this LLVM-C runtime; debug info disabled\n", .{});
            return null;
        }

        // The dbg.declare records API (LLVM 22) needs the module in "new debug
        // info format". Harmless where it is already the default.
        if (api.LLVMSetIsNewDbgInfoFormat) |set_fmt| set_fmt(module_ref, 1);

        const di = (api.LLVMCreateDIBuilder.?)(module_ref);

        var self = DwarfBuilder{
            .allocator = allocator,
            .api = api,
            .context = context,
            .module_ref = module_ref,
            .di = di,
            .compile_unit = undefined,
        };

        // Module flags LLVM requires so the verifier keeps (and the emitter
        // writes) the debug info: version 3 metadata + a DWARF version.
        self.addI32ModuleFlag("Debug Info Version", 3);
        self.addI32ModuleFlag("Dwarf Version", 4);

        // The compile unit needs a primary DIFile: the first source path any
        // function location carries, else the placeholder.
        const primary_path = choosePrimaryPath(program);
        const primary_file = self.fileFor(primary_path);

        const producer = "kira";
        self.compile_unit = (api.LLVMDIBuilderCreateCompileUnit.?)(
            di,
            llvm.c.LLVMDWARFSourceLanguageC99,
            primary_file,
            producer,
            producer.len,
            1, // isOptimized: the native object is built at -O2 by default.
            "", // Flags
            0,
            0, // RuntimeVer
            "", // SplitName
            0,
            llvm.c.LLVMDWARFEmissionFull,
            0, // DWOId
            1, // SplitDebugInlining
            0, // DebugInfoForProfiling
            "", // SysRoot
            0,
            "", // SDK
            0,
        );

        return self;
    }

    pub fn deinit(self: *DwarfBuilder) void {
        var it = self.files.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.line_map) |lm| lm.deinit(self.allocator);
            if (entry.value_ptr.text) |t| self.allocator.free(t);
            self.allocator.free(entry.key_ptr.*);
        }
        self.files.deinit(self.allocator);
        if (self.api.LLVMDisposeDIBuilder) |dispose| dispose(self.di);
    }

    /// Resolve every temporary/forward metadata node. Must run before the module
    /// is printed/emitted/verified.
    pub fn finalize(self: *DwarfBuilder) void {
        (self.api.LLVMDIBuilderFinalize.?)(self.di);
    }

    fn addI32ModuleFlag(self: *DwarfBuilder, key: []const u8, value: c_ulonglong) void {
        const api = self.api;
        const i32_ty = api.LLVMInt32TypeInContext(self.context);
        const const_val = api.LLVMConstInt(i32_ty, value, 0);
        const md = (api.LLVMValueAsMetadata.?)(const_val);
        (api.LLVMAddModuleFlag.?)(
            self.module_ref,
            llvm.c.LLVMModuleFlagBehaviorWarning,
            key.ptr,
            key.len,
            md,
        );
    }

    fn intType(self: *DwarfBuilder) llvm.c.LLVMMetadataRef {
        if (self.int_type) |t| return t;
        const name = "i64";
        const t = (self.api.LLVMDIBuilderCreateBasicType.?)(
            self.di,
            name,
            name.len,
            64,
            DW_ATE_signed,
            llvm.c.LLVMDIFlagZero,
        );
        self.int_type = t;
        return t;
    }

    /// Get-or-create the DIFile for `path` (null => the shared placeholder). The
    /// on-disk file is read once to build a LineMap; unreadable files still get a
    /// DIFile (so scopes resolve) but report line 0.
    pub fn fileFor(self: *DwarfBuilder, path: ?[]const u8) llvm.c.LLVMMetadataRef {
        const key = path orelse unknown_path;
        if (self.files.get(key)) |entry| return entry.di_file;

        const base = std.fs.path.basename(key);
        const dir = std.fs.path.dirname(key) orelse ".";
        const di_file = (self.api.LLVMDIBuilderCreateFile.?)(
            self.di,
            base.ptr,
            base.len,
            dir.ptr,
            dir.len,
        );

        var entry = FileEntry{ .di_file = di_file };
        if (path) |real_path| {
            if (readLineMap(self.allocator, real_path)) |loaded| {
                entry.text = loaded.text;
                entry.line_map = loaded.line_map;
            } else {
                std.debug.print("kira llvm backend: could not read '{s}' for debug line table; lines report 0\n", .{real_path});
            }
        }

        const owned_key = self.allocator.dupe(u8, key) catch return di_file;
        self.files.put(self.allocator, owned_key, entry) catch {
            self.allocator.free(owned_key);
            if (entry.line_map) |lm| lm.deinit(self.allocator);
            if (entry.text) |t| self.allocator.free(t);
        };
        return di_file;
    }

    /// Byte offset -> line:column for `span`, using the file named by the span
    /// (else `preferred_path`). Unknown offset / unreadable file / `{0,0}` span
    /// all yield line 0 (the debugger's "no location" sentinel).
    pub fn lineColumnFor(self: *DwarfBuilder, preferred_path: ?[]const u8, span: source.Span) source.LineColumn {
        if (span.start == 0 and span.end == 0) return .{ .line = 0, .column = 0 };
        const path = span.source_path orelse preferred_path orelse return .{ .line = 0, .column = 0 };
        // Ensure the file (and its line map) is loaded.
        _ = self.fileFor(path);
        const entry = self.files.get(path) orelse return .{ .line = 0, .column = 0 };
        const line_map = entry.line_map orelse return .{ .line = 0, .column = 0 };
        return line_map.lineColumn(span.start);
    }

    /// Create + attach a DISubprogram for `function_decl` on `fn_value`. Returns
    /// the scope/file/line callers thread through per-instruction locations and
    /// `dbg.declare`. Line comes from the function's first source location.
    pub fn attachFunction(
        self: *DwarfBuilder,
        function_decl: ir.Function,
        fn_value: llvm.c.LLVMValueRef,
    ) Attached {
        var path: ?[]const u8 = null;
        var line: c_uint = 0;
        if (function_decl.locations.len > 0) {
            const first = function_decl.locations[0];
            path = first.source_path;
            const lc = self.lineColumnFor(path, first);
            line = @intCast(lc.line);
        }
        const file = self.fileFor(path);

        // Minimal `void()` subroutine type: a single null element is the DWARF
        // convention for an unspecified/void return with no parameters. Line
        // tables and breakpoints only need the subprogram to exist and carry a
        // file+line, not a full parameter type list.
        var param_types = [_]llvm.c.LLVMMetadataRef{null};
        const subroutine = (self.api.LLVMDIBuilderCreateSubroutineType.?)(
            self.di,
            file,
            &param_types,
            @intCast(param_types.len),
            llvm.c.LLVMDIFlagZero,
        );

        const name = function_decl.name;
        const scope = (self.api.LLVMDIBuilderCreateFunction.?)(
            self.di,
            self.compile_unit,
            name.ptr,
            name.len,
            name.ptr, // linkage name: reuse the display name
            name.len,
            file,
            line,
            subroutine,
            0, // IsLocalToUnit
            1, // IsDefinition
            line, // ScopeLine
            llvm.c.LLVMDIFlagZero,
            1, // IsOptimized
        );
        (self.api.LLVMSetSubprogram.?)(fn_value, scope);

        return .{ .scope = scope, .file = file, .line = line, .source_path = path };
    }

    /// Set the builder's current `!dbg` location. Every IR value emitted after
    /// this inherits it, which is how a single source instruction tags all the
    /// LLVM it lowers to. `scope` must be the enclosing DISubprogram.
    pub fn setLocation(
        self: *DwarfBuilder,
        builder: llvm.c.LLVMBuilderRef,
        scope: llvm.c.LLVMMetadataRef,
        line: c_uint,
        column: c_uint,
    ) void {
        const loc = (self.api.LLVMDIBuilderCreateDebugLocation.?)(self.context, line, column, scope, null);
        (self.api.LLVMSetCurrentDebugLocation2.?)(builder, loc);
    }

    /// Clear the builder's current `!dbg` location. Required before building IR
    /// for a function WITHOUT a subprogram on the same shared builder (support
    /// helpers, dispatchers, host main): otherwise that IR inherits the previous
    /// function's scope, an invalid cross-function attachment the verifier rejects.
    pub fn clearLocation(self: *DwarfBuilder, builder: llvm.c.LLVMBuilderRef) void {
        (self.api.LLVMSetCurrentDebugLocation2.?)(builder, null);
    }

    /// Emit a `dbg.declare` record for an entry-block local alloca. The variable
    /// name is the slot index. No-op (with the feature already diagnosed at load)
    /// when the records API is unavailable.
    pub fn declareLocal(
        self: *DwarfBuilder,
        scope: llvm.c.LLVMMetadataRef,
        file: llvm.c.LLVMMetadataRef,
        storage: llvm.c.LLVMValueRef,
        block: llvm.c.LLVMBasicBlockRef,
        slot_index: usize,
        line: c_uint,
    ) void {
        const api = self.api;
        if (!api.hasDbgDeclare()) return;

        var name_buf: [24]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "{d}", .{slot_index}) catch return;

        const var_md = (api.LLVMDIBuilderCreateAutoVariable.?)(
            self.di,
            scope,
            name.ptr,
            name.len,
            file,
            line,
            self.intType(),
            1, // AlwaysPreserve: keep through -O2 so the local stays inspectable.
            llvm.c.LLVMDIFlagZero,
            0, // AlignInBits
        );
        const expr = (api.LLVMDIBuilderCreateExpression.?)(self.di, null, 0);
        const loc = (api.LLVMDIBuilderCreateDebugLocation.?)(self.context, line, 0, scope, null);
        _ = (api.LLVMDIBuilderInsertDeclareRecordAtEnd.?)(self.di, storage, var_md, expr, loc, block);
    }
};

const LoadedFile = struct {
    text: []u8,
    line_map: source.LineMap,
};

// Read `path` (absolute or cwd-relative) and build a LineMap, or null if the
// file can't be read. `cwd().readFileAlloc` accepts an absolute path (it maps to
// openFileAbsolute), so both forms work.
fn readLineMap(allocator: std.mem.Allocator, path: []const u8) ?LoadedFile {
    const text = std.Io.Dir.cwd().readFileAlloc(
        std.Options.debug_io,
        path,
        allocator,
        .limited(max_source_bytes),
    ) catch return null;
    const line_map = source.LineMap.init(allocator, text) catch {
        allocator.free(text);
        return null;
    };
    return .{ .text = text, .line_map = line_map };
}

// First source path any function location carries, else null.
fn choosePrimaryPath(program: *const ir.Program) ?[]const u8 {
    for (program.functions) |function_decl| {
        for (function_decl.locations) |span| {
            if (span.source_path) |path| return path;
        }
    }
    return null;
}

test "readLineMap maps byte offsets to source line:column" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Three lines; byte offsets: 'a'=0 line1col1, 'b'=6 line2col1, 'c'=13 line3col2.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src.kira", .data = "alpha\nbeta\n cgamma\n" });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "src.kira", allocator);
    defer allocator.free(path);

    var loaded = readLineMap(allocator, path) orelse return error.Unreadable;
    defer {
        loaded.line_map.deinit(allocator);
        allocator.free(loaded.text);
    }

    const first = loaded.line_map.lineColumn(0);
    try std.testing.expectEqual(@as(usize, 1), first.line);
    try std.testing.expectEqual(@as(usize, 1), first.column);

    const second = loaded.line_map.lineColumn(6); // start of "beta"
    try std.testing.expectEqual(@as(usize, 2), second.line);
    try std.testing.expectEqual(@as(usize, 1), second.column);

    const third = loaded.line_map.lineColumn(12); // 'c' on the third line (after leading space)
    try std.testing.expectEqual(@as(usize, 3), third.line);
    try std.testing.expectEqual(@as(usize, 2), third.column);
}

test "readLineMap returns null for a missing file" {
    try std.testing.expect(readLineMap(std.testing.allocator, "/nonexistent/kira/source/path.kira") == null);
}

test "choosePrimaryPath returns the first location's source path" {
    var loc_with = [_]source.Span{.{ .start = 3, .end = 8, .source_path = "/proj/app/main.kira" }};
    var loc_without = [_]source.Span{.{ .start = 0, .end = 0, .source_path = null }};
    var no_instr = [_]ir.Instruction{};

    var functions = [_]ir.Function{
        .{
            .id = 0,
            .name = "synth",
            .execution = .native,
            .register_count = 0,
            .local_count = 0,
            .local_types = &.{},
            .instructions = &no_instr,
            .locations = &loc_without,
        },
        .{
            .id = 1,
            .name = "real",
            .execution = .native,
            .register_count = 0,
            .local_count = 0,
            .local_types = &.{},
            .instructions = &no_instr,
            .locations = &loc_with,
        },
    };
    const program = ir.Program{ .functions = &functions, .entry_index = 1 };
    const path = choosePrimaryPath(&program) orelse return error.NoPath;
    try std.testing.expectEqualStrings("/proj/app/main.kira", path);
}
