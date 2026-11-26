#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# install-aseprite.sh - build Aseprite from source inside a Docker container
# (ubuntu:24.04) and install it for the current user, on any x86_64 Linux
# that uses glibc. Running it again updates to the newest stable release.
#
# The host stays clean: no sudo, no host packages, every working file in
# .work/ next to this script. See README.md for the details.
#
# The script runs main only when executed. When it is sourced (by the tests,
# or inside the build container) it only defines constants and functions:
# no output, no traps, no shell option changes.
#
# shellcheck disable=SC2317,SC2329  # functions called indirectly (traps, container, tests)

# ================================================================ constants

SCRIPT_VERSION="1.0.0"
SCRIPT_NAME="install-aseprite.sh"
TOTAL_STEPS=9
REPO_URL="https://github.com/aseprite/aseprite.git"
BASE_IMAGE="ubuntu:24.04"
MIN_GLIBC="2.39"     # glibc of BASE_IMAGE: change both together

# Runtime libraries the binary loads from the host (README.md, "Runtime
# libraries"), with the package that provides each one, per distro family.
# Checked against the built binary (readelf -d); libXi.so.6 is loaded with
# dlopen for pen input. Package names were checked in real containers (Arch
# splits libstdc++ and libgcc out
# of gcc-libs; openSUSE ships libGL.so.1 in libglvnd).
#   soname|dnf (Fedora/RHEL)|apt (Debian/Ubuntu)|pacman (Arch)|zypper (openSUSE)
RUNTIME_LIBS=(
  "libstdc++.so.6|libstdc++|libstdc++6|libstdc++|libstdc++6"
  "libgcc_s.so.1|libgcc|libgcc-s1|libgcc|libgcc_s1"
  "libX11.so.6|libX11|libx11-6|libx11|libX11-6"
  "libxcb.so.1|libxcb|libxcb1|libxcb|libxcb1"
  "libXext.so.6|libXext|libxext6|libxext|libXext6"
  "libXcursor.so.1|libXcursor|libxcursor1|libxcursor|libXcursor1"
  "libXi.so.6|libXi|libxi6|libxi|libXi6"
  "libXrandr.so.2|libXrandr|libxrandr2|libxrandr|libXrandr2"
  "libGL.so.1|libglvnd-glx|libgl1|libglvnd|libglvnd"
  "libfontconfig.so.1|fontconfig|libfontconfig1|fontconfig|libfontconfig1"
)
LDCONFIG_CANDIDATES=(ldconfig /sbin/ldconfig /usr/sbin/ldconfig)

BUILDER_IMAGE="aseprite-installer-builder:ubuntu-24.04"
CONTAINER_PREFIX="aseprite-installer"
# Installed only in the builder image (the Ubuntu line of Aseprite's INSTALL.md, plus
# git, curl and ca-certificates for the clone and the Skia download).
CONTAINER_PACKAGES=(g++ clang cmake ninja-build unzip libx11-dev libxcursor-dev libxi-dev
  libxrandr-dev libgl1-mesa-dev libfontconfig1-dev git curl ca-certificates ccache)

MIN_FREE_WORK_KIB=$((4 * 1024 * 1024))  # 4 GiB under the work folder
MIN_FREE_PREFIX_KIB=$((500 * 1024))     # 500 MiB under the prefix
MIN_FREE_DOCKER_KIB=$((3 * 1024 * 1024)) # 3 GiB under Docker's root folder
LOG_KEEP=5

SKIA_ZIP="Skia-Linux-Release-x64.zip"
SKIA_PINNED_TAG="m124-08a5439a6b"
SKIA_PINNED_SHA256="a327e89b244f24cecaa34eb37544bae00d447b96c583d26ed29d6a3ad2e8a8b8"
MIN_GLIBCXX="3.4.32" # libstdc++ of GCC 13 in BASE_IMAGE: change with BASE_IMAGE
# Libraries that come with glibc itself; never "surprising" in the build check.
GLIBC_SONAMES=" libc.so.6 libm.so.6 libdl.so.2 libpthread.so.0 librt.so.1 libresolv.so.2 libutil.so.1 ld-linux-x86-64.so.2 "

# ============================================================ external tools
# Every external command the script depends on goes through one of these,
# so the unit tests can replace them after sourcing.

x_docker() { command docker "$@"; }
x_git() { GIT_TERMINAL_PROMPT=0 command git "$@"; }
x_uname() { command uname "$@"; }
x_getconf() { command getconf "$@"; }
x_ldd() { command ldd "$@"; }
x_id() { command id "$@"; }
x_df() { command df "$@"; }
x_flock() { command flock "$@"; }
x_date() { command date "$@"; }
x_sleep() { command sleep "$@"; }
x_nproc() { command nproc; }
x_curl() { command curl "$@"; }
x_sha256sum() { command sha256sum "$@"; }
x_unzip() { command unzip "$@"; }
x_cmake() { command cmake "$@"; }
x_ninja() { command ninja "$@"; }
x_readelf() { command readelf "$@"; }
x_objdump() { command objdump "$@"; }
is_root() { [[ ${EUID:-$(command id -u)} -eq 0 ]]; }
stdout_is_tty() { [[ -t 1 ]]; }
stderr_is_tty() { [[ -t 2 ]]; }
stdin_is_tty() { [[ -t 0 ]]; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }
bash_major() { printf '%s' "${BASH_VERSINFO[0]}"; }
selinux_enabled() { [[ -e /sys/fs/selinux/enforce ]]; }
os_release_file() { printf '%s' /etc/os-release; }

# x_ldconfig ARGS: run the first ldconfig candidate that works.
x_ldconfig() {
  local c out
  for c in "${LDCONFIG_CANDIDATES[@]}"; do
    command -v "$c" >/dev/null 2>&1 || continue
    if out=$(command "$c" "$@" 2>/dev/null); then
      printf '%s\n' "$out"
      return 0
    fi
  done
  return 127
}

# ================================================================== globals

# init_globals: reset every piece of run state to its default. main and
# container_build call it; the tests call it after sourcing.
init_globals() {
  ACTION="install"
  OPT_REF="" OPT_FORCE=0 OPT_YES=0 OPT_KEEP_BUILD=0 OPT_KEEP_IMAGE=0
  OPT_JOBS="" OPT_UNINSTALL=0 OPT_PURGE=0 DRY_RUN=0 VERBOSE=0
  CURRENT_STEP=0 CURRENT_STEP_NAME="Preflight" STEP_TOTAL=$TOTAL_STEPS
  LOG_FILE="" LOG_BUFFER=()
  COLOR_OUT=0 COLOR_ERR=0
  IN_CONTAINER=0
  WORK="" PREFIX="" RUN_STAMP="" JOBS=""
  LOCK_HELD=0 SWAP_OLD=0 DOCKER_PID=""
  CONTAINERS=() PARTIALS=()
  DOCKER_ROOT_DIR="" DOCKER_SECURITY=""
  BUILD_REF="" REF_KIND="" REF_COMMIT="" LATEST_TAG=""
  BUILD_CONTAINER="" BUILD_RUN_CMD=() BUILD_RUNNING=0
  IMAGE_STEP_REACHED=0 IMAGES_HANDLED=0 IMAGE_STATUS=""
  SKIA_TAG="" BUILT_VERSION_LINE="" BUILD_SECONDS=0 CONTAINER_SECONDS=0 INSTALLED=()
}

# ================================================================== output

_paint() { # enabled code text
  if [[ $1 == 1 ]]; then printf '\033[%sm%s\033[0m' "$2" "$3"; else printf '%s' "$3"; fi
}

# log TEXT: write a line to the run log, or keep it until the log is open.
log() {
  if [[ -n ${LOG_FILE:-} ]]; then
    { printf '%s\n' "$*" >>"$LOG_FILE"; } 2>/dev/null || true
  else
    LOG_BUFFER+=("$*")
  fi
}

info() {
  printf '   -> %s\n' "$*"
  log "   -> $*"
}

warn() {
  printf '%s %s\n' "$(_paint "${COLOR_ERR:-0}" '1;33' 'warning:')" "$*" >&2
  log "warning: $*"
}

err() {
  printf '%s %s\n' "$(_paint "${COLOR_ERR:-0}" '1;31' 'error:')" "$*" >&2
  log "error: $*"
}

# open_log PATH: start writing the run log, with any lines kept so far.
open_log() {
  LOG_FILE=$1
  : >>"$LOG_FILE"
  if ((${#LOG_BUFFER[@]})); then
    printf '%s\n' "${LOG_BUFFER[@]}" >>"$LOG_FILE"
  fi
  LOG_BUFFER=()
}

# quote_cmd ARGS: a command line that can be pasted back into a shell.
quote_word() {
  if [[ $1 =~ ^[A-Za-z0-9_./:=@%+,-]+$ ]]; then
    printf '%s' "$1"
  else
    printf "'%s'" "${1//\'/\'\\\'\'}"
  fi
}

quote_cmd() {
  local out="" w
  for w in "$@"; do
    out+="${out:+ }$(quote_word "$w")"
  done
  printf '%s' "$out"
}

# run CMD...: log "+ CMD", then run it with its output in the run log (and
# on the terminal with --verbose). With --dry-run only print it.
run() { run_into "${LOG_FILE:-}" "$@"; }

# run_into LOGFILE CMD...: like run, but the output goes to LOGFILE.
run_into() {
  local target=$1 shown
  shift
  shown=$(quote_cmd "${1#x_}" "${@:2}")
  log "+ $shown"
  if ((${DRY_RUN:-0})); then
    printf '   [dry-run] %s\n' "$shown"
    return 0
  fi
  if [[ -z $target ]]; then
    "$@"
    return
  fi
  if ((${VERBOSE:-0})); then
    "$@" 2>&1 | tee -a "$target"
    return "${PIPESTATUS[0]}"
  fi
  "$@" >>"$target" 2>&1
}

# run_waited LOGFILE CMD...: like run_into, but CMD runs in the background
# and the shell waits for it. A signal then reaches the trap at once (bash
# runs traps only between commands, and a container's PID 1 ignores the
# forwarded SIGINT); the trap removes the container. Returns CMD's status.
# An empty LOGFILE leaves the output on the terminal.
run_waited() {
  local target=$1 shown rc=0
  shift
  shown=$(quote_cmd "${1#x_}" "${@:2}")
  log "+ $shown"
  if ((${DRY_RUN:-0})); then
    printf '   [dry-run] %s\n' "$shown"
    return 0
  fi
  if [[ -z $target ]]; then
    "$@" &
  elif ((${VERBOSE:-0})); then
    { "$@" 2>&1 | tee -a "$target"; } &
  else
    "$@" >>"$target" 2>&1 &
  fi
  DOCKER_PID=$!
  wait "$DOCKER_PID" || rc=$?
  DOCKER_PID=""
  return "$rc"
}

# die CODE MESSAGE: print an error and exit with CODE. The EXIT trap (when
# main set it) adds the last line naming the step and the log.
die() {
  local code=$1
  shift
  err "$*"
  exit "$code"
}

# ======================================================= usage and options

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [options]

Build Aseprite from source in a Docker container (ubuntu:24.04) and install
it for the current user. With no options, installs or updates to the latest
stable release.

Options:
  --ref <ref>       Build this tag or branch instead of the latest stable tag
                    (e.g. v1.3.17, main).
  --force           Rebuild and reinstall even if the installed version matches.
  --yes, -y         Answer yes to every prompt (today only the uninstall one).
  --keep-build      Keep the source and build folders after a successful install.
  --keep-image      Keep the builder image, so the next build skips making it.
                    --uninstall --purge removes it.
  --jobs <n>, -j <n>
                    Parallel build jobs, passed to ninja -j (default: nproc).
  --uninstall       Remove the installed app and desktop files.
  --purge           With --uninstall, also delete the work folder and the
                    builder image.
  --dry-run         Print each step and command it would run; change nothing.
  --verbose, -v     Also stream build output to the terminal.
  --help, -h        Print this help and exit.
  --version         Print the script's version and exit.

Environment:
  ASEPRITE_PREFIX     Install root (default: \$HOME/.local).
  ASEPRITE_WORK_DIR   Work folder (default: .work next to this script).
EOF
}

# usage_error MESSAGE: bad command line -> usage on stderr, exit 2.
usage_error() {
  usage >&2
  die 2 "$*"
}

# parse_args ARGS...: set the OPT_* globals and ACTION. --help and --version
# win over everything else, wherever they are.
parse_args() {
  local a
  for a in "$@"; do
    case $a in
      --help | -h) ACTION="help"; return 0 ;;
      --version) ACTION="version"; return 0 ;;
    esac
  done
  while (($#)); do
    case $1 in
      --ref)
        [[ $# -ge 2 && -n $2 && $2 != -* ]] || usage_error "--ref needs a tag or branch name"
        OPT_REF=$2
        shift
        ;;
      --ref=*)
        OPT_REF=${1#--ref=}
        [[ -n $OPT_REF && $OPT_REF != -* ]] || usage_error "--ref needs a tag or branch name"
        ;;
      --jobs | -j)
        [[ $# -ge 2 ]] || usage_error "$1 needs a number"
        OPT_JOBS=$2
        shift
        ;;
      --jobs=*)
        OPT_JOBS=${1#--jobs=}
        [[ -n $OPT_JOBS ]] || usage_error "--jobs needs a number"
        ;;
      --force) OPT_FORCE=1 ;;
      --yes | -y) OPT_YES=1 ;;
      --keep-build) OPT_KEEP_BUILD=1 ;;
      --keep-image) OPT_KEEP_IMAGE=1 ;;
      --uninstall) OPT_UNINSTALL=1 ;;
      --purge) OPT_PURGE=1 ;;
      --dry-run) DRY_RUN=1 ;;
      --verbose | -v) VERBOSE=1 ;;
      *) usage_error "unknown option: $1" ;;
    esac
    shift
  done
  if [[ -n $OPT_JOBS && ! $OPT_JOBS =~ ^[1-9][0-9]*$ ]]; then
    usage_error "--jobs needs a positive whole number, not '$OPT_JOBS'"
  fi
  ((OPT_PURGE == 0 || OPT_UNINSTALL == 1)) || usage_error "--purge only works together with --uninstall"
  ((OPT_UNINSTALL == 0)) || ACTION="uninstall"
  return 0
}

# ==================================================================== paths

# script_path: absolute path of this file, symlinks resolved. BASH_SOURCE
# (not the current folder) decides, so the default work folder is always
# next to the real script.
script_path() {
  local s=${BASH_SOURCE[0]}
  readlink -f -- "$s" 2>/dev/null || printf '%s' "$s"
}

script_dir() {
  local p
  p=$(script_path)
  printf '%s' "${p%/*}"
}

# normalize_path PATH: collapse repeated slashes and drop trailing ones.
normalize_path() {
  local p=$1
  while [[ $p == *//* ]]; do p=${p//\/\//\/}; done
  while [[ $p == */ && $p != / ]]; do p=${p%/}; done
  printf '%s' "$p"
}

# check_path_value NAME PATH KIND: exit 2 unless PATH is a safe absolute
# path. KIND is "work" or "prefix".
check_path_value() {
  local name=$1 p=$2 kind=$3 c
  [[ $p == /* ]] || die 2 "$name must be an absolute path, not '$p'"
  [[ $p != *[[:cntrl:]]* ]] || die 2 "$name must not contain control characters"
  [[ $p != / ]] || die 2 "$name must not be /"
  [[ "$p/" != *"/./"* && "$p/" != *"/../"* ]] || die 2 "$name must not contain . or .. folders: $p"
  if [[ $kind == work ]]; then
    [[ $p != *:* ]] || die 2 "$name must not contain ':' (Docker cannot mount it): $p"
    [[ -z ${HOME:-} || $p != "$(normalize_path "$HOME")" ]] || die 2 "$name must not be your home folder"
  else
    for c in ' ' '"' "'" '`' '$' "\\" '%'; do
      [[ $p != *"$c"* ]] || die 2 "$name must not contain spaces or any of \" ' \` \$ \\ % (the desktop files cannot quote them): $p"
    done
    [[ $p != *[[:space:]]* ]] || die 2 "$name must not contain spaces: $p"
  fi
}

# resolve_paths: set WORK, PREFIX and every derived path (README.md, "Paths and overrides").
resolve_paths() {
  local work=${ASEPRITE_WORK_DIR:-} prefix=${ASEPRITE_PREFIX:-}
  [[ -n $work ]] || work="$(script_dir)/.work"
  if [[ -z $prefix ]]; then
    [[ -n ${HOME:-} ]] || die 2 "HOME is not set; set ASEPRITE_PREFIX to an absolute path"
    prefix="$HOME/.local"
  fi
  WORK=$(normalize_path "$work")
  PREFIX=$(normalize_path "$prefix")
  check_path_value ASEPRITE_WORK_DIR "$WORK" work
  check_path_value ASEPRITE_PREFIX "$PREFIX" prefix
  APP_DIR="$PREFIX/opt/aseprite"
  RECORDS_DIR="$APP_DIR/.aseprite-installer"
  STATE_FILE="$RECORDS_DIR/state"
  MANIFEST_FILE="$RECORDS_DIR/manifest"
  BIN="$APP_DIR/aseprite"
  BIN_LINK="$PREFIX/bin/aseprite"
  THUMB_BIN="$PREFIX/bin/aseprite-thumbnailer"
  APPS_DIR="$PREFIX/share/applications"
  DESKTOP_FILE="$APPS_DIR/aseprite.desktop"
  ICON_ROOT="$PREFIX/share/icons/hicolor"
  MIME_ROOT="$PREFIX/share/mime"
  MIME_FILE="$MIME_ROOT/packages/aseprite.xml"
  THUMB_ENTRY="$PREFIX/share/thumbnailers/aseprite.thumbnailer"
}

# tilde PATH: show a path under $HOME as ~/...
tilde() {
  local p=$1
  if [[ -n ${HOME:-} && $p == "$HOME"/* ]]; then
    # shellcheck disable=SC2088  # a literal ~ for display
    p="~/${p#"$HOME"/}"
  fi
  printf '%s' "$p"
}

# ================================================== text and version helpers

first_line() { printf '%s' "${1%%$'\n'*}"; }

trim() {
  local s=$1
  s=${s#"${s%%[![:space:]]*}"}
  s=${s%"${s##*[![:space:]]}"}
  printf '%s' "$s"
}

# version_ge A B: true when version A >= version B, as sort -V orders them.
version_ge() {
  [[ $1 == "$2" ]] && return 0
  local -a sorted
  mapfile -t sorted < <(printf '%s\n%s\n' "$1" "$2" | LC_ALL=C sort -V)
  [[ ${sorted[0]} == "$2" ]]
}

# tag_names_from_ls_remote: "<sha>\trefs/tags/<name>" lines -> names.
tag_names_from_ls_remote() {
  local _sha ref
  while IFS=$'\t' read -r _sha ref; do
    [[ $ref == refs/tags/* ]] && printf '%s\n' "${ref#refs/tags/}"
  done
  return 0
}

# pick_stable_tag: tag names on stdin -> the newest stable one
# (^v[0-9]+(\.[0-9]+)+$, sorted with sort -V). Fails when there is none.
pick_stable_tag() {
  local t re='^v[0-9]+(\.[0-9]+)+$'
  local -a tags=()
  while IFS= read -r t; do
    [[ $t =~ $re ]] && tags+=("$t")
  done
  ((${#tags[@]})) || return 1
  printf '%s\n' "${tags[@]}" | LC_ALL=C sort -V | tail -n 1
}

# pick_ref REF: ls-remote output on stdin -> "tag <sha>" or "branch <sha>".
# A peeled tag (annotated) wins over the tag object, a tag over a branch.
pick_ref() {
  local want=$1 sha name peeled="" tag="" head="" re='^[0-9a-f]{40}([0-9a-f]{24})?$'
  while IFS=$'\t' read -r sha name; do
    [[ $sha =~ $re ]] || continue
    if [[ $name == "refs/tags/$want^{}" ]]; then
      peeled=$sha
    elif [[ $name == "refs/tags/$want" ]]; then
      tag=$sha
    elif [[ $name == "refs/heads/$want" ]]; then
      head=$sha
    fi
  done
  if [[ -n $peeled ]]; then
    printf 'tag %s' "$peeled"
  elif [[ -n $tag ]]; then
    printf 'tag %s' "$tag"
  elif [[ -n $head ]]; then
    printf 'branch %s' "$head"
  else
    return 1
  fi
}

# resolve_ref REF: set REF_KIND (tag|branch) and REF_COMMIT, or exit 3.
resolve_ref() {
  local ref=$1 out picked
  if ! out=$(x_git ls-remote "$REPO_URL" "refs/tags/$ref^{}" "refs/tags/$ref" "refs/heads/$ref" 2>&1); then
    die 3 "Could not list refs from $REPO_URL: $(first_line "$out")"
  fi
  picked=$(pick_ref "$ref" <<<"$out") || die 3 "No tag or branch named $ref"
  REF_KIND=${picked%% *}
  REF_COMMIT=${picked#* }
}

# latest_stable_tag: set LATEST_TAG to the newest stable tag, or exit 3.
latest_stable_tag() {
  local out
  if ! out=$(x_git ls-remote --tags --refs "$REPO_URL" 2>&1); then
    die 3 "Could not list tags from $REPO_URL: $(first_line "$out")"
  fi
  LATEST_TAG=$(tag_names_from_ls_remote <<<"$out" | pick_stable_tag) ||
    die 3 "No stable release tag found in $REPO_URL"
}

# read_skia_tag FILE: first line, whitespace trimmed (laf/misc/skia-tag.txt).
read_skia_tag() {
  local line=""
  [[ -f $1 && -r $1 ]] || return 1
  IFS= read -r line <"$1" || [[ -n $line ]] || return 1
  line=$(trim "$line")
  [[ $line =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1
  printf '%s' "$line"
}

# parse_cmake_min: CMakeLists.txt on stdin -> the cmake_minimum_required
# version (the lower end of a x...y range).
parse_cmake_min() {
  local line lower re='^[[:space:]]*cmake_minimum_required[[:space:]]*\([[:space:]]*version[[:space:]]+([0-9]+(\.[0-9]+)*)'
  while IFS= read -r line || [[ -n $line ]]; do
    lower=${line,,}
    if [[ $lower =~ $re ]]; then
      printf '%s' "${BASH_REMATCH[1]}"
      return 0
    fi
  done
  return 1
}

# parse_cmake_version: `cmake --version` output on stdin -> x.y.z
parse_cmake_version() {
  local line re='^cmake version ([0-9]+(\.[0-9]+)*)'
  while IFS= read -r line; do
    if [[ $line =~ $re ]]; then
      printf '%s' "${BASH_REMATCH[1]}"
      return 0
    fi
  done
  return 1
}

cmake_new_enough() { version_ge "$1" "$2"; } # have need

# parse_ninja_progress: ninja output on stdin -> the last "n/N".
parse_ninja_progress() {
  local line last="" re='^\[([0-9]+)/([0-9]+)\]'
  while IFS= read -r line; do
    if [[ $line =~ $re ]]; then
      last="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
    fi
  done
  [[ -n $last ]] || return 1
  printf '%s' "$last"
}

progress_text() { # done total
  printf '[%s/%s] %s%%' "$1" "$2" "$(($2 > 0 ? $1 * 100 / $2 : 0))"
}

# ============================================================ desktop files

# rewrite_desktop_file SRC BIN: the desktop entry with Exec=BIN %U and
# TryExec=BIN in the [Desktop Entry] group; every other line unchanged.
rewrite_desktop_file() {
  local line in_main=0 re_exec='^Exec[[:space:]]*=' re_try='^TryExec[[:space:]]*='
  while IFS= read -r line || [[ -n $line ]]; do
    if [[ $line == '['*']' ]]; then
      if [[ $line == '[Desktop Entry]' ]]; then in_main=1; else in_main=0; fi
    elif ((in_main)) && [[ $line =~ $re_exec ]]; then
      line="Exec=$2 %U"
    elif ((in_main)) && [[ $line =~ $re_try ]]; then
      line="TryExec=$2"
    fi
    printf '%s\n' "$line"
  done <"$1"
}

# rewrite_thumbnailer_script SRC BIN: every bare "aseprite -b" becomes
# "BIN -b" ("bare": not part of a longer word or path).
rewrite_thumbnailer_script() {
  local line out rest before prev needle="aseprite -b" word_char='[A-Za-z0-9_./-]'
  while IFS= read -r line || [[ -n $line ]]; do
    out="" rest=$line
    while [[ $rest == *"$needle"* ]]; do
      before=${rest%%"$needle"*}
      prev=${before:${#before}-1:1}
      if [[ -z $before || ! $prev =~ $word_char ]]; then
        out+="$before$2 -b"
      else
        out+="$before$needle"
      fi
      rest=${rest#*"$needle"}
    done
    printf '%s\n' "$out$rest"
  done <"$1"
}

# rewrite_thumbnailer_entry SRC THUMB_BIN: TryExec=THUMB_BIN and
# Exec=THUMB_BIN <the original arguments>.
rewrite_thumbnailer_entry() {
  local line re_exec='^Exec[[:space:]]*=[[:space:]]*[^[:space:]]+(.*)$' re_try='^TryExec[[:space:]]*='
  while IFS= read -r line || [[ -n $line ]]; do
    if [[ $line =~ $re_exec ]]; then
      line="Exec=$2${BASH_REMATCH[1]}"
    elif [[ $line =~ $re_try ]]; then
      line="TryExec=$2"
    fi
    printf '%s\n' "$line"
  done <"$1"
}

# icon_targets ICONS_DIR ICON_ROOT: "src<TAB>dst" for each ase<N>.png,
# smallest first; dst is ICON_ROOT/<N>x<N>/apps/aseprite.png.
icon_targets() {
  local f name n re='^ase([0-9]+)\.png$'
  local -a sizes=()
  for f in "$1"/ase*.png; do
    [[ -f $f ]] || continue
    name=${f##*/}
    if [[ $name =~ $re ]]; then
      sizes+=("${BASH_REMATCH[1]}")
    fi
  done
  ((${#sizes[@]})) || return 0
  while IFS= read -r n; do
    printf '%s\t%s\n' "$1/ase$n.png" "$2/${n}x$n/apps/aseprite.png"
  done < <(printf '%s\n' "${sizes[@]}" | sort -n)
}

# ======================================================== state and manifest

# state_write FILE KEY=VALUE...: the state file format (install step).
state_write() {
  local file=$1 kv
  shift
  {
    for kv in "$@"; do
      printf '%s\n' "${kv//$'\n'/ }"
    done
  } >"$file"
}

# state_get FILE KEY: print the value of KEY, or fail.
state_get() {
  local line
  [[ -r $1 ]] || return 1
  while IFS= read -r line || [[ -n $line ]]; do
    if [[ $line == *=* && ${line%%=*} == "$2" ]]; then
      printf '%s' "${line#*=}"
      return 0
    fi
  done <"$1"
  return 1
}

manifest_write() { # FILE PATH...
  local file=$1
  shift
  printf '%s\n' "$@" >"$file"
}

# path_in_prefix PATH: true for a clean absolute path strictly inside PREFIX.
path_in_prefix() {
  local p=$1
  [[ $p == "$PREFIX"/* ]] || return 1
  [[ "$p/" != *"/./"* && "$p/" != *"/../"* && $p != *//* ]] || return 1
  [[ $p != *[[:cntrl:]]* ]]
}

# manifest_path_known PATH: true for a path the install step creates: the
# app folder, the bin link, the desktop entry, an icon, the MIME file or a
# thumbnailer file. A damaged manifest can then never remove anything else.
manifest_path_known() {
  local p=$1 size
  case $p in
    "$APP_DIR" | "$BIN_LINK" | "$DESKTOP_FILE" | "$MIME_FILE" | "$THUMB_BIN" | "$THUMB_ENTRY") return 0 ;;
  esac
  [[ $p == "$ICON_ROOT"/*/apps/aseprite.png ]] || return 1
  size=${p#"$ICON_ROOT"/}
  size=${size%/apps/aseprite.png}
  [[ $size =~ ^[0-9]+x[0-9]+$ ]]
}

# manifest_read FILE: the manifest paths, keeping only clean paths inside
# PREFIX that the script itself installs.
manifest_read() {
  local line
  while IFS= read -r line || [[ -n $line ]]; do
    [[ -n $line ]] || continue
    if ! path_in_prefix "$line"; then
      warn "Ignoring a manifest entry outside $PREFIX: $line"
    elif ! manifest_path_known "$line"; then
      warn "Ignoring a manifest entry that the script does not install: $line"
    else
      printf '%s\n' "$line"
    fi
  done <"$1"
}

# rotate_logs DIR KEEP: keep the KEEP newest run-/build-<stamp>.log files.
rotate_logs() {
  local dir=$1 keep=$2 f name i re='^(run|build)-([0-9]{8}-[0-9]{6})\.log$'
  local -a entries=() sorted=()
  [[ -d $dir ]] || return 0
  for f in "$dir"/*.log; do
    [[ -f $f ]] || continue
    name=${f##*/}
    if [[ $name =~ $re ]]; then
      entries+=("${BASH_REMATCH[2]} $name")
    fi
  done
  ((${#entries[@]} > keep)) || return 0
  mapfile -t sorted < <(printf '%s\n' "${entries[@]}" | LC_ALL=C sort -r)
  for ((i = keep; i < ${#sorted[@]}; i++)); do
    rm -f -- "$dir/${sorted[i]#* }"
  done
}

# ================================================================ platform

# glibc_version: the host's glibc version (from getconf), or fail.
glibc_version() {
  local out re='^glibc[[:space:]]+([0-9]+(\.[0-9]+)+)'
  out=$(x_getconf GNU_LIBC_VERSION 2>/dev/null) || return 1
  [[ $out =~ $re ]] || return 1
  printf '%s' "${BASH_REMATCH[1]}"
}

# os_release_get FILE KEY: the unquoted value of KEY in an os-release file.
os_release_get() {
  local line v
  [[ -r $1 ]] || return 1
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line == "$2="* ]] || continue
    v=$(trim "${line#*=}")
    if [[ ${#v} -ge 2 && ($v == \"*\" || $v == \'*\') ]]; then
      v=${v:1:${#v}-2}
    fi
    printf '%s' "$v"
    return 0
  done <"$1"
  return 1
}

# log_os_release: record ID, ID_LIKE and VERSION_ID. Only for the log.
log_os_release() {
  local f id like ver
  f=$(os_release_file)
  if [[ -r $f ]]; then
    id=$(os_release_get "$f" ID) || id=""
    like=$(os_release_get "$f" ID_LIKE) || like=""
    ver=$(os_release_get "$f" VERSION_ID) || ver=""
    log "os-release: ID=$id ID_LIKE=$like VERSION_ID=$ver"
  else
    log "os-release: $f not found"
  fi
}

# check_platform: preflight. Silent on Linux with glibc >= MIN_GLIBC;
# otherwise an error naming what was found, and exit 1.
check_platform() {
  local os v
  os=$(x_uname -s 2>/dev/null) || os=""
  [[ $os == Linux ]] || die 1 "This script runs only on Linux; this system is '${os:-unknown}'."
  v=$(glibc_version) ||
    die 1 "No glibc found: 'getconf GNU_LIBC_VERSION' failed (musl or another C library?). Aseprite needs glibc $MIN_GLIBC or newer."
  version_ge "$v" "$MIN_GLIBC" || die 1 "glibc $v is too old; glibc $MIN_GLIBC or newer is needed."
  log "platform: Linux, glibc $v"
  log_os_release
}

# ===================================================== runtime libraries

# detect_family [FILE]: fedora, debian, arch or suse from os-release ID and
# ID_LIKE; fails for any other distro. Only used for the install hint.
detect_family() {
  local f=${1:-$(os_release_file)} id like w
  local -a words
  [[ -r $f ]] || return 1
  id=$(os_release_get "$f" ID) || id=""
  like=$(os_release_get "$f" ID_LIKE) || like=""
  read -ra words <<<"$id $like"
  for w in "${words[@]+"${words[@]}"}"; do
    case $w in
      fedora | rhel) printf fedora; return 0 ;;
      debian | ubuntu) printf debian; return 0 ;;
      arch) printf arch; return 0 ;;
      suse) printf suse; return 0 ;;
    esac
  done
  return 1
}

# install_hint FAMILY SONAME...: the "hint: sudo <pm> <packages>" line.
# Fails when the family is unknown or no soname is in the table.
install_hint() {
  local family=$1 col cmd soname entry pkg
  local -a pkgs=() fields
  shift
  case $family in
    fedora) col=1 cmd="sudo dnf install" ;;
    debian) col=2 cmd="sudo apt install" ;;
    arch) col=3 cmd="sudo pacman -S --needed" ;;
    suse) col=4 cmd="sudo zypper install" ;;
    *) return 1 ;;
  esac
  for soname in "$@"; do
    for entry in "${RUNTIME_LIBS[@]}"; do
      IFS='|' read -ra fields <<<"$entry"
      [[ ${fields[0]} == "$soname" ]] || continue
      pkg=${fields[$col]}
      [[ " ${pkgs[*]-} " == *" $pkg "* ]] || pkgs+=("$pkg")
    done
  done
  ((${#pkgs[@]})) || return 1
  printf 'hint: %s %s\n' "$cmd" "${pkgs[*]}"
}

# print_install_hint SONAME...: the hint for this host on stderr, if any.
print_install_hint() {
  local family hint
  family=$(detect_family "$(os_release_file)") || family=""
  if hint=$(install_hint "$family" "$@"); then
    printf '%s\n' "$hint" >&2
    log "$hint"
  fi
  return 0
}

# ldconfig_sonames: `ldconfig -p` output on stdin -> x86-64 sonames.
ldconfig_sonames() {
  local line re='^[[:space:]]+([^[:space:]]+)[[:space:]]+\(([^)]*)\)[[:space:]]+=>'
  while IFS= read -r line; do
    [[ $line =~ $re ]] || continue
    if [[ ${BASH_REMATCH[2]} == *x86-64* ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}"
    fi
  done
  return 0
}

# check_runtime_libs: preflight. Succeeds when ldconfig -p knows every
# library in RUNTIME_LIBS; otherwise lists the missing ones with the install
# hint and exits 4. Without ldconfig it warns and leaves it to ldd (step 8).
check_runtime_libs() {
  local out entry soname
  local -A found=()
  local -a missing=()
  if ! out=$(x_ldconfig -p 2>/dev/null); then
    warn "ldconfig was not found, so the runtime libraries are checked only after the build (with ldd, step 8)."
    return 0
  fi
  while IFS= read -r soname; do
    found[$soname]=1
  done < <(ldconfig_sonames <<<"$out")
  for entry in "${RUNTIME_LIBS[@]}"; do
    soname=${entry%%|*}
    [[ -n ${found[$soname]:-} ]] || missing+=("$soname")
  done
  if ((${#missing[@]} == 0)); then
    log "runtime libraries: all found with ldconfig -p"
    return 0
  fi
  err "Missing runtime libraries: ${missing[*]}"
  print_install_hint "${missing[@]}"
  err "Install them with your package manager, then run this script again. It never installs packages itself."
  exit 4
}

# parse_ldd_problems: ldd output on stdin -> "missing <soname>" and
# "version <ldd line>" lines.
parse_ldd_problems() {
  local line re='^[[:space:]]*([^[:space:]]+)[[:space:]]+=>[[:space:]]+not found'
  while IFS= read -r line; do
    if [[ $line =~ $re ]]; then
      printf 'missing %s\n' "${BASH_REMATCH[1]}"
    elif [[ $line == *"version \`"*"' not found"* ]]; then
      printf 'version %s\n' "$(trim "$line")"
    fi
  done
  return 0
}

# fake_missing_lib SONAME: ldd output on stdin, with SONAME "not found".
# Only used for the ASEPRITE_TEST_FAKE_MISSING_LIB test hook.
fake_missing_lib() {
  local want=$1 line seen=0 re='^[[:space:]]*([^[:space:]]+)[[:space:]]+=>'
  while IFS= read -r line; do
    if [[ $line =~ $re && ${BASH_REMATCH[1]} == "$want" ]]; then
      printf '\t%s => not found\n' "$want"
      seen=1
    else
      printf '%s\n' "$line"
    fi
  done
  ((seen)) || printf '\t%s => not found\n' "$want"
}

# check_binary_libs BIN: install step. ldd on the real binary; on any
# "not found" or "version ... not found", print the problems with the
# install hint and fail.
check_binary_libs() {
  local bin=$1 out rc=0 p
  local -a missing=() version=()
  out=$(x_ldd "$bin" 2>&1) || rc=$?
  if [[ -n ${ASEPRITE_TEST_FAKE_MISSING_LIB:-} ]]; then
    log "test hook ASEPRITE_TEST_FAKE_MISSING_LIB: reporting $ASEPRITE_TEST_FAKE_MISSING_LIB as not found"
    out=$(fake_missing_lib "$ASEPRITE_TEST_FAKE_MISSING_LIB" <<<"$out")
  fi
  log "+ ldd $bin (exit $rc)" "$out"
  while IFS= read -r p; do
    case $p in
      "missing "*) missing+=("${p#missing }") ;;
      "version "*) version+=("${p#version }") ;;
    esac
  done < <(parse_ldd_problems <<<"$out")
  if ((${#missing[@]} == 0 && ${#version[@]} == 0)); then
    ((rc == 0)) && return 0
    err "ldd failed on $bin: $(first_line "$out")"
    return 1
  fi
  if ((${#missing[@]})); then
    err "The new build cannot run on this host; these libraries are missing: ${missing[*]}"
  fi
  for p in "${version[@]+"${version[@]}"}"; do
    err "ldd: $p"
  done
  if ((${#version[@]})); then
    err "The host's glibc or libstdc++ is older than the build needs (glibc $MIN_GLIBC or newer, libstdc++ from GCC 13 or newer)."
  fi
  if ((${#missing[@]})); then
    print_install_hint "${missing[@]}"
  fi
  return 1
}

check_arch() {
  local m
  m=$(x_uname -m 2>/dev/null) || m=""
  [[ $m == x86_64 ]] ||
    die 1 "This script supports only x86_64 CPUs; this one is '${m:-unknown}'. Aseprite's prebuilt Skia library exists only for x86_64 Linux."
}

check_root() {
  if is_root; then
    die 1 "Run as your normal user; the script never needs root."
  fi
}

check_bash() {
  (($(bash_major) >= 4)) || die 1 "Bash 4 or newer is needed; this is Bash ${BASH_VERSION:-unknown}."
}

# ============================================================ traps and exit

# step_exit_code: the exit code for an unexpected failure in the current
# step, so every failure still exits with a code from the exit code table (README.md).
step_exit_code() {
  if [[ ${ACTION:-install} == uninstall ]]; then
    printf 1
    return
  fi
  case ${CURRENT_STEP:-1} in
    0 | 1) printf 1 ;;
    2) printf 3 ;;
    3) printf 4 ;;
    4) printf 5 ;;
    5) printf 6 ;;
    6 | 7) printf 7 ;;
    *) printf 8 ;;
  esac
}

on_err() { # status line command
  local rc=$1
  if ((BASH_SUBSHELL > 0)); then
    exit "$rc"
  fi
  trap - ERR
  err "Unexpected failure (exit $rc) at line $2: $3"
  exit "$(step_exit_code)"
}

on_signal() {
  trap - INT TERM HUP
  printf '\n' >&2
  err "Interrupted."
  exit 130
}

# restore_swap: if the run stopped between the two renames of the install
# swap (step 8), put the previous install back.
restore_swap() {
  if ((${SWAP_OLD:-0})) && [[ -d $APP_DIR.old && ! -e $APP_DIR ]]; then
    if mv -T -- "$APP_DIR.old" "$APP_DIR"; then
      warn "Put the previous install back in $(tilde "$APP_DIR")."
    fi
  fi
  SWAP_OLD=0
}

empty_tmp() {
  if [[ -d $WORK/tmp ]]; then
    rm -rf -- "$WORK/tmp" && mkdir -p -- "$WORK/tmp"
  fi
}

# cleanup_run: set up in preflight. Remove only what this run created; never
# the existing install. Work-folder cleanup needs the lock.
cleanup_run() {
  local c p
  if [[ -n ${DOCKER_PID:-} ]]; then
    kill "$DOCKER_PID" 2>/dev/null
    DOCKER_PID=""
  fi
  for c in "${CONTAINERS[@]+"${CONTAINERS[@]}"}"; do
    log "+ docker rm -f $c"
    x_docker rm -f "$c" >/dev/null 2>&1
  done
  CONTAINERS=()
  restore_swap
  for p in "${PARTIALS[@]+"${PARTIALS[@]}"}"; do
    rm -rf -- "$p"
  done
  PARTIALS=()
  if ((${LOCK_HELD:-0})); then
    rm -rf -- "$WORK/src.partial"
    for p in "$WORK"/skia/*.partial; do
      [[ -e $p ]] && rm -rf -- "$p"
    done
    remove_images_if_needed
    empty_tmp
    rotate_logs "$WORK/logs" "$LOG_KEEP"
  fi
}


on_exit() {
  local rc=$?
  trap - ERR
  set +e
  if ((${IN_CONTAINER:-0})); then
    container_cleanup
    exit "$rc"
  fi
  if ((${BUILD_RUNNING:-0})); then
    sync_container_step # before cleanup empties tmp/
  fi
  cleanup_run
  if ((rc != 0)); then
    local where="[${CURRENT_STEP:-1}/${STEP_TOTAL:-$TOTAL_STEPS}] ${CURRENT_STEP_NAME:-Preflight}"
    ((${CURRENT_STEP:-0} > 0)) || where="[1/${STEP_TOTAL:-$TOTAL_STEPS}] Preflight"
    local logmsg="no log was written"
    [[ -n ${LOG_FILE:-} && -f ${LOG_FILE:-} ]] && logmsg="log: $LOG_FILE"
    printf '%s stopped at step %s (exit %s); %s\n' \
      "$(_paint "${COLOR_ERR:-0}" '1;31' 'error:')" "$where" "$rc" "$logmsg" >&2
  fi
  exit "$rc"
}

install_traps() {
  trap 'on_err "$?" "$LINENO" "$BASH_COMMAND"' ERR
  trap on_exit EXIT
  trap on_signal INT TERM HUP
}

# ============================================== work folder, tools and disk

# setup_work_folder: preflight. Create the work folder, take the lock
# and open the run log.
setup_work_folder() {
  mkdir -p -- "$WORK/tmp" "$WORK/logs" 2>/dev/null || die 1 "Cannot create the work folder $WORK"
  exec 9>>"$WORK/lock"
  x_flock -n 9 || die 1 "Another run is in progress."
  LOCK_HELD=1
  RUN_STAMP=$(x_date +%Y%m%d-%H%M%S)
  open_log "$WORK/logs/run-$RUN_STAMP.log"
  log "$SCRIPT_NAME $SCRIPT_VERSION started $(x_date -Iseconds 2>/dev/null || true)"
}

# check_host_tools: preflight. git and a usable Docker, or exit 4.
check_host_tools() {
  local out
  have_cmd git || die 4 "git is not installed or not on PATH. This script does not install git."
  if ! have_cmd docker || ! out=$(x_docker info --format '{{.DockerRootDir}}|{{.SecurityOptions}}' 2>/dev/null); then
    die 4 "Docker is not installed, its daemon is not running, or your user cannot use it. This script does not install or start Docker."
  fi
  out=$(first_line "$out")
  DOCKER_ROOT_DIR=${out%%|*}
  DOCKER_SECURITY=${out#*|}
  log "docker: root folder $DOCKER_ROOT_DIR, security options $DOCKER_SECURITY"
}

docker_rootless() { [[ ${DOCKER_SECURITY:-} == *rootless* ]]; }

# parse_df_avail: `df -Pk` output on stdin -> available KiB. The column
# before the "NN%" one, so spaces in the device name do not matter.
parse_df_avail() {
  local line i
  local -a f
  IFS= read -r _ || return 1
  IFS= read -r line || return 1
  read -ra f <<<"$line"
  for ((i = 1; i < ${#f[@]}; i++)); do
    if [[ ${f[i]} =~ ^[0-9]+%$ && ${f[i - 1]} =~ ^[0-9]+$ ]]; then
      printf '%s' "${f[i - 1]}"
      return 0
    fi
  done
  return 1
}

nearest_existing() {
  local p=$1
  while [[ ! -e $p && $p == /* && $p != / ]]; do
    p=${p%/*}
    [[ -n $p ]] || p=/
  done
  printf '%s' "$p"
}

free_kib() {
  local out
  out=$(x_df -Pk -- "$(nearest_existing "$1")" 2>/dev/null) || return 1
  parse_df_avail <<<"$out"
}

human_kib() {
  local k=$1
  if ((k >= 1048576)); then
    printf '%d.%d GiB' $((k / 1048576)) $((k % 1048576 * 10 / 1048576))
  else
    printf '%d MiB' $((k / 1024))
  fi
}

check_free_space() { # DIR NEED_KIB LABEL
  local avail
  if ! avail=$(free_kib "$1"); then
    warn "Could not read the free disk space under $1 ($3); going on."
    return 0
  fi
  log "free space under $1: $avail KiB, need $2 KiB"
  ((avail >= $2)) ||
    die 1 "Not enough free disk space under $1 ($3): $(human_kib "$avail") free, $(human_kib "$2") needed."
}

# check_disk: preflight.
check_disk() {
  check_free_space "$WORK" "$MIN_FREE_WORK_KIB" "work folder"
  check_free_space "$PREFIX" "$MIN_FREE_PREFIX_KIB" "install prefix"
  if [[ -n ${DOCKER_ROOT_DIR:-} ]]; then
    check_free_space "$DOCKER_ROOT_DIR" "$MIN_FREE_DOCKER_KIB" "Docker's root folder"
  else
    warn "Docker did not report its root folder, so its free space was not checked; going on."
  fi
}

# ============================================================ build container

# build_container_cmd: set BUILD_RUN_CMD, the docker run command for steps
# steps 4-7. Only the work folder is mounted; --user for rootful Docker; :Z
# when SELinux is enabled on the host.
build_container_cmd() {
  local -a user_args=()
  local selinux_opt="" tty=0
  if ! docker_rootless; then
    user_args=(--user "$(x_id -u):$(x_id -g)")
  fi
  if selinux_enabled; then
    selinux_opt=":Z"
  fi
  if stdout_is_tty; then
    tty=1
  fi
  BUILD_CONTAINER="$CONTAINER_PREFIX-build-$$"
  # shellcheck disable=SC2016  # $@ expands inside the container
  BUILD_RUN_CMD=(docker run --rm --name "$BUILD_CONTAINER"
    "${user_args[@]+"${user_args[@]}"}" --env HOME=/tmp
    --volume "$WORK:/work$selinux_opt"
    "$BUILDER_IMAGE"
    bash -c 'source /work/tmp/install-aseprite.sh && container_build "$@"' _
    "ref=$BUILD_REF" "ref_kind=$REF_KIND" "commit=$REF_COMMIT" "jobs=$JOBS"
    "run_log=/work/logs/run-$RUN_STAMP.log" "build_log=/work/logs/build-$RUN_STAMP.log"
    "host_work=$WORK" "tty=$tty" "color=$COLOR_OUT" "verbose=$VERBOSE"
    "break_skia=${ASEPRITE_TEST_BREAK_SKIA:-}")
}

# ================================================================== images

image_present() { x_docker image inspect "$1" >/dev/null 2>&1; }

# remove_images_if_needed: finish step, also run by the EXIT trap.
# Only for runs that reached the image step, and never with --keep-image.
remove_images_if_needed() {
  if ((!${IMAGE_STEP_REACHED:-0} || ${OPT_KEEP_IMAGE:-0} || ${IMAGES_HANDLED:-0})); then
    return 0
  fi
  IMAGES_HANDLED=1
  remove_builder_image
  remove_pulled_base
}

# remove_builder_image: docker image rm without -f, so an image that another
# run's container is using stays (with a warning) instead of failing.
remove_builder_image() {
  if ! image_present "$BUILDER_IMAGE"; then
    IMAGE_STATUS="removed"
    return 0
  fi
  if run x_docker image rm "$BUILDER_IMAGE"; then
    IMAGE_STATUS="removed"
  else
    IMAGE_STATUS="still present (in use by another run?)"
    warn "Could not remove $BUILDER_IMAGE; another run may be using it. Remove it later with: docker image rm $BUILDER_IMAGE"
  fi
}

# remove_pulled_base: remove BASE_IMAGE only if $WORK/pulled-base says this
# script pulled it. The mark stays if removal fails, for a later run.
remove_pulled_base() {
  [[ -f $WORK/pulled-base ]] || return 0
  if image_present "$BASE_IMAGE"; then
    if run x_docker image rm "$BASE_IMAGE"; then
      rm -f -- "$WORK/pulled-base"
    else
      warn "Could not remove $BASE_IMAGE (this script pulled it); it may be in use. Remove it later with: docker image rm $BASE_IMAGE"
    fi
  else
    rm -f -- "$WORK/pulled-base"
  fi
}

log_image_facts() {
  local facts
  ((DRY_RUN)) && return 0
  facts=$(x_docker image inspect --format '{{.Id}} {{.Size}}' "$BUILDER_IMAGE" 2>/dev/null) || return 0
  facts=$(first_line "$facts")
  log "builder image: id ${facts%% *}, size ${facts#* } bytes"
}

# map_container_exit CODE: container_build's codes pass on unchanged; a
# container that docker could not start is a host problem (4); anything
# else (a crash, the OOM killer) counts as a build failure (7).
map_container_exit() {
  case $1 in
    0 | 4 | 5 | 6 | 7 | 130) printf '%s' "$1" ;;
    125 | 126 | 127) printf 4 ;;
    *) printf 7 ;;
  esac
}

# ============================================================ container side
# Steps 4-7 (source to build check) run inside the build container, where $WORK is /work. The
# host passes the run facts as KEY=VALUE arguments (build_container_cmd).

parse_container_args() {
  local kv
  C_REF="" C_REF_KIND="" C_COMMIT="" C_JOBS=2 C_BUILD_LOG="" C_HOST_WORK="" C_TTY=0 C_BREAK_SKIA=""
  for kv in "$@"; do
    case $kv in
      ref=*) C_REF=${kv#*=} ;;
      ref_kind=*) C_REF_KIND=${kv#*=} ;;
      commit=*) C_COMMIT=${kv#*=} ;;
      jobs=*) C_JOBS=${kv#*=} ;;
      run_log=*) LOG_FILE=${kv#*=} ;;
      build_log=*) C_BUILD_LOG=${kv#*=} ;;
      host_work=*) C_HOST_WORK=${kv#*=} ;;
      tty=*) C_TTY=${kv#*=} ;;
      color=*) COLOR_OUT=${kv#*=} COLOR_ERR=${kv#*=} ;;
      verbose=*) VERBOSE=${kv#*=} ;;
      break_skia=*) C_BREAK_SKIA=${kv#*=} ;;
      *) die 7 "container_build: unknown argument '$kv'" ;;
    esac
  done
}

# container_build KEY=VALUE...: run steps 4-7, exit with the fixed exit codes.
container_build() {
  set -Eeuo pipefail
  init_globals
  IN_CONTAINER=1
  WORK=/work
  parse_container_args "$@"
  trap 'on_err "$?" "$LINENO" "$BASH_COMMAND"' ERR
  trap on_exit EXIT
  log_tool_versions
  cstep_source
  cstep_skia
  cstep_build
  cstep_check
  state_write "$WORK/tmp/build-info" "version_line=$C_VERSION_LINE" "skia_tag=$SKIA_TAG" \
    "describe=$C_DESCRIBE" "build_seconds=$C_BUILD_SECONDS"
}

container_cleanup() {
  local p
  if ((${C_PROGRESS_SHOWN:-0})); then printf '\n'; fi
  rm -rf -- "$WORK/src.partial"
  for p in "$WORK"/skia/*.partial; do
    [[ -e $p ]] && rm -rf -- "$p"
  done
  if [[ -n ${C_ZIP_PART:-} ]]; then rm -f -- "$C_ZIP_PART"; fi
}

# hp PATH: a container path as the host sees it, for messages.
hp() {
  local p=$1
  if ((IN_CONTAINER)) && [[ -n ${C_HOST_WORK:-} && ($p == "$WORK" || $p == "$WORK"/*) ]]; then
    p=$C_HOST_WORK${p#"$WORK"}
  fi
  tilde "$p"
}

break_skia_on() { [[ -n ${C_BREAK_SKIA:-} && $C_BREAK_SKIA != 0 ]]; }

log_tool_versions() {
  local t out
  for t in clang cmake ninja git; do
    out=$("$t" --version 2>&1) || out="(not available)"
    log "tool: $t: $(first_line "$out")"
  done
}

# ---- step 4: source

source_reusable() { # DIR COMMIT
  local head st
  [[ -e $1/.git ]] || return 1
  head=$(x_git -C "$1" rev-parse HEAD 2>/dev/null) || return 1
  [[ $head == "$2" ]] || return 1
  st=$(x_git -C "$1" status --porcelain 2>/dev/null) || return 1
  [[ -z $st ]]
}

clone_source() {
  local attempt
  for attempt in 1 2; do
    rm -rf -- "$WORK/src.partial"
    if run x_git clone --depth 1 --branch "$C_REF" --recurse-submodules --shallow-submodules \
      "$REPO_URL" "$WORK/src.partial"; then
      run mv -T -- "$WORK/src.partial" "$WORK/src"
      return 0
    fi
    if ((attempt == 1)); then
      warn "The clone failed; trying once more in 5 seconds."
      x_sleep 5
    fi
  done
  rm -rf -- "$WORK/src.partial"
  die 5 "Could not clone $REPO_URL at $C_REF (see the log)."
}

# submodule_status_ok: `git submodule status` on stdin; fails on a line
# starting with - (not initialised) or + (wrong commit).
submodule_status_ok() {
  local line
  while IFS= read -r line; do
    [[ $line == [-+]* ]] && return 1
  done
  return 0
}

submodules_ok() {
  local out
  out=$(x_git -C "$1" submodule status --recursive 2>&1) || return 1
  submodule_status_ok <<<"$out"
}

cstep_source() {
  local src=$WORK/src head
  say_step 4 "Getting source ($C_REF)"
  if source_reusable "$src" "$C_COMMIT"; then
    info "Reusing the source in $(hp "$src") (commit ${C_COMMIT:0:12})"
  else
    if [[ -e $src ]]; then run rm -rf -- "$src"; fi
    info "Cloning $REPO_URL at $C_REF with its submodules"
    clone_source
  fi
  head=$(x_git -C "$src" rev-parse HEAD 2>/dev/null) || head=""
  [[ $head == "$C_COMMIT" ]] ||
    die 5 "The source is at commit ${head:-unknown}, not $C_COMMIT. The ref may have just moved; run the script again."
  if ! submodules_ok "$src"; then
    info "Some submodules are missing or at the wrong commit; updating them"
    run x_git -C "$src" submodule update --init --recursive --depth 1 || true
    submodules_ok "$src" || die 5 "Some submodules are still missing or at the wrong commit (see the log)."
  fi
  if C_DESCRIBE=$(x_git -C "$src" describe --tags 2>/dev/null); then
    log "git describe --tags: $C_DESCRIBE"
  elif [[ $C_REF_KIND == tag ]]; then
    die 5 "'git describe --tags' does not work in the source, so the version string would be wrong."
  else
    C_DESCRIBE=$(x_git -C "$src" describe --tags --always 2>/dev/null) || C_DESCRIBE="unknown"
    warn "This shallow clone of branch $C_REF has no tag, so Aseprite will report version 1.x-$C_DESCRIBE-dev."
  fi
}

# ---- step 5: Skia

skia_url() { printf 'https://github.com/aseprite/skia/releases/download/%s/%s' "$1" "$SKIA_ZIP"; }

sha256_of() {
  local out
  out=$(x_sha256sum "$1") || return 1
  printf '%s' "${out%% *}"
}

cstep_skia() {
  local tagfile=$WORK/src/laf/misc/skia-tag.txt url dl zip sha
  SKIA_TAG=$(read_skia_tag "$tagfile") ||
    die 6 "Could not read the Skia tag from $(hp "$tagfile") (missing, empty or not a tag)."
  say_step 5 "Getting Skia ($SKIA_TAG)"
  SKIA_DIR=$WORK/skia/skia-$SKIA_TAG
  url=$(skia_url "$SKIA_TAG")
  if [[ -f $SKIA_DIR/out/Release-x64/libskia.a && -d $SKIA_DIR/include ]]; then
    info "Skia $SKIA_TAG already present"
  else
    dl=$WORK/downloads/$SKIA_TAG
    zip=$dl/$SKIA_ZIP
    mkdir -p -- "$dl" "$WORK/skia"
    if [[ -f $zip ]]; then
      info "Reusing the downloaded $(hp "$zip")"
    else
      info "Downloading $url"
      C_ZIP_PART=$zip.part
      if ! run x_curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 --no-progress-meter \
        -o "$zip.part" "$url"; then
        rm -f -- "$zip.part"
        die 6 "Could not download Skia from $url"
      fi
      run mv -f -- "$zip.part" "$zip"
      C_ZIP_PART=""
    fi
    sha=$(sha256_of "$zip") || die 6 "Could not compute the SHA-256 of the Skia zip from $url"
    log "sha256 of $SKIA_ZIP ($SKIA_TAG): $sha"
    if [[ $SKIA_TAG == "$SKIA_PINNED_TAG" ]]; then
      if [[ $sha != "$SKIA_PINNED_SHA256" ]]; then
        rm -f -- "$zip"
        die 6 "The Skia zip from $url has SHA-256 $sha, not the expected $SKIA_PINNED_SHA256. It was deleted."
      fi
      info "SHA-256 matches the pinned value"
    else
      info "No published checksum for Skia $SKIA_TAG; its SHA-256 is $sha (logged)"
    fi
    if ! run x_unzip -tq "$zip"; then
      rm -f -- "$zip"
      die 6 "The Skia zip from $url is damaged (unzip -t failed). It was deleted."
    fi
    rm -rf -- "$SKIA_DIR.partial"
    mkdir -p -- "$SKIA_DIR.partial"
    run x_unzip -q "$zip" -d "$SKIA_DIR.partial" || die 6 "Could not unpack the Skia zip from $url"
    [[ -f $SKIA_DIR.partial/out/Release-x64/libskia.a ]] ||
      die 6 "The Skia zip from $url has no out/Release-x64/libskia.a."
    rm -rf -- "$SKIA_DIR"
    run mv -T -- "$SKIA_DIR.partial" "$SKIA_DIR"
  fi
  if break_skia_on; then
    SKIA_DIR=$WORK/tmp/empty-skia
    rm -rf -- "$SKIA_DIR"
    mkdir -p -- "$SKIA_DIR"
    warn "Test hook ASEPRITE_TEST_BREAK_SKIA is set: building against the empty folder $(hp "$SKIA_DIR")."
  fi
}

# ---- step 6: configure and compile

# cmake_args SRC BUILD SKIA: set CMAKE_ARGS to the pinned cmake command.
cmake_args() {
  CMAKE_ARGS=(-S "$1" -B "$2" -G Ninja
    -DCMAKE_BUILD_TYPE=RelWithDebInfo
    -DCMAKE_CXX_FLAGS:STRING=-stdlib=libstdc++
    -DCMAKE_EXE_LINKER_FLAGS:STRING=-stdlib=libstdc++
    -DLAF_BACKEND=skia
    "-DSKIA_DIR=$3"
    "-DSKIA_LIBRARY_DIR=$3/out/Release-x64"
    "-DSKIA_LIBRARY=$3/out/Release-x64/libskia.a"
    -DCMAKE_C_COMPILER_LAUNCHER=ccache
    -DCMAKE_CXX_COMPILER_LAUNCHER=ccache)
}

# ccache_env: keep compiler cache in $WORK/ccache so rebuilds are fast (README.md, "Implementation notes").
# compilercheck=content because the builder image, and so the compiler's
# mtime, can be new on every run.
ccache_env() {
  export CCACHE_DIR="$WORK/ccache" CCACHE_COMPILERCHECK=content CCACHE_MAXSIZE=3G
}

build_failed() { # MESSAGE
  if ((${C_PROGRESS_SHOWN:-0})); then printf '\n'; C_PROGRESS_SHOWN=0; fi
  err "$1. The last 40 lines of the build log:"
  if [[ -f $C_BUILD_LOG ]]; then tail -n 40 -- "$C_BUILD_LOG" >&2; fi
  die 7 "$1. Build log: $(hp "$C_BUILD_LOG"). The source and build folders are kept for inspection."
}

# run_ninja: ninja with its output in the build log. On a terminal, show
# the latest [n/N] on one line; otherwise a progress line every 60 s.
run_ninja() {
  local pid rc=0 tick=0 prog
  log "+ ninja -C $WORK/build -j $C_JOBS aseprite"
  if ((VERBOSE)); then
    x_ninja -C "$WORK/build" -j "$C_JOBS" aseprite 2>&1 | tee -a "$C_BUILD_LOG"
    return "${PIPESTATUS[0]}"
  fi
  x_ninja -C "$WORK/build" -j "$C_JOBS" aseprite >>"$C_BUILD_LOG" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    x_sleep 1
    tick=$((tick + 1))
    prog=$(tail -n 20 -- "$C_BUILD_LOG" 2>/dev/null | parse_ninja_progress) || continue
    if ((C_TTY)); then
      printf '\r   -> %s\033[K' "$(progress_text "${prog%/*}" "${prog#*/}")"
      C_PROGRESS_SHOWN=1
    elif ((tick % 60 == 0)); then
      info "Still building: $(progress_text "${prog%/*}" "${prog#*/}")"
    fi
  done
  wait "$pid" || rc=$?
  if ((${C_PROGRESS_SHOWN:-0})); then
    printf '\n'
    C_PROGRESS_SHOWN=0
  fi
  return "$rc"
}

cstep_build() {
  local build=$WORK/build stamp want min have out start
  say_step 6 "Building Aseprite (ninja -j $C_JOBS)"
  stamp=$build/.aseprite-installer-stamp
  want="$C_COMMIT $SKIA_TAG"
  if break_skia_on; then
    # Never reuse or stamp a build folder configured against the empty Skia.
    if [[ -e $build ]]; then run rm -rf -- "$build"; fi
  elif [[ -f $stamp && "$(<"$stamp")" == "$want" ]]; then
    info "Reusing the build folder (only changed files are rebuilt)"
  elif [[ -e $build ]]; then
    run rm -rf -- "$build"
  fi
  min=$(parse_cmake_min <"$WORK/src/CMakeLists.txt") ||
    die 7 "Could not read cmake_minimum_required from the source's CMakeLists.txt."
  out=$(x_cmake --version 2>&1) || die 4 "cmake does not run in the builder image."
  have=$(parse_cmake_version <<<"$out") || die 4 "Could not read the CMake version in the builder image."
  cmake_new_enough "$have" "$min" ||
    die 4 "CMake $have in the builder image is older than the $min this source needs. Remove the image (docker image rm $BUILDER_IMAGE) so the next run makes a new one."
  log "cmake $have (the source needs $min)"
  info "Build log: $(hp "$C_BUILD_LOG")"
  start=$SECONDS
  export CC=clang CXX=clang++
  ccache_env
  cmake_args "$WORK/src" "$build" "$SKIA_DIR"
  run_into "$C_BUILD_LOG" x_cmake "${CMAKE_ARGS[@]}" || build_failed "CMake configure failed"
  if ! break_skia_on; then
    printf '%s\n' "$want" >"$stamp"
  fi
  run_ninja || build_failed "The build failed"
  C_BUILD_SECONDS=$((SECONDS - start))
  info "Build took $(duration "$C_BUILD_SECONDS")"
}

# ---- step 7: check the build

version_line_of() { # TEXT -> the first line starting with "Aseprite "
  local l
  while IFS= read -r l; do
    if [[ $l == "Aseprite "* ]]; then
      printf '%s' "$l"
      return 0
    fi
  done <<<"$1"
  return 1
}

# version_matches_tag LINE TAG: "Aseprite 1.3.18.6-dev" matches v1.3.18.6.
version_matches_tag() {
  local v=${1#Aseprite } t=${2#v}
  [[ $v == "$t" || $v == "$t"-* || $v == "$t "* ]]
}

parse_readelf_needed() {
  local line re='\(NEEDED\).*\[([^]]+)\]'
  while IFS= read -r line; do
    if [[ $line =~ $re ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}"
    fi
  done
  return 0
}

# max_symbol_version PREFIX: `objdump -T` on stdin -> newest PREFIX_x.y.
max_symbol_version() {
  local line re="(^|[^A-Za-z0-9_])${1}_([0-9]+(\.[0-9]+)*)([^A-Za-z0-9_.]|$)"
  local -a vers=()
  while IFS= read -r line; do
    if [[ $line =~ $re ]]; then
      vers+=("${BASH_REMATCH[2]}")
    fi
  done
  ((${#vers[@]})) || return 1
  printf '%s\n' "${vers[@]}" | LC_ALL=C sort -V | tail -n 1
}

# record_runtime_deps BIN: build check, into build/runtime-deps.txt.
record_runtime_deps() {
  local bin=$1 file=$WORK/build/runtime-deps.txt lib entry known syms glibc glibcxx
  local -a needed=()
  mapfile -t needed < <(x_readelf -d "$bin" 2>/dev/null | parse_readelf_needed)
  syms=$(x_objdump -T "$bin" 2>/dev/null) || syms=""
  glibc=$(max_symbol_version GLIBC <<<"$syms") || glibc=""
  glibcxx=$(max_symbol_version GLIBCXX <<<"$syms") || glibcxx=""
  {
    printf '# What %s needs at run time (readelf -d, objdump -T)\n' "${C_VERSION_LINE:-the binary}"
    printf 'needed: %s\n' "${needed[*]-}"
    printf 'newest glibc symbol: GLIBC_%s\n' "${glibc:-none}"
    printf 'newest libstdc++ symbol: GLIBCXX_%s\n' "${glibcxx:-none}"
  } >"$file"
  log "runtime deps: needed ${needed[*]-}; newest GLIBC_${glibc:-none}, GLIBCXX_${glibcxx:-none}"
  for lib in "${needed[@]+"${needed[@]}"}"; do
    [[ $GLIBC_SONAMES == *" $lib "* ]] && continue
    known=0
    for entry in "${RUNTIME_LIBS[@]}"; do
      if [[ ${entry%%|*} == "$lib" ]]; then known=1; fi
    done
    if ((!known)); then
      warn "The binary needs $lib, which is not in the runtime library table; the table should be corrected."
    fi
  done
  if [[ -n $glibc ]] && ! version_ge "$MIN_GLIBC" "$glibc"; then
    warn "The binary uses GLIBC_$glibc, newer than the minimum glibc $MIN_GLIBC."
  fi
  if [[ -n $glibcxx ]] && ! version_ge "$MIN_GLIBCXX" "$glibcxx"; then
    warn "The binary uses GLIBCXX_$glibcxx, newer than GLIBCXX_$MIN_GLIBCXX (libstdc++ from GCC 13)."
  fi
}

# Aseprite v1.3.17 and older hard-code VERSION "1.x-dev" in src/ver/CMakeLists.txt,
# so a build of those tags cannot report its tag.
version_is_placeholder() {
  [[ $1 == "Aseprite 1.x-dev" ]]
}

cstep_check() {
  local bin=$WORK/build/bin/aseprite out
  say_step 7 "Checking the build"
  [[ -f $bin && -x $bin ]] || die 7 "The build did not produce $(hp "$bin")."
  [[ -d $WORK/build/bin/data ]] || die 7 "The build did not produce $(hp "$WORK/build/bin/data/")."
  out=$("$bin" --version 2>&1) || die 7 "'aseprite --version' failed in the container: $(first_line "$out")"
  C_VERSION_LINE=$(version_line_of "$out") ||
    die 7 "'aseprite --version' printed no line starting with 'Aseprite ': $(first_line "$out")"
  log "aseprite --version (container): $C_VERSION_LINE"
  if [[ $C_REF_KIND == tag ]] && ! version_matches_tag "$C_VERSION_LINE" "$C_REF"; then
    if version_is_placeholder "$C_VERSION_LINE"; then
      warn "This release's source sets the placeholder version '1.x-dev' instead of ${C_REF#v}; accepting it."
    else
      die 7 "The build reports '$C_VERSION_LINE', which does not match the tag $C_REF."
    fi
  fi
  info "$C_VERSION_LINE"
  record_runtime_deps "$bin"
}

# ================================================= host: the build container

# step_container: steps 4-7 in the build container (run_waited, so
# Ctrl-C reaches the trap at once and the trap removes the container).
step_container() {
  local rc=0 start info_file=$WORK/tmp/build-info
  if ((DRY_RUN)); then
    dry_run_container
    return 0
  fi
  rm -f -- "$info_file" "$WORK/tmp/container-step"
  run cp -- "$(script_path)" "$WORK/tmp/install-aseprite.sh"
  build_container_cmd
  CURRENT_STEP=4 CURRENT_STEP_NAME="Getting source ($BUILD_REF)"
  CONTAINERS+=("$BUILD_CONTAINER")
  start=$SECONDS
  BUILD_RUNNING=1
  run_waited "" x_docker "${BUILD_RUN_CMD[@]:1}" || rc=$?
  BUILD_RUNNING=0
  CONTAINER_SECONDS=$((SECONDS - start))
  if ((rc != 0)); then
    sync_container_step
    case $rc in
      125 | 126 | 127) err "Docker could not start the build container (docker exit $rc)." ;;
      0 | 4 | 5 | 6 | 7 | 130) ;;
      *) err "The build container stopped unexpectedly (exit $rc; out of memory?)." ;;
    esac
    exit "$(map_container_exit "$rc")"
  fi
  CONTAINERS=()
  BUILT_VERSION_LINE=$(state_get "$info_file" version_line) ||
    die 7 "The build container finished without reporting the build."
  SKIA_TAG=$(state_get "$info_file" skia_tag) || SKIA_TAG=""
  BUILD_SECONDS=$(state_get "$info_file" build_seconds) || BUILD_SECONDS=0
  log "build container: $(duration "$CONTAINER_SECONDS") in all, cmake and ninja $(duration "$BUILD_SECONDS")"
}

# sync_container_step: take the step the build container last started
# (it writes tmp/container-step), so the last error line names it.
sync_container_step() {
  local stepinfo
  [[ -f $WORK/tmp/container-step ]] || return 0
  stepinfo=$(<"$WORK/tmp/container-step")
  CURRENT_STEP=${stepinfo%%|*}
  CURRENT_STEP_NAME=${stepinfo#*|}
}

dry_run_container() {
  local tag url
  [[ -n $RUN_STAMP ]] || RUN_STAMP=$(x_date +%Y%m%d-%H%M%S)
  build_container_cmd
  say_step 4 "Getting source ($BUILD_REF)"
  info "[dry-run] would copy this script to $(tilde "$WORK/tmp/install-aseprite.sh") and run steps 4-7 in:"
  printf '   [dry-run] %s\n' "$(quote_cmd "${BUILD_RUN_CMD[@]}")"
  if [[ -d $WORK/src ]]; then
    info "[dry-run] would reuse $(tilde "$WORK/src") if it is clean and at commit ${REF_COMMIT:0:12}; otherwise:"
  fi
  printf '   [dry-run] %s\n' "$(quote_cmd git clone --depth 1 --branch "$BUILD_REF" --recurse-submodules \
    --shallow-submodules "$REPO_URL" /work/src.partial)"
  if tag=$(read_skia_tag "$WORK/src/laf/misc/skia-tag.txt" 2>/dev/null); then
    say_step 5 "Getting Skia ($tag)"
  else
    tag="<tag from laf/misc/skia-tag.txt>"
    say_step 5 "Getting Skia"
  fi
  url=$(skia_url "$tag")
  info "[dry-run] would reuse $(tilde "$WORK/skia/skia-$tag") if present; otherwise:"
  printf '   [dry-run] %s\n' "$(quote_cmd curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 \
    -o "/work/downloads/$tag/$SKIA_ZIP.part" "$url")"
  say_step 6 "Building Aseprite (ninja -j $JOBS)"
  cmake_args /work/src /work/build "/work/skia/skia-$tag"
  printf '   [dry-run] %s\n' "$(quote_cmd cmake "${CMAKE_ARGS[@]}")"
  printf '   [dry-run] %s\n' "$(quote_cmd ninja -C /work/build -j "$JOBS" aseprite)"
  say_step 7 "Checking the build"
  printf '   [dry-run] %s\n' "/work/build/bin/aseprite --version; readelf -d and objdump -T on it"
}

# ============================================================ step headers

setup_colors() {
  COLOR_OUT=0 COLOR_ERR=0
  if [[ -z ${NO_COLOR+x} ]]; then
    if stdout_is_tty; then COLOR_OUT=1; fi
    if stderr_is_tty; then COLOR_ERR=1; fi
  fi
}

# say_step N TITLE: print "==> [N/9] TITLE" and log it with a timestamp.
say_step() {
  CURRENT_STEP=$1
  CURRENT_STEP_NAME=$2
  printf '%s %s\n' "$(_paint "$COLOR_OUT" '1;34' "==> [$1/$STEP_TOTAL]")" "$(_paint "$COLOR_OUT" 1 "$2")"
  log "==> [$1/$STEP_TOTAL] $2  ($(x_date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || true))"
  if ((IN_CONTAINER)); then
    # Tells the host which step failed (the container's exit code alone
    # cannot say whether it was the build or the build check).
    printf '%s|%s\n' "$1" "$2" >"$WORK/tmp/container-step" 2>/dev/null || true
  fi
}

# duration SECONDS: "14m 32s"
duration() {
  local s=$1
  if ((s >= 3600)); then
    printf '%dh %dm %ds' $((s / 3600)) $((s % 3600 / 60)) $((s % 60))
  elif ((s >= 60)); then
    printf '%dm %ds' $((s / 60)) $((s % 60))
  else
    printf '%ds' "$s"
  fi
}

# ==================================================================== steps

step_preflight() {
  say_step 1 "Preflight"
  check_root
  check_platform
  check_arch
  check_bash
  # Step 6: main set the ERR, EXIT and signal traps before anything exists.
  if ((DRY_RUN)); then
    info "[dry-run] would create $(tilde "$WORK") and take the lock $(tilde "$WORK/lock")"
  else
    setup_work_folder
  fi
  info "Work folder: $(tilde "$WORK")"
  info "Install prefix: $(tilde "$PREFIX")"
  check_host_tools
  check_disk
  check_runtime_libs
  JOBS=${OPT_JOBS:-$(x_nproc 2>/dev/null || printf 2)}
  log "jobs: $JOBS"
}

# step_resolve: step 2, resolve. Sets BUILD_REF, REF_KIND and REF_COMMIT; exits 0
# when the installed commit is already the target.
step_resolve() {
  local inst_commit="" inst_version=""
  say_step 2 "Deciding what to build"
  if [[ -n $OPT_REF ]]; then
    BUILD_REF=$OPT_REF
  else
    latest_stable_tag
    BUILD_REF=$LATEST_TAG
  fi
  resolve_ref "$BUILD_REF"
  if [[ -f $STATE_FILE ]]; then
    inst_commit=$(state_get "$STATE_FILE" commit) || inst_commit=""
    inst_version=$(state_get "$STATE_FILE" version) || inst_version=""
  fi
  if [[ -n $inst_commit && $inst_commit == "$REF_COMMIT" && -e $BIN ]] && ((!OPT_FORCE)); then
    info "Aseprite ${inst_version:-$BUILD_REF} is already installed and up to date ($BUILD_REF, commit ${REF_COMMIT:0:12})."
    exit 0
  fi
  info "Target: $BUILD_REF ($REF_KIND), commit ${REF_COMMIT:0:12}"
  if [[ -z $inst_version ]]; then
    info "Installing $BUILD_REF"
  elif [[ $inst_commit == "$REF_COMMIT" ]]; then
    info "Rebuilding $inst_version (--force)"
  else
    info "Updating $inst_version → $BUILD_REF"
  fi
}

# step_image: step 3, builder image. Reuse the builder image, or make it with docker run
# plus docker commit (never docker build, so no build cache is left).
step_image() {
  local setup="$CONTAINER_PREFIX-setup-$$" script
  say_step 3 "Builder image"
  ((DRY_RUN)) || IMAGE_STEP_REACHED=1
  if image_present "$BUILDER_IMAGE"; then
    info "Builder image already present ($BUILDER_IMAGE)"
    log_image_facts
    return 0
  fi
  if image_present "$BASE_IMAGE"; then
    info "Base image $BASE_IMAGE already present"
  else
    info "Pulling $BASE_IMAGE"
    # Marked before the pull, so an interrupted pull is cleaned up too.
    ((DRY_RUN)) || : >"$WORK/pulled-base"
    run x_docker pull "$BASE_IMAGE" || die 4 "Could not pull $BASE_IMAGE from Docker Hub."
  fi
  info "Installing the build tools in a setup container (this takes a few minutes)"
  script="apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ${CONTAINER_PACKAGES[*]} && rm -rf /var/lib/apt/lists/*"
  ((DRY_RUN)) || CONTAINERS+=("$setup")
  run_waited "${LOG_FILE:-}" x_docker run --name "$setup" "$BASE_IMAGE" bash -c "$script" ||
    die 4 "Could not install the build packages in the setup container (see the log)."
  run x_docker commit --change 'LABEL aseprite-installer=1' "$setup" "$BUILDER_IMAGE" ||
    die 4 "Could not save the builder image $BUILDER_IMAGE."
  run x_docker rm "$setup" || die 4 "Could not remove the setup container $setup."
  CONTAINERS=()
  if ((DRY_RUN)); then
    info "[dry-run] would make the builder image $BUILDER_IMAGE"
  else
    info "Made the builder image $BUILDER_IMAGE"
  fi
  log_image_facts
}

# run_host_binary BIN ARGS...: run the built Aseprite on the host with its
# user folder under $WORK/tmp. Aseprite rewrites Aseprite.log in its user
# folder on every start, even for --version, and ~/.config/aseprite must
# never be touched (install step).
run_host_binary() {
  local sandbox=$WORK/tmp/aseprite-home
  mkdir -p -- "$sandbox/.config/aseprite"
  env -u DISPLAY -u WAYLAND_DISPLAY HOME="$sandbox" XDG_CONFIG_HOME="$sandbox/.config" \
    XDG_CACHE_HOME="$sandbox/.cache" ASEPRITE_USER_FOLDER="$sandbox/.config/aseprite" "$@" 2>&1
}

# refresh_caches: install step. Each tool only if it exists; a failure
# is a warning, never a failed install.
refresh_caches() {
  if have_cmd update-desktop-database && [[ -d $APPS_DIR ]]; then
    run update-desktop-database "$APPS_DIR" || warn "update-desktop-database failed; the menu may update only at your next login."
  fi
  if have_cmd update-mime-database && [[ -d $MIME_ROOT/packages ]]; then
    run update-mime-database "$MIME_ROOT" || warn "update-mime-database failed."
  fi
  if have_cmd gtk-update-icon-cache && [[ -d $ICON_ROOT ]]; then
    run gtk-update-icon-cache -f -t "$ICON_ROOT" || warn "gtk-update-icon-cache failed."
  fi
  if [[ -d $ICON_ROOT ]]; then
    run touch -- "$ICON_ROOT" || warn "Could not touch $ICON_ROOT."
  fi
}

# recover_stale_swap: an aseprite.old left by a killed run is either the
# previous install (put it back) or a leftover next to a good install.
recover_stale_swap() {
  [[ -d $APP_DIR.old ]] || return 0
  if [[ -e $APP_DIR ]]; then
    run rm -rf -- "$APP_DIR.old"
  else
    run mv -T -- "$APP_DIR.old" "$APP_DIR"
    warn "Put back the previous install that an interrupted run left in $(tilde "$APP_DIR.old")."
  fi
}

# install_desktop_files: install step. Appends to INSTALLED.
install_desktop_files() {
  local d=$WORK/src/src/desktop/linux s t
  if [[ -f $d/aseprite.desktop ]]; then
    run mkdir -p -- "$APPS_DIR"
    log "+ write $DESKTOP_FILE (Exec=$BIN %U, TryExec=$BIN)"
    rewrite_desktop_file "$d/aseprite.desktop" "$BIN" >"$DESKTOP_FILE"
    INSTALLED+=("$DESKTOP_FILE")
  else
    warn "The source has no src/desktop/linux/aseprite.desktop; no menu entry was installed."
  fi
  while IFS=$'\t' read -r s t; do
    run mkdir -p -- "${t%/*}"
    run cp -- "$s" "$t"
    INSTALLED+=("$t")
  done < <(icon_targets "$WORK/src/data/icons" "$ICON_ROOT")
  if [[ -f $d/mime/aseprite.xml ]]; then
    run mkdir -p -- "${MIME_FILE%/*}"
    run cp -- "$d/mime/aseprite.xml" "$MIME_FILE"
    INSTALLED+=("$MIME_FILE")
  else
    warn "The source has no src/desktop/linux/mime/aseprite.xml; the MIME type was not installed."
  fi
  if [[ -f $d/aseprite-thumbnailer && -f $d/gnome/aseprite.thumbnailer ]]; then
    log "+ write $THUMB_BIN (aseprite -b -> $BIN -b)"
    rewrite_thumbnailer_script "$d/aseprite-thumbnailer" "$BIN" >"$THUMB_BIN"
    run chmod 755 -- "$THUMB_BIN"
    INSTALLED+=("$THUMB_BIN")
    run mkdir -p -- "${THUMB_ENTRY%/*}"
    log "+ write $THUMB_ENTRY (TryExec/Exec -> $THUMB_BIN)"
    rewrite_thumbnailer_entry "$d/gnome/aseprite.thumbnailer" "$THUMB_BIN" >"$THUMB_ENTRY"
    INSTALLED+=("$THUMB_ENTRY")
  else
    warn "The source has no thumbnailer files; the thumbnailer was not installed."
  fi
}

# step_install: step 8, install. New folder as aseprite.new, ldd check, swap.
step_install() {
  local new=$APP_DIR.new old=$APP_DIR.old
  say_step 8 "Installing into $(tilde "$PREFIX")"
  if [[ -e $BIN_LINK && ! -L $BIN_LINK ]]; then
    die 8 "$(tilde "$BIN_LINK") exists and is not a symlink, so it is not overwritten. Move it away and run again."
  fi
  if ((DRY_RUN)); then
    dry_run_install
    return 0
  fi
  recover_stale_swap
  run mkdir -p -- "$PREFIX/opt" "$PREFIX/bin"
  run rm -rf -- "$new"
  PARTIALS+=("$new")
  run cp -a -- "$WORK/build/bin" "$new" || die 8 "Could not copy the build to $(tilde "$new")."
  if ! check_binary_libs "$new/aseprite"; then
    run rm -rf -- "$new"
    die 8 "Nothing was installed; the existing install is untouched."
  fi
  if [[ -e $APP_DIR ]]; then
    run mv -T -- "$APP_DIR" "$old"
    SWAP_OLD=1
  fi
  if ! run mv -T -- "$new" "$APP_DIR"; then
    if ((SWAP_OLD)); then
      mv -T -- "$old" "$APP_DIR"
      SWAP_OLD=0
    fi
    die 8 "Could not move the new build into place; the previous install was put back."
  fi
  PARTIALS=()
  if ((SWAP_OLD)); then
    run rm -rf -- "$old"
    SWAP_OLD=0
  fi
  run ln -sfn -- "$BIN" "$BIN_LINK"
  INSTALLED=("$BIN_LINK")
  install_desktop_files
  refresh_caches
  run mkdir -p -- "$RECORDS_DIR"
  manifest_write "$MANIFEST_FILE" "${INSTALLED[@]}" "$APP_DIR"
  state_write "$STATE_FILE" "ref=$BUILD_REF" "commit=$REF_COMMIT" "version=${BUILT_VERSION_LINE#Aseprite }" \
    "skia_tag=$SKIA_TAG" "build_base=$BASE_IMAGE" "installed_at=$(x_date -Iseconds)" \
    "script_version=$SCRIPT_VERSION"
  log "manifest: $MANIFEST_FILE (${#INSTALLED[@]} paths and the app folder)" "state: $(tr '\n' ' ' <"$STATE_FILE")"
  info "Installed $(tilde "$APP_DIR") and the menu entry, icons, MIME type and thumbnailer"
}

dry_run_install() {
  local d=$WORK/src/src/desktop/linux
  printf '   [dry-run] %s\n' "$(quote_cmd cp -a -- "$WORK/build/bin" "$APP_DIR.new")" \
    "$(quote_cmd ldd "$APP_DIR.new/aseprite")  (stop with exit 8 if a library is missing)" \
    "$(quote_cmd mv -T -- "$APP_DIR" "$APP_DIR.old")  (if installed)" \
    "$(quote_cmd mv -T -- "$APP_DIR.new" "$APP_DIR")" \
    "$(quote_cmd rm -rf -- "$APP_DIR.old")" \
    "$(quote_cmd ln -sfn -- "$BIN" "$BIN_LINK")" \
    "write $DESKTOP_FILE from $d/aseprite.desktop (Exec=$BIN %U, TryExec=$BIN)" \
    "copy $WORK/src/data/icons/ase<N>.png to $ICON_ROOT/<N>x<N>/apps/aseprite.png" \
    "$(quote_cmd cp -- "$d/mime/aseprite.xml" "$MIME_FILE")" \
    "write $THUMB_BIN and $THUMB_ENTRY (absolute paths)" \
    "update-desktop-database, update-mime-database, gtk-update-icon-cache (where present)" \
    "write $MANIFEST_FILE and $STATE_FILE"
}

# desktop_menu_name: "Aseprite (Graphics)" from the installed desktop file.
desktop_menu_name() {
  local name="Aseprite" cat="" line
  if [[ -f $DESKTOP_FILE ]]; then
    while IFS= read -r line; do
      case $line in
        Name=*) name=${line#Name=} ;;
        Categories=*) cat=${line#Categories=} cat=${cat%%;*} ;;
      esac
    done <"$DESKTOP_FILE"
  fi
  printf '%s%s' "$name" "${cat:+ ($cat)}"
}

print_summary() {
  local image
  if ((OPT_KEEP_IMAGE)); then
    image="kept ($BUILDER_IMAGE; --uninstall --purge removes it)"
  elif [[ ${IMAGE_STATUS:-removed} == removed ]]; then
    image="removed (use --keep-image to keep it)"
  else
    image=$IMAGE_STATUS
  fi
  printf '\n%s\n' "$(_paint "$COLOR_OUT" '1;32' "Aseprite ${BUILT_VERSION_LINE#Aseprite } installed")"
  printf '  binary:   %s -> %s\n' "$(tilde "$BIN_LINK")" "$(tilde "$BIN")"
  printf '  menu:     %s\n' "$(desktop_menu_name)"
  printf '  skia:     %s\n' "$SKIA_TAG"
  printf '  built in: %s (%s container)\n' "$(duration "${CONTAINER_SECONDS:-0}")" "$BASE_IMAGE"
  printf '  image:    %s\n' "$image"
  printf '  log:      %s\n' "$(tilde "$LOG_FILE")"
  printf 'Run again any time to update to the newest release.\n'
}

# step_finish: step 9, finish.
step_finish() {
  local out line d
  say_step 9 "Checking the install and cleaning up"
  if ((DRY_RUN)); then
    dry_run_finish
    return 0
  fi
  log "+ $BIN_LINK --version (HOME and the Aseprite user folder under $WORK/tmp)"
  out=$(run_host_binary "$BIN_LINK" --version) ||
    die 8 "'$(tilde "$BIN_LINK") --version' failed on this host: $(first_line "$out")"
  line=$(version_line_of "$out") || line=""
  [[ $line == "$BUILT_VERSION_LINE" ]] ||
    die 8 "The installed binary reports '${line:-nothing}', but the build reported '$BUILT_VERSION_LINE'."
  info "$line runs on this host"
  if have_cmd desktop-file-validate && [[ -f $DESKTOP_FILE ]]; then
    if out=$(desktop-file-validate "$DESKTOP_FILE" 2>&1) && [[ -z $out ]]; then
      log "desktop-file-validate: no warnings"
    else
      log "desktop-file-validate $DESKTOP_FILE:" "$out"
      info "desktop-file-validate reported warnings (see the log)"
    fi
  fi
  if [[ ":$PATH:" != *":$PREFIX/bin:"* && ":$PATH:" != *":$PREFIX/bin/:"* ]]; then
    info "Note: $(tilde "$PREFIX/bin") is not in your PATH. The menu entry works anyway; to run aseprite from a terminal, add this line to ~/.bashrc (or your shell's startup file): export PATH=\"$PREFIX/bin:\$PATH\""
  fi
  if ((OPT_KEEP_BUILD)); then
    info "Keeping the source and build folders (--keep-build)"
  else
    run rm -rf -- "$WORK/src" "$WORK/build"
  fi
  run rm -rf -- "$WORK/downloads"
  if [[ -n $SKIA_TAG ]]; then
    for d in "$WORK"/skia/skia-*; do
      if [[ -e $d && $d != "$WORK/skia/skia-$SKIA_TAG" ]]; then run rm -rf -- "$d"; fi
    done
  fi
  empty_tmp
  remove_images_if_needed
  rotate_logs "$WORK/logs" "$LOG_KEEP"
  print_summary
}

dry_run_finish() {
  printf '   [dry-run] %s\n' "$BIN_LINK --version  (must print the same line as the build check)"
  if ((OPT_KEEP_BUILD)); then
    info "[dry-run] would keep the source and build folders (--keep-build)"
  else
    printf '   [dry-run] %s\n' "$(quote_cmd rm -rf -- "$WORK/src" "$WORK/build")"
  fi
  printf '   [dry-run] %s\n' "$(quote_cmd rm -rf -- "$WORK/downloads")" \
    "remove every $WORK/skia/skia-* folder except the current tag's"
  if ((OPT_KEEP_IMAGE)); then
    info "[dry-run] would keep the builder image (--keep-image)"
  else
    printf '   [dry-run] %s\n' "$(quote_cmd docker image rm "$BUILDER_IMAGE")"
    if [[ -f $WORK/pulled-base ]]; then
      printf '   [dry-run] %s\n' "$(quote_cmd docker image rm "$BASE_IMAGE")  (this script pulled it)"
    fi
  fi
  printf '\nDry run: nothing was changed.\n'
}

# ===================================================================== main

main() {
  set -Eeuo pipefail
  init_globals
  install_traps
  parse_args "$@"
  case $ACTION in
    help) usage; exit 0 ;;
    version) printf '%s %s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"; exit 0 ;;
  esac
  resolve_paths
  setup_colors
  if [[ $ACTION == uninstall ]]; then
    main_uninstall
  else
    main_install
  fi
}

main_install() {
  step_preflight
  step_resolve
  step_image
  step_container
  step_install
  step_finish
}

# main_uninstall: --uninstall. Preflight steps 1, 2, 5, 6 and 7 only.
main_uninstall() {
  STEP_TOTAL=2
  say_step 1 "Preflight"
  check_root
  check_bash
  if ((DRY_RUN)); then
    info "[dry-run] would create $(tilde "$WORK") and take the lock $(tilde "$WORK/lock")"
  else
    setup_work_folder
  fi
  info "Work folder: $(tilde "$WORK")"
  info "Install prefix: $(tilde "$PREFIX")"
  step_uninstall
}

read_tty_answer() {
  local a=""
  IFS= read -r a </dev/tty || true
  printf '%s' "$a"
}

# confirm_removal: --yes, or a "y" typed on the terminal; otherwise exit 1.
confirm_removal() {
  local answer
  if ((OPT_YES)); then
    return 0
  fi
  stdin_is_tty || die 1 "Nothing was removed: there is no terminal to ask on. Run with --yes to confirm."
  printf 'Remove these? [y/N] '
  answer=$(read_tty_answer)
  [[ $answer == [yY] || $answer == [yY][eE][sS] ]] || die 1 "Nothing was removed."
}

# uninstall_paths: what to remove, existing paths only. The manifest if
# there is one (entries outside the prefix are skipped), else the fixed
# paths in README.md "Paths and overrides", with bin/aseprite only if it links into the app.
uninstall_paths() {
  local p target
  if [[ -f $MANIFEST_FILE ]]; then
    while IFS= read -r p; do
      if [[ -e $p || -L $p ]]; then printf '%s\n' "$p"; fi
    done < <(manifest_read "$MANIFEST_FILE")
    return 0
  fi
  if [[ -L $BIN_LINK ]]; then
    target=$(readlink -- "$BIN_LINK") || target=""
    if [[ $target == "$APP_DIR"/* ]]; then printf '%s\n' "$BIN_LINK"; fi
  fi
  for p in "$DESKTOP_FILE" "$ICON_ROOT"/*/apps/aseprite.png "$MIME_FILE" "$THUMB_BIN" "$THUMB_ENTRY" "$APP_DIR"; do
    if [[ -e $p || -L $p ]]; then printf '%s\n' "$p"; fi
  done
  return 0
}

remove_path() {
  if [[ -d $1 && ! -L $1 ]]; then
    run rm -rf -- "$1"
  else
    run rm -f -- "$1"
  fi
}

# remove_empty_icon_dirs PATH...: rmdir hicolor/<N>x<N>/apps (and <N>x<N>)
# left empty by removing our icons.
remove_empty_icon_dirs() {
  local p
  for p in "$@"; do
    [[ $p == "$ICON_ROOT"/*/apps/aseprite.png ]] || continue
    rmdir -- "${p%/*}" 2>/dev/null && rmdir -- "${p%/*/*}" 2>/dev/null
  done
  return 0
}

# delete_work_folder: the --purge part of --uninstall. Removes the entries
# this script makes, then the folder if that leaves it empty.
delete_work_folder() {
  local e left
  [[ -d $WORK ]] || return 0
  log "+ rm -rf -- (the script's entries in) $WORK"
  LOG_FILE="" # the run log is inside
  for e in src src.partial build skia downloads logs tmp ccache lock pulled-base; do
    rm -rf -- "${WORK:?}/$e"
  done
  if rmdir -- "$WORK" 2>/dev/null; then
    info "Deleted the work folder $(tilde "$WORK")"
  else
    left=$(shopt -s nullglob dotglob && cd -- "$WORK" && printf '%s ' *)
    warn "Kept $(tilde "$WORK") because it holds files this script did not make: ${left% }"
  fi
}

purge_images_and_work() {
  if have_cmd docker && x_docker info >/dev/null 2>&1; then
    if image_present "$BUILDER_IMAGE"; then
      run x_docker image rm "$BUILDER_IMAGE" ||
        warn "Could not remove $BUILDER_IMAGE (in use?). Remove it later with: docker image rm $BUILDER_IMAGE"
    fi
    remove_pulled_base
  else
    warn "Docker cannot be reached, so the builder image may remain. Remove it later with: docker image rm $BUILDER_IMAGE"
    if [[ -f $WORK/pulled-base ]]; then
      warn "This script also pulled $BASE_IMAGE. Remove it later with: docker image rm $BASE_IMAGE"
    fi
  fi
  delete_work_folder
}

step_uninstall() {
  local p
  local -a paths=()
  say_step 2 "Uninstalling"
  mapfile -t paths < <(uninstall_paths)
  if ((${#paths[@]})); then
    info "These will be removed:"
    for p in "${paths[@]}"; do printf '      %s\n' "$(tilde "$p")"; done
  else
    info "Aseprite is not installed in $(tilde "$PREFIX")"
    ((OPT_PURGE)) || return 0
  fi
  if ((OPT_PURGE)); then
    info "--purge also removes:"
    printf '      %s\n' "the work folder $(tilde "$WORK")" "the Docker image $BUILDER_IMAGE (if present)"
    if [[ -f $WORK/pulled-base ]]; then
      printf '      %s\n' "the Docker image $BASE_IMAGE (this script pulled it)"
    fi
  fi
  if ((DRY_RUN)); then
    info "[dry-run] would remove everything listed above, then refresh the desktop caches"
    printf '\nDry run: nothing was changed.\n'
    return 0
  fi
  confirm_removal
  for p in "${paths[@]+"${paths[@]}"}"; do remove_path "$p"; done
  remove_empty_icon_dirs "${paths[@]+"${paths[@]}"}"
  if ((${#paths[@]})); then
    refresh_caches
    info "Removed the ${#paths[@]} paths listed above"
  fi
  if ((OPT_PURGE)); then purge_images_and_work; fi
  info "Your Aseprite settings in ~/.config/aseprite/ were kept; delete that folder by hand if you no longer want them."
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
