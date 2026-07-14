# RESOLVED 2026-07-13 — all four migrated to `app/OwcConsumingTests.kira`.

Re-attempted now that `body { ... }` builder blocks are family-generic
(Construct 2.0) and the Test driver compares scalars: each program already folds
its rendered `[Widget]` tree to an integer checksum internally (the original
`@Main` printed the constant `"ok"` gated on that checksum, not the tree). Each
is now a scalar `Test` on the `Owc`-prefixed consuming Widget family that returns
the checksum and asserts the exact expected value, running on vm/llvm/hybrid and
under the `KIRA_TEST_CHECK_LEAKS` VM live-count gate — preserving the
consuming-receiver / partial-move drop coverage. Migration map:

- consuming_body_wrapper_parity            -> OwcConsumingBodyWrapperParity     (checksum 7)
- consuming_children_drain_parity          -> OwcConsumingChildrenDrainParity   (checksum 9)
- consuming_for_reemit_parity              -> OwcConsumingForReemitParity       (checksum 3)
- consuming_single_to_array_forward_parity -> OwcConsumingSingleToArrayForward  (checksum 5)

Historical skip rationale (widget-tree result "cannot reduce to a scalar Test")
no longer holds — the result reduces to the same Int checksum the original case
computed.
