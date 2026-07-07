#!/bin/bash

# Thin PortMaster entry point for YoYo Pilas Runner.
# The launcher logic lives in pilasrunner/launcher.sh.

set -u

SCRIPT_SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SCRIPT_SOURCE" ]; do
    SCRIPT_DIR="$(cd -P "$(dirname "$SCRIPT_SOURCE")" >/dev/null 2>&1 && pwd)"
    LINK_TARGET="$(readlink "$SCRIPT_SOURCE")"
    case "$LINK_TARGET" in
        /*) SCRIPT_SOURCE="$LINK_TARGET" ;;
        *) SCRIPT_SOURCE="$SCRIPT_DIR/$LINK_TARGET" ;;
    esac
done

PORT_DIR="$(cd -P "$(dirname "$SCRIPT_SOURCE")" >/dev/null 2>&1 && pwd)"
RUNTIME_DIR="$PORT_DIR/pilasrunner"
if [ -d "$RUNTIME_DIR" ]; then
    LOG_DIR="$RUNTIME_DIR/logs"
else
    LOG_DIR="$PORT_DIR/logs"
fi
DETAILED_LOG="$LOG_DIR/detailed.log"
READABLE_LOG="$LOG_DIR/log.txt"
LOG_FILE="$DETAILED_LOG"
LAUNCHER="$RUNTIME_DIR/launcher.sh"
BOOT_SCREEN_FILE="$RUNTIME_DIR/assets/loading_screen.txt"
BOOT_TTY="${PILASRUNNER_TTY:-/dev/tty0}"
CONTROLFOLDER=""

timestamp() {
    date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf '%s' 'unknown-time'
}

boot_log() {
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    printf '[%s] [BOOT] %s\n' "$(timestamp)" "$*" >> "$LOG_FILE" 2>/dev/null || true
}

readable_boot_log() {
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    printf '[%s] %s\n' "$(timestamp)" "$*" >> "$READABLE_LOG" 2>/dev/null || true
}

fail() {
    boot_log "$*"
    readable_boot_log "Startup failed: $*"
    printf '%s\n' "$*"
    printf 'See logs: %s and %s\n' "$READABLE_LOG" "$DETAILED_LOG"
    exit 1
}

reset_boot_logs() {
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    : > "$DETAILED_LOG" 2>/dev/null || true
    : > "$READABLE_LOG" 2>/dev/null || true
}

find_portmaster_controlfolder() {
    local home_base="${HOME:-$RUNTIME_DIR/home}"
    local xdg_base="${XDG_DATA_HOME:-$home_base/.local/share}"

    CONTROLFOLDER=""
    if [ -d "/opt/system/Tools/PortMaster/" ]; then
        CONTROLFOLDER="/opt/system/Tools/PortMaster"
    elif [ -d "/opt/tools/PortMaster/" ]; then
        CONTROLFOLDER="/opt/tools/PortMaster"
    elif [ -d "$xdg_base/PortMaster/" ]; then
        CONTROLFOLDER="$xdg_base/PortMaster"
    elif [ -d "/roms/ports/PortMaster" ]; then
        CONTROLFOLDER="/roms/ports/PortMaster"
    fi
}

source_portmaster_boot_helpers() {
    local had_nounset=""

    find_portmaster_controlfolder
    [ -n "$CONTROLFOLDER" ] || return 0
    [ -f "$CONTROLFOLDER/control.txt" ] || return 0

    case "$-" in
        *u*)
            had_nounset="true"
            set +u
            ;;
    esac

    # PortMaster control files provide helpers such as ESUDO and device metadata.
    # shellcheck source=/dev/null
    . "$CONTROLFOLDER/control.txt" 2>> "$LOG_FILE" || boot_log "Could not source PortMaster control.txt for boot helpers: $CONTROLFOLDER/control.txt"

    if [ -f "$CONTROLFOLDER/device_info.txt" ]; then
        # shellcheck source=/dev/null
        . "$CONTROLFOLDER/device_info.txt" 2>> "$LOG_FILE" || boot_log "Could not source PortMaster device_info.txt for boot helpers: $CONTROLFOLDER/device_info.txt"
    fi

    [ "$had_nounset" = "true" ] && set -u
}

chmod_tty() {
    local tty_path="$1"

    chmod 666 "$tty_path" 2>> "$LOG_FILE" && return 0

    if [ -n "${ESUDO:-}" ]; then
        # shellcheck disable=SC2086
        $ESUDO chmod 666 "$tty_path" 2>> "$LOG_FILE" && return 0
    fi

    return 1
}

show_boot_terminal_screen() {
    [ -e "$BOOT_TTY" ] || {
        boot_log "Boot TTY was not found: $BOOT_TTY"
        return 0
    }

    chmod_tty "$BOOT_TTY" || boot_log "Could not change boot TTY permissions: $BOOT_TTY"

    if [ -w "$BOOT_TTY" ]; then
        printf '\033c' > "$BOOT_TTY" 2>> "$LOG_FILE" || true
        if [ -f "$BOOT_SCREEN_FILE" ]; then
            cat "$BOOT_SCREEN_FILE" > "$BOOT_TTY" 2>> "$LOG_FILE" || boot_log "Could not write boot loading screen to: $BOOT_TTY"
        else
            boot_log "Boot loading screen file was not found, using embedded fallback: $BOOT_SCREEN_FILE"
            cat > "$BOOT_TTY" <<'EOF'
Loading... Please Wait.

 ____ ___ _     _    ____
|  _ \_ _| |   / \  / ___|
| |_) | || |  / _ \ \___ \
|  __/| || |_| ___ \ ___) |
|_|  |___|____/_/ \_\____/

       /\
      //\\
 ____//__\\____
 \.-//----\\-,/
  \v/      \v/
  /\\      //\
 //_\\____//_\\
'----\\--//----`
      \\//
       \/
EOF
        fi
        readable_boot_log "Boot terminal screen was written to $BOOT_TTY before launching the runner."
    else
        boot_log "Boot TTY is not writable: $BOOT_TTY"
    fi
}

clear_boot_terminal_screen() {
    [ "${PILASRUNNER_KEEP_TTY:-0}" = "1" ] && return 0
    [ -e "$BOOT_TTY" ] || return 0
    [ -w "$BOOT_TTY" ] || return 0
    printf '\033c' > "$BOOT_TTY" 2>> "$LOG_FILE" || true
}

reset_boot_logs
boot_log "Starting YoYo Pilas Runner from: $PORT_DIR"
readable_boot_log "Starting YoYo Pilas Runner."
source_portmaster_boot_helpers
show_boot_terminal_screen

[ -d "$RUNTIME_DIR" ] || fail "Runtime folder was not found: $RUNTIME_DIR"
[ -f "$LAUNCHER" ] || fail "Internal launcher was not found: $LAUNCHER"

if [ ! -x "$LAUNCHER" ]; then
    boot_log "Internal launcher is not executable. Trying chmod +x."
    chmod +x "$LAUNCHER" 2>> "$LOG_FILE" || {
        if [ -n "${ESUDO:-}" ]; then
            # shellcheck disable=SC2086
            $ESUDO chmod +x "$LAUNCHER" 2>> "$LOG_FILE" || fail "Could not make internal launcher executable: $LAUNCHER"
        else
            fail "Could not make internal launcher executable: $LAUNCHER"
        fi
    }
fi

cd "$RUNTIME_DIR" || fail "Could not enter runtime folder: $RUNTIME_DIR"
"$LAUNCHER" "$@"
status=$?
clear_boot_terminal_screen
exit "$status"
