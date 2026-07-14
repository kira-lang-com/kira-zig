# Package manifest (`package.kira`)

A Kira package is described by a manifest. The modern manifest is
`package.kira`, a Kira **declaration** authored in the language itself; the
legacy `kira.toml` is still fully supported for any package that has not been
migrated.

When both files exist in a package directory, **`package.kira` wins** — it is
first in every manifest-discovery precedence list. `kira.lock` is unchanged and
is shared by both manifest formats.

## Shape

`package.kira` is a single construct-form declaration named `Package`, whose
declaration name is the package name. Its members are literal `let` bindings —
the same shape as a `Widget Text { let text: String = "" }` declaration.

```kira
Package LiquidGlass {
    let version = "0.1.0"
    let kind = PackageKind.App
    let defaults = Defaults { executionMode: Backend.Hybrid, buildTarget: BuildTarget.Host }
    let tests = Tests { backends: [Backend.Vm, Backend.Llvm, Backend.Hybrid], phase: TestPhase.Both }
    let dependencies = [
        Dependency { name: "Foundation", version: "0.1.0" }
    ]
    let nativeLibraries = [
        NativeLibrary {
            name: "sokol_gfx",
            linkMode: LinkMode.Static,
            headers: Headers {
                entrypoint: "third_party/sokol/sokol_gfx.h",
                includeDirs: ["third_party/sokol"],
                defines: ["SOKOL_DUMMY_BACKEND"]
            },
            sources: ["third_party/sokol/sokol_gfx_impl.c"],
            autobind: Autobind { module: "sokol_gfx", functions: ["sg_setup", "sg_isvalid"], structs: ["sg_desc"] },
            nativeTargets: [
                NativeTarget { triple: "x86_64-linux-gnu", systemLibs: ["X11"] }
            ]
        }
    ]
}
```

The manifest is parsed by the Kira lexer + parser only (no semantic analysis)
and walked statically. Every initializer must be a **literal** — a string,
implicit enum member (`.Variant`; qualified `Enum.Variant` remains accepted),
array literal, or struct literal. A computed
initializer (a call, arithmetic, an identifier) is rejected in v1 with a clear
diagnostic.

Struct-literal fields accept `:` today (`executionMode: .Hybrid`). The
loader reads the parsed AST, so it is separator-agnostic: once the parser
accepts `=` as well, `executionMode = .Hybrid` will load identically.

## Schema

The schema is declared in Kira in `foundation/app/Kira/PackageSchema.kira`.
`Backend` (`foundation/app/Kira/Build.kira`) and `PackageKind`
(`foundation/app/Kira/Package.kira`) already existed and are reused.

| Field | Type | Notes |
|---|---|---|
| `version` | `String` | Package version. |
| `kind` | `PackageKind` | `.App` or `.Library`. Default `.App`. |
| `kira` | `String` | Kira language version (optional). |
| `moduleRoot` | `String` | Logical module-root prefix (libraries). |
| `defaults` | `Defaults` | `{ executionMode: Backend, buildTarget: BuildTarget }`. |
| `tests` | `Tests` | `{ backends: [Backend], phase: TestPhase }`. |
| `dependencies` | `[Dependency]` | `{ name, version }` (registry) or `{ name, path }`. |
| `nativeLibraries` | `[NativeLibrary]` | Inline native libraries (see below). |
| `assets` | `[String]` | Project-relative asset paths (wasm packaging). |

Enums: `Backend { Vm Llvm Hybrid Wasm }`, `BuildTarget { Host Wasm }`,
`TestPhase { Check Run Both }`, `LinkMode { Static Dynamic }`,
`AutobindMode { Listed AllPublic }`.

Target-specific native compile/link settings use `nativeTargets` rather than
the reserved Kira keyword `targets`; each `NativeTarget` identifies a full
`<arch>-<os>-<abi>` triple.

### `NativeLibrary`

```kira
NativeLibrary {
    name: "sokol_gfx",
    linkMode: LinkMode.Static,
    headers: Headers { entrypoint: "...", includeDirs: ["..."], defines: ["..."] },
    sources: ["...c"],
    autobind: Autobind { module: "sokol_gfx", functions: ["..."], structs: ["..."] }
}
```

Native libraries are compiled **from source** for the active target into
`.kira-build/native/<arch>-<os>-<abi>/lib<name>.a` — there are no per-target
`static_lib` paths in `package.kira`. All paths are resolved relative to the
package root.

### The autobind output law

For an inline native library, generated FFI bindings **always** land at
`app/bindings/<module>.kira`. There is intentionally no configurable `output`.
If a migrated declaration includes an `output`, it is ignored with a warning
(`KMAN011`). `import <module>` resolves the generated binding because
`app/bindings/<module>.kira` (and `app/bindings/<module>/main.kira`) are import
candidates.

> Deprecation note: the legacy sibling `<pkg>/bindings/` import root and the
> `.toml` `[autobinding] output` key still work for unmigrated packages
> (Foundation relies on the sibling `bindings/` root). Only `package.kira`
> inline libraries are subject to the always-on `app/bindings/` law.

## The `Tests` matrix

`bare kira test <pkg>` reads `Tests { backends, phase }`:

- **`backends`** — the matrix (`Backend.Vm`, `.Llvm`, `.Hybrid`). Each backend
  runs the suite once; a per-backend tally is printed and every backend must
  end `0 failed`.
- **`phase`** — `Check` compiles/analyzes `Test` and `FailTest` declarations
  without executing `Test` bodies (`FailTest`s still evaluate — they are
  compile-time). `Run` executes. `Both` does both.
- **`--backend <b>`** overrides the matrix to a single backend.
- A manifest with no `tests` field keeps the historical single-backend
  behavior.

## Migrating from `kira.toml`

```
kira migrate-manifest <project-dir|kira.toml>
```

Reads the legacy `kira.toml`, inlines any `native_libraries = ["NativeLibs/*.toml"]`
entries as `NativeLibrary { ... }` declarations, and writes `package.kira`
beside it. `kira.toml` is left in place (deleting it is your choice; because
`package.kira` wins, tests immediately load from the new manifest). Per-target
`static_lib` paths and the autobind `output` field are dropped — build-from-
source and the `app/bindings/` law replace them.
Legacy package names that are not Kira identifiers are normalized for the
declaration name (for example, `backend-policy-app` becomes
`backend_policy_app`).

> After migrating a native library, review the inlined `headers`/`sources`
> paths: they are copied verbatim from the `NativeLibs/*.toml` (whose paths were
> relative to `NativeLibs/`), and inline paths resolve relative to the package
> root, so they may need rebasing.

## Diagnostics

Every schema violation carries a source span. Errors make the manifest
unusable; warnings do not.

| Code | Meaning |
|---|---|
| `KMAN001` | Missing `Package` declaration. |
| `KMAN002` | Non-`let` member in a `Package` body. |
| `KMAN003` | `let` field with no initializer. |
| `KMAN004` | Unknown field for `Package`/`Defaults`/`Tests`/`Dependency`/`NativeLibrary`/`Headers`/`Autobind`. |
| `KMAN005` | Unknown `PackageKind` variant. |
| `KMAN006` | Unknown `Backend`/`LinkMode` (or unsupported test backend). |
| `KMAN007` | Unknown `TestPhase`. |
| `KMAN008` | `Tests` with no `backends`. |
| `KMAN009` | Missing required field (`Dependency.name`, `NativeLibrary.name`, `Autobind.module`, or a dependency lacking both version and path). |
| `KMAN010` | More than one `Package` declaration. |
| `KMAN011` | (warning) `output` on an `Autobind` is ignored. |
| `KMAN012` | Field expected a string literal. |
| `KMAN013` | Field expected an array literal. |
| `KMAN014` | Field expected a struct literal. |
| `KMAN015` | Field expected an enum member (`.Variant` or `Enum.Variant`). |

Loader diagnostics are manifest-level (they describe `package.kira` itself),
not source-level Kira diagnostics, so they cannot be expressed as Foundation
`FailTest` cases (which assert diagnostics for a quoted Kira **source**
snippet). They are covered by the manifest loader and declaration-writer unit
tests.
