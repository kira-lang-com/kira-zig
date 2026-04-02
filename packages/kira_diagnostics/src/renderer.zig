const std = @import("std");
const Diagnostic = @import("diagnostic.zig").Diagnostic;
const SourceFile = @import("kira_source").SourceFile;

pub fn render(writer: anytype, source: *const SourceFile, diagnostic: Diagnostic) !void {
    try writer.print("{s}: {s}\n", .{ @tagName(diagnostic.severity), diagnostic.message });
    for (diagnostic.labels) |label| {
        const location = source.line_map.lineColumn(label.span.start);
        const snippet = label.span.slice(source.text);
        try writer.print(
            "  --> {s}:{d}:{d}: {s}\n      {s}\n",
            .{ source.path, location.line, location.column, label.message, snippet },
        );
    }
}

pub fn renderAll(writer: anytype, source: *const SourceFile, diagnostics: []const Diagnostic) !void {
    for (diagnostics) |diagnostic| {
        try render(writer, source, diagnostic);
    }
}
