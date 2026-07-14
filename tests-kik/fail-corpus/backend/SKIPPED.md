# Backend fail-corpus — skipped cases

> RESOLVED 2026-07-13: `vm_native_main` is now MIGRATED as a pass-corpus package
> at `tests-kik/corpus/native-main` (manifest `Tests { backends: [Hybrid, Llvm] }`
> — vm deliberately absent, which IS the pass-differential — plus `NmNativeDouble`
> exercising @Native code on both backends). Its `@Native @Main`'s `"native main\n"`
> is proven identical across hybrid+llvm by `KIRA_TEST_PARITY=1`. The historical
> rationale below is retained for context.

## vm_native_main — per-backend-differential PASS expectation, no diagnostic to assert
Legacy `tests/fail/backend/vm_native_main/expect.toml`:

    backends = ["hybrid", "llvm"]
    [phases.check] result = "pass"
    [phases.build] result = "pass"
    [phases.run]   result = "pass"  stdout = "native main\n"

Source:

    @Main
    @Native
    function main() { print("native main"); return; }

The expect.toml declares the case **passes** on `hybrid` and `llvm` (with stdout
`"native main\n"`). It does NOT declare a failing phase, and there is NO `diagnostic_code`
or `diagnostic_title` anywhere. The "fail" dimension — `@Native main` being unsupported
on the `vm` backend — is expressed only by `vm`'s **absence** from the `backends` list,
never as an asserted rejection with a code or title.

This is a per-backend-DIFFERENTIAL expectation: passes on `hybrid` + `llvm`, and is simply
not covered on `vm`. `FailTest` asserts a rejection (a matching `TestFailure`) on EVERY
backend listed in its `backends` block, and it needs a code or a distinctive title
substring to match. Here:
  - there is no failing subset with an asserted diagnostic to encode, and
  - the real expectation is "pass on hybrid+llvm" — which is a pass-corpus expectation,
    not an expected-diagnostic one.

Therefore `vm_native_main` cannot be authored as a `FailTest`. It belongs in the pass
corpus (asserting pass on hybrid+llvm). `SKIPPED`.

This package is created (kira.toml + app/main.kira, name `KikFailBackend`, prefix `Fbk`)
to hold this record.
