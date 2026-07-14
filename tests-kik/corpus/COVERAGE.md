# Legacy corpus → kik transport coverage

Maps every legacy corpus case under `tests/` to its Kira-native `Test`-construct
home under `tests-kik/corpus/`. Continues commit e8369eb; transport completed
2026-07-12.

> **`tests/` has been DELETED (2026-07-13).** The last transport gaps are closed
> and the legacy tree, its corpus runner, and its `build.zig` wiring are gone.
> `zig build test` is now package unit tests + the repo-purity gate (relocated to
> `build_support/repository_truth.zig`); all user-visible behavior is covered by
> the Kira-native suites here, run through `kira test`. See the guarantee map.

## Summary

- `tests/pass/run` — **177/177 accounted**: 176 migrated as `Test` declarations
  (incl. the 4 formerly-skipped widget-builder-DSL consuming cases, now
  `ownership-b/app/OwcConsumingTests.kira` — each folds its rendered widget tree
  to the exact Int checksum the original asserted); 1 phantom case that never had
  sources, permanently CLOSED in `widgets/SKIPPED.md`.
- `tests/pass/check` (19 cases) — **all 19 covered**: 18 as must-compile
  `FailTest` declarations in `tests-kik/fail-corpus/check-surface/`, plus
  `imported_global_namespace` (formerly the multi-file skip) now migrated via
  **FailTest fixture mode** (`fixture("fixtures/imported_global_namespace")`).
- `tests/fail` (~146 case dirs) — **145 transported** as `FailTest` declarations
  asserting `TestFailure.Compile("<code>")` per backend. The 4 formerly-skipped
  multi-file / import-graph cases are now migrated via **FailTest fixture mode**
  (a `source { fixture("fixtures/<name>") }` compiling a real on-disk package DIR
  through the per-backend check path): `invalid_callback_signature` (KSEM045),
  `outside_app_import` (KSEM032), `declarative_showcase` (KSEM060). The
  per-backend-differential `vm_native_main` is migrated as the pass-corpus package
  `tests-kik/corpus/native-main`. The only remaining SKIPPED.md entries are two
  pipeline PASS-cases (`defaulted_construction_and_function_field_defaults`,
  `ffi_nested_fixed_array_assignment`) — no diagnostic to assert, so not FailTest
  material.

## Guarantee map (what replaced each legacy tests/ mechanism)

| Legacy tests/ mechanism | Replacement |
|---|---|
| Exact stdout diff across vm/llvm/hybrid (pass/run) | **Parity mode**: `KIRA_TEST_PARITY=1 kira test <pkg>` byte-diffs `@Main` stdout across the manifest `Tests { backends }` matrix (packages with an `@Main`). Verified on `harness` (vm/llvm) and `string-primitives` (vm/llvm/hybrid). A native `@Main`'s stdout is not capturable in-process, so its diff is skipped — the pass-differential is proven by the Tests matrix (`native-main`). |
| Native leak check (`leaks --atExit` on the llvm binary; `KIRA_CORPUS_CHECK_LEAKS=1`) | **Leak gate**: `KIRA_TEST_CHECK_LEAKS=1 kira test <pkg>`. The VM/hybrid Test driver's post-run VM live-count must be 0 (preserves `vm.heap.count()==0`); a package with an `@Main` additionally runs its llvm binary under `leaks --atExit`. A manifest `leakCheck` field is a noted follow-up (the `Tests` schema is owned by another workstream). |
| Expected-diagnostic corpus (`tests/fail/**`) | **FailTests** asserting `TestFailure.Compile("<code>")` per backend, incl. **fixture mode** for multi-file / import-graph / native-lib cases. |
| Analysis-only corpus (`tests/pass/check/**`) | **check-surface** must-compile FailTests (`Result.Ok(1)` sentinel), incl. fixture mode. |
| Backend matrix (`expect.toml backends`) | Manifest **`Tests { backends: [...], phase: ... }`** per package, iterated by `kira test`. |
| Repo-purity scan (`tests/repository_truth.zig`) | Relocated to **`build_support/repository_truth.zig`**, still wired into `zig build test`. |
| Shader golden fixtures (`tests/shaders/**`) | Relocated to **`tests-kik/shaders/**`** (consumed by `kira_build`/`kira_cli` shader unit tests). |

## Running

Every package: `kira test tests-kik/corpus/<pkg>` — must end `0 failed`
(each package's manifest declares its own backend matrix). EXCEPTION:
`ffi-dynamic` is bare-VM only; its direct VM FFI is rejected by design under the
hybrid driver (KSEM093).

Related, independent suites (not case-mapped): `tests-kik/harness` (949+ tests,
language stress), `tests-kik/ffi-harness` (224 tests, bridge stress).

## Case map (`tests/pass/run/<case>` → corpus location)

```
array_append_loop_no_stack_growth -> arrays/app/ArxTests.kira
array_append_parity -> arrays/app/ArxTests.kira
array_call_parity -> arrays/app/ArxTests.kira
array_element_borrow_mut_writeback_parity -> arrays/app/ArxTests.kira
array_element_deep_field_store_parity -> arrays/app/ArxTests.kira
array_element_mixed_projection_parity -> arrays/app/ArxTests.kira
array_element_nested_append_parity -> arrays/app/ArxTests.kira
array_local_parity -> arrays/app/ArxTests.kira
attempt_handle_payloadless_variant -> enums/app/EmxTests.kira
attempt_try_handle -> enums/app/EmxTests.kira
basic -> controlflow/app/CtxTests.kira
borrow_mut_struct_writeback -> structs/app/SkxTests.kira
borrowed_field_owned_array_clone_regression -> arrays/app/ArxTests.kira
call_temp_string_count_parity -> strings/app/SgxTests.kira
call_value_parity -> strings/app/SgxTests.kira
callback_builder_style_parity -> closures/app/CkxTests.kira
callback_mutable_value_capture -> closures/app/CkxTests.kira
callback_return_value_parity -> closures/app/CkxTests.kira
callback_value_capture -> closures/app/CkxTests.kira
callback_value_parity -> closures/app/CkxTests.kira
cast_call_reachability -> numeric/app/NuxTests.kira
closure_export_distinct_dispatch -> closures/app/CkxTests.kira
conditional_array_return_parity -> arrays/app/ArxTests.kira
conditional_expr_parity -> numeric/app/NuxTests.kira
construct_any_binding_move_parity -> structs/app/SkxTests.kira
construct_array_field_owned_value -> structs/app/SkxTests.kira
construct_declaration_functions -> structs/app/SkxTests.kira
consuming_body_wrapper_parity -> ownership-b/app/OwcConsumingTests.kira
consuming_children_drain_parity -> ownership-b/app/OwcConsumingTests.kira
consuming_for_reemit_parity -> ownership-b/app/OwcConsumingTests.kira
consuming_nested_field_receiver_parity -> ownership-b/app/OwyTests.kira
consuming_nested_indexed_receiver_parity -> ownership-b/app/OwyTests.kira
consuming_single_to_array_forward_parity -> ownership-b/app/OwcConsumingTests.kira
control_flow_parity -> numeric/app/NuxTests.kira
copyable_payload_enum_field_reuse -> enums/app/EmxTests.kira
empty_control_flow_bodies -> controlflow/app/CtxTests.kira
enum_basic_parity -> enums/app/EmxTests.kira
enum_equality_tag_compare -> enums/app/EmxTests.kira
enum_kind_split_cache_parity -> enums/app/EmxTests.kira
enum_payload_move_chain_parity -> enums/app/EmxTests.kira
enum_result_parity -> enums/app/EmxTests.kira
enum_var_reassign_return -> enums/app/EmxTests.kira
ffi_callback_hybrid -> ffi-callbacks/app/FccTests.kira
ffi_callback_native -> ffi-callbacks/app/FccTests.kira
ffi_callback_state_parity -> ffi-callbacks/app/FccTests.kira
ffi_dynamic_vm -> ffi-dynamic/app/FdmTests.kira
ffi_extern_cstring_arg_leak_regression -> ffi-extern/app/FxcTests.kira
ffi_sokol_hybrid -> sokol/app/SkgTests.kira
ffi_sokol_native -> sokol/app/SkgTests.kira
ffi_sokol_triangle_native -> sokol-triangle/app/SktTests.kira
ffi_struct_return_parity -> foundation/app/FnsTests.kira
ffi_struct_zero_init -> structs/app/SkxTests.kira
fieldless_enum_is_copy -> enums/app/EmxTests.kira
float_basic_parity -> numeric/app/NuxTests.kira
float_hybrid_bridge -> hybrid-bridge/app/scalars/HbfScalarTests.kira
float32_reinterpret_parity -> numeric/app/NuxTests.kira
float32_width_parity -> numeric/app/NuxTests.kira
for_basic_parity -> controlflow/app/CtxTests.kira
for_binding_parity -> controlflow/app/CtxTests.kira
for_empty_parity -> controlflow/app/CtxTests.kira
for_stateful_parity -> controlflow/app/CtxTests.kira
foundation_filesystem_compile -> foundation/app/FnsTests.kira
foundation_fs_argparser_leak_regression -> foundation/app/FnaTests.kira
foundation_math_operators -> numeric/app/NuxTests.kira
hybrid_append_struct_nested_array_mutation_sync -> hybrid-bridge/app/arrays/HbaArraySyncTests.kira
hybrid_append_struct_then_mutate_nested_field_sync -> hybrid-bridge/app/arrays/HbaArraySyncTests.kira
hybrid_native_state_nested_enum_array -> hybrid-bridge/app/state/HbnNativeStateTests.kira
hybrid_nested_struct_array_bridge -> hybrid-bridge/app/structs/HbsStructBridgeTests.kira
hybrid_roundtrip -> hybrid-bridge/app/scalars/HbfScalarTests.kira
hybrid_runtime_array_append_struct_sync -> hybrid-bridge/app/arrays/HbaArraySyncTests.kira
hybrid_runtime_array_struct_native_indexing -> hybrid-bridge/app/arrays/HbxArrayIndexTests.kira
hybrid_runtime_native_callback_export -> hybrid-bridge/app/closures/HbcClosureBridgeTests.kira
hybrid_runtime_native_closure_callback_capture -> hybrid-bridge/app/closures/HbcClosureBridgeTests.kira
hybrid_runtime_native_closure_capture_export -> hybrid-bridge/app/closures/HbcClosureBridgeTests.kira
if_basic_parity -> controlflow/app/CtxTests.kira
if_condition_trailing_call -> controlflow/app/CtxTests.kira
ime_pinyin_prediction -> strings/app/SgxTests.kira
imported_instance_method_parity -> imports/app/ImxTests.kira
imported_library_class_metadata_parity -> imports/app/ImxTests.kira
imported_namespace_parity -> imports/app/support.kira
imports -> imports/app/main.kira
inheritance_imported_parent_parity -> imports/app/ImxTests.kira
inheritance_multi_parent_parity -> imports/app/ImxTests.kira
instance_method_parity -> structs/app/SkxTests.kira
integer_arithmetic_parity -> numeric/app/NuxTests.kira
large_future_ui_nested_data_stress -> stress/app/FuxTests.kira
large_graphics_descriptor_stress -> stress/app/GdxTests.kira
large_graphics_shaped_pipeline_access_regression -> stress/app/GpxTests.kira
large_nested_struct_copy_source_must_be_pointer_regression -> stress/app/NsxTests.kira
large_runtime_native_descriptor_boundary -> hybrid-bridge/app/structs/HbsStructBridgeTests.kira
llvm_append_struct_then_mutate_nested_field_policy -> hybrid-bridge/app/arrays/HbxArrayIndexTests.kira
llvm_array_struct_materialization_parity -> arrays/app/ArxTests.kira
llvm_textcore_glyphrun_parity -> stress/app/TgxTests.kira
logical_short_circuit_parity -> numeric/app/NuxTests.kira
macro_field_trigger_rewrite -> macros/app/MacTests.kira
macro_property_wrapper -> macros/app/MacTests.kira
macro_wrapper_state -> macros/app/MacTests.kira
mid_ir_disjoint_struct_field_borrows -> ownership-b/app/OwyTests.kira
native_callback_capture_local_remap -> hybrid-bridge/app/closures/HbcClosureBridgeTests.kira
native_print_struct_array -> hybrid-bridge/app/structs/HbsStructBridgeTests.kira
native_runtime_array_callback_pinning -> hybrid-bridge/app/arrays/HbxArrayIndexTests.kira
native_runtime_bool_bridge -> hybrid-bridge/app/structs/HbsStructBridgeTests.kira
native_runtime_struct_bridge -> hybrid-bridge/app/structs/HbsStructBridgeTests.kira
native_runtime_struct_callback_bridge -> hybrid-bridge/app/closures/HbcClosureBridgeTests.kira
native_state_enum_field -> hybrid-bridge/app/state/HbnNativeStateTests.kira
native_state_field_moveout_parity -> hybrid-bridge/app/state/HbnNativeStateTests.kira
native_state_free_parity -> hybrid-bridge/app/state/HbnNativeStateTests.kira
negative_modulo_truncation_parity -> numeric/app/NuxTests.kira
negative_typed_literal_parity -> numeric/app/NuxTests.kira
nested_enum_payload_parity -> enums/app/EmxTests.kira
numeric_cast_parity -> numeric/app/NuxTests.kira
ownership_array_field_readback_parity -> ownership-a/app/OwxTests.kira
ownership_array_struct_elements_parity -> ownership-a/app/OwxTests.kira
ownership_borrow_mut_struct_field_parity -> ownership-a/app/OwxTests.kira
ownership_borrow_param_parity -> ownership-a/app/OwxTests.kira
ownership_closure_array_elements_parity -> ownership-a/app/OwxTests.kira
ownership_closure_block_churn_parity -> ownership-a/app/OwxTests.kira
ownership_closure_body_recursive_tree_parity -> ownership-a/app/OwxTests.kira
ownership_closure_branch_local_parity -> ownership-a/app/OwxTests.kira
ownership_closure_capture_copy_parity -> ownership-a/app/OwxTests.kira
ownership_closure_field_reassign_parity -> ownership-a/app/OwxTests.kira
ownership_closure_mixed_aggregate_churn_parity -> ownership-a/app/OwxTests.kira
ownership_closure_multi_capture_churn_parity -> ownership-a/app/OwxTests.kira
ownership_closure_nested_capture_parity -> ownership-a/app/OwxTests.kira
ownership_closure_owned_param_parity -> ownership-a/app/OwxTests.kira
ownership_closure_returned_parity -> ownership-a/app/OwxTests.kira
ownership_closure_struct_array_parity -> ownership-a/app/OwxTests.kira
ownership_closure_struct_copy_parity -> ownership-a/app/OwxTests.kira
ownership_closure_struct_field_parity -> ownership-a/app/OwxTests.kira
ownership_construct_any_tree_churn_parity -> ownership-b/app/OwyTests.kira
ownership_enum_argument_into_field_parity -> ownership-b/app/OwyTests.kira
ownership_enum_string_payload_free_parity -> ownership-b/app/OwyTests.kira
ownership_enum_struct_field_parity -> ownership-b/app/OwyTests.kira
ownership_explicit_move_ok -> ownership-b/app/OwyTests.kira
ownership_free_state_moveout_return_parity -> ownership-b/app/OwyTests.kira
ownership_let_field_alias_if_partial_move -> ownership-b/app/OwyTests.kira
ownership_let_field_alias_partial_move -> ownership-b/app/OwyTests.kira
ownership_let_field_alias_switch_partial_move -> ownership-b/app/OwyTests.kira
ownership_let_field_alias_while_partial_move -> ownership-b/app/OwyTests.kira
ownership_multi_closure_copy_capture -> ownership-b/app/OwyTests.kira
ownership_partial_move_scope_exit_parity -> ownership-b/app/OwyTests.kira
ownership_recursive_closure_tree_parity -> ownership-b/app/OwyTests.kira
ownership_string_deep_value_parity -> ownership-b/app/OwyTests.kira
ownership_struct_param_move_into_array_parity -> ownership-b/app/OwyTests.kira
ownership_temporary_move_ok -> ownership-b/app/OwyTests.kira
ownership_trivial_value_no_move -> ownership-b/app/OwyTests.kira
partial_move_disjoint_fields -> ownership-b/app/OwyTests.kira
printable_dispatch_parity -> structs/app/SkxTests.kira
retained_tree_aggregate_defaults_parity -> structs/app/SkxTests.kira
runtime_native_enum_bridge -> hybrid-bridge/app/enums/HbeEnumBridgeTests.kira
runtime_native_struct_bridge -> hybrid-bridge/app/structs/HbsStructBridgeTests.kira
runtime_native_struct_value_return -> hybrid-bridge/app/structs/HbsStructBridgeTests.kira
runtime_native_struct_value_return_callback -> hybrid-bridge/app/closures/HbcClosureBridgeTests.kira
shift_amount_masking_parity -> numeric/app/NuxTests.kira
string_array_overwrite_no_leak -> strings/app/SgxTests.kira
string_concat_parity -> strings/app/SgxTests.kira
string_count_parity -> strings/app/SgxTests.kira
string_equality_parity -> strings/app/SgxTests.kira
struct_state_parity -> structs/app/SkxTests.kira
switch_basic_parity -> controlflow/app/CtxTests.kira
task_spawn_lifecycle_leak_parity -> tasks/app/TskTests.kira
trailing_callback_captures -> closures/app/CkxTests.kira
trailing_callback_mutable_capture -> closures/app/CkxTests.kira
trailing_callback_native_syntax -> closures/app/CkxTests.kira
unary_not_parity -> numeric/app/NuxTests.kira
while_index_struct_methods -> structs/app/SkxTests.kira
widget_any_coercion -> widgets/app/WcaTests.kira
widget_any_return_dispatch -> widgets/app/WarTests.kira
widget_body_locals_and_for -> widgets/app/WblTests.kira
widget_chained_modifier_dispatch -> widgets/app/WcmTests.kira
widget_children_dispatch -> widgets/app/WcdTests.kira
widget_dynamic_node -> widgets/app/WdnTests.kira
widget_for_modifier_content -> widgets/app/WfmTests.kira
widget_imported_constructor_resolution -> CLOSED (phantom; tests-kik/corpus/widgets/SKIPPED.md)
widget_node_bridge -> widgets/app/WnbTests.kira
widget_tree_construction -> widgets/app/WtcTests.kira
widget_value_runtime -> widgets/app/WvrTests.kira
```
