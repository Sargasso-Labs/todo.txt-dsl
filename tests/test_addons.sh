#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

fail() {
    echo "FAIL: $*" >&2
    FAIL=$((FAIL + 1))
}

assert_status() {
    local expected="$1" actual="$2" label="$3"
    if [ "$expected" -eq "$actual" ]; then
        PASS=$((PASS + 1))
    else
        fail "$label (expected status $expected, got $actual)"
    fi
}

assert_contains() {
    local content="$1" expected="$2" label="$3"
    if [[ "$content" == *"$expected"* ]]; then
        PASS=$((PASS + 1))
    else
        fail "$label (missing '$expected')"
    fi
}

assert_eq() {
    local actual="$1" expected="$2" label="$3"
    if [ "$actual" = "$expected" ]; then
        PASS=$((PASS + 1))
    else
        fail "$label (expected '$expected', got '$actual')"
    fi
}

run() {
    set +e
    OUTPUT=$("$@" 2>&1)
    STATUS=$?
    set -e
}

new_home() {
    HOME="$TMP/home-$1"
    TODO_DIR="$HOME/.todo/list"
    TODO_FILE="$TODO_DIR/todo.txt"
    DONE_FILE="$TODO_DIR/done.txt"
    mkdir -p "$TODO_DIR"
    export HOME TODO_DIR TODO_FILE DONE_FILE
}

test_resolve() {
    new_home resolve
    bash "$ROOT/addons/resolve" usage >/dev/null
    assert_status 0 "$?" "resolve usage"

    run bash "$ROOT/addons/resolve"
    assert_status 1 "$STATUS" "resolve missing argument"
    assert_contains "$OUTPUT" "numeric id" "resolve argument diagnostic"

    run bash "$ROOT/addons/resolve" nope
    assert_status 1 "$STATUS" "resolve nonnumeric argument"

    run bash "$ROOT/addons/resolve" 1
    assert_status 1 "$STATUS" "resolve without list files"

    mkdir -p "$TODO_DIR/archive"
    printf 'First task id:12\nTask id:1\n' > "$TODO_FILE"
    printf 'Archived task id:2' > "$TODO_DIR/archive/done.txt"
    run bash "$ROOT/addons/resolve" 1
    assert_status 0 "$STATUS" "resolve unique task"
    assert_contains "$OUTPUT" "$TODO_FILE:2: Task id:1" "resolve reports line"

    run bash "$ROOT/addons/resolve" 2
    assert_status 0 "$STATUS" "resolve archived task"
    assert_contains "$OUTPUT" "done.txt:1: Archived task id:2" "resolve searches done.txt"

    printf 'Duplicate id:1\n' >> "$TODO_DIR/archive/done.txt"
    run bash "$ROOT/addons/resolve" 1
    assert_status 2 "$STATUS" "resolve duplicate IDs"
    assert_contains "$OUTPUT" "found 2 times" "resolve duplicate diagnostic"

    run bash "$ROOT/addons/resolve" 99
    assert_status 1 "$STATUS" "resolve unknown ID"
}

test_capture() {
    new_home capture
    printf '0\n' > "$HOME/.todo/.idseq"
    bash "$ROOT/addons/capture" usage >/dev/null
    assert_status 0 "$?" "capture usage"

    run bash "$ROOT/addons/capture"
    assert_status 1 "$STATUS" "capture missing text"
    assert_contains "$OUTPUT" "no task text" "capture missing text diagnostic"

    run bash "$ROOT/addons/capture" "Existing id:5 task"
    assert_status 1 "$STATUS" "capture rejects existing id"

    run env DATE_ON_ADD=0 bash "$ROOT/addons/capture" "Buy tea" filters
    assert_status 0 "$STATUS" "capture unquoted task"
    assert_eq "$(cat "$TODO_FILE")" "Buy tea filters id:1" "capture appends task"
    assert_eq "$(cat "$HOME/.todo/.idseq")" "1" "capture increments counter"

    run env DATE_ON_ADD=1 bash "$ROOT/addons/capture" "(B) Review PR"
    assert_status 0 "$STATUS" "capture with date and priority"
    assert_contains "$(cat "$TODO_FILE")" "(B) $(date +%F) Review PR id:2" "capture date follows priority"

    new_home capture-synced
    printf '4\n' > "$HOME/.todo/.idseq"
    mkdir -p "$TODO_DIR/.sync"
    : > "$TODO_DIR/.list-meta"
    run bash "$ROOT/addons/capture" "Sync task star:1"
    assert_status 0 "$STATUS" "capture synced-list task"
    assert_contains "$(cat "$TODO_DIR/.sync/map.tsv")" "5"$'\t\t' "capture creates map row"
    assert_contains "$(cat "$TODO_DIR/.sync/map.tsv")" $'\tnew' "capture marks map row new"
    expected_hash=$(printf 'Sync task' | md5sum | cut -d' ' -f1)
    assert_contains "$(cat "$TODO_DIR/.sync/map.tsv")" "$expected_hash" "capture stores canonical hash"

    new_home capture-counter
    run bash "$ROOT/addons/capture" "First task"
    assert_status 0 "$STATUS" "capture creates missing counter"
    assert_eq "$(cat "$HOME/.todo/.idseq")" "1" "capture initializes counter"
}

test_lint() {
    new_home lint
    printf '1\n' > "$HOME/.todo/.idseq"
    printf 'Task without id\n' > "$TODO_FILE"
    run bash "$ROOT/addons/lint"
    assert_status 1 "$STATUS" "lint reports missing ID"
    assert_contains "$OUTPUT" "missing id:" "lint missing ID diagnostic"

    run bash "$ROOT/addons/lint" --fix
    assert_status 0 "$STATUS" "lint backfills IDs"
    assert_contains "$(cat "$TODO_FILE")" "id:2" "lint allocated ID"
    assert_eq "$(cat "$TODO_FILE.bak")" "Task without id" "lint keeps backup"

    printf 'First id:2\nDuplicate id:2\nChild p:999 id:3\n\n' > "$TODO_FILE"
    run bash "$ROOT/addons/lint" --orphans
    assert_status 1 "$STATUS" "lint reports duplicate and orphan"
    assert_contains "$OUTPUT" "duplicate id:2" "lint duplicate diagnostic"
    assert_contains "$OUTPUT" "p:999 not found" "lint orphan diagnostic"

    printf '10\n' > "$HOME/.todo/.idseq"
    run bash "$ROOT/addons/lint" --fix --orphans
    assert_status 0 "$STATUS" "lint fixes duplicate and orphan"
    assert_contains "$(cat "$TODO_FILE")" "Duplicate id:11" "lint reassigns duplicate ID"
    assert_contains "$(cat "$TODO_FILE")" "Child id:3" "lint strips dangling parent"

    mkdir -p "$TODO_DIR/.sync" "$TODO_DIR/conflicts"
    printf '2\tremote2\thash\tsynced\n999\tremote9\thash\tsynced\n' > "$TODO_DIR/.sync/map.tsv"
    : > "$TODO_DIR/conflicts/pending.txt"
    run bash "$ROOT/addons/lint" --map
    assert_status 1 "$STATUS" "lint reports map and conflicts"
    assert_contains "$OUTPUT" "GC orphan map row" "lint reports orphan map row"
    assert_contains "$OUTPUT" "unresolved conflict file" "lint reports conflict files"

    run bash "$ROOT/addons/lint" --map --fix
    assert_status 1 "$STATUS" "lint fixes map but reports conflict"
    assert_eq "$(wc -l < "$TODO_DIR/.sync/map.tsv" | tr -d ' ')" "1" "lint removes orphan map row"

    new_home lint-all
    printf '0\n' > "$HOME/.todo/.idseq"
    mkdir -p "$HOME/.todo/other"
    printf 'Current task\n' > "$TODO_FILE"
    printf 'Other list task\n' > "$HOME/.todo/other/todo.txt"
    TODO_DIR="$HOME/.todo"
    export TODO_DIR
    run bash "$ROOT/addons/lint" --all --fix
    assert_status 1 "$STATUS" "lint --all reports other-list missing ID"
    assert_contains "$(cat "$TODO_FILE")" "id:1" "lint --all repairs current list"
    assert_eq "$(cat "$HOME/.todo/other/todo.txt")" "Other list task" "lint --all does not rewrite other list"

    new_home lint-lock
    printf 'Missing id\n' > "$TODO_FILE"
    mkdir -p "$TMP/failing-flock"
    printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/failing-flock/flock"
    chmod +x "$TMP/failing-flock/flock"
    run env PATH="$TMP/failing-flock:$PATH" bash "$ROOT/addons/lint" --fix
    assert_status 2 "$STATUS" "lint reports ID lock failure"
    assert_contains "$OUTPUT" "could not lock" "lint lock failure diagnostic"

    new_home lint-empty
    run bash "$ROOT/addons/lint"
    assert_status 0 "$STATUS" "lint with no files"
    assert_contains "$OUTPUT" "no files to scan" "lint no files diagnostic"
}

write_curl_stub() {
    mkdir -p "$TMP/bin"
    cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$CURL_LOG"
if [[ " $* " == *" -X POST "* ]]; then
    printf '%s\n' "${MOCK_POST_RESPONSE:-{\"id\":\"remote-new\"}}"
else
    printf '%s\n' "${MOCK_GET_RESPONSE:-{\"value\":[]}}"
fi
EOF
    chmod +x "$TMP/bin/curl"
    export PATH="$TMP/bin:$PATH"
}

write_credentials() {
    mkdir -p "$HOME/.config/todo-sync"
    printf 'MSFT_ACCESS_TOKEN=test-token\nMSFT_LIST_ID=list-id\n' > "$HOME/.config/todo-sync/credentials"
    chmod 600 "$HOME/.config/todo-sync/credentials"
}

test_sync() {
    new_home sync
    bash "$ROOT/addons/sync" usage >/dev/null
    assert_status 0 "$?" "sync usage"

    run bash "$ROOT/addons/sync" status
    assert_status 1 "$STATUS" "sync requires credentials"

    mkdir -p "$HOME/.config/todo-sync"
    printf 'MSFT_ACCESS_TOKEN=test-token\nMSFT_LIST_ID=list-id\n' > "$HOME/.config/todo-sync/credentials"
    chmod 644 "$HOME/.config/todo-sync/credentials"
    run bash "$ROOT/addons/sync" status
    assert_status 1 "$STATUS" "sync rejects insecure credential mode"

    chmod 600 "$HOME/.config/todo-sync/credentials"
    printf 'MSFT_LIST_ID=list-id\n' > "$HOME/.config/todo-sync/credentials"
    run bash "$ROOT/addons/sync" status
    assert_status 1 "$STATUS" "sync requires access token"
    write_credentials

    run bash "$ROOT/addons/sync" invalid
    assert_status 1 "$STATUS" "sync rejects unknown subcommand"

    mkdir -p "$TODO_DIR/.sync"
    : > "$TODO_FILE"
    CURL_LOG="$TMP/curl.log"
    : > "$CURL_LOG"
    export CURL_LOG
    write_curl_stub
    run bash "$ROOT/addons/sync" status
    assert_status 0 "$STATUS" "sync status without map"
    assert_contains "$OUTPUT" "(no map file)" "sync status empty map"

    printf '1\tremote-1\thash\tsynced\n2\tremote-2\thash\tnew\n' > "$TODO_DIR/.sync/map.tsv"
    printf 'Task id:1\n' > "$TODO_FILE"
    run bash "$ROOT/addons/sync" status
    assert_status 0 "$STATUS" "sync status with map"
    assert_contains "$OUTPUT" "NEW   id:2" "sync status reports new task"
    assert_contains "$OUTPUT" "MOD   id:1" "sync status reports modified task"
    printf '99\tremote-99\thash\tsynced\n' >> "$TODO_DIR/.sync/map.tsv"
    run bash "$ROOT/addons/sync" status
    assert_contains "$OUTPUT" "DEL   id:99" "sync status reports deleted local task"

    printf 'New task due:2026-10-10 rem:2026-10-10T0900 star:1 id:3\n' > "$TODO_FILE"
    : > "$TODO_DIR/.sync/map.tsv"
    : > "$CURL_LOG"
    run bash "$ROOT/addons/sync" push
    assert_status 0 "$STATUS" "sync pushes new task"
    assert_contains "$OUTPUT" "created remote id:3" "sync reports new remote task"
    assert_contains "$(cat "$TODO_DIR/.sync/map.tsv")" "3"$'\tremote-new\t' "sync maps created task"
    assert_contains "$(cat "$CURL_LOG")" "Authorization:" "sync sends bearer token"
    assert_contains "$(cat "$CURL_LOG")" '"importance":"high"' "sync maps star to importance"
    assert_contains "$(cat "$CURL_LOG")" '"reminderDateTime"' "sync maps reminder"

    printf 'Changed task id:3\n' > "$TODO_FILE"
    run env MOCK_GET_RESPONSE='{"@odata.deltaLink":"delta-url","value":[]}' bash "$ROOT/addons/sync" push
    assert_status 0 "$STATUS" "sync pushes changed task"
    assert_contains "$OUTPUT" "pushed id:3" "sync reports local update"
    assert_eq "$(wc -l < "$TODO_DIR/.sync/map.tsv" | tr -d ' ')" "1" "sync updates existing map row"
    assert_eq "$(cat "$TODO_DIR/.sync/delta.link")" "delta-url" "sync saves delta link"

    printf 'Remote unchanged id:5\n' > "$TODO_FILE"
    hash5=$(printf 'Remote unchanged' | md5sum | cut -d' ' -f1)
    printf '5\tremote-5\t%s\tsynced\n' "$hash5" > "$TODO_DIR/.sync/map.tsv"
    run env MOCK_GET_RESPONSE='{"value":[{"id":"remote-5","title":"Remote version"}]}' bash "$ROOT/addons/sync" pull
    assert_status 0 "$STATUS" "sync pulls remote-only change"
    assert_contains "$OUTPUT" "pull id:5" "sync reports remote-only change"
    printf 'Locally changed id:5\n' > "$TODO_FILE"
    run env MOCK_GET_RESPONSE='{"value":[]}' bash "$ROOT/addons/sync" pull
    assert_status 0 "$STATUS" "sync pull skips local-only change"
    if [[ "$OUTPUT" != *"pushed id:5"* ]]; then
        PASS=$((PASS + 1))
    else
        fail "sync pull skips local-only change"
    fi

    printf 'x Completed task id:6\n' > "$TODO_FILE"
    : > "$TODO_DIR/.sync/map.tsv"
    : > "$CURL_LOG"
    run bash "$ROOT/addons/sync" push
    assert_status 0 "$STATUS" "sync pushes completed task"
    assert_contains "$(cat "$CURL_LOG")" '"status":"completed"' "sync maps completion status"
    assert_contains "$(cat "$CURL_LOG")" '"importance":"normal"' "sync defaults importance"

    printf '1\tremote-1\toldhash\tsynced\n' > "$TODO_DIR/.sync/map.tsv"
    : > "$TODO_FILE"
    run env MOCK_GET_RESPONSE='{"value":[{"id":"remote-1","title":"Remote task"}]}' bash "$ROOT/addons/sync" --dry-run
    assert_status 0 "$STATUS" "sync dry-run deletion"
    assert_contains "$OUTPUT" "Planned deletions (1)" "sync plans deletion"

    run env SYNC_DELETE_FRACTION=1 MOCK_GET_RESPONSE='{"value":[{"id":"remote-1","title":"Remote task"}]}' bash "$ROOT/addons/sync" --max-delete=0
    assert_status 2 "$STATUS" "sync honors max-delete override"

    run env MOCK_GET_RESPONSE='{"value":[{"id":"remote-1","title":"Remote task"}]}' bash "$ROOT/addons/sync"
    assert_status 2 "$STATUS" "sync enforces deletion threshold"

    run env MOCK_GET_RESPONSE='{"value":[{"id":"remote-1","title":"Remote task"}]}' bash "$ROOT/addons/sync" --force-delete
    assert_status 0 "$STATUS" "sync forced deletion"
    assert_contains "$OUTPUT" "deleted remote id:1" "sync reports remote deletion"
    assert_eq "$(wc -l < "$TODO_DIR/.sync/map.tsv" | tr -d ' ')" "0" "sync removes deleted map row"

    printf 'Local change id:4\n' > "$TODO_FILE"
    printf '4\tremote-4\toldhash\tsynced\n' > "$TODO_DIR/.sync/map.tsv"
    run env MOCK_GET_RESPONSE='{"value":[{"id":"remote-4","title":"Remote change"}]}' bash "$ROOT/addons/sync" push
    assert_status 0 "$STATUS" "sync resolves local/remote conflict"
    assert_contains "$OUTPUT" "local wins" "sync reports conflict"
    if compgen -G "$TODO_DIR/conflicts/*.txt" >/dev/null; then
        PASS=$((PASS + 1))
    else
        fail "sync saves conflict file"
    fi
}

test_resolve
test_capture
test_lint
test_sync

echo "$PASS assertions passed; $FAIL failed"
[ "$FAIL" -eq 0 ]
