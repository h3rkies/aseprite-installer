# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project state

`README.md` documents the behaviour users rely on: options, steps, paths, exit codes, the runtime library table and "Implementation notes". The tests pin that behaviour, so change a test first and then the code (TDD). When the README says nothing, pick the simpler, safer option and add it to "Implementation notes". Log user-visible changes in `CHANGELOG.md`.

The files are `install-aseprite.sh` (one self-contained Bash 4+ file), `README.md`, and `tests/` (`unit.sh`, `e2e.sh`, `portability.sh`, `lint.sh`, plus fake `docker` and `sudo` in `tests/fakes/`). A local `internal/` folder, if present, holds private notes: it is git-ignored, never commit it.

## Constraints

- The host must stay clean. The build runs in a Docker container (`ubuntu:24.04`). The script never calls `sudo`, never installs host packages, and never runs `rpm`/`dnf`/`apt`/`pacman`/`zypper` on the host.
- Every working file lives in `.work/` in this repo; tests use `.test/`. Both are git-ignored. Nothing goes in `~/.cache`, `~/deps` or `/tmp`. Only the installed app lands in `~/.local`.
- The host can be any x86_64 Linux with glibc 2.39 or newer. No step may depend on the distro. `/etc/os-release` only picks the package-name hint for missing runtime libraries.
- Aseprite's EULA forbids redistributing builds: never add CI that publishes binaries or artifacts.

## Commands

```bash
tests/lint.sh                               # shellcheck (container if not installed) + bash -n on every script
tests/unit.sh                               # offline, no Docker; sources the script
tests/e2e.sh                                # real builds into .test/, including full builds
tests/e2e.sh --quick                        # skips the downgrade/update builds
tests/unit.sh <name>... ; tests/e2e.sh --list   # run a subset / list tests
tests/portability.sh                        # runtime checks in throwaway distro containers
./install-aseprite.sh --dry-run             # print the planned steps, change nothing
./install-aseprite.sh --yes                 # unattended real install into ~/.local
```

The script runs `main "$@"` only when executed, so the tests (and the build container) can source it and call single functions. There are two test-only hooks, `ASEPRITE_TEST_BREAK_SKIA=1` and `ASEPRITE_TEST_FAKE_MISSING_LIB=<soname>`. Neither may have any effect when unset.

## Architecture of `install-aseprite.sh`

- Nine steps, each printing `==> [n/9]`: preflight, resolve, builder image, source, Skia, build, build check, install, finish. Steps 4–7 (source to build check) run inside the build container through `container_build`. The host copies the script into `.work/tmp/`, mounts only `.work/` at `/work`, and sources the script there. Everything else runs on the host.
- The builder image is made with `docker run` plus `docker commit`, never `docker build`, so no build cache is left behind. It and any base image the script pulled (marked by `.work/pulled-base`) are removed on exit unless `--keep-image` is given. Never prune, and never touch other images or containers.
- Version facts are read from the checked-out source, never hard-coded: the latest stable tag, the Skia tag, the minimum CMake version, icons, and the desktop, MIME and thumbnailer files. The pinned values are the repo URL, the container package list, the Skia `m124-08a5439a6b` SHA-256, the base image, the minimum glibc and the runtime library table.
- Compiler cache: ccache in `.work/ccache` (3 GB cap), set up by `ccache_env`; `--purge` removes it.
- Reuse: `src/` is reused when HEAD matches the commit and the tree is clean. `build/` is reused when `.aseprite-installer-stamp` equals `<commit> <skia-tag>`. Skia is kept per tag in `.work/skia/`.
- Atomic replace: new folders are built as `*.partial` or `.new` and renamed into place. The traps clean up only this run's partial folders and containers, never the existing install.
- Records live inside the app folder: `$PREFIX/opt/aseprite/.aseprite-installer/state` decides "up to date" by commit, and `manifest` is what uninstall removes.
- The runtime libraries are checked twice: with `ldconfig -p` in preflight (exit 4) and with `ldd` on the real binary before the swap (exit 8).
- Exit codes 0–8 and 130 are fixed per failure class (README "Exit codes"), and the tests assert them.
