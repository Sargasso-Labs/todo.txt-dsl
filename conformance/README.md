# Conformance suite

Language-neutral test cases for the todo.txt DSL. `SPEC.md` is the prose;
these files are the contract. Any client — the bash addons here, the
[mobilis](https://github.com/Sargasso-Labs/mobilis) Android app, the Vala
desktop app — proves conformance by running every case.

The version of the suite is in [`VERSION`](VERSION) and follows the spec
version. Clients pin a version by pinning a commit of this repository (for
example as a git submodule).

## Case files

Each file in `cases/` is a JSON array of `{name, input, expect, xfail?}`.
Shapes are described in [`schema.json`](schema.json).

| File | Spec | Input | Expect |
|---|---|---|---|
| `parse.json` | §1.0 line grammar | one line | prefix fields, description, projects, contexts, ordered token stream |
| `keys.json` | §1.2 key set | one line | typed key fields, unknown keys (`extras`), per-line diagnostics |
| `canonical.json` | §3.2 canonicalization | one line | canonical string and its md5 |
| `lint.json` | §2.3 lint | a list directory (`todo.txt`, `done.txt`, `.idseq`) | diagnostics, and the directory after `--fix` |

### Rules for runners

- **Partial expectations.** Only the fields present in `expect` are checked.
- **Lossless round trip.** For every `parse.json` and `keys.json` case, a
  client that can serialise tasks MUST reproduce `input` byte for byte when
  the task was not edited.
- **Order matters** for `tokens`, `projects`, `contexts`, `wait`, `extras`
  and `diagnostics` in `keys.json`. In `lint.json`, compare diagnostics as a
  set sorted by `(file, line, code, key)`.
- **`xfail`** lists clients that are known not to pass a case yet, with the
  reason. A runner for client `C` reports a case in `xfail.C` as `XFAIL`
  when it fails and as `XPASS` when it passes; neither fails the run. Remove
  the entry once the client is fixed.
- Lines are given without a trailing newline. Files in `lint.json` are
  written one entry per line, each terminated by `\n`.

## Runners

| Client | Command |
|---|---|
| bash addons | `bash tests/test_conformance.sh` (needs `jq`; runs `canonical.json` and `lint.json`) |
| mobilis | `./gradlew :shared:jvmTest` (submodule at `dsl/`) |

## Changing the suite

1. Change `SPEC.md` first; add a Decision Log entry if behaviour changes.
2. Add or edit cases. Prefer a new case over widening an old one.
3. Bump `VERSION` (minor for new rules, patch for new cases of existing rules).
4. Mark clients that now fail with `xfail` and a reason.
