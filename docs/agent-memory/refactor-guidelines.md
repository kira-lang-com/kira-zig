# Refactor Guidelines

Internal rules for safe implementation work.

## Hard file-size rule

- Any touched file must stay under 1000 physical lines.
- Prefer splitting around 800 lines before the file becomes hard to reason about.
- `packages/kira_vm_runtime/src/vm.zig` was already over 1000 lines before the recent hybrid fix; treat it as a high-priority split candidate.

## Split strategy

- Inventory responsibilities first.
- Split by concern, not by arbitrary line count.
- Keep behavior unchanged during the split.
- Move helpers into focused sibling files, then re-export from the package root if needed.

Good split examples:

- parser decls / statements / expressions / blocks
- semantics by concern (`lower_exprs_*`, `lower_program_*`)
- backend core / call lowering / utilities
- VM execution core / struct marshalling / helper routines

## Generated-artifact hygiene

- Never edit `generated/`, `.zig-cache/`, `zig-out/`, or `.kira/` by hand.
- Regenerate bindings/assets through the real commands instead.

## Docs/examples sync

When implementation changes user-visible behavior:

- update the relevant memory file(s)
- update public docs only if they are already part of the repo’s documented surface
- update examples and corpus cases together

## Avoid broad churn

- Don’t refactor across layers unless the layering issue is real.
- Don’t move logic upward into CLI/build roots.
- Don’t invent new abstractions if the current split is already clear enough.
- Prefer small, composable changes.
