# YoYo Pilas Runner

YoYo Pilas Runner is a PortMaster frontend inspired by YoYo Loader Vita. Copy Android GameMaker Studio APKs into `pilasrunner/games`, launch `YoYo Pilas Runner.sh`, choose a game, and the launcher generates the needed gmloader-next configuration automatically.

This package includes prebuilt `gmloadernext.aarch64` and `gmloadernext.armhf` binaries. The aarch64 binary was extracted from the public `gmloadernext.squashfs` runtime used by recent PortMaster GameMaker ports; the armhf binary was taken from a public released PortMaster/RHH GameMaker port and verified locally as an ELF 32-bit ARM EABI5 executable. A legacy `gmloader.armhf` fallback is also present for older 32-bit experiments.

The canonical UI lives in `pilasrunner/ui/index.html` and uses `pilasrunner/assets/fonts/Alata-Regular.ttf` as its default font. The site demo opens that same UI so the preview and packaged interface stay identical.

The PortMaster entry screen uses `pilasrunner/assets/loading_screen.txt` and writes it to `/dev/tty0` before the launcher starts, matching the boot terminal pattern used by the official ClassiCube PortMaster package.

The launcher also applies the reusable PortMaster 0.8.10 runtime-handoff lessons that fit gmloader-next: a per-game 0700 `XDG_RUNTIME_DIR`, scoped app library paths, non-fatal X11/Wayland display diagnostics, and generated-cache versioning that leaves saves intact.

Runtime logs are written to `pilasrunner/logs/log.txt` for the readable summary and `pilasrunner/logs/detailed.log` for the full technical trace.

For launcher QA without executing ARM binaries:

```bash
PILASRUNNER_DRY_RUN=1 PILASRUNNER_SELECT=GameName bash "../YoYo Pilas Runner.sh"
./scripts/qa_smoke_test.sh
```

Use only APKs for games you own or have the right to use.
