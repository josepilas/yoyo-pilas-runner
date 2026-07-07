#!/bin/bash

# Install gmloader-next binaries produced by the vendored source tree into
# pilasrunner/bin and refresh the Android runtime redistributable libraries.

set -u

SCRIPT_SOURCE="${BASH_SOURCE[0]}"
SCRIPT_DIR="$(cd -P "$(dirname "$SCRIPT_SOURCE")" >/dev/null 2>&1 && pwd)"
RUNTIME_DIR="$(cd -P "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd)"
GMLOADER_DIR="$RUNTIME_DIR/vendor/gmloader-next"
BIN_DIR="$RUNTIME_DIR/bin"
LIB_DIR="$RUNTIME_DIR/lib"

TARGET="${1:-all}"

say() {
    printf '%s\n' "$*"
}

fail() {
    say "Error: $*"
    exit 1
}

usage() {
    cat <<'EOF'
Usage:
  install_gmloader_next.sh [aarch64|armhf|all]

This copies built vendor binaries into:
  pilasrunner/bin/gmloadernext.aarch64
  pilasrunner/bin/gmloadernext.armhf

It also refreshes Android redistributable libraries from:
  pilasrunner/vendor/gmloader-next/lib

into:
  pilasrunner/lib/android
EOF
}

copy_binary() {
    local label="$1"
    local src="$2"
    local dst="$3"

    if [ ! -f "$src" ]; then
        say "Skipping $label: built binary was not found at $src"
        return 0
    fi

    mkdir -p "$BIN_DIR" || return 1
    cp "$src" "$dst" || return 1
    chmod +x "$dst" 2>/dev/null || true
    say "Installed $label: $dst"
}

install_libs() {
    local src="$GMLOADER_DIR/lib"
    local dst="$LIB_DIR/android"

    if [ ! -d "$src" ]; then
        say "Skipping Android redistributable libraries: source folder not found at $src"
        return 0
    fi

    mkdir -p "$dst" || return 1
    cp -R "$src/." "$dst/" || return 1
    say "Installed Android redistributable libraries: $dst"
}

main() {
    case "$TARGET" in
        -h|--help|help)
            usage
            return 0
            ;;
        aarch64|arm64)
            TARGET="aarch64"
            ;;
        armhf|armv7|armv7l)
            TARGET="armhf"
            ;;
        all)
            ;;
        *)
            usage
            fail "Unknown target: $TARGET"
            ;;
    esac

    [ -d "$GMLOADER_DIR" ] || fail "gmloader-next source was not found: $GMLOADER_DIR"

    case "$TARGET" in
        aarch64)
            copy_binary "aarch64 gmloader-next" \
                "$GMLOADER_DIR/build/aarch64-linux-gnu/gmloader/gmloadernext.aarch64" \
                "$BIN_DIR/gmloadernext.aarch64" || fail "Could not install aarch64 binary."
            ;;
        armhf)
            copy_binary "armhf gmloader-next" \
                "$GMLOADER_DIR/build/arm-linux-gnueabihf/gmloader/gmloadernext.armhf" \
                "$BIN_DIR/gmloadernext.armhf" || fail "Could not install armhf binary."
            ;;
        all)
            copy_binary "aarch64 gmloader-next" \
                "$GMLOADER_DIR/build/aarch64-linux-gnu/gmloader/gmloadernext.aarch64" \
                "$BIN_DIR/gmloadernext.aarch64" || fail "Could not install aarch64 binary."
            copy_binary "armhf gmloader-next" \
                "$GMLOADER_DIR/build/arm-linux-gnueabihf/gmloader/gmloadernext.armhf" \
                "$BIN_DIR/gmloadernext.armhf" || fail "Could not install armhf binary."
            ;;
    esac

    install_libs || fail "Could not install Android redistributable libraries."
}

main "$@"
