pub const ProgramGraph = @import("builder.zig").ProgramGraph;
pub const buildProgramGraph = @import("builder.zig").buildProgramGraph;
pub const buildProgramGraphFromFiles = @import("builder.zig").buildProgramGraphFromFiles;
pub const collectPackageModuleFiles = @import("builder.zig").collectPackageModuleFiles;
pub const parseModuleProgram = @import("builder.zig").parseModuleProgram;
pub const ImportResolution = @import("imports.zig").ImportResolution;
pub const resolveImportPath = @import("imports.zig").resolveImportPath;
pub const packageRootOwnerForImport = @import("imports.zig").packageRootOwnerForImport;
pub const firstExistingCandidate = @import("imports.zig").firstExistingCandidate;
pub const resolvedCandidateNotes = @import("imports.zig").resolvedCandidateNotes;
pub const qualifiedNameDisplay = @import("imports.zig").qualifiedNameDisplay;
pub const canonicalizeExistingPath = @import("paths.zig").canonicalizeExistingPath;
pub const canonicalizeSourceRoot = @import("paths.zig").canonicalizeSourceRoot;
pub const canonicalAppSourceRoot = @import("roots.zig").canonicalAppSourceRoot;
pub const sourceRootForPackageRoot = @import("roots.zig").sourceRootForPackageRoot;

test {
    _ = @import("builder.zig");
    _ = @import("imports.zig");
    _ = @import("paths.zig");
    _ = @import("roots.zig");
}
