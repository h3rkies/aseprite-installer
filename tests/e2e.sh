#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# tests/e2e.sh: end-to-end tests of install-aseprite.sh.
#
#   tests/e2e.sh [--list] [--fresh] [--quick] [test...]
#
# These are real runs: they build Aseprite in Docker. A full run includes
# several full builds; --quick skips the downgrade/update builds. Every step
# prints a timestamped line.
#
# All runs use ASEPRITE_PREFIX=.test/e2e/prefix and ASEPRITE_WORK_DIR=.test/e2e/work
# (one work folder for the whole run, so Skia is downloaded once). The purge test
# removes the work folder at the end. Suite files stay in .test/e2e/ for review:
#   runs/NN-<test>.{out,err}  stdout and stderr of each script run
#   runs/NN-<test>.run-*.log  copies of the script's own logs (purge deletes the originals)
#   state/                    the baseline taken at the start (docker lists, ~/.config/aseprite
#                             checksums, the stamp file for the containment check)
#
# Running a subset: name the tests. They always run in suite order. Tests that need
# state from an earlier test check for it first and FAIL with "needs ..." if it is
# missing; `--list` shows what each one needs. A subset reuses the baseline of the
# run that made .test/e2e/state; `--fresh` wipes .test/e2e and takes a new one (a run
# with no test names always starts fresh).
#
# Prerequisites: Docker usable by this user, git, network access to github.com and
# Docker Hub, and enough free disk in the repo for a few builds. No builder image or script container
# may exist when a fresh run starts. Do not run tests/portability.sh at the same
# time: both use ubuntu:24.04, and the "present before" checks would clash.
#
# Every run of the script has fake sudo/dnf/rpm/apt/apt-get/dpkg/pacman/zypper/
# pkexec/doas first on PATH (tests/fakes/sudo): any call to them fails the test.
# The suite runs the installed binary only with `--version`, with HOME, XDG dirs and
# TMPDIR pointed into .test/e2e/home and DISPLAY unset, so it never opens a window
# and never touches ~/.config/aseprite.
#
# Environment knobs (all optional):
#   E2E_OLD_REF       older tag for ref_old           (default v1.3.17)
#   E2E_MISSING_LIB   soname for missing_lib          (default libXcursor.so.1)
#   E2E_RUN_TIMEOUT   seconds before one script run is stopped (default 5400)
#   E2E_INT_MAX       seconds the script may take to exit after SIGINT (default 30)
#   E2E_TMP_IGNORE    find -path pattern skipped by the /tmp checks (default: none)
set -uo pipefail

REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT=$REPO/install-aseprite.sh
E2E=$REPO/.test/e2e
TMPDIR_SENTINEL=$REPO/.test/e2e-tmpdir
PREFIX=$E2E/prefix
WORK=$E2E/work
STATE=$E2E/state
RUNS=$E2E/runs
GUARD=$E2E/guard
FAKELOG=$E2E/fakes
SBXHOME=$E2E/home
STATE_FILE=$PREFIX/opt/aseprite/.aseprite-installer/state
MANIFEST=$PREFIX/opt/aseprite/.aseprite-installer/manifest
BIN=$PREFIX/opt/aseprite/aseprite

BUILDER=aseprite-installer-builder:ubuntu-24.04
BASE=ubuntu:24.04
REPO_URL=https://github.com/aseprite/aseprite.git
OLD_REF=${E2E_OLD_REF:-v1.3.17}
MISSING_LIB=${E2E_MISSING_LIB:-libXcursor.so.1}
RUN_TIMEOUT=${E2E_RUN_TIMEOUT:-5400}
INT_MAX=${E2E_INT_MAX:-30}
ICON_COUNT=9
UPTODATE_MAX=30
FORBIDDEN=(sudo su pkexec doas dnf yum microdnf rpm apt apt-get apt-cache dpkg pacman zypper)

# --quick leaves out the downgrade/update pair, the two extra full builds.
QUICK_SKIP=(ref_old update_back)
QUICK=0
TESTS=(dry_run bad_ref fresh_install docker_unusable up_to_date force_rebuild missing_lib
  ref_old update_back interrupt break_skia interrupt_build uninstall uninstall_again purge containment)
declare -A DESC=(
  [dry_run]='--dry-run exits 0, creates nothing under the prefix; docker image ls -q / ps -aq unchanged'
  [bad_ref]='--ref no-such-ref exits 3 and makes no image'
  [fresh_install]='fresh install (--yes --keep-build) exits 0; binary, desktop/icons/MIME/thumbnailer/manifest/state, no image left, files owned by user'
  [docker_unusable]='fake docker whose info fails: exit 4, says Docker is unusable, prefix unchanged, sudo never called'
  [up_to_date]='second plain run exits 0 within 30 s, "already installed and up to date", no rebuild, no image'
  [force_rebuild]='--force --keep-build --keep-image rebuilds and reinstalls; src/build kept, one opt/aseprite, image kept'
  [missing_lib]="ASEPRITE_TEST_FAKE_MISSING_LIB=$MISSING_LIB: exit 8, names the library, previous install untouched"
  [ref_old]="--ref $OLD_REF --yes reuses the kept image, installs ${OLD_REF#v}, removes the image"
  [update_back]='plain run updates back to the latest tag; old Skia removed if the tag differs; src/build/downloads cleaned'
  [interrupt]='SIGINT during the setup container: exit 130, container and image removed, install untouched'
  [interrupt_build]='--force --keep-image; SIGINT 3 s after the build container starts: exit 130 fast, no container or partial folder left, install intact, image kept'
  [break_skia]='ASEPRITE_TEST_BREAK_SKIA=1: exit 7, previous install still runs, no script container left'
  [uninstall]='--uninstall --yes exits 0; every manifest path gone; ~/.config/aseprite untouched'
  [uninstall_again]='second --uninstall --yes prints "not installed" and exits 0'
  [purge]='--uninstall --purge --yes removes the work folder and the kept builder image'
  [containment]='nothing written outside the repo; ~/.cache/aseprite-installer, ~/deps/skia-*, /tmp files absent; lists changed files under HOME'
)
declare -A COST=(
  [dry_run]=quick [bad_ref]=quick [fresh_install]='full build'
  [docker_unusable]=quick [up_to_date]=quick [force_rebuild]='short (new image, reused build)'
  [missing_lib]='short (reuses image and build)' [ref_old]='full build'
  [update_back]='full build' [interrupt]=short [interrupt_build]=short [break_skia]='short (new image, clone)'
  [uninstall]=quick [uninstall_again]=quick [purge]=quick [containment]='short (scans HOME)'
)
declare -A NEEDS=(
  [dry_run]='nothing'
  [bad_ref]='nothing'
  [fresh_install]='an empty prefix and no builder image (makes: latest install, kept src/ and build/)'
  [docker_unusable]='nothing (more telling after fresh_install, when the prefix is not empty)'
  [up_to_date]='the latest tag installed (from fresh_install)'
  [force_rebuild]='the latest tag installed; fast only with src/ and build/ kept by fresh_install (makes: kept image)'
  [missing_lib]='an install; fast only with the image and build kept by force_rebuild (keeps the image)'
  [ref_old]='the kept builder image (from force_rebuild / missing_lib)'
  [update_back]="$OLD_REF installed (from ref_old)"
  [interrupt]='an install and no builder image (state after update_back)'
  [interrupt_build]='an install and the kept builder image (from break_skia)'
  [break_skia]='an install (from update_back) (makes: kept image for purge)'
  [uninstall]='an install with a manifest (from break_skia / update_back)'
  [uninstall_again]='nothing installed (from uninstall)'
  [purge]='the kept builder image and the work folder (from break_skia)'
  [containment]='the baseline of this run (state/); best run last, after purge'
)

PASSED=0 FAILED=0 SKIPPED=0
CUR='' T0=0 RUN_N=0 GUARD_LINES=0
REASONS=()
RUN_ENV=() RUN_PATH='' RC=0 OUT='' ERR='' RUN_BASE='' ELAPSED=0
RUN_LOGS=() CMD=()
APP_OUT='' LATEST=''

# ---------------------------------------------------------------- output helpers

ts() { date +%H:%M:%S; }
log() { printf '# %s %s\n' "$(ts)" "$*"; }
note() { printf '#          %s\n' "$@"; }
indent() { sed 's/^/#            /'; }
dur() { printf '%dm %02ds' $(($1 / 60)) $(($1 % 60)); }
re_escape() { sed 's/[][\.^$*+?(){}|/]/\\&/g' <<<"$1"; }

# tmp_find EXPR...: find in /tmp (3 levels), skipping E2E_TMP_IGNORE (a find -path
# pattern) when it is set, for tools that keep their own files there.
tmp_find() {
  if [[ -n ${E2E_TMP_IGNORE:-} ]]; then
    find /tmp -maxdepth 3 -path "$E2E_TMP_IGNORE" -prune -o "$@"
  else
    find /tmp -maxdepth 3 "$@"
  fi
}
bad() {
  REASONS+=("$*")
  printf '# %s   check failed: %s\n' "$(ts)" "$*"
}

begin_test() {
  CUR=$1
  REASONS=()
  T0=$SECONDS
  log "=== $CUR (${COST[$CUR]}): ${DESC[$CUR]}"
}

end_test() {
  log "=== $CUR finished in $(dur $((SECONDS - T0)))"
  if ((${#REASONS[@]})); then
    local joined
    joined=$(printf '%s; ' "${REASONS[@]}")
    echo "FAIL $CUR: ${joined%; }"
    FAILED=$((FAILED + 1))
  else
    echo "PASS $CUR"
    PASSED=$((PASSED + 1))
  fi
}

summary() {
  echo "e2e: $PASSED passed, $FAILED failed, $SKIPPED skipped"
}

same_or_bad() { # before after message
  [[ $1 == "$2" ]] && return 0
  bad "$3"
  diff <(printf '%s\n' "$1") <(printf '%s\n' "$2") | head -n 30 | indent
  return 1
}

# ------------------------------------------------------------- snapshot helpers

tree_snapshot() {
  if [[ -e $1 || -L $1 ]]; then
    find "$1" -printf '%P\t%y\t%s\t%T@\t%m\t%l\n' 2>/dev/null | LC_ALL=C sort
  else
    echo '<absent>'
  fi
}

docker_images() { docker image ls -q | LC_ALL=C sort; }
docker_containers() { docker ps -aq | LC_ALL=C sort; }
image_present() { docker image inspect "$1" >/dev/null 2>&1; }
script_containers() { docker ps -a --filter 'name=aseprite-installer-' --format '{{.Names}}'; }

config_listing() { # sha256 listing of ~/.config/aseprite (read only)
  local d=$HOME/.config/aseprite
  if [[ -d $d ]]; then
    (cd -- "$d" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum &&
      find . -printf '%y %p\n' | LC_ALL=C sort)
  else
    echo '<absent>'
  fi
}

config_mtimes() {
  local d=$HOME/.config/aseprite
  if [[ -d $d ]]; then
    find "$d" -printf '%T@ %P\n' | LC_ALL=C sort -k2
  else
    echo '<absent>'
  fi
}

default_install_listing() { # the default ~/.local install paths must not change during e2e
  local p
  for p in "$HOME/.local/opt/aseprite" "$HOME/.local/bin/aseprite" "$HOME/.local/bin/aseprite-thumbnailer" \
    "$HOME/.local/share/applications/aseprite.desktop" "$HOME/.local/share/mime/packages/aseprite.xml" \
    "$HOME/.local/share/thumbnailers/aseprite.thumbnailer"; do
    if [[ -e $p || -L $p ]]; then
      find "$p" -maxdepth 1 -printf '%p\t%y\t%s\t%T@\n' 2>/dev/null
    else
      echo "absent $p"
    fi
  done
  find "$HOME/.local/share/icons/hicolor" -path '*/apps/aseprite.png' -printf '%p\t%s\t%T@\n' 2>/dev/null | LC_ALL=C sort
}

take_baseline() {
  mkdir -p -- "$STATE"
  : >"$STATE/stamp"
  docker_images >"$STATE/images"
  docker_containers >"$STATE/containers"
  if image_present "$BASE"; then echo present; else echo absent; fi >"$STATE/base"
  config_listing >"$STATE/config-aseprite.sha256"
  config_mtimes >"$STATE/config-aseprite.mtimes"
  default_install_listing >"$STATE/default-install"
  tree_snapshot "$REPO/.work" >"$STATE/dotwork"
  tmp_find \( -iname '*aseprite*' -o -iname '*skia*' \) -print \
    2>/dev/null | LC_ALL=C sort >"$STATE/tmp-named"
  log "baseline taken in $STATE ($BASE was $(cat "$STATE/base") before the run;" \
    "$(wc -l <"$STATE/images") images, $(wc -l <"$STATE/containers") containers)"
}

# ------------------------------------------------------------ guard and runner

setup_guard() {
  mkdir -p -- "$GUARD" "$FAKELOG" "$RUNS" "$SBXHOME/.config" "$SBXHOME/.cache" "$SBXHOME/tmp"
  local c
  for c in "${FORBIDDEN[@]}"; do ln -sfn -- "$REPO/tests/fakes/sudo" "$GUARD/$c"; done
  touch -- "$FAKELOG/calls.log"
  GUARD_LINES=$(wc -l <"$FAKELOG/calls.log")
  RUN_N=$(find "$RUNS" -maxdepth 1 -name '*.out' | wc -l)
}

check_guard() { # fail the test if the fakes logged a forbidden command since the last check
  local n new='' forbidden
  n=$(wc -l <"$FAKELOG/calls.log")
  ((n > GUARD_LINES)) && new=$(tail -n "+$((GUARD_LINES + 1))" "$FAKELOG/calls.log")
  GUARD_LINES=$n
  forbidden=$(grep -v '^docker\( \|$\)' <<<"$new" | grep -v '^$' || true)
  if [[ -n $forbidden ]]; then
    bad "the script called forbidden host command(s): $(head -n 3 <<<"$forbidden" | tr '\n' ' ')"
  fi
}

new_run_files() { # label
  RUN_N=$((RUN_N + 1))
  RUN_BASE=$(printf '%s/%02d-%s' "$RUNS" "$RUN_N" "$1")
  OUT=$RUN_BASE.out
  ERR=$RUN_BASE.err
  : >"$RUN_BASE.start"
}

script_cmd() { # fills CMD: the script, run in the suite's environment (RUN_ENV, RUN_PATH)
  CMD=(env -u DISPLAY -u WAYLAND_DISPLAY -u ASEPRITE_TEST_BREAK_SKIA -u ASEPRITE_TEST_FAKE_MISSING_LIB
    "ASEPRITE_PREFIX=$PREFIX" "ASEPRITE_WORK_DIR=$WORK" "FAKE_LOG_DIR=$FAKELOG"
    "PATH=${RUN_PATH:-$GUARD:$PATH}" "${RUN_ENV[@]}" "$SCRIPT")
}

save_run_logs() { # copy the script's logs written during this run (purge deletes the originals)
  RUN_LOGS=()
  local f
  [[ -d $WORK/logs ]] || return 0
  while IFS= read -r f; do
    cp -p -- "$f" "$RUN_BASE.${f##*/}"
    RUN_LOGS+=("$RUN_BASE.${f##*/}")
  done < <(find "$WORK/logs" -maxdepth 1 -type f -newer "$RUN_BASE.start" 2>/dev/null | LC_ALL=C sort)
}

run_script() { # label args... ; sets RC OUT ERR ELAPSED RUN_LOGS; uses RUN_ENV and RUN_PATH
  local label=$1 extra=''
  shift
  new_run_files "$label"
  ((${#RUN_ENV[@]})) && extra=" with ${RUN_ENV[*]}"
  log "$label: running install-aseprite.sh ${*:-(no options)}$extra"
  local t0=$SECONDS line
  script_cmd
  # --foreground keeps the script in this terminal's process group, so a Ctrl-C by the
  # person running the suite reaches the script (and its docker client) too.
  # The readers ignore SIGINT: a Ctrl-C must not leave the script writing into
  # a dead pipe while it cleans up. TMPDIR points at an empty folder that must stay
  # empty: the script may only make temp files under its work folder.
  mkdir -p -- "$TMPDIR_SENTINEL"
  TMPDIR=$TMPDIR_SENTINEL timeout --foreground -k 60 "$RUN_TIMEOUT" "${CMD[@]}" "$@" </dev/null 2>"$ERR" |
    (trap '' INT; tee "$OUT") |
    (trap '' INT; while IFS= read -r line; do printf '# %s   | %s\n' "$(ts)" "$line"; done)
  RC=${PIPESTATUS[0]}
  check_tmpdir_sentinel
  ELAPSED=$((SECONDS - t0))
  log "$label: exit $RC after $(dur "$ELAPSED")"
  save_run_logs
  check_guard
}

printed_has() { grep -Eq -- "$1" "$OUT" "$ERR"; }
logged_has() { grep -Eq -- "$1" "$OUT" "$ERR" "${RUN_LOGS[@]}"; }

show_tail() {
  note "last lines of stderr ($ERR):"
  tail -n 15 "$ERR" | indent
}

expect_rc() {
  ((RC == $1)) && return 0
  if ((RC == 124 || RC == 137)); then
    bad "the run was stopped after ${RUN_TIMEOUT}s (exit $RC), expected exit $1"
  else
    bad "exit code $RC, expected $1"
  fi
  show_tail
  return 1
}

check_last_err_line() { # the last line on stderr names the step and the log path
  local last
  last=$(grep -v '^[[:space:]]*$' "$ERR" | tail -n 1)
  [[ $last =~ logs/run-[0-9]{8}-[0-9]{6}\.log ]] ||
    bad "the last stderr line does not name the run log: '${last:0:160}'"
}

# ------------------------------------------------------------- state helpers

state_get() { sed -n "s/^$1=//p" "$STATE_FILE" 2>/dev/null | head -n 1; }

latest_tag() {
  if [[ ! -s $STATE/latest_tag ]]; then
    local tags
    tags=$(git ls-remote --tags --refs "$REPO_URL") || return 1
    awk -F 'refs/tags/' '{ print $2 }' <<<"$tags" | grep -E '^v[0-9]+(\.[0-9]+)+$' | sort -V | tail -n 1 >"$STATE/latest_tag"
  fi
  [[ -s $STATE/latest_tag ]] && cat "$STATE/latest_tag"
}

tag_commit() { # commit a tag points to (peeled for annotated tags), from git ls-remote
  local lines
  lines=$(git ls-remote --tags "$REPO_URL" "refs/tags/$1") || return 1
  awk -v t="refs/tags/$1^{}" '$2 == t { print $1; found = 1 } END { if (!found) exit 1 }' <<<"$lines" ||
    awk -v t="refs/tags/$1" '$2 == t { print $1 }' <<<"$lines"
}

app_version() { # binary -> its --version output, run sandboxed (no display, no real HOME)
  # Aseprite opens (truncates) <user folder>/Aseprite.log on every start, even for --version.
  # The user folder is $ASEPRITE_USER_FOLDER, else $XDG_CONFIG_HOME/aseprite, else ~/.config/aseprite.
  timeout 60 env -u DISPLAY -u WAYLAND_DISPLAY HOME="$SBXHOME" XDG_CONFIG_HOME="$SBXHOME/.config" \
    ASEPRITE_USER_FOLDER="$SBXHOME/aseprite-user" \
    XDG_CACHE_HOME="$SBXHOME/.cache" XDG_DATA_HOME="$SBXHOME/.local/share" TMPDIR="$SBXHOME/tmp" \
    "$1" --version 2>&1 </dev/null
}

check_app_version() { # regex the first line must match
  local out rc first
  out=$(app_version "$PREFIX/bin/aseprite")
  rc=$?
  APP_OUT=$out
  first=${out%%$'\n'*}
  note "installed binary says: ${first:-<nothing>}"
  if ((rc != 0)); then
    bad "$PREFIX/bin/aseprite --version exited $rc: ${first:0:160}"
    return 1
  fi
  [[ $first =~ $1 ]] || {
    bad "--version printed '$first', expected /$1/"
    return 1
  }
}

install_fingerprint() { # what must not change when a run fails
  if [[ -f $STATE_FILE ]]; then sha256sum <"$STATE_FILE"; else echo 'no state'; fi
  stat -c '%i %Y' -- "$PREFIX/opt/aseprite" "$BIN" 2>/dev/null || echo 'no app'
  readlink -- "$PREFIX/bin/aseprite" 2>/dev/null || echo 'no symlink'
  app_version "$PREFIX/bin/aseprite" | head -n 1
}

check_install_untouched() { # fingerprint-before
  same_or_bad "$1" "$(install_fingerprint)" "the previous install changed" || return 1
  local first
  first=$(app_version "$PREFIX/bin/aseprite" | head -n 1)
  [[ $first == Aseprite\ * ]] || bad "the previous install no longer runs: '$first'"
}

opt_dirs() { find "$PREFIX/opt" -mindepth 1 -maxdepth 1 -name 'aseprite*' -printf '%f\n' 2>/dev/null | LC_ALL=C sort; }

check_one_opt_dir() {
  local d
  d=$(opt_dirs | tr '\n' ' ')
  [[ $d == 'aseprite ' ]] || bad "expected exactly one opt/aseprite folder, found: ${d:-none}"
}

check_docker_after() { # keep|none: whether the builder image must remain
  local c
  c=$(script_containers | tr '\n' ' ')
  [[ -z $c ]] || bad "script container(s) left: $c"
  if [[ $1 == keep ]]; then
    image_present "$BUILDER" || bad "builder image $BUILDER is gone, but --keep-image was given"
  else
    image_present "$BUILDER" && bad "builder image $BUILDER was left behind"
    check_base_as_baseline
  fi
}

check_base_as_baseline() {
  local before
  before=$(cat "$STATE/base")
  if image_present "$BASE"; then
    [[ $before == present ]] || bad "$BASE was left behind (it was not present before the suite)"
  else
    [[ $before == absent ]] || bad "$BASE was removed, but it was present before the suite"
  fi
}

check_config_untouched() { # ~/.config/aseprite: same content and same mtimes as at the baseline
  same_or_bad "$(cat "$STATE/config-aseprite.sha256")" "$(config_listing)" "$HOME/.config/aseprite changed (content)"
  if [[ $(cat "$STATE/config-aseprite.mtimes") != "$(config_mtimes)" ]]; then
    bad "$HOME/.config/aseprite was touched (mtimes changed). Aseprite opens and truncates Aseprite.log there on every start, even for --version; the script must run it with ASEPRITE_USER_FOLDER (or HOME) pointing elsewhere"
    diff <(cat "$STATE/config-aseprite.mtimes") <(config_mtimes) | head -n 20 | indent
  fi
}

check_ownership() {
  [[ -d $WORK ]] || return 0
  local others
  others=$(find "$WORK" ! -user "$(id -u)" -print 2>/dev/null | head -n 10)
  if [[ -n $others ]]; then
    bad "files under the work folder are not owned by $(id -un)"
    indent <<<"$others"
  fi
}

check_no_partials() {
  local found
  found=$(find "$PREFIX" "$WORK" -maxdepth 2 \( -name '*.partial' -o -name '*.new' -o -name 'aseprite.old' \) \
    -print 2>/dev/null)
  [[ -z $found ]] || bad "leftover partial folders: $(tr '\n' ' ' <<<"$found")"
  if [[ -d $WORK/tmp ]] && [[ -n $(find "$WORK/tmp" -mindepth 1 -print -quit) ]]; then
    bad "$WORK/tmp is not empty"
  fi
}

skia_dirs() { find "$WORK/skia" -mindepth 1 -maxdepth 1 -name 'skia-*' -printf '%f\n' 2>/dev/null | LC_ALL=C sort; }

check_clean_work_after_success() {
  check_no_partials
  [[ -e $WORK/downloads ]] && bad "$WORK/downloads still exists (step 9)"
  local want got
  want="skia-$(state_get skia_tag)"
  got=$(skia_dirs | tr '\n' ' ')
  [[ $got == "$want " ]] || bad "Skia folders in the work folder: '${got% }', expected only $want"
}

check_installed_files() {
  local f out rc
  for f in "$PREFIX/share/applications/aseprite.desktop" "$PREFIX/share/mime/packages/aseprite.xml" \
    "$PREFIX/share/thumbnailers/aseprite.thumbnailer" "$MANIFEST" "$STATE_FILE"; do
    [[ -f $f ]] || bad "missing ${f#"$PREFIX"/}"
  done
  [[ -f $PREFIX/bin/aseprite-thumbnailer && -x $PREFIX/bin/aseprite-thumbnailer ]] ||
    bad "missing or not executable: bin/aseprite-thumbnailer"
  [[ -L $PREFIX/bin/aseprite && $(readlink -- "$PREFIX/bin/aseprite") == "$BIN" ]] ||
    bad "bin/aseprite is not a symlink to $BIN"

  local icons=()
  mapfile -t icons < <(find "$PREFIX/share/icons/hicolor" -path '*/apps/aseprite.png' 2>/dev/null | LC_ALL=C sort -V)
  note "icons: $(printf '%s\n' "${icons[@]}" | sed -n 's#.*/hicolor/\([^/]*\)/apps/.*#\1#p' | tr '\n' ' ')"
  ((${#icons[@]} == ICON_COUNT)) || bad "found ${#icons[@]} icons, expected $ICON_COUNT"
  for f in "${icons[@]}"; do
    [[ $f =~ /hicolor/([0-9]+)x([0-9]+)/apps/aseprite\.png$ && ${BASH_REMATCH[1]} == "${BASH_REMATCH[2]}" ]] ||
      bad "icon in an unexpected place: $f"
  done

  local desk=$PREFIX/share/applications/aseprite.desktop
  if [[ -f $desk ]]; then
    grep -qxF "Exec=$BIN %U" "$desk" || bad "desktop file has no line 'Exec=$BIN %U'"
    grep -qxF "TryExec=$BIN" "$desk" || bad "desktop file has no line 'TryExec=$BIN'"
    if command -v desktop-file-validate >/dev/null 2>&1; then
      out=$(desktop-file-validate "$desk" 2>&1)
      rc=$?
      [[ -n $out ]] && indent <<<"$out"
      if ((rc != 0)) || grep -q 'error:' <<<"$out"; then
        bad "desktop-file-validate reports errors (exit $rc)"
      else
        note "desktop-file-validate: no errors"
      fi
    else
      note "desktop-file-validate is not installed on this host; that check was not done"
    fi
  fi

  local thumb=$PREFIX/share/thumbnailers/aseprite.thumbnailer tbin=$PREFIX/bin/aseprite-thumbnailer
  if [[ -f $thumb ]]; then
    grep -qxF "TryExec=$tbin" "$thumb" || bad "thumbnailer entry has no line 'TryExec=$tbin'"
    grep -qxF "Exec=$tbin %i %o %s" "$thumb" || bad "thumbnailer entry has no line 'Exec=$tbin %i %o %s'"
  fi
  if [[ -f $tbin ]]; then
    grep -Eq '(^|[^/[:alnum:]_.-])aseprite -b' "$tbin" && bad "bin/aseprite-thumbnailer still has a bare 'aseprite -b'"
    grep -qF "$BIN -b" "$tbin" || bad "bin/aseprite-thumbnailer does not call '$BIN -b'"
  fi

  if [[ -f $MANIFEST ]]; then
    grep -qxF "$PREFIX/opt/aseprite" "$MANIFEST" || bad "manifest does not list $PREFIX/opt/aseprite"
    local line missing=0
    while IFS= read -r line; do
      [[ -z $line ]] && continue
      if [[ $line != /* ]]; then
        bad "manifest line is not an absolute path: $line"
      elif [[ ! -e $line && ! -L $line ]]; then
        missing=$((missing + 1))
        note "manifest lists a missing path: $line"
      fi
    done <"$MANIFEST"
    ((missing == 0)) || bad "$missing manifest path(s) do not exist"
  fi
}

check_state() { # tag commit
  local k v
  [[ -f $STATE_FILE ]] || return 0
  for k in ref commit version skia_tag build_base installed_at script_version; do
    grep -q "^$k=" "$STATE_FILE" || bad "state file has no '$k=' line"
  done
  [[ $(state_get ref) == "$1" ]] || bad "state ref='$(state_get ref)', expected $1"
  [[ -z $2 || $(state_get commit) == "$2" ]] || bad "state commit='$(state_get commit)', git ls-remote says $2"
  [[ $(state_get build_base) == "$BASE" ]] || bad "state build_base='$(state_get build_base)', expected $BASE"
  [[ $(state_get installed_at) =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}(:[0-9]{2}([.,][0-9]+)?)?(Z|[+-][0-9]{2}(:?[0-9]{2})?)$ ]] ||
    bad "state installed_at='$(state_get installed_at)' is not ISO 8601 with a time zone"
  v=${APP_OUT%%$'\n'*}
  v=${v#Aseprite }
  [[ $(state_get version) == "$v" ]] || bad "state version='$(state_get version)', but --version prints '$v'"
  v=$(state_get script_version)
  script_cmd
  [[ -n $v ]] && ! "${CMD[@]}" --version 2>/dev/null </dev/null | grep -qF -- "$v" &&
    bad "state script_version='$v' does not match install-aseprite.sh --version"
  return 0
}

# ------------------------------------------------------------- preconditions

require_install() {
  [[ -f $STATE_FILE && -x $BIN ]] && return 0
  bad "needs an install in $PREFIX (made by fresh_install); there is none"
  return 1
}

require_ref() { # ref, test that makes it
  require_install || return 1
  local r
  r=$(state_get ref)
  [[ $r == "$1" ]] && return 0
  bad "needs $1 installed (made by $2); the installed ref is '${r:-?}'"
  return 1
}

require_builder() { # test that keeps it
  image_present "$BUILDER" && return 0
  bad "needs the kept builder image $BUILDER (kept by $1); it does not exist"
  return 1
}

require_latest() {
  local tag
  tag=$(latest_tag) || {
    bad "cannot list the tags with git ls-remote $REPO_URL"
    return 1
  }
  LATEST=$tag
}

# ======================================================================= tests

t_dry_run() {
  local pfx imgs ctrs work n
  pfx=$(tree_snapshot "$PREFIX")
  imgs=$(docker_images)
  ctrs=$(docker_containers)
  work=$(tree_snapshot "$WORK")
  run_script dry_run --dry-run
  expect_rc 0
  same_or_bad "$pfx" "$(tree_snapshot "$PREFIX")" "the dry run changed something under the prefix"
  same_or_bad "$imgs" "$(docker_images)" "docker image ls -q changed"
  same_or_bad "$ctrs" "$(docker_containers)" "docker ps -aq changed"
  for n in {1..9}; do
    printed_has "^==> \[$n/9\]" || bad "no step header '==> [$n/9]' in the dry-run output"
  done
  if [[ $work != "$(tree_snapshot "$WORK")" ]]; then
    note "for review (not a failure): the dry run wrote to the work folder:"
    diff <(printf '%s\n' "$work") <(tree_snapshot "$WORK") | grep '^>' | cut -f1 | head -n 20 | indent
  fi
}

t_bad_ref() {
  local pfx imgs ctrs
  pfx=$(tree_snapshot "$PREFIX")
  imgs=$(docker_images)
  ctrs=$(docker_containers)
  run_script bad_ref --ref no-such-ref
  expect_rc 3
  printed_has 'no-such-ref' || bad "the error does not name the ref 'no-such-ref'"
  same_or_bad "$imgs" "$(docker_images)" "docker image ls -q changed (no image may be made)"
  same_or_bad "$ctrs" "$(docker_containers)" "docker ps -aq changed"
  same_or_bad "$pfx" "$(tree_snapshot "$PREFIX")" "the prefix changed"
  check_last_err_line
}

t_fresh_install() {
  if [[ -e $STATE_FILE || -e $PREFIX/opt/aseprite ]]; then
    bad "the prefix already holds an install; fresh_install needs an empty one (use --fresh)"
    return 0
  fi
  if image_present "$BUILDER"; then
    bad "builder image $BUILDER already exists; fresh_install must make it (docker image rm $BUILDER)"
    return 0
  fi
  require_latest || return 0
  local commit
  commit=$(tag_commit "$LATEST")
  note "latest stable tag: $LATEST (commit ${commit:-?})"
  note "--keep-build is added so that force_rebuild and missing_lib reuse this build"
  run_script fresh_install --yes --keep-build
  if ! expect_rc 0; then
    check_docker_after none
    check_ownership
    return 0
  fi
  check_app_version "^Aseprite $(re_escape "${LATEST#v}")-dev$"
  check_installed_files
  check_state "$LATEST" "$commit"
  check_one_opt_dir
  check_docker_after none
  check_ownership
  check_clean_work_after_success
  [[ -d $WORK/src && -d $WORK/build ]] || bad "--keep-build: src/ or build/ is missing from the work folder"
  state_get skia_tag >"$STATE/latest_skia_tag"
  stat -c %i -- "$WORK/skia/skia-$(state_get skia_tag)" >"$STATE/skia_inode" 2>/dev/null || true
}

t_docker_unusable() {
  local pfx imgs ctrs calls
  pfx=$(tree_snapshot "$PREFIX")
  imgs=$(docker_images)
  ctrs=$(docker_containers)
  RUN_PATH="$REPO/tests/fakes:$GUARD:$PATH"
  run_script docker_unusable
  RUN_PATH=''
  expect_rc 4
  grep -Eiq 'docker.*(not installed|not running|cannot use|unusable)' "$ERR" ||
    bad "stderr does not say that Docker is unusable"
  same_or_bad "$pfx" "$(tree_snapshot "$PREFIX")" "the prefix changed"
  same_or_bad "$imgs" "$(docker_images)" "the real docker image list changed"
  same_or_bad "$ctrs" "$(docker_containers)" "the real docker container list changed"
  calls=$(grep '^docker' "$FAKELOG/calls.log" | tail -n 20)
  note "fake docker calls so far (last 20):"
  indent <<<"$calls"
  grep -q '^docker info' <<<"$calls" || bad "the fake docker was never asked for 'info' (was it used?)"
  grep -Eq '^docker (run|pull|commit|build|buildx)( |$)' <<<"$calls" &&
    bad "the script tried 'docker run/pull/commit/build' after 'docker info' failed"
  grep -q '^sudo' "$FAKELOG/calls.log" && bad "sudo was called"
  check_last_err_line
}

t_up_to_date() {
  require_latest || return 0
  require_ref "$LATEST" fresh_install || return 0
  local imgs ctrs fp
  imgs=$(docker_images)
  ctrs=$(docker_containers)
  fp=$(install_fingerprint)
  run_script up_to_date
  expect_rc 0
  ((ELAPSED <= UPTODATE_MAX)) || bad "took $(dur "$ELAPSED"), the limit is ${UPTODATE_MAX}s"
  printed_has 'already installed and up to date' || bad "did not print 'already installed and up to date'"
  same_or_bad "$imgs" "$(docker_images)" "docker image ls -q changed (no image may be made)"
  same_or_bad "$ctrs" "$(docker_containers)" "docker ps -aq changed"
  local f
  for f in "${RUN_LOGS[@]}"; do
    [[ $f == *build-*.log ]] && bad "a build log was written ($f): it rebuilt"
  done
  check_install_untouched "$fp"
}

t_force_rebuild() {
  require_latest || return 0
  require_ref "$LATEST" fresh_install || return 0
  [[ -d $WORK/src && -d $WORK/build ]] ||
    note "no kept src/ and build/ from fresh_install: this will be a full build"
  local sha_before skia_inode
  sha_before=$(sha256sum <"$STATE_FILE")
  run_script force_rebuild --force --keep-build --keep-image
  expect_rc 0 || return 0
  local f built=0
  for f in "${RUN_LOGS[@]}"; do [[ $f == *build-*.log ]] && built=1; done
  ((built)) || bad "no build log was written during the run: it did not rebuild"
  [[ $(sha256sum <"$STATE_FILE") != "$sha_before" ]] || bad "the state file did not change: it did not reinstall"
  check_app_version "^Aseprite $(re_escape "${LATEST#v}")-dev$"
  [[ -d $WORK/src ]] || bad "src/ is gone despite --keep-build"
  [[ -d $WORK/build ]] || bad "build/ is gone despite --keep-build"
  check_one_opt_dir
  check_docker_after keep
  check_ownership
  check_no_partials
  if [[ -s $STATE/skia_inode ]]; then
    skia_inode=$(stat -c %i -- "$WORK/skia/skia-$(state_get skia_tag)" 2>/dev/null)
    [[ $skia_inode == "$(cat "$STATE/skia_inode")" ]] ||
      bad "the Skia folder was replaced: Skia was not reused (step 5)"
  fi
}

t_missing_lib() {
  require_install || return 0
  image_present "$BUILDER" || note "no kept builder image: the run makes one first"
  [[ -d $WORK/build ]] || note "no kept build: this will be a full build"
  local fp
  fp=$(install_fingerprint)
  RUN_ENV=("ASEPRITE_TEST_FAKE_MISSING_LIB=$MISSING_LIB")
  run_script missing_lib --force --keep-build --keep-image
  RUN_ENV=()
  expect_rc 8
  printed_has "$(re_escape "$MISSING_LIB")" || bad "the output does not name $MISSING_LIB"
  local family
  family=$(host_family)
  if [[ -n $family ]]; then
    grep -Eq "^hint: sudo $(hint_cmd_re "$family") [^ ]+( [^ ]+)*$" "$ERR" ||
      bad "no '$(hint_cmd "$family")' hint line on stderr for this $family host"
  fi
  grep '^hint:' "$ERR" | indent
  check_install_untouched "$fp"
  check_one_opt_dir
  check_docker_after keep
  check_no_partials
  check_ownership
  check_last_err_line
}

t_ref_old() {
  require_builder 'force_rebuild / missing_lib' || return 0
  require_latest || return 0
  if ! git ls-remote --exit-code --tags "$REPO_URL" "refs/tags/$OLD_REF" >/dev/null; then
    bad "tag $OLD_REF not found with git ls-remote"
    return 0
  fi
  local commit
  commit=$(tag_commit "$OLD_REF")
  run_script ref_old --ref "$OLD_REF" --yes
  expect_rc 0 || return 0
  logged_has 'Builder image already present' || bad "neither the output nor the log says 'Builder image already present'"
  check_app_version "^Aseprite ($(re_escape "${OLD_REF#v}")(-dev)?|1\.x-dev)$"  # v1.3.17 and older report the placeholder
  check_state "$OLD_REF" "$commit"
  check_one_opt_dir
  check_docker_after none
  check_ownership
  check_clean_work_after_success
  state_get skia_tag >"$STATE/old_skia_tag"
  note "Skia tag for $OLD_REF: $(cat "$STATE/old_skia_tag"); for $LATEST: $(cat "$STATE/latest_skia_tag" 2>/dev/null || echo '?')"
}

t_update_back() {
  require_latest || return 0
  require_ref "$OLD_REF" ref_old || return 0
  local old_skia commit
  old_skia=$(state_get skia_tag)
  commit=$(tag_commit "$LATEST")
  run_script update_back
  expect_rc 0 || return 0
  check_app_version "^Aseprite $(re_escape "${LATEST#v}")-dev$"
  check_state "$LATEST" "$commit"
  check_one_opt_dir
  check_docker_after none
  check_ownership
  [[ -e $WORK/src ]] && bad "src/ still exists after a run without --keep-build (step 9)"
  [[ -e $WORK/build ]] && bad "build/ still exists after a run without --keep-build (step 9)"
  check_clean_work_after_success
  if [[ $old_skia != "$(state_get skia_tag)" ]]; then
    note "$OLD_REF used Skia $old_skia, $LATEST uses $(state_get skia_tag)"
    [[ -e $WORK/skia/skia-$old_skia ]] && bad "the old Skia folder skia-$old_skia was not removed"
  else
    note "$OLD_REF and $LATEST use the same Skia tag ($old_skia); nothing to remove"
  fi
}

interrupt_killer() { # pidfile events [setup|build]: SIGINT the script's group once that container runs
  local pidfile=$1 events=$2 kind=${3:-setup} pid='' pg i deadline
  for ((i = 0; i < 200; i++)); do
    [[ -s $pidfile ]] && break
    sleep 0.1
  done
  pid=$(cat "$pidfile" 2>/dev/null)
  [[ -n $pid ]] || {
    echo "nopid" >>"$events"
    return
  }
  pg=$(ps -o pgid= -p "$pid" | tr -d ' ')
  if [[ $pg != "$pid" ]]; then
    echo "notleader $pg" >>"$events"
    return
  fi
  deadline=$((SECONDS + 1200))
  until [[ -n $(docker ps -q --filter "name=aseprite-installer-$kind-") ]]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "exited-early" >>"$events"
      return
    fi
    if ((SECONDS > deadline)); then
      echo "no-setup-container" >>"$events"
      kill -TERM -- "-$pid" 2>/dev/null
      return
    fi
    sleep 0.5
  done
  echo "seen $(date +%s)" >>"$events"
  sleep 3
  echo "sigint $(date +%s)" >>"$events"
  kill -INT -- "-$pid" 2>/dev/null
  for ((i = 0; i < 180; i++)); do
    kill -0 "$pid" 2>/dev/null || return
    sleep 1
  done
  echo "term $(date +%s)" >>"$events"
  kill -TERM -- "-$pid" 2>/dev/null
  sleep 20
  if kill -0 "$pid" 2>/dev/null; then
    echo "kill $(date +%s)" >>"$events"
    kill -KILL -- "-$pid" 2>/dev/null
  fi
}

INT_KIND=setup INT_DOCKER=none
INT_OPTS=()

t_interrupt() {
  INT_KIND=setup INT_DOCKER=none INT_OPTS=()
  require_install || return 0
  if ((QUICK)) && image_present "$BUILDER"; then
    # --quick skips update_back, which normally removes the image kept by
    # force_rebuild/missing_lib; that image is this suite's own.
    log "interrupt (--quick): removing the builder image kept by earlier tests"
    docker image rm "$BUILDER" >/dev/null 2>&1 || true
  fi
  if image_present "$BUILDER"; then
    bad "needs no builder image, so that a setup container runs (state after update_back); $BUILDER exists"
    return 0
  fi
  interrupt_core
}

# Interrupt the long-running build container, not just the setup one.
t_interrupt_build() {
  INT_KIND=build INT_DOCKER=keep INT_OPTS=(--keep-image)
  require_install || return 0
  image_present "$BUILDER" || {
    bad "needs the kept builder image (made by break_skia), so that the build container starts at once"
    return 0
  }
  interrupt_core
}

interrupt_core() {
  local fp pidfile events killer t_end t_int delay
  fp=$(install_fingerprint)
  new_run_files interrupt
  pidfile=$RUN_BASE.pid
  events=$RUN_BASE.events
  : >"$events"
  log "interrupt: running install-aseprite.sh --force in its own process group;" \
    "SIGINT goes to that group 3 s after the setup container appears"
  interrupt_killer "$pidfile" "$events" "$INT_KIND" &
  killer=$!
  # setsid gives the script its own session and process group, like a terminal job, so
  # the SIGINT reaches the script and its docker client but never this suite. It runs in
  # the foreground: a background job would start with SIGINT ignored and could not trap it.
  script_cmd
  # shellcheck disable=SC2016 # the inner bash expands $$, $1 and $@ itself
  setsid -w bash -c 'echo "$$" >"$1"; shift; exec "$@"' _ "$pidfile" \
    "${CMD[@]}" --force "${INT_OPTS[@]}" </dev/null >"$OUT" 2>"$ERR"
  RC=$?
  t_end=$(date +%s)
  wait "$killer" 2>/dev/null
  save_run_logs
  check_guard
  note "events: $(tr '\n' ' ' <"$events")"
  sed 's/^/| /' "$OUT" | tail -n 12 | indent
  if grep -q '^exited-early' "$events"; then
    bad "the script exited ($RC) before a $INT_KIND container appeared; nothing to interrupt"
    show_tail
    return 0
  fi
  if grep -Eq '^(nopid|notleader)' "$events"; then
    bad "could not put the script in its own process group; SIGINT was not sent"
    return 0
  fi
  t_int=$(sed -n 's/^sigint //p' "$events")
  if [[ -n $t_int ]]; then
    delay=$((t_end - t_int))
    log "interrupt: exit $RC, ${delay}s after SIGINT"
    ((delay <= INT_MAX)) || bad "the script took ${delay}s to exit after SIGINT (limit ${INT_MAX}s): it did not stop the container"
  fi
  grep -Eq '^(term|kill) ' "$events" && bad "the script ignored SIGINT and had to be stopped with SIGTERM/SIGKILL"
  ((RC == 130)) || {
    bad "exit code $RC, expected 130"
    show_tail
  }
  check_docker_after "$INT_DOCKER"
  check_no_partials
  check_install_untouched "$fp"
  check_ownership
  check_last_err_line
}

t_break_skia() {
  require_install || return 0
  local fp
  fp=$(install_fingerprint)
  RUN_ENV=(ASEPRITE_TEST_BREAK_SKIA=1)
  run_script break_skia --force --keep-image
  RUN_ENV=()
  expect_rc 7
  check_install_untouched "$fp"
  check_one_opt_dir
  check_docker_after keep
  [[ -d $WORK/src && -d $WORK/build ]] || bad "src/ or build/ was removed; a failed build keeps them for inspection"
  check_no_partials
  check_ownership
  check_last_err_line
}

t_uninstall() {
  if [[ ! -f $MANIFEST ]]; then
    bad "needs an install with a manifest (from fresh_install ... break_skia); $MANIFEST does not exist"
    return 0
  fi
  local paths=() p left had_image=0
  mapfile -t paths < <(grep -v '^$' "$MANIFEST")
  image_present "$BUILDER" && had_image=1
  run_script uninstall --uninstall --yes
  expect_rc 0
  for p in "${paths[@]}"; do
    [[ -e $p || -L $p ]] && bad "manifest path still exists: $p"
  done
  for p in "$PREFIX/opt/aseprite" "$PREFIX/bin/aseprite" "$PREFIX/bin/aseprite-thumbnailer" \
    "$PREFIX/share/applications/aseprite.desktop" "$PREFIX/share/mime/packages/aseprite.xml" \
    "$PREFIX/share/thumbnailers/aseprite.thumbnailer"; do
    [[ -e $p || -L $p ]] && bad "still installed: $p"
  done
  left=$(find "$PREFIX/share/icons/hicolor" -path '*/apps/aseprite.png' 2>/dev/null)
  [[ -z $left ]] || bad "icons still installed: $(tr '\n' ' ' <<<"$left")"
  check_config_untouched
  printed_has '\.config/aseprite' || bad "the output does not mention that ~/.config/aseprite was kept (uninstall)"
  [[ -d $WORK ]] || bad "the work folder was removed without --purge"
  ((had_image)) && ! image_present "$BUILDER" && bad "the builder image was removed without --purge"
  note "left under the prefix (desktop caches may remain):"
  find "$PREFIX" -mindepth 1 ! -type d -printf '%P\n' 2>/dev/null | head -n 30 | indent
}

t_uninstall_again() {
  if [[ -e $PREFIX/opt/aseprite ]]; then
    bad "needs nothing installed (state after uninstall); $PREFIX/opt/aseprite exists"
    return 0
  fi
  run_script uninstall_again --uninstall --yes
  expect_rc 0
  printed_has '[Nn]ot installed' || bad "did not print 'not installed'"
}

t_purge() {
  require_builder break_skia || return 0
  if [[ ! -d $WORK ]]; then
    bad "needs the work folder $WORK (from the earlier tests); it does not exist"
    return 0
  fi
  run_script purge --uninstall --purge --yes
  expect_rc 0
  [[ -e $WORK ]] && bad "the work folder $WORK still exists"
  check_docker_after none
}

t_containment() {
  local found
  [[ -e $HOME/.cache/aseprite-installer ]] && bad "$HOME/.cache/aseprite-installer exists"
  found=$(compgen -G "$HOME/deps/skia-*" || true)
  [[ -n $found ]] && bad "found $found"

  found=$(tmp_find \
    \( -iname '*aseprite*' -o -iname '*skia*' -o -name 'install-aseprite*' \) -newer "$STATE/stamp" -print 2>/dev/null)
  if [[ -n $found ]]; then
    bad "files in /tmp made or changed during the run: $(tr '\n' ' ' <<<"$found")"
  fi
  if [[ -s $STATE/tmp-named ]]; then
    note "matching names in /tmp that existed before the run (not counted):"
    indent <"$STATE/tmp-named"
  fi

  same_or_bad "$(cat "$STATE/dotwork")" "$(tree_snapshot "$REPO/.work")" \
    "$REPO/.work changed although ASEPRITE_WORK_DIR was set"
  same_or_bad "$(cat "$STATE/default-install")" "$(default_install_listing)" \
    "the default install paths under ~/.local changed although ASEPRITE_PREFIX was set"
  check_config_untouched
  same_or_bad "$(cat "$STATE/images")" "$(docker_images)" "docker image ls -q differs from the start of the run"
  same_or_bad "$(cat "$STATE/containers")" "$(docker_containers)" "docker ps -aq differs from the start of the run"
  [[ -e $WORK ]] && note "the work folder $WORK still exists (purge did not run or failed)"

  log "containment: files under \$HOME changed during the run, outside the repo (report only, not pass/fail):"
  local n=0 f
  while IFS= read -r f; do
    printf '#   changed: %s\n' "$f"
    n=$((n + 1))
  done < <(find "$HOME" -xdev -path "$REPO" -prune -o ! -type d -newer "$STATE/stamp" -print 2>/dev/null | LC_ALL=C sort)
  log "containment: $n changed file(s) under \$HOME outside the repo"
  log "containment: files of this user in /tmp changed during the run (report only):"
  tmp_find -user "$(id -u)" ! -type d -newer "$STATE/stamp" -print \
    2>/dev/null | sed 's/^/#   changed: /'
}

# ------------------------------------------------------------- host family

host_family() { # the hint family for this host, from /etc/os-release (empty if unknown)
  local id='' like='' w
  [[ -r /etc/os-release ]] || return 0
  # shellcheck source=/dev/null
  id=$(. /etc/os-release && echo "${ID:-}")
  # shellcheck source=/dev/null
  like=$(. /etc/os-release && echo "${ID_LIKE:-}")
  for w in $id $like; do
    case $w in
      fedora | rhel) echo fedora; return ;;
      debian | ubuntu) echo debian; return ;;
      arch) echo arch; return ;;
      suse | opensuse*) echo suse; return ;;
    esac
  done
}

hint_cmd() {
  case $1 in
    fedora) echo 'dnf install' ;; debian) echo 'apt install' ;;
    arch) echo 'pacman -S --needed' ;; suse) echo 'zypper install' ;;
  esac
}
hint_cmd_re() { re_escape "$(hint_cmd "$1")"; }

# ======================================================================= main

usage() {
  echo "usage: tests/e2e.sh [--list] [--fresh] [--quick] [test...]"
  echo "  --quick  skip the two extra full builds (${QUICK_SKIP[*]})"
  echo "tests (always run in this order): ${TESTS[*]}"
}

list_tests() {
  local t
  echo "e2e tests, in run order (cost: quick, short or full build):"
  for t in "${TESTS[@]}"; do
    printf '  %-16s %-34s %s\n' "$t" "[${COST[$t]}]" "${DESC[$t]}"
    printf '  %-16s %-34s needs: %s\n' '' '' "${NEEDS[$t]}"
  done
}

check_tmpdir_sentinel() {
  local left
  left=$(find "$TMPDIR_SENTINEL" -mindepth 1 2>/dev/null | head -5 | tr '\n' ' ')
  if [[ -n $left ]]; then
    bad "the script wrote temporary files outside its work folder (TMPDIR): $left"
    rm -rf -- "${TMPDIR_SENTINEL:?}"/* "${TMPDIR_SENTINEL:?}"/.[!.]* 2>/dev/null || true
  fi
}

fresh_start() {
  local c
  c=$(script_containers | tr '\n' ' ')
  if [[ -n $c ]]; then
    echo "FAIL setup: script containers exist from an earlier run: $c(remove them with docker rm -f)"
    return 1
  fi
  if image_present "$BUILDER"; then
    echo "FAIL setup: the builder image $BUILDER exists from an earlier run; a fresh run must start" \
      "without it (docker image rm $BUILDER)"
    return 1
  fi
  # An aborted earlier run may have left ubuntu:24.04 that it pulled. Its marker
  # says so; remove that image now, or the baseline would count it as "present before".
  if [[ -e $E2E/work/pulled-base ]] && image_present ubuntu:24.04; then
    log "removing ubuntu:24.04, pulled by an earlier aborted run (its pulled-base marker is still there)"
    docker image rm ubuntu:24.04 >/dev/null 2>&1 ||
      { echo "FAIL setup: could not remove ubuntu:24.04 left by an earlier run"; return 1; }
  fi
  if [[ -e $E2E ]]; then
    log "removing the previous run's $E2E"
    rm -rf -- "${E2E:?}"
  fi
  mkdir -p -- "$E2E"
  take_baseline
}

on_interrupt() {
  echo
  log "interrupted"
  [[ -n $CUR ]] && echo "FAIL $CUR: interrupted"
  summary
  exit 130
}

main() {
  local selected=() fresh=0 quick=0 t
  declare -A want=() skip=()
  for t in "$@"; do
    case $t in
      --list) list_tests; return 0 ;;
      --fresh) fresh=1 ;;
      --quick) quick=1 QUICK=1 ;;
      -h | --help) usage; return 0 ;;
      -*) usage >&2; return 2 ;;
      *)
        if [[ -z ${DESC[$t]+x} ]]; then
          echo "unknown test: $t" >&2
          usage >&2
          return 2
        fi
        want[$t]=1
        ;;
    esac
  done
  if ((quick)); then
    for t in "${QUICK_SKIP[@]}"; do skip[$t]=1; done
  fi
  if ((${#want[@]} == 0)); then
    for t in "${TESTS[@]}"; do [[ -n ${skip[$t]:-} ]] || selected+=("$t"); done
    fresh=1
  else
    for t in "${TESTS[@]}"; do [[ -n ${want[$t]:-} ]] && selected+=("$t"); done
  fi

  mkdir -p -- "$REPO/.test"
  exec 9>"$REPO/.test/e2e.lock"
  if ! flock -n 9; then
    echo "FAIL setup: another tests/e2e.sh run holds $REPO/.test/e2e.lock"
    return 1
  fi
  if [[ ! -x $SCRIPT ]]; then
    echo "FAIL setup: $SCRIPT is missing or not executable"
    summary
    return 1
  fi
  if ! docker info >/dev/null 2>&1; then
    echo "FAIL setup: docker is not usable by this user; the e2e tests need it"
    return 1
  fi

  trap on_interrupt INT
  log "e2e: ${#selected[@]} test(s): ${selected[*]}"
  if ((fresh)); then
    fresh_start || {
      FAILED=1
      summary
      return 1
    }
  elif [[ ! -f $STATE/stamp ]]; then
    log "no baseline in $STATE yet: taking it now"
    mkdir -p -- "$E2E"
    take_baseline
  else
    log "reusing the baseline taken $(date -r "$STATE/stamp" '+%F %T') ($BASE was $(cat "$STATE/base") then)"
  fi
  setup_guard

  for t in "${selected[@]}"; do
    begin_test "$t"
    "t_$t"
    end_test
    CUR=''
  done
  summary
  ((FAILED == 0))
}

main "$@"
