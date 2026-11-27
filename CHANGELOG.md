# Changelog

## Unreleased

- Uninstall removes only manifest entries that are paths the install step creates; anything else in a damaged manifest is skipped with a warning.
- Uninstall removes `bin/aseprite` only while it still links into the app folder; a link or file you put there yourself is kept.
- `tests/lint.sh` uses shellcheck 0.10.0 (local if that version, else the pinned container), so local runs and CI give the same result. If the image cannot be pulled, it falls back to a local shellcheck of another version and says so.

## 1.0.0 (2026-11-26)

First public release.

- `install-aseprite.sh` builds the latest stable Aseprite (or `--ref <tag|branch>`) in a throwaway `ubuntu:24.04` container and installs it into `~/.local` with desktop entry, icons, MIME type and thumbnailer.
- Works on any x86_64 Linux with glibc 2.39 or newer; missing runtime libraries are reported with a distro-specific install hint, never installed.
- Updates, `--force`, `--uninstall` and `--uninstall --purge`; all working files stay in `.work/`.
- Test suites: `tests/lint.sh`, `tests/unit.sh`, `tests/e2e.sh` (with `--quick`) and `tests/portability.sh`.
