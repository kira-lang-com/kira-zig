//! Aggregator for the analyzer/semantics unit tests. The individual `test`
//! blocks live in themed sibling files (kept well under the file-size limit);
//! shared fixtures are in `analyzer_test_support.zig`.
test {
    _ = @import("analyzer_entry_async_tests.zig");
    _ = @import("analyzer_execution_ffi_tests.zig");
    _ = @import("analyzer_annotations_tests.zig");
    _ = @import("analyzer_namespace_inheritance_tests.zig");
    _ = @import("analyzer_callables_native_misc_tests.zig");
}
