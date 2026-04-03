pub const Label = @import("label.zig").Label;
pub const LabelKind = @import("label.zig").LabelKind;
pub const primaryLabel = @import("label.zig").primary;
pub const secondaryLabel = @import("label.zig").secondary;
pub const Diagnostic = @import("diagnostic.zig").Diagnostic;
pub const Severity = @import("diagnostic.zig").Severity;
pub const Suggestion = @import("diagnostic.zig").Suggestion;
pub const hasErrors = @import("diagnostic.zig").hasErrors;
pub const appendOwned = @import("diagnostic.zig").appendOwned;
pub const single = @import("diagnostic.zig").single;
pub const renderer = @import("renderer.zig");

test {
    _ = @import("renderer.zig");
}
