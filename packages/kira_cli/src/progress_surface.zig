const std = @import("std");
const build = @import("kira_build");
const package_manager = @import("kira_package_manager");

const visible_history = 6;
// Stay below the conventional 80-column floor so one logical status row never
// wraps into two physical rows and breaks cursor-relative redraws.
const max_line_len = 72;

/// Cargo-style, terminal-only status surface. The title describes the current
/// command while up to six rows retain the most recent compiler phases.
pub const Surface = struct {
    title: [max_line_len]u8 = undefined,
    title_len: usize = 0,
    history: [visible_history][max_line_len]u8 = undefined,
    history_len: [visible_history]usize = [_]usize{0} ** visible_history,
    count: usize = 0,
    rendered_lines: usize = 0,
    active: bool = false,
    paused: bool = false,
    finish_after_build: bool = false,

    pub fn init(command: []const u8) Surface {
        var surface = Surface{};
        const title = std.fmt.bufPrint(&surface.title, "{s} Kira project", .{commandTitle(command)}) catch "Working on Kira project";
        surface.title_len = title.len;
        surface.finish_after_build = std.mem.eql(u8, command, "run");

        const terminal = std.Io.File.stderr();
        terminal.enableAnsiEscapeCodes(std.Options.debug_io) catch return surface;
        surface.active = true;
        return surface;
    }

    pub fn activate(self: *Surface) void {
        if (self.active) {
            build.setProgressCallback(self, receive);
            package_manager.setProgressCallback(self, receive);
        }
    }

    pub fn finish(self: *Surface, succeeded: bool) void {
        _ = succeeded;
        if (!self.active) return;
        build.setProgressCallback(null, null);
        package_manager.setProgressCallback(null, null);
        self.clear();
        self.active = false;
    }

    fn receive(context: ?*anyopaque, event: []const u8) void {
        const self: *Surface = @ptrCast(@alignCast(context orelse return));
        if (std.mem.eql(u8, event, "[kira:control] pause")) {
            self.clear();
            self.paused = true;
            return;
        }
        if (std.mem.eql(u8, event, "[kira:control] resume")) {
            self.paused = false;
            if (self.count != 0) self.draw();
            return;
        }
        if (std.mem.eql(u8, event, "[kira:control] suspend")) {
            self.finish(false);
            return;
        }
        if (std.mem.eql(u8, event, "[kira:control] build-finished")) {
            if (self.finish_after_build) self.finish(true);
            return;
        }
        self.push(describeEvent(event));
    }

    fn push(self: *Surface, description: []const u8) void {
        if (!self.active or description.len == 0) return;
        if (self.count < visible_history) {
            self.store(self.count, description);
            self.count += 1;
        } else {
            for (0..visible_history - 1) |index| {
                self.history[index] = self.history[index + 1];
                self.history_len[index] = self.history_len[index + 1];
            }
            self.store(visible_history - 1, description);
        }
        if (!self.paused) self.draw();
    }

    fn store(self: *Surface, index: usize, description: []const u8) void {
        const len = @min(description.len, self.history[index].len);
        @memcpy(self.history[index][0..len], description[0..len]);
        if (description.len > len and len >= 3) @memcpy(self.history[index][len - 3 .. len], "...");
        self.history_len[index] = len;
    }

    fn draw(self: *Surface) void {
        var buffer: [4096]u8 = undefined;
        var terminal = std.Io.File.stderr().writer(std.Options.debug_io, &buffer);
        defer terminal.interface.flush() catch {};

        if (self.rendered_lines != 0) terminal.interface.print("\x1b[{d}A", .{self.rendered_lines}) catch return;
        terminal.interface.print("\r\x1b[2K{s}\n", .{self.title[0..self.title_len]}) catch return;
        for (0..self.count) |index| {
            terminal.interface.print("\r\x1b[2K  {s}\n", .{self.history[index][0..self.history_len[index]]}) catch return;
        }
        self.rendered_lines = self.count + 1;
    }

    fn clear(self: *Surface) void {
        if (self.rendered_lines == 0) return;
        var buffer: [512]u8 = undefined;
        var terminal = std.Io.File.stderr().writer(std.Options.debug_io, &buffer);
        defer terminal.interface.flush() catch {};

        terminal.interface.print("\x1b[{d}A", .{self.rendered_lines}) catch return;
        for (0..self.rendered_lines) |index| {
            terminal.interface.writeAll("\r\x1b[2K") catch return;
            if (index + 1 < self.rendered_lines) terminal.interface.writeAll("\x1b[1B") catch return;
        }
        if (self.rendered_lines > 1) terminal.interface.print("\x1b[{d}A", .{self.rendered_lines - 1}) catch return;
        terminal.interface.writeAll("\r") catch return;
        self.rendered_lines = 0;
    }
};

fn commandTitle(command: []const u8) []const u8 {
    if (std.mem.eql(u8, command, "build")) return "Building";
    if (std.mem.eql(u8, command, "check")) return "Checking";
    if (std.mem.eql(u8, command, "test")) return "Testing";
    if (std.mem.eql(u8, command, "run")) return "Compiling";
    return "Running";
}

fn describeEvent(event: []const u8) []const u8 {
    const prefix = "[kira:timing] ";
    if (!std.mem.startsWith(u8, event, prefix)) return event;
    const body = event[prefix.len..];
    const phase = body[0 .. std.mem.indexOfScalar(u8, body, ' ') orelse body.len];

    const descriptions = .{
        .{ "SourceFile.fromPath", "Reading source files" },
        .{ "collectPackageModuleFiles", "Discovering package sources" },
        .{ "graph.collectPackageModuleFiles", "Discovering imported package sources" },
        .{ "lex/tokenize", "Lexing and tokenizing" },
        .{ "parse", "Parsing source" },
        .{ "graph.parseModuleProgram", "Parsing imported modules" },
        .{ "loadModuleMapForSource", "Resolving the module graph" },
        .{ "buildProgramGraph", "Building the program graph" },
        .{ "buildProgramGraphFromFiles", "Building the package graph" },
        .{ "validateImports", "Validating imports" },
        .{ "prepareNativeLibraries", "Preparing native libraries" },
        .{ "prepareDeclaredNativeLibraries", "Preparing declared native libraries" },
        .{ "native.ensureGeneratedBindings", "Generating native bindings" },
        .{ "native.ensureArtifact", "Building native dependencies" },
        .{ "semantics.analyzeLibrary", "Checking library semantics" },
        .{ "semantics.analyzeWithImports", "Checking program semantics" },
        .{ "ir.prepareProgram", "Preparing Kira IR" },
        .{ "ir.lowerProgram", "Lowering Kira IR" },
        .{ "verifyExecutableProgram", "Verifying executable requirements" },
        .{ "bytecode.compileProgram", "Generating VM bytecode" },
        .{ "bytecode.writeToFile", "Writing VM bytecode" },
        .{ "llvm_backend.validate", "Validating native code generation" },
        .{ "llvm_backend.compile", "Generating native machine code" },
        .{ "hybrid_manifest.write", "Writing the hybrid manifest" },
        .{ "build.cache_hit", "Reusing cached build artifacts" },
        .{ "check.cache_hit", "Reusing cached check results" },
        .{ "check.frontend_cache_hit", "Reusing cached frontend results" },
        .{ "check.package_cache_hit", "Reusing cached package results" },
        .{ "build.cache_store", "Caching build artifacts" },
        .{ "check.cache_store", "Caching check results" },
        .{ "check.frontend_cache_store", "Caching frontend results" },
        .{ "check.package_cache_store", "Caching package results" },
        .{ "mergeNativeLibraries", "Linking native libraries" },
        .{ "buildLlvmExecutableArtifact.total", "Finishing the native executable" },
        .{ "buildHybridArtifact.total", "Finishing the hybrid executable" },
        .{ "compileFileForBackend.total", "Finishing backend compilation" },
        .{ "checkFileForBackend.total", "Finishing backend checks" },
        .{ "checkFileFrontend.total", "Finishing frontend checks" },
        .{ "checkPackageRoot.total", "Finishing package checks" },
        .{ "compileFileToIr.total", "Finishing IR compilation" },
        .{ "build.total", "Finishing the build" },
    };
    inline for (descriptions) |entry| {
        if (std.mem.eql(u8, phase, entry[0])) return entry[1];
    }
    return phase;
}

test "timing events become concise status descriptions" {
    try std.testing.expectEqualStrings("Parsing source", describeEvent("[kira:timing] parse path=app/main.kira ns=42"));
    try std.testing.expectEqualStrings("Generating native machine code", describeEvent("[kira:timing] llvm_backend.compile path=app/main.kira ns=42"));
    try std.testing.expectEqualStrings("custom.phase", describeEvent("[kira:timing] custom.phase value=1"));
    try std.testing.expectEqualStrings("PASS ExampleTest", describeEvent("PASS ExampleTest"));
}

test "long progress rows are bounded and marked as truncated" {
    var surface = Surface{};
    surface.store(0, "This deliberately long progress event is wider than a conventional eighty-column terminal and must not wrap");
    try std.testing.expectEqual(@as(usize, max_line_len), surface.history_len[0]);
    try std.testing.expectEqualStrings("...", surface.history[0][max_line_len - 3 .. max_line_len]);
}
