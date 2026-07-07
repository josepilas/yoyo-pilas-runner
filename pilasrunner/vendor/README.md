# Vendored Runtime Source

This folder contains the source tree used by YoYo Pilas Runner to build or inspect `gmloader-next`.

Current bundled source:

- Project: `gmloader-next`
- Upstream: <https://github.com/JohnnyonFlame/gmloader-next>
- License: GPL-2.0, see `gmloader-next/LICENSE.md`
- Bundled commit: `c2fca354df73761887c15f44a0b28ec823581cd5`

The source was cloned with submodules because upstream documents recursive cloning as required for builds.

Bundled runtime binaries:

- Runtime source: <https://github.com/JeodC/RHH-Ports/raw/main/runtimes/gmloadernext.squashfs>
- Extracted binary: `../bin/gmloadernext.aarch64`
- Runtime SHA256: `241E5C299C9DD7195D0857D036FDA0C924485084C5ED39A0BB60F3C95CDA3837`
- Extracted binary SHA256: `419B9C51BB75C6E10CDFB5F1ECD3767629AA8D9B664B4EC83B57160F4EC3A562`
- ARMv7 binary source: <https://github.com/JeodC/RHH-Ports/blob/main/ports/released/gamemakerengine/digitaltamersreborn/digitaltamersreborn/gmloadernext.armhf>
- ARMv7 binary: `../bin/gmloadernext.armhf`
- ARMv7 binary SHA256: `789BE95F52F0CE7BD67E6FB3A7DA304BB7832B2764E8A15C9D3F4106FF80A984`

Build helper:

```bash
pilasrunner/scripts/build_gmloader_next.sh all
```

Install helper:

```bash
pilasrunner/scripts/install_gmloader_next.sh all
```

YoYo Pilas Runner does not include commercial games or proprietary GameMaker game runtimes. Android APKs must be supplied by the user and must be games they own or have the right to use.
