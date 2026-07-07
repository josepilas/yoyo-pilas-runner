#!/bin/bash

# Build the vendored gmloader-next source and optionally install the result.
# This is a developer/build-host script. Typical handheld PortMaster devices may
# not include the compiler toolchain needed to run it directly.

set -u
set -o pipefail 2>/dev/null || true

SCRIPT_SOURCE="${BASH_SOURCE[0]}"
SCRIPT_DIR="$(cd -P "$(dirname "$SCRIPT_SOURCE")" >/dev/null 2>&1 && pwd)"
RUNTIME_DIR="$(cd -P "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd)"
GMLOADER_DIR="$RUNTIME_DIR/vendor/gmloader-next"
INSTALL_SCRIPT="$SCRIPT_DIR/install_gmloader_next.sh"

TARGET="${1:-all}"
JOBS="${JOBS:-}"
OPTM="${OPTM:-}"
STATIC_LIBSTDCXX="${STATIC_LIBSTDCXX:-0}"
USE_FMOD="${USE_FMOD:-0}"
USE_LUA="${USE_LUA:-0}"
VIDEO_SUPPORT="${VIDEO_SUPPORT:-0}"

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
  build_gmloader_next.sh [aarch64|armhf|all]

Environment:
  JOBS=4                  Parallel make jobs. Defaults to nproc when available.
  INSTALL=1               Copy successful build outputs into pilasrunner/bin.
  OPTM="-O2 -ggdb"        Extra optimization/debug flags passed to gmloader-next.
  STATIC_LIBSTDCXX=1      Link libstdc++ statically when supported by toolchain.
  USE_FMOD=1              Enable FMOD extension support if FMOD SDK is installed.
  USE_LUA=1               Enable Lua extension support.
  VIDEO_SUPPORT=1         Enable SDL_kitchensink/ffmpeg video support.

Cross toolchain examples:
  ARCH=aarch64-linux-gnu requires aarch64-linux-gnu-gcc/g++.
  ARCH=arm-linux-gnueabihf requires arm-linux-gnueabihf-gcc/g++.

LLVM helpers may be needed by gmloader-next:
  LLVM_FILE=/usr/lib/llvm-11/lib/libclang-11.so.1
  LLVM_INC=/usr/aarch64-linux-gnu/include/c++/10/aarch64-linux-gnu
  LLVM_SYSROOT=/path/to/sysroot
EOF
}

detect_jobs() {
    if [ -n "$JOBS" ]; then
        printf '%s' "$JOBS"
    elif command -v nproc >/dev/null 2>&1; then
        nproc
    else
        printf '%s' 1
    fi
}

check_source() {
    [ -d "$GMLOADER_DIR" ] || fail "gmloader-next source was not found: $GMLOADER_DIR"
    [ -f "$GMLOADER_DIR/Makefile.gmloader" ] || fail "Makefile.gmloader was not found in: $GMLOADER_DIR"
    [ -d "$GMLOADER_DIR/3rdparty/json/include" ] || say "Warning: nlohmann/json submodule include folder was not found."
    [ -d "$GMLOADER_DIR/3rdparty/libzip/lib" ] || say "Warning: libzip submodule folder was not found."
}

build_one() {
    local label="$1"
    local arch="$2"
    local jobs=""
    local make_args=()

    jobs="$(detect_jobs)"
    say "Building gmloader-next for $label ($arch) with -j$jobs"

    make_args=(
        -f Makefile.gmloader
        "ARCH=$arch"
        "STATIC_LIBSTDCXX=$STATIC_LIBSTDCXX"
        "USE_FMOD=$USE_FMOD"
        "USE_LUA=$USE_LUA"
        "VIDEO_SUPPORT=$VIDEO_SUPPORT"
    )

    [ -z "$OPTM" ] || make_args+=("OPTM=$OPTM")
    [ -z "${LLVM_FILE:-}" ] || make_args+=("LLVM_FILE=${LLVM_FILE:-}")
    [ -z "${LLVM_INC:-}" ] || make_args+=("LLVM_INC=${LLVM_INC:-}")
    [ -z "${LLVM_SYSROOT:-}" ] || make_args+=("LLVM_SYSROOT=${LLVM_SYSROOT:-}")

    (
        cd "$GMLOADER_DIR" || exit 1
        make "${make_args[@]}" -j"$jobs"
    ) || return 1

    return 0
}

install_outputs() {
    if [ "${INSTALL:-0}" = "1" ]; then
        [ -x "$INSTALL_SCRIPT" ] || chmod +x "$INSTALL_SCRIPT" 2>/dev/null || true
        "$INSTALL_SCRIPT" "$TARGET"
    fi
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

    check_source

    case "$TARGET" in
        aarch64)
            build_one "aarch64" "aarch64-linux-gnu" || fail "aarch64 build failed."
            ;;
        armhf)
            build_one "armhf" "arm-linux-gnueabihf" || fail "armhf build failed."
            ;;
        all)
            build_one "aarch64" "aarch64-linux-gnu" || fail "aarch64 build failed."
            build_one "armhf" "arm-linux-gnueabihf" || fail "armhf build failed."
            ;;
    esac

    install_outputs
    say "gmloader-next build finished."
}

main "$@"
