# Kira Debugger — Architecture

Full source-level debugger for Kira across **VM**, **LLVM/native**, and **hybrid**,
hardware-assisted on every platform that has debug registers, software-fallback
everywhere else. Built to Core Law #1 (VM/LLVM/Hybrid/WASM parity) — a debug
feature that works in only one backend is unfinished.

Recon source: `.codex/work/debugger/` (7-subsystem map, workflow wiv8thneg).

## The one hard truth from recon

**No source location survives past low IR.** Spans exist in HIR + MIR (`mid_ir`)
as byte offsets, then are *dropped* at `packages/kira_ir/src/lower_from_hir.zig`
(the span-drop boundary — `current_span` is used only for error text, never
attached to emitted `ir.Instruction`s). Consequences, all confirmed:

- `ir.Function`/`ir.Instruction` (`packages/kira_ir/src/ir.zig:128/145`): no location.
- `bytecode.Function`/`Instruction` (`packages/kira_bytecode`): no line table, no source-file ref.
- `vm_prepare.zig` fuses ops + removes labels + appends trailing `ret`, so even
  the `pc -> original-instruction-index` correspondence is destroyed.
- `kira_llvm_backend`: no DIBuilder/DILocation/DISubprogram; `llvm_c.zig` binds
  zero DI symbols; clang invoked without `-g`.

Everything source-level (line breakpoints, step, `list`, locals-by-name, native
DWARF) depends on rebuilding this. **Phase 1 is the tent-pole.**

## Package layout — new `packages/kira_debug`

Layer: above runtime backends, below CLI. Depends on `kira_core, kira_source,
kira_ir, kira_bytecode, kira_runtime_abi, kira_vm_runtime, kira_hybrid_runtime,
kira_diagnostics`. Wired by one Package literal in `build.zig:20-68` + one entry
in `build_support/test_roots.zig` + `docs/package_graph.md`. Files kept < 600
lines (Core Law #5) — many small focused modules.

```
packages/kira_debug/src/
  root.zig                 # exports/wiring only
  debug_info.zig           # SourceLoc, LineTable, LocalNameTable, ScopeTable (the shared model)
  session.zig              # DebugSession orchestrator (breakpoints, step controller, target mux)
  breakpoint.zig           # BreakpointTable: source line <-> {vm pc | native address}, conditions
  step.zig                 # step-in/over/out/continue state machine (frame-depth + line driven)
  frame.zig                # unified Frame model (backend, function_id, name, loc, locals view)
  value_view.zig           # render a runtime_abi.Value for inspection (read-only, respects owned[])
  eval.zig                 # expression eval in frame context (print / conditional breakpoints)
  vm_target.zig            # in-process VM DebugTarget impl
  native_target.zig        # attached-process DebugTarget impl (drives hw/*)
  hybrid_target.zig        # unified target: muxes vm_target + native_target across the boundary
  hw/
    controller.zig         # HwBreakpointController interface + capability table + dispatch
    darwin_arm64.zig       # Mach exception ports + ARM_DEBUG_STATE64 (BVR/BCR, WVR/WCR)
    darwin_x86_64.zig      # Mach ports + x86_DEBUG_STATE64 (DR0-DR7)
    linux_arm64.zig        # ptrace NT_ARM_HW_BREAK / NT_ARM_HW_WATCH
    linux_x86_64.zig       # perf_event_open(HW_BREAKPOINT) self-debug / ptrace DR0-DR7
    windows.zig            # Get/SetThreadContext DR0-DR7 + vectored exception handler
    software_trap.zig      # BRK/INT3 patching fallback when HW slots exhausted / unavailable (+wasm)
  protocol/
    dap.zig                # Debug Adapter Protocol (subset) server — editor integration
    verbs.zig              # kira_live LiveMessageKind debug-verb extension (in-tree transport)
  repl.zig                 # interactive CLI REPL (break/watch/continue/step/next/finish/bt/locals/print/list)
```

## Phase plan (foundation-first; each phase lands compiling + tested)

### Phase 1 — Debug-info foundation (serial, build-verified, invasive)
Thread source locations end-to-end. Shared/hot files → done serially by main thread.

1. **IR**: add `locations: []SourceLoc` (parallel to `instructions`) + `local_names`
   table to `ir.Function`. Populate in `lower_from_hir.zig` from the `current_span`
   it already computes at `:259/:356`; record name↔slot as locals are lowered.
   `SourceLoc = { file_id: u32, span: Span }` (byte offsets; line/col derived via
   `kira_source` `LineMap` at debug time, as diagnostics already do).
2. **bytecode**: new optional `DebugInfo` section on `bytecode.Module` — source
   file table + per-`Function` `pc -> SourceLoc` line table + local-name table.
   Populate in `compiler.zig`. Serialize/deserialize behind a **bumped .kbc
   version with an optional section** (old modules load with empty debug info).
3. **vm_prepare**: remap the line table across fusion + label-removal + trailing
   `ret`. Build `original_index -> SourceLoc` pre-fusion, carry a
   `prepared_pc -> SourceLoc` map on `PreparedFunction`.
4. **LLVM/DWARF**: bind `LLVMDIBuilder*`, `LLVMDIBuilderCreate{CompileUnit,File,
   Function,...}`, `LLVMSetCurrentDebugLocation2`, `LLVMSetSubprogram`,
   `AddModuleFlag("Debug Info Version")` in `llvm_c.zig`. In `backend_capi.zig`
   create DICompileUnit+DIFile+DISubprogram/fn; set DILocation per instruction
   from the IR `locations`; `llvm.dbg.declare` locals (names from the IR local
   table). Add `-g` in `emitObjectFileViaClang`; `dsymutil` on macOS; ensure the
   incremental `cgu_build.zig` path also carries `-g`. Preserve metadata across
   the `LLVMPrintModuleToString` round-trip (or prefer direct emit).
5. **Verify**: `zig build`; `llvm-dwarfdump` shows `.debug_line`; corpus still green.

### Phase 2 — VM debug engine (serial on vm files, then parallel)
1. `.breakpoint` opcode (INT3-style): patched into the mutable `PreparedFunction.code`
   copy; new dispatch arm restores original + yields to session. Zero-cost when unset.
2. Explicit VM frame stack on `Vm` (pushed in `runPrepared` prologue / popped on
   exit) so backtraces are walkable — today frames are native Zig recursion only.
3. `Vm.Hooks` debug seam: `on_stop(reason, frame_stack) -> resume|step|...`.
4. Software watchpoints in VM: check on local/slot stores.
5. Variable inspection: read registers/locals + heap type lookups
   (`heap.getStructTypeName`, `getClosure`) — **read-only, must respect `owned[]`
   bools** (never drop/move an inspected value → no double-free/leak).

### Phase 3 — Hardware controller (parallel; well-isolated per-OS files)
`hw/controller.zig` interface + capability table; six impls. Each: set/clear HW
breakpoint (exec) + watchpoint (r/w/rw) in N register slots; single-step; catch
debug exception; read/write registers + memory. Software-trap fallback when slots
exhausted or arch unsupported. WASM → clear "hardware debug unavailable, software
instrumentation only" diagnostic (never a smoke pass). Capability table advertises
per-target `{max_hw_breakpoints, max_watchpoints, single_step}`.

### Phase 4 — Targets + session + protocol (parallel modules on shared session iface)
`DebugTarget` interface (attach, set/clear bp, continue, step, read frames, read
vars, read/write mem). `vm_target` (in-process), `native_target` (drives hw/*),
`hybrid_target` (muxes both, reads manifest `FunctionExecution` to label each
frame VM vs native; wraps `hooks.call_native`, the runtime invoker, and the
`runPrepared` loop — the three boundary funnels from recon). `session.zig` ties
breakpoints + step + target. Protocol: DAP subset (`protocol/dap.zig`) for editors
+ in-tree `verbs.zig` extending `LiveMessageKind`. Reuse `kira_diagnostics`
renderer for "stopped at line" caret views; reuse `kira_live` framed TCP transport.

### Phase 5 — CLI `kira debug` + REPL (serial 7-edit registration)
Compiler-forced registration (recon `cli` map): `CommandKind` tag, `ParsedCommand`
variant + `DebugOptions`, `Parser.parseDebug`, `CommandArgs.toArgs`, `app.zig`
dispatch, `HelpText`, `commands/debug.zig`. Model on `run.zig`: VM in-process by
default; `--backend llvm|hybrid` attaches `native_target`/`hybrid_target` to a
child launched stopped (hidden `__debug-runner` helper, mirroring
`__run-hybrid-artifact`). REPL verbs: `break FILE:LINE`, `watch EXPR`, `continue`,
`step`, `next`, `finish`, `bt`, `frame N`, `locals`, `print EXPR`, `list`.

### Phase 6 — Tests (parallel), real execution only
- Unit tests per `kira_debug` module.
- Corpus (`tests/pass/run/debug_*`) with `backends = ["vm","llvm","hybrid"]`
  exercising: line breakpoints hit at the right source line; step in/over/out;
  backtrace names; locals-by-name; conditional breakpoint; watchpoint.
- DWARF proof: build `-g`, assert `.debug_line` via `llvm-dwarfdump`, drive `lldb`
  in batch to set a source-line breakpoint and confirm it stops at the right line
  (real native execution, not a marker).
- Negative: WASM HW request → diagnostic + negative test it can't smoke-pass.
- Parity: each capability proven on VM **and** native (+ hybrid where relevant).

## Cross-backend frame model (unify VM + native)

```
Frame {
  backend: enum { vm, native },
  function_id: u32,          // shared id across VM module + hybrid manifest
  name: []const u8,
  loc: ?SourceLoc,           // from Phase 1 line table (VM) / DWARF (native)
  locals: []LocalView,       // name + type + rendered value (read-only)
}
```
Hybrid: read `FunctionManifest.execution` (`calling.zig`) to tag each frame VM vs
native; correlate the two stacks at `BridgeValue` boundaries.

## Hardware matrix (Phase 3 detail)

| OS / arch | exec breakpoint | watchpoint | exception delivery |
|---|---|---|---|
| macOS arm64 | `ARM_DEBUG_STATE64` BVR/BCR (~6) | WVR/WCR (~4) | Mach exception port, `EXC_BREAKPOINT` |
| macOS x86_64 | `x86_DEBUG_STATE64` DR0-DR3/DR7 | DR7 R/W bits | Mach exception port |
| Linux x86_64 | perf_event(HW_BP) self / ptrace DR | DR7 | SIGTRAP / perf fd |
| Linux arm64 | ptrace `NT_ARM_HW_BREAK` | `NT_ARM_HW_WATCH` | SIGTRAP |
| Windows x64/arm64 | `CONTEXT.Dr0-3/Dr7` | Dr7 R/W | vectored handler, `EXCEPTION_SINGLE_STEP` |
| WASM | none → software instrument | none | diagnostic, no smoke |

Software fallback (`software_trap.zig`): patch `BRK #0` (arm64) / `int3` (x86) at
target address, save/restore original bytes, step over by temporarily restoring.
Used when HW slots exhausted or arch has no HW path.

## Non-negotiables (from AGENTS.md)
- Parity: every feature VM + LLVM (+ hybrid/WASM where applicable) or explicitly
  rejected with a diagnostic + negative test.
- No smoke: a breakpoint "hit" must be proven by real stop at real line; DWARF
  proven by dwarfdump + lldb, not by "build succeeded".
- No Python; no root-level Zig; files < 600 lines; `.codex/` only for scratch.
- `zig build` + `zig build test` (or targeted corpus) green before done.
