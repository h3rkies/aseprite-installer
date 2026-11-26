# Changelog

## 1.0.0 (2026-11-26)

First public release.

- `install-aseprite.sh` builds the latest stable Aseprite (or `--ref <tag|branch>`) in a throwaway `ubuntu:24.04` container and installs it into `~/.local` with desktop entry, icons, MIME type and thumbnailer.
- Works on any x86_64 Linux with glibc 2.39 or newer; missing runtime libraries are reported with a distro-specific install hint, never installed.
- Updates, `--force`, `--uninstall` and `--uninstall --purge`; all working files stay in `.work/`.
- Test suites: `tests/lint.sh`, `tests/unit.sh`, `tests/e2e.sh` (with `--quick`) and `tests/portability.sh`.
