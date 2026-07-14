# Kira Native Memory Model

Authoritative model for heap ownership on the native (LLVM) backend. Every
backend, runtime-helper, and drop-elaboration change must conform to this
document. The goals, in priority order:

1. **Maximum performance.** No implicit deep copies of unbounded data. Ever.
2. **No leaks.** Every owned heap value has exactly one drop obligation that
   runs at a statically known point.
3. **No unsound frees.** A double free or use-after-free is always worse than
   a leak; where the model cannot yet prove single ownership, it leaks
   conservatively and this document records the gap.

The model is Rust's affine model adapted to Kira: **moves transfer, borrows
observe, drops run once at scope exit**. There is no reference counting and
no garbage collector.

Partial moves are Rust-parity: a binding may reach scope exit with fields
moved out when every moved field's type transfers by pointer with storage
nulling — arrays, enums, and type-erased (some/any) values. The moved read
voids/nulls the field slot on every backend (VM `load_indirect` moved-void,
LLVM `load.move.field` null), so the base drops with only its remaining
fields (`let root = app.content`). A moved field whose type is a NAMED
STRUCT still blocks the drop (KSEM107/KIR003): struct reads copy with
aliasing Any interiors (§3), so the base's drop would free storage the copy
references.

Consuming receivers are Rust's `self` methods: a construct-declaration
method marked `@Consuming` (and every `body` accessor, implicitly) takes its
receiver OWNED. The call transfers the receiver at every dispatch edge —
implicit move for owned receivers (no `move` keyword on method calls), deep
clone for borrowed PLAIN-STRUCT receivers, and a KSEM157/KIR002 rejection
for borrowed receivers carrying Any storage. Every implementation of a
consuming family method inherits the owned receiver (uniform dispatch), the
callee owns and drops the shell, and a body block's `{ content }` capture is
a partial move out of owned self — the field slot nulls, the shell drops
with its remaining fields, nothing clones. This is the body-consumes-self
model that makes wrapper widgets leak-free by construction
(tests/pass/run/consuming_body_wrapper_parity). Tracked type-erased values
MOVE through consuming dispatch (`moveOrCloneToHeap` hands the shell over
and nulls the slot — never a runtime-typed clone).

## 1. Core rules

- **One owner.** Every heap allocation is owned by exactly one place: a
  register cleanup slot, a local slot, an aggregate (struct field, array
  element, enum payload, closure capture, native-state slot), or the caller
  of a returning function. Ownership is established at the allocation site
  and moves along dataflow edges the checker has verified.
- **Moves are free.** Transferring ownership copies a pointer and nulls the
  source's cleanup slot (`onEscape`). This is the ONLY way unbounded data
  (structs, arrays, construct/Any trees) crosses an ownership boundary.
- **Borrows are free.** A read out of an aggregate, a borrow parameter, or a
  field access aliases the owner's storage. Borrows are never dropped and
  never cloned. The CHECKER — not codegen — is responsible for rejecting
  borrows that outlive or duplicate their owner.
- **Drops are typed and run once.** At scope exit (or loop overwrite) each
  live cleanup slot runs the destructor matching what the slot owns:
  `kira_destroy_<T>` for structs, `kira_array_release` (+ element destructor)
  for arrays, typed enum destroy, tag-safe closure release, plain `free` for
  string buffers. Escaped (moved-out) slots are null and drop to a no-op.
- **Codegen must never "fix" ownership with a deep clone.** If a dataflow
  edge would need a clone to be sound (borrowed value flowing into an owned
  position), that is either (a) a checker gap to close with a diagnostic, or
  (b) a documented conservative leak. It is NEVER an implicit deep copy —
  that converts a soundness question into an unbounded performance and
  memory cost, which is how a widget tree becomes a multi-gigabyte-per-frame
  explosion.

## 2. The bounded-clone whitelist

Implicit clones are permitted ONLY for values whose size is statically
bounded and small. Anything not on this list moves or borrows.

| Value | Clone cost | Where cloned |
|---|---|---|
| String buffer | O(len), typically bytes | consumer stores (field/element/state/capture/enum payload), clone-on-read out of aggregates, untracked `ret` sources |
| Enum block | 16 B (+ string payload box) | borrowed enum into owned position, struct copy |
| Closure block | 16 B + 32 B × captures (captures are trivial types by KSEM117) | consumer stores, struct copy, borrowed-into-owned |

Strings are the deliberate exception to move-purity: the language treats
`String` as a Copy value type, so buffers deep-copy at ownership boundaries.
This is bounded per-value and measured cheap. (Perf follow-up: a
borrow-only-use peephole for compare/print/len readers.)

**Never on this list:** arrays as a whole tree (element deep-clone runs only
for the whitelist above and for struct elements via the pre-existing borrowed
array promotion — see §4), structs of unbounded content beyond the language's
own value-semantics copies, and above all **type-erased (construct_any / Any)
values — widget trees**. These move. Always.

## 3. Type-erased (Any / construct) values

Any-typed values (`some T`, construct instances, widget trees) are opaque
`i64` shell pointers with a type-id header (written by `kira_struct_alloc`,
read back by `kira_struct_type_id`). The header enables **runtime-typed
destruction** (`kira_capi_dynamic_destroy` recovers `kira_destroy_<T>`), but
typed destruction may run ONLY where single ownership is structurally
guaranteed:

- `.struct_ptr` cleanup slots (construct-family virtual-call results and
  owned Any parameters): the caller escapes owned arguments and results are
  recorded exactly once, so the slot is the sole owner.
- Plain-call results whose callee is PROVEN by the fresh-Any return analysis
  (backend_capi_fresh_any.zig) to return a fresh owned tree on every path:
  every `ret` source traces to an alloc_struct, a construct-virtual result,
  or a fresh-Any callee's result, flowing only through non-borrow locals.
  These results get the same `.struct_ptr` slot — this is what reclaims
  `body`/factory widget trees. The analysis starts pessimistic, so recursion
  and any alias-shaped return path resolve to "not fresh" (untracked).
- Native-state interior release, for slot kinds whose stores establish
  ownership (see §5).

Everywhere else, Any values keep **alias semantics with no free**:

- Any struct fields: stores move the pointer in (escape); struct copies alias
  the field; `kira_release_contents_<T>` does NOT free Any fields.
- `[Any]` array elements: moved in (escape); `kira_array_release`'s element
  fallback frees tagged closures only, not Any shells.
- Any native-state slots: moved in (escape); the interior release skips them
  (§5).
- Borrowed Any into an owned element / a plain return the fresh-Any analysis
  could not prove: passes the alias through; nothing frees it.

These aliases are the model's **known conservative leaks** — bounded per tree
node per rebuild, reclaimable only once the checker can enforce move-only Any
flows end to end (no aliasing struct copies, no borrowed-into-owned). Closing
that is checker/semantics work, not codegen cloning. Until then: leak, never
copy, never guess-free.

**Structural assumptions the checker does not yet enforce** (the two typed
drop points above rely on them; violating code is UNSOUND today and closing
them is roadmap item 1):

1. A construct-family virtual method returns a FRESH tree (a tracked owned
   value, escaped through `ret`) — not an alias of storage it retains
   (`return self.cached`). The caller's `.struct_ptr` slot deep-destroys the
   result at scope exit.
2. An owned/move Any parameter receives a value the caller HANDED OVER
   (owned sources are escaped at the call site) — not a borrowed alias. The
   callee's param slot deep-destroys it at scope exit.

Both held for every measured app/corpus flow (UI builders construct fresh
trees and pass freshly built children). Codegen must never "repair" a
violation with a clone; the fix is a checker diagnostic.

## 4. Per-kind ownership summary

| Kind | Producer owns | Consumer store | Read out | Borrowed → owned edge |
|---|---|---|---|---|
| struct (`ffi_struct`) | alloc / call result slot | MOVE (heap-stable via moveOrCloneToHeap when stack-backed) | borrow | deep clone (pre-existing promotion; language value semantics) |
| array | alloc / call result slot | MOVE + drop-replaced (self-store guarded) | borrow | deep clone (pre-existing promotion — bounded by the language's value semantics for arrays) |
| string | every producer (concat, coercion, read-clone, call result) | CLONE (whitelist) | CLONE (whitelist) | clone (whitelist) |
| enum | alloc / call result slot (every call result is tracked — the returned-enum invariant makes them fresh) | move-or-clone (16 B, whitelist) | payload string clones out | clone (whitelist) |
| closure | const_closure / call result slot | CLONE (small block, whitelist) + drop-replaced | borrow (call) | clone (whitelist) |
| construct_any | virtual-call result / owned param slot only | MOVE (alias, escape) — field never freed | borrow | ALIAS (conservative leak; checker gap) |
| native-state token | app code via `nativeState` | — | recover = borrow | — |

Struct/array borrowed→owned deep clones predate this document and implement
the language's value semantics for typed aggregates; they are bounded by what
the user wrote (a typed struct of fields), not by an erased tree. They stay.
If profiling ever shows one hot, the fix is a checker-verified move at the
call site, not a shallower copy.

## 5. Native-state boxes

A `KiraNativeState` payload is an array of tagged bridge slots. Ownership per
slot kind, established by `lowerNativeStateFieldSet` / `lowerAllocNativeState`:

- string: slot owns a clone (whitelist); set drops the replaced buffer.
- array: slot owns (move-or-clone per §4); set drops the replaced value
  (self-store guarded).
- struct: slot owns the SHELL POINTER stored directly (box_struct=false) —
  alloc clones in, set normalizes through moveOrCloneToHeap. The old boxing
  pack shallow-copied the shell and orphaned it (one leaked shell per store).
- closure: slot owns a clone (whitelist); set drops the replaced block.
- enum: slot OWNS its block — alloc clones in, set destroys-replaced +
  move-or-clones (native; hybrid keeps the alias default), the interior
  release frees it via the typed enum destroy (VM parity:
  destroyPreservedNativeStateValue destroys enum slots).
- Any: MOVE — the pointer is stored as-is and an owned source ESCAPES at the
  set site (never cloned, and the frame must not free what the state now
  references). The slot is a conservative leak: the interior release MUST NOT
  free it (another alias may exist until move-only Any is checker-enforced).

`kira_native_state_free` runs `kira_capi_state_interior_release` (installed
by the native global constructor), which frees exactly the owning slot kinds
above — string buffers, arrays with element destructors, boxed structs,
closures, enum blocks — and skips Any aliases. This matches the VM's
`freeNativeState` for the owned kinds.

State TOKENS have no scope-based lifetime (`nativeUserData` handles may
alias them program-long). The C runtime keeps a registry of live tokens
(`kira_native_state_alloc` adds, `kira_native_state_free` unlinks) and an
atexit teardown disposes survivors through the same typed-interior path —
VM parity with `deinitTrackedNativeStates`, and what keeps program-lifetime
states out of the `leaks --atExit` report.

## 6. Runtime helper contracts (C side)

- `kira_destroy_closure(i64)` — tag-safe: frees only values carrying the
  closure high bit; dispatches to the generated typed capture teardown via
  the hook. Safe to call on any raw pointer.
- `kira_capi_closure_clone(i64)` — tag-safe deep clone; pass-through for
  non-closure values.
- `kira_capi_dynamic_destroy(i64)` — tag-safe for closures; type-id switch
  for shells; unknown id = no-op. May be called only at §3 drop points.
- `kira_capi_dynamic_clone(i64)` — EXISTS but must have no call sites for
  unbounded values; retained for the future move-only Any completion and for
  tooling. Adding a call site for Any data requires amending this document.
- `kira_array_release` / `kira_array_store_release` — free STRING-tag
  element buffers, run the element destructor on RAW_PTR elements; hybrid
  defers to the VM.
- `kira_struct_free` / `kira_struct_type_id` — shell alloc/read primitives;
  the type-id header is 8 bytes before the payload pointer.

## 7. Invariants that keep the model sound

1. **Record once.** Every allocation/result is recorded into at most ONE
   cleanup slot, exactly once. Double-recording triggers the
   drop-before-overwrite path and destroys a live value (the construct
   virtual-call double-record bug). Guarded by memory_validation.
2. **Escape before the callee frees.** Passing an owned value to an
   owned/move parameter escapes the caller's slot. Callee-side param slots
   exist only for kinds whose call sites uphold this (structs, arrays,
   closures, Any).
3. **Same-value stores are no-ops.** Every drop-replaced store path compares
   old vs incoming and skips both the destroy and the clone on self-store.
4. **Pairing by construction.** A kind is deep-destroyed at an edge iff the
   matching store edge establishes ownership (move or whitelist clone). The
   enum typed pair and the Any alias rules both follow from this: change one
   side of an edge and you must change the other.
5. **Hybrid is VM-owned.** None of the native frees/clones above run for
   hybrid-mode values; hooks stay uninstalled and `deep_closures` gates every
   native-only path.

## 8. Validation gates

- `zig build test-full` — full corpus, vm/llvm/hybrid parity.
- `check_leaks = true` corpus cases — zero-leak proof on the native binary
  for every flow the model claims leak-free (strings, enums, closures,
  arrays, structs). Any-tree cases assert parity + crash-freedom only, until
  §3's checker gap closes.
- `zig build verify-memory` — invariant guards pinning each rule above.
- App gate: editor offscreen RSS must be FLAT per frame and per interaction
  (`/usr/bin/time -l` + `KIRA_UI_CLICK_SCRIPT`), and `leaks --atExit`
  residuals must not scale with frames or clicks.

## 9. Roadmap (in order)

1. **Checker-enforced move-only Any** (closes §3's conservative leaks): reject
   or explicitly-annotate aliasing Any struct copies and borrowed-Any-into-
   owned edges; then flip Any fields/elements to typed destroy with zero
   clones. Body-consumes-self LANDED (`@Consuming` receivers, body accessors
   owned, single-content wrappers leak-free). NEXT CONCRETE STEP — owned-array
   element drain, the last blocker for `@Consuming lower` in kira_ui and the
   editor build: `widgets[index].lower(context)` on an OWNED `[any Widget]`
   must move the element out (array_get `moved`: dst owns, slot tombstones to
   VOID — release/read of a voided slot no-ops/traps deterministically), plus
   owned-array arguments fed by partial-moving a field out of owned self
   (`loweredChildren(context, children)` marks `children` moved). Until then
   kira_ui keeps `borrow [any Widget]` children and non-consuming `lower`.
2. **String borrow peephole**: skip clone-on-read when all consumers are
   compare/print/len.
3. **State-slot replacement**: `uiStateSlotPut` frees the replaced token via
   `kira_native_state_free` (interiors now reclaim correctly).
4. **`[U8]` packed byte arrays**: kill the 24-byte-per-byte bridge-value
   representation (multi-hundred-MB transient on asset loads; the editor's
   startup RSS spike).
