#!/usr/bin/env bash
# test_everyday_usage.sh — Comprehensive end-to-end simulations of real-world everyday usage
#
# Tests modeled on real user workflows (GTD, topydo conventions, multi-list triage,
# subtasks, delegation, text editor hand-editing, and Microsoft To Do cloud sync).

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
        fail "$label (missing '$expected' in: '$content')"
    fi
}

assert_not_contains() {
    local content="$1" unexpected="$2" label="$3"
    if [[ "$content" != *"$unexpected"* ]]; then
        PASS=$((PASS + 1))
    else
        fail "$label (unexpectedly contained '$unexpected')"
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

new_env() {
    local name="$1"
    HOME="$TMP/env-$name"
    TODO_DIR="$HOME/.todo/logbook"
    TODO_FILE="$TODO_DIR/todo.txt"
    DONE_FILE="$TODO_DIR/done.txt"
    mkdir -p "$TODO_DIR" "$HOME/.todo"
    printf '0\n' > "$HOME/.todo/.idseq"
    export HOME TODO_DIR TODO_FILE DONE_FILE
}

write_mock_curl() {
    mkdir -p "$TMP/bin"
    cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$CURL_LOG"
if [[ " $* " == *" -X POST "* ]]; then
    printf '%s\n' "${MOCK_POST_RESPONSE:-{\"id\":\"mock-msft-id\"}}"
elif [[ " $* " == *" -X PATCH "* ]]; then
    printf '%s\n' "${MOCK_PATCH_RESPONSE:-{\"id\":\"patched-id\"}}"
elif [[ " $* " == *" -X DELETE "* ]]; then
    printf '%s\n' ""
else
    printf '%s\n' "${MOCK_GET_RESPONSE:-{\"value\":[]}}"
fi
EOF
    chmod +x "$TMP/bin/curl"
    export PATH="$TMP/bin:$PATH"
}

write_creds() {
    mkdir -p "$HOME/.config/todo-sync"
    printf 'MSFT_ACCESS_TOKEN=mock-token-xyz\nMSFT_LIST_ID=mock-logbook-list\n' > "$HOME/.config/todo-sync/credentials"
    chmod 600 "$HOME/.config/todo-sync/credentials"
}

# ==============================================================================
# Suite 1: Morning Routine & Daily Focus Planning (GTD Review)
# ==============================================================================
test_morning_routine_and_daily_focus() {
    new_env morning-routine
    local TODAY
    TODAY=$(date +%F)

    # 1. Capture today's focus task with myday: and star:
    run bash "$ROOT/addons/capture" "(A) Critical production deployment +infra star:1 myday:${TODAY} due:${TODAY}"
    assert_status 0 "$STATUS" "morning: capture starred focus task"

    # 2. Capture a task with an expired yesterday myday:
    run bash "$ROOT/addons/capture" "Read documentation on eBPF +learning myday:2026-01-01"
    assert_status 0 "$STATUS" "morning: capture expired myday task"

    # 3. Capture deferred task (t: threshold date in future)
    run bash "$ROOT/addons/capture" "Plan Q4 budget review +finance t:2026-12-01 s:someday"
    assert_status 0 "$STATUS" "morning: capture future threshold task"

    # 4. Capture task becoming actionable today (t: is today)
    run bash "$ROOT/addons/capture" "Submit monthly expense report +finance t:${TODAY} s:next"
    assert_status 0 "$STATUS" "morning: capture today threshold task"

    # Test daily focus filter: grep "myday:$(date +%F)"
    local MYDAY_MATCHES
    MYDAY_MATCHES=$(grep "myday:${TODAY}" "$TODO_FILE" || true)
    assert_contains "$MYDAY_MATCHES" "Critical production deployment" "morning: myday filter matches today"
    assert_not_contains "$MYDAY_MATCHES" "Read documentation" "morning: myday filter excludes expired dates"

    # Test threshold filter: grep "t:$(date +%F)"
    local THRESHOLD_MATCHES
    THRESHOLD_MATCHES=$(grep "t:${TODAY}" "$TODO_FILE" || true)
    assert_contains "$THRESHOLD_MATCHES" "Submit monthly expense report" "morning: threshold filter matches today"
    assert_not_contains "$THRESHOLD_MATCHES" "Plan Q4 budget review" "morning: threshold filter excludes future"

    # Test sync push with star projection
    write_creds
    CURL_LOG="$TMP/curl-morning.log"
    : > "$CURL_LOG"
    export CURL_LOG
    write_mock_curl

    run bash "$ROOT/addons/sync" push
    assert_status 0 "$STATUS" "morning: sync push succeeds"
    assert_contains "$(cat "$CURL_LOG")" '"importance":"high"' "morning: star:1 projected to importance:high"
    assert_contains "$(cat "$CURL_LOG")" "\"dueDateTime\":{\"dateTime\":\"${TODAY}T00:00:00.0000000\"" "morning: due date sent in payload"
}

# ==============================================================================
# Suite 2: Ad-Hoc Fast Capture & CLI Ergonomics (Smoothness)
# ==============================================================================
test_rapid_capture_ergonomics() {
    new_env capture-ergonomics
    local TODAY
    TODAY=$(date +%F)

    # 1. Unquoted arguments with multiple spaces and tags
    run bash "$ROOT/addons/capture" Pick up fresh sourdough and oat milk @groceries +home
    assert_status 0 "$STATUS" "ergonomics: unquoted capture"
    assert_contains "$(cat "$TODO_FILE")" "Pick up fresh sourdough and oat milk @groceries +home id:1" "ergonomics: preserved unquoted words"

    # 2. Capture URL with query strings, slashes, and symbols
    run bash "$ROOT/addons/capture" "Review API issue https://github.com/todotxt/todo.txt-cli/issues/123?sort=asc&filter=open @github"
    assert_status 0 "$STATUS" "ergonomics: capture with complex URL"
    assert_contains "$(cat "$TODO_FILE")" "https://github.com/todotxt/todo.txt-cli/issues/123?sort=asc&filter=open" "ergonomics: URL preserved untouched"

    # 3. Capture with non-key colons (file lines, re:, timestamps)
    run bash "$ROOT/addons/capture" "Fix panic in auth/jwt.go:142 (re: expired token) +auth @backend"
    assert_status 0 "$STATUS" "ergonomics: capture with non-key colons"
    assert_contains "$(cat "$TODO_FILE")" "auth/jwt.go:142 (re: expired token)" "ergonomics: non-key colons preserved"

    # 4. Capture with quotes and ampersands
    run bash "$ROOT/addons/capture" "Discuss \"Q3 Targets & Hiring\" with team +strategy"
    assert_status 0 "$STATUS" "ergonomics: capture with quotes and ampersand"
    assert_contains "$(cat "$TODO_FILE")" "\"Q3 Targets & Hiring\"" "ergonomics: inner quotes preserved"

    # 5. Capture with priority (A) and DATE_ON_ADD=1
    run env DATE_ON_ADD=1 bash "$ROOT/addons/capture" "(A) Urgent server hotfix +ops"
    assert_status 0 "$STATUS" "ergonomics: capture with priority and date"
    assert_contains "$(cat "$TODO_FILE")" "(A) ${TODAY} Urgent server hotfix +ops id:5" "ergonomics: date follows priority before text"

    # 6. Rejection of pre-existing id: tag in captured text
    run bash "$ROOT/addons/capture" "Malicious text trying to inject id:999"
    assert_status 1 "$STATUS" "ergonomics: rejects task text containing id:"
    assert_contains "$OUTPUT" "already contains id:" "ergonomics: diagnostic explains id collision"
}

# ==============================================================================
# Suite 3: Project Breakdown, Hierarchies & Subtasks (DL-5 / P05)
# ==============================================================================
test_project_hierarchy_and_subtasks() {
    new_env project-subtasks
    local TODAY
    TODAY=$(date +%F)

    # 1. Capture parent project milestone
    run bash "$ROOT/addons/capture" "Launch v2.0 mobile app +mobile"
    assert_status 0 "$STATUS" "subtasks: capture parent milestone"
    local PARENT_ID=1

    # 2. Capture 3 subtasks referencing parent via p:1
    run bash "$ROOT/addons/capture" "Finalize iOS release build +mobile p:${PARENT_ID} s:next"
    assert_status 0 "$STATUS" "subtasks: capture child 1"
    run bash "$ROOT/addons/capture" "Upload Google Play bundle +mobile p:${PARENT_ID} wait:@android"
    assert_status 0 "$STATUS" "subtasks: capture child 2"
    run bash "$ROOT/addons/capture" "Publish release notes blog post +mobile p:${PARENT_ID} due:2026-10-30"
    assert_status 0 "$STATUS" "subtasks: capture child 3"

    # 3. Query all children of parent via grep
    local CHILD_COUNT
    CHILD_COUNT=$(grep -c "p:${PARENT_ID}" "$TODO_FILE")
    assert_eq "$CHILD_COUNT" "3" "subtasks: grep finds all 3 children"

    # 4. Resolve parent by ID
    run bash "$ROOT/addons/resolve" "$PARENT_ID"
    assert_status 0 "$STATUS" "subtasks: resolve parent task"
    assert_contains "$OUTPUT" "Launch v2.0 mobile app" "subtasks: resolve outputs parent text"

    # 5. Complete parent and archive to done.txt
    # Simulate todo.sh do & archive: remove line 1 from todo.txt and append completed line to done.txt
    sed -i '1d' "$TODO_FILE"
    printf 'x %s Launch v2.0 mobile app +mobile id:%d\n' "$TODAY" "$PARENT_ID" > "$DONE_FILE"

    # 6. Verify resolve STILL finds parent in done.txt
    run bash "$ROOT/addons/resolve" "$PARENT_ID"
    assert_status 0 "$STATUS" "subtasks: resolve finds completed parent in done.txt"
    assert_contains "$OUTPUT" "done.txt:1: x" "subtasks: resolve indicates done.txt location"

    # 7. Lint --orphans must NOT report p:1 as an orphan because parent exists in done.txt
    run bash "$ROOT/addons/lint" --orphans
    assert_status 0 "$STATUS" "subtasks: lint does not flag archived parent as orphan"
    assert_not_contains "$OUTPUT" "p:${PARENT_ID} not found" "subtasks: no false positive orphan warning"
}

# ==============================================================================
# Suite 4: Orphan Detection and Repair (P06 / Dangling parent removal)
# ==============================================================================
test_orphan_detection_and_repair() {
    new_env orphan-repair

    # Create task with a dangling parent p:888 that does not exist anywhere
    printf 'Subtask with broken parent p:888 id:1\nValid task id:2\n' > "$TODO_FILE"

    # Lint without fix should report issue
    run bash "$ROOT/addons/lint" --orphans
    assert_status 1 "$STATUS" "orphan: lint detects broken p:888"
    assert_contains "$OUTPUT" "p:888 not found in any file" "orphan: diagnostic pinpoints missing parent"

    # Lint with --fix --orphans should strip dangling p:888 cleanly
    run bash "$ROOT/addons/lint" --fix --orphans
    assert_status 0 "$STATUS" "orphan: lint --fix --orphans repairs line"
    assert_contains "$OUTPUT" "removed dangling p:888" "orphan: reports removal"
    assert_eq "$(cat "$TODO_FILE")" "Subtask with broken parent id:1
Valid task id:2" "orphan: line preserved without dangling p: key"
    assert_contains "$(cat "$TODO_FILE.bak")" "p:888" "orphan: backup retains original line"
}

# ==============================================================================
# Suite 5: GTD Delegation & Action Lifecycle (s: and wait:)
# ==============================================================================
test_gtd_delegation_and_lifecycle() {
    new_env gtd-lifecycle

    # 1. Capture tasks across different GTD states
    run bash "$ROOT/addons/capture" "Review vendor NDA +legal s:wait wait:@alice due:2026-10-20"
    assert_status 0 "$STATUS" "gtd: capture waiting task with delegate"
    run bash "$ROOT/addons/capture" "Investigate database sharding options +db s:someday e:high"
    assert_status 0 "$STATUS" "gtd: capture someday task"
    run bash "$ROOT/addons/capture" "Upgrade Kubernetes cluster to 1.32 +infra s:blocked wait:@devops"
    assert_status 0 "$STATUS" "gtd: capture blocked task"
    run bash "$ROOT/addons/capture" "Draft weekly engineering summary @computer s:next"
    assert_status 0 "$STATUS" "gtd: capture next action"

    # 2. Filter delegated tasks
    local WAITING_PERSONS
    WAITING_PERSONS=$(grep -oE 'wait:@[a-zA-Z0-9_]+' "$TODO_FILE" | sort)
    assert_contains "$WAITING_PERSONS" "wait:@alice" "gtd: found delegation to @alice"
    assert_contains "$WAITING_PERSONS" "wait:@devops" "gtd: found delegation to @devops"

    # 3. Simulate Alice replying: transition task from s:wait to s:next
    sed -i 's/s:wait wait:@alice/s:next/' "$TODO_FILE"
    assert_contains "$(cat "$TODO_FILE")" "Review vendor NDA +legal s:next" "gtd: transitioned to next action"

    # 4. Verify Next Actions list
    local NEXT_ACTIONS
    NEXT_ACTIONS=$(grep "s:next" "$TODO_FILE")
    assert_contains "$NEXT_ACTIONS" "Review vendor NDA" "gtd: next actions include unblocked task"
    assert_contains "$NEXT_ACTIONS" "Draft weekly engineering summary" "gtd: next actions include existing next"
}

# ==============================================================================
# Suite 6: Energy Levels and Situational Context Filtering (e: & @context)
# ==============================================================================
test_energy_and_context_filtering() {
    new_env energy-filtering

    run bash "$ROOT/addons/capture" "Design consensus state machine +engine e:high @desk"
    run bash "$ROOT/addons/capture" "Organize downloads folder and clean desktop e:low @computer"
    run bash "$ROOT/addons/capture" "Schedule annual dentist checkup e:low @phone"
    run bash "$ROOT/addons/capture" "Write RFC for audit logging +compliance e:med @desk"

    # Filter for low energy tasks (afternoon exhaustion)
    local LOW_ENERGY
    LOW_ENERGY=$(grep "e:low" "$TODO_FILE")
    assert_contains "$LOW_ENERGY" "Organize downloads folder" "energy: low energy task 1 found"
    assert_contains "$LOW_ENERGY" "Schedule annual dentist checkup" "energy: low energy task 2 found"
    assert_not_contains "$LOW_ENERGY" "Design consensus state machine" "energy: high energy excluded"

    # Filter for phone calls context
    local CALLS
    CALLS=$(grep "@phone" "$TODO_FILE")
    assert_contains "$CALLS" "Schedule annual dentist checkup" "energy: context filter found phone task"
    assert_not_contains "$CALLS" "Organize downloads" "energy: other contexts excluded"
}

# ==============================================================================
# Suite 7: Text Editor Hand-Edits & Bulk Lint Backfill (P03 / P04)
# ==============================================================================
test_editor_hand_edits_and_lint_repair() {
    new_env editor-hand-edits
    printf '10\n' > "$HOME/.todo/.idseq"

    # Simulate user opening todo.txt in editor and pasting 4 tasks without IDs,
    # plus accidentally duplicating an existing ID (id:5)
    cat > "$TODO_FILE" <<'EOF'
Existing task id:5
Pasted task one without id
Pasted task two without id +project @work
Accidental copy paste duplicate id:5
Pasted task three without id due:2026-11-01

EOF

    # 1. Lint detects missing IDs and duplicate
    run bash "$ROOT/addons/lint"
    assert_status 1 "$STATUS" "editor: lint detects un-ID'd lines and duplicate"
    assert_contains "$OUTPUT" "missing id:" "editor: missing ID detected"
    assert_contains "$OUTPUT" "duplicate id:5" "editor: duplicate ID detected"

    # 2. Lint --fix repairs everything
    run bash "$ROOT/addons/lint" --fix
    assert_status 0 "$STATUS" "editor: lint --fix succeeds"

    # Check that .idseq incremented from 10:
    # 3 missing lines backfilled (11, 12, 13) + 1 duplicate reassigned (14) = 14
    local FINAL_SEQ
    FINAL_SEQ=$(cat "$HOME/.todo/.idseq")
    assert_eq "$FINAL_SEQ" "14" "editor: idseq incremented atomically to 14"

    # Check that every non-empty line now has a unique ID
    run bash "$ROOT/addons/lint"
    assert_status 0 "$STATUS" "editor: lint passes cleanly after fix"
    assert_not_contains "$OUTPUT" "missing id:" "editor: no missing IDs remain"
    assert_not_contains "$OUTPUT" "duplicate id:" "editor: no duplicates remain"
}

# ==============================================================================
# Suite 8: Multi-List Lifecycle & Movement (P07 / P08)
# ==============================================================================
test_multi_list_lifecycle() {
    new_env multi-list
    local INBOX_DIR="$HOME/.todo/inbox"
    local PERSONAL_DIR="$HOME/.todo/personal"
    mkdir -p "$INBOX_DIR" "$PERSONAL_DIR" "$TODO_DIR/.sync"
    : > "$TODO_DIR/.list-meta"

    write_creds
    CURL_LOG="$TMP/curl-multilist.log"
    : > "$CURL_LOG"
    export CURL_LOG
    write_mock_curl

    # 1. Capture rough idea into inbox
    TODO_DIR="$INBOX_DIR" TODO_FILE="$INBOX_DIR/todo.txt" run bash "$ROOT/addons/capture" "Research alternative auth providers +auth"
    assert_status 0 "$STATUS" "multilist: captured into inbox"
    assert_contains "$(cat "$INBOX_DIR/todo.txt")" "id:1" "multilist: allocated id:1 in inbox"

    # 2. Triage: Move task from inbox to logbook (synced list)
    sed -i '1d' "$INBOX_DIR/todo.txt"
    printf 'Research alternative auth providers +auth id:1\n' >> "$TODO_FILE"
    assert_eq "$(wc -l < "$INBOX_DIR/todo.txt" | tr -d ' ')" "0" "multilist: removed from inbox"

    # 3. Sync push logbook: task is discovered without map row and created in To Do
    run bash "$ROOT/addons/sync" push
    assert_status 0 "$STATUS" "multilist: sync pushed moved task"
    assert_contains "$OUTPUT" "created remote id:1" "multilist: created remote task"
    assert_contains "$(cat "$TODO_DIR/.sync/map.tsv")" "1"$'\tmock-msft-id\t' "multilist: map row created"

    # 4. Demote task: Move from logbook to personal (local only)
    sed -i '1d' "$TODO_FILE"
    printf 'Research alternative auth providers +auth id:1\n' >> "$PERSONAL_DIR/todo.txt"

    # 5. Sync push logbook: task gone locally -> without --force-delete it hits threshold (100% of list deleted)
    MOCK_GET_RESPONSE='{"value":[{"id":"mock-msft-id","title":"Research alternative auth providers +auth id:1"}]}'
    export MOCK_GET_RESPONSE
    run bash "$ROOT/addons/sync" push
    assert_status 2 "$STATUS" "multilist: sync protects against full list clearing"
    assert_contains "$OUTPUT" "Sync aborted" "multilist: safety threshold triggered"

    # Re-run with --force-delete confirms remote deletion
    run bash "$ROOT/addons/sync" push --force-delete
    assert_status 0 "$STATUS" "multilist: sync deletes task moved out of logbook with force-delete"
    assert_contains "$OUTPUT" "deleted remote id:1" "multilist: reports remote delete"
    assert_eq "$(wc -l < "$TODO_DIR/.sync/map.tsv" | tr -d ' ')" "0" "multilist: map row removed"
    assert_contains "$(cat "$CURL_LOG")" "DELETE" "multilist: curl DELETE issued"
}

# ==============================================================================
# Suite 9: Microsoft To Do Cloud Sync Real-World Scenarios
# ==============================================================================
test_cloud_sync_scenarios() {
    new_env cloud-sync
    mkdir -p "$TODO_DIR/.sync"
    : > "$TODO_DIR/.list-meta"
    write_creds
    CURL_LOG="$TMP/curl-cloud.log"
    : > "$CURL_LOG"
    export CURL_LOG
    write_mock_curl

    # 1. Reminder format expansion: rem:YYYY-MM-DDTHHMM -> ISO 8601
    printf 'Doctor appointment due:2026-11-15 rem:2026-11-15T0930 star:1 id:10\n' > "$TODO_FILE"
    run bash "$ROOT/addons/sync" push
    assert_status 0 "$STATUS" "cloud: push task with reminder"
    assert_contains "$(cat "$CURL_LOG")" '"reminderDateTime":{"dateTime":"2026-11-15T09:30:00.0000000","timeZone":"UTC"}' "cloud: reminder expanded to full ISO with seconds"

    # 2. Local completion sync: x YYYY-MM-DD ...
    printf 'x 2026-10-10 Doctor appointment due:2026-11-15 rem:2026-11-15T0930 star:1 id:10\n' > "$TODO_FILE"
    : > "$CURL_LOG"
    run bash "$ROOT/addons/sync" push
    assert_status 0 "$STATUS" "cloud: push completed task"
    assert_contains "$(cat "$CURL_LOG")" '"status":"completed"' "cloud: task status completed sent"

    # 3. Offline edit vs cloud edit conflict (Local-wins policy)
    local HASH_PREV
    HASH_PREV=$(printf 'Doctor appointment' | md5sum | cut -d' ' -f1)
    printf '10\tmock-msft-id\t%s\tsynced\n' "$HASH_PREV" > "$TODO_DIR/.sync/map.tsv"
    printf 'Doctor appointment rescheduled due:2026-11-20 star:1 id:10\n' > "$TODO_FILE"

    MOCK_GET_RESPONSE='{"value":[{"id":"mock-msft-id","title":"Doctor appointment updated remotely"}]}'
    export MOCK_GET_RESPONSE
    run bash "$ROOT/addons/sync" push
    assert_status 0 "$STATUS" "cloud: conflict resolved with local wins"
    assert_contains "$OUTPUT" "local wins" "cloud: local wins reported"

    # Verify conflict file was written
    local CONFLICT_FILES
    CONFLICT_FILES=$(find "$TODO_DIR/conflicts" -name '10-*.txt' 2>/dev/null || true)
    if [ -n "$CONFLICT_FILES" ]; then
        PASS=$((PASS + 1))
        assert_contains "$(cat "$CONFLICT_FILES")" "REMOTE at" "cloud: conflict file records remote text"
        assert_contains "$(cat "$CONFLICT_FILES")" "Doctor appointment rescheduled" "cloud: conflict file records local text"
    else
        fail "cloud: conflict file was not generated"
    fi

    # 4. Lint warns about unresolved conflict files
    run bash "$ROOT/addons/lint"
    assert_status 1 "$STATUS" "cloud: lint warns about unresolved conflict file"
    assert_contains "$OUTPUT" "unresolved conflict file" "cloud: lint diagnostic mentions conflict"

    # 5. D10 Safety threshold when bulk deleting
    # Setup 15 tasks in map.tsv
    : > "$TODO_DIR/.sync/map.tsv"
    for i in $(seq 1 15); do
        printf '%d\tremote-%d\toldhash\tsynced\n' "$i" "$i" >> "$TODO_DIR/.sync/map.tsv"
    done
    : > "$TODO_FILE" # Accidentally emptied

    MOCK_GET_RESPONSE='{"value":[{"id":"remote-1","title":"Task 1"}]}'
    export MOCK_GET_RESPONSE
    run bash "$ROOT/addons/sync"
    assert_status 2 "$STATUS" "cloud: deletion threshold aborted catastrophic delete"
    assert_contains "$OUTPUT" "Sync aborted" "cloud: safety threshold message emitted"

    # Overriding with --force-delete proceeds
    run bash "$ROOT/addons/sync" --force-delete
    assert_status 0 "$STATUS" "cloud: force-delete succeeds"

    # 6. Status check without map
    rm -f "$TODO_DIR/.sync/map.tsv"
    run bash "$ROOT/addons/sync" status
    assert_status 0 "$STATUS" "cloud: sync status handles missing map"
    assert_contains "$OUTPUT" "(no map file)" "cloud: status reports no map"
}

# ==============================================================================
# Suite 10: Global ID Resolution Across Sublists and done.txt (P02 Ergonomics)
# ==============================================================================
test_cross_list_resolve_ergonomics() {
    new_env cross-list-resolve
    mkdir -p "$HOME/.todo/inbox" "$HOME/.todo/archive"

    printf 'Captured task in inbox id:42\n' > "$HOME/.todo/inbox/todo.txt"
    printf 'x 2026-09-01 Old archived task id:99\n' > "$HOME/.todo/archive/done.txt"

    # User has TODO_DIR set to logbook sublist (the default in todo.cfg.example)
    TODO_DIR="$HOME/.todo/logbook"
    export TODO_DIR

    # Resolve task in inbox
    run bash "$ROOT/addons/resolve" 42
    assert_status 0 "$STATUS" "resolve: finds task across sibling inbox list"
    assert_contains "$OUTPUT" "inbox/todo.txt:1: Captured task in inbox id:42" "resolve: reports exact file and line"

    # Resolve task in archive/done.txt
    run bash "$ROOT/addons/resolve" 99
    assert_status 0 "$STATUS" "resolve: finds task in archive/done.txt"
    assert_contains "$OUTPUT" "archive/done.txt:1: x 2026-09-01 Old archived task id:99" "resolve: reports archived line"
}

# ==============================================================================
# Suite 11: Consecutive Rapid Captures & Counter Integrity
# ==============================================================================
test_rapid_consecutive_captures() {
    new_env rapid-captures

    for i in $(seq 1 20); do
        run bash "$ROOT/addons/capture" "Batch task iteration $i +batch"
        assert_status 0 "$STATUS" "rapid: capture iteration $i"
    done

    # Verify counter equals 20
    assert_eq "$(cat "$HOME/.todo/.idseq")" "20" "rapid: .idseq reached exactly 20"

    # Verify 20 lines in todo.txt
    assert_eq "$(wc -l < "$TODO_FILE" | tr -d ' ')" "20" "rapid: todo.txt has 20 lines"

    # Verify lint reports 0 duplicates and 0 missing IDs
    run bash "$ROOT/addons/lint"
    assert_status 0 "$STATUS" "rapid: lint passes with 0 issues on 20 captured tasks"
}

# ==============================================================================
# Main Runner
# ==============================================================================
echo "Running Everyday Usage Test Suite..."
test_morning_routine_and_daily_focus
test_rapid_capture_ergonomics
test_project_hierarchy_and_subtasks
test_orphan_detection_and_repair
test_gtd_delegation_and_lifecycle
test_energy_and_context_filtering
test_editor_hand_edits_and_lint_repair
test_multi_list_lifecycle
test_cloud_sync_scenarios
test_cross_list_resolve_ergonomics
test_rapid_consecutive_captures

echo "--------------------------------------------------------"
echo "Everyday Usage Suite: $PASS assertions passed; $FAIL failed"
echo "--------------------------------------------------------"
[ "$FAIL" -eq 0 ]
