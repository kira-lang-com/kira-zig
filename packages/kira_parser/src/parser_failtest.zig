//! Parsing for the `FailTest` construct — expected-compile-outcome tests.
//!
//! `FailTest Name { backends {..} source {..} expect {..} }` is parsed with a
//! dedicated path (not the generic construct-form parser) because its `source`
//! section is QUOTED: the block's raw text is captured verbatim and never handed
//! to the enclosing package's parser/semantics. Ill-formed code inside `source`
//! (the whole point of a fail-test) must not poison the surrounding suite.
//!
//! Raw-text capture works without threading the source buffer through the parser:
//! a `{`/`}` single-character token's `lexeme` is a direct slice into the source
//! (only string tokens are decoded), so the source base pointer is recovered as
//! `lexeme.ptr - span.start` and the block interior is sliced by byte offset —
//! faithful to the original, including strings, comments, and whitespace.

const std = @import("std");
const diagnostics = @import("kira_diagnostics");
const source_pkg = @import("kira_source");
const syntax = @import("kira_syntax_model");
const parent = @import("parser.zig");
const Parser = parent.Parser;

/// True when the upcoming tokens are a `FailTest Name { ... }` declaration.
pub fn looksLikeFailTest(self: *Parser) bool {
    return self.at(.identifier) and std.mem.eql(u8, self.peek().lexeme, "FailTest") and
        self.looksLikeConstructFormDecl();
}

pub fn parseFailTestDecl(self: *Parser, annotations: []const syntax.ast.Annotation) !syntax.ast.FailTestDecl {
    const keyword = self.advance(); // `FailTest`
    const name_token = try self.expect(.identifier, "expected FailTest name", "name the FailTest here");
    _ = try self.expect(.l_brace, "expected '{' to start the FailTest body", "open the FailTest body here");

    var backends = std.array_list.Managed([]const u8).init(self.allocator);
    var source: ?syntax.ast.FailTestSource = null;
    var expect_text: ?[]const u8 = null;

    while (!self.at(.r_brace) and !self.at(.eof)) {
        const section = try self.expect(.identifier, "expected FailTest section", "write `backends`, `source`, or `expect` here");
        const sname = section.lexeme;
        if (std.mem.eql(u8, sname, "backends")) {
            try parseBackends(self, &backends);
        } else if (std.mem.eql(u8, sname, "source")) {
            source = try parseSourceSection(self);
        } else if (std.mem.eql(u8, sname, "expect")) {
            expect_text = try captureBracedRaw(self);
        } else {
            try emit(self, "KPAR022", "unknown FailTest section", section.span, "unexpected section", "A FailTest has only `backends`, `source`, and `expect` sections.");
            return error.DiagnosticsEmitted;
        }
    }
    const close = try self.expect(.r_brace, "expected '}' to close the FailTest body", "the FailTest body should end here");

    if (source == null) {
        try emit(self, "KPAR020", "FailTest requires a source section", name_token.span, "no source to compile", "Add a `source { ... }` block (or `source = \"...\"`) with the code the compiler must reject.");
        return error.DiagnosticsEmitted;
    }
    if (expect_text == null) {
        try emit(self, "KPAR021", "FailTest requires an expect section", name_token.span, "no expected outcome", "Add an `expect { let e: Result<Int, TestFailure> = Result.Error(TestFailure.Compile(\"CODE\")); return e }` block.");
        return error.DiagnosticsEmitted;
    }

    const start = if (annotations.len > 0) annotations[0].span.start else keyword.span.start;
    return .{
        .annotations = annotations,
        .name = name_token.lexeme,
        .backends = try backends.toOwnedSlice(),
        .source = source,
        .expect_text = expect_text,
        .span = source_pkg.Span.init(start, close.span.end),
    };
}

/// `backends { vm llvm hybrid }` — space-separated lowercase idents, a subset of
/// {vm, llvm, hybrid}. Each entry is validated at parse time.
fn parseBackends(self: *Parser, out: *std.array_list.Managed([]const u8)) !void {
    _ = try self.expect(.l_brace, "expected '{' after `backends`", "list the backends here");
    while (!self.at(.r_brace) and !self.at(.eof)) {
        const tok = try self.expect(.identifier, "expected a backend name", "write `vm`, `llvm`, or `hybrid`");
        const name = tok.lexeme;
        if (!std.mem.eql(u8, name, "vm") and !std.mem.eql(u8, name, "llvm") and !std.mem.eql(u8, name, "hybrid")) {
            try emit(self, "KPAR023", "unknown FailTest backend", tok.span, "not a known backend", "Declare a subset of `vm`, `llvm`, and `hybrid`.");
            return error.DiagnosticsEmitted;
        }
        try out.append(name);
    }
    _ = try self.expect(.r_brace, "expected '}' to close `backends`", "close the backends list here");
}

/// Either `source { ...raw... }` (quoted block) or `source = "..."` (raw string
/// tier, for sources that must not even tokenize/brace-balance).
fn parseSourceSection(self: *Parser) !syntax.ast.FailTestSource {
    if (self.match(.equal)) {
        const str = try self.expect(.string, "expected a string literal after `source =`", "write the source as a single string literal");
        _ = self.match(.semicolon);
        return .{ .string = str.lexeme };
    }
    return .{ .block = try captureBracedRaw(self) };
}

/// Capture the verbatim text between a `{ ... }` pair without parsing it as Kira.
/// Brace depth is tracked over TOKENS, so braces inside string literals (a single
/// string token) never affect matching; the returned slice is the exact source.
fn captureBracedRaw(self: *Parser) ![]const u8 {
    const open = try self.expect(.l_brace, "expected '{' to start the block", "open the block here");
    const base_addr = @intFromPtr(open.lexeme.ptr) - open.span.start;
    const base: [*]const u8 = @ptrFromInt(base_addr);
    var depth: usize = 1;
    while (!self.at(.eof)) {
        const tok = self.advance();
        switch (tok.kind) {
            .l_brace => depth += 1,
            .r_brace => {
                depth -= 1;
                if (depth == 0) return base[open.span.end..tok.span.start];
            },
            else => {},
        }
    }
    try emit(self, "KPAR024", "unterminated FailTest block", open.span, "block is never closed", "Add a matching `}` to close this block.");
    return error.DiagnosticsEmitted;
}

fn emit(self: *Parser, code: []const u8, title: []const u8, span: source_pkg.Span, label: []const u8, help: []const u8) !void {
    try diagnostics.appendOwned(self.allocator, self.diagnostics, .{
        .severity = .@"error",
        .code = code,
        .title = title,
        .message = title,
        .labels = &.{diagnostics.primaryLabel(span, label)},
        .help = help,
    });
}

const parse_root = @import("parser.zig");

fn parseOnly(allocator: std.mem.Allocator, text: []const u8) !syntax.ast.Program {
    var diags = std.array_list.Managed(diagnostics.Diagnostic).init(allocator);
    return parse_root.parseSource(allocator, text, &diags);
}

fn firstFailTest(program: syntax.ast.Program) ?syntax.ast.FailTestDecl {
    for (program.decls) |decl| {
        if (decl == .fail_test_decl) return decl.fail_test_decl;
    }
    return null;
}

test "FailTest with a quoted source block captures raw text and backends verbatim" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const program = try parseOnly(allocator,
        \\FailTest UseAfterMove {
        \\    backends { vm llvm hybrid }
        \\    source {
        \\        struct Thing { var x: Int }
        \\        @Main function main() { let a = Thing { x: 1 } consume(move a) print(a.x) return }
        \\    }
        \\    expect { let e: Result<Int, TestFailure> = Result.Error(TestFailure.Compile("KSEM107")); return e }
        \\}
    );

    const ft = firstFailTest(program) orelse return error.NoFailTest;
    try std.testing.expectEqualStrings("UseAfterMove", ft.name);
    try std.testing.expectEqual(@as(usize, 3), ft.backends.len);
    try std.testing.expectEqualStrings("vm", ft.backends[0]);
    try std.testing.expectEqualStrings("llvm", ft.backends[1]);
    try std.testing.expectEqualStrings("hybrid", ft.backends[2]);

    const src = ft.source orelse return error.NoSource;
    try std.testing.expect(src == .block);
    // Raw capture is verbatim: braces inside the source and the `move a` use are
    // preserved, and the surrounding package never sees this text.
    try std.testing.expect(std.mem.indexOf(u8, src.block, "move a") != null);
    try std.testing.expect(std.mem.indexOf(u8, src.block, "struct Thing") != null);

    const expect_text = ft.expect_text orelse return error.NoExpect;
    try std.testing.expect(std.mem.indexOf(u8, expect_text, "KSEM107") != null);
}

test "FailTest source = string uses the raw-string tier and defaults backends to empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const program = try parseOnly(allocator,
        \\FailTest ParserError {
        \\    source = "@Main function main() {\n    let x = \n}\n"
        \\    expect { let e: Result<Int, TestFailure> = Result.Error(TestFailure.Compile("KPAR002")); return e }
        \\}
    );

    const ft = firstFailTest(program) orelse return error.NoFailTest;
    try std.testing.expectEqual(@as(usize, 0), ft.backends.len); // omitted block
    const src = ft.source orelse return error.NoSource;
    try std.testing.expect(src == .string);
    // The lexer decodes escapes: the captured value has real newlines, not `\n`.
    try std.testing.expect(std.mem.indexOf(u8, src.string, "let x =") != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, src.string, '\n') != null);
}

test "a source block containing a brace inside a string stays balanced" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const program = try parseOnly(allocator,
        \\FailTest BraceInString {
        \\    source { @Main function main() { print("}") return } }
        \\    expect { let e: Result<Int, TestFailure> = Result.Ok(1); return e }
        \\}
    );
    const ft = firstFailTest(program) orelse return error.NoFailTest;
    const src = ft.source orelse return error.NoSource;
    try std.testing.expect(src == .block);
    try std.testing.expect(std.mem.indexOf(u8, src.block, "print(\"}\")") != null);
}

test "FailTest coexists with a regular Test in the same program" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const program = try parseOnly(allocator,
        \\Test Regular {
        \\    test { return 42 }
        \\    expect { let e: Result<Int, TestFailure> = Result.Ok(42); return e }
        \\}
        \\FailTest Fails {
        \\    source { @Main function main() { print(nope) return } }
        \\    expect { let e: Result<Int, TestFailure> = Result.Error(TestFailure.Compile("KSEM012")); return e }
        \\}
    );

    var fail_tests: usize = 0;
    var construct_forms: usize = 0;
    for (program.decls) |decl| switch (decl) {
        .fail_test_decl => fail_tests += 1,
        .construct_form_decl => construct_forms += 1,
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), fail_tests);
    try std.testing.expectEqual(@as(usize, 1), construct_forms); // the Test
}
