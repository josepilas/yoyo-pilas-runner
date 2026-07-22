#!/bin/bash

# YoYo Pilas Runner launcher.
# This script keeps the user workflow simple:
# copy a GameMaker Android APK into games, choose it, and run it through gmloader-next.

set -u
set -o pipefail 2>/dev/null || true

SCRIPT_SOURCE="${BASH_SOURCE[0]}"
SCRIPT_DIR="$(cd -P "$(dirname "$SCRIPT_SOURCE")" >/dev/null 2>&1 && pwd)"
RUNTIME_DIR="$SCRIPT_DIR"
PORT_DIR="$(cd -P "$RUNTIME_DIR/.." >/dev/null 2>&1 && pwd)"

BIN_DIR="$RUNTIME_DIR/bin"
LIB_DIR="$RUNTIME_DIR/lib"
VENDOR_DIR="$RUNTIME_DIR/vendor"
GMLOADER_NEXT_DIR="$VENDOR_DIR/gmloader-next"
CONFIG_DIR="$RUNTIME_DIR/config"
DEFAULTS_DIR="$RUNTIME_DIR/defaults"
LOGS_DIR="$RUNTIME_DIR/logs"
TMP_DIR="$RUNTIME_DIR/tmp"
SCRIPTS_DIR="$RUNTIME_DIR/scripts"
GLOBAL_CONFIG="$CONFIG_DIR/global.ini"
DETAILED_LOG="$LOGS_DIR/detailed.log"
READABLE_LOG="$LOGS_DIR/log.txt"
LOG_FILE="$DETAILED_LOG"
CONTROLFOLDER=""
PILASRUNNER_COMPAT_VERSION="0.8.10-portmaster-runtime-handoff"

CFG_show_cursor="false"
CFG_disable_controller="false"
CFG_disable_joystick="false"
CFG_disable_rumble="false"
CFG_disable_depth="false"
CFG_disable_extensions="false"
CFG_rumble_scale="1.0"
CFG_force_platform="os_android"
CFG_log_enabled="true"
CFG_default_arch="auto"
CFG_games_dir="games"
CFG_cache_dir="cache"
CFG_ui_path="ui/index.html"
CFG_ui_font="assets/fonts/Alata-Regular.woff2"
CFG_fullscreen="true"
CFG_dump_shaders="false"
CFG_trace_vm="false"
CFG_display_probe="auto"
CFG_display_wait_seconds="3"
CFG_audio_driver="auto"
CFG_audio_sample_rate="48000"
CFG_opensles_bridge="off"
CFG_controls_backend="auto"
CFG_gptokeyb_binary=""
CFG_hotkey_quit="true"
CFG_hotkey_quit_grace_seconds="1"
CFG_dry_run="false"

LOG_ENABLED="true"
GAMES_DIR="$RUNTIME_DIR/games"
CACHE_DIR="$RUNTIME_DIR/cache"
UI_ENTRY="$RUNTIME_DIR/ui/index.html"
UI_FONT="$RUNTIME_DIR/assets/fonts/Alata-Regular.woff2"
APP_XDG_RUNTIME_DIR=""

ARCH_RAW="unknown"
ARCH_FAMILY="unknown"
PREFERRED_ARCH="unknown"
LOADER_BIN=""
LOADER_ARCH=""
LOADER_AARCH64="$BIN_DIR/gmloadernext.aarch64"
LOADER_ARMHF="$BIN_DIR/gmloadernext.armhf"
LEGACY_GMLOADER_ARMHF="$BIN_DIR/gmloader.armhf"
NATIVE_UI_AARCH64="$BIN_DIR/pilasrunner-ui.aarch64"
NATIVE_UI_ARMHF="$BIN_DIR/pilasrunner-ui.armhf"
NATIVE_HOTKEY_AARCH64="$BIN_DIR/pilasrunner-hotkey.aarch64"
NATIVE_HOTKEY_ARMHF="$BIN_DIR/pilasrunner-hotkey.armhf"
ELF_NEEDER_AARCH64="$BIN_DIR/pilasrunner-elf-needer.aarch64"
ELF_NEEDER_ARMHF="$BIN_DIR/pilasrunner-elf-needer.armhf"
VENDOR_LOADER_AARCH64="$GMLOADER_NEXT_DIR/build/aarch64-linux-gnu/gmloader/gmloadernext.aarch64"
VENDOR_LOADER_ARMHF="$GMLOADER_NEXT_DIR/build/arm-linux-gnueabihf/gmloader/gmloadernext.armhf"
LOADER_MODE="next"
GPTOKEYB_BIN=""
GPTOKEYB_CONFIG=""
GPTOKEYB_PID=""
GPTOKEYB_WAS_STARTED="false"
HOTKEY_WATCHER_PID=""
HOTKEY_WATCHER_PIDS=""
HOTKEY_FORCE_QUIT_FLAG=""
HOTKEY_WAS_TRIGGERED="false"
MENU_TTY=""
MENU_INPUT_FD="0"
MENU_OUTPUT_FD="1"

GAME_NAMES=()
GAME_APKS=()
GAME_KINDS=()
GAME_KEYS=()
GAME_BASES=()

SELECTED_INDEX=-1
SELECTED_GAME_NAME=""
SELECTED_APK=""
SELECTED_KIND=""
SELECTED_BASE=""

GAME_CACHE_NAME=""
GAME_CACHE_DIR=""
SAVE_DIR=""
SHADER_DIR=""
VERSION_FILE=""
GMLOADER_JSON=""
RUN_INFO=""
GAME_LOG=""
READABLE_GAME_STARTED="false"
OPENSL_OVERLAY_ROOT=""
OPENSL_OVERLAY_ARCH_DIR=""
OPENSL_BRIDGE_LIB=""

APK_HAS_ARMV7="false"
APK_HAS_ARM64="false"
APK_HAS_ARMEABI="false"

CONTROL_KEYS=(
    dpad_up dpad_down dpad_left dpad_right
    a b x y
    l1 r1 l2 r2
    start select
    left_stick_click right_stick_click
)
CONTROL_VALUES=()

mkdir -p "$LOGS_DIR" "$TMP_DIR" 2>/dev/null || true

timestamp() {
    date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf '%s' 'unknown-time'
}

log_line() {
    local level="$1"
    shift
    local message="$*"

    if [ "$level" = "INFO" ] && [ "$LOG_ENABLED" != "true" ]; then
        return 0
    fi

    printf '[%s] [%s] %s\n' "$(timestamp)" "$level" "$message" >> "$LOG_FILE" 2>/dev/null || true
}

log_info() {
    log_line "INFO" "$*"
}

log_warn() {
    log_line "WARN" "$*"
}

log_error() {
    log_line "ERROR" "$*"
}

readable_log() {
    mkdir -p "$LOGS_DIR" 2>/dev/null || true
    printf '[%s] %s\n' "$(timestamp)" "$*" >> "$READABLE_LOG" 2>/dev/null || true
}

readable_section() {
    mkdir -p "$LOGS_DIR" 2>/dev/null || true
    {
        printf '\n%s\n' "== $* =="
    } >> "$READABLE_LOG" 2>/dev/null || true
}

begin_readable_game_log() {
    [ "$READABLE_GAME_STARTED" = "true" ] && return 0
    READABLE_GAME_STARTED="true"

    readable_section "Game Launch"
    readable_log "Game: $SELECTED_GAME_NAME"
    readable_log "APK: $SELECTED_APK"
    readable_log "Runtime: $LOADER_BIN"
    readable_log "Runtime architecture: $LOADER_ARCH ($LOADER_MODE)"
    readable_log "Config: $GMLOADER_JSON"
    readable_log "Detailed log: $DETAILED_LOG"
}

finish_readable_game_log() {
    local status="$1"
    local mode="$2"

    readable_section "Result"
    if [ "$status" -eq 0 ]; then
        readable_log "$mode finished normally with exit code 0."
    else
        readable_log "$mode closed unexpectedly or crashed with exit code $status."
        readable_log "Open detailed.log for the full launcher, environment, and runtime output."
    fi
}

say() {
    printf '%s\n' "$*"
}

trim() {
    local value="${1:-}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

lower() {
    printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]'
}

upper() {
    printf '%s' "${1:-}" | tr '[:lower:]' '[:upper:]'
}

strip_optional_quotes() {
    local value="${1:-}"
    local first=""
    local last=""

    [ -n "$value" ] || {
        printf '%s' "$value"
        return 0
    }

    first="${value:0:1}"
    last="${value: -1}"

    if { [ "$first" = '"' ] && [ "$last" = '"' ]; } || { [ "$first" = "'" ] && [ "$last" = "'" ]; }; then
        value="${value:1:${#value}-2}"
    fi

    printf '%s' "$value"
}

ensure_dir() {
    local path="$1"
    local label="$2"

    if [ -d "$path" ]; then
        return 0
    fi

    if mkdir -p "$path" 2>> "$LOG_FILE"; then
        log_info "Created $label directory: $path"
        return 0
    fi

    log_error "Could not create $label directory: $path"
    return 1
}

setup_portmaster_environment() {
    local home_base="${HOME:-$RUNTIME_DIR/home}"
    local xdg_base="${XDG_DATA_HOME:-$home_base/.local/share}"
    local had_nounset=""

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

    if [ -n "$CONTROLFOLDER" ] && [ -f "$CONTROLFOLDER/control.txt" ]; then
        case "$-" in
            *u*)
                had_nounset="true"
                set +u
                ;;
        esac

        # PortMaster's control.txt intentionally defines launcher helpers and paths.
        # It is not user game configuration and is part of the trusted PortMaster runtime.
        # shellcheck source=/dev/null
        . "$CONTROLFOLDER/control.txt" 2>> "$LOG_FILE" || log_warn "Could not source PortMaster control.txt: $CONTROLFOLDER/control.txt"
        log_info "Loaded PortMaster control.txt from: $CONTROLFOLDER"

        if [ -f "$CONTROLFOLDER/device_info.txt" ]; then
            # shellcheck source=/dev/null
            . "$CONTROLFOLDER/device_info.txt" 2>> "$LOG_FILE" || log_warn "Could not source PortMaster device_info.txt: $CONTROLFOLDER/device_info.txt"
            log_info "Loaded PortMaster device_info.txt from: $CONTROLFOLDER"
        fi

        if [ -n "${CFW_NAME:-}" ] && [ -f "$CONTROLFOLDER/mod_${CFW_NAME}.txt" ]; then
            # shellcheck source=/dev/null
            . "$CONTROLFOLDER/mod_${CFW_NAME}.txt" 2>> "$LOG_FILE" || log_warn "Could not source PortMaster mod file for CFW_NAME=$CFW_NAME"
            log_info "Loaded PortMaster mod file for CFW_NAME=$CFW_NAME"
        fi

        [ "$had_nounset" = "true" ] && set -u

        if command -v get_controls >/dev/null 2>&1; then
            get_controls >> "$LOG_FILE" 2>&1 || log_warn "PortMaster get_controls returned a non-zero status."
            export SDL_GAMECONTROLLERCONFIG="${sdl_controllerconfig:-${SDL_GAMECONTROLLERCONFIG:-}}"
            log_info "PortMaster controls loaded. ANALOG_STICKS=${ANALOG_STICKS:-unset}"
        fi
    else
        log_info "PortMaster control.txt was not found. Running with standalone launcher environment."
    fi
}

enable_32bit_portmaster_mode() {
    export PORT_32BIT="Y"
    log_info "Enabled PortMaster 32-bit mode: PORT_32BIT=Y"

    if [ -n "$CONTROLFOLDER" ] && [ -n "${CFW_NAME:-}" ] && [ -f "$CONTROLFOLDER/mod_${CFW_NAME}.txt" ]; then
        # Re-source after PORT_32BIT is known so firmware-specific helpers can adjust.
        # shellcheck source=/dev/null
        . "$CONTROLFOLDER/mod_${CFW_NAME}.txt" 2>> "$LOG_FILE" || log_warn "Could not re-source PortMaster mod file for 32-bit mode."
    fi
}

write_default_global_config() {
    cat > "$GLOBAL_CONFIG" <<'EOF'
# YoYo Pilas Runner global configuration.
# Values are read safely as plain text; they are never executed as shell code.

# Show the system cursor while the game is running.
show_cursor=false

# Disable controller input if a game has input conflicts.
disable_controller=false

# Disable joystick input if a game has analog input conflicts.
disable_joystick=false

# Disable rumble output.
disable_rumble=false

# Disable depth handling patches in gmloader-next.
disable_depth=false

# Disable GameMaker extension loading.
disable_extensions=false

# Rumble strength multiplier passed to gmloader-next.
rumble_scale=1.0

# Platform reported to the GameMaker runner.
force_platform=os_android

# Write verbose launcher logs.
log_enabled=true

# Preferred gmloader-next architecture: auto, aarch64, or armhf.
default_arch=auto

# Folder for APK files. Relative paths are resolved inside pilasrunner.
games_dir=games

# Folder for generated per-game files. Relative paths are resolved inside pilasrunner.
cache_dir=cache

# Canonical HTML/CSS/JavaScript interface bundled with the runner.
ui_path=ui/index.html

# Default UI font. The site demo and packaged interface use this same font file.
ui_font=assets/fonts/Alata-Regular.woff2

# Fullscreen preference. Some runtimes may ignore this value.
fullscreen=true

# Dump shaders into the per-game shader folder for troubleshooting.
dump_shaders=false

# Enable gmloader-next VM trace output. This can make logs very large.
trace_vm=false

# Display readiness probe: auto, none, x11, or wayland. Probes are diagnostic
# and never block launch permanently.
display_probe=auto

# Maximum seconds to wait for the configured display probe before launching anyway.
display_wait_seconds=3

# SDL audio driver: auto, alsa, pulse, pipewire, dsp, or off.
audio_driver=auto

# Shared sample rate for SDL audio and optional libOpenSLES SDL backend.
audio_sample_rate=48000

# Experimental OpenSL ES bridge injection: off, on, or force.
# Keep this off for maximum game compatibility. Enable only while testing audio fixes.
opensles_bridge=off

# Control mapper backend: auto, none, or gptokeyb.
controls_backend=auto

# Optional explicit gptokeyb/gptokeyb2 path. Leave empty for auto-detection.
gptokeyb_binary=

# Force-close the running game when Select + Start are pressed together.
hotkey_quit=true

# Seconds to wait after TERM before KILL when the hotkey force-quit is used.
hotkey_quit_grace_seconds=1

# Validate scanning, config generation, controls, and loader selection without
# executing the ARM loader binary. Useful for desktop QA.
dry_run=false
EOF
}

write_default_controls_config() {
    cat > "$DEFAULTS_DIR/default_controls.ini" <<'EOF'
# Default YoYo Pilas Runner controls.
# This file is parsed by the launcher and copied into each game's generated cache.
# Supported keys are listed in README.md.

[buttons]
dpad_up=UP
dpad_down=DOWN
dpad_left=LEFT
dpad_right=RIGHT
a=Z
b=X
x=C
y=V
l1=Q
r1=E
l2=SHIFT
r2=CTRL
start=ENTER
select=ESC
left_stick_click=TAB
right_stick_click=SPACE
EOF
}

write_controls_example() {
    cat > "$DEFAULTS_DIR/controls.example.ini" <<'EOF'
# Example per-game controls.ini file.
# Put this next to a folder-format game as:
#   pilasrunner/games/GameName/controls.ini
# For a loose APK, use:
#   pilasrunner/games/GameName.controls.ini
# or:
#   pilasrunner/games/GameName/controls.ini

[buttons]
dpad_up=W
dpad_down=S
dpad_left=A
dpad_right=D
a=Z
b=X
x=C
y=V
l1=Q
r1=E
l2=SHIFT
r2=CTRL
start=ENTER
select=ESC
left_stick_click=TAB
right_stick_click=SPACE
EOF
}

write_gmloader_template() {
    cat > "$DEFAULTS_DIR/gmloader.template.json" <<'EOF'
{
  "apk_path": "${apk_path}",
  "save_dir": "${save_dir}",
  "shader_dir": "${shader_dir}",
  "show_cursor": false,
  "disable_controller": false,
  "disable_joystick": false,
  "disable_rumble": false,
  "rumble_scale": 1.0,
  "force_platform": "os_android",
  "fullscreen": true
}
EOF
}

init_base_dirs() {
    ensure_dir "$BIN_DIR" "binary" || return 1
    ensure_dir "$LIB_DIR" "library" || return 1
    ensure_dir "$VENDOR_DIR" "vendor" || return 1
    ensure_dir "$CONFIG_DIR" "configuration" || return 1
    ensure_dir "$DEFAULTS_DIR" "defaults" || return 1
    ensure_dir "$LOGS_DIR" "logs" || return 1
    ensure_dir "$TMP_DIR" "temporary" || return 1
    ensure_dir "$SCRIPTS_DIR" "scripts" || return 1
    return 0
}

ensure_default_files() {
    if [ ! -f "$GLOBAL_CONFIG" ]; then
        if write_default_global_config; then
            log_info "Created default global configuration: $GLOBAL_CONFIG"
        else
            log_error "Could not create default global configuration: $GLOBAL_CONFIG"
        fi
    fi

    if [ ! -f "$DEFAULTS_DIR/default_controls.ini" ]; then
        if write_default_controls_config; then
            log_info "Created default controls file: $DEFAULTS_DIR/default_controls.ini"
        else
            log_warn "Could not create default controls file: $DEFAULTS_DIR/default_controls.ini"
        fi
    fi

    if [ ! -f "$DEFAULTS_DIR/controls.example.ini" ]; then
        if write_controls_example; then
            log_info "Created controls example: $DEFAULTS_DIR/controls.example.ini"
        else
            log_warn "Could not create controls example: $DEFAULTS_DIR/controls.example.ini"
        fi
    fi

    if [ ! -f "$DEFAULTS_DIR/gmloader.template.json" ]; then
        if write_gmloader_template; then
            log_info "Created gmloader template: $DEFAULTS_DIR/gmloader.template.json"
        else
            log_warn "Could not create gmloader template: $DEFAULTS_DIR/gmloader.template.json"
        fi
    fi
}

normalize_bool() {
    local value
    local fallback="$2"
    local key_name="$3"
    value="$(lower "$(trim "$1")")"

    case "$value" in
        true|yes|1|on) printf '%s' 'true' ;;
        false|no|0|off) printf '%s' 'false' ;;
        *)
            log_warn "Invalid boolean value for $key_name: '$1'. Using '$fallback'."
            printf '%s' "$fallback"
            ;;
    esac
}

normalize_arch_setting() {
    local value
    value="$(lower "$(trim "$1")")"

    case "$value" in
        auto|aarch64|arm64) printf '%s' "${value/arm64/aarch64}" ;;
        armhf|armv7l|armv6l) printf '%s' 'armhf' ;;
        *)
            log_warn "Invalid default_arch value: '$1'. Using 'auto'."
            printf '%s' 'auto'
            ;;
    esac
}

normalize_display_probe() {
    local value
    value="$(lower "$(trim "$1")")"

    case "$value" in
        auto|none|x11|wayland) printf '%s' "$value" ;;
        *)
            log_warn "Invalid display_probe value: '$1'. Using 'auto'."
            printf '%s' 'auto'
            ;;
    esac
}

normalize_wait_seconds() {
    local value
    local fallback="$2"
    local key_name="$3"
    value="$(trim "$1")"

    if printf '%s' "$value" | grep -Eq '^[0-9]+$'; then
        if [ "$value" -le 30 ]; then
            printf '%s' "$value"
            return 0
        fi
        log_warn "Value for $key_name is too high: '$1'. Using '30'."
        printf '%s' '30'
        return 0
    fi

    log_warn "Invalid integer value for $key_name: '$1'. Using '$fallback'."
    printf '%s' "$fallback"
}

normalize_audio_driver() {
    local value
    value="$(lower "$(trim "$1")")"

    case "$value" in
        auto|alsa|pulse|pipewire|dsp|off) printf '%s' "$value" ;;
        pulseaudio) printf '%s' 'pulse' ;;
        none|disabled|false|0) printf '%s' 'off' ;;
        *)
            log_warn "Invalid audio_driver value: '$1'. Using 'auto'."
            printf '%s' 'auto'
            ;;
    esac
}

normalize_sample_rate() {
    local value
    local fallback="$2"
    local key_name="$3"
    value="$(trim "$1")"

    if printf '%s' "$value" | grep -Eq '^[0-9]+$'; then
        if [ "$value" -ge 8000 ] && [ "$value" -le 192000 ]; then
            printf '%s' "$value"
            return 0
        fi
        log_warn "Value for $key_name is outside the supported range: '$1'. Using '$fallback'."
        printf '%s' "$fallback"
        return 0
    fi

    log_warn "Invalid integer value for $key_name: '$1'. Using '$fallback'."
    printf '%s' "$fallback"
}

normalize_float() {
    local value
    local fallback="$2"
    local key_name="$3"
    value="$(trim "$1")"

    if printf '%s' "$value" | grep -Eq '^[0-9]+([.][0-9]+)?$'; then
        printf '%s' "$value"
        return 0
    fi

    log_warn "Invalid numeric value for $key_name: '$1'. Using '$fallback'."
    printf '%s' "$fallback"
}

normalize_force_platform() {
    local value
    value="$(trim "$1")"

    if printf '%s' "$value" | grep -Eq '^[A-Za-z0-9_.-]+$'; then
        printf '%s' "$value"
        return 0
    fi

    log_warn "Invalid force_platform value: '$1'. Using 'os_android'."
    printf '%s' 'os_android'
}

load_global_config() {
    local raw_line=""
    local line=""
    local key=""
    local value=""
    local line_number=0

    [ -f "$GLOBAL_CONFIG" ] || write_default_global_config

    while IFS= read -r raw_line || [ -n "$raw_line" ]; do
        line_number=$((line_number + 1))
        line="${raw_line%$'\r'}"
        line="$(trim "$line")"

        case "$line" in
            ""|\#*|\;*) continue ;;
        esac

        if [ "${line#\[}" != "$line" ]; then
            if [ "${line%\]}" = "$line" ]; then
                log_warn "Malformed section header in global.ini line $line_number: $line"
            fi
            continue
        fi

        if [ "${line#*=}" = "$line" ]; then
            log_warn "Malformed global.ini line $line_number ignored: $line"
            continue
        fi

        key="$(lower "$(trim "${line%%=*}")")"
        value="$(strip_optional_quotes "$(trim "${line#*=}")")"

        case "$key" in
            show_cursor) CFG_show_cursor="$(normalize_bool "$value" "$CFG_show_cursor" "$key")" ;;
            disable_controller) CFG_disable_controller="$(normalize_bool "$value" "$CFG_disable_controller" "$key")" ;;
            disable_joystick) CFG_disable_joystick="$(normalize_bool "$value" "$CFG_disable_joystick" "$key")" ;;
            disable_rumble) CFG_disable_rumble="$(normalize_bool "$value" "$CFG_disable_rumble" "$key")" ;;
            disable_depth) CFG_disable_depth="$(normalize_bool "$value" "$CFG_disable_depth" "$key")" ;;
            disable_extensions) CFG_disable_extensions="$(normalize_bool "$value" "$CFG_disable_extensions" "$key")" ;;
            rumble_scale) CFG_rumble_scale="$(normalize_float "$value" "$CFG_rumble_scale" "$key")" ;;
            force_platform) CFG_force_platform="$(normalize_force_platform "$value")" ;;
            log_enabled)
                CFG_log_enabled="$(normalize_bool "$value" "$CFG_log_enabled" "$key")"
                LOG_ENABLED="$CFG_log_enabled"
                ;;
            default_arch) CFG_default_arch="$(normalize_arch_setting "$value")" ;;
            games_dir) CFG_games_dir="$value" ;;
            cache_dir) CFG_cache_dir="$value" ;;
            ui_path) CFG_ui_path="$value" ;;
            ui_font) CFG_ui_font="$value" ;;
            fullscreen) CFG_fullscreen="$(normalize_bool "$value" "$CFG_fullscreen" "$key")" ;;
            dump_shaders) CFG_dump_shaders="$(normalize_bool "$value" "$CFG_dump_shaders" "$key")" ;;
            trace_vm) CFG_trace_vm="$(normalize_bool "$value" "$CFG_trace_vm" "$key")" ;;
            display_probe) CFG_display_probe="$(normalize_display_probe "$value")" ;;
            display_wait_seconds) CFG_display_wait_seconds="$(normalize_wait_seconds "$value" "$CFG_display_wait_seconds" "$key")" ;;
            audio_driver) CFG_audio_driver="$(normalize_audio_driver "$value")" ;;
            audio_sample_rate) CFG_audio_sample_rate="$(normalize_sample_rate "$value" "$CFG_audio_sample_rate" "$key")" ;;
            opensles_bridge)
                value="$(lower "$(trim "$value")")"
                case "$value" in
                    off|false|0|no) CFG_opensles_bridge="off" ;;
                    on|true|1|yes) CFG_opensles_bridge="on" ;;
                    force) CFG_opensles_bridge="force" ;;
                    *)
                        log_warn "Invalid opensles_bridge value: '$value'. Using '$CFG_opensles_bridge'."
                        ;;
                esac
                ;;
            dry_run) CFG_dry_run="$(normalize_bool "$value" "$CFG_dry_run" "$key")" ;;
            controls_backend)
                value="$(lower "$(trim "$value")")"
                case "$value" in
                    auto|none|gptokeyb) CFG_controls_backend="$value" ;;
                    *)
                        log_warn "Invalid controls_backend value: '$value'. Using '$CFG_controls_backend'."
                        ;;
                esac
                ;;
            gptokeyb_binary) CFG_gptokeyb_binary="$value" ;;
            hotkey_quit) CFG_hotkey_quit="$(normalize_bool "$value" "$CFG_hotkey_quit" "$key")" ;;
            hotkey_quit_grace_seconds) CFG_hotkey_quit_grace_seconds="$(normalize_wait_seconds "$value" "$CFG_hotkey_quit_grace_seconds" "$key")" ;;
            *) log_warn "Unknown global.ini option ignored: $key" ;;
        esac
    done < "$GLOBAL_CONFIG"

    LOG_ENABLED="$CFG_log_enabled"
    log_info "Loaded global configuration from: $GLOBAL_CONFIG"
}

apply_environment_overrides() {
    if [ -n "${PILASRUNNER_DRY_RUN:-}" ]; then
        CFG_dry_run="$(normalize_bool "${PILASRUNNER_DRY_RUN:-}" "$CFG_dry_run" "PILASRUNNER_DRY_RUN")"
        log_warn "PILASRUNNER_DRY_RUN overrides dry_run. dry_run=$CFG_dry_run"
    fi

    if [ -n "${PILASRUNNER_DEFAULT_ARCH:-}" ]; then
        CFG_default_arch="$(normalize_arch_setting "${PILASRUNNER_DEFAULT_ARCH:-}")"
        log_warn "PILASRUNNER_DEFAULT_ARCH overrides default_arch. default_arch=$CFG_default_arch"
    fi

    if [ -n "${PILASRUNNER_AUDIO_DRIVER:-}" ]; then
        CFG_audio_driver="$(normalize_audio_driver "${PILASRUNNER_AUDIO_DRIVER:-}")"
        log_warn "PILASRUNNER_AUDIO_DRIVER overrides audio_driver. audio_driver=$CFG_audio_driver"
    fi

    if [ -n "${PILASRUNNER_OPENSL_BRIDGE:-}" ]; then
        case "$(lower "$(trim "${PILASRUNNER_OPENSL_BRIDGE:-}")")" in
            off|false|0|no) CFG_opensles_bridge="off" ;;
            on|true|1|yes) CFG_opensles_bridge="on" ;;
            force) CFG_opensles_bridge="force" ;;
            *) log_warn "Invalid PILASRUNNER_OPENSL_BRIDGE value: ${PILASRUNNER_OPENSL_BRIDGE:-}. Keeping opensles_bridge=$CFG_opensles_bridge." ;;
        esac
        log_warn "PILASRUNNER_OPENSL_BRIDGE overrides opensles_bridge. opensles_bridge=$CFG_opensles_bridge"
    fi

    if [ -n "${PILASRUNNER_HOTKEY_QUIT:-}" ]; then
        CFG_hotkey_quit="$(normalize_bool "${PILASRUNNER_HOTKEY_QUIT:-}" "$CFG_hotkey_quit" "PILASRUNNER_HOTKEY_QUIT")"
        log_warn "PILASRUNNER_HOTKEY_QUIT overrides hotkey_quit. hotkey_quit=$CFG_hotkey_quit"
    fi
}

resolve_runtime_path() {
    local value="${1:-}"
    local fallback="$2"

    [ -n "$value" ] || value="$fallback"

    case "$value" in
        /*) printf '%s' "$value" ;;
        *) printf '%s/%s' "$RUNTIME_DIR" "$value" ;;
    esac
}

apply_configured_paths() {
    GAMES_DIR="$(resolve_runtime_path "$CFG_games_dir" "games")"
    CACHE_DIR="$(resolve_runtime_path "$CFG_cache_dir" "cache")"
    UI_ENTRY="$(resolve_runtime_path "$CFG_ui_path" "ui/index.html")"
    UI_FONT="$(resolve_runtime_path "$CFG_ui_font" "assets/fonts/Alata-Regular.woff2")"

    ensure_dir "$GAMES_DIR" "games" || return 1
    ensure_dir "$CACHE_DIR" "cache" || return 1

    if [ -f "$UI_ENTRY" ]; then
        log_info "Canonical UI entry: $UI_ENTRY"
    else
        log_warn "Canonical UI entry was not found: $UI_ENTRY"
    fi

    if [ -f "$UI_FONT" ]; then
        log_info "Canonical UI font: $UI_FONT"
    else
        log_warn "Canonical UI font was not found: $UI_FONT"
    fi

    return 0
}

detect_arch() {
    if [ -n "${DEVICE_ARCH:-}" ]; then
        ARCH_RAW="$DEVICE_ARCH"
        log_info "Using PortMaster DEVICE_ARCH: $DEVICE_ARCH"
    else
        ARCH_RAW="$(uname -m 2>/dev/null || printf '%s' 'unknown')"
    fi

    case "$(lower "$ARCH_RAW")" in
        aarch64|arm64) ARCH_FAMILY="aarch64" ;;
        armv7l|armv6l|armhf|arm) ARCH_FAMILY="armhf" ;;
        *) ARCH_FAMILY="unknown" ;;
    esac

    if [ "$CFG_default_arch" != "auto" ]; then
        PREFERRED_ARCH="$CFG_default_arch"
        log_warn "default_arch overrides detected architecture. detected=$ARCH_RAW preferred=$PREFERRED_ARCH"
    else
        PREFERRED_ARCH="$ARCH_FAMILY"
    fi

    log_info "Detected system architecture: raw=$ARCH_RAW family=$ARCH_FAMILY preferred=$PREFERRED_ARCH"
}

make_executable() {
    local binary="$1"
    local host_os=""

    if [ -x "$binary" ]; then
        return 0
    fi

    log_warn "Binary is not executable. Trying chmod +x: $binary"
    chmod +x "$binary" 2>> "$LOG_FILE" || {
        if [ -n "${ESUDO:-}" ]; then
            log_warn "chmod +x failed. Retrying with PortMaster ESUDO: $binary"
            # shellcheck disable=SC2086
            $ESUDO chmod +x "$binary" 2>> "$LOG_FILE" || {
                log_error "chmod +x with ESUDO failed for: $binary"
                return 1
            }
        else
            log_error "chmod +x failed for: $binary"
            return 1
        fi
    }

    if [ -x "$binary" ]; then
        return 0
    fi

    host_os="$(uname -s 2>/dev/null || printf '%s' unknown)"
    case "$host_os" in
        MINGW*|MSYS*|CYGWIN*)
            log_warn "Executable bit could not be verified on $host_os. Continuing for desktop validation; Linux PortMaster should preserve or apply chmod correctly."
            return 0
            ;;
    esac

    {
        log_error "Binary still is not executable after chmod: $binary"
        return 1
    }
}

select_loader_binary() {
    local candidate=""
    local arch_label=""

    case "$PREFERRED_ARCH" in
        aarch64)
            if [ -f "$LOADER_AARCH64" ]; then
                candidate="$LOADER_AARCH64"
                arch_label="aarch64"
            elif [ -f "$VENDOR_LOADER_AARCH64" ]; then
                candidate="$VENDOR_LOADER_AARCH64"
                arch_label="aarch64"
                log_warn "Using gmloader-next from vendor build output. Run scripts/install_gmloader_next.sh to copy it into bin."
            elif [ -f "$LOADER_ARMHF" ]; then
                candidate="$LOADER_ARMHF"
                arch_label="armhf"
                log_warn "Preferred aarch64 loader was not found. Falling back to armhf loader."
            elif [ -f "$VENDOR_LOADER_ARMHF" ]; then
                candidate="$VENDOR_LOADER_ARMHF"
                arch_label="armhf"
                log_warn "Preferred aarch64 loader was not found. Falling back to vendor armhf loader."
            fi
            ;;
        armhf)
            if [ -f "$LOADER_ARMHF" ]; then
                candidate="$LOADER_ARMHF"
                arch_label="armhf"
            elif [ -f "$VENDOR_LOADER_ARMHF" ]; then
                candidate="$VENDOR_LOADER_ARMHF"
                arch_label="armhf"
                log_warn "Using gmloader-next from vendor build output. Run scripts/install_gmloader_next.sh to copy it into bin."
            elif [ -f "$LOADER_AARCH64" ]; then
                candidate="$LOADER_AARCH64"
                arch_label="aarch64"
                log_warn "Preferred armhf loader was not found. Falling back to aarch64 loader."
            elif [ -f "$VENDOR_LOADER_AARCH64" ]; then
                candidate="$VENDOR_LOADER_AARCH64"
                arch_label="aarch64"
                log_warn "Preferred armhf loader was not found. Falling back to vendor aarch64 loader."
            fi
            ;;
        *)
            if [ -f "$LOADER_AARCH64" ]; then
                candidate="$LOADER_AARCH64"
                arch_label="aarch64"
                log_warn "Unknown architecture. Trying aarch64 loader first."
            elif [ -f "$VENDOR_LOADER_AARCH64" ]; then
                candidate="$VENDOR_LOADER_AARCH64"
                arch_label="aarch64"
                log_warn "Unknown architecture. Trying vendor aarch64 loader first."
            elif [ -f "$LOADER_ARMHF" ]; then
                candidate="$LOADER_ARMHF"
                arch_label="armhf"
                log_warn "Unknown architecture. Trying armhf loader."
            elif [ -f "$VENDOR_LOADER_ARMHF" ]; then
                candidate="$VENDOR_LOADER_ARMHF"
                arch_label="armhf"
                log_warn "Unknown architecture. Trying vendor armhf loader."
            fi
            ;;
    esac

    if [ -z "$candidate" ]; then
        log_error "No gmloader-next binary found in $BIN_DIR or vendor build outputs."
        say "gmloader-next was not found in this package."
        say "This build should include gmloadernext.aarch64 in:"
        say "$BIN_DIR"
        say "For development builds, rebuild the vendored source with:"
        say "$SCRIPTS_DIR/build_gmloader_next.sh"
        say "See logs: $READABLE_LOG and $DETAILED_LOG"
        return 1
    fi

    make_executable "$candidate" || {
        say "The selected gmloader-next binary is not executable."
        say "See logs: $READABLE_LOG and $DETAILED_LOG"
        return 1
    }

    LOADER_BIN="$candidate"
    LOADER_ARCH="$arch_label"
    log_info "Selected gmloader-next binary: $LOADER_BIN ($LOADER_ARCH)"
    return 0
}

game_key() {
    lower "$1"
}

add_game() {
    local name="$1"
    local apk="$2"
    local kind="$3"
    local base="$4"
    local key=""
    local index=0

    key="$(game_key "$base")"

    for ((index = 0; index < ${#GAME_KEYS[@]}; index++)); do
        if [ "${GAME_KEYS[$index]}" = "$key" ]; then
            if [ "$kind" = "folder" ] && [ "${GAME_KINDS[$index]}" != "folder" ]; then
                log_info "Replacing duplicate loose APK with folder-format game for base name: $base"
                GAME_NAMES[$index]="$name"
                GAME_APKS[$index]="$apk"
                GAME_KINDS[$index]="$kind"
                GAME_BASES[$index]="$base"
            else
                log_info "Skipping duplicate game entry for base name '$base'. Folder-format games are preferred when names match."
            fi
            return 0
        fi
    done

    GAME_NAMES+=("$name")
    GAME_APKS+=("$apk")
    GAME_KINDS+=("$kind")
    GAME_KEYS+=("$key")
    GAME_BASES+=("$base")
    log_info "Found game: name='$name' kind=$kind apk='$apk'"
}

swap_games() {
    local a="$1"
    local b="$2"
    local tmp=""

    tmp="${GAME_NAMES[$a]}"; GAME_NAMES[$a]="${GAME_NAMES[$b]}"; GAME_NAMES[$b]="$tmp"
    tmp="${GAME_APKS[$a]}"; GAME_APKS[$a]="${GAME_APKS[$b]}"; GAME_APKS[$b]="$tmp"
    tmp="${GAME_KINDS[$a]}"; GAME_KINDS[$a]="${GAME_KINDS[$b]}"; GAME_KINDS[$b]="$tmp"
    tmp="${GAME_KEYS[$a]}"; GAME_KEYS[$a]="${GAME_KEYS[$b]}"; GAME_KEYS[$b]="$tmp"
    tmp="${GAME_BASES[$a]}"; GAME_BASES[$a]="${GAME_BASES[$b]}"; GAME_BASES[$b]="$tmp"
}

sort_games() {
    local count="${#GAME_NAMES[@]}"
    local i=0
    local j=0
    local min=0
    local left=""
    local right=""

    for ((i = 0; i < count; i++)); do
        min="$i"
        for ((j = i + 1; j < count; j++)); do
            left="$(lower "${GAME_NAMES[$j]}")"
            right="$(lower "${GAME_NAMES[$min]}")"
            if [[ "$left" < "$right" ]]; then
                min="$j"
            fi
        done

        if [ "$min" -ne "$i" ]; then
            swap_games "$i" "$min"
        fi
    done
}

scan_games() {
    local entry=""
    local name=""
    local lower_name=""
    local game_apk=""
    local filename=""
    local base=""

    GAME_NAMES=()
    GAME_APKS=()
    GAME_KINDS=()
    GAME_KEYS=()
    GAME_BASES=()

    ensure_dir "$GAMES_DIR" "games" || return 1
    log_info "Scanning games directory: $GAMES_DIR"

    shopt -s nullglob

    for entry in "$GAMES_DIR"/*; do
        [ -d "$entry" ] || continue
        name="$(basename "$entry")"
        lower_name="$(lower "$name")"

        case "$lower_name" in
            cache|logs|config|tmp|defaults|bin|lib|scripts)
                log_warn "Ignoring unexpected runtime folder inside games: $entry"
                continue
                ;;
        esac

        game_apk="$entry/game.apk"
        if [ -f "$game_apk" ]; then
            add_game "$name" "$game_apk" "folder" "$name"
        fi
    done

    for entry in "$GAMES_DIR"/*; do
        [ -f "$entry" ] || continue
        filename="$(basename "$entry")"
        lower_name="$(lower "$filename")"

        case "$lower_name" in
            *.apk)
                base="${filename%.*}"
                add_game "$base" "$entry" "apk" "$base"
                ;;
            *)
                log_info "Ignoring unsupported file in games directory: $entry"
                ;;
        esac
    done

    shopt -u nullglob
    sort_games

    log_info "Game scan complete. Count=${#GAME_NAMES[@]}"
    return 0
}

select_game_index() {
    local index="$1"

    SELECTED_INDEX="$index"
    SELECTED_GAME_NAME="${GAME_NAMES[$SELECTED_INDEX]}"
    SELECTED_APK="${GAME_APKS[$SELECTED_INDEX]}"
    SELECTED_KIND="${GAME_KINDS[$SELECTED_INDEX]}"
    SELECTED_BASE="${GAME_BASES[$SELECTED_INDEX]}"
    log_info "Selected game: name='$SELECTED_GAME_NAME' apk='$SELECTED_APK' kind=$SELECTED_KIND"
}

select_game_by_token() {
    local token=""
    local token_key=""
    local count="${#GAME_NAMES[@]}"
    local i=0

    token="$(trim "${1:-}")"
    [ -n "$token" ] || return 1

    if printf '%s' "$token" | grep -Eq '^[0-9]+$'; then
        if [ "$token" -ge 1 ] && [ "$token" -le "$count" ]; then
            select_game_index "$((token - 1))"
            return 0
        fi
    fi

    token_key="$(game_key "$token")"
    for ((i = 0; i < count; i++)); do
        if [ "$(game_key "${GAME_NAMES[$i]}")" = "$token_key" ] || [ "$(game_key "${GAME_BASES[$i]}")" = "$token_key" ]; then
            select_game_index "$i"
            return 0
        fi
    done

    return 1
}

open_menu_tty() {
    local candidate=""

    MENU_TTY=""
    MENU_INPUT_FD="0"
    MENU_OUTPUT_FD="1"

    if [ -t 0 ]; then
        log_info "Using stdin/stdout for the launcher menu UI."
        return 0
    fi

    for candidate in "${PILASRUNNER_MENU_TTY:-}" /dev/tty /dev/tty0 /dev/tty1 /dev/console; do
        [ -n "$candidate" ] || continue
        [ -e "$candidate" ] || continue

        if exec 8< "$candidate" 2>> "$LOG_FILE"; then
            if exec 9> "$candidate" 2>> "$LOG_FILE"; then
                MENU_TTY="$candidate"
                MENU_INPUT_FD="8"
                MENU_OUTPUT_FD="9"
                log_info "Using launcher menu TTY: $MENU_TTY"
                return 0
            fi
            exec 8<&- 2>/dev/null || true
        fi
    done

    log_warn "No readable and writable TTY was found for the launcher menu UI."
    return 1
}

close_menu_tty() {
    if [ "$MENU_INPUT_FD" = "8" ]; then
        exec 8<&- 2>/dev/null || true
    fi
    if [ "$MENU_OUTPUT_FD" = "9" ]; then
        exec 9>&- 2>/dev/null || true
    fi
    MENU_TTY=""
    MENU_INPUT_FD="0"
    MENU_OUTPUT_FD="1"
}

menu_printf() {
    if [ "$MENU_OUTPUT_FD" = "9" ]; then
        printf "$@" >&9
    else
        printf "$@"
    fi
}

menu_line() {
    if [ "$MENU_OUTPUT_FD" = "9" ]; then
        printf '%s\n' "$*" >&9
    else
        printf '%s\n' "$*"
    fi
}

menu_control() {
    if [ "$MENU_OUTPUT_FD" = "9" ]; then
        printf '%b' "$1" >&9
    else
        printf '%b' "$1"
    fi
}

menu_read_one() {
    local __target="$1"
    local key=""

    if [ "$MENU_INPUT_FD" = "8" ]; then
        IFS= read -r -s -n 1 key <&8 || return 1
    else
        IFS= read -r -s -n 1 key || return 1
    fi

    printf -v "$__target" '%s' "$key"
    return 0
}

menu_read_extra() {
    local __target="$1"
    local count="$2"
    local text=""

    if [ "$MENU_INPUT_FD" = "8" ]; then
        IFS= read -r -s -n "$count" -t 0.08 text <&8 || true
    else
        IFS= read -r -s -n "$count" -t 0.08 text || true
    fi

    printf -v "$__target" '%s' "$text"
    return 0
}

read_menu_action() {
    local key=""
    local rest=""

    menu_read_one key || return 1

    case "$key" in
        $'\033')
            menu_read_extra rest 2
            case "$rest" in
                "[A"|"OA") printf '%s' 'up' ;;
                "[B"|"OB") printf '%s' 'down' ;;
                *) printf '%s' 'back' ;;
            esac
            ;;
        "")
            printf '%s' 'launch'
            ;;
        " ")
            printf '%s' 'launch'
            ;;
        w|W|k|K)
            printf '%s' 'up'
            ;;
        s|S|j|J)
            printf '%s' 'down'
            ;;
        a|A|l|L)
            printf '%s' 'launch'
            ;;
        b|B|q|Q)
            printf '%s' 'back'
            ;;
        [0-9])
            printf 'number:%s' "$key"
            ;;
        *)
            printf '%s' 'none'
            ;;
    esac
}

render_tty_ui() {
    local selected="$1"
    local count="${#GAME_NAMES[@]}"
    local page_size=10
    local start=0
    local end=0
    local i=0
    local kind=""

    if [ "$count" -gt "$page_size" ]; then
        start=$((selected - page_size / 2))
        [ "$start" -lt 0 ] && start=0
        if [ $((start + page_size)) -gt "$count" ]; then
            start=$((count - page_size))
        fi
    fi
    end=$((start + page_size))
    [ "$end" -gt "$count" ] && end="$count"

    menu_control '\033[2J\033[H'
    menu_line "===================================================="
    menu_line " YoYo Pilas Runner"
    menu_line " Inspired by YoYo Loader Vita, powered by gmloader-next"
    menu_line "===================================================="
    menu_line "Games: $count | Runtime: $LOADER_ARCH | Loader: $LOADER_MODE"
    menu_line ""

    if [ "$start" -gt 0 ]; then
        menu_line "    ..."
    fi

    for ((i = start; i < end; i++)); do
        if [ "${GAME_KINDS[$i]}" = "folder" ]; then
            kind="folder"
        else
            kind="apk"
        fi

        if [ "$i" -eq "$selected" ]; then
            menu_printf '\033[7m > %02d  %-34.34s  [%s]\033[0m\n' "$((i + 1))" "${GAME_NAMES[$i]}" "$kind"
        else
            menu_printf '   %02d  %-34.34s  [%s]\n' "$((i + 1))" "${GAME_NAMES[$i]}" "$kind"
        fi
    done

    if [ "$end" -lt "$count" ]; then
        menu_line "    ..."
    fi

    menu_line ""
    menu_line "Up/Down: Move   A/Enter: Launch   B/Esc: Exit"
    menu_line "Select + Start closes the running game."
}

render_noninteractive_menu_preview() {
    local count="${#GAME_NAMES[@]}"
    local i=0
    local kind=""

    say ""
    say "===================================================="
    say " YoYo Pilas Runner"
    say " Inspired by YoYo Loader Vita, powered by gmloader-next"
    say "===================================================="
    say "Games: $count | Runtime: $LOADER_ARCH | Loader: $LOADER_MODE"
    say ""
    for ((i = 0; i < count; i++)); do
        if [ "${GAME_KINDS[$i]}" = "folder" ]; then
            kind="folder"
        else
            kind="apk"
        fi
        printf '   %02d  %-34.34s  [%s]\n' "$((i + 1))" "${GAME_NAMES[$i]}" "$kind"
    done
    say ""
}

run_native_menu() {
    local native_ui=""
    local games_file="$TMP_DIR/native-games-$$.tsv"
    local selection_file="$TMP_DIR/native-selection-$$.txt"
    local status=0
    local selected_index=""
    local i=0
    local host_os=""
    local boot_tty="${PILASRUNNER_TTY:-/dev/tty0}"
    local fb_path="${PILASRUNNER_FB:-/dev/fb0}"

    case "${PILASRUNNER_MENU_BACKEND:-auto}" in
        tty|bash|terminal|python|visual) return 3 ;;
    esac

    host_os="$(uname -s 2>/dev/null || printf '%s' unknown)"
    case "$host_os" in
        Linux*) ;;
        *)
            log_info "Native C menu skipped on non-Linux host: $host_os"
            return 3
            ;;
    esac

    case "$ARCH_FAMILY" in
        aarch64) native_ui="$NATIVE_UI_AARCH64" ;;
        armhf) native_ui="$NATIVE_UI_ARMHF" ;;
    esac

    if [ -z "$native_ui" ] || [ ! -f "$native_ui" ]; then
        case "$LOADER_ARCH" in
            aarch64) native_ui="$NATIVE_UI_AARCH64" ;;
            armhf) native_ui="$NATIVE_UI_ARMHF" ;;
        esac
    fi

    [ -n "$native_ui" ] && [ -f "$native_ui" ] || {
        log_warn "Native C launcher UI binary was not found for arch=$ARCH_FAMILY loader=$LOADER_ARCH."
        return 3
    }

    make_executable "$native_ui" || return 3

    : > "$games_file" || return 3
    for ((i = 0; i < count; i++)); do
        printf '%s\t%s\n' "${GAME_KINDS[$i]}" "${GAME_NAMES[$i]}" >> "$games_file" || return 3
    done

    rm -f "$selection_file" 2>/dev/null || true
    prepare_input_device_access || true
    if [ -e "$fb_path" ] && { [ ! -r "$fb_path" ] || [ ! -w "$fb_path" ]; }; then
        chmod a+rw "$fb_path" >> "$LOG_FILE" 2>&1 || {
            if [ -n "${ESUDO:-}" ]; then
                # shellcheck disable=SC2086
                $ESUDO chmod a+rw "$fb_path" >> "$LOG_FILE" 2>&1 || true
            fi
        }
    fi
    if [ "${PILASRUNNER_CLEAR_BOOT_TTY:-1}" != "0" ] && [ -e "$boot_tty" ] && [ -w "$boot_tty" ]; then
        printf '\033c' > "$boot_tty" 2>> "$LOG_FILE" || true
    fi
    log_info "Starting native C launcher UI: $native_ui"

    "$native_ui" \
        --games "$games_file" \
        --selection "$selection_file" \
        --runtime "$LOADER_ARCH" \
        --loader "$LOADER_MODE" \
        --logo "$RUNTIME_DIR/assets/logo.webp" \
        --font "$UI_FONT" \
        --fb "$fb_path" \
        --log "$LOG_FILE" >> "$LOG_FILE" 2>&1
    status=$?

    rm -f "$games_file" 2>/dev/null || true

    if [ "$status" -eq 0 ] && [ -f "$selection_file" ]; then
        selected_index="$(head -n 1 "$selection_file" 2>/dev/null || true)"
        rm -f "$selection_file" 2>/dev/null || true
        if printf '%s' "$selected_index" | grep -Eq '^[0-9]+$' && [ "$selected_index" -ge 0 ] && [ "$selected_index" -lt "$count" ]; then
            select_game_index "$selected_index"
            log_info "Native C launcher UI selected game: $SELECTED_GAME_NAME"
            return 0
        fi
        log_warn "Native C launcher UI returned an invalid selection: $selected_index"
        return 3
    fi

    rm -f "$selection_file" 2>/dev/null || true
    if [ "$status" -eq 2 ]; then
        log_info "User exited from native C launcher UI."
        return 2
    fi

    log_warn "Native C launcher UI was unavailable or failed with status $status. Falling back to terminal menu."
    return 3
}

run_python_menu() {
    local python_bin=""
    local menu_script="$SCRIPTS_DIR/menu_ui.py"
    local games_file="$TMP_DIR/menu-games-$$.tsv"
    local selection_file="$TMP_DIR/menu-selection-$$.txt"
    local status=0
    local selected_index=""
    local i=0

    case "${PILASRUNNER_MENU_BACKEND:-auto}" in
        tty|bash) return 3 ;;
    esac

    [ -f "$menu_script" ] || return 3

    python_bin="$(find_python_runtime || true)"
    [ -n "$python_bin" ] || return 3

    : > "$games_file" || return 3
    for ((i = 0; i < count; i++)); do
        printf '%s\t%s\n' "${GAME_KINDS[$i]}" "${GAME_NAMES[$i]}" >> "$games_file" || return 3
    done

    rm -f "$selection_file" 2>/dev/null || true
    prepare_input_device_access || true

    "$python_bin" "$menu_script" \
        --games "$games_file" \
        --selection "$selection_file" \
        --runtime "$LOADER_ARCH" \
        --loader "$LOADER_MODE" \
        --tty "$MENU_TTY" >> "$LOG_FILE" 2>&1
    status=$?

    rm -f "$games_file" 2>/dev/null || true

    if [ "$status" -eq 0 ] && [ -f "$selection_file" ]; then
        selected_index="$(head -n 1 "$selection_file" 2>/dev/null || true)"
        rm -f "$selection_file" 2>/dev/null || true
        if printf '%s' "$selected_index" | grep -Eq '^[0-9]+$' && [ "$selected_index" -ge 0 ] && [ "$selected_index" -lt "$count" ]; then
            select_game_index "$selected_index"
            log_info "Python launcher UI selected game: $SELECTED_GAME_NAME"
            return 0
        fi
        log_warn "Python launcher UI returned an invalid selection: $selected_index"
        return 3
    fi

    rm -f "$selection_file" 2>/dev/null || true
    if [ "$status" -eq 2 ]; then
        log_info "User exited from Python launcher UI."
        return 2
    fi

    log_warn "Python launcher UI was unavailable or failed with status $status. Falling back to Bash TTY UI."
    return 3
}

run_visual_menu() {
    local python_bin=""
    local visual_script="$SCRIPTS_DIR/visual_ui.py"
    local games_file="$TMP_DIR/visual-games-$$.tsv"
    local selection_file="$TMP_DIR/visual-selection-$$.txt"
    local status=0
    local selected_index=""
    local i=0

    case "${PILASRUNNER_MENU_BACKEND:-auto}" in
        tty|bash|terminal) return 3 ;;
    esac

    [ -f "$visual_script" ] || return 3

    python_bin="$(find_python_runtime || true)"
    [ -n "$python_bin" ] || return 3

    : > "$games_file" || return 3
    for ((i = 0; i < count; i++)); do
        printf '%s\t%s\n' "${GAME_KINDS[$i]}" "${GAME_NAMES[$i]}" >> "$games_file" || return 3
    done

    rm -f "$selection_file" 2>/dev/null || true
    prepare_input_device_access || true

    "$python_bin" "$visual_script" \
        --games "$games_file" \
        --selection "$selection_file" \
        --runtime "$LOADER_ARCH" \
        --loader "$LOADER_MODE" \
        --logo "$RUNTIME_DIR/assets/logo.webp" \
        --log "$LOG_FILE" >> "$LOG_FILE" 2>&1
    status=$?

    rm -f "$games_file" 2>/dev/null || true

    if [ "$status" -eq 0 ] && [ -f "$selection_file" ]; then
        selected_index="$(head -n 1 "$selection_file" 2>/dev/null || true)"
        rm -f "$selection_file" 2>/dev/null || true
        if printf '%s' "$selected_index" | grep -Eq '^[0-9]+$' && [ "$selected_index" -ge 0 ] && [ "$selected_index" -lt "$count" ]; then
            select_game_index "$selected_index"
            log_info "Framebuffer launcher UI selected game: $SELECTED_GAME_NAME"
            return 0
        fi
        log_warn "Framebuffer launcher UI returned an invalid selection: $selected_index"
        return 3
    fi

    rm -f "$selection_file" 2>/dev/null || true
    if [ "$status" -eq 2 ]; then
        log_info "User exited from framebuffer launcher UI."
        return 2
    fi

    log_warn "Framebuffer launcher UI was unavailable or failed with status $status. Falling back to TTY menu."
    return 3
}

show_menu() {
    local count="${#GAME_NAMES[@]}"
    local selected=0
    local action=""
    local requested_number=0
    local native_menu_status=0
    local python_menu_status=0
    local visual_menu_status=0

    if [ "$count" -eq 0 ]; then
        say "No compatible APK files were found."
        say "Place Android GameMaker Studio APK files in:"
        say "$GAMES_DIR"
        log_warn "No APK files found. User should place GameMaker Android APK files in $GAMES_DIR"
        return 1
    fi

    if [ -n "${PILASRUNNER_SELECT:-}" ] && { [ "$CFG_dry_run" = "true" ] || [ "${PILASRUNNER_ALLOW_SELECT_BYPASS:-0}" = "1" ]; }; then
        if select_game_by_token "${PILASRUNNER_SELECT:-}"; then
            log_warn "PILASRUNNER_SELECT selected game: $SELECTED_GAME_NAME"
            return 0
        fi

        say "PILASRUNNER_SELECT did not match any scanned game: ${PILASRUNNER_SELECT:-}"
        log_error "PILASRUNNER_SELECT did not match any scanned game: ${PILASRUNNER_SELECT:-}"
        return 1
    fi
    if [ -n "${PILASRUNNER_SELECT:-}" ]; then
        log_warn "Ignoring PILASRUNNER_SELECT because normal launches must pass through the UI. Set PILASRUNNER_ALLOW_SELECT_BYPASS=1 only for explicit QA automation."
    fi

    run_native_menu
    native_menu_status=$?
    if [ "$native_menu_status" -eq 0 ]; then
        return 0
    fi
    if [ "$native_menu_status" -eq 2 ]; then
        return 2
    fi

    if [ "${PILASRUNNER_ALLOW_PYTHON_FB_UI:-0}" = "1" ]; then
        run_visual_menu
        visual_menu_status=$?
    else
        visual_menu_status=3
        log_info "Python framebuffer launcher UI is disabled by default; set PILASRUNNER_ALLOW_PYTHON_FB_UI=1 to use it."
    fi

    if [ "$visual_menu_status" -eq 0 ]; then
        return 0
    fi
    if [ "$visual_menu_status" -eq 2 ]; then
        return 2
    fi

    if open_menu_tty; then
        run_python_menu
        python_menu_status=$?
        if [ "$python_menu_status" -eq 0 ]; then
            close_menu_tty
            return 0
        fi
        if [ "$python_menu_status" -eq 2 ]; then
            close_menu_tty
            return 2
        fi

        while true; do
            render_tty_ui "$selected"
            action="$(read_menu_action)" || {
                close_menu_tty
                log_warn "Input ended before game selection."
                return 2
            }

            case "$action" in
                up)
                    selected=$((selected - 1))
                    [ "$selected" -lt 0 ] && selected=$((count - 1))
                    ;;
                down)
                    selected=$((selected + 1))
                    [ "$selected" -ge "$count" ] && selected=0
                    ;;
                launch)
                    select_game_index "$selected"
                    close_menu_tty
                    log_info "Launcher UI selected game: $SELECTED_GAME_NAME"
                    return 0
                    ;;
                back)
                    close_menu_tty
                    log_info "User exited from launcher UI."
                    return 2
                    ;;
                number:*)
                    requested_number="${action#number:}"
                    if [ "$requested_number" -eq 0 ]; then
                        close_menu_tty
                        log_info "User exited from launcher UI with number 0."
                        return 2
                    fi
                    if [ "$requested_number" -ge 1 ] && [ "$requested_number" -le "$count" ]; then
                        selected=$((requested_number - 1))
                        select_game_index "$selected"
                        close_menu_tty
                        log_info "Launcher UI selected game by number: $SELECTED_GAME_NAME"
                        return 0
                    fi
                    ;;
                *)
                    ;;
            esac
        done
    fi

    render_noninteractive_menu_preview
    if [ "${PILASRUNNER_ALLOW_HEADLESS_AUTORUN:-0}" = "1" ]; then
        sleep "${PILASRUNNER_MENU_FALLBACK_DELAY:-2}"
        select_game_index 0
        log_warn "Headless autorun was explicitly enabled. Selected first scanned game: $SELECTED_GAME_NAME"
        return 0
    fi

    say "No menu input terminal is available."
    say "YoYo Pilas Runner will not start a game without a usable UI selection."
    log_error "No usable launcher UI input was available. Refusing to auto-launch a game."
    return 1
}

validate_apk() {
    local apk="$1"
    local list_file="$TMP_DIR/apk-list-$$.txt"

    APK_HAS_ARMV7="false"
    APK_HAS_ARM64="false"
    APK_HAS_ARMEABI="false"

    if [ ! -f "$apk" ]; then
        log_error "APK does not exist: $apk"
        say "The selected APK was not found."
        return 1
    fi

    if [ ! -r "$apk" ]; then
        log_error "APK is not readable: $apk"
        say "The selected APK is not readable."
        return 1
    fi

    if [ ! -s "$apk" ]; then
        log_error "APK is empty: $apk"
        say "The selected APK is empty."
        return 1
    fi

    log_info "APK basic validation passed: $apk"

    if command -v unzip >/dev/null 2>&1; then
        if unzip -l "$apk" 2>> "$LOG_FILE" | sed 's#\\#/#g' > "$list_file"; then
            if grep -q 'lib/armeabi-v7a/libyoyo\.so' "$list_file"; then
                APK_HAS_ARMV7="true"
            fi

            if grep -q 'lib/armeabi/libyoyo\.so' "$list_file"; then
                APK_HAS_ARMEABI="true"
            fi

            if grep -q 'lib/arm64-v8a/libyoyo\.so' "$list_file"; then
                APK_HAS_ARM64="true"
            fi

            if [ "$APK_HAS_ARMV7" = "true" ] || [ "$APK_HAS_ARMEABI" = "true" ] || [ "$APK_HAS_ARM64" = "true" ]; then
                log_info "GameMaker libyoyo.so detected. armeabi=$APK_HAS_ARMEABI armeabi-v7a=$APK_HAS_ARMV7 arm64-v8a=$APK_HAS_ARM64"
            else
                log_warn "libyoyo.so was not found inside APK. This may not be a compatible GameMaker Android game."
                say "Warning: libyoyo.so was not found. This APK may not be a compatible GameMaker Android game."
            fi
        else
            rm -f "$list_file"
            log_error "unzip could not list APK contents. File may not be a valid APK/ZIP: $apk"
            say "The selected file does not look like a valid APK."
            return 1
        fi
        rm -f "$list_file"
    else
        log_warn "unzip is not available. Deep APK validation was skipped."
    fi

    if [ "$ARCH_FAMILY" = "armhf" ] && [ "$APK_HAS_ARM64" = "true" ] && [ "$APK_HAS_ARMV7" != "true" ] && [ "$APK_HAS_ARMEABI" != "true" ]; then
        log_warn "APK appears to contain only arm64-v8a libyoyo.so on an armhf system. Compatibility is unlikely."
        say "Warning: this APK appears to be arm64-only, but this system looks armhf."
    fi

    if [ "$ARCH_FAMILY" = "aarch64" ] && { [ "$APK_HAS_ARMV7" = "true" ] || [ "$APK_HAS_ARMEABI" = "true" ]; } && [ "$APK_HAS_ARM64" != "true" ]; then
        log_warn "APK appears to contain only armeabi-v7a libyoyo.so on an aarch64 system. A 32-bit environment or armhf gmloader-next may be required."
    fi

    return 0
}

adjust_loader_binary_for_apk() {
    if { [ "$APK_HAS_ARMV7" = "true" ] || [ "$APK_HAS_ARMEABI" = "true" ]; } && [ "$APK_HAS_ARM64" != "true" ] && [ "$LOADER_ARCH" = "aarch64" ]; then
        if [ -f "$LOADER_ARMHF" ]; then
            log_warn "APK is 32-bit only. Switching to armhf gmloader-next because it is available."
            make_executable "$LOADER_ARMHF" || return 1
            LOADER_BIN="$LOADER_ARMHF"
            LOADER_ARCH="armhf"
        elif [ -f "$VENDOR_LOADER_ARMHF" ]; then
            log_warn "APK is 32-bit only. Switching to vendor armhf gmloader-next because it is available."
            make_executable "$VENDOR_LOADER_ARMHF" || return 1
            LOADER_BIN="$VENDOR_LOADER_ARMHF"
            LOADER_ARCH="armhf"
        else
            log_error "APK is 32-bit only, but gmloadernext.armhf is not available. Refusing to launch with gmloadernext.aarch64."
            if [ -f "$LEGACY_GMLOADER_ARMHF" ]; then
                log_warn "Falling back to legacy gmloader.armhf for this 32-bit APK."
                make_executable "$LEGACY_GMLOADER_ARMHF" || return 1
                LOADER_BIN="$LEGACY_GMLOADER_ARMHF"
                LOADER_ARCH="armhf"
                LOADER_MODE="legacy"
                enable_32bit_portmaster_mode
            else
                say "This APK is 32-bit only."
                say "gmloadernext.armhf or legacy gmloader.armhf is required."
                say "See logs: $READABLE_LOG and $DETAILED_LOG"
                return 1
            fi
        fi
    fi

    if [ "$APK_HAS_ARM64" = "true" ] && [ "$APK_HAS_ARMV7" != "true" ] && [ "$LOADER_ARCH" = "armhf" ]; then
        if [ "$ARCH_FAMILY" = "aarch64" ] && [ -f "$LOADER_AARCH64" ]; then
            log_warn "APK is arm64-only. Switching to aarch64 gmloader-next because it is available."
            make_executable "$LOADER_AARCH64" || return 1
            LOADER_BIN="$LOADER_AARCH64"
            LOADER_ARCH="aarch64"
        elif [ "$ARCH_FAMILY" = "aarch64" ] && [ -f "$VENDOR_LOADER_AARCH64" ]; then
            log_warn "APK is arm64-only. Switching to vendor aarch64 gmloader-next because it is available."
            make_executable "$VENDOR_LOADER_AARCH64" || return 1
            LOADER_BIN="$VENDOR_LOADER_AARCH64"
            LOADER_ARCH="aarch64"
        else
            log_warn "APK is arm64-only, but the selected loader is armhf. The game will probably fail."
        fi
    fi

    log_info "Loader after APK compatibility check: $LOADER_BIN ($LOADER_ARCH)"
    return 0
}

normalize_cache_name() {
    local value="$1"
    local normalized=""

    normalized="$(printf '%s' "$value" | tr '[:space:]' '_' | tr -cd 'A-Za-z0-9._-' | sed 's/__*/_/g; s/^[_.-]*//; s/[_.-]*$//')"

    if [ -z "$normalized" ]; then
        normalized="game_$(date '+%s' 2>/dev/null || printf '%s' "$$")"
    fi

    printf '%s' "$normalized"
}

invalidate_generated_cache_if_needed() {
    local old_version=""

    if [ -f "$VERSION_FILE" ]; then
        IFS= read -r old_version < "$VERSION_FILE" || old_version=""
    fi

    if [ "$old_version" = "$PILASRUNNER_COMPAT_VERSION" ]; then
        return 0
    fi

    if [ -n "$old_version" ]; then
        log_warn "Generated cache version changed for '$SELECTED_GAME_NAME': $old_version -> $PILASRUNNER_COMPAT_VERSION"
    else
        log_info "Writing generated cache version for '$SELECTED_GAME_NAME': $PILASRUNNER_COMPAT_VERSION"
    fi

    rm -f \
        "$GMLOADER_JSON" \
        "$RUN_INFO" \
        "$GAME_CACHE_DIR/controls.normalized.ini" \
        "$GAME_CACHE_DIR/controls.source.ini" \
        "$GAME_CACHE_DIR/gptokeyb2.ini" \
        "$GAME_CACHE_DIR/$GAME_CACHE_NAME.gptk" \
        2>> "$LOG_FILE" || log_warn "Could not remove one or more generated cache files for: $GAME_CACHE_DIR"

    printf '%s\n' "$PILASRUNNER_COMPAT_VERSION" > "$VERSION_FILE" 2>> "$LOG_FILE" || {
        log_warn "Could not write generated cache version marker: $VERSION_FILE"
        return 1
    }

    return 0
}

chmod_runtime_dir() {
    local path="$1"

    chmod 700 "$path" 2>> "$LOG_FILE" && return 0

    if [ -n "${ESUDO:-}" ]; then
        # shellcheck disable=SC2086
        $ESUDO chmod 700 "$path" 2>> "$LOG_FILE" && return 0
    fi

    log_warn "Could not chmod 700 XDG runtime directory: $path"
    return 1
}

prepare_game_cache() {
    GAME_CACHE_NAME="$(normalize_cache_name "$SELECTED_GAME_NAME")"
    GAME_CACHE_DIR="$CACHE_DIR/$GAME_CACHE_NAME"
    SAVE_DIR="$GAME_CACHE_DIR/saves"
    SHADER_DIR="$GAME_CACHE_DIR/shaders"
    VERSION_FILE="$GAME_CACHE_DIR/cache.version"
    APP_XDG_RUNTIME_DIR="$GAME_CACHE_DIR/xdg/runtime"
    GMLOADER_JSON="$GAME_CACHE_DIR/gmloader.json"
    RUN_INFO="$GAME_CACHE_DIR/run.info"
    GAME_LOG="$DETAILED_LOG"
    READABLE_GAME_STARTED="false"

    ensure_dir "$GAME_CACHE_DIR" "game cache" || return 1
    invalidate_generated_cache_if_needed || true
    ensure_dir "$SAVE_DIR" "save" || return 1
    ensure_dir "$SHADER_DIR" "shader" || return 1
    ensure_dir "$GAME_CACHE_DIR/home" "game home" || return 1
    ensure_dir "$GAME_CACHE_DIR/xdg/data" "game XDG data" || return 1
    ensure_dir "$GAME_CACHE_DIR/xdg/config" "game XDG config" || return 1
    ensure_dir "$GAME_CACHE_DIR/xdg/cache" "game XDG cache" || return 1
    ensure_dir "$APP_XDG_RUNTIME_DIR" "game XDG runtime" || return 1
    chmod_runtime_dir "$APP_XDG_RUNTIME_DIR" || true

    : >> "$GAME_LOG" 2>/dev/null || {
        log_error "Could not write detailed log: $GAME_LOG"
        say "Could not write the detailed log."
        return 1
    }

    log_info "Prepared cache for '$SELECTED_GAME_NAME': $GAME_CACHE_DIR"
    log_info "Prepared XDG_RUNTIME_DIR for '$SELECTED_GAME_NAME': $APP_XDG_RUNTIME_DIR"
    readable_section "Selected Game"
    readable_log "Prepared $SELECTED_GAME_NAME."
    readable_log "Cache: $GAME_CACHE_DIR"
    readable_log "Saves: $SAVE_DIR"
    return 0
}

guest_arch_dir_for_loader() {
    case "$LOADER_ARCH" in
        aarch64) printf '%s' "arm64-v8a" ;;
        armhf) printf '%s' "armeabi-v7a" ;;
        *) printf '%s' "" ;;
    esac
}

apk_libyoyo_entry_for_loader() {
    case "$LOADER_ARCH" in
        aarch64)
            if [ "$APK_HAS_ARM64" = "true" ]; then
                printf '%s' "lib/arm64-v8a/libyoyo.so"
                return 0
            fi
            ;;
        armhf)
            if [ "$APK_HAS_ARMV7" = "true" ]; then
                printf '%s' "lib/armeabi-v7a/libyoyo.so"
                return 0
            fi
            if [ "$APK_HAS_ARMEABI" = "true" ]; then
                printf '%s' "lib/armeabi/libyoyo.so"
                return 0
            fi
            ;;
    esac

    return 1
}

opensles_bridge_for_loader() {
    case "$LOADER_ARCH" in
        aarch64)
            if [ -f "$LIB_DIR/opensles/arm64-v8a/libopensles.so" ]; then
                printf '%s' "$LIB_DIR/opensles/arm64-v8a/libopensles.so"
                return 0
            fi
            if [ -f "$LIB_DIR/arm64-v8a/libopensles.so" ]; then
                printf '%s' "$LIB_DIR/arm64-v8a/libopensles.so"
                return 0
            fi
            if [ -f "$LIB_DIR/arm64-v8a/libOpenSLES.so" ]; then
                printf '%s' "$LIB_DIR/arm64-v8a/libOpenSLES.so"
                return 0
            fi
            ;;
        armhf)
            if [ -f "$LIB_DIR/opensles/armeabi-v7a/libopensles.so" ]; then
                printf '%s' "$LIB_DIR/opensles/armeabi-v7a/libopensles.so"
                return 0
            fi
            if [ -f "$LIB_DIR/android/armeabi-v7a/libopensles.so" ]; then
                printf '%s' "$LIB_DIR/android/armeabi-v7a/libopensles.so"
                return 0
            fi
            if [ -f "$LIB_DIR/android/armeabi-v7a/libOpenSLES.so" ]; then
                printf '%s' "$LIB_DIR/android/armeabi-v7a/libOpenSLES.so"
                return 0
            fi
            ;;
    esac

    return 1
}

opensles_support_dir_for_loader() {
    case "$LOADER_ARCH" in
        aarch64)
            [ -d "$LIB_DIR/opensles/arm64-v8a" ] && printf '%s' "$LIB_DIR/opensles/arm64-v8a" && return 0
            ;;
        armhf)
            [ -d "$LIB_DIR/opensles/armeabi-v7a" ] && printf '%s' "$LIB_DIR/opensles/armeabi-v7a" && return 0
            ;;
    esac

    return 1
}

elf_needer_for_system() {
    case "$ARCH_FAMILY" in
        aarch64)
            [ -f "$ELF_NEEDER_AARCH64" ] && printf '%s' "$ELF_NEEDER_AARCH64" && return 0
            ;;
        armhf)
            [ -f "$ELF_NEEDER_ARMHF" ] && printf '%s' "$ELF_NEEDER_ARMHF" && return 0
            ;;
    esac

    case "$LOADER_ARCH" in
        aarch64)
            [ -f "$ELF_NEEDER_AARCH64" ] && printf '%s' "$ELF_NEEDER_AARCH64" && return 0
            ;;
        armhf)
            [ -f "$ELF_NEEDER_ARMHF" ] && printf '%s' "$ELF_NEEDER_ARMHF" && return 0
            ;;
    esac

    return 1
}

copy_native_lib_dir_into_overlay() {
    local source_dir="$1"
    local target_dir="$2"

    [ -d "$source_dir" ] || return 0
    mkdir -p "$target_dir" 2>> "$LOG_FILE" || return 1
    cp -R "$source_dir"/. "$target_dir"/ 2>> "$LOG_FILE" || return 1
    return 0
}

prepare_opensles_overlay() {
    local guest_arch=""
    local apk_entry=""
    local overlay_root=""
    local overlay_arch=""
    local bridge_lib=""
    local support_dir=""
    local helper=""
    local patched_libyoyo=""

    OPENSL_OVERLAY_ROOT=""
    OPENSL_OVERLAY_ARCH_DIR=""
    OPENSL_BRIDGE_LIB=""

    case "$CFG_opensles_bridge" in
        on|force) ;;
        *)
            log_info "OpenSL ES bridge overlay disabled. Launching with the APK's original libyoyo.so for maximum compatibility."
            return 0
            ;;
    esac

    [ "$LOADER_MODE" = "next" ] || {
        log_info "OpenSL ES bridge overlay skipped for legacy gmloader."
        return 0
    }

    guest_arch="$(guest_arch_dir_for_loader)"
    if [ -z "$guest_arch" ]; then
        log_warn "OpenSL ES bridge overlay skipped because loader architecture is unknown."
        return 0
    fi

    apk_entry="$(apk_libyoyo_entry_for_loader || true)"
    if [ -z "$apk_entry" ]; then
        log_warn "OpenSL ES bridge overlay skipped because no compatible libyoyo.so entry was found for loader arch $LOADER_ARCH."
        return 0
    fi

    bridge_lib="$(opensles_bridge_for_loader || true)"
    if [ -z "$bridge_lib" ]; then
        log_warn "OpenSL ES bridge library is missing for $LOADER_ARCH. Audio may remain silent for Oboe/OpenSL ES games."
        return 0
    fi

    support_dir="$(opensles_support_dir_for_loader || true)"

    helper="$(elf_needer_for_system || true)"
    if [ -z "$helper" ]; then
        log_warn "OpenSL ES ELF patch helper is missing. Audio bridge cannot be forced into libyoyo.so."
        return 0
    fi

    if ! command -v unzip >/dev/null 2>&1; then
        log_warn "OpenSL ES bridge overlay requires unzip to extract libyoyo.so from APK."
        return 0
    fi

    make_executable "$helper" || {
        log_warn "OpenSL ES ELF patch helper is not executable: $helper"
        return 0
    }

    overlay_root="$GAME_CACHE_DIR/native"
    overlay_arch="$overlay_root/$guest_arch"
    patched_libyoyo="$overlay_arch/libyoyo.so"

    ensure_dir "$overlay_arch" "native audio overlay" || return 1

    case "$LOADER_ARCH" in
        aarch64)
            copy_native_lib_dir_into_overlay "$LIB_DIR/arm64-v8a" "$overlay_arch" || return 1
            copy_native_lib_dir_into_overlay "$LIB_DIR/android/arm64-v8a" "$overlay_arch" || return 1
            ;;
        armhf)
            copy_native_lib_dir_into_overlay "$LIB_DIR/android/armeabi-v7a" "$overlay_arch" || return 1
            copy_native_lib_dir_into_overlay "$LIB_DIR/android/armeabi-v7a-r19" "$overlay_arch" || true
            ;;
    esac

    cp "$bridge_lib" "$overlay_arch/libopensle.so" 2>> "$LOG_FILE" || {
        log_warn "Could not copy OpenSL ES bridge into overlay: $bridge_lib"
        return 0
    }
    cp "$bridge_lib" "$overlay_arch/libopensles.so" 2>> "$LOG_FILE" || true
    cp "$bridge_lib" "$overlay_arch/libOpenSLES.so" 2>> "$LOG_FILE" || true
    if [ -n "$support_dir" ] && [ -f "$support_dir/libpthread.so.0" ]; then
        cp "$support_dir/libpthread.so.0" "$overlay_arch/libpthread.so.0" 2>> "$LOG_FILE" || true
    fi

    if ! unzip -p "$SELECTED_APK" "$apk_entry" > "$patched_libyoyo" 2>> "$LOG_FILE"; then
        log_warn "Could not extract $apk_entry from APK for OpenSL ES overlay."
        rm -f "$patched_libyoyo" 2>/dev/null || true
        return 0
    fi

    if "$helper" "$patched_libyoyo" >> "$LOG_FILE" 2>&1; then
        OPENSL_OVERLAY_ROOT="$overlay_root"
        OPENSL_OVERLAY_ARCH_DIR="$overlay_arch"
        OPENSL_BRIDGE_LIB="$overlay_arch/libopensle.so"
        log_info "OpenSL ES bridge overlay prepared: root=$OPENSL_OVERLAY_ROOT arch_dir=$OPENSL_OVERLAY_ARCH_DIR"
        log_info "Patched libyoyo.so dependency for OpenSL ES bridge: $patched_libyoyo"
        return 0
    fi

    log_warn "OpenSL ES dependency patch did not apply to $patched_libyoyo. Audio bridge will not be forced for this game."
    return 0
}

json_escape() {
    local value="${1:-}"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\r'/\\r}"
    value="${value//$'\n'/\\n}"
    value="${value//$'\t'/\\t}"
    printf '%s' "$value"
}

write_run_info() {
    cat > "$RUN_INFO" <<EOF
game_name=$SELECTED_GAME_NAME
cache_name=$GAME_CACHE_NAME
game_kind=$SELECTED_KIND
apk_path=$SELECTED_APK
port_compat_version=$PILASRUNNER_COMPAT_VERSION
gmloader_json=$GMLOADER_JSON
save_dir=$SAVE_DIR
shader_dir=$SHADER_DIR
loader_bin=$LOADER_BIN
loader_arch=$LOADER_ARCH
loader_mode=$LOADER_MODE
library_path=$(build_library_path)
opensles_overlay_root=$OPENSL_OVERLAY_ROOT
opensles_overlay_arch_dir=$OPENSL_OVERLAY_ARCH_DIR
xdg_runtime_dir=$APP_XDG_RUNTIME_DIR
display=${DISPLAY:-}
wayland_display=${WAYLAND_DISPLAY:-}
sdl_videodriver=${SDL_VIDEODRIVER:-}
display_probe=$CFG_display_probe
display_wait_seconds=$CFG_display_wait_seconds
audio_driver=$CFG_audio_driver
audio_sample_rate=$CFG_audio_sample_rate
opensles_bridge=$CFG_opensles_bridge
ui_entry=$UI_ENTRY
ui_font=$UI_FONT
system_arch_raw=$ARCH_RAW
system_arch_family=$ARCH_FAMILY
device_arch=${DEVICE_ARCH:-}
textinputinteractive=${TEXTINPUTINTERACTIVE:-Y}
show_cursor=$CFG_show_cursor
disable_controller=$CFG_disable_controller
disable_joystick=$CFG_disable_joystick
disable_rumble=$CFG_disable_rumble
disable_depth=$CFG_disable_depth
disable_extensions=$CFG_disable_extensions
rumble_scale=$CFG_rumble_scale
force_platform=$CFG_force_platform
fullscreen=$CFG_fullscreen
dump_shaders=$CFG_dump_shaders
trace_vm=$CFG_trace_vm
controls_backend=$CFG_controls_backend
hotkey_quit=$CFG_hotkey_quit
hotkey_quit_grace_seconds=$CFG_hotkey_quit_grace_seconds
dry_run=$CFG_dry_run
EOF
}

generate_gmloader_json() {
    local apk_json=""
    local save_json=""
    local shader_json=""
    local platform_json=""

    apk_json="$(json_escape "$SELECTED_APK")"
    save_json="$(json_escape "$SAVE_DIR")"
    shader_json="$(json_escape "$SHADER_DIR")"
    platform_json="$(json_escape "$CFG_force_platform")"

    if ! cat > "$GMLOADER_JSON" <<EOF
{
  "apk_path": "$apk_json",
  "save_dir": "$save_json",
  "shader_dir": "$shader_json",
  "show_cursor": $CFG_show_cursor,
  "disable_controller": $CFG_disable_controller,
  "disable_depth": $CFG_disable_depth,
  "disable_extensions": $CFG_disable_extensions,
  "disable_joystick": $CFG_disable_joystick,
  "disable_rumble": $CFG_disable_rumble,
  "rumble_scale": $CFG_rumble_scale,
  "force_platform": "$platform_json",
  "fullscreen": $CFG_fullscreen
}
EOF
    then
        log_error "Could not write gmloader.json: $GMLOADER_JSON"
        say "Could not write gmloader.json."
        return 1
    fi

    if ! write_run_info; then
        log_warn "Could not write run.info: $RUN_INFO"
    fi

    log_info "Generated gmloader.json: $GMLOADER_JSON"
    return 0
}

control_key_index() {
    local target="$1"
    local i=0

    for ((i = 0; i < ${#CONTROL_KEYS[@]}; i++)); do
        if [ "${CONTROL_KEYS[$i]}" = "$target" ]; then
            printf '%s' "$i"
            return 0
        fi
    done

    return 1
}

init_builtin_controls() {
    CONTROL_VALUES=(
        UP DOWN LEFT RIGHT
        Z X C V
        Q E SHIFT CTRL
        ENTER ESC
        TAB SPACE
    )
}

normalize_control_value() {
    local value
    value="$(upper "$(trim "$1")")"

    case "$value" in
        RETURN) value="ENTER" ;;
        ESCAPE) value="ESC" ;;
        CONTROL) value="CTRL" ;;
        LEFTSHIFT|RIGHTSHIFT) value="SHIFT" ;;
        LEFTCTRL|RIGHTCTRL) value="CTRL" ;;
        LEFTALT|RIGHTALT) value="ALT" ;;
        ARROW_UP|KEY_UP) value="UP" ;;
        ARROW_DOWN|KEY_DOWN) value="DOWN" ;;
        ARROW_LEFT|KEY_LEFT) value="LEFT" ;;
        ARROW_RIGHT|KEY_RIGHT) value="RIGHT" ;;
    esac

    case "$value" in
        W|A|S|D|Z|X|C|V|Q|E|ENTER|ESC|SPACE|SHIFT|CTRL|ALT|TAB|UP|DOWN|LEFT|RIGHT)
            printf '%s' "$value"
            return 0
            ;;
    esac

    return 1
}

parse_controls_file() {
    local file="$1"
    local label="$2"
    local raw_line=""
    local line=""
    local section=""
    local key=""
    local value=""
    local normalized_value=""
    local index=""
    local line_number=0

    [ -f "$file" ] || return 1

    log_info "Parsing controls file ($label): $file"

    while IFS= read -r raw_line || [ -n "$raw_line" ]; do
        line_number=$((line_number + 1))
        line="${raw_line%$'\r'}"
        line="$(trim "$line")"

        case "$line" in
            ""|\#*|\;*) continue ;;
        esac

        if [ "${line#\[}" != "$line" ]; then
            if [ "${line%\]}" = "$line" ]; then
                log_warn "Malformed section header in $file line $line_number: $line"
                continue
            fi
            section="${line#\[}"
            section="${section%\]}"
            section="$(lower "$(trim "$section")")"
            continue
        fi

        [ "$section" = "buttons" ] || continue

        if [ "${line#*=}" = "$line" ]; then
            log_warn "Malformed controls line ignored in $file line $line_number: $line"
            continue
        fi

        key="$(lower "$(trim "${line%%=*}")")"
        value="$(strip_optional_quotes "$(trim "${line#*=}")")"

        if ! index="$(control_key_index "$key")"; then
            log_warn "Unknown control key ignored in $file line $line_number: $key"
            continue
        fi

        if ! normalized_value="$(normalize_control_value "$value")"; then
            log_warn "Unsupported control value ignored in $file line $line_number: $key=$value"
            continue
        fi

        CONTROL_VALUES[$index]="$normalized_value"
        log_info "Control mapping: $key=$normalized_value"
    done < "$file"

    return 0
}

find_controls_file() {
    local game_dir=""
    local sidecar=""
    local side_folder=""

    if [ "$SELECTED_KIND" = "folder" ]; then
        game_dir="$(dirname "$SELECTED_APK")"
        if [ -f "$game_dir/controls.ini" ]; then
            printf '%s' "$game_dir/controls.ini"
            return 0
        fi
        return 1
    fi

    sidecar="${SELECTED_APK%.*}.controls.ini"
    side_folder="$GAMES_DIR/$SELECTED_BASE/controls.ini"

    if [ -f "$sidecar" ]; then
        printf '%s' "$sidecar"
        return 0
    fi

    if [ -f "$side_folder" ]; then
        printf '%s' "$side_folder"
        return 0
    fi

    return 1
}

write_controls_outputs() {
    local normalized_file="$GAME_CACHE_DIR/controls.normalized.ini"
    local gptk_file="$GAME_CACHE_DIR/$GAME_CACHE_NAME.gptk"
    local gptk2_file="$GAME_CACHE_DIR/gptokeyb2.ini"

    {
        say "# Generated by YoYo Pilas Runner."
        say "# This is the validated control map used for this launch."
        say ""
        say "[buttons]"
        for ((i = 0; i < ${#CONTROL_KEYS[@]}; i++)); do
            printf '%s=%s\n' "${CONTROL_KEYS[$i]}" "${CONTROL_VALUES[$i]}"
        done
    } > "$normalized_file" || {
        log_warn "Could not write normalized controls file: $normalized_file"
        return 1
    }

    {
        say "# Generated PortMaster GptokeyB mapping."
        say "# Values come from controls.ini after validation."
        say ""
        printf 'up = "%s"\n' "${CONTROL_VALUES[0]}"
        printf 'down = "%s"\n' "${CONTROL_VALUES[1]}"
        printf 'left = "%s"\n' "${CONTROL_VALUES[2]}"
        printf 'right = "%s"\n' "${CONTROL_VALUES[3]}"
        printf 'a = "%s"\n' "${CONTROL_VALUES[4]}"
        printf 'b = "%s"\n' "${CONTROL_VALUES[5]}"
        printf 'x = "%s"\n' "${CONTROL_VALUES[6]}"
        printf 'y = "%s"\n' "${CONTROL_VALUES[7]}"
        printf 'l1 = "%s"\n' "${CONTROL_VALUES[8]}"
        printf 'r1 = "%s"\n' "${CONTROL_VALUES[9]}"
        printf 'l2 = "%s"\n' "${CONTROL_VALUES[10]}"
        printf 'r2 = "%s"\n' "${CONTROL_VALUES[11]}"
        printf 'start = "%s"\n' "${CONTROL_VALUES[12]}"
        printf 'back = "%s"\n' "${CONTROL_VALUES[13]}"
        printf 'l3 = "%s"\n' "${CONTROL_VALUES[14]}"
        printf 'r3 = "%s"\n' "${CONTROL_VALUES[15]}"
        say 'left_analog_up = ""'
        say 'left_analog_down = ""'
        say 'left_analog_left = ""'
        say 'left_analog_right = ""'
        say 'right_analog_up = ""'
        say 'right_analog_down = ""'
        say 'right_analog_left = ""'
        say 'right_analog_right = ""'
    } > "$gptk_file" || {
        log_warn "Could not write GptokeyB-style controls file: $gptk_file"
        return 1
    }

    {
        say "# Generated gptokeyb2-compatible mapping."
        say ""
        say "[controls]"
        printf 'up = %s\n' "${CONTROL_VALUES[0]}"
        printf 'down = %s\n' "${CONTROL_VALUES[1]}"
        printf 'left = %s\n' "${CONTROL_VALUES[2]}"
        printf 'right = %s\n' "${CONTROL_VALUES[3]}"
        printf 'a = %s\n' "${CONTROL_VALUES[4]}"
        printf 'b = %s\n' "${CONTROL_VALUES[5]}"
        printf 'x = %s\n' "${CONTROL_VALUES[6]}"
        printf 'y = %s\n' "${CONTROL_VALUES[7]}"
        printf 'l1 = %s\n' "${CONTROL_VALUES[8]}"
        printf 'r1 = %s\n' "${CONTROL_VALUES[9]}"
        printf 'l2 = %s\n' "${CONTROL_VALUES[10]}"
        printf 'r2 = %s\n' "${CONTROL_VALUES[11]}"
        printf 'start = %s\n' "${CONTROL_VALUES[12]}"
        printf 'back = %s\n' "${CONTROL_VALUES[13]}"
        printf 'l3 = %s\n' "${CONTROL_VALUES[14]}"
        printf 'r3 = %s\n' "${CONTROL_VALUES[15]}"
    } > "$gptk2_file" || {
        log_warn "Could not write gptokeyb2 controls file: $gptk2_file"
        return 1
    }

    log_info "Generated controls output: $normalized_file"
    log_info "Generated GptokeyB-style controls output: $gptk_file"
    log_info "Generated gptokeyb2 controls output: $gptk2_file"
    GPTOKEYB_CONFIG="$gptk_file"
    return 0
}

process_controls() {
    local controls_source=""
    local default_controls="$DEFAULTS_DIR/default_controls.ini"
    local copied_source="$GAME_CACHE_DIR/controls.source.ini"

    init_builtin_controls

    if [ -f "$default_controls" ]; then
        parse_controls_file "$default_controls" "default" || log_warn "Could not parse default controls file: $default_controls"
    else
        log_warn "Default controls file was not found. Built-in defaults will be used."
    fi

    if controls_source="$(find_controls_file)"; then
        log_info "Per-game controls.ini found: $controls_source"
        if cp "$controls_source" "$copied_source" 2>> "$LOG_FILE"; then
            log_info "Copied controls source to cache: $copied_source"
        else
            log_warn "Could not copy controls source to cache: $controls_source"
        fi
        parse_controls_file "$controls_source" "per-game" || log_warn "Could not parse per-game controls file: $controls_source"
    else
        log_info "No per-game controls.ini found. Default controls will be used."
    fi

    write_controls_outputs || true
    log_info "Controls processing complete."
    return 0
}

build_library_path() {
    local output=""

    add_library_dir() {
        local dir="$1"
        [ -d "$dir" ] || return 0

        case ":$output:" in
            *":$dir:"*) return 0 ;;
        esac

        if [ -n "$output" ]; then
            output="$output:$dir"
        else
            output="$dir"
        fi
    }

    case "$LOADER_ARCH:$LOADER_MODE" in
        aarch64:*)
            add_library_dir "$LIB_DIR/arm64-v8a"
            add_library_dir "$LIB_DIR/android/arm64-v8a"
            ;;
        armhf:legacy)
            add_library_dir "$LIB_DIR/legacy-armhf"
            add_library_dir "$LIB_DIR/armhf"
            add_library_dir "$LIB_DIR/android/armeabi-v7a"
            add_library_dir "$LIB_DIR/android/armeabi-v7a-r19"
            ;;
        armhf:*)
            add_library_dir "$LIB_DIR/armhf"
            add_library_dir "$LIB_DIR/android/armeabi-v7a"
            add_library_dir "$LIB_DIR/android/armeabi-v7a-r19"
            ;;
    esac

    add_library_dir "$LIB_DIR"

    if [ -n "${LD_LIBRARY_PATH:-}" ]; then
        if [ -n "$output" ]; then
            output="$output:${LD_LIBRARY_PATH:-}"
        else
            output="${LD_LIBRARY_PATH:-}"
        fi
    fi

    printf '%s' "$output"
}

build_gmloader_lib_path() {
    local root_arch_dir=""
    local android_arch_dir=""

    if [ -n "$OPENSL_OVERLAY_ROOT" ] && [ -d "$OPENSL_OVERLAY_ROOT" ]; then
        printf '%s' "$OPENSL_OVERLAY_ROOT"
        return 0
    fi

    case "$LOADER_ARCH" in
        aarch64)
            root_arch_dir="$LIB_DIR/arm64-v8a"
            android_arch_dir="$LIB_DIR/android/arm64-v8a"
            ;;
        armhf)
            root_arch_dir="$LIB_DIR/armeabi-v7a"
            android_arch_dir="$LIB_DIR/android/armeabi-v7a"
            ;;
    esac

    if [ -n "$root_arch_dir" ] && [ -f "$root_arch_dir/libm.so" ]; then
        printf '%s' "$LIB_DIR"
        return 0
    fi

    if [ -n "$android_arch_dir" ] && [ -f "$android_arch_dir/libm.so" ]; then
        printf '%s' "$LIB_DIR/android"
        return 0
    fi

    if [ -n "$root_arch_dir" ] && [ -d "$root_arch_dir" ]; then
        printf '%s' "$LIB_DIR"
        return 0
    fi

    if [ -n "$android_arch_dir" ] && [ -d "$android_arch_dir" ]; then
        printf '%s' "$LIB_DIR/android"
        return 0
    fi

    printf '%s' ""
}

find_runtime_arch_library() {
    local libname="$1"
    local arch_dir=""
    local root=""
    local candidate=""

    case "$LOADER_ARCH" in
        aarch64) arch_dir="arm64-v8a" ;;
        armhf) arch_dir="armeabi-v7a" ;;
        *) arch_dir="" ;;
    esac

    for root in "$OPENSL_OVERLAY_ROOT" "$LIB_DIR" "$LIB_DIR/android" "$LIB_DIR/opensles" "$LIB_DIR/audio"; do
        [ -n "$root" ] || continue
        if [ -n "$arch_dir" ]; then
            candidate="$root/$arch_dir/$libname"
            if [ -f "$candidate" ]; then
                printf '%s' "$candidate"
                return 0
            fi
        fi

        candidate="$root/$libname"
        if [ -f "$candidate" ]; then
            printf '%s' "$candidate"
            return 0
        fi
    done

    return 1
}

detect_pulse_server() {
    local uid=""
    local socket_path=""

    [ -z "${PULSE_SERVER:-}" ] || return 0

    uid="$(id -u 2>/dev/null || printf '%s' '0')"
    for socket_path in "/run/user/$uid/pulse/native" "/var/run/user/$uid/pulse/native" "/tmp/pulse-$uid/native"; do
        if [ -S "$socket_path" ]; then
            export PULSE_SERVER="unix:$socket_path"
            log_info "Detected PulseAudio socket: $PULSE_SERVER"
            return 0
        fi
    done

    return 1
}

configure_audio_environment() {
    local driver="$CFG_audio_driver"
    local opensles_lib=""
    local opensles_lib_lower=""
    local aaudio_lib=""

    opensles_lib="$(find_runtime_arch_library "libOpenSLES.so" || true)"
    opensles_lib_lower="$(find_runtime_arch_library "libopensles.so" || true)"
    aaudio_lib="$(find_runtime_arch_library "libaaudio.so" || true)"

    detect_pulse_server || true

    case "$driver" in
        off)
            export SDL_AUDIODRIVER="dummy"
            ;;
        auto)
            log_info "SDL audio driver left on automatic selection."
            ;;
        *)
            export SDL_AUDIODRIVER="$driver"
            ;;
    esac

    export SDL_AUDIO_FREQUENCY="${SDL_AUDIO_FREQUENCY:-$CFG_audio_sample_rate}"
    export SLES_SDL_FREQ="${SLES_SDL_FREQ:-$CFG_audio_sample_rate}"
    export ALSOFT_DRIVERS="${ALSOFT_DRIVERS:-alsa,pulse,pipewire}"

    if [ -n "$opensles_lib" ] || [ -n "$opensles_lib_lower" ]; then
        log_info "Android OpenSL ES runtime found: ${opensles_lib:-$opensles_lib_lower}"
        if [ -n "$OPENSL_OVERLAY_ROOT" ]; then
            log_info "OpenSL ES bridge overlay is active: $OPENSL_OVERLAY_ROOT"
        fi
    else
        log_warn "Android OpenSL ES runtime libOpenSLES.so was not found for $LOADER_ARCH. Oboe-based GameMaker audio may fall back to silence."
    fi

    if [ -n "$aaudio_lib" ]; then
        log_info "Android AAudio runtime found: $aaudio_lib"
    else
        log_info "Android AAudio runtime libaaudio.so was not found. Oboe should try OpenSL ES next when libOpenSLES.so is available."
    fi
}

log_display_environment() {
    local library_path="$1"
    local gmloader_lib_path="${2:-}"

    log_info "Environment DISPLAY=${DISPLAY:-}"
    log_info "Environment WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-}"
    log_info "Environment SDL_VIDEODRIVER=${SDL_VIDEODRIVER:-}"
    log_info "Environment SDL_AUDIODRIVER=${SDL_AUDIODRIVER:-}"
    log_info "Environment SDL_AUDIO_FREQUENCY=${SDL_AUDIO_FREQUENCY:-}"
    log_info "Environment SLES_SDL_FREQ=${SLES_SDL_FREQ:-}"
    log_info "Environment PULSE_SERVER=${PULSE_SERVER:-}"
    log_info "Environment ALSOFT_DRIVERS=${ALSOFT_DRIVERS:-}"
    log_info "Environment XDG_RUNTIME_DIR=$APP_XDG_RUNTIME_DIR"
    log_info "Environment app LD_LIBRARY_PATH=$library_path"
    log_info "Environment GMLOADER_LIB_PATH=$gmloader_lib_path"
    log_info "Outer LD_LIBRARY_PATH remains scoped outside the app launch path."
}

probe_x11_display() {
    local wait_seconds="$CFG_display_wait_seconds"
    local elapsed=0
    local probe_tool=""

    if [ -z "${DISPLAY:-}" ]; then
        log_info "X11 readiness probe skipped: DISPLAY is empty."
        return 0
    fi

    if command -v xdpyinfo >/dev/null 2>&1; then
        probe_tool="xdpyinfo"
    elif command -v xset >/dev/null 2>&1; then
        probe_tool="xset"
    else
        log_warn "X11 readiness probe requested for DISPLAY=${DISPLAY:-}, but neither xdpyinfo nor xset is available. Launching anyway."
        return 0
    fi

    log_info "Waiting for X11 display ${DISPLAY:-} with $probe_tool for up to ${wait_seconds}s."
    while [ "$elapsed" -le "$wait_seconds" ]; do
        if [ "$probe_tool" = "xdpyinfo" ]; then
            DISPLAY="${DISPLAY:-}" xdpyinfo >/dev/null 2>&1 && {
                log_info "X11 display ${DISPLAY:-} accepted a connection after ${elapsed}s."
                return 0
            }
        else
            DISPLAY="${DISPLAY:-}" xset q >/dev/null 2>&1 && {
                log_info "X11 display ${DISPLAY:-} accepted a connection after ${elapsed}s."
                return 0
            }
        fi

        [ "$elapsed" -ge "$wait_seconds" ] && break
        elapsed=$((elapsed + 1))
        sleep 1
    done

    log_warn "X11 readiness probe timed out for DISPLAY=${DISPLAY:-}. Running one verbose final probe and launching anyway."
    if [ "$probe_tool" = "xdpyinfo" ]; then
        DISPLAY="${DISPLAY:-}" xdpyinfo >> "$GAME_LOG" 2>&1 || true
    else
        DISPLAY="${DISPLAY:-}" xset q >> "$GAME_LOG" 2>&1 || true
    fi
    return 0
}

probe_wayland_display() {
    local wait_seconds="$CFG_display_wait_seconds"
    local elapsed=0
    local socket_path=""

    if [ -z "${WAYLAND_DISPLAY:-}" ]; then
        log_info "Wayland readiness probe skipped: WAYLAND_DISPLAY is empty."
        return 0
    fi

    case "${WAYLAND_DISPLAY:-}" in
        /*) socket_path="${WAYLAND_DISPLAY:-}" ;;
        *) socket_path="$APP_XDG_RUNTIME_DIR/${WAYLAND_DISPLAY:-}" ;;
    esac

    log_info "Waiting for Wayland display ${WAYLAND_DISPLAY:-} at $socket_path for up to ${wait_seconds}s."
    while [ "$elapsed" -le "$wait_seconds" ]; do
        if [ -S "$socket_path" ] || [ -e "$socket_path" ]; then
            log_info "Wayland display ${WAYLAND_DISPLAY:-} appeared after ${elapsed}s."
            return 0
        fi

        [ "$elapsed" -ge "$wait_seconds" ] && break
        elapsed=$((elapsed + 1))
        sleep 1
    done

    log_warn "Wayland readiness probe timed out for WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-} at $socket_path. Launching anyway."
    return 0
}

probe_display_readiness() {
    local mode="$CFG_display_probe"

    case "$mode" in
        none)
            log_info "Display readiness probe disabled by configuration."
            return 0
            ;;
        auto)
            if [ -n "${DISPLAY:-}" ]; then
                probe_x11_display
            elif [ -n "${WAYLAND_DISPLAY:-}" ]; then
                probe_wayland_display
            else
                log_info "Display readiness probe skipped: neither DISPLAY nor WAYLAND_DISPLAY is set."
            fi
            ;;
        x11)
            probe_x11_display
            ;;
        wayland)
            probe_wayland_display
            ;;
    esac

    return 0
}

finish_dry_run() {
    local library_path=""
    local gmloader_lib_path=""

    library_path="$(build_library_path)"
    gmloader_lib_path="$(build_gmloader_lib_path)"
    begin_readable_game_log
    configure_audio_environment
    log_info "Dry run requested. Skipping loader execution."
    log_info "Dry run selected loader: $LOADER_BIN ($LOADER_ARCH, mode=$LOADER_MODE)"
    log_info "Dry run LD_LIBRARY_PATH=$library_path"
    log_info "Dry run GMLOADER_LIB_PATH=$gmloader_lib_path"
    log_display_environment "$library_path" "$gmloader_lib_path"
    probe_display_readiness

    {
        printf '\n[%s] Dry run for %s\n' "$(timestamp)" "$SELECTED_GAME_NAME"
        printf 'APK: %s\n' "$SELECTED_APK"
        printf 'Config: %s\n' "$GMLOADER_JSON"
        printf 'Loader: %s\n' "$LOADER_BIN"
        printf 'Loader arch: %s\n' "$LOADER_ARCH"
        printf 'Loader mode: %s\n' "$LOADER_MODE"
        printf 'LD_LIBRARY_PATH: %s\n' "$library_path"
        printf 'GMLOADER_LIB_PATH: %s\n' "$gmloader_lib_path"
        printf 'SDL_AUDIODRIVER: %s\n' "${SDL_AUDIODRIVER:-}"
        printf 'SDL_AUDIO_FREQUENCY: %s\n' "${SDL_AUDIO_FREQUENCY:-}"
        printf 'SLES_SDL_FREQ: %s\n' "${SLES_SDL_FREQ:-}"
        printf 'XDG_RUNTIME_DIR: %s\n' "$APP_XDG_RUNTIME_DIR"
        printf 'DISPLAY: %s\n' "${DISPLAY:-}"
        printf 'WAYLAND_DISPLAY: %s\n' "${WAYLAND_DISPLAY:-}"
        printf 'SDL_VIDEODRIVER: %s\n' "${SDL_VIDEODRIVER:-}"
        printf 'No ARM binary was executed.\n'
    } >> "$GAME_LOG" 2>/dev/null || true

    say "Dry run complete."
    say "Selected game: $SELECTED_GAME_NAME"
    say "Selected loader: $LOADER_BIN ($LOADER_ARCH, $LOADER_MODE)"
    say "Generated config: $GMLOADER_JSON"
    say "Detailed log: $DETAILED_LOG"
    finish_readable_game_log 0 "Dry run"
    return 0
}

find_gptokeyb() {
    local candidate=""

    GPTOKEYB_BIN=""

    if [ "$CFG_controls_backend" = "none" ]; then
        log_info "controls_backend=none. GptokeyB will not be started."
        return 1
    fi

    if [ -n "$CFG_gptokeyb_binary" ]; then
        if [ -x "$CFG_gptokeyb_binary" ]; then
            GPTOKEYB_BIN="$CFG_gptokeyb_binary"
            log_info "Using configured GptokeyB binary: $GPTOKEYB_BIN"
            return 0
        fi
        log_warn "Configured gptokeyb_binary is not executable: $CFG_gptokeyb_binary"
        [ "$CFG_controls_backend" = "gptokeyb" ] && return 1
    fi

    for candidate in "${GPTOKEYB:-}" "${GPTOKEYB2:-}" gptokeyb2 gptokeyb "$PORT_DIR/gptokeyb2" "$PORT_DIR/gptokeyb" "$RUNTIME_DIR/gptokeyb2" "$RUNTIME_DIR/gptokeyb"; do
        [ -n "$candidate" ] || continue
        if command -v "$candidate" >/dev/null 2>&1; then
            GPTOKEYB_BIN="$(command -v "$candidate")"
            log_info "Auto-detected GptokeyB binary: $GPTOKEYB_BIN"
            return 0
        fi
        if [ -x "$candidate" ]; then
            GPTOKEYB_BIN="$candidate"
            log_info "Auto-detected GptokeyB binary: $GPTOKEYB_BIN"
            return 0
        fi
    done

    if [ "$CFG_controls_backend" = "gptokeyb" ]; then
        log_warn "controls_backend=gptokeyb but no GptokeyB binary was found."
    else
        log_info "No GptokeyB binary found. Continuing without external control mapper."
    fi
    return 1
}

start_gptokeyb() {
    [ -n "$GPTOKEYB_CONFIG" ] || return 1
    export TEXTINPUTINTERACTIVE="${TEXTINPUTINTERACTIVE:-Y}"
    find_gptokeyb || return 1

    "$GPTOKEYB_BIN" "$(basename "$LOADER_BIN")" -c "$GPTOKEYB_CONFIG" >> "$GAME_LOG" 2>&1 &
    GPTOKEYB_PID="$!"
    GPTOKEYB_WAS_STARTED="true"
    log_info "Started GptokeyB: bin=$GPTOKEYB_BIN pid=$GPTOKEYB_PID config=$GPTOKEYB_CONFIG"
    sleep 1
    return 0
}

stop_gptokeyb() {
    if [ -n "$GPTOKEYB_PID" ]; then
        kill "$GPTOKEYB_PID" >/dev/null 2>&1 || true
        wait "$GPTOKEYB_PID" >/dev/null 2>&1 || true
        log_info "Stopped GptokeyB pid=$GPTOKEYB_PID"
        GPTOKEYB_PID=""
    fi
}

restart_portmaster_input_events() {
    [ "$GPTOKEYB_WAS_STARTED" = "true" ] || return 0
    GPTOKEYB_WAS_STARTED="false"

    command -v systemctl >/dev/null 2>&1 || return 0

    if [ -n "${ESUDO:-}" ]; then
        # shellcheck disable=SC2086
        $ESUDO systemctl restart oga_events >> "$GAME_LOG" 2>&1 &
    else
        systemctl restart oga_events >> "$GAME_LOG" 2>&1 &
    fi

    log_info "Requested oga_events restart."
}

find_python_runtime() {
    local candidate=""

    for candidate in "${PYTHON_BIN:-}" "${PYTHON:-}" python3 python; do
        [ -n "$candidate" ] || continue
        if command -v "$candidate" >/dev/null 2>&1; then
            command -v "$candidate"
            return 0
        fi
        if [ -x "$candidate" ]; then
            printf '%s' "$candidate"
            return 0
        fi
    done

    return 1
}

prepare_input_device_access() {
    local event_path=""
    local changed="false"
    local input_log="${GAME_LOG:-$LOG_FILE}"

    [ -d /dev/input ] || return 0

    for event_path in /dev/input/event*; do
        [ -e "$event_path" ] || continue
        if [ ! -r "$event_path" ]; then
            if [ -n "${ESUDO:-}" ]; then
                # shellcheck disable=SC2086
                $ESUDO chmod a+r "$event_path" >> "$input_log" 2>&1 && changed="true" || true
            else
                chmod a+r "$event_path" >> "$input_log" 2>&1 && changed="true" || true
            fi
        fi
    done

    [ "$changed" = "true" ] && log_info "Adjusted read access for one or more /dev/input/event devices."
    return 0
}

pid_is_alive() {
    local pid="$1"
    [ -n "$pid" ] || return 1
    kill -0 "$pid" >/dev/null 2>&1
}

cleanup_stale_runtime_processes() {
    local proc=""
    local pid=""
    local cmdline=""
    local killed="false"

    [ -d /proc ] || return 0

    for proc in /proc/[0-9]*; do
        [ -d "$proc" ] || continue
        pid="${proc##*/}"
        case "$pid" in
            "$$"|"$PPID") continue ;;
        esac

        cmdline="$(tr '\000' ' ' < "$proc/cmdline" 2>/dev/null || true)"
        [ -n "$cmdline" ] || continue

        case "$cmdline" in
            *"$RUNTIME_DIR/bin/gmloadernext.aarch64"*|*"$RUNTIME_DIR/bin/gmloadernext.armhf"*|*"$RUNTIME_DIR/bin/gmloader.armhf"*|*"$RUNTIME_DIR/bin/pilasrunner-ui.aarch64"*|*"$RUNTIME_DIR/bin/pilasrunner-ui.armhf"*|*"$RUNTIME_DIR/bin/pilasrunner-hotkey.aarch64"*|*"$RUNTIME_DIR/bin/pilasrunner-hotkey.armhf"*)
                log_warn "Killing stale YoYo Pilas Runner process pid=$pid cmd=$cmdline"
                kill -KILL "$pid" >/dev/null 2>&1 || true
                killed="true"
                ;;
        esac
    done

    [ "$killed" = "true" ] && sleep 0.2
    return 0
}

force_kill_game_process() {
    local pid="$1"
    local reason="$2"
    local pgid=""
    [ -n "$pid" ] || return 1
    log_warn "$reason. Sending SIGKILL to pid $pid."
    pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d '[:space:]' || true)"
    if [ "$pgid" = "$pid" ]; then
        log_warn "Target pid $pid is its own process-group leader; sending group SIGKILL too."
        kill -KILL "-$pid" >/dev/null 2>&1 || true
    fi
    kill -KILL "$pid" >/dev/null 2>&1 || true
}

hotkey_flag_monitor() {
    local game_pid="$1"
    local flag_path="$2"
    local log_path="$3"

    while pid_is_alive "$game_pid"; do
        if [ -n "$flag_path" ] && [ -f "$flag_path" ]; then
            printf '[%s] [HOTKEY_SH] Force-quit flag detected for pid %s.\n' "$(timestamp)" "$game_pid" >> "$log_path" 2>/dev/null || true
            force_kill_game_process "$game_pid" "Shell hotkey monitor force quit"
            return 0
        fi
        sleep 0.1
    done
    return 0
}

start_hotkey_watcher() {
    local game_pid="$1"
    local native_hotkey=""
    local python_bin=""
    local watcher="$SCRIPTS_DIR/hotkey_watcher.py"
    local watcher_pid=""
    local started="false"

    HOTKEY_WATCHER_PID=""
    HOTKEY_WATCHER_PIDS=""
    HOTKEY_WAS_TRIGGERED="false"
    HOTKEY_FORCE_QUIT_FLAG="$GAME_CACHE_DIR/force_quit.flag"
    rm -f "$HOTKEY_FORCE_QUIT_FLAG" 2>/dev/null || true

    [ "$CFG_hotkey_quit" = "true" ] || {
        log_info "Select+Start force-quit hotkey disabled by configuration."
        return 1
    }

    case "$ARCH_FAMILY" in
        aarch64) native_hotkey="$NATIVE_HOTKEY_AARCH64" ;;
        armhf) native_hotkey="$NATIVE_HOTKEY_ARMHF" ;;
    esac

    if [ -z "$native_hotkey" ] || [ ! -f "$native_hotkey" ]; then
        case "$LOADER_ARCH" in
            aarch64) native_hotkey="$NATIVE_HOTKEY_AARCH64" ;;
            armhf) native_hotkey="$NATIVE_HOTKEY_ARMHF" ;;
        esac
    fi

    prepare_input_device_access || true

    if [ -n "$native_hotkey" ] && [ -f "$native_hotkey" ]; then
        if make_executable "$native_hotkey"; then
            "$native_hotkey" \
                --pid "$game_pid" \
                --flag "$HOTKEY_FORCE_QUIT_FLAG" \
                --log "$GAME_LOG" >> "$GAME_LOG" 2>&1 &
            watcher_pid="$!"
            HOTKEY_WATCHER_PID="$watcher_pid"
            HOTKEY_WATCHER_PIDS="${HOTKEY_WATCHER_PIDS:+$HOTKEY_WATCHER_PIDS }$watcher_pid"
            started="true"
            log_info "Started native Select+Start hotkey watcher: pid=$watcher_pid target=$game_pid bin=$native_hotkey"
        else
            log_warn "Native Select+Start hotkey watcher exists but could not be made executable: $native_hotkey"
        fi
    else
        log_warn "Native Select+Start hotkey watcher binary was not found for arch=$ARCH_FAMILY loader=$LOADER_ARCH."
    fi

    if [ -f "$watcher" ]; then
        python_bin="$(find_python_runtime || true)"
    fi

    if [ ! -f "$watcher" ]; then
        log_warn "Hotkey watcher script was not found: $watcher"
    elif [ -z "$python_bin" ]; then
        log_warn "Python was not found. Select+Start force-quit hotkey is unavailable."
    else
        "$python_bin" "$watcher" \
            --pid "$game_pid" \
            --flag "$HOTKEY_FORCE_QUIT_FLAG" \
            --log "$GAME_LOG" \
            --grace "$CFG_hotkey_quit_grace_seconds" >> "$GAME_LOG" 2>&1 &

        watcher_pid="$!"
        HOTKEY_WATCHER_PIDS="${HOTKEY_WATCHER_PIDS:+$HOTKEY_WATCHER_PIDS }$watcher_pid"
        [ -z "$HOTKEY_WATCHER_PID" ] && HOTKEY_WATCHER_PID="$watcher_pid"
        started="true"
        log_info "Started Python Select+Start hotkey watcher fallback: pid=$watcher_pid target=$game_pid"
    fi

    hotkey_flag_monitor "$game_pid" "$HOTKEY_FORCE_QUIT_FLAG" "$GAME_LOG" &
    watcher_pid="$!"
    HOTKEY_WATCHER_PIDS="${HOTKEY_WATCHER_PIDS:+$HOTKEY_WATCHER_PIDS }$watcher_pid"
    log_info "Started shell hotkey flag monitor: pid=$watcher_pid target=$game_pid"

    [ "$started" = "true" ] && return 0
    return 1
}

stop_hotkey_watcher() {
    local watcher_pid=""
    if [ -n "$HOTKEY_WATCHER_PIDS" ]; then
        for watcher_pid in $HOTKEY_WATCHER_PIDS; do
            kill "$watcher_pid" >/dev/null 2>&1 || true
        done
        for watcher_pid in $HOTKEY_WATCHER_PIDS; do
            wait "$watcher_pid" >/dev/null 2>&1 || true
        done
        log_info "Stopped Select+Start hotkey watcher pids=$HOTKEY_WATCHER_PIDS"
        HOTKEY_WATCHER_PID=""
        HOTKEY_WATCHER_PIDS=""
    elif [ -n "$HOTKEY_WATCHER_PID" ]; then
        kill "$HOTKEY_WATCHER_PID" >/dev/null 2>&1 || true
        wait "$HOTKEY_WATCHER_PID" >/dev/null 2>&1 || true
        log_info "Stopped Select+Start hotkey watcher pid=$HOTKEY_WATCHER_PID"
        HOTKEY_WATCHER_PID=""
    fi
}

check_hotkey_force_quit() {
    HOTKEY_WAS_TRIGGERED="false"

    if [ -n "$HOTKEY_FORCE_QUIT_FLAG" ] && [ -f "$HOTKEY_FORCE_QUIT_FLAG" ]; then
        HOTKEY_WAS_TRIGGERED="true"
        log_warn "Select+Start force-quit hotkey was triggered for '$SELECTED_GAME_NAME'."
        printf '[%s] Select+Start force-quit requested.\n' "$(timestamp)" >> "$GAME_LOG" 2>/dev/null || true
    fi
}

run_game() {
    local status=0
    local library_path=""
    local gmloader_lib_path=""
    local game_pid=""

    library_path="$(build_library_path)"
    gmloader_lib_path="$(build_gmloader_lib_path)"
    begin_readable_game_log
    configure_audio_environment

    log_info "Launching game: $SELECTED_GAME_NAME"
    log_info "APK path: $SELECTED_APK"
    log_info "gmloader.json path: $GMLOADER_JSON"
    log_info "gmloader-next binary: $LOADER_BIN"
    log_info "Detailed log: $GAME_LOG"
    log_info "Environment HOME=$GAME_CACHE_DIR/home"
    log_info "Environment XDG_DATA_HOME=$GAME_CACHE_DIR/xdg/data"
    log_info "Environment XDG_CONFIG_HOME=$GAME_CACHE_DIR/xdg/config"
    log_info "Environment XDG_CACHE_HOME=$GAME_CACHE_DIR/xdg/cache"
    log_info "Environment XDG_RUNTIME_DIR=$APP_XDG_RUNTIME_DIR"
    log_info "Environment LD_LIBRARY_PATH=$library_path"
    log_info "Environment GMLOADER_LIB_PATH=$gmloader_lib_path"
    log_info "Environment GMLOADER_DUMP_SHADERS=$CFG_dump_shaders"
    log_info "Environment GMLOADER_TRACE_VM=$CFG_trace_vm"
    log_info "Environment TEXTINPUTINTERACTIVE=${TEXTINPUTINTERACTIVE:-Y}"
    log_display_environment "$library_path" "$gmloader_lib_path"

    {
        printf '\n[%s] Starting %s\n' "$(timestamp)" "$SELECTED_GAME_NAME"
        printf 'APK: %s\n' "$SELECTED_APK"
        printf 'Config: %s\n' "$GMLOADER_JSON"
        printf 'Loader: %s\n' "$LOADER_BIN"
        printf 'XDG_RUNTIME_DIR: %s\n' "$APP_XDG_RUNTIME_DIR"
        printf 'GMLOADER_LIB_PATH: %s\n' "$gmloader_lib_path"
        printf 'SDL_AUDIODRIVER: %s\n' "${SDL_AUDIODRIVER:-}"
        printf 'SDL_AUDIO_FREQUENCY: %s\n' "${SDL_AUDIO_FREQUENCY:-}"
        printf 'SLES_SDL_FREQ: %s\n' "${SLES_SDL_FREQ:-}"
    } >> "$GAME_LOG" 2>/dev/null || true

    start_gptokeyb || true
    probe_display_readiness

    if command -v pm_platform_helper >/dev/null 2>&1; then
        pm_platform_helper "$LOADER_BIN" >> "$GAME_LOG" 2>&1 || log_warn "pm_platform_helper returned a non-zero status."
    fi

    (
        export LD_LIBRARY_PATH="$library_path"
        if [ -n "$gmloader_lib_path" ]; then
            export GMLOADER_LIB_PATH="$gmloader_lib_path"
        else
            unset GMLOADER_LIB_PATH
        fi
        export HOME="$GAME_CACHE_DIR/home"
        export XDG_DATA_HOME="$GAME_CACHE_DIR/xdg/data"
        export XDG_CONFIG_HOME="$GAME_CACHE_DIR/xdg/config"
        export XDG_CACHE_HOME="$GAME_CACHE_DIR/xdg/cache"
        export XDG_RUNTIME_DIR="$APP_XDG_RUNTIME_DIR"
        export TEXTINPUTINTERACTIVE="${TEXTINPUTINTERACTIVE:-Y}"
        if [ "$CFG_dump_shaders" = "true" ]; then
            export GMLOADER_DUMP_SHADERS=1
        else
            unset GMLOADER_DUMP_SHADERS
        fi
        if [ "$CFG_trace_vm" = "true" ]; then
            export GMLOADER_TRACE_VM=1
        else
            unset GMLOADER_TRACE_VM
        fi
        export PILASRUNNER_PORT_DIR="$PORT_DIR"
        export PILASRUNNER_RUNTIME_DIR="$RUNTIME_DIR"
        export PILASRUNNER_GAME_CACHE="$GAME_CACHE_DIR"
        cd "$RUNTIME_DIR" || exit 111
        exec "$LOADER_BIN" -c "$GMLOADER_JSON"
    ) >> "$GAME_LOG" 2>&1 &

    game_pid="$!"
    log_info "Started gmloader-next process pid=$game_pid"
    start_hotkey_watcher "$game_pid" || true
    wait "$game_pid"
    status=$?
    check_hotkey_force_quit
    stop_hotkey_watcher
    stop_gptokeyb
    restart_portmaster_input_events
    if command -v pm_finish >/dev/null 2>&1; then
        pm_finish >> "$GAME_LOG" 2>&1 || log_warn "pm_finish returned a non-zero status."
    fi

    if [ "$HOTKEY_WAS_TRIGGERED" = "true" ]; then
        status=0
    fi

    log_info "gmloader-next exit code for '$SELECTED_GAME_NAME': $status"
    printf '[%s] Exit code: %s\n' "$(timestamp)" "$status" >> "$GAME_LOG" 2>/dev/null || true

    if [ "$HOTKEY_WAS_TRIGGERED" = "true" ]; then
        finish_readable_game_log "$status" "gmloader-next force quit"
        say "Game closed by Select + Start."
        return 0
    fi

    if [ "$status" -eq 0 ]; then
        finish_readable_game_log "$status" "gmloader-next"
        say "Game closed."
        return 0
    fi

    finish_readable_game_log "$status" "gmloader-next"
    say "The game exited with an error."
    say "See logs: $READABLE_LOG and $DETAILED_LOG"
    return "$status"
}

run_legacy_game() {
    local status=0
    local library_path=""
    local gmloader_lib_path=""
    local game_pid=""

    library_path="$(build_library_path)"
    gmloader_lib_path="$(build_gmloader_lib_path)"
    begin_readable_game_log
    configure_audio_environment

    log_info "Launching game with legacy gmloader: $SELECTED_GAME_NAME"
    log_info "APK path: $SELECTED_APK"
    log_info "Legacy gmloader binary: $LOADER_BIN"
    log_info "Detailed log: $GAME_LOG"
    log_info "Environment XDG_RUNTIME_DIR=$APP_XDG_RUNTIME_DIR"
    log_info "Environment GMLOADER_LIB_PATH=$gmloader_lib_path"
    log_display_environment "$library_path" "$gmloader_lib_path"

    {
        printf '\n[%s] Starting %s with legacy gmloader\n' "$(timestamp)" "$SELECTED_GAME_NAME"
        printf 'APK: %s\n' "$SELECTED_APK"
        printf 'Loader: %s\n' "$LOADER_BIN"
        printf 'XDG_RUNTIME_DIR: %s\n' "$APP_XDG_RUNTIME_DIR"
        printf 'GMLOADER_LIB_PATH: %s\n' "$gmloader_lib_path"
        printf 'SDL_AUDIODRIVER: %s\n' "${SDL_AUDIODRIVER:-}"
        printf 'SDL_AUDIO_FREQUENCY: %s\n' "${SDL_AUDIO_FREQUENCY:-}"
        printf 'SLES_SDL_FREQ: %s\n' "${SLES_SDL_FREQ:-}"
    } >> "$GAME_LOG" 2>/dev/null || true

    start_gptokeyb || true
    probe_display_readiness

    if command -v pm_platform_helper >/dev/null 2>&1; then
        pm_platform_helper "$LOADER_BIN" >> "$GAME_LOG" 2>&1 || log_warn "pm_platform_helper returned a non-zero status."
    fi

    (
        export LD_LIBRARY_PATH="$library_path"
        if [ -n "$gmloader_lib_path" ]; then
            export GMLOADER_LIB_PATH="$gmloader_lib_path"
        else
            unset GMLOADER_LIB_PATH
        fi
        export HOME="$GAME_CACHE_DIR/home"
        export XDG_DATA_HOME="$GAME_CACHE_DIR/xdg/data"
        export XDG_CONFIG_HOME="$GAME_CACHE_DIR/xdg/config"
        export XDG_CACHE_HOME="$GAME_CACHE_DIR/xdg/cache"
        export XDG_RUNTIME_DIR="$APP_XDG_RUNTIME_DIR"
        export TEXTINPUTINTERACTIVE="${TEXTINPUTINTERACTIVE:-Y}"
        export GMLOADER_SAVEDIR="$SAVE_DIR/"
        export GMLOADER_PLATFORM="$CFG_force_platform"
        [ "$CFG_disable_depth" = "true" ] && export GMLOADER_DEPTH_DISABLE=1
        export PILASRUNNER_PORT_DIR="$PORT_DIR"
        export PILASRUNNER_RUNTIME_DIR="$RUNTIME_DIR"
        export PILASRUNNER_GAME_CACHE="$GAME_CACHE_DIR"
        cd "$RUNTIME_DIR" || exit 111
        exec "$LOADER_BIN" "$SELECTED_APK"
    ) >> "$GAME_LOG" 2>&1 &

    game_pid="$!"
    log_info "Started legacy gmloader process pid=$game_pid"
    start_hotkey_watcher "$game_pid" || true
    wait "$game_pid"
    status=$?
    check_hotkey_force_quit
    stop_hotkey_watcher
    stop_gptokeyb
    restart_portmaster_input_events
    if command -v pm_finish >/dev/null 2>&1; then
        pm_finish >> "$GAME_LOG" 2>&1 || log_warn "pm_finish returned a non-zero status."
    fi

    if [ "$HOTKEY_WAS_TRIGGERED" = "true" ]; then
        status=0
    fi

    log_info "legacy gmloader exit code for '$SELECTED_GAME_NAME': $status"
    printf '[%s] Exit code: %s\n' "$(timestamp)" "$status" >> "$GAME_LOG" 2>/dev/null || true

    if [ "$HOTKEY_WAS_TRIGGERED" = "true" ]; then
        finish_readable_game_log "$status" "legacy gmloader force quit"
        say "Game closed by Select + Start."
        return 0
    fi

    if [ "$status" -eq 0 ]; then
        finish_readable_game_log "$status" "legacy gmloader"
        say "Game closed."
        return 0
    fi

    finish_readable_game_log "$status" "legacy gmloader"
    say "The game exited with an error."
    say "See logs: $READABLE_LOG and $DETAILED_LOG"
    return "$status"
}

main() {
    local menu_status=0

    init_base_dirs || {
        say "Could not initialize YoYo Pilas Runner folders."
        return 1
    }

    log_info "==== YoYo Pilas Runner startup ===="
    log_info "Runtime directory: $RUNTIME_DIR"
    log_info "Port directory: $PORT_DIR"
    readable_section "Startup"
    readable_log "YoYo Pilas Runner launcher started."
    readable_log "Readable log: $READABLE_LOG"
    readable_log "Detailed log: $DETAILED_LOG"

    ensure_default_files
    load_global_config
    apply_environment_overrides
    apply_configured_paths || {
        say "Could not prepare configured folders."
        say "See logs: $READABLE_LOG and $DETAILED_LOG"
        return 1
    }

    setup_portmaster_environment
    detect_arch

    select_loader_binary || return 1
    cleanup_stale_runtime_processes || true

    scan_games || {
        readable_section "Result"
        readable_log "Game scan failed. Open detailed.log for the scanner output."
        say "Could not scan games."
        say "See logs: $READABLE_LOG and $DETAILED_LOG"
        return 1
    }

    show_menu
    menu_status=$?
    if [ "$menu_status" -eq 2 ]; then
        readable_section "Result"
        readable_log "User exited before launching a game."
        return 0
    fi
    if [ "$menu_status" -ne 0 ]; then
        readable_section "Result"
        readable_log "Game menu failed with status $menu_status."
        return "$menu_status"
    fi

    validate_apk "$SELECTED_APK" || {
        readable_section "Result"
        readable_log "APK validation failed for $SELECTED_GAME_NAME."
        readable_log "APK: $SELECTED_APK"
        readable_log "Open detailed.log for the full validation output."
        say "See logs: $READABLE_LOG and $DETAILED_LOG"
        return 1
    }

    adjust_loader_binary_for_apk || {
        readable_section "Result"
        readable_log "Could not prepare a compatible gmloader binary for $SELECTED_GAME_NAME."
        say "Could not prepare gmloader-next."
        say "See logs: $READABLE_LOG and $DETAILED_LOG"
        return 1
    }

    prepare_game_cache || {
        readable_section "Result"
        readable_log "Could not prepare the game cache for $SELECTED_GAME_NAME."
        say "Could not prepare the game cache."
        say "See logs: $READABLE_LOG and $DETAILED_LOG"
        return 1
    }

    prepare_opensles_overlay || log_warn "OpenSL ES audio bridge preparation failed non-fatally; continuing with original game libraries."

    generate_gmloader_json || {
        readable_section "Result"
        readable_log "Could not generate gmloader.json for $SELECTED_GAME_NAME."
        say "Could not generate the game configuration."
        say "See logs: $READABLE_LOG and $DETAILED_LOG"
        return 1
    }

    process_controls
    if [ "$CFG_dry_run" = "true" ]; then
        finish_dry_run
        return $?
    fi

    if [ "$LOADER_MODE" = "legacy" ]; then
        run_legacy_game
    else
        run_game
    fi
}

main "$@"
exit $?
