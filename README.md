# Aseprite build-and-install script for Linux

[![tests](https://github.com/h3rkies/aseprite-installer/actions/workflows/tests.yml/badge.svg)](https://github.com/h3rkies/aseprite-installer/actions/workflows/tests.yml)

`install-aseprite.sh` builds [Aseprite](https://github.com/aseprite/aseprite) from source inside a Docker container and installs it for the current user, so it starts from the app menu. Run it again later to update to the newest stable release.

The host stays clean. The script installs no packages on the host and never calls `sudo`. Compilers and `-dev` packages live only in a throwaway `ubuntu:24.04` builder image. Every working file (source, build, Skia, downloads, logs, temporary files) stays in `.work/` next to the script. When the run ends, the builder image is removed. The host keeps only the installed app.

This is an unofficial project, not affiliated with or endorsed by Igara Studio, the makers of Aseprite. "Aseprite" is their trademark; it is used here only to say what the script builds.

> **Licence.** Aseprite's EULA allows you to build it from source for your own personal use, but not to share or redistribute the binary you built. This script builds for you only; do not pass the result on.

## Quick start

You need Docker (rootful or rootless) and `git`, on x86_64 Linux with glibc 2.39 or newer.

```bash
git clone https://github.com/h3rkies/aseprite-installer.git
cd aseprite-installer
./install-aseprite.sh --dry-run   # show what it would do
./install-aseprite.sh             # build and install into ~/.local
```

Run it again later to update. `./install-aseprite.sh --uninstall` removes it.

## Supported hosts

- Any **x86_64** Linux with **glibc 2.39 or newer**, whatever the distro: for example Fedora 40+, Ubuntu 24.04+, Debian 13+, RHEL 10, Arch, openSUSE Tumbleweed. No step depends on the distro. `/etc/os-release` is read only to suggest the install command for a missing library, and for the log.
- Not supported (the script stops with a clear error, exit 1): musl systems such as Alpine, glibc older than 2.39, and other CPUs (there is no prebuilt Skia for them).
- libstdc++ and libgcc from GCC 13 or newer (any distro that has glibc 2.39 has them).

## Host requirements

The script checks all of these and stops (exit 4) naming what is missing. It never installs or starts any of them.

- **Docker**: installed, daemon running, and your user allowed to use it (rootful with the `docker` group, or rootless Docker).
- **git**: used only for `git ls-remote`, which reads the tag list and writes nothing.
- Standard tools that every glibc distro ships: Bash 4+, coreutils, `flock` (util-linux), `getconf` and `ldd` (glibc).
- Free disk space: 4 GiB under the work folder, 500 MiB under the install prefix, 3 GiB under Docker's root folder.
- The runtime libraries below.

### Runtime libraries

The binary is built in the container but runs on the host, so it loads these libraries from the host. Most desktops already have them. If one is missing, the script names it before the build (exit 4) and prints the install command for your distro family, for you to run.

| Library | Fedora / RHEL (`dnf`) | Debian / Ubuntu (`apt`) | Arch (`pacman`) | openSUSE (`zypper`) |
| --- | --- | --- | --- | --- |
| `libstdc++.so.6` | `libstdc++` | `libstdc++6` | `libstdc++` | `libstdc++6` |
| `libgcc_s.so.1` | `libgcc` | `libgcc-s1` | `libgcc` | `libgcc_s1` |
| `libX11.so.6` | `libX11` | `libx11-6` | `libx11` | `libX11-6` |
| `libxcb.so.1` | `libxcb` | `libxcb1` | `libxcb` | `libxcb1` |
| `libXext.so.6` | `libXext` | `libxext6` | `libxext` | `libXext6` |
| `libXcursor.so.1` | `libXcursor` | `libxcursor1` | `libxcursor` | `libXcursor1` |
| `libXi.so.6` | `libXi` | `libxi6` | `libxi` | `libXi6` |
| `libXrandr.so.2` | `libXrandr` | `libxrandr2` | `libxrandr` | `libXrandr2` |
| `libGL.so.1` | `libglvnd-glx` | `libgl1` | `libglvnd` | `libglvnd` |
| `libfontconfig.so.1` | `fontconfig` | `libfontconfig1` | `fontconfig` | `libfontconfig1` |

Step 7 records what the built binary links against in `.work/build/runtime-deps.txt` and warns about anything not in this table (glibc's own libraries excepted). `libXi.so.6` is listed even though it is not linked: Aseprite loads it with `dlopen` for pen and tablet input. Other libraries that `ldd` shows (`libXrender`, `libfreetype`, `libharfbuzz` and so on) are dependencies of these and come with their packages. The Arch and openSUSE names were checked in real containers (see "Implementation notes").

Aseprite draws through X11. On a Wayland desktop it runs through XWayland, which every major desktop provides.

## Usage

```
./install-aseprite.sh [options]
```

With no options it installs the latest stable release, or updates to it. If that release is already installed, it says so and stops within seconds.

| Option | Effect |
| --- | --- |
| `--ref <ref>` | Build this tag or branch instead of the latest stable tag (e.g. `v1.3.17`, `main`). `--ref=<ref>` works too. |
| `--force` | Rebuild and reinstall even if the installed version already matches. |
| `--yes`, `-y` | Answer yes to every prompt (today only the uninstall prompt). Needed for unattended runs. |
| `--keep-build` | Keep the source and build folders after a successful install, so the next build only recompiles what changed. |
| `--keep-image` | Keep the builder image after the run, so the next build skips making it (a few minutes). `--uninstall --purge` removes it. |
| `--jobs <n>`, `-j <n>` | Parallel build jobs, passed to `ninja -j`. Default: `nproc`. Must be a positive whole number. `--jobs=<n>` works too. |
| `--uninstall` | Remove the installed app and its desktop files. The work folder is kept. |
| `--purge` | With `--uninstall`, also delete the work folder and the builder image. |
| `--dry-run` | Print each step and command it would run, change nothing, exit 0. |
| `--verbose`, `-v` | Also stream the build output to the terminal (it always goes to the log). |
| `--help`, `-h` | Print usage and exit 0. |
| `--version` | Print the script's own version and exit 0. |

Bad usage (an unknown option, a missing or non-numeric value, `--purge` without `--uninstall`) prints the usage and exits 2.

Examples:

```bash
./install-aseprite.sh --yes                  # install or update to the latest stable release
./install-aseprite.sh --ref v1.3.17 --yes    # install a specific release (replaces the current one)
./install-aseprite.sh --keep-image --keep-build   # faster next build, at the cost of disk space
./install-aseprite.sh --dry-run              # see what would happen
./install-aseprite.sh --uninstall            # remove the app (asks first)
./install-aseprite.sh --uninstall --purge --yes   # remove the app, the work folder and the image
```

## Paths and overrides

Every path can be overridden with the variable shown. Overrides must be absolute paths; otherwise the script exits 2. They exist so the tests can work in `.test/` inside the repo.

| Variable | Default | Holds |
| --- | --- | --- |
| `ASEPRITE_WORK_DIR` | `.work` next to the script (found from the script's own location, not the current folder) | `src/` (the clone), `build/`, `skia/`, `downloads/`, `logs/`, `tmp/`, `ccache/` (compiler cache, up to 3 GB), `lock`, `pulled-base` |
| (derived) | `$WORK/skia/skia-<skia-tag>/` | Skia, one folder per tag |
| `ASEPRITE_PREFIX` | `$HOME/.local` | Root for everything installed below |
| (derived) | `$PREFIX/opt/aseprite/` | The installed app (`aseprite`, `data/`, `icudtl.dat`) |
| (derived) | `$PREFIX/opt/aseprite/.aseprite-installer/` | The script's records: `state` and `manifest` |
| (derived) | `$PREFIX/bin/aseprite` | Symlink to `$PREFIX/opt/aseprite/aseprite` |
| (derived) | `$PREFIX/bin/aseprite-thumbnailer` | Thumbnailer script |
| (derived) | `$PREFIX/share/applications/aseprite.desktop` | Menu entry |
| (derived) | `$PREFIX/share/icons/hicolor/<N>x<N>/apps/aseprite.png` | Icons (9 sizes) |
| (derived) | `$PREFIX/share/mime/packages/aseprite.xml` | MIME type for `*.ase` and `*.aseprite` |
| (derived) | `$PREFIX/share/thumbnailers/aseprite.thumbnailer` | Thumbnailer entry for file managers that read `share/thumbnailers` (e.g. GNOME Files) |

The desktop entry and thumbnailer use absolute paths, so the menu works even if `~/.local/bin` is not in your `PATH`. If it is not, the script tells you how to add it.

## What is left on the host, and when

- **After a successful run:** the installed app and desktop files listed above, plus `.work/logs/` (the 5 newest log files) and `.work/skia/skia-<current-tag>/` (kept so the next update does not download Skia again), and `.work/ccache/` (the compiler cache, up to 3 GB, kept so rebuilds are fast). With `--keep-build`, also `.work/src/` and `.work/build/`.
- **In Docker's storage** (`docker info` → `DockerRootDir`, normally `/var/lib/docker`, or `~/.local/share/docker` with rootless Docker): the script creates only `aseprite-installer-builder:ubuntu-24.04`, the `ubuntu:24.04` base image (only if it was not already there; `.work/pulled-base` marks it) and its own containers (`aseprite-installer-setup-<pid>`, `aseprite-installer-build-<pid>`). It removes all of them when the run ends, on success or failure, unless you pass `--keep-image`. It never uses `docker build`, so there is no build cache, and it never prunes or touches other images or containers.
- **Desktop caches:** the cache refresh regenerates the per-user desktop, MIME and icon caches under `$PREFIX/share` (shared with other apps). Uninstall refreshes them again.
- **Never touched:** `~/.config/aseprite/` (your Aseprite settings), `~/.cache`, `/tmp`, and anything outside the paths above.

## Updating and uninstalling

- **Update:** run `./install-aseprite.sh --yes` again. It checks the latest stable tag; if the installed commit already matches, it stops at once ("already installed and up to date"). Otherwise it builds the new release and swaps it in. Only one version is kept.
- **Install an older or newer ref:** `./install-aseprite.sh --ref v1.3.17 --yes`. A later plain run goes back to the latest stable tag.
- **Uninstall:** `./install-aseprite.sh --uninstall` lists what it will remove and asks. Add `--yes` to skip the question (needed when there is no terminal). It removes exactly the paths in `$PREFIX/opt/aseprite/.aseprite-installer/manifest`. `~/.config/aseprite/` is kept; delete it by hand if you want.
- **Remove everything:** `./install-aseprite.sh --uninstall --purge --yes` also deletes the work folder and the builder image.

## Logs

Every run writes `.work/logs/run-<YYYYmmdd-HHMMSS>.log`: each command run (as `+ cmd`), its output, and a timestamp per step, including the builder image setup. The compiler output goes to `.work/logs/build-<YYYYmmdd-HHMMSS>.log`, and the run log names it. The 5 newest log files are kept. When a run fails, the last line on stderr names the step and the log, for example:

```
error: stopped at step [6/9] Building Aseprite (ninja -j 20) (exit 7); log: ~/aseprite-installer/.work/logs/run-20261126-101500.log
```

## Exit codes and troubleshooting

| Code | Meaning |
| --- | --- |
| 0 | Success, already up to date, or nothing to uninstall |
| 1 | Preflight failed: running as root, not Linux, wrong CPU, no glibc or glibc too old, another run holds the lock, low disk, or uninstall declined |
| 2 | Bad command line or bad path override |
| 3 | Could not resolve the ref or the latest tag (network, or no such name) |
| 4 | A host requirement is missing (Docker or git missing or unusable, or a runtime library missing before the build), the builder image could not be made, or CMake in the image is too old |
| 5 | Clone or submodule failure |
| 6 | Skia download, checksum or unpack failure |
| 7 | CMake configure, compile or build check failure |
| 8 | Install or post-install check failure, including runtime libraries missing on the host |
| 130 | Interrupted (Ctrl-C); the running container is removed and the run cleaned up |

**Exit 4.**
- "Docker is not installed, its daemon is not running, or your user cannot use it": install Docker with your distro's instructions, start it (`systemctl start docker`), and add yourself to the `docker` group (log out and in again), or set up rootless Docker. Check with `docker info`.
- "git is not installed": install git with your package manager.
- "Missing runtime libraries": the script prints a `hint:` line with the install command for your distro (see the table above). Run it, then run the script again.
- "Could not pull ubuntu:24.04" or "Could not install the build packages": a network problem reaching Docker Hub or the Ubuntu mirrors. The run log has the details. Try again later.
- "CMake ... is older than ...": a kept builder image is too old for a newer Aseprite. Remove it (`docker image rm aseprite-installer-builder:ubuntu-24.04`) and run again.

**Exit 6.** The Skia library could not be downloaded, did not match its checksum, or did not unpack. The message names the URL. A bad zip is deleted, so running again downloads it afresh. Check that `github.com` is reachable from Docker containers (a proxy or firewall may block it).

**Exit 7.** CMake configure, the compile, or the build check failed. The script prints the last 40 lines of the build log and its path, and keeps `.work/src` and `.work/build` for inspection. Common causes: running out of memory with many jobs (try `--jobs 4`), or a `--ref` branch that does not build. A broken source folder is cleaned up by the next run if it is not at the right commit or not clean; `--force` rebuilds.

**Exit 8.** The install or its check failed. The existing install is never removed until the new one is ready.
- "these libraries are missing" (from `ldd` on the new binary): run the `hint:` install command, then run the script again. Nothing was installed.
- "glibc or libstdc++ is older than the build needs": the host is older than glibc 2.39 / GCC 13. Use a newer distro release.
- "... exists and is not a symlink": something else owns `~/.local/bin/aseprite`. Move it away and run again.
- "The installed binary reports ...": the installed binary does not run on this host as it did in the container. Check the run log.

## Testing

| Suite | What it checks |
| --- | --- |
| `tests/lint.sh` | `bash -n` on every script, and shellcheck 0.10.0 (in a container unless that version is installed) |
| `tests/unit.sh` | Offline unit tests: sources the script and calls its functions. No network, Docker or root. `tests/unit.sh --list` lists the tests; `tests/unit.sh <name>...` runs some. |
| `tests/e2e.sh` | Real builds into `.test/`. A full run includes several full builds; `tests/e2e.sh --quick` skips the downgrade/update pair. Also `--list`, `--fresh` and test names to run a subset |
| `tests/portability.sh` | The runtime checks in throwaway distro containers (`--app-dir DIR`, default `~/.local/opt/aseprite`; `--list`) |

The e2e suite checks that a run leaves nothing in `/tmp`. If another tool keeps its own files there under names containing "aseprite" or "skia", set `E2E_TMP_IGNORE` to a `find -path` pattern to skip, for example `E2E_TMP_IGNORE='/tmp/mytool-*'`.

Each suite prints `PASS name`, `FAIL name: reason` or `SKIP name: reason` per test, then a summary, and exits non-zero if anything failed. The unit suite keeps its temporary files under `.test/unit/`; guard commands on its `PATH` fail any test that would reach Docker, the network, `curl` or `sudo`.

Two test-only variables exist. Neither has any effect when unset (or empty):

| Variable | Effect |
| --- | --- |
| `ASEPRITE_TEST_BREAK_SKIA=1` | The build runs against an empty Skia folder, so it fails with exit 7. The build folder is deleted first and no stamp is written, so the next real run builds cleanly. |
| `ASEPRITE_TEST_FAKE_MISSING_LIB=<soname>` | The `ldd` check in step 8 reports that library as `not found`, so the install stops with exit 8 and leaves the existing install alone. |

## Implementation notes

- **Compiler cache.** The build container runs the compilers through `ccache`, with the cache in `.work/ccache` (capped at 3 GB, compiler checked by content). Rebuilds of the same or a nearby version reuse earlier compiles. `--uninstall --purge` deletes the cache with the rest of the work folder.
- **Lint without installing shellcheck.** `tests/lint.sh` always uses shellcheck 0.10.0, so local runs and CI agree. It uses a local `shellcheck` of that version, or otherwise runs the pinned `koalaman/shellcheck:v0.10.0` image with the repo mounted read-only and removes the image afterwards if it pulled it. Only without usable Docker does it fall back to a local shellcheck of another version, and it says so.
- **Package names checked in real containers.** `tests/portability.sh` checks the runtime table's names in real distro containers. openSUSE ships `libGL.so.1` in `libglvnd` (there is no `libGL1`). Arch uses `libstdc++` and `libgcc`, because `gcc-libs` is now a meta-package that pulls in much more.
- **Skia checksum.** The Skia release the build uses by default is checked against a pinned SHA-256, and a mismatch stops the run (exit 6). If an Aseprite version asks for a different Skia release, there is no pinned checksum for it: the zip is still tested for damage and its SHA-256 is written to the log, but it is not verified.
- **Placeholder version on old releases.** v1.3.17 and older hard-code `set(VERSION "1.x-dev")`, so their `--version` cannot show the tag. When the line is exactly `Aseprite 1.x-dev`, the build check warns and goes on; the state file's `ref` and `commit` still record what is installed.
- **Portability tests adapt the hint.** `tests/portability.sh` runs the hinted package manager command without `sudo`, refreshes the package lists first, and adds the non-interactive flag. Minimal containers have no sudo and no package lists, and would wait for confirmation. The packages stay exactly as the hint gives them.

### Details

**Command line and paths**

- `--help` and `--version` win wherever they appear, even after a bad option. `--ref=<ref>` and `--jobs=<n>` are accepted as well as the two-word forms. A `--ref` value that starts with `-` counts as missing (git ref names cannot start with `-`). `--jobs 0` is refused (ninja would read it as "unlimited"). With `--uninstall`, the build options (`--ref`, `--force`, `--keep-*`, `--jobs`) are accepted and ignored.
- An empty `ASEPRITE_PREFIX` or `ASEPRITE_WORK_DIR` means the default. Besides being absolute, a path must not be `/` or contain `.` or `..` folders. The work folder must not be your home folder (`--purge` deletes it) and must not contain `:` (Docker's `--volume` syntax). The prefix must not contain whitespace or any of `" ' ` $ \ %`, because the desktop entry and thumbnailer would need extra quoting rules. Any of these exits 2.
- The script folder is `readlink -f` of `BASH_SOURCE`, so a symlink to the script still uses `.work` next to the real file.

**Running, output and logs**

- `main` sets the ERR, EXIT and INT/TERM/HUP traps first, before step 1, so even a usage error ends with the step/log line. That line reads `error: stopped at step [n/9] <step> (exit <code>); log: <path>`, or `no log was written` when the run stopped before the log existed.
- An unexpected command failure (the ERR trap) exits with the code class of the step it happened in (step 1 → 1, 2 → 3, 3 → 4, 4 → 5, 5 → 6, 6 and 7 → 7, 8 and 9 → 8; uninstall → 1), so every exit code is one from the table.
- The run log is opened only after the lock is taken, so a second run that finds the lock held writes no log. Lines printed before that (the platform checks) are kept in memory and written at the top of the log.
- `--dry-run` still runs the read-only checks (platform, `docker info`, disk space, `ldconfig -p`, `git ls-remote`, `docker image inspect`, reading the state file) and stops with their exit codes if they fail. It creates nothing: no work folder, no lock, no log.
- Colour: only when the stream is a terminal and `NO_COLOR` is not set at all (even an empty `NO_COLOR=` turns it off).
- Without `--verbose`, on a terminal the build shows `-> [n/N] P%` on one line; otherwise it prints `-> Still building: [n/N] P%` every 60 seconds. `curl` runs with `--no-progress-meter` so the progress meter does not fill the log.
- Step timestamps in the run log carry their UTC offset. Steps 4-7 log from inside the container, which runs in UTC (only the work folder is mounted, so the host's time zone is not visible there).
- Log rotation counts `run-*.log` and `build-*.log` together (the 5 newest are kept) and goes by the timestamp in the name. It runs at the end of every run, failed ones too; files with other names are left alone.
- Host-side text parsing (`ldconfig -p`, `ldd`, `df`, `os-release`, state and manifest) is plain Bash, so the host needs nothing beyond the tools listed in "Host requirements" (no `grep`, `sed` or `awk`).

**Preflight**

- `docker info` runs once, with `--format '{{.DockerRootDir}}|{{.SecurityOptions}}'`. Rootless Docker is detected by `rootless` in the security options.
- Free space is measured with `df -Pk` on the nearest existing parent of each folder (the prefix may not exist yet). If `df` cannot read any of the three folders, the script warns and goes on; only too little free space stops it.
- The runtime library check takes only `x86-64` entries from `ldconfig -p`, so 32-bit copies do not count.

**Builder image**

- The tool versions (`clang`, `cmake`, `ninja`, `git`) are logged at the start of every build container, not in step 3, so a reused image is logged too and no extra probe container is needed. Step 3 logs the image ID and size.
- `.work/pulled-base` is written just before `docker pull`, so an interrupted pull is cleaned up as well. If removing `ubuntu:24.04` fails, the mark stays and a later run tries again.
- Images are removed only by runs that reached step 3. A run that stops earlier (for example "already up to date") leaves a kept builder image alone.
- `docker image rm` runs without `-f`. An image that another run's container is using therefore stays, with a warning and the command to remove it later, and the run does not fail. **Limitation:** the builder image name is global, so two concurrent runs with different work folders share it: one run may reuse or remove the image the other made. The lock only covers one work folder. Run one build at a time.
- SELinux and `:Z`: the work folder is mounted with `:Z` when `/sys/fs/selinux/enforce` exists, as Docker documents. When the daemon runs without SELinux support (no `selinux` in `docker info`'s security options), containers are not labelled and `:Z` changes nothing, so it is harmless. On a daemon with SELinux support on (`--selinux-enabled`), containers run confined and need `:Z` to use the folder, and Docker relabels only the work folder. Keying `:Z` on the daemon's security options instead would gain nothing, since `:Z` is a no-op whenever the daemon does not label containers, so the simple check stays.

**Build container**

- The setup container and the build container run in the background and the script `wait`s for them. Bash runs traps only between commands, and the container's PID 1 ignores the SIGINT that Docker forwards, so this is what lets Ctrl-C stop the run at once: the trap runs `docker rm -f` on the container and exits 130.
- The container writes its current step to `.work/tmp/container-step`, so the host's last error line names the right step (exit 7 alone cannot tell the build from the build check). Docker's own codes 125-127 (the container could not start) map to 4; any other code outside the table (a crash, the OOM killer) maps to 7.
- Messages from inside the container show paths as the host sees them (`.work/...`, not `/work/...`).
- `git describe --tags` must work for a tag build (exit 5 otherwise). A shallow clone of a branch has no tags, so for `--ref <branch>` it is only a warning, and Aseprite reports a version like `1.x-<sha>-dev`.
- The build check matches the tag more strictly than "contains": the version must be the tag without `v`, followed by the end, `-` or a space. So `1.3.18.60` does not pass for `v1.3.18.6`.
- The runtime-deps check (step 7) does not warn about glibc's own libraries (`libc.so.6`, `libm.so.6` and so on). The libstdc++ minimum is `GLIBCXX_3.4.32` (GCC 13).
- `ASEPRITE_TEST_BREAK_SKIA` deletes the build folder before configuring and writes no stamp, so a cache configured against the empty Skia is never reused.

**Install**

- The "regular file at `bin/aseprite`" check (step 8) also runs before anything is copied, so that failure changes nothing.
- An `opt/aseprite.old` left by a killed run is put back if `opt/aseprite` is missing, or deleted if it is not. The EXIT trap also puts it back if the run stops between the two renames.
- Every host run of the built binary (`--version` in step 9) gets `HOME`, `XDG_CONFIG_HOME`, `XDG_CACHE_HOME` and `ASEPRITE_USER_FOLDER` pointing under `.work/tmp/aseprite-home`, and no `DISPLAY` or `WAYLAND_DISPLAY`. Aseprite rewrites `Aseprite.log` in its user folder on every start, even for `--version`, and `~/.config/aseprite/` must never be touched.
- The desktop entry rewrite changes `Exec` and `TryExec` only in the `[Desktop Entry]` group (other groups, such as actions, are left alone) and accepts spaces around `=`. "Bare `aseprite -b`" in the thumbnailer means not preceded by a letter, digit, `_`, `.`, `/` or `-`.
- If the source lacks the desktop file, the MIME file or the thumbnailer files, that part is skipped with a warning instead of failing the install.
- The summary shows the version exactly as the build reports it (e.g. `1.3.18.6-dev`), and "built in" is the time the build container took.

**Uninstall**

- Uninstall prints `==> [1/2] Preflight` and `==> [2/2] Uninstalling`.
- Uninstall removes a manifest entry only if it is one of the paths the install step creates (the app folder, the `bin` link, the desktop entry, `hicolor/<N>x<N>/apps/aseprite.png` icons, the MIME file and the thumbnailer files). Anything else, including paths outside the prefix or with `.`/`..` parts, is skipped with a warning, so a damaged manifest cannot remove anything else. `bin/aseprite` is removed only while it still links into the app folder, so a link or file you put there yourself is kept.
- After removing the icons, `hicolor/<N>x<N>/apps` and `hicolor/<N>x<N>` are removed only if empty.
- `--purge` adds the work folder and the image to the list that is shown and confirmed. It deletes only the entries the script makes in the work folder, then the folder itself if that leaves it empty.

## Contributing and reporting issues

Issues and pull requests are welcome. When reporting a problem, please include:

- your distro and version, and the output of `ldd --version | head -1` and `docker version --format '{{.Server.Version}}'`;
- the command you ran and its exit code;
- the last lines of the log named in the `error:` line (`.work/logs/`). Check it for anything private first.

For code changes, run `tests/lint.sh` and `tests/unit.sh` (both need `git`; lint may download the pinned shellcheck image; CI runs them too). For changes to the build or install steps, also run `tests/e2e.sh --quick`. Change or add a test first, then the code.

## Licence

The script and its tests are released under the MIT licence; see `LICENSE`. That licence covers this repo only. Aseprite itself is under its own [EULA](https://github.com/aseprite/aseprite/blob/main/EULA.txt), which allows building it from source for your own use but not redistributing the result. Do not publish binaries built with this script, including from CI.
