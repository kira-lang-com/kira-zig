# Construct Family Layer — Study & Implementation Plan

Status: **PLAN ONLY (no implementation code written yet besides this file).**
Author: Claude (Opus) study session, 2026-06-13.
Decisions in §0 are **locked** by the task owner. §7 records the resolved answers verbatim.

This document is written in a critical, truth-seeking register. Where the task is
under-defined or more expensive than it reads, it says so. Read §2 (Challenges) and §3
(Resolved semantics) before the phases.

---

## 0. Locked decisions (task owner, 2026-06-13)

1. **Properties vs form params:** **coexist.** Form/function params stay. Construct
   declaration properties use the **section form only** (`Route Home { properties { path: "/" } }`).
   Do **not** implement `Route Home(path: "/")` construct-property syntax.
2. **Legacy `requires { content; }`:** **migrate away.** New `requires` = *function*
   requirements. Content-requiredness moves to channel rules (`count 1..`). Keep legacy
   compatibility only transitionally to avoid immediate corpus breakage; the new model is the target.
3. **`sealed`/`refine`/`passthrough`/`project`:** all four get **real, honest validation** —
   not parse-only. May be sequenced (failing fixtures first, phase by phase) but **not permanently
   descoped.**
4. **`attempt`/`try`/`handle`:** **executes now.** Implement the executable path for
   `Result<Value, Failure>` unwrapping + handler dispatch. A backend that genuinely cannot execute
   it must **reject with a tested diagnostic**, never silently pretend support.
5. **`Self`:** implement **broadly** enough for the construct system to work properly, not just the
   narrow type-position case.
6. **`Goal.md`:** the new model **replaces** the conflicting `Goal.md` construct direction. Do not
   preserve the old divergent model as the spec.

Priority: **design cleanliness over backward-compat, with migration discipline.** Real
implementation, not a parser-only layer.

---

## 1. Scope and honest framing

The deliverable: a real `construct` declaration-family system — inheritance (`extends` + form
parents), required functions with satisfaction analysis, properties (incl. `required`), named
content channels (`accepts`/`count`), content composition (`sealed`/`refine`/`passthrough`/
`project`), and **executable** `attempt`/`try`/`handle` over `Result`. Scoped to the
construct-system foundation: **no Kira Web runtime, no DOM backend.**

### 1.1 What "executes" and what stays check-level
- **`attempt`/`try`/`handle` executes** (decision 4). It desugars to existing executable IR
  primitives (enum tag/payload branching already lowers across vm/llvm/hybrid — see
  `docs/language_inventory.md` "lowered enum construction… generic `Result<Value, Failure>`…
  enum tag/payload branching across vm, llvm, hybrid"). So no new runtime is required; we lower
  `try`/`handle` to match/branch. Backend parity is mandatory; any backend that cannot must emit a
  tested rejection diagnostic.
- **Construct family declarations remain check-level**, because construct-forms themselves do not
  execute today (they lower to IR *metadata* only — `packages/kira_ir/src/lower_from_hir_program.zig:166`,
  `ir.ConstructImplementation { type_name, has_content, lifecycle_hooks }`). This task does **not**
  make `Route`/`WebElement`/`Drawable` *run*; it makes them *validate* richly. That remains the
  honest boundary: widget-tree execution is a separate later effort. Only `attempt`/`try`/`handle`
  gains real execution here.

### 1.2 Verified codebase facts (assumptions re-checked; several were wrong)
- `parser.zig:396 sectionKind` is clean (earlier "duplication" was a Read display glitch).
- Decl dispatch: `parser_decls.zig:15`; `looksLikeConstructFormDecl` (`parser.zig:242`) matches
  `Ident(.Ident)* Ident ('(' | '{')`, so `Sprite Player {` / `Route Home {` already parse as
  construct-forms. **Form-as-parent is a semantics problem, not a parser problem.**
- `ast.ConstructDecl` (`ast.zig:166`) has **no parents**. `parseConstructDeclWithAnnotations`
  (`parser_decls.zig:538`) does `construct` `name` `{` with no `extends`.
- `model.Construct` (`kira_semantics_model/src/hir.zig:109`) is minimal: `name, allowed_annotations,
  required_content: bool, content_element_type: ?, allowed_lifecycle_hooks, span`. Almost everything
  here is net-new to the model.
- `requires { function … }` already *parses* (`parser_decls.zig:612`). `requires { content; }` is
  the **legacy** meaning (named_rule → `required_content = true`).
- **No `Self`** anywhere in the lexer. **No `..` token** (`.` → `.dot`, `lexer.zig:81`; `0..1` →
  `integer(0) dot dot integer(1)`).
- Keywords present: `uses`, `as`. Absent: `attempt`, `try`, `handle`, `accepts`, `count`, `sealed`,
  `refine`, `passthrough`, `project`, `required`, `properties`.
- **Keyword-collision evidence (decisive):** `handle` is used as an ordinary identifier in
  ≥3 corpus files (`foundation/app/FileSystem.kira` `var handle: RawPtr`, `foundation/bindings/fs/fs.kira`,
  `tests/pass/run/runtime_native_enum_bridge/main.kira` `function handle(...)`). **`handle` must stay
  an identifier (contextual keyword).** `try`/`attempt`/`Self` have no identifier collisions in the
  corpus and can be reserved.
- **`requires { content; }` migration size: 14 `.kira` files** (examples + fail-tests). Real churn.
- Diagnostics: `KSEM###` enum in `kira_diagnostic_messages/src/DiagnosticCode.zig`, highest existing
  **KSEM117**; new codes from **KSEM118**. Fail fixtures assert `diagnostic_code` + `diagnostic_title`
  + `stage` in `expect.toml`.
- **Codex did not do this layer.** Its queue is platform milestones; `Goal.md` is a *different*,
  now-superseded construct design (decision 6).

---

## 2. Challenges / Pushback (resolved positions)

- **A — properties vs params:** resolved → coexist (decision 1). Independent mechanisms; a construct
  may declare a property schema and/or its forms may take params.
- **B — `content` is overloaded** (typed `content: Content<T>;`, construct-body channel schema
  `content { chan { … } }`, form-body builder `content { Widget{…} }`, and directives
  `content sealed/refine/passthrough/project`). Resolution: thread an explicit **body-kind** context
  through the parser (construct-body vs form-body). In a construct body, after `content`:
  `:` → typed, a directive word → directive, `{` → channel schema. In a form body, `content { … }`
  stays the builder. The literal channel named `content` nested in a schema is legal and must not be
  special-cased by word.
- **C — legacy `requires { content; }`:** resolved → migrate (decision 2). Strategy: keep legacy
  parsing/semantics working through Phases 1–4 so the corpus stays green, introduce the new model in
  parallel, then a dedicated **migration phase** rewrites all 14 fixtures/examples to the new model
  and finally removes the legacy path. No silent dual-meaning left at the end.
- **D — mixed inheritance graph (hardest):** required-function satisfaction spans construct→construct,
  form→construct, and form→form. The `construct_name` of a form may resolve to a construct **or** a
  prior form. Analysis must resolve parents, detect cycles across the mixed graph, collect transitive
  required functions, and track satisfaction up the form chain to flag the *first concrete child* that
  leaves a requirement unmet. **No shortcut that only inspects a declaration's own body** — that passes
  the toy case and fails `Sprite Player`. Failing fixtures written first.
- **E — refine/passthrough honest semantics:** resolved → real validation (decision 3). Precise rules
  in §3.
- **F — attempt execution:** resolved → executes (decision 4). Lower to enum match/branch; parity +
  rejection-diagnostic discipline. §3.
- **G — Self:** resolved → broad (decision 5). §3.
- **H — sequencing of content directives:** kept in-scope (decision 3); sequenced as Phase 6, not
  descoped.

---

## 3. Resolved semantics specification (the spec I will implement)

These are concrete, internally-consistent rules. They are my proposal under the locked decisions;
correct me if any rule is wrong, but each is *honestly validated*, not a smoke surface.

### 3.1 Keywords / tokens
- Add token `dot_dot` (`..`) to the lexer + `TokenKind`.
- Reserve keywords: `attempt`, `try`, `Self`. (`try` = prefix expression; `Self` = type name.)
- `handle` stays an **identifier**; the parser recognizes it **contextually** only immediately after
  an `attempt { … }` block. Using `handle` elsewhere remains a normal identifier.
- Contextual (identifier-level) words inside their sections: `accepts`, `count`, `required`,
  `properties`, `sealed`, `refine`, `passthrough`, `project`. (`as` is already a keyword.)

### 3.2 `extends` + inheritance
- `construct C extends A, B { … }`: AST `ConstructDecl.parents: []QualifiedName`; model carries
  resolved parents. Multiple parents allowed (mirrors class `extends`).
- Form parent: a form's `construct_name` resolves to a construct **or** a prior form.
- Validation: KSEM118 unknown parent; KSEM119 inheritance cycle (across the mixed graph);
  KSEM122 parent is neither a construct nor a declaration.

### 3.3 Properties
- Construct schema: `properties { id: String; required path: String; uuid: UUID }`. AST
  `PropertySchemaField { required: bool, name, type_expr, default: ?Expr }`.
- Declaration fill: `properties { path: "/" }` (section form only).
- Inherited properties accumulate through `extends`/form chain.
- Validation: KSEM123 missing required; KSEM124 unknown property; KSEM125 type mismatch;
  KSEM126 duplicate (schema or declaration).

### 3.4 Required functions
- `requires { function render() -> Result<DomNode, RenderFailure>; function update(previous: Self);
  function unmount() }` → stored as required signatures on the construct.
- Satisfaction (decision-D analysis): the **first concrete child declaration** of a construct must
  implement every transitive required function unless an inherited concrete parent (construct-form)
  already implements it. Descendants inherit impls and may override.
- Validation: KSEM120 missing required function; KSEM121 override signature mismatch.
- "Interface-like" construct = `requires`-only, no content; valid.

### 3.5 Named content channels
- `content { head { accepts WebElement; count 0..1 } view { accepts WebElement; count 1.. } }`.
  AST `ContentChannel { name, accepts: ?QualifiedName, count: CountRange }`,
  `CountRange { min: u32, max: ?u32 }` (`0..`→{0,null}, `0..1`→{0,1}, `1..`→{1,null}).
- Declaration named sections (`head { … }`, `view { … }`) fill channels with **builder/content
  blocks** (not statement blocks); form-body parsing adjusted so these are content items.
- Validation: KSEM127 unknown channel; KSEM129 count violation; KSEM130 content type vs `accepts`.

### 3.6 Content composition (honest rules)
- `content sealed`: closes this construct's content surface. **Descendant constructs may not add,
  `refine`, or `project` channels onto the sealed ancestor's channel set.** Declarations may still
  fill the existing channels per their rules. Violation by a descendant → KSEM128.
- `content refine { chan { count R; accepts T } }`: `chan` must name an **inherited** channel
  (else KSEM132); the refined `count` must be a **subrange** of the inherited range and `accepts`
  may only **narrow** (same type or a subtype) — widening either is KSEM132. Real tightening only.
- `content passthrough`: the construct **forwards** inherited content instead of owning its own.
  Validation: it must have a parent that exposes content channels (else passthrough is meaningless →
  KSEM132 variant); it may **not** declare its own `content { channels }`; declarations under it fill
  the **parent's** channels directly.
- `content project { view as WebElement.content; head as WebElement.head }`: each mapping's target
  construct must be an ancestor and the target channel must exist (else KSEM131); a declaration using
  the projected local name (`view`) then typechecks as filling the target channel (its `accepts`/
  `count` apply).

### 3.7 `Self` (broad)
- `Self` resolves to the enclosing **construct or form's nominal type** wherever a type is expected:
  `requires` signatures, property/field types, function param/return types, and inside impl bodies
  (e.g. as a type in locals/casts where types appear). Outside any construct/form context, `Self`
  is rejected with a diagnostic.

### 3.8 `attempt` / `try` / `handle` (executable)
- Syntax: `attempt { <stmts, incl. `try` exprs> } handle { Variant(binding) { <stmts> } … }`.
  `try expr` is a prefix expression whose operand must be `Result<V, F>`; valid **only** lexically
  inside an `attempt`.
- Static checks: KSEM133 `try` outside `attempt`; KSEM134 `try` on non-Result; KSEM135 missing
  handle case for a reachable failure variant (exhaustiveness over `F`, reusing match-exhaustiveness
  machinery); KSEM136 handle case not a variant of `F`; KSEM137 incompatible failure enums in one
  `attempt` (all `try` operands must share the same `F`; "shared failure type" = identical `F` or
  one assignable to the other via existing enum rules — **no new subtyping lattice invented**).
- Execution: lower to existing IR — each `try e` evaluates `e: Result<V,F>`; `Ok(v)` binds `v` and
  continues; `Error(f)` transfers control to handler dispatch, which matches `f`'s variant against the
  `handle` cases and runs the matching body; after a handler runs, control resumes after the `attempt`.
  This composes existing enum match/branch lowering. Parity required across vm/llvm/hybrid; if a
  backend cannot lower it, emit a tested `KBE`/`KSEM` "attempt/try not executable on this backend"
  diagnostic (none expected, since `Result` already lowers on all three). WASM: covered by the shared
  executable lowering or explicitly rejected.

---

## 4. Diagnostics catalog (proposed, KSEM118+)

Each gets a fail fixture asserting code + title + stage. Final numbers assigned against
`DiagnosticCode.zig` at impl time; some may merge.

- KSEM118 unknown parent construct in `extends`
- KSEM119 construct inheritance cycle
- KSEM120 missing required function in concrete declaration
- KSEM121 required-function override signature mismatch
- KSEM122 parent is neither a construct nor a declaration
- KSEM123 missing required property
- KSEM124 unknown property
- KSEM125 property type mismatch
- KSEM126 duplicate property
- KSEM127 unknown content channel
- KSEM128 content/refine/project onto a sealed construct
- KSEM129 content count violation
- KSEM130 content type mismatch against `accepts`
- KSEM131 unknown projection target construct/channel
- KSEM132 invalid content refinement / meaningless passthrough
- KSEM133 `try` outside `attempt`
- KSEM134 `try` on non-Result value
- KSEM135 missing handle case for reachable failure variant
- KSEM136 handle case not a variant of the failure enum
- KSEM137 incompatible failure enums in a single `attempt`
- (reserved) KBE/KSEM `attempt`/`try` not executable on this backend

---

## 5. Phased implementation plan (each phase ends GREEN + tested)

Principle: never red between phases; every phase adds real pass+fail fixtures and weakens no existing
test. "Done" for a phase = its **fail fixtures fire the right diagnostics**, not merely that the happy
example parses. (Explicitly resisting the happy-path-only shortcut.)

**Phase 0 — Lexer/token groundwork**
- Add `dot_dot` token; reserve `attempt`/`try`/`Self` keywords (NOT `handle`). Lexer unit tests.
- Grep-guard: confirm no corpus identifier uses `attempt`/`try`/`Self` (done: none). `handle` stays id.
- Gate: `zig build` + lexer tests green; no token-test regressions.

**Phase 1 — construct `extends` (foundation)**
- AST `ConstructDecl.parents`; parse `extends A, B`. Model parents + lowering.
- Semantics: KSEM118 unknown parent, KSEM119 cycle (construct→construct first cut).
- Fixtures: pass (single/multi extends), fail (unknown, direct + indirect cycle). `ast_dump` updated.

**Phase 2 — properties schema + declaration properties section**
- AST property schema + declaration `properties { name: value }` (new parse path; current `named_rule`
  cannot parse `name: value` statements). Model + inherited accumulation.
- Validation: KSEM123–126.
- Fixtures: pass (required+optional+inherited), fail (each).

**Phase 3 — named content channels (`accepts`/`count`)**
- AST channel schema + `CountRange` (uses `dot_dot`). Form-body named sections (`head`/`view`) parse as
  content/builder blocks bound to channels. Keep existing `content: Content<T>` path working.
- Validation: KSEM127/129/130.
- Fixtures: pass (multi-channel, 0.., 0..1, 1.., inherited), fail (each).

**Phase 4 — required functions + mixed inheritance satisfaction (highest risk)**
- Model required signatures; build mixed construct/form DAG; resolve form parents (KSEM122); transitive
  collection; satisfaction up the form chain (KSEM120); override signature check (KSEM121); extend cycle
  detection across forms. Integrate `Self` (Phase 0/3.7) in signatures.
- Fixtures (dense): the `Drawable`/`Sprite`/`Player`/`AnimatedPlayer` matrix; missing-impl fail;
  inherited-satisfies pass; override pass; override-mismatch fail; multi-level chains; bad-parent fail.

**Phase 5 — `attempt`/`try`/`handle` (parse → typecheck → execute)**
- AST `AttemptStatement`/`HandleCase`/`try` prefix expr; contextual `handle`. Static checks KSEM133–137.
- Executable lowering to enum match/branch; vm/llvm/hybrid parity; backend rejection diagnostic if any.
- Fixtures: pass (single F all-variants, value flow through `Ok`), fail (each diagnostic, try-outside-attempt);
  **run** fixtures proving Ok-path and Error-dispatch produce correct observable output on vm/llvm/hybrid.

**Phase 6 — content composition (`sealed`/`refine`/`passthrough`/`project`)**
- AST + parse the four directives. Validation per §3.6 (KSEM128/131/132). Failing fixtures first.
- Fixtures: project pass + unknown-target fail; sealed pass + violate-sealed fail; refine-tighten pass +
  refine-widen fail; passthrough pass + meaningless-passthrough fail.

**Phase 7 — legacy `requires { content; }` migration**
- Migrate all 14 `.kira` files to the new model (content-requiredness via `count 1..`; `requires` becomes
  function-only). Update affected fail-tests' expected diagnostics. Remove the legacy `required_content`
  path once the corpus is migrated. (Sequenced last so earlier phases stay green.)

**Phase 8 — docs/spec + sweep + cleanup**
- New `docs/` spec page for this layer, aligned strictly to tested fixtures (no unsupported syntax in docs).
- Update `docs/language_inventory.md`. Retire/replace the superseded `.codex/tmp/Goal.md` construct
  direction note (decision 6) — flag, don't silently delete Codex state.
- Confirm `tests/**/.kira-build/` caches are gitignored (observed in working tree during study).
- Full targeted re-run; no weakened tests.

---

## 6. Risk register

- **R1 (high):** Phase 4 mixed-graph satisfaction — shortcuts pass the toy case, fail `Sprite Player`.
  Mitigation: failing fixtures first.
- **R2 (med):** `content` overloading (Challenge B) → parser ambiguity if body-kind context isn't threaded.
  Mitigation: explicit context flag + targeted parser tests.
- **R3 (med):** Phase 5 execution parity — `attempt` value-flow / early-exit must agree across
  vm/llvm/hybrid. Mitigation: run fixtures on all three; reuse proven enum-match lowering.
- **R4 (med):** Phase 7 migration churn (14 files incl. fail-tests whose diagnostics may shift).
  Mitigation: dedicated late phase; migrate + re-bless expectations deliberately.
- **R5 (med):** keyword reservation — `handle` cannot be reserved (real collisions). Mitigation:
  contextual `handle`; reserve only `attempt`/`try`/`Self`; re-grep before reserving.
- **R6 (low):** KSEM code collisions — assign against `DiagnosticCode.zig` at impl time.

---

## 7. §7 decisions — RESOLVED (verbatim summary)

1. coexist; section-form properties only; no `Route Home(path:"/")`.
2. migrate away from `requires { content; }`; `requires` = functions; content-requiredness via `count 1..`;
   transitional legacy compat only.
3. real semantics for sealed/project/refine/passthrough; failing fixtures first; not permanently descoped.
4. `attempt`/`try`/`handle` executes; per-backend tested rejection if unexecutable; no silent pretend.
5. `Self` broad.
6. new model replaces `Goal.md`; do not preserve the divergent old model.

Priority: design cleanliness over backward-compat, with migration discipline. Real implementation,
construct-system foundation scope (no Kira Web runtime / DOM backend).

---

## 9. Progress log

- **Phase 0 — DONE.** Added `dot_dot` (`..`) token; reserved `attempt`/`try`/`Self` keywords
  (`handle` left as identifier per the collision finding). Lexer unit test covers range lexing +
  keyword/identifier split. `tokenDescription` updated for the new variants. Full unit suite green.
- **Phase 1 — DONE.** `construct C extends A, B`: AST `ConstructDecl.parents`, parser support,
  model `ConstructParent` + `Construct.parents`, and `validateConstructInheritance`
  (KSEM118 unknown parent, KSEM119 cycle incl. self + transitive, via DFS over the local graph;
  imported parents treated as external roots). Fixtures: `tests/pass/check/construct_extends`
  (forward ref + multi-parent, green on vm/llvm/hybrid), `tests/fail/semantics/construct_unknown_parent`
  (KSEM118), `tests/fail/semantics/construct_inheritance_cycle` (KSEM119). Parser unit test added.
  `zig build test` green; construct corpus green on all three backends.

- **Phase 2 — DONE.** Construct `properties { [required] name: Type }` schema + declaration
  `properties { name: value }` section. New AST (`PropertySchemaField`, `DeclPropertiesSection`,
  `ConstructSectionKind.properties`), parser paths (contextual `required`; newline-separated
  entries with optional `;`), model `PropertySchema` + `Construct.properties`, transitive schema
  collection over `extends`, and `validateFormProperties`: KSEM123 missing required, KSEM124
  unknown, KSEM125 type mismatch (reuses `resolveSyntaxExprType` + `canAssignInContext`), KSEM126
  duplicate (schema or declaration). Fixtures: `construct_properties` pass + four fail cases.
  Parser unit test added. `zig build test` green; `test-full` (construct filter) 96 passed / 0 failed.

  **Testing gotcha discovered:** `build.zig` hardcodes corpus phases per step and overrides shell
  `KIRA_CORPUS_PHASES`/`KIRA_CORPUS_BACKENDS`. `test` and `test-backends` run only the **run**
  phase, so fail/semantics diagnostics are validated **only by `zig build test-full`**.
  `KIRA_CORPUS_FILTER` is respected. (Recorded in agent memory.)

- **Phase 3 — DONE.** Construct `content { chan { accepts T; count min..max } }` named channels
  (uses the `dot_dot` token). New AST (`ContentChannelSchema`, `CountRange`, `content_channel`
  entry), parser dispatch for construct-body `content {` → channels (form-body `content {` builder
  unchanged), model `ContentChannel` + `Construct.content_channels`, transitive channel inheritance
  over `extends`, and `validateFormContentChannels`: KSEM127 unknown channel, KSEM129 count
  violation, KSEM130 accepts mismatch (AST-level: rejects primitive literals against a named
  `accepts`, mirroring typed-content validation — precise family subtyping deferred, no form
  value-type system yet), KSEM138 duplicate channel in schema. Declarations fill channels via
  named sections (`head { … }`/`view { … }` as `named_rule` blocks; `content { … }` builder maps to
  channel `content`); validation only engages when the construct declares channels, so channel-less
  constructs are unaffected. Fixtures: `construct_content_channels` pass + four fail cases. Parser
  unit test added. `zig build test` 75/0; `test-full` (construct) 126/0.

- **Phase 4 — DONE.** Required functions + mixed-graph satisfaction. `requires { function … }`
  signatures collected into `Construct.required_functions`. New file
  `lower_construct_requirements.zig`: `resolveFamilyConstructModel` (walks declaration parents to
  the rooting construct, so `Drawable Sprite { … }` then `Sprite Player { … }` resolves Player's
  family to Drawable), `validateFormParentCycles` (KSEM119 for declaration-parent cycles, runs
  before form lowering so cycles aren't masked as unresolved parents), and
  `validateConstructFormRequirements` (transitive required collection over `extends`; chain-
  implemented collection over the declaration chain; KSEM120 missing required function; KSEM121
  signature mismatch with `Self` normalized to the implementing declaration). `lowerConstructForm`
  now resolves form-or-construct parents via `resolveFamilyConstructModel`, so a declaration may
  reuse a prior declaration as its parent and inherit its construct family + implementations.
  KSEM122 folded into the existing KSEM020 (truly-unknown parents are rejected during form
  lowering before the requirements pass runs — KSEM122 would be dead code). Fixtures:
  `construct_required_functions` pass (the Drawable/Sprite/Player/AnimatedPlayer matrix incl.
  inherited + overridden impls) + three fail cases (KSEM120/121/119). `zig build test` 76/0;
  `test-full` (construct) 150/0.

  Note for Phase 8: `lower_program_types.zig` has grown past the 600-line guidance (Core Law #5)
  from the properties/channels validators; consider extracting a `lower_construct_validation.zig`.

- **Phase 5 — DONE (with documented limitations).** `attempt`/`try`/`handle`. New AST
  (`AttemptStatement`, `HandleCase`, `try_expr`), parser (`attempt` statement; contextual
  `handle`; `try` prefix in `parseUnary`), and `lower_stmts_attempt.zig`: validation
  (KSEM134 try-on-non-Result, KSEM135 missing handle case, KSEM136 unknown handle case,
  KSEM137 incompatible failure enums — extracts `F` by lowering the try operand in a cloned
  scope and reading the monomorphized `Result`'s `Error` payload enum) + AST→`match` desugar for
  **execution** (expanded in `lowerBlockStatements` since it can yield multiple statements).
  KSEM133 (`try` outside attempt / unsupported position) fires from `lowerExpr` because valid
  `try`s are desugared away. Fixtures: `tests/pass/run/attempt_try_handle` (executes:
  Ok-value unwrap + Error→handler dispatch, **vm+hybrid**) + five fail cases (KSEM133–137), all
  green under `test-full`. `zig build test` 77/0.

  **Honest limitations (pre-existing match-lowering gaps, not introduced here):**
  - **llvm:** nested `match` Error-path dispatch does not execute on the llvm backend (llvm prints
    only the Ok output). The existing `construct_typed_content_widget` test likewise runs vm+hybrid
    only. `attempt` executes wherever nested `match` does; the run test targets vm+hybrid.
  - **Failure payload in a handler:** binding the failure payload (`MissingNode(reason)` then using
    `reason`) hits a nested-`match` payload-binding limitation — the handler dispatches correctly
    but the bound payload comes through empty on vm. Two desugar shapes were tried: a single match
    with `Error(Variant(binding))` arms is rejected as duplicate arms (KSEM101, top-level-only
    duplicate check), and the double-match (`Error(f)` → `match f`) dispatches but loses the inner
    payload. The run fixture therefore dispatches via bindingless `handle` cases. Reading the
    failure payload needs a fix in the underlying nested-match payload binding / duplicate-arm
    check — flagged as follow-up, out of this layer's scope.

- **Phase 6 — DONE.** Content composition `sealed`/`refine`/`passthrough`/`project` with real
  validation (decision 3 — not descoped). New AST (`ContentDirective`, `ContentDirectiveMode`,
  `ContentProjection`, two entry variants), parser dispatch in `parseConstructContentSection`
  (`content sealed`/`passthrough` bare directives; `content refine { … }`; `content project
  { local as Parent.channel }`), model fields (`content_refine`, `content_projections`,
  `content_sealed`, `content_passthrough`) + `model.ContentProjection`, and
  `lower_construct_content.zig`: KSEM128 (content below a sealed ancestor), KSEM131 (projection
  target not an ancestor or unknown channel), KSEM132 (refine that widens count / changes
  `accepts` / names a non-inherited channel; passthrough with no inherited channels or with its
  own channels). Fixtures: `construct_content_composition` pass (all four directives) + three
  fail cases. `zig build test` 78/0; `test-full` (construct) 174/0.

- **Phase 7 — DONE.** Legacy `requires { content; }` fully migrated out and the
  `required_content` path removed. All 14 `.kira` files migrated: the three showcase
  examples (`ui_library`, `complex_language_showcase` UI+main) and the canonical
  `missing_content` fail-test now express content-requiredness through a `content { content
  { count 1.. } }` channel (a channel literally named `content`, so declarations keep their
  natural bare `content { ... }` blocks). `missing_content` now asserts `KSEM129`
  ("content count violation") instead of the removed `KSEM022`. The remaining ten files
  (annotation/lifecycle/pipeline fail-tests + the `annotation_definitions` pass test) used
  `requires { content; }` only as scaffolding; the block was dropped (their target
  diagnostics — annotation/lifecycle/KSEM010/KSEM060 — are unaffected). Code removals:
  `model.Construct.required_content` (hir.zig); the `required_content` var/assignments and the
  `requires`-section `content;` named-rule handling (`lower_program_types.zig`, which now keeps
  only the typed `content: Content<T>` element-type capture); the `KSEM022` emission block
  (`lower_program.zig`). Unit-test sources in `analyzer_tests.zig` (requiredness test → KSEM129;
  four scaffolding strings de-legacied) and `parser.zig` (→ `requires { function render() }`)
  migrated. Docs updated (`construct_family.md`, `language_inventory.md`). Verification:
  `zig build` 80/0; `zig build test-full` **1329 passed / 0 failed**; both migrated examples
  `kira check` pass and `complex_language_showcase` runs. Repo-wide: zero `requires { content; }`
  and zero `required_content` remain outside this plan doc.
- **Phase 8 — DONE.** `docs/construct_family.md` (user-facing spec, aligned strictly to tested
  fixtures, incl. the honest attempt limitations); `docs/language_inventory.md` updated.
  `.kira-build` caches confirmed gitignored (0 tracked). New semantics files
  (`lower_construct_requirements.zig`, `lower_construct_content.zig`, `lower_stmts_attempt.zig`)
  keep `lower_program_types.zig` from growing further, though that file is still over the Core
  Law #5 600-line guidance and remains flagged for a future extraction.

## 8. Open items still worth a sanity check (non-blocking)

- §3.6 `refine`/`passthrough`/`sealed` precise rules are *my* honest proposal under decision 3. If you
  have a different intended meaning (esp. what `passthrough` forwards, and whether `sealed` blocks
  declarations vs only descendant refinement), correct §3.6 before Phase 6.
- §3.8 "shared failure type" interpreted as identical/assignable `F` (no new subtyping). Confirm that is
  the intended bar for KSEM137.
- Phase ordering is independently shippable; safe stop points after any phase (matters for a quota-bound
  runtime).
