//! native_target_dwarf — source/address resolution for the native debug target.
//!
//! The native `DebugTarget` needs three DWARF-driven mappings that the hardware
//! `HwBreakpointController` cannot provide on its own:
//!
//!   1. `file:line -> address`   — to arm a source-line breakpoint.
//!   2. `address -> file:line`   — to attach a `SourcePosition` to each frame in
//!                                 a backtrace.
//!   3. `function -> address`    — to arm a function-name breakpoint.
//!
//! **Chosen strategy (documented per the task):** rather than re-implement a
//! DWARF `.debug_line` state-machine here, we shell out to the Kira toolchain's
//! `llvm-dwarfdump --debug-line` and `llvm-nm`, and parse their textual output.
//! Kira's native binaries carry real DWARF (see `kira_llvm_backend/debug_dwarf.zig`),
//! so this is a faithful mapping, not a stub. The parsers are pulled out as pure
//! functions (`parseLineTable`, `parseSymbols`) so they are unit-tested against
//! canned tool output without needing the tool present in this environment; the
//! subprocess wrappers (`loadLineTable`, `resolveFunction`) layer the exec on top.
//!
//! Tool discovery mirrors the repo's LLVM order (AGENTS.md): `KIRA_LLVM_HOME/bin`
//! first, then the bare tool name on `PATH`. If the tool is absent every lookup
//! degrades to `null` (breakpoint resolution fails with a clear error upstream)
//! rather than crashing the debugger.

const std = @import("std");
const builtin = @import("builtin");
const debug_info = @import("debug_info.zig");

const SourcePosition = debug_info.SourcePosition;

/// One decoded `.debug_line` row, with the file name already resolved to a
/// basename (so cross-compile-unit file-index tables never leak out of the
/// parser). `end_sequence` rows delimit an address range and carry no location.
pub const LineRow = struct {
    addr: u64,
    line: u32,
    column: u32,
    /// Basename of the source file for this row, owned by the table's arena.
    file: []const u8,
    end_sequence: bool,
};

/// A parsed `.debug_line` table: rows in the order the tool emitted them
/// (already address-sorted within each sequence). Owns its own arena.
pub const LineTable = struct {
    arena: std.heap.ArenaAllocator,
    rows: []const LineRow,

    pub fn deinit(self: *LineTable) void {
        self.arena.deinit();
    }

    /// Resolve a runtime address to a source position: the row that covers
    /// `[row.addr, next.addr)` within a sequence. Returns null when no row
    /// covers the address (stripped/synthetic code).
    pub fn addressToPosition(self: LineTable, addr: u64) ?SourcePosition {
        var i: usize = 0;
        while (i + 1 < self.rows.len) : (i += 1) {
            const row = self.rows[i];
            if (row.end_sequence) continue;
            const next = self.rows[i + 1];
            if (addr >= row.addr and addr < next.addr) {
                return .{ .file = row.file, .line = row.line, .column = row.column };
            }
        }
        return null;
    }

    /// Resolve a source `file:line` to the address to arm a breakpoint at.
    /// Matching is by basename. Prefers an exact line match; failing that, the
    /// row on the same file with the smallest line strictly greater than `line`
    /// (so a breakpoint on a blank/comment line lands on the next real code).
    pub fn lineToAddress(self: LineTable, file: []const u8, line: u32) ?u64 {
        const want = std.fs.path.basename(file);
        var best_next: ?LineRow = null;
        for (self.rows) |row| {
            if (row.end_sequence) continue;
            if (!std.mem.eql(u8, row.file, want)) continue;
            if (row.line == line) return row.addr;
            if (row.line > line) {
                if (best_next == null or row.line < best_next.?.line)
                    best_next = row;
            }
        }
        return if (best_next) |b| b.addr else null;
    }
};

/// A parsed symbol table: defined symbol name -> address. Owns its own arena.
pub const Symbols = struct {
    arena: std.heap.ArenaAllocator,
    map: std.StringHashMapUnmanaged(u64),

    pub fn deinit(self: *Symbols) void {
        self.arena.deinit();
    }

    /// Address of `name`, trying the bare name and the underscore-prefixed
    /// mangling Mach-O uses for C symbols (`main` -> `_main`).
    pub fn address(self: Symbols, name: []const u8) ?u64 {
        if (self.map.get(name)) |a| return a;
        var buf: [256]u8 = undefined;
        if (name.len + 1 <= buf.len) {
            buf[0] = '_';
            @memcpy(buf[1 .. name.len + 1], name);
            if (self.map.get(buf[0 .. name.len + 1])) |a| return a;
        }
        return null;
    }
};

// ---------------------------------------------------------------------------
// Pure parsers (unit-tested against canned tool output).
// ---------------------------------------------------------------------------

/// Parse the textual output of `llvm-dwarfdump --debug-line`. The row table
/// begins after a header line starting with `Address` and a dashed separator;
/// each data row is `addr line column file isa disc opindex flags...`. The
/// `file` column indexes the current compile unit's `file_names[N]` table, so we
/// track that table per `debug_line[` section and resolve each row's file name
/// (to a basename) at parse time.
pub fn parseLineTable(gpa: std.mem.Allocator, text: []const u8) !LineTable {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var rows = std.array_list.Managed(LineRow).init(a);
    // Current compile unit's file table: index -> basename.
    var files = std.array_list.Managed([]const u8).init(a);
    var in_rows = false;

    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        const trimmed = std.mem.trim(u8, line, " \t");

        // A new line program resets the file table and leaves the row section.
        if (std.mem.startsWith(u8, trimmed, "debug_line[")) {
            files.clearRetainingCapacity();
            in_rows = false;
            continue;
        }

        // `file_names[  N]:` header — remember N; the following `name:` line
        // carries the basename.
        if (std.mem.startsWith(u8, trimmed, "file_names[")) {
            const idx = parseBracketIndex(trimmed) orelse continue;
            // Grow the table to hold index `idx`.
            while (files.items.len <= idx) try files.append("");
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "name:")) {
            const name = parseQuoted(trimmed) orelse continue;
            if (files.items.len > 0) {
                const base = std.fs.path.basename(name);
                files.items[files.items.len - 1] = try a.dupe(u8, base);
            }
            continue;
        }

        // The row header switches us into row-parsing mode.
        if (std.mem.startsWith(u8, trimmed, "Address") and
            std.mem.indexOf(u8, trimmed, "Line") != null)
        {
            in_rows = true;
            continue;
        }
        if (!in_rows) continue;
        // Dashed separator under the header.
        if (trimmed.len == 0 or trimmed[0] == '-') continue;
        if (!std.mem.startsWith(u8, trimmed, "0x")) {
            in_rows = false;
            continue;
        }

        const row = parseRow(trimmed, files.items) catch continue;
        try rows.append(row);
    }

    return .{ .arena = arena, .rows = try rows.toOwnedSlice() };
}

/// Parse one `.debug_line` data row. Columns are whitespace-separated; only the
/// first four (address, line, column, file-index) are numeric and needed, and
/// the trailing free-form flags may contain `end_sequence`.
fn parseRow(line: []const u8, files: []const []const u8) !LineRow {
    var fields = std.mem.tokenizeAny(u8, line, " \t");
    const addr_s = fields.next() orelse return error.BadRow;
    const line_s = fields.next() orelse return error.BadRow;
    const col_s = fields.next() orelse return error.BadRow;
    const file_s = fields.next() orelse return error.BadRow;

    const addr = try std.fmt.parseInt(u64, stripHexPrefix(addr_s), 16);
    const line_no = try std.fmt.parseInt(u32, line_s, 10);
    const col = std.fmt.parseInt(u32, col_s, 10) catch 0;
    const file_idx = std.fmt.parseInt(usize, file_s, 10) catch 0;

    const file: []const u8 = if (file_idx < files.len and files[file_idx].len > 0)
        files[file_idx]
    else
        "";
    const end_seq = std.mem.indexOf(u8, line, "end_sequence") != null;
    return .{ .addr = addr, .line = line_no, .column = col, .file = file, .end_sequence = end_seq };
}

/// Parse `llvm-nm` output lines of the form `<hexaddr> <type> <name>`; symbols
/// with no address (undefined `U`, common) are skipped.
pub fn parseSymbols(gpa: std.mem.Allocator, text: []const u8) !Symbols {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var map: std.StringHashMapUnmanaged(u64) = .{};

    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, std.mem.trimEnd(u8, raw, "\r"), " \t");
        if (line.len == 0) continue;
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const addr_s = fields.next() orelse continue;
        const type_s = fields.next() orelse continue;
        const name_s = fields.next() orelse continue;
        _ = type_s;
        const addr = std.fmt.parseInt(u64, addr_s, 16) catch continue;
        try map.put(a, try a.dupe(u8, name_s), addr);
    }

    return .{ .arena = arena, .map = map };
}

// ---------------------------------------------------------------------------
// Small text helpers.
// ---------------------------------------------------------------------------

fn stripHexPrefix(s: []const u8) []const u8 {
    if (std.mem.startsWith(u8, s, "0x") or std.mem.startsWith(u8, s, "0X"))
        return s[2..];
    return s;
}

/// Extract N from `file_names[  N]:` (or any `xxx[  N]`).
fn parseBracketIndex(s: []const u8) ?usize {
    const open = std.mem.indexOfScalar(u8, s, '[') orelse return null;
    const close = std.mem.indexOfScalarPos(u8, s, open, ']') orelse return null;
    const inner = std.mem.trim(u8, s[open + 1 .. close], " \t");
    return std.fmt.parseInt(usize, inner, 10) catch null;
}

/// Extract the first double-quoted substring from `line` (e.g. `name: "foo.c"`).
fn parseQuoted(s: []const u8) ?[]const u8 {
    const first = std.mem.indexOfScalar(u8, s, '"') orelse return null;
    const second = std.mem.indexOfScalarPos(u8, s, first + 1, '"') orelse return null;
    return s[first + 1 .. second];
}

// ---------------------------------------------------------------------------
// Subprocess wrappers (tool discovery + exec).
// ---------------------------------------------------------------------------

const max_tool_output: usize = 64 * 1024 * 1024;

/// Resolve a toolchain executable. Search order: `tool_dir/<tool>` (the LLVM bin
/// directory the CLI resolved for *this* build — the managed
/// `~/.kira/toolchains/llvm/...` install is here, not on `PATH`), then
/// `KIRA_LLVM_HOME/bin/<tool>`, then the bare name (found on `PATH` at exec
/// time). Without `tool_dir` the managed toolchain is invisible and every lookup
/// fails on a machine that has no system LLVM, so line breakpoints never resolve.
/// Caller owns the returned slice.
fn toolPath(gpa: std.mem.Allocator, tool: []const u8, tool_dir: ?[]const u8) ![]const u8 {
    if (tool_dir) |dir| {
        if (dir.len != 0) {
            if (existingToolPath(gpa, dir, tool)) |path| return path;
        }
    }
    // kira_debug links libc; `std.c.getenv` is the repo-wide env accessor (Zig 0.16
    // dropped `std.process.getEnvVarOwned` from this build's std).
    if (std.c.getenv("KIRA_LLVM_HOME")) |home_ptr| {
        const home = std.mem.span(home_ptr);
        if (home.len != 0) {
            const bin = try std.fs.path.join(gpa, &.{ home, "bin" });
            defer gpa.free(bin);
            if (existingToolPath(gpa, bin, tool)) |path| return path;
        }
    }
    return gpa.dupe(u8, tool);
}

/// Join `dir/tool` and return it (caller-owned) only when the file exists,
/// otherwise free the candidate and return null so the next fallback is tried.
fn existingToolPath(gpa: std.mem.Allocator, dir: []const u8, tool: []const u8) ?[]const u8 {
    const candidate = std.fs.path.join(gpa, &.{ dir, tool }) catch return null;
    if (std.Io.Dir.cwd().access(std.Options.debug_io, candidate, .{})) |_| {
        return candidate;
    } else |_| {
        gpa.free(candidate);
        return null;
    }
}

/// The child (`llvm-dwarfdump`/`llvm-nm`) must inherit our environment so it finds
/// its own shared libs and honors `PATH` when `toolPath` returned a bare name.
fn processEnviron() std.process.Environ {
    return switch (builtin.os.tag) {
        .windows => .{ .block = .global },
        .wasi, .emscripten, .freestanding, .other => .empty,
        else => .{ .block = .{ .slice = posixEnvironBlock() } },
    };
}

fn posixEnvironBlock() [:null]const ?[*:0]const u8 {
    if (!builtin.link_libc) return &.{};
    const environ = std.c.environ;
    var len: usize = 0;
    while (environ[len] != null) : (len += 1) {}
    return environ[0..len :null];
}

/// Run `argv` and return captured stdout (caller owns). Returns null when the
/// tool cannot be spawned or exits non-zero. Zig 0.16 replaced `Child.run` with
/// `std.process.run` over an explicit `Io`.
fn runCapture(gpa: std.mem.Allocator, argv: []const []const u8) ?[]u8 {
    var io_impl: std.Io.Threaded = .init(gpa, .{ .environ = processEnviron() });
    defer io_impl.deinit();
    const result = std.process.run(gpa, io_impl.io(), .{
        .argv = argv,
        .stdout_limit = .limited(max_tool_output),
        .stderr_limit = .limited(max_tool_output),
    }) catch return null;
    gpa.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) {
            gpa.free(result.stdout);
            return null;
        },
        else => {
            gpa.free(result.stdout);
            return null;
        },
    }
    return result.stdout;
}

/// Resolve the object that actually carries DWARF for `binary`. On macOS the
/// linker leaves `.debug_line` in the object files and `dsymutil` collects it
/// into a companion `<binary>.dSYM` bundle — the executable's own Mach-O has no
/// `.debug_line` section, so pointing `llvm-dwarfdump` at it yields an empty
/// table. When the sibling bundle exists we hand the tool the bundle instead
/// (llvm-dwarfdump accepts the `.dSYM` directory directly, and its row
/// addresses match the linked image, so `+ load_bias` still holds). On
/// ELF/COFF targets DWARF lives in the binary itself, so the bundle never
/// exists and we fall through to `binary` unchanged. Caller owns the result.
fn dwarfObjectPath(gpa: std.mem.Allocator, binary: []const u8) ![]const u8 {
    const dsym = try std.fmt.allocPrint(gpa, "{s}.dSYM", .{binary});
    // `binary` is argv[0], which may be cwd-relative; `Dir.cwd().access` handles
    // both relative and absolute paths and succeeds on the `.dSYM` directory.
    if (std.Io.Dir.cwd().access(std.Options.debug_io, dsym, .{})) |_| {
        return dsym;
    } else |_| {
        gpa.free(dsym);
        return gpa.dupe(u8, binary);
    }
}

/// Load the `.debug_line` table for `binary` via `llvm-dwarfdump --debug-line`.
/// Returns null when the tool is unavailable or the binary has no line table.
/// The DWARF is read from the `.dSYM` companion on macOS (see `dwarfObjectPath`).
pub fn loadLineTable(gpa: std.mem.Allocator, binary: []const u8, tool_dir: ?[]const u8) ?LineTable {
    const tool = toolPath(gpa, "llvm-dwarfdump", tool_dir) catch return null;
    defer gpa.free(tool);
    const object = dwarfObjectPath(gpa, binary) catch return null;
    defer gpa.free(object);
    const out = runCapture(gpa, &.{ tool, "--debug-line", object }) orelse return null;
    defer gpa.free(out);
    return parseLineTable(gpa, out) catch null;
}

/// Load the defined-symbol table for `binary` via `llvm-nm`. Returns null when
/// the tool is unavailable. Symbols live in the executable's own symbol table,
/// so this reads `binary` directly (no `.dSYM` indirection).
pub fn loadSymbols(gpa: std.mem.Allocator, binary: []const u8, tool_dir: ?[]const u8) ?Symbols {
    const tool = toolPath(gpa, "llvm-nm", tool_dir) catch return null;
    defer gpa.free(tool);
    const out = runCapture(gpa, &.{ tool, "--defined-only", binary }) orelse return null;
    defer gpa.free(out);
    return parseSymbols(gpa, out) catch null;
}

// ---------------------------------------------------------------------------
// Tests — parser logic against canned tool output.
// ---------------------------------------------------------------------------

const testing = std.testing;

const sample_debug_line =
    \\.debug_line contents:
    \\debug_line[0x00000000]
    \\Line table prologue:
    \\    total_length: 0x00000050
    \\         version: 5
    \\file_names[  0]:
    \\           name: "main.kira"
    \\      dir_index: 0
    \\file_names[  1]:
    \\           name: "/abs/path/util.kira"
    \\      dir_index: 1
    \\
    \\Address            Line   Column File   ISA Discriminator OpIndex Flags
    \\------------------ ------ ------ ------ --- ------------- ------- -------
    \\0x0000000100003f9c     10      0      0   0             0       0  is_stmt
    \\0x0000000100003fa4     11      5      0   0             0       0  is_stmt
    \\0x0000000100003fb0      7      3      1   0             0       0  is_stmt
    \\0x0000000100003fc0      0      0      1   0             0       0  is_stmt end_sequence
    \\
;

test "parseLineTable resolves file indices to basenames and keeps rows" {
    var tbl = try parseLineTable(testing.allocator, sample_debug_line);
    defer tbl.deinit();

    try testing.expectEqual(@as(usize, 4), tbl.rows.len);
    try testing.expectEqual(@as(u64, 0x100003f9c), tbl.rows[0].addr);
    try testing.expectEqual(@as(u32, 10), tbl.rows[0].line);
    try testing.expectEqualStrings("main.kira", tbl.rows[0].file);
    // Index 1 pointed at an absolute path; the parser keeps only the basename.
    try testing.expectEqualStrings("util.kira", tbl.rows[2].file);
    try testing.expect(tbl.rows[3].end_sequence);
}

test "addressToPosition covers the row's address range" {
    var tbl = try parseLineTable(testing.allocator, sample_debug_line);
    defer tbl.deinit();

    // Exactly on the first row.
    const p0 = tbl.addressToPosition(0x100003f9c).?;
    try testing.expectEqual(@as(u32, 10), p0.line);
    // Between row 0 and row 1 still resolves to row 0's line.
    const p_mid = tbl.addressToPosition(0x100003fa0).?;
    try testing.expectEqual(@as(u32, 10), p_mid.line);
    // Inside row 1.
    const p1 = tbl.addressToPosition(0x100003fa8).?;
    try testing.expectEqual(@as(u32, 11), p1.line);
    // Row on the second file.
    const p2 = tbl.addressToPosition(0x100003fb4).?;
    try testing.expectEqualStrings("util.kira", p2.file);
    try testing.expectEqual(@as(u32, 7), p2.line);
    // Past the end sequence -> unresolved.
    try testing.expectEqual(@as(?SourcePosition, null), tbl.addressToPosition(0x100004000));
}

test "lineToAddress matches by basename with exact and next-line fallback" {
    var tbl = try parseLineTable(testing.allocator, sample_debug_line);
    defer tbl.deinit();

    // Exact line, matched by basename even when caller passes a full path.
    try testing.expectEqual(@as(?u64, 0x100003fa4), tbl.lineToAddress("src/main.kira", 11));
    // A line with no row falls forward to the next code line (10) in main.kira.
    try testing.expectEqual(@as(?u64, 0x100003f9c), tbl.lineToAddress("main.kira", 5));
    // util.kira line 7.
    try testing.expectEqual(@as(?u64, 0x100003fb0), tbl.lineToAddress("util.kira", 7));
    // No such file.
    try testing.expectEqual(@as(?u64, null), tbl.lineToAddress("missing.kira", 1));
    // Past the last line of main.kira -> no forward match.
    try testing.expectEqual(@as(?u64, null), tbl.lineToAddress("main.kira", 999));
}

test "parseSymbols maps names to addresses and address() tries underscore form" {
    const nm_out =
        \\0000000100003f9c T _main
        \\0000000100003fb0 t _helper
        \\                 U _printf
        \\0000000100008000 D _global
        \\
    ;
    var syms = try parseSymbols(testing.allocator, nm_out);
    defer syms.deinit();

    try testing.expectEqual(@as(?u64, 0x100003f9c), syms.address("_main"));
    // Bare name resolves to the Mach-O `_`-prefixed symbol.
    try testing.expectEqual(@as(?u64, 0x100003f9c), syms.address("main"));
    try testing.expectEqual(@as(?u64, 0x100003fb0), syms.address("helper"));
    // Undefined symbol had no address column -> not recorded.
    try testing.expectEqual(@as(?u64, null), syms.address("printf"));
    try testing.expectEqual(@as(?u64, null), syms.address("nope"));
}

test "parsers tolerate empty and malformed input without crashing" {
    var tbl = try parseLineTable(testing.allocator, "");
    tbl.deinit();
    var tbl2 = try parseLineTable(testing.allocator, "garbage\n0xnothex 1 2 3\n");
    tbl2.deinit();
    var syms = try parseSymbols(testing.allocator, "\n\n   \n");
    syms.deinit();
}

test "dwarfObjectPath prefers a sibling .dSYM bundle when present" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &path_buf);
    const dir_path = path_buf[0..dir_len];
    const binary = try std.fs.path.join(testing.allocator, &.{ dir_path, "prog" });
    defer testing.allocator.free(binary);

    // No .dSYM yet -> resolves to the binary itself.
    const bare = try dwarfObjectPath(testing.allocator, binary);
    defer testing.allocator.free(bare);
    try testing.expectEqualStrings(binary, bare);

    // Create the companion bundle (a directory, as dsymutil emits) -> resolves to it.
    try tmp.dir.createDirPath(testing.io, "prog.dSYM");
    const resolved = try dwarfObjectPath(testing.allocator, binary);
    defer testing.allocator.free(resolved);
    try testing.expect(std.mem.endsWith(u8, resolved, "prog.dSYM"));
}

test "toolPath searches tool_dir first, then falls back to the bare name" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &path_buf);
    const dir_path = path_buf[0..dir_len];

    // Tool absent from tool_dir and (assumed) PATH -> bare fallback.
    const missing = try toolPath(testing.allocator, "kira-fake-dwarfdump", dir_path);
    defer testing.allocator.free(missing);
    try testing.expectEqualStrings("kira-fake-dwarfdump", missing);

    // Tool present in tool_dir -> the fully-qualified path wins.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "kira-fake-dwarfdump", .data = "" });
    const found = try toolPath(testing.allocator, "kira-fake-dwarfdump", dir_path);
    defer testing.allocator.free(found);
    try testing.expect(std.mem.endsWith(u8, found, "kira-fake-dwarfdump"));
    try testing.expect(std.mem.startsWith(u8, found, dir_path));
}
