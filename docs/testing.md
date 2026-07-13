# Testing in Kira

`kira test <path>` runs every test declaration in a package (or every package
under a directory) on the build-time VM and prints `N passed; M failed; T total`.
Tests are written in pure Kira as Foundation constructs; both kinds below run in
the same suite and are tallied together.

## `Test` — assert a runtime value

A `Test` computes a scalar and compares it against an expected `Result`:

```kira
Test SumsRange {
    test { var s = 0; for i in 0..5 { s = s + i }; return s }
    expect { let e: Result<Int, TestFailure> = Result.Ok(10); return e }
}
```

- `test { ... }` ends with a trailing `return <scalar>` (Int / Bool / String, or a
  struct with a structural / `@Derive(Equatable)` comparator).
- `expect { ... }` returns `Result.Ok(value)` for a value assertion, or
  `Result.Error(TestFailure.Runtime(""))` to assert the body **traps**.
- Declare a backend matrix with a `backends { ... }` block; the verdict is
  build-time and identical across backends, and a non-`vm` backend additionally
  proves the program codegens for it.

## `FailTest` — assert a compile outcome

A `Test` can only live inside a package that itself compiles, so it cannot express
"this code must be **rejected** by the compiler". `FailTest` fills that gap: its
`source` is **quoted** — the surrounding package never parses or analyzes it — and
the runner compiles that text as an isolated synthetic single-file package, once
per declared backend, entirely runner-side (no VM involvement).

```kira
FailTest UseAfterMove {
    backends { vm llvm hybrid }
    source {
        struct Thing { var x: Int }
        function consume(t: Thing) { return }
        @Main function main() {
            let a = Thing { x: 1 }
            consume(move a)
            print(a.x)
            return
        }
    }
    expect { let e: Result<Int, TestFailure> = Result.Error(TestFailure.Compile("KSEM107")); return e }
}
```

### Sections

- `backends { vm llvm hybrid }` — space-separated lowercase idents, a subset of
  `{vm, llvm, hybrid}`. **Omit the block to default to `vm` only.** The FailTest
  passes only if the expected outcome holds on **every** declared backend.
- `source { ... }` — the quoted code to compile, captured verbatim (braces inside
  string literals are handled correctly). Its contents never reach the enclosing
  package's semantic analysis, so ill-formed code cannot poison the suite. The
  block must at least tokenize and brace-balance.
- `source = "..."` — the **raw-string tier**: a single Kira string literal (with
  standard `\n` / `\"` / `\\` escapes) for sources that must not even tokenize —
  e.g. reproducing a **parser** diagnostic.
- `expect { ... }` — read **textually** by the runner (never executed):
  - `Result.Error(TestFailure.Compile("CODE"))` — the compile must **fail** with a
    diagnostic whose code **or** rendered text contains the substring `CODE`.
  - `Result.Ok(1)` — the must-**compile** sentinel: the source must compile cleanly
    on every declared backend. `Ok(1)` is arbitrary but fixed by convention so the
    two forms stay symmetric on `Result<Int, TestFailure>`.

`FailTest` and `Test` declarations coexist freely in the same file and package.

### How the expected code is extracted

The runner reads the expected diagnostic substring and Ok/Error polarity straight
out of the `expect` block's source text (the same textual approach the pure-Kira
test driver uses to read a `Test`'s result type). The `expect` block is never run
in the VM — `TestFailure` / `Result` need not even be in scope where the FailTest
is declared.

### Limitations

- A `source` that needs library imports must be self-contained: it is compiled as
  a standalone single file, not as a member of the surrounding package. Diagnostic
  repros are normally self-contained and need no imports.
- Prefer diagnostics that fail in the frontend (parser / semantics) when declaring
  a multi-backend matrix, so the check is fast and toolchain-independent (a failing
  compile short-circuits before backend codegen). A `Result.Ok` must-compile case
  on `backends { llvm }` requires the LLVM toolchain.
