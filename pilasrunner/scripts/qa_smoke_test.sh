#!/bin/bash

# Developer smoke test for YoYo Pilas Runner.
# It creates tiny temporary APK-shaped ZIP files, runs the launcher in dry-run
# mode, checks loader selection, then removes the temporary games/cache/logs.

set -u
set -o pipefail 2>/dev/null || true

SCRIPT_SOURCE="${BASH_SOURCE[0]}"
SCRIPT_DIR="$(cd -P "$(dirname "$SCRIPT_SOURCE")" >/dev/null 2>&1 && pwd)"
RUNTIME_DIR="$(cd -P "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd)"
PORT_DIR="$(cd -P "$RUNTIME_DIR/.." >/dev/null 2>&1 && pwd)"
GAMES_DIR="$RUNTIME_DIR/games"
CACHE_DIR="$RUNTIME_DIR/cache"
LOGS_DIR="$RUNTIME_DIR/logs"
TMP_DIR="$RUNTIME_DIR/tmp/qa-smoke-$$"

PYTHON_BIN="${PYTHON_BIN:-}"
KEEP_QA_ARTIFACTS="${KEEP_QA_ARTIFACTS:-0}"

say() {
    printf '%s\n' "$*"
}

fail() {
    say "FAIL: $*"
    exit 1
}

find_python() {
    if [ -n "$PYTHON_BIN" ] && command -v "$PYTHON_BIN" >/dev/null 2>&1; then
        return 0
    fi

    if command -v python >/dev/null 2>&1; then
        PYTHON_BIN="$(command -v python)"
        return 0
    fi

    if command -v python3 >/dev/null 2>&1; then
        PYTHON_BIN="$(command -v python3)"
        return 0
    fi

    return 1
}

cleanup() {
    if [ "$KEEP_QA_ARTIFACTS" = "1" ]; then
        say "Keeping QA artifacts because KEEP_QA_ARTIFACTS=1"
        return 0
    fi

    rm -rf "$TMP_DIR" \
        "$GAMES_DIR/QA-Smoke-Arm64.apk" \
        "$GAMES_DIR/QA-Smoke-Armhf.apk" \
        "$GAMES_DIR/QA-Smoke-Bad.apk" \
        "$GAMES_DIR/QA-Smoke-Duplicate.apk" \
        "$GAMES_DIR/QA-Smoke-Duplicate" \
        "$CACHE_DIR/QA-Smoke-Arm64" \
        "$CACHE_DIR/QA-Smoke-Armhf" \
        "$CACHE_DIR/QA-Smoke-Duplicate" \
        "$LOGS_DIR/log.txt" 2>/dev/null || true

    [ -d "$LOGS_DIR" ] && find "$LOGS_DIR" -maxdepth 1 -type f -name '*.log' -delete 2>/dev/null || true
}

create_apk() {
    local apk_path="$1"
    local lib_path="$2"

    "$PYTHON_BIN" - "$apk_path" "$lib_path" <<'PY'
import sys
import zipfile

apk_path, lib_path = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(apk_path, "w", zipfile.ZIP_DEFLATED) as zf:
    zf.writestr(lib_path, b"qa smoke libyoyo")
    zf.writestr("assets/game.droid", b"qa smoke game data")
PY
}

run_dry() {
    local select_token="$1"

    (
        cd "$PORT_DIR" || exit 1
        PILASRUNNER_DRY_RUN=1 PILASRUNNER_SELECT="$select_token" bash "./YoYo Pilas Runner.sh"
    )
}

assert_run_info() {
    local cache_name="$1"
    local key="$2"
    local expected="$3"
    local run_info="$CACHE_DIR/$cache_name/run.info"

    [ -f "$run_info" ] || fail "Missing run.info for $cache_name"
    grep -Fq "$key=$expected" "$run_info" || {
        say "run.info contents:"
        cat "$run_info"
        fail "Expected $key=$expected in $run_info"
    }
}

main() {
    find_python || fail "Python was not found. Set PYTHON_BIN=/path/to/python."

    cleanup
    mkdir -p "$TMP_DIR" "$GAMES_DIR" "$CACHE_DIR" "$LOGS_DIR" || fail "Could not create QA directories."

    create_apk "$GAMES_DIR/QA-Smoke-Arm64.apk" "lib/arm64-v8a/libyoyo.so"
    create_apk "$GAMES_DIR/QA-Smoke-Armhf.apk" "lib/armeabi-v7a/libyoyo.so"
    printf '%s\n' "not a zip" > "$GAMES_DIR/QA-Smoke-Bad.apk"
    create_apk "$GAMES_DIR/QA-Smoke-Duplicate.apk" "lib/arm64-v8a/libyoyo.so"
    mkdir -p "$GAMES_DIR/QA-Smoke-Duplicate" || fail "Could not create folder-format fixture."
    create_apk "$GAMES_DIR/QA-Smoke-Duplicate/game.apk" "lib/armeabi-v7a/libyoyo.so"
    cat > "$GAMES_DIR/QA-Smoke-Duplicate/controls.ini" <<'EOF'
[buttons]
dpad_up=W
dpad_down=S
dpad_left=A
dpad_right=D
a=SPACE
b=SHIFT
start=ENTER
select=ESC
EOF

    run_dry "QA-Smoke-Arm64" || fail "Arm64 dry run failed."
    assert_run_info "QA-Smoke-Arm64" "loader_arch" "aarch64"
    assert_run_info "QA-Smoke-Arm64" "loader_mode" "next"

    run_dry "QA-Smoke-Armhf" || fail "Armhf dry run failed."
    assert_run_info "QA-Smoke-Armhf" "loader_arch" "armhf"
    assert_run_info "QA-Smoke-Armhf" "loader_mode" "next"

    run_dry "QA-Smoke-Duplicate" || fail "Duplicate dry run failed."
    assert_run_info "QA-Smoke-Duplicate" "game_kind" "folder"
    assert_run_info "QA-Smoke-Duplicate" "loader_arch" "armhf"
    grep -Fq "a=SPACE" "$CACHE_DIR/QA-Smoke-Duplicate/controls.normalized.ini" || fail "Per-game controls were not applied."

    if run_dry "QA-Smoke-Bad"; then
        fail "Invalid APK dry run unexpectedly succeeded."
    fi

    cleanup
    say "PASS: YoYo Pilas Runner smoke tests completed."
}

trap cleanup EXIT
main "$@"
