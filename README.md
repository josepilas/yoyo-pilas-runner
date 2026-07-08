# YoYo Pilas Runner

<img src="https://files.catbox.moe/3w8i1r.webp" width="600" height="400" alt="Imagem">

YoYo Pilas Runner is a unified PortMaster frontend inspired by the simple library experience of [YoYo Loader Vita](https://github.com/Rinnegatamante/yoyoloader_vita). Its goal is to let users run Android games made with GameMaker Studio by copying APK files into one folder and selecting them from a simple menu.

The execution layer is [gmloader-next](https://github.com/JohnnyonFlame/gmloader-next). This package now includes prebuilt `gmloadernext.aarch64` and `gmloadernext.armhf` binaries, the gmloader-next source tree under `pilasrunner/vendor/gmloader-next`, Android redistributable libraries, automatic `gmloader.json` generation, per-game saves/shaders/cache, logs, optional per-game controls, and basic PortMaster helper integration. A legacy `gmloader.armhf` fallback is also included for older 32-bit experiments, but gmloader-next is preferred whenever possible.

No commercial games, APKs, or proprietary GameMaker game content are included. Use only APKs for games you own or have the right to use.

## What Works Now

- Lists loose APKs in `pilasrunner/games`.
- Lists folder-format games with `pilasrunner/games/GameName/game.apk`.
- Prefers folder-format games when both `GameName.apk` and `GameName/game.apk` exist.
- Creates missing runtime folders automatically.
- Reads `pilasrunner/config/global.ini` safely.
- Bundles the canonical HTML/CSS/JavaScript UI inside `pilasrunner/ui`.
- Uses the bundled Alata Regular font as the default UI font.
- Shows a PortMaster-style boot terminal loading screen on `/dev/tty0`.
- Reads PortMaster `device_info.txt` and prefers `DEVICE_ARCH` when available.
- Detects `aarch64` and `armhf` systems with `uname -m`.
- Uses the bundled `pilasrunner/bin/gmloadernext.aarch64` binary.
- Uses the bundled `pilasrunner/bin/gmloadernext.armhf` binary for ARMv7/32-bit APKs.
- Keeps a bundled legacy `pilasrunner/bin/gmloader.armhf` fallback for older cases.
- Falls back to built vendor outputs if present.
- Generates per-game `gmloader.json` with absolute paths.
- Creates per-game `saves`, `shaders`, `home`, XDG data/config/cache folders, and a 0700 `XDG_RUNTIME_DIR`.
- Runs non-fatal X11/Wayland display readiness diagnostics when display variables are present.
- Invalidates generated per-game cache files when the launcher compatibility version changes, without deleting saves.
- Validates APK readability, size, ZIP structure, and `libyoyo.so` hints.
- Copies and parses optional `controls.ini`.
- Generates PortMaster-style `.gptk` and `gptokeyb2.ini` files.
- Supports deterministic QA runs with `dry_run=true` or `PILASRUNNER_DRY_RUN=1`.
- Supports automated selection with `PILASRUNNER_SELECT`.
- Auto-selects the only scanned game, or the first scanned game, when PortMaster launches without an interactive terminal.
- Auto-detects PortMaster `control.txt` and calls `get_controls` when available.
- Starts GptokeyB automatically when configured or auto-detected.
- Calls `pm_platform_helper` and `pm_finish` when PortMaster provides them.
- Writes `pilasrunner/logs/log.txt` as a readable run summary.
- Writes `pilasrunner/logs/detailed.log` with full launcher details and gmloader-next stdout/stderr.

## What It Still Does Not Do

- It does not download games.
- It does not download proprietary runtimes.
- It does not guarantee every GameMaker APK will work.
- It does not patch incompatible games automatically.
- It does not import ZIP, `data.win`, Windows executables, native Linux games, or non-APK formats.
- It does not emulate ARM Linux binaries on Windows; desktop validation can verify the launcher path, but real gameplay still needs an ARM PortMaster device.

Compatibility depends on the GameMaker version, bytecode/YYC usage, APK architecture, the target device, available libraries, and the gmloader-next build used.

## Project Tree

```text
YoYo Pilas Runner/
|-- YoYo Pilas Runner.sh
|-- demo/
|   |-- index.html
|-- README.md
`-- pilasrunner/
    |-- launcher.sh
    |-- port.json
    |-- gameinfo.xml
    |-- screenshot.png
    |-- cover.png
    |-- assets/
    |   |-- logo.png
    |   |-- loading_screen.txt
    |   `-- fonts/
    |       `-- Alata-Regular.ttf
    |-- bin/
    |   |-- gmloader.armhf
    |   |-- gmloadernext.aarch64
    |   `-- gmloadernext.armhf
    |-- cache/
    |-- config/
    |   `-- global.ini
    |-- defaults/
    |   |-- controls.example.ini
    |   |-- default_controls.ini
    |   `-- gmloader.template.json
    |-- games/
    |-- lib/
    |   |-- android/
    |   |   |-- arm64-v8a/
    |   |   |-- armeabi-v7a/
    |   |   `-- armeabi-v7a-r19/
    |   |-- armhf/
    |   `-- legacy-armhf/
    |-- logs/
    |-- scripts/
    |   |-- build_gmloader_next.sh
    |   |-- install_gmloader_next.sh
    |   `-- qa_smoke_test.sh
    |-- tmp/
    |-- ui/
    |   |-- index.html
    |   |-- styles.css
    |   `-- app.js
    `-- vendor/
        |-- README.md
        |-- UPSTREAMS.txt
        `-- gmloader-next/
```

`YoYo Pilas Runner.sh` is the PortMaster entry point. `pilasrunner/launcher.sh` contains the main logic.

## Branding

The project logo is bundled in:

```text
pilasrunner/assets/logo.png
```

The same logo is also used as the PortMaster-facing `cover.png` and `screenshot.png`.

The default UI font is bundled in:

```text
pilasrunner/assets/fonts/Alata-Regular.ttf
```

The boot terminal loading screen is bundled in:

```text
pilasrunner/assets/loading_screen.txt
```

## UI Demo

The canonical HTML/CSS/JavaScript UI is included inside the real runner package:

```text
pilasrunner/ui/index.html
```

The site demo opens that same UI instead of maintaining a separate copy:

```text
demo/index.html
```

This keeps the demo extremely faithful to the interface shipped with YoYo Pilas Runner. The UI uses the bundled app logo, the bundled Alata font, a Vita-inspired dark handheld layout, an interactive game list, architecture/runtime details, filters, and simulated launch/scan/config actions.

## gmloader-next Included As Source

The source is vendored at:

```text
pilasrunner/vendor/gmloader-next
```

Bundled upstream commit:

```text
c2fca354df73761887c15f44a0b28ec823581cd5
```

The source was cloned with submodules because upstream documents recursive cloning for builds. Its license is GPL-2.0; see:

```text
pilasrunner/vendor/gmloader-next/LICENSE.md
```

## Bundled Loader Binaries

This package includes:

```text
pilasrunner/bin/gmloadernext.aarch64
pilasrunner/bin/gmloadernext.armhf
pilasrunner/bin/gmloader.armhf
```

`gmloadernext.aarch64` source runtime:

```text
https://github.com/JeodC/RHH-Ports/raw/main/runtimes/gmloadernext.squashfs
```

Hashes from this packaging pass:

```text
gmloadernext.squashfs SHA256:
241E5C299C9DD7195D0857D036FDA0C924485084C5ED39A0BB60F3C95CDA3837

gmloadernext.aarch64 SHA256:
419B9C51BB75C6E10CDFB5F1ECD3767629AA8D9B664B4EC83B57160F4EC3A562
```

`gmloadernext.armhf` source:

```text
https://github.com/JeodC/RHH-Ports/blob/main/ports/released/gamemakerengine/digitaltamersreborn/digitaltamersreborn/gmloadernext.armhf
```

Hash from this packaging pass:

```text
gmloadernext.armhf SHA256:
789BE95F52F0CE7BD67E6FB3A7DA304BB7832B2764E8A15C9D3F4106FF80A984
```

The upstream gmloader-next GitHub Actions workflow is configured to build both arm64 and armhf, but the repository Actions artifact API returned zero downloadable artifacts during this packaging pass. The armhf binary above was therefore taken from a public released PortMaster/RHH GameMaker port and verified locally as an ELF 32-bit ARM EABI5 executable.

The legacy fallback is:

```text
gmloader.armhf SHA256:
311AC2CB1B39D730CAD5D7BA296845E5AE6C4B7DF9311C6D122F2346B00475A5
```

If you build from the vendored source, install build outputs with:

```bash
cd pilasrunner
./scripts/install_gmloader_next.sh all
```

You can also install only one architecture:

```bash
./scripts/install_gmloader_next.sh aarch64
./scripts/install_gmloader_next.sh armhf
```

## Building gmloader-next

This is normally done on a Linux build host with the required cross toolchains, not on a small handheld and not on this Windows workspace.

Build both architectures:

```bash
cd pilasrunner
INSTALL=1 ./scripts/build_gmloader_next.sh all
```

Build only aarch64:

```bash
INSTALL=1 ./scripts/build_gmloader_next.sh aarch64
```

Build only armhf:

```bash
INSTALL=1 ./scripts/build_gmloader_next.sh armhf
```

Useful environment variables:

```bash
JOBS=4
OPTM="-O2 -ggdb"
STATIC_LIBSTDCXX=1
LLVM_FILE=/usr/lib/llvm-11/lib/libclang-11.so.1
LLVM_INC=/usr/aarch64-linux-gnu/include/c++/10/aarch64-linux-gnu
LLVM_SYSROOT=/path/to/sysroot
USE_FMOD=0
USE_LUA=0
VIDEO_SUPPORT=0
```

The upstream build outputs are expected at:

```text
pilasrunner/vendor/gmloader-next/build/aarch64-linux-gnu/gmloader/gmloadernext.aarch64
pilasrunner/vendor/gmloader-next/build/arm-linux-gnueabihf/gmloader/gmloadernext.armhf
```

The launcher can use those vendor build outputs directly, but installing them into `pilasrunner/bin` is cleaner.

## Adding Games

Loose APK:

```text
pilasrunner/games/CelesteClassic.apk
```

Folder-format game:

```text
pilasrunner/games/CelesteClassic/game.apk
```

Folder format is preferred if both forms exist with the same base name because the folder can also contain `controls.ini`.

Unsupported files in `games` are ignored and logged.

## Menu

The menu is intentionally simple and terminal-friendly:

```text
==============================================
 YoYo Pilas Runner
 Inspired by YoYo Loader Vita, powered by gmloader-next
==============================================
Runtime: aarch64 | Games: 2

 1) CelesteClassic                  [apk]
 2) ExampleFolderGame               [folder]
0) Exit
```

This keeps the first version portable across typical PortMaster environments.

When PortMaster starts the port without an interactive stdin terminal, the launcher cannot show this text menu. In that case it automatically selects the only scanned game. If multiple games are present, it selects the first sorted game by default. Set `PILASRUNNER_SELECT` to choose a specific game, or set `PILASRUNNER_AUTORUN_FIRST=0` to make a non-interactive multi-game launch fail instead of autorunning the first entry.

## Generated Per-Game Cache

For each selected game:

```text
pilasrunner/cache/NORMALIZED_GAME_NAME/
|-- gmloader.json
|-- run.info
|-- cache.version
|-- saves/
|-- shaders/
|-- home/
|-- xdg/
|   |-- cache/
|   |-- config/
|   |-- data/
|   `-- runtime/
|-- controls.normalized.ini
|-- gptokeyb2.ini
`-- NORMALIZED_GAME_NAME.gptk
```

Generated `gmloader.json` includes:

```json
{
  "apk_path": "/absolute/path/to/game.apk",
  "save_dir": "/absolute/path/to/cache/Game/saves",
  "shader_dir": "/absolute/path/to/cache/Game/shaders",
  "show_cursor": false,
  "disable_controller": false,
  "disable_depth": false,
  "disable_extensions": false,
  "disable_joystick": false,
  "disable_rumble": false,
  "rumble_scale": 1.0,
  "force_platform": "os_android",
  "fullscreen": true
}
```

## Global Configuration

Edit:

```text
pilasrunner/config/global.ini
```

Available options:

```ini
show_cursor=false
disable_controller=false
disable_joystick=false
disable_rumble=false
disable_depth=false
disable_extensions=false
rumble_scale=1.0
force_platform=os_android
log_enabled=true
default_arch=auto
games_dir=games
cache_dir=cache
ui_path=ui/index.html
ui_font=assets/fonts/Alata-Regular.ttf
fullscreen=true
dump_shaders=false
trace_vm=false
display_probe=auto
display_wait_seconds=3
controls_backend=auto
gptokeyb_binary=
dry_run=false
```

`default_arch` may be `auto`, `aarch64`, or `armhf`.

`ui_path` and `ui_font` point to the canonical interface and bundled Alata font. Relative paths are resolved inside `pilasrunner`.

`display_probe` may be `auto`, `none`, `x11`, or `wayland`. The probe is diagnostic and non-fatal: if the display is not ready, the launcher logs the timeout and starts the game anyway.

`display_wait_seconds` controls how long the display probe waits. Values above `30` are clamped to `30`.

`controls_backend` may be:

- `auto`: use GptokeyB if it is available.
- `gptokeyb`: require GptokeyB if possible, warning if missing.
- `none`: never start GptokeyB.

`dry_run=true` validates game scanning, APK compatibility, loader selection, config generation, and controls generation without executing the ARM loader binary.

INI values are parsed as text and never executed as shell code.

## Desktop QA

For deterministic non-interactive tests:

```bash
PILASRUNNER_DRY_RUN=1 PILASRUNNER_SELECT=GameName bash "./YoYo Pilas Runner.sh"
```

`PILASRUNNER_SELECT` accepts either a 1-based menu number, the displayed game name, or the game's base folder/APK name. `PILASRUNNER_DEFAULT_ARCH=aarch64` or `PILASRUNNER_DEFAULT_ARCH=armhf` can be used to test architecture-specific loader selection without editing `global.ini`.

Dry run mode still validates the APK, writes `gmloader.json`, writes `run.info`, writes controls, prepares `XDG_RUNTIME_DIR`, runs non-fatal display diagnostics, and logs the exact app `LD_LIBRARY_PATH` and `GMLOADER_LIB_PATH` that would be used on a device.

Developer smoke test:

```bash
cd pilasrunner
./scripts/qa_smoke_test.sh
```

The smoke test creates temporary APK-shaped ZIP files, verifies aarch64 selection, verifies armhf selection, verifies folder-format preference over a duplicate loose APK, verifies per-game controls, and removes its temporary artifacts when it finishes.

## Controls

Default controls:

```text
pilasrunner/defaults/default_controls.ini
```

Example:

```text
pilasrunner/defaults/controls.example.ini
```

Folder-format per-game controls:

```text
pilasrunner/games/GameName/controls.ini
```

Loose APK per-game controls:

```text
pilasrunner/games/GameName.controls.ini
pilasrunner/games/GameName/controls.ini
```

Supported keys:

```text
dpad_up dpad_down dpad_left dpad_right
a b x y
l1 r1 l2 r2
start select
left_stick_click right_stick_click
```

Supported values:

```text
W A S D Z X C V Q E ENTER ESC SPACE SHIFT CTRL ALT TAB UP DOWN LEFT RIGHT
```

The launcher validates the file, logs unknown entries, writes `controls.normalized.ini`, writes a classic `.gptk`, and writes `gptokeyb2.ini`.

## PortMaster Integration

When running inside a PortMaster environment, the launcher looks for:

```text
/opt/system/Tools/PortMaster/control.txt
/opt/tools/PortMaster/control.txt
$XDG_DATA_HOME/PortMaster/control.txt
/roms/ports/PortMaster/control.txt
```

If found, it sources `control.txt`, sources `device_info.txt` when present, loads firmware-specific mod files when present, calls `get_controls`, exports `SDL_GAMECONTROLLERCONFIG`, uses `$GPTOKEYB` or `$GPTOKEYB2` when available, and calls `pm_platform_helper` plus `pm_finish`.

The top-level PortMaster entry point also follows the ClassiCube-style boot terminal pattern: it clears `/dev/tty0`, writes `pilasrunner/assets/loading_screen.txt`, and clears the terminal again when the launcher exits. This boot screen is shown before the runtime folder and launcher are validated, so it can still appear even if the main runner cannot start. It uses PortMaster `$ESUDO` when that helper is available.

When `device_info.txt` provides `DEVICE_ARCH`, that value is preferred over `uname -m` for loader selection. This matches current PortMaster ports that use device metadata instead of relying only on the kernel architecture string.

After a run that starts GptokeyB, the launcher requests an `oga_events` restart when `systemctl` is available, matching the input cleanup pattern used by several PortMaster ports.

The launcher does not force Westonpack for GameMaker/gmloader-next games. The PortMaster 0.8.10 Ren'Py report showed that Weston/Xwayland readiness was decisive for an X11 Ren'Py runtime, but gmloader-next is a different execution path. The reusable parts applied here are environment isolation, explicit `XDG_RUNTIME_DIR`, display readiness logging, and non-fatal launch diagnostics.

If PortMaster helpers are not present, the launcher still works as a standalone Bash runner.

## Logs

Readable run summary:

```text
pilasrunner/logs/log.txt
```

Detailed launcher/runtime log:

```text
pilasrunner/logs/detailed.log
```

`log.txt` is intended to be easy to read after a game closes, exits unexpectedly, or crashes. `detailed.log` includes architecture detection, selected binary, APK validation, generated config paths, `DISPLAY`, `WAYLAND_DISPLAY`, `SDL_VIDEODRIVER`, `XDG_RUNTIME_DIR`, app `LD_LIBRARY_PATH`, gmloader-next `GMLOADER_LIB_PATH`, control mapping, gmloader-next stdout/stderr, helper output, and exit code.

## PortMaster Metadata

The package includes:

```text
pilasrunner/port.json
pilasrunner/gameinfo.xml
pilasrunner/screenshot.png
pilasrunner/cover.png
```

This is experimental metadata for PortMaster-style packaging. The port is not marked ready-to-run because users must provide legal APKs.

## References

- [YoYo Loader Vita](https://github.com/Rinnegatamante/yoyoloader_vita)
- [gmloader-next](https://github.com/JohnnyonFlame/gmloader-next)
- [droidports](https://github.com/JohnnyonFlame/droidports)
- [Doronimmo/GameMakerPorts](https://github.com/Doronimmo/GameMakerPorts)
- [Fraxinus88/GMloader-ports](https://github.com/Fraxinus88/GMloader-ports)
- [RHH-Ports runtimes and GameMaker ports](https://github.com/JeodC/RHH-Ports)
- [PortMaster ClassiCube package](https://github.com/PortsMaster/PortMaster-New/tree/main/ports/classicube)
- [PortMaster GameMaker Studio documentation](https://github.com/JanTrueno/PortMaster-Wiki/blob/master/docs/contribute/porting/engines/gamemaker-studio.md)
- [PortMaster packaging documentation](https://portmaster.games/packaging.html)
