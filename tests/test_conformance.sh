#!/usr/bin/env bash
# test_conformance.sh — Run conformance/cases/*.json against the bash addons
#
# Covers the cases the addons implement:
#   canonical.json  → canonical_hash() from addons/sync
#   lint.json       → addons/lint --orphans  and  addons/lint --fix --orphans
#
# parse.json and keys.json have no bash consumer (the addons use grep/sed
# rather than a parser); they are exercised by typed clients such as mobilis.
#
# Cases listed under "xfail": {"bash": "..."} are reported but do not fail
# the run (see conformance/README.md).

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CASES="$ROOT/conformance/cases"

if ! command -v jq >/dev/null 2>&1; then
    echo "SKIP: jq not found; conformance suite not run"
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
XFAIL=0
XPASS=0

# report <file> <index> <ok:0|1> <name> <detail>
report() {
    local file="$1" idx="$2" ok="$3" name="$4" detail="$5" reason
    reason=$(jq -r --argjson i "$idx" '.[$i].xfail.bash // empty' "$CASES/$file")
    if [ "$ok" -eq 1 ]; then
        if [ -n "$reason" ]; then
            XPASS=$((XPASS + 1))
            echo "XPASS: $file/$name (remove xfail.bash)"
        else
            PASS=$((PASS + 1))
        fi
    elif [ -n "$reason" ]; then
        XFAIL=$((XFAIL + 1))
        echo "XFAIL: $file/$name — $reason"
    else
        FAIL=$((FAIL + 1))
        echo "FAIL: $file/$name — $detail" >&2
    fi
}

# ------------------------------------------------------------------------------
# canonical.json
# ------------------------------------------------------------------------------

# Load canonical_hash() from the sync addon without executing the addon.
eval "$(sed -n '/^canonical_hash() {/,/^}/p' "$ROOT/addons/sync")"
declare -F canonical_hash >/dev/null || { echo "FAIL: canonical_hash not found in addons/sync" >&2; exit 1; }

test_canonical() {
    local n i name input want got
    n=$(jq length "$CASES/canonical.json")
    for ((i = 0; i < n; i++)); do
        name=$(jq -r ".[$i].name" "$CASES/canonical.json")
        input=$(jq -r ".[$i].input" "$CASES/canonical.json")
        want=$(jq -r ".[$i].expect.md5" "$CASES/canonical.json")
        got=$(canonical_hash "$input")
        if [ "$got" = "$want" ]; then
            report canonical.json "$i" 1 "$name" ""
        else
            report canonical.json "$i" 0 "$name" "md5 $got, expected $want"
        fi
    done
}

# ------------------------------------------------------------------------------
# lint.json
# ------------------------------------------------------------------------------

# setup_list <case-index> <jq path to listDir>  → sets HOME/TODO_DIR/... and writes files
setup_list() {
    local idx="$1" path="$2" f
    HOME="$TMP/lint-$idx"
    rm -rf "$HOME"
    TODO_DIR="$HOME/.todo/logbook"
    TODO_FILE="$TODO_DIR/todo.txt"
    DONE_FILE="$TODO_DIR/done.txt"
    mkdir -p "$TODO_DIR"
    jq -r ".[$idx]$path.idseq" "$CASES/lint.json" > "$HOME/.todo/.idseq"
    for f in todo.txt done.txt; do
        if jq -e ".[$idx]$path.files | has(\"$f\")" "$CASES/lint.json" >/dev/null; then
            jq -r ".[$idx]$path.files[\"$f\"][]" "$CASES/lint.json" > "$TODO_DIR/$f"
        fi
    done
    export HOME TODO_DIR TODO_FILE DONE_FILE
}

# Map lint's WARN lines to "file<TAB>line<TAB>code<TAB>key", sorted.
lint_diagnostics() {
    sed -nE \
        -e 's#^WARN  missing id: on .*/([^/:]+):([0-9]+):.*#\1\t\2\tMISSING_ID\t#p' \
        -e 's#^WARN  duplicate id:[0-9]+ later occurrence at .*/([^/:]+):([0-9]+)$#\1\t\2\tDUP_ID\t#p' \
        -e 's#^WARN  p:[0-9]+ not found in any file \(.*/([^/:]+):([0-9]+):.*#\1\t\2\tDANGLING_PARENT\t#p' |
        sort
}

test_lint() {
    local n i name want got detail ok f
    n=$(jq length "$CASES/lint.json")
    for ((i = 0; i < n; i++)); do
        name=$(jq -r ".[$i].name" "$CASES/lint.json")
        ok=1
        detail=""

        # Diagnostics: lint --orphans (read-only)
        setup_list "$i" ".input"
        want=$(jq -r ".[$i].expect.diagnostics[] | [.file, (.line|tostring), .code, (.key // \"\")] | @tsv" \
            "$CASES/lint.json" | sort)
        got=$(bash "$ROOT/addons/lint" --orphans 2>&1 | lint_diagnostics || true)
        if [ "$got" != "$want" ]; then
            ok=0
            detail="diagnostics [$(echo "$got" | tr '\n\t' '; ')] expected [$(echo "$want" | tr '\n\t' '; ')]"
        fi

        # Repair: lint --fix --orphans on a fresh copy
        setup_list "$i" ".input"
        bash "$ROOT/addons/lint" --fix --orphans >/dev/null 2>&1 || true
        for f in todo.txt done.txt; do
            jq -e ".[$i].expect.fixed.files | has(\"$f\")" "$CASES/lint.json" >/dev/null || continue
            want=$(jq -r ".[$i].expect.fixed.files[\"$f\"][]" "$CASES/lint.json")
            got=$(cat "$TODO_DIR/$f")
            if [ "$got" != "$want" ]; then
                ok=0
                detail="$detail; fixed $f [$(echo "$got" | tr '\n' '|')] expected [$(echo "$want" | tr '\n' '|')]"
            fi
        done
        want=$(jq -r ".[$i].expect.fixed.idseq" "$CASES/lint.json")
        got=$(tr -d '[:space:]' < "$HOME/.todo/.idseq")
        if [ "$got" != "$want" ]; then
            ok=0
            detail="$detail; idseq $got expected $want"
        fi

        report lint.json "$i" "$ok" "$name" "$detail"
    done
}

test_canonical
test_lint

echo "--------------------------------------------------------"
echo "Conformance Suite (bash, v$(cat "$ROOT/conformance/VERSION")): $PASS passed; $FAIL failed; $XFAIL xfail; $XPASS xpass"
echo "--------------------------------------------------------"
[ "$FAIL" -eq 0 ]
