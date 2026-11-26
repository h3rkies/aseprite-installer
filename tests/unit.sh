#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# tests/unit.sh - offline unit tests for install-aseprite.sh.
#
# Each test runs in its own subshell, sources the script and calls its
# functions. No network, no Docker, no root. Temporary files go under
# .test/unit/ in the repo. Guard commands (docker, sudo, curl, network git)
# sit on PATH and fail the test if anything reaches them.
#
# Usage: tests/unit.sh [--list] [test-name...]
#
# shellcheck disable=SC2317,SC2329  # test functions and fakes are called indirectly
# shellcheck disable=SC2034         # tests set script globals the sourced code reads
# shellcheck disable=SC2016         # single quotes: code for fakes and bash -c, expanded later
# shellcheck disable=SC2088         # expected output shows a literal ~

set -uo pipefail

UNIT_REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
UNIT_SCRIPT="$UNIT_REPO/install-aseprite.sh"
UNIT_ROOT="$UNIT_REPO/.test/unit"
UNIT_PATH=$PATH
UNIT_REAL_GIT=$(command -v git || true)
[[ -n $UNIT_REAL_GIT ]] || { echo "unit: git is required (some tests make local git repos)" >&2; exit 1; }

# ------------------------------------------------------------- assertions
# These run inside a test's subshell. fd 3 carries the failure reason.

fail() { printf '%s\n' "$*" >&3; exit 1; }

assert_eq() { # expected actual [what]
  [[ $1 == "$2" ]] || fail "${3:-value}: expected [$1], got [$2]"
}

assert_contains() { # haystack needle [what]
  [[ $1 == *"$2"* ]] || fail "${3:-output}: [$2] not found in [$1]"
}

assert_not_contains() { # haystack needle [what]
  [[ $1 != *"$2"* ]] || fail "${3:-output}: unexpected [$2] in [$1]"
}

assert_rc() { # expected actual [what]
  [[ $1 == "$2" ]] || fail "${3:-exit code}: expected $1, got $2; output: ${OUT:-}${ERR_OUT:+ / stderr: $ERR_OUT}"
}

assert_exists() { [[ -e $1 || -L $1 ]] || fail "missing: $1"; }
assert_missing() { [[ ! -e $1 && ! -L $1 ]] || fail "should not exist: $1"; }

# capture CMD...: run CMD in a subshell; OUT gets stdout+stderr, RC the status.
capture() { OUT=$("$@" 2>&1); RC=$?; }

# capture2 CMD...: like capture, but OUT gets stdout and ERR_OUT stderr.
capture2() {
  OUT=$("$@" 2>"$T/.stderr"); RC=$?
  ERR_OUT=$(<"$T/.stderr")
}

last_line() { local l="" x; while IFS= read -r x; do l=$x; done <<<"$1"; printf '%s' "$l"; }

# fake NAME BODY: write an executable fake command into $T/bin (first on PATH).
fake() {
  printf '#!/usr/bin/env bash\n%s\n' "$2" >"$T/bin/$1"
  chmod +x "$T/bin/$1"
}

# A fake docker that records every call in $T/docker.log. $1 is a bash
# snippet that decides the result from "$@" (default: succeed silently).
fake_docker() {
  fake docker "printf '%s\n' \"\$*\" >>\"$T/docker.log\"
${1:-exit 0}"
}

# Write a fake os-release file and point the script at it.
fake_os_release() { # contents
  printf '%s\n' "$1" >"$T/os-release"
  os_release_file() { printf '%s' "$T/os-release"; }
}

# on_exit_with RC: run the script's EXIT handler as if the run ended with RC.
on_exit_with() {
  (exit "$1")
  on_exit
}

# Run the script as a separate process (main runs), from $T.
run_script() { bash "$UNIT_SCRIPT" "$@"; }

# Common setup for tests that use paths: test work dir and prefix under $T.
use_test_paths() {
  export ASEPRITE_WORK_DIR="$T/work" ASEPRITE_PREFIX="$T/prefix"
}

# =================================================================== tests
# Every function named test_<name> is a test. Keep them in step order.

# ---------------------------------------------------------------- sourcing

test_source_has_no_output_traps_or_option_changes() {
  local out
  out=$(bash -c '
    set +e
    before_o=$(set -o); before_s=$(shopt -p); before_t=$(trap -p)
    source "$1" >"$2" 2>&1
    rc=$?
    [[ $rc == 0 ]] || { echo "source rc=$rc"; exit 1; }
    [[ "$(set -o)" == "$before_o" ]] || { echo "set -o changed"; exit 1; }
    [[ "$(shopt -p)" == "$before_s" ]] || { echo "shopt changed"; exit 1; }
    [[ "$(trap -p)" == "$before_t" ]] || { echo "traps changed: $(trap -p)"; exit 1; }
    [[ ! -s $2 ]] || { echo "output: $(cat "$2")"; exit 1; }
    echo ok' _ "$UNIT_SCRIPT" "$T/source.out" 2>&1)
  assert_eq ok "$out" "sourcing with errexit off"
  out=$(bash -c '
    set -e
    source "$1" >/dev/null 2>&1
    [[ $- == *e* ]] || { echo "errexit lost"; exit 1; }
    echo ok' _ "$UNIT_SCRIPT" 2>&1)
  assert_eq ok "$out" "sourcing with errexit on"
}

test_source_does_not_run_main() {
  capture bash -c 'source "$1" --help; echo "rc=$?"' _ "$UNIT_SCRIPT"
  assert_eq "rc=0" "$OUT" "sourcing with arguments"
}

# ------------------------------------------------------------ help/version

test_help_exits_0_and_lists_every_option() {
  capture2 run_script --help
  assert_rc 0 "$RC"
  local opt
  for opt in --ref --force --yes -y --keep-build --keep-image --jobs -j \
    --uninstall --purge --dry-run --verbose -v --help -h --version; do
    assert_contains "$OUT" "$opt" "--help text"
  done
  assert_contains "$OUT" "Usage:"
  assert_eq "" "$ERR_OUT" "stderr"
  capture run_script -h
  assert_rc 0 "$RC"
  assert_contains "$OUT" "Usage:"
}

test_version_prints_script_version() {
  capture2 run_script --version
  assert_rc 0 "$RC"
  assert_eq "install-aseprite.sh 1.0.0" "$OUT"
}

test_help_and_version_are_handled_first() {
  capture run_script --bogus --help
  assert_rc 0 "$RC" "--help after a bad option"
  capture run_script --jobs x --version
  assert_rc 0 "$RC" "--version after a bad value"
  assert_eq "install-aseprite.sh 1.0.0" "$OUT"
}

# ------------------------------------------------------------ option parsing

test_parse_defaults() {
  init_globals
  parse_args
  assert_eq install "$ACTION"
  assert_eq "" "$OPT_REF"
  assert_eq "0 0 0 0 0 0 0 0" "$OPT_FORCE $OPT_YES $OPT_KEEP_BUILD $OPT_KEEP_IMAGE $OPT_UNINSTALL $OPT_PURGE $DRY_RUN $VERBOSE"
  assert_eq "" "$OPT_JOBS" "jobs before defaulting"
}

test_parse_every_option() {
  init_globals
  parse_args --ref v1.3.17 --force --yes --keep-build --keep-image --jobs 6 --dry-run --verbose
  assert_eq "v1.3.17|1|1|1|1|6|1|1" "$OPT_REF|$OPT_FORCE|$OPT_YES|$OPT_KEEP_BUILD|$OPT_KEEP_IMAGE|$OPT_JOBS|$DRY_RUN|$VERBOSE"
  init_globals
  parse_args -y -j 3 -v --uninstall --purge
  assert_eq "1|3|1|1|1|uninstall" "$OPT_YES|$OPT_JOBS|$VERBOSE|$OPT_UNINSTALL|$OPT_PURGE|$ACTION"
  init_globals
  parse_args --ref=main --jobs=12
  assert_eq "main|12" "$OPT_REF|$OPT_JOBS" "--opt=value forms"
}

test_bad_option_exits_2_with_usage_on_stderr() {
  capture2 run_script --bogus
  assert_rc 2 "$RC"
  assert_eq "" "$OUT" "stdout"
  assert_contains "$ERR_OUT" "Usage:"
  assert_contains "$ERR_OUT" "--bogus"
  local last; last=$(last_line "$ERR_OUT")
  assert_contains "$last" "[1/9]" "last stderr line names the step"
  assert_contains "$last" "log" "last stderr line names the log"
  assert_missing "$T/home/.local"
}

test_bad_values_exit_2() {
  local args
  for args in "--jobs x" "--jobs 0" "--jobs -3" "--jobs 1.5" "--jobs" "-j" "--jobs=" \
    "--ref" "--ref=" "--ref --force" "--purge" "--purge --yes" "positional" "-yv" "--"; do
    # shellcheck disable=SC2086  # word splitting of the case is intended
    capture run_script $args
    assert_rc 2 "$RC" "args [$args]"
  done
}

# ------------------------------------------------------------------- paths

test_default_work_dir_is_next_to_the_script() {
  local got
  init_globals
  resolve_paths
  assert_eq "$UNIT_REPO/.work" "$WORK" "sourced by absolute path from another folder"
  got=$(cd "$UNIT_REPO/tests" && bash -c 'source ../install-aseprite.sh && init_globals && resolve_paths && printf %s "$WORK"')
  assert_eq "$UNIT_REPO/.work" "$got" "sourced by a relative path from tests/"
  mkdir -p "$T/elsewhere"
  ln -s "$UNIT_SCRIPT" "$T/elsewhere/install-aseprite.sh"
  got=$(cd "$T/elsewhere" && bash -c 'source ./install-aseprite.sh && init_globals && resolve_paths && printf %s "$WORK"')
  assert_eq "$UNIT_REPO/.work" "$got" "through a symlink in another folder"
}

test_default_prefix_and_derived_paths() {
  init_globals
  resolve_paths
  local p="$HOME/.local"
  assert_eq "$p" "$PREFIX"
  assert_eq "$p/opt/aseprite" "$APP_DIR"
  assert_eq "$p/opt/aseprite/aseprite" "$BIN"
  assert_eq "$p/opt/aseprite/.aseprite-installer/state" "$STATE_FILE"
  assert_eq "$p/opt/aseprite/.aseprite-installer/manifest" "$MANIFEST_FILE"
  assert_eq "$p/bin/aseprite" "$BIN_LINK"
  assert_eq "$p/bin/aseprite-thumbnailer" "$THUMB_BIN"
  assert_eq "$p/share/applications/aseprite.desktop" "$DESKTOP_FILE"
  assert_eq "$p/share/icons/hicolor" "$ICON_ROOT"
  assert_eq "$p/share/mime/packages/aseprite.xml" "$MIME_FILE"
  assert_eq "$p/share/thumbnailers/aseprite.thumbnailer" "$THUMB_ENTRY"
}

test_path_overrides_are_used_and_normalized() {
  ASEPRITE_WORK_DIR="$T//w//" ASEPRITE_PREFIX="$T/p/"
  init_globals
  resolve_paths
  assert_eq "$T/w" "$WORK"
  assert_eq "$T/p" "$PREFIX"
  ASEPRITE_WORK_DIR="" ASEPRITE_PREFIX=""
  resolve_paths
  assert_eq "$UNIT_REPO/.work" "$WORK" "empty override means default"
  assert_eq "$HOME/.local" "$PREFIX" "empty override means default"
  ASEPRITE_WORK_DIR="$T/my work"
  resolve_paths
  assert_eq "$T/my work" "$WORK" "spaces are fine in the work folder"
}

test_relative_paths_exit_2() {
  local v
  for v in rel/path ./x '~/x' x; do
    capture env ASEPRITE_PREFIX="$v" bash "$UNIT_SCRIPT" --dry-run
    assert_rc 2 "$RC" "ASEPRITE_PREFIX=$v"
    assert_contains "$OUT" "ASEPRITE_PREFIX"
    capture env ASEPRITE_WORK_DIR="$v" bash "$UNIT_SCRIPT" --dry-run
    assert_rc 2 "$RC" "ASEPRITE_WORK_DIR=$v"
    assert_contains "$OUT" "ASEPRITE_WORK_DIR"
  done
  assert_missing "$T/home/.local"
}

test_unsafe_paths_exit_2() {
  local v
  for v in / "$HOME" "$HOME/" "$T/a/../b" "$T/./a" "$T/a:b" $'/x\ny'; do
    capture env ASEPRITE_WORK_DIR="$v" bash "$UNIT_SCRIPT" --dry-run
    assert_rc 2 "$RC" "ASEPRITE_WORK_DIR=[$v]"
  done
  for v in / "$T/my prefix" "$T/a\$b" "$T/a\"b" "$T/a'b" "$T/a%b" "$T/a\\b" "$T/a\`b" "$T/a/../b" $'/x\ty'; do
    capture env ASEPRITE_PREFIX="$v" bash "$UNIT_SCRIPT" --dry-run
    assert_rc 2 "$RC" "ASEPRITE_PREFIX=[$v]"
  done
}

test_tilde_shortens_home_paths() {
  assert_eq "~/.local/bin/aseprite" "$(tilde "$HOME/.local/bin/aseprite")"
  assert_eq "/opt/x" "$(tilde /opt/x)"
  assert_eq "${HOME}x/y" "$(tilde "${HOME}x/y")" "a sibling of HOME is not shortened"
}

# ------------------------------------------------------- versions and refs

test_stable_tag_pick_from_tag_list() {
  local got
  got=$(printf '%s\n' v1.3.18-beta3 v1.3.9 v1.3.10 v1.3.18.6 v1.4-rc1 | pick_stable_tag)
  assert_eq v1.3.18.6 "$got"
}

test_stable_tag_pick_from_ls_remote_output() {
  local out got
  out=$'aaa\trefs/tags/v1.3.9\nbbb\trefs/tags/v1.3.10\nccc\trefs/tags/v1.3.18.6\nddd\trefs/tags/v1.3.18-beta3\neee\trefs/tags/v2\nfff\trefs/tags/1.3.20\nggg\trefs/tags/v1.3.19.x\nhhh\trefs/heads/v9.9'
  got=$(tag_names_from_ls_remote <<<"$out" | pick_stable_tag)
  assert_eq v1.3.18.6 "$got"
}

test_no_stable_tag_fails() {
  local got rc
  got=$(printf '%s\n' v1.4-rc1 v1.3.18-beta3 | pick_stable_tag)
  rc=$?
  assert_rc 1 "$rc"
  assert_eq "" "$got"
}

test_version_ge() {
  local pair
  for pair in "3.20 3.20" "3.31.6 3.20" "2.39 2.39" "2.42 2.39" "2.100 2.39" "3.4.33 3.4.32" "10.0 9.9"; do
    # shellcheck disable=SC2086
    version_ge $pair || fail "version_ge $pair should be true"
  done
  for pair in "3.19 3.20" "2.38 2.39" "3.4.31 3.4.32" "9.9 10.0"; do
    # shellcheck disable=SC2086
    ! version_ge $pair || fail "version_ge $pair should be false"
  done
}

test_skia_tag_file_is_trimmed() {
  printf '  m124-08a5439a6b \n ' >"$T/skia-tag.txt"
  assert_eq m124-08a5439a6b "$(read_skia_tag "$T/skia-tag.txt")"
  printf 'm125-abc' >"$T/skia-tag.txt"
  assert_eq m125-abc "$(read_skia_tag "$T/skia-tag.txt")" "no trailing newline"
}

test_skia_tag_missing_empty_or_odd_fails() {
  read_skia_tag "$T/none.txt" >/dev/null && fail "missing file accepted"
  : >"$T/empty.txt"
  read_skia_tag "$T/empty.txt" >/dev/null && fail "empty file accepted"
  printf '   \n' >"$T/blank.txt"
  read_skia_tag "$T/blank.txt" >/dev/null && fail "blank file accepted"
  printf '../../etc\n' >"$T/odd.txt"
  read_skia_tag "$T/odd.txt" >/dev/null && fail "path-like tag accepted"
  return 0
}

test_cmake_minimum_parsed() {
  assert_eq 3.20 "$(parse_cmake_min <<<'cmake_minimum_required(VERSION 3.20)')"
  assert_eq 3.20 "$(parse_cmake_min <<<$'# ASEPRITE\n\ncmake_minimum_required(VERSION 3.20)\nproject(aseprite C CXX)')"
  assert_eq 3.16 "$(parse_cmake_min <<<'cmake_minimum_required(VERSION 3.16...3.28)')" "range syntax"
  assert_eq 3.5 "$(parse_cmake_min <<<'  CMAKE_MINIMUM_REQUIRED( VERSION 3.5 FATAL_ERROR )')" "upper case"
  parse_cmake_min <<<'project(x)' >/dev/null && fail "no cmake_minimum_required accepted"
  return 0
}

test_cmake_version_check() {
  ! cmake_new_enough 3.19 3.20 || fail "CMake 3.19 passed a 3.20 minimum"
  cmake_new_enough 3.20 3.20 || fail "CMake 3.20 failed a 3.20 minimum"
  cmake_new_enough 3.31.6 3.20 || fail "CMake 3.31.6 failed a 3.20 minimum"
  assert_eq 3.28.3 "$(parse_cmake_version <<<$'cmake version 3.28.3\n\nCMake suite maintained and supported by Kitware (kitware.com/cmake).')"
}

SHA_A=c48fa3b1de38098d74e5c5fc2b7f6ac43d2b5329
SHA_B=331e898ef405d919539c03fd1675691cfa16c3a3
SHA_C=e593180ee7cb0349f40c4e057f357830ebb0fa10

test_resolve_ref_lightweight_tag() {
  x_git() { printf '%s\n' "$*" >>"$T/git.log"; printf '%s\trefs/tags/v1.3.17\n' "$SHA_A"; }
  init_globals
  resolve_ref v1.3.17
  assert_eq "tag $SHA_A" "$REF_KIND $REF_COMMIT"
  local args; args=$(<"$T/git.log")
  assert_contains "$args" "ls-remote https://github.com/aseprite/aseprite.git"
  assert_contains "$args" "refs/tags/v1.3.17^{}" "asks for the peeled tag"
  assert_contains "$args" "refs/heads/v1.3.17" "asks for the branch"
}

test_resolve_ref_annotated_tag_uses_peeled_commit() {
  x_git() { printf '%s\trefs/tags/v9.9\n%s\trefs/tags/v9.9^{}\n' "$SHA_A" "$SHA_B"; }
  init_globals
  resolve_ref v9.9
  assert_eq "tag $SHA_B" "$REF_KIND $REF_COMMIT"
}

test_resolve_ref_branch_and_tag_priority() {
  x_git() { printf '%s\trefs/heads/main\n' "$SHA_C"; }
  init_globals
  resolve_ref main
  assert_eq "branch $SHA_C" "$REF_KIND $REF_COMMIT"
  x_git() { printf '%s\trefs/heads/both\n%s\trefs/tags/both\n' "$SHA_C" "$SHA_A"; }
  resolve_ref both
  assert_eq "tag $SHA_A" "$REF_KIND $REF_COMMIT" "a tag wins over a branch"
}

test_resolve_ref_unknown_exits_3() {
  x_git() { printf '%s\trefs/heads/feature/v1.3.17\n%s\trefs/tags/v1.3.17-beta1\n' "$SHA_A" "$SHA_B"; }
  init_globals
  capture resolve_ref v1.3.17
  assert_rc 3 "$RC" "only longer names match"
  x_git() { :; }
  capture resolve_ref no-such-ref
  assert_rc 3 "$RC"
  assert_contains "$OUT" "No tag or branch named no-such-ref"
}

test_resolve_ref_network_failure_exits_3() {
  x_git() { echo "fatal: unable to access 'https://github.com/aseprite/aseprite.git/': Could not resolve host: github.com" >&2; return 128; }
  init_globals
  capture resolve_ref v1.3.17
  assert_rc 3 "$RC"
  assert_contains "$OUT" "Could not resolve host"
}

test_latest_stable_tag_from_remote() {
  x_git() {
    printf '%s\n' "$*" >>"$T/git.log"
    printf '%s\trefs/tags/%s\n' "$SHA_A" v1.3.9 "$SHA_A" v1.3.10 "$SHA_B" v1.3.18.6 "$SHA_C" v1.3.18-beta3 "$SHA_C" v1.4-rc1
  }
  init_globals
  latest_stable_tag
  assert_eq v1.3.18.6 "$LATEST_TAG"
  assert_contains "$(<"$T/git.log")" "ls-remote --tags --refs https://github.com/aseprite/aseprite.git"
  x_git() { printf '%s\trefs/tags/v1.4-rc1\n' "$SHA_A"; }
  capture latest_stable_tag
  assert_rc 3 "$RC" "no stable tag"
  x_git() { return 128; }
  capture latest_stable_tag
  assert_rc 3 "$RC" "network failure"
}

# ---------------------------------------------------------------- platform

# fake_platform OS GETCONF-OUTPUT|FAIL [MACHINE]
fake_platform() {
  PLAT_OS=$1 PLAT_LIBC=$2 PLAT_ARCH=${3:-x86_64}
  x_uname() {
    case $1 in
      -s) printf '%s\n' "$PLAT_OS" ;;
      -m) printf '%s\n' "$PLAT_ARCH" ;;
    esac
  }
  x_getconf() {
    [[ $PLAT_LIBC != FAIL ]] || { echo "getconf: Unrecognized variable 'GNU_LIBC_VERSION'" >&2; return 1; }
    printf '%s\n' "$PLAT_LIBC"
  }
}

test_glibc_check_passes_239_and_242() {
  init_globals
  fake_platform Linux "glibc 2.39"
  capture check_platform
  assert_rc 0 "$RC" "glibc 2.39"
  assert_eq "" "$OUT" "check_platform is silent on success"
  fake_platform Linux "glibc 2.42"
  capture check_platform
  assert_rc 0 "$RC" "glibc 2.42"
  assert_eq "" "$OUT"
}

test_glibc_check_fails_238_and_no_glibc() {
  init_globals
  fake_platform Linux "glibc 2.38"
  capture check_platform
  assert_rc 1 "$RC" "glibc 2.38"
  assert_contains "$OUT" "error:"
  assert_contains "$OUT" "2.38"
  assert_contains "$OUT" "too old"
  fake_platform Linux FAIL
  capture check_platform
  assert_rc 1 "$RC" "failing getconf (musl)"
  assert_contains "$OUT" "error: No glibc found"
  fake_platform Linux "musl libc (x86_64)"
  capture check_platform
  assert_rc 1 "$RC" "unparsable getconf output"
}

test_not_linux_exits_1() {
  init_globals
  fake_platform Darwin "glibc 2.40"
  capture check_platform
  assert_rc 1 "$RC"
  assert_contains "$OUT" "Darwin"
}

test_os_release_is_logged_but_never_decides() {
  init_globals
  fake_platform Linux "glibc 2.40"
  fake_os_release $'NAME="Weird"\nID=weird\nID_LIKE="odd other"\nVERSION_ID="7.1"'
  check_platform
  assert_contains "${LOG_BUFFER[*]}" "ID=weird ID_LIKE=odd other VERSION_ID=7.1"
  rm -f "$T/os-release"
  capture check_platform
  assert_rc 0 "$RC" "no os-release file"
}

test_arch_must_be_x86_64() {
  init_globals
  fake_platform Linux "glibc 2.40" aarch64
  capture check_arch
  assert_rc 1 "$RC"
  assert_contains "$OUT" "aarch64"
  assert_contains "$OUT" "Skia"
  fake_platform Linux "glibc 2.40" x86_64
  capture check_arch
  assert_rc 0 "$RC"
}

test_root_exits_1() {
  use_test_paths
  is_root() { return 0; }
  capture main --dry-run
  assert_rc 1 "$RC"
  assert_contains "$OUT" "Run as your normal user; the script never needs root."
  assert_missing "$T/work"
  assert_missing "$T/prefix"
  capture main --uninstall --yes
  assert_rc 1 "$RC" "uninstall as root"
}

test_bash_older_than_4_exits_1() {
  init_globals
  bash_major() { echo 3; }
  capture check_bash
  assert_rc 1 "$RC"
  assert_contains "$OUT" "Bash 4"
  bash_major() { echo 5; }
  capture check_bash
  assert_rc 0 "$RC"
}

# ---------------------------------------------- runtime libraries and hints

ALL_SONAMES=(libstdc++.so.6 libgcc_s.so.1 libX11.so.6 libxcb.so.1 libXext.so.6 libXcursor.so.1 libXi.so.6 libXrandr.so.2 libGL.so.1 libfontconfig.so.1)

LDCONFIG_SAMPLE="1234 libs found in cache \`/etc/ld.so.cache'
	libz.so.1 (libc6,x86-64) => /lib64/libz.so.1
	libstdc++.so.6 (libc6,x86-64) => /lib64/libstdc++.so.6
	libgcc_s.so.1 (libc6,x86-64) => /lib64/libgcc_s.so.1
	libX11.so.6 (libc6,x86-64) => /lib64/libX11.so.6
	libxcb.so.1 (libc6,x86-64) => /lib64/libxcb.so.1
	libXext.so.6 (libc6,x86-64) => /lib64/libXext.so.6
	libXcursor.so.1 (libc6,x86-64) => /lib64/libXcursor.so.1
	libXi.so.6 (libc6,x86-64) => /lib64/libXi.so.6
	libXrandr.so.2 (libc6,x86-64) => /lib64/libXrandr.so.2
	libGL.so.1 (libc6,x86-64) => /lib64/libGL.so.1
	libfontconfig.so.1 (libc6,x86-64, OS ABI: Linux 3.2.0) => /lib64/libfontconfig.so.1
	libold32.so.1 (libc6) => /lib/libold32.so.1
Cache generated by: ldconfig (GNU libc) stable release version 2.44"

fake_ldconfig() { # OUTPUT | FAIL
  LDC_OUT=$1
  x_ldconfig() { [[ $LDC_OUT != FAIL ]] || return 127; printf '%s\n' "$LDC_OUT"; }
}

hint_line() { # text -> its hint: line
  local l
  while IFS= read -r l; do [[ $l == hint:* ]] && printf '%s' "$l"; done <<<"$1"
}

test_family_from_os_release() {
  local f="$T/osr" pair
  for pair in "ID=fedora|fedora" "ID=debian|debian" "ID=arch|arch" \
    $'ID=opensuse-tumbleweed\nID_LIKE="opensuse suse"|suse' \
    $'ID=linuxmint\nID_LIKE="ubuntu debian"|debian' \
    'ID="rhel"|fedora' $'ID=rocky\nID_LIKE="rhel centos fedora"|fedora' \
    'ID=ubuntu|debian' $'ID=manjaro\nID_LIKE=arch|arch' "ID='debian'|debian" \
    'ID=gentoo|' $'ID=nixos\nID_LIKE=""|'; do
    printf '%s\n' "${pair%|*}" >"$f"
    assert_eq "${pair##*|}" "$(detect_family "$f")" "family for [${pair%|*}]"
  done
  detect_family "$T/missing" >/dev/null && fail "a missing os-release gave a family"
  return 0
}

test_install_hint_lines_per_family() {
  assert_eq "hint: sudo dnf install libstdc++ libgcc libX11 libxcb libXext libXcursor libXi libXrandr libglvnd-glx fontconfig" \
    "$(install_hint fedora "${ALL_SONAMES[@]}")"
  assert_eq "hint: sudo apt install libstdc++6 libgcc-s1 libx11-6 libxcb1 libxext6 libxcursor1 libxi6 libxrandr2 libgl1 libfontconfig1" \
    "$(install_hint debian "${ALL_SONAMES[@]}")"
  assert_eq "hint: sudo pacman -S --needed libstdc++ libgcc libx11 libxcb libxext libxcursor libxi libxrandr libglvnd fontconfig" \
    "$(install_hint arch "${ALL_SONAMES[@]}")" "arch (names checked in archlinux:latest)"
  assert_eq "hint: sudo zypper install libstdc++6 libgcc_s1 libX11-6 libxcb1 libXext6 libXcursor1 libXi6 libXrandr2 libglvnd libfontconfig1" \
    "$(install_hint suse "${ALL_SONAMES[@]}")" "openSUSE (libGL.so.1 comes from libglvnd)"
  assert_eq "hint: sudo pacman -S --needed libglvnd" "$(install_hint arch libGL.so.1 libGL.so.1)" "no duplicates"
  assert_eq "hint: sudo apt install libgl1" "$(install_hint debian libGL.so.1)"
  install_hint fedora libunknown.so.1 >/dev/null && fail "hint for a library not in the table"
  install_hint "" libGL.so.1 >/dev/null && fail "hint for an unknown family"
  return 0
}

test_ldconfig_output_parsing() {
  local got
  got=$(ldconfig_sonames <<<"$LDCONFIG_SAMPLE")
  assert_contains "$got" "libfontconfig.so.1" "entry with OS ABI flags"
  assert_contains "$got" "libstdc++.so.6"
  assert_contains "$got" "libz.so.1"
  assert_not_contains "$got" "libold32.so.1" "32-bit entries do not count"
  assert_not_contains "$got" "Cache generated"
}

test_ldconfig_candidates_are_tried_in_order() {
  assert_eq "ldconfig /sbin/ldconfig /usr/sbin/ldconfig" "${LDCONFIG_CANDIDATES[*]}"
  fake fake-ldconfig 'printf "1 libs found\n\tlibq.so.1 (libc6,x86-64) => /x/libq.so.1\n"'
  LDCONFIG_CANDIDATES=("$T/nope/ldconfig" "$T/bin/fake-ldconfig")
  assert_contains "$(x_ldconfig -p)" "libq.so.1"
  LDCONFIG_CANDIDATES=("$T/nope/ldconfig")
  x_ldconfig -p >/dev/null 2>&1 && fail "no candidate should fail"
  return 0
}

test_check_runtime_libs_all_found_is_silent() {
  init_globals
  fake_ldconfig "$LDCONFIG_SAMPLE"
  capture check_runtime_libs
  assert_rc 0 "$RC"
  assert_eq "" "$OUT"
}

test_check_runtime_libs_missing_exits_4_with_hint() {
  init_globals
  fake_ldconfig "$(grep -vE 'libX11|libGL' <<<"$LDCONFIG_SAMPLE")"
  fake_os_release 'ID=fedora'
  capture2 check_runtime_libs
  assert_rc 4 "$RC"
  assert_contains "$ERR_OUT" "libX11.so.6"
  assert_contains "$ERR_OUT" "libGL.so.1"
  assert_eq "hint: sudo dnf install libX11 libglvnd-glx" "$(hint_line "$ERR_OUT")"
  fake_os_release $'ID=linuxmint\nID_LIKE="ubuntu debian"'
  capture2 check_runtime_libs
  assert_eq "hint: sudo apt install libx11-6 libgl1" "$(hint_line "$ERR_OUT")" "ID_LIKE family"
}

test_check_runtime_libs_end_to_end_for_arch_and_opensuse() {
  init_globals
  fake_ldconfig "$(grep -vE 'libstdc|libgcc_s|libGL' <<<"$LDCONFIG_SAMPLE")"
  fake_os_release $'NAME="Arch Linux"\nID=arch\nBUILD_ID=rolling'
  capture2 check_runtime_libs
  assert_rc 4 "$RC" "arch"
  assert_contains "$ERR_OUT" "libstdc++.so.6 libgcc_s.so.1 libGL.so.1"
  assert_eq "hint: sudo pacman -S --needed libstdc++ libgcc libglvnd" "$(hint_line "$ERR_OUT")"
  fake_os_release $'NAME="openSUSE Tumbleweed"\nID="opensuse-tumbleweed"\nID_LIKE="opensuse suse"\nVERSION_ID="20261120"'
  capture2 check_runtime_libs
  assert_rc 4 "$RC" "opensuse"
  assert_eq "hint: sudo zypper install libstdc++6 libgcc_s1 libglvnd" "$(hint_line "$ERR_OUT")"
  fake_os_release $'ID=debian\nVERSION_ID="13"'
  capture2 check_runtime_libs
  assert_eq "hint: sudo apt install libstdc++6 libgcc-s1 libgl1" "$(hint_line "$ERR_OUT")" "debian"
}

test_check_runtime_libs_unknown_family_names_only() {
  init_globals
  fake_ldconfig "$(grep -v 'libGL' <<<"$LDCONFIG_SAMPLE")"
  fake_os_release 'ID=gentoo'
  capture2 check_runtime_libs
  assert_rc 4 "$RC"
  assert_contains "$ERR_OUT" "libGL.so.1"
  assert_not_contains "$ERR_OUT" "hint:"
  os_release_file() { printf '%s' "$T/none"; }
  capture2 check_runtime_libs
  assert_rc 4 "$RC" "no os-release"
  assert_not_contains "$ERR_OUT" "hint:"
}

test_check_runtime_libs_without_ldconfig_warns() {
  init_globals
  fake_ldconfig FAIL
  capture check_runtime_libs
  assert_rc 0 "$RC"
  assert_contains "$OUT" "warning:"
  assert_contains "$OUT" "ldconfig"
}

LDD_CLEAN=$'\tlinux-vdso.so.1 (0x00007ffd5a1e0000)
\tlibX11.so.6 => /lib64/libX11.so.6 (0x00007f2c1a000000)
\tlibXcursor.so.1 => /lib64/libXcursor.so.1 (0x00007f2c19ff0000)
\tlibc.so.6 => /lib64/libc.so.6 (0x00007f2c19e00000)
\t/lib64/ld-linux-x86-64.so.2 (0x00007f2c1a200000)'

test_ldd_output_parsing() {
  assert_eq "" "$(parse_ldd_problems <<<"$LDD_CLEAN")" "clean output"
  assert_eq "missing libXi.so.6" "$(parse_ldd_problems <<<$'\tlibXi.so.6 => not found\n\tlibc.so.6 => /lib64/libc.so.6 (0x1)')"
  local v
  v=$(parse_ldd_problems <<<"./aseprite: /lib64/libstdc++.so.6: version \`GLIBCXX_3.4.32' not found (required by ./aseprite)")
  assert_contains "$v" "version "
  assert_contains "$v" "GLIBCXX_3.4.32"
}

test_fake_missing_lib_hook() {
  local got
  got=$(fake_missing_lib libXcursor.so.1 <<<"$LDD_CLEAN")
  assert_contains "$got" "libXcursor.so.1 => not found"
  assert_not_contains "$got" "/lib64/libXcursor.so.1"
  assert_contains "$got" "libX11.so.6 => /lib64/libX11.so.6"
  got=$(fake_missing_lib libfoo.so.9 <<<"$LDD_CLEAN")
  assert_contains "$got" "libfoo.so.9 => not found" "absent library is added"
}

test_check_binary_libs() {
  init_globals
  x_ldd() { printf '%s\n' "$LDD_CLEAN"; }
  capture check_binary_libs /x/aseprite
  assert_rc 0 "$RC" "clean ldd, hook unset"
  ASEPRITE_TEST_FAKE_MISSING_LIB=""
  capture check_binary_libs /x/aseprite
  assert_rc 0 "$RC" "hook set but empty"
  ASEPRITE_TEST_FAKE_MISSING_LIB=libXcursor.so.1
  fake_os_release 'ID=debian'
  capture2 check_binary_libs /x/aseprite
  assert_rc 1 "$RC" "fake missing library"
  assert_contains "$ERR_OUT" "libXcursor.so.1"
  assert_eq "hint: sudo apt install libxcursor1" "$(hint_line "$ERR_OUT")"
  unset ASEPRITE_TEST_FAKE_MISSING_LIB
  x_ldd() { printf '%s\n' "$LDD_CLEAN"; echo "/x/aseprite: /lib64/libstdc++.so.6: version \`GLIBCXX_3.4.32' not found (required by /x/aseprite)" >&2; }
  capture2 check_binary_libs /x/aseprite
  assert_rc 1 "$RC" "version not found"
  assert_contains "$ERR_OUT" "GLIBCXX_3.4.32"
  assert_contains "$ERR_OUT" "older than the build needs"
  x_ldd() { echo "	not a dynamic executable"; return 1; }
  capture2 check_binary_libs /x/aseprite
  assert_rc 1 "$RC" "ldd failure"
}

# ---------------------------------------------- logging, run and dry-run

test_quote_cmd() {
  assert_eq "docker run --rm" "$(quote_cmd docker run --rm)"
  assert_eq "bash -c 'apt-get update && echo it'\\''s'" "$(quote_cmd bash -c "apt-get update && echo it's")"
  assert_eq "''" "$(quote_cmd "")" "empty argument"
  assert_eq "a=b /x/y:z" "$(quote_cmd a=b /x/y:z)"
}

test_run_logs_command_and_output() {
  init_globals
  LOG_FILE="$T/run.log"
  capture run printf 'hello\n'
  assert_rc 0 "$RC"
  assert_eq "" "$OUT" "nothing on the terminal without --verbose"
  local logged; logged=$(<"$T/run.log")
  assert_contains "$logged" "+ printf 'hello\n'"
  assert_contains "$logged" $'\nhello'
  VERBOSE=1
  capture run printf 'shown\n'
  assert_eq "shown" "$OUT" "--verbose streams output"
  VERBOSE=0
  run x_date +%s
  assert_contains "$(<"$T/run.log")" "+ date +%s" "the x_ wrapper prefix is not shown"
  capture run false
  assert_rc 1 "$RC" "the command's status is returned"
}

test_run_in_dry_run_prints_and_runs_nothing() {
  init_globals
  DRY_RUN=1
  capture run touch "$T/should-not-exist"
  assert_rc 0 "$RC"
  assert_contains "$OUT" "[dry-run] touch $T/should-not-exist"
  assert_missing "$T/should-not-exist"
}

test_log_buffer_is_flushed_when_the_log_opens() {
  init_globals
  log "early line"
  mkdir -p "$T/logs"
  open_log "$T/logs/run-20261126-101500.log"
  log "later line"
  local logged; logged=$(<"$T/logs/run-20261126-101500.log")
  assert_contains "$logged" "early line"
  assert_contains "$logged" "later line"
  assert_eq 0 "${#LOG_BUFFER[@]}" "buffer emptied"
}

test_colors_only_on_a_terminal_without_NO_COLOR() {
  init_globals
  stdout_is_tty() { return 0; }
  stderr_is_tty() { return 0; }
  setup_colors
  assert_eq "1 1" "$COLOR_OUT $COLOR_ERR"
  assert_contains "$(say_step 3 Test)" $'\033[' "colour on a terminal"
  NO_COLOR="" setup_colors
  assert_eq "0 0" "$COLOR_OUT $COLOR_ERR" "NO_COLOR set (even empty)"
  stdout_is_tty() { return 1; }
  setup_colors
  assert_eq 0 "$COLOR_OUT" "stdout not a terminal"
  assert_eq "==> [3/9] Test" "$(say_step 3 Test)"
}

# ------------------------------------------------------ state and manifest

test_state_write_then_read() {
  local -a kv=(ref=v1.3.18.6 "commit=$SHA_B" version=1.3.18.6-dev skia_tag=m124-08a5439a6b
    build_base=ubuntu:24.04 installed_at=2026-11-26T10:15:00+01:00 script_version=1.0.0)
  state_write "$T/state" "${kv[@]}"
  local pair
  for pair in "${kv[@]}"; do
    assert_eq "${pair#*=}" "$(state_get "$T/state" "${pair%%=*}")" "state key ${pair%%=*}"
  done
  assert_eq "$(printf '%s\n' "${kv[@]}")" "$(<"$T/state")" "key=value lines"
  state_get "$T/state" nope >/dev/null && fail "missing key found"
  state_get "$T/none" ref >/dev/null && fail "missing file read"
  state_write "$T/s2" "x=a=b" "y="
  assert_eq "a=b" "$(state_get "$T/s2" x)" "value with ="
  assert_eq "" "$(state_get "$T/s2" y)" "empty value"
}

test_manifest_write_and_read() {
  ASEPRITE_PREFIX="$T/p"
  init_globals
  resolve_paths
  manifest_write "$T/m" "$BIN_LINK" "$DESKTOP_FILE" "$APP_DIR"
  assert_eq "$(printf '%s\n' "$BIN_LINK" "$DESKTOP_FILE" "$APP_DIR")" "$(manifest_read "$T/m")"
}

test_manifest_read_skips_paths_outside_the_prefix() {
  ASEPRITE_PREFIX="$T/p"
  init_globals
  resolve_paths
  printf '%s\n' "$BIN_LINK" /etc/passwd relative/x "$PREFIX/../evil" "$PREFIX" "${PREFIX}x/y" "" "$PREFIX/share/./x" >"$T/m"
  capture2 manifest_read "$T/m"
  assert_eq "$BIN_LINK" "$OUT"
  assert_contains "$ERR_OUT" "/etc/passwd"
}

# --------------------------------------------------------------- log files

test_rotate_logs_keeps_the_five_newest() {
  mkdir -p "$T/logs"
  local f
  for f in run-20261120-100000 build-20261120-100000 run-20261121-090000 run-20261122-080000 \
    build-20261122-080000 run-20261123-070000 run-20261124-060000 build-20261124-060000; do
    : >"$T/logs/$f.log"
  done
  : >"$T/logs/notes.txt"
  : >"$T/logs/other.log"
  rotate_logs "$T/logs" 5
  local left; left=$(cd "$T/logs" && printf '%s\n' * | LC_ALL=C sort | tr '\n' ' ')
  assert_eq "build-20261122-080000.log build-20261124-060000.log notes.txt other.log run-20261122-080000.log run-20261123-070000.log run-20261124-060000.log " "$left"
}

# ----------------------------------------------------------- ninja progress

test_ninja_progress_parsing() {
  local text=$'[1/1529] Building CXX object laf/base/CMakeFiles/laf-base.dir/base.cpp.o
warning: unused variable
[812/1529] Building CXX object src/app/CMakeFiles/app-lib.dir/app.cpp.o
In file included from /work/src/src/app/app.cpp:12:'
  assert_eq 812/1529 "$(parse_ninja_progress <<<"$text")"
  parse_ninja_progress <<<"no progress here" >/dev/null && fail "progress found in plain text"
  assert_eq "[812/1529] 53%" "$(progress_text 812 1529)"
  assert_eq "[0/0] 0%" "$(progress_text 0 0)"
}

# ----------------------------------------------------------- desktop files
# Self-written samples shaped like the files an Aseprite source tree provides.

DESKTOP_SAMPLE='[Desktop Entry]
Type=Application
Name=Aseprite
Comment=Test fixture written for this repo (not copied from Aseprite)
Icon=aseprite
Categories=Graphics;
Exec=aseprite %U
TryExec=aseprite
Terminal=false
MimeType=image/png;image/x-aseprite;'

THUMB_SCRIPT_SAMPLE='#!/bin/sh
# Test fixture written for this repo (not copied from Aseprite): two calls to
# rewrite, plus a mention of the name that must stay as it is.
out=$2
if [ -n "$3" ]; then
  aseprite -b "$1" --shrink-to "$3,$3" --sheet "$out"
else
  aseprite -b "$1" --sheet "$out"
fi
echo "usage: aseprite-thumbnailer input output [size]"'

THUMB_ENTRY_SAMPLE='[Thumbnailer Entry]
TryExec=aseprite-thumbnailer
Exec=aseprite-thumbnailer %i %o %s
MimeType=image/png;image/x-aseprite;'

test_desktop_file_rewrite() {
  printf '%s\n' "$DESKTOP_SAMPLE" >"$T/in.desktop"
  local got want
  got=$(rewrite_desktop_file "$T/in.desktop" /abs/path)
  want=${DESKTOP_SAMPLE/Exec=aseprite %U/Exec=\/abs\/path %U}
  want=${want/TryExec=aseprite/TryExec=\/abs\/path}
  assert_eq "$want" "$got"
  assert_contains "$got" $'\nExec=/abs/path %U\n'
  assert_contains "$got" $'\nTryExec=/abs/path\n'
}

test_desktop_rewrite_only_touches_the_main_group() {
  printf '%s\n' '[Desktop Entry]' 'Name=A' 'Exec = aseprite %U' '' '[Desktop Action New]' 'Exec=aseprite --new' 'TryExec=aseprite' >"$T/in.desktop"
  local got
  got=$(rewrite_desktop_file "$T/in.desktop" /abs/path)
  assert_eq "$(printf '%s\n' '[Desktop Entry]' 'Name=A' 'Exec=/abs/path %U' '' '[Desktop Action New]' 'Exec=aseprite --new' 'TryExec=aseprite')" "$got"
}

test_thumbnailer_script_rewrite() {
  printf '%s\n' "$THUMB_SCRIPT_SAMPLE" >"$T/thumb"
  local got want
  got=$(rewrite_thumbnailer_script "$T/thumb" /p/opt/aseprite/aseprite)
  want=${THUMB_SCRIPT_SAMPLE//aseprite -b//p/opt/aseprite/aseprite -b}
  assert_eq "$want" "$got"
  [[ $got != *" aseprite -b"* ]] || fail "a bare 'aseprite -b' is left"
  printf '%s\n' 'aseprite -b x' '/usr/bin/aseprite -b y' 'xaseprite -b z' 'a;aseprite -b' >"$T/t2"
  got=$(rewrite_thumbnailer_script "$T/t2" /B)
  assert_eq "$(printf '%s\n' '/B -b x' '/usr/bin/aseprite -b y' 'xaseprite -b z' 'a;/B -b')" "$got" "only bare words"
}

test_thumbnailer_entry_rewrite() {
  printf '%s\n' "$THUMB_ENTRY_SAMPLE" >"$T/entry"
  local got
  got=$(rewrite_thumbnailer_entry "$T/entry" /p/bin/aseprite-thumbnailer)
  assert_contains "$got" $'\nTryExec=/p/bin/aseprite-thumbnailer\n'
  assert_contains "$got" $'\nExec=/p/bin/aseprite-thumbnailer %i %o %s\n'
  assert_contains "$got" $'[Thumbnailer Entry]\n'
  assert_contains "$got" "MimeType=image/png;image/x-aseprite;"
}

test_icon_targets() {
  mkdir -p "$T/icons"
  local n
  for n in 16 20 24 28 32 48 64 128 256; do : >"$T/icons/ase$n.png"; done
  : >"$T/icons/ase.ico"
  : >"$T/icons/doc16.png"
  : >"$T/icons/asex.png"
  local got
  got=$(icon_targets "$T/icons" /p/share/icons/hicolor)
  local -a lines
  mapfile -t lines <<<"$got"
  assert_eq 9 "${#lines[@]}" "icon count"
  assert_eq "$T/icons/ase16.png"$'\t'"/p/share/icons/hicolor/16x16/apps/aseprite.png" "${lines[0]}"
  assert_eq "$T/icons/ase256.png"$'\t'"/p/share/icons/hicolor/256x256/apps/aseprite.png" "${lines[8]}"
  assert_eq "" "$(icon_targets "$T/none" /p)" "no icons folder"
}

# ------------------------------------------------------ traps and exit codes

test_err_trap_maps_the_step_to_its_exit_code() {
  local pair
  for pair in 1:1 2:3 3:4 4:5 5:6 6:7 7:7 8:8 9:8; do
    capture bash -c 'source "$1"; init_globals; set -Eeuo pipefail; install_traps; CURRENT_STEP=$2; false; echo unreachable' _ "$UNIT_SCRIPT" "${pair%%:*}"
    assert_rc "${pair##*:}" "$RC" "unexpected failure in step ${pair%%:*}"
    assert_contains "$OUT" "Unexpected failure"
    assert_not_contains "$OUT" "unreachable"
  done
}

test_exit_trap_last_line_names_step_and_log() {
  capture2 bash -c 'source "$1"; init_globals; set -Eeuo pipefail; install_traps
    LOG_FILE=$2; : >"$LOG_FILE"; say_step 6 Building >/dev/null; die 7 "ninja failed"' _ "$UNIT_SCRIPT" "$T/run.log"
  assert_rc 7 "$RC"
  assert_eq "error: stopped at step [6/9] Building (exit 7); log: $T/run.log" "$(last_line "$ERR_OUT")"
}

test_interrupt_exits_130() {
  capture bash -c 'source "$1"; init_globals; set -Eeuo pipefail; install_traps; kill -INT $$; sleep 2; echo unreachable' _ "$UNIT_SCRIPT"
  assert_rc 130 "$RC"
  assert_not_contains "$OUT" "unreachable"
}

# A work folder that looks like the middle of a failed run.
make_failed_run_state() {
  use_test_paths
  init_globals
  resolve_paths
  mkdir -p "$WORK/tmp/sub" "$WORK/src.partial" "$WORK/skia/skia-m1.partial" "$WORK/skia/skia-m1" \
    "$APP_DIR" "$APP_DIR.new" "$WORK/logs"
  : >"$WORK/tmp/install-aseprite.sh"
  : >"$WORK/tmp/.hidden"
  : >"$APP_DIR/aseprite"
  LOCK_HELD=1
  PARTIALS+=("$APP_DIR.new")
}

test_exit_trap_cleans_this_runs_leftovers_only() {
  make_failed_run_state
  fake_docker
  CONTAINERS=(aseprite-installer-build-4242)
  capture on_exit_with 7
  assert_rc 7 "$RC"
  assert_eq "" "$(ls -A "$WORK/tmp")" "tmp emptied"
  assert_missing "$WORK/src.partial"
  assert_missing "$WORK/skia/skia-m1.partial"
  assert_exists "$WORK/skia/skia-m1"
  assert_missing "$APP_DIR.new"
  assert_exists "$APP_DIR/aseprite" "the existing install is kept"
  assert_contains "$(<"$T/docker.log")" "rm -f aseprite-installer-build-4242"
}

test_exit_trap_restores_an_interrupted_swap() {
  make_failed_run_state
  mv "$APP_DIR" "$APP_DIR.old"
  SWAP_OLD=1
  capture on_exit_with 130
  assert_exists "$APP_DIR/aseprite"
  assert_missing "$APP_DIR.old"
}

test_exit_trap_without_lock_touches_nothing() {
  make_failed_run_state
  LOCK_HELD=0
  PARTIALS=()
  capture on_exit_with 1
  assert_exists "$WORK/tmp/install-aseprite.sh"
  assert_exists "$WORK/src.partial"
}

# ------------------------------------------------------- work folder, lock

test_work_folder_lock_and_log_are_set_up() {
  use_test_paths
  init_globals
  resolve_paths
  x_date() { echo 20261126-101500; }
  setup_work_folder
  assert_exists "$WORK/tmp"
  assert_exists "$WORK/lock"
  assert_eq "$WORK/logs/run-20261126-101500.log" "$LOG_FILE"
  assert_exists "$LOG_FILE"
  assert_eq 1 "$LOCK_HELD"
}

test_lock_held_by_another_run_exits_1() {
  use_test_paths
  init_globals
  resolve_paths
  mkdir -p "$WORK"
  exec 8>>"$WORK/lock"
  flock -n 8 || fail "could not take the test lock"
  capture setup_work_folder
  assert_rc 1 "$RC"
  assert_contains "$OUT" "Another run is in progress."
  exec 8>&-
}

# ---------------------------------------------------- host tools and Docker

# Everything preflight needs, faked, so main reaches the host-tool check.
fake_good_host() {
  use_test_paths
  fake_platform Linux "glibc 2.44"
  fake_ldconfig "$LDCONFIG_SAMPLE"
  x_df() { printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/x 999999999 1 900000000 1%% /\n'; }
  fake sudo "printf '%s\n' \"\$*\" >>\"$T/sudo.log\"; exit 1"
}

test_preflight_with_unusable_docker_exits_4_and_never_calls_sudo() {
  fake_good_host
  fake_docker '[[ $1 == info ]] && { echo "Cannot connect to the Docker daemon" >&2; exit 1; }; exit 1'
  capture2 main --yes
  assert_rc 4 "$RC"
  assert_contains "$ERR_OUT" "Docker is not installed, its daemon is not running, or your user cannot use it. This script does not install or start Docker."
  assert_contains "$(<"$T/docker.log")" "info"
  assert_missing "$T/sudo.log"
  assert_missing "$T/prefix"
  capture2 bash "$UNIT_SCRIPT" --yes
  assert_rc 4 "$RC" "as a separate process"
  assert_missing "$T/sudo.log"
}

test_preflight_without_docker_or_git_exits_4() {
  fake_good_host
  have_cmd() { [[ $1 != docker ]] && command -v "$1" >/dev/null 2>&1; }
  capture main --yes
  assert_rc 4 "$RC" "docker missing"
  assert_contains "$OUT" "Docker is not installed"
  have_cmd() { [[ $1 != git ]] && command -v "$1" >/dev/null 2>&1; }
  fake_docker
  capture main --yes
  assert_rc 4 "$RC" "git missing"
  assert_contains "$OUT" "git is not installed"
}

test_docker_info_facts_and_rootless_detection() {
  init_globals
  fake_docker 'printf "/var/lib/docker|[name=seccomp,profile=builtin name=cgroupns]\n"'
  check_host_tools
  assert_eq /var/lib/docker "$DOCKER_ROOT_DIR"
  docker_rootless && fail "rootful Docker seen as rootless"
  fake_docker 'printf "/home/u/.local/share/docker|[name=seccomp,profile=builtin name=rootless name=cgroupns]\n"'
  check_host_tools
  docker_rootless || fail "rootless Docker not detected"
  assert_eq /home/u/.local/share/docker "$DOCKER_ROOT_DIR"
}

# -------------------------------------------------------------------- disk

test_df_output_parsing() {
  assert_eq 900000 "$(parse_df_avail <<<$'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/nvme0n1p3 1000000 100000 900000 10% /home')"
  assert_eq 5 "$(parse_df_avail <<<$'Filesystem 1024-blocks Used Available Capacity Mounted on\nmap auto home 10 5 5 50% /my home')" "spaces in the names"
  parse_df_avail <<<"garbage" >/dev/null && fail "garbage parsed"
  return 0
}

test_low_disk_exits_1_naming_the_folder() {
  use_test_paths
  init_globals
  resolve_paths
  mkdir -p "$WORK"
  DOCKER_ROOT_DIR=/var/lib/docker
  x_df() {
    local avail=900000000
    [[ ${*: -1} == "$WORK" ]] && avail=1048576
    printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/x 999999999 1 %s 1%% /\n' "$avail"
  }
  capture check_disk
  assert_rc 1 "$RC"
  assert_contains "$OUT" "$WORK"
  assert_contains "$OUT" "1.0 GiB free"
  assert_contains "$OUT" "4.0 GiB"
}

test_disk_check_uses_the_nearest_existing_folder_and_warns_for_docker() {
  use_test_paths
  init_globals
  resolve_paths
  mkdir -p "$WORK"
  DOCKER_ROOT_DIR=$T/docker-root # exists, so df is asked about it (not a parent)
  mkdir -p "$DOCKER_ROOT_DIR"
  x_df() {
    printf '%s\n' "${*: -1}" >>"$T/df.log"
    [[ ${*: -1} == "$DOCKER_ROOT_DIR" ]] && return 1
    printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/x 999999999 1 900000000 1%% /\n'
  }
  capture check_disk
  assert_rc 0 "$RC"
  assert_contains "$OUT" "warning:"
  assert_contains "$OUT" "docker-root"
  assert_contains "$(<"$T/df.log")" "$T"$'\n' "prefix (not created yet) checked at its nearest existing parent"
}

# ---------------------------------------------------- build container command

setup_container_cmd() { # rootless(0/1) selinux(0/1)
  use_test_paths
  init_globals
  resolve_paths
  if (($1)); then DOCKER_SECURITY="[name=seccomp,profile=builtin name=rootless]"; else DOCKER_SECURITY="[name=seccomp,profile=builtin name=cgroupns]"; fi
  SELINUX_TEST=$2
  selinux_enabled() { ((SELINUX_TEST)); }
  x_id() { case $1 in -u) echo 1000 ;; -g) echo 1001 ;; esac; }
  BUILD_REF=v1.3.18.6 REF_KIND=tag REF_COMMIT=$SHA_B JOBS=20 RUN_STAMP=20261126-101500
  build_container_cmd
}

count_args() { # word args... -> how many args equal word
  local w=$1 n=0 a
  shift
  for a in "$@"; do [[ $a == "$w" ]] && n=$((n + 1)); done
  printf '%s' "$n"
}

test_docker_run_rootful_with_selinux() {
  setup_container_cmd 0 1
  local cmd=" ${BUILD_RUN_CMD[*]} "
  assert_eq "docker run --rm" "${BUILD_RUN_CMD[*]:0:3}"
  assert_contains "$cmd" " --user 1000:1001 "
  assert_contains "$cmd" " --volume $WORK:/work:Z "
  assert_contains "$cmd" " --name aseprite-installer-build-"
  assert_contains "$cmd" " --env HOME=/tmp "
  assert_contains "$cmd" " aseprite-installer-builder:ubuntu-24.04 bash -c "
  assert_eq 1 "$(count_args 'source /work/tmp/install-aseprite.sh && container_build "$@"' "${BUILD_RUN_CMD[@]}")" "the bash -c script"
  assert_eq 1 "$(count_args --volume "${BUILD_RUN_CMD[@]}")" "exactly one mount"
  local a
  for a in "${BUILD_RUN_CMD[@]}"; do
    case $a in -v | --mount | -t | --tty | -it | -ti | --privileged | --network=host) fail "unexpected docker option $a" ;; esac
  done
}

test_docker_run_rootless_without_selinux() {
  setup_container_cmd 1 0
  local cmd=" ${BUILD_RUN_CMD[*]} "
  assert_not_contains "$cmd" "--user"
  assert_contains "$cmd" " --volume $WORK:/work "
  assert_not_contains "$cmd" ":Z"
  setup_container_cmd 0 0
  cmd=" ${BUILD_RUN_CMD[*]} "
  assert_contains "$cmd" " --user 1000:1001 " "rootful without SELinux"
  assert_contains "$cmd" " --volume $WORK:/work "
  assert_not_contains "$cmd" ":Z"
  setup_container_cmd 1 1
  cmd=" ${BUILD_RUN_CMD[*]} "
  assert_not_contains "$cmd" "--user" "rootless with SELinux"
  assert_contains "$cmd" " --volume $WORK:/work:Z "
}

test_container_args_carry_the_run_facts() {
  setup_container_cmd 0 0
  local cmd=" ${BUILD_RUN_CMD[*]} "
  assert_contains "$cmd" " _ ref=v1.3.18.6 ref_kind=tag commit=$SHA_B jobs=20 "
  assert_contains "$cmd" " run_log=/work/logs/run-20261126-101500.log build_log=/work/logs/build-20261126-101500.log "
  assert_contains "$cmd" " host_work=$WORK "
  assert_contains "$cmd" " tty=0 color=0 verbose=0 break_skia= "
  ASEPRITE_TEST_BREAK_SKIA=1
  build_container_cmd
  assert_contains " ${BUILD_RUN_CMD[*]} " " break_skia=1 "
}

test_container_exit_codes_are_passed_on() {
  local pair
  for pair in 0:0 4:4 5:5 6:6 7:7 130:130 125:4 126:4 127:4 137:7 1:7; do
    assert_eq "${pair##*:}" "$(map_container_exit "${pair%%:*}")" "container exit ${pair%%:*}"
  done
}

# ------------------------------------------------ resolve and up to date

setup_resolve() {
  use_test_paths
  init_globals
  resolve_paths
  x_git() {
    printf '%s\n' "$*" >>"$T/git.log"
    if [[ $* == *--tags* ]]; then
      printf '%s\trefs/tags/%s\n' "$SHA_B" v1.3.18.6 "$SHA_A" v1.3.17 "$SHA_C" v1.3.19-beta1
    else
      case $* in
        *refs/tags/v1.3.18.6*) printf '%s\trefs/tags/v1.3.18.6\n' "$SHA_B" ;;
        *refs/tags/v1.3.17*) printf '%s\trefs/tags/v1.3.17\n' "$SHA_A" ;;
        *refs/heads/main*) printf '%s\trefs/heads/main\n' "$SHA_C" ;;
      esac
    fi
  }
}

install_fake_state() { # commit version [ref]
  mkdir -p "$RECORDS_DIR"
  printf '#!/bin/sh\necho "Aseprite %s"\n' "$2" >"$BIN"
  chmod +x "$BIN"
  state_write "$STATE_FILE" "ref=${3:-v1.3.18.6}" "commit=$1" "version=$2" skia_tag=m124-08a5439a6b \
    build_base=ubuntu:24.04 installed_at=2026-11-25T10:00:00+01:00 script_version=1.0.0
}

test_up_to_date_exits_0_without_touching_docker() {
  setup_resolve
  install_fake_state "$SHA_B" 1.3.18.6-dev
  fake_docker
  capture step_resolve
  assert_rc 0 "$RC"
  assert_contains "$OUT" "Aseprite 1.3.18.6-dev is already installed and up to date"
  assert_missing "$T/docker.log"
  assert_contains "$(<"$T/git.log")" "ls-remote --tags --refs"
  OPT_REF=v1.3.17
  install_fake_state "$SHA_A" 1.3.17-dev v1.3.17
  capture step_resolve
  assert_contains "$OUT" "Aseprite 1.3.17-dev is already installed and up to date" "--ref of the installed tag"
}

test_resolve_decides_to_build() {
  setup_resolve
  capture step_resolve
  assert_contains "$OUT" "Installing v1.3.18.6" "nothing installed"
  assert_contains "$OUT" "${SHA_B:0:12}" "commit, 12 characters"
  assert_not_contains "$OUT" "${SHA_B:0:13}"
  install_fake_state "$SHA_A" 1.3.17-dev v1.3.17
  capture step_resolve
  assert_contains "$OUT" "Updating 1.3.17-dev → v1.3.18.6"
  install_fake_state "$SHA_B" 1.3.18.6-dev
  OPT_FORCE=1
  capture step_resolve
  assert_not_contains "$OUT" "up to date" "--force"
  assert_contains "$OUT" "Rebuilding"
  OPT_FORCE=0
  rm -f "$BIN"
  capture step_resolve
  assert_not_contains "$OUT" "up to date" "binary missing"
  OPT_REF=main
  step_resolve >/dev/null
  assert_eq "main branch $SHA_C" "$BUILD_REF $REF_KIND $REF_COMMIT"
}

test_second_run_up_to_date_makes_no_image_or_container() {
  fake_good_host
  setup_resolve
  install_fake_state "$SHA_B" 1.3.18.6-dev
  fake_docker '[[ $1 == info ]] && echo "/var/lib/docker|[name=seccomp]"; exit 0'
  capture main
  assert_rc 0 "$RC"
  assert_contains "$OUT" "already installed and up to date"
  local line
  while IFS= read -r line; do
    [[ $line == info* ]] || fail "docker called for more than info: $line"
  done <"$T/docker.log"
}

# ----------------------------------------------------------- builder image

setup_image_step() {
  use_test_paths
  init_globals
  resolve_paths
  mkdir -p "$WORK/tmp" "$WORK/logs"
  LOG_FILE="$WORK/logs/run-test.log"
  LOCK_HELD=1
}

test_image_step_reuses_a_present_image() {
  setup_image_step
  fake_docker
  capture step_image
  assert_rc 0 "$RC"
  assert_contains "$OUT" "Builder image already present"
  assert_contains "$(<"$LOG_FILE")" "Builder image already present"
  local calls; calls=$(<"$T/docker.log")
  assert_not_contains "$calls" "pull"
  assert_not_contains "$calls" "commit"
  assert_not_contains "$calls" $'\nrun '
}

# Docker fake: nothing is present; inspect --format answers; the rest works.
IMAGE_FAKE='if [[ "$1 $2" == "image inspect" ]]; then [[ $3 == --format ]] && { echo "sha256:abc 123"; exit 0; }; exit 1; fi; exit 0'

test_image_step_makes_the_image_with_run_and_commit() {
  setup_image_step
  fake_docker "$IMAGE_FAKE"
  capture step_image
  assert_rc 0 "$RC"
  assert_exists "$WORK/pulled-base"
  local calls; calls=$(<"$T/docker.log")
  assert_contains "$calls" "image inspect aseprite-installer-builder:ubuntu-24.04"$'\n'"image inspect ubuntu:24.04"$'\n'"pull ubuntu:24.04"$'\n'"run --name aseprite-installer-setup-"
  assert_contains "$calls" "ubuntu:24.04 bash -c apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends g++ clang cmake ninja-build unzip libx11-dev libxcursor-dev libxi-dev libxrandr-dev libgl1-mesa-dev libfontconfig1-dev git curl ca-certificates ccache && rm -rf /var/lib/apt/lists/*"
  assert_contains "$calls" $'\ncommit --change LABEL aseprite-installer=1 aseprite-installer-setup-'
  assert_contains "$calls" " aseprite-installer-builder:ubuntu-24.04"$'\n'"rm aseprite-installer-setup-"
  local line
  while IFS= read -r line; do
    case $line in build* | system* | *prune*) fail "forbidden docker command: $line" ;; esac
  done <<<"$calls"
  assert_contains "$(<"$LOG_FILE")" "id sha256:abc, size 123"
}

test_image_step_does_not_mark_a_base_image_that_was_there() {
  setup_image_step
  fake_docker 'if [[ "$1 $2" == "image inspect" ]]; then [[ $3 == ubuntu:24.04 || $3 == --format ]] && exit 0; exit 1; fi; exit 0'
  capture step_image
  assert_rc 0 "$RC"
  assert_missing "$WORK/pulled-base"
  assert_not_contains "$(<"$T/docker.log")" "pull"
}

image_step_with_traps() {
  set -Eeuo pipefail
  install_traps
  IMAGE_STEP_REACHED=0
  step_image
}

test_image_step_failure_exits_4_and_removes_the_setup_container() {
  setup_image_step
  fake_docker 'if [[ "$1 $2" == "image inspect" ]]; then exit 1; fi; [[ $1 == run ]] && exit 100; exit 0'
  capture image_step_with_traps
  assert_rc 4 "$RC"
  assert_contains "$(<"$T/docker.log")" $'\nrm -f aseprite-installer-setup-'
  assert_missing "$WORK/pulled-base" "the mark goes once the base image is gone"
}

test_image_step_dry_run_prints_commands_and_changes_nothing() {
  setup_image_step
  LOCK_HELD=0
  DRY_RUN=1
  fake_docker '[[ "$1 $2" == "image inspect" ]] && exit 1; exit 0'
  capture step_image
  assert_rc 0 "$RC"
  assert_contains "$OUT" "[dry-run] docker pull ubuntu:24.04"
  assert_contains "$OUT" "[dry-run] docker run --name aseprite-installer-setup-"
  assert_contains "$OUT" "[dry-run] docker commit --change 'LABEL aseprite-installer=1' aseprite-installer-setup-"
  assert_contains "$OUT" "[dry-run] docker rm aseprite-installer-setup-"
  local line
  while IFS= read -r line; do
    [[ $line == "image inspect"* ]] || fail "dry-run ran docker $line"
  done <"$T/docker.log"
  assert_missing "$WORK/pulled-base"
}

test_image_removal_rules() {
  setup_image_step
  IMAGE_STEP_REACHED=1
  fake_docker
  : >"$WORK/pulled-base"
  remove_images_if_needed
  local calls; calls=$(<"$T/docker.log")
  assert_contains "$calls" "image rm aseprite-installer-builder:ubuntu-24.04"
  assert_contains "$calls" "image rm ubuntu:24.04"
  assert_missing "$WORK/pulled-base"
  assert_eq removed "$IMAGE_STATUS"
  rm -f "$T/docker.log"
  IMAGES_HANDLED=0 OPT_KEEP_IMAGE=1
  : >"$WORK/pulled-base"
  remove_images_if_needed
  assert_missing "$T/docker.log" "--keep-image keeps both"
  IMAGES_HANDLED=0 OPT_KEEP_IMAGE=0 IMAGE_STEP_REACHED=0
  remove_images_if_needed
  assert_missing "$T/docker.log" "a run that stopped before the image step leaves images alone"
  rm -f "$WORK/pulled-base"
  IMAGES_HANDLED=0 IMAGE_STEP_REACHED=1
  remove_images_if_needed
  assert_not_contains "$(<"$T/docker.log")" "ubuntu:24.04" "base image not pulled by the script"
}

test_image_removal_in_use_warns_and_goes_on() {
  setup_image_step
  IMAGE_STEP_REACHED=1
  fake_docker '[[ "$1 $2" == "image rm" ]] && { echo "conflict: unable to remove repository reference (container 1234 is using its referenced image)" >&2; exit 1; }; exit 0'
  : >"$WORK/pulled-base"
  capture2 remove_images_if_needed
  assert_rc 0 "$RC"
  assert_contains "$ERR_OUT" "warning:"
  assert_contains "$ERR_OUT" "docker image rm aseprite-installer-builder:ubuntu-24.04"
  assert_exists "$WORK/pulled-base" "the mark stays so a later run can remove the base image"
}

# ------------------------------------------------- container: arguments

test_container_args_parse() {
  init_globals
  parse_container_args ref=v1.3.18.6 ref_kind=tag "commit=$SHA_B" jobs=20 run_log=/work/logs/run-1.log \
    build_log=/work/logs/build-1.log "host_work=/h/my work" tty=1 color=1 verbose=0 break_skia=
  assert_eq "v1.3.18.6|tag|$SHA_B|20|/work/logs/run-1.log|/work/logs/build-1.log|/h/my work|1|1|1|0|" \
    "$C_REF|$C_REF_KIND|$C_COMMIT|$C_JOBS|$LOG_FILE|$C_BUILD_LOG|$C_HOST_WORK|$C_TTY|$COLOR_OUT|$COLOR_ERR|$VERBOSE|$C_BREAK_SKIA"
  capture parse_container_args bogus=1
  assert_rc 7 "$RC" "unknown argument"
}

test_host_and_container_args_agree() {
  setup_container_cmd 0 1
  local -a args=()
  local i work=$WORK
  for ((i = 0; i < ${#BUILD_RUN_CMD[@]}; i++)); do
    [[ ${BUILD_RUN_CMD[i]} == _ ]] && args=("${BUILD_RUN_CMD[@]:i+1}")
  done
  init_globals
  parse_container_args "${args[@]}"
  assert_eq "v1.3.18.6 $SHA_B 20 $work" "$C_REF $C_COMMIT $C_JOBS $C_HOST_WORK"
}

# ---------------------------------------------------- container: source

setup_container_side() {
  init_globals
  WORK="$T/work"
  mkdir -p "$WORK/tmp" "$WORK/logs"
  LOG_FILE="$WORK/logs/run.log"
  C_BUILD_LOG="$WORK/logs/build.log"
  C_REF=v1.3.18.6 C_REF_KIND=tag C_JOBS=4 C_TTY=0 C_BREAK_SKIA="" C_HOST_WORK="$T/hostwork"
  x_sleep() { printf 'sleep %s\n' "$*" >>"$T/sleep.log"; }
  IN_CONTAINER=1
}

rgit() { "$UNIT_REAL_GIT" "$@"; }

make_fixture_repo() { # DIR [TAG] -> prints the commit
  rgit init -q "$1"
  printf 'cmake_minimum_required(VERSION 3.20)\n' >"$1/CMakeLists.txt"
  rgit -C "$1" add CMakeLists.txt
  rgit -C "$1" -c user.email=t@t -c user.name=t commit -qm init
  [[ -z ${2:-} ]] || rgit -C "$1" tag "$2"
  rgit -C "$1" rev-parse HEAD
}

# x_git that "clones" from the local fixture $T/upstream.
fixture_clone_git() {
  x_git() {
    if [[ $1 == clone ]]; then
      printf '%s\n' "$*" >>"$T/clone.log"
      rgit clone -q "$T/upstream" "${*: -1}"
    else
      rgit "$@"
    fi
  }
}

test_source_is_reused_at_the_commit_when_clean() {
  setup_container_side
  C_COMMIT=$(make_fixture_repo "$WORK/src" v1.3.18.6)
  x_git() { rgit "$@"; }
  capture cstep_source
  assert_rc 0 "$RC"
  assert_contains "$OUT" "Reusing the source"
  assert_contains "$OUT" "[4/9] Getting source (v1.3.18.6)"
  assert_eq "4|Getting source (v1.3.18.6)" "$(<"$WORK/tmp/container-step")" "step recorded for the host"
}

test_dirty_or_foreign_source_is_cloned_fresh() {
  setup_container_side
  C_COMMIT=$(make_fixture_repo "$T/upstream" v1.3.18.6)
  fixture_clone_git
  mkdir -p "$WORK/src" "$WORK/src.partial"
  : >"$WORK/src/junk"
  capture cstep_source
  assert_rc 0 "$RC"
  assert_eq "clone --depth 1 --branch v1.3.18.6 --recurse-submodules --shallow-submodules https://github.com/aseprite/aseprite.git $WORK/src.partial" "$(<"$T/clone.log")"
  assert_missing "$WORK/src/junk"
  assert_missing "$WORK/src.partial"
  assert_eq "$C_COMMIT" "$(rgit -C "$WORK/src" rev-parse HEAD)"
  rm -f "$T/clone.log"
  : >"$WORK/src/dirty"
  capture cstep_source
  assert_exists "$T/clone.log" "an untracked file makes the tree dirty"
}

test_clone_failure_is_retried_once_then_exits_5() {
  setup_container_side
  C_COMMIT=$SHA_B
  x_git() {
    if [[ $1 == clone ]]; then echo clone >>"$T/clone.log"; mkdir -p "${*: -1}"; return 128; fi
    rgit "$@"
  }
  capture cstep_source
  assert_rc 5 "$RC"
  assert_eq $'clone\nclone' "$(<"$T/clone.log")"
  assert_eq "sleep 5" "$(<"$T/sleep.log")"
  assert_missing "$WORK/src.partial"
}

test_source_at_another_commit_exits_5() {
  setup_container_side
  make_fixture_repo "$T/upstream" v1.3.18.6 >/dev/null
  C_COMMIT=$SHA_A
  fixture_clone_git
  capture cstep_source
  assert_rc 5 "$RC"
}

test_submodule_status_check() {
  submodule_status_ok <<<" 1234abcd laf (v1.0)" || fail "initialised submodule refused"
  submodule_status_ok <<<"" || fail "no submodules refused"
  submodule_status_ok <<<$' 1234 a (x)\n-5678 laf' && fail "uninitialised submodule accepted"
  submodule_status_ok <<<"+5678 laf (v2)" && fail "submodule at the wrong commit accepted"
  return 0
}

test_describe_must_work_for_tags_only() {
  setup_container_side
  C_COMMIT=$(make_fixture_repo "$WORK/src")
  x_git() { rgit "$@"; }
  capture cstep_source
  assert_rc 5 "$RC" "tag build without a describable tag"
  C_REF=main C_REF_KIND=branch
  capture cstep_source
  assert_rc 0 "$RC" "branch build"
  assert_contains "$OUT" "warning:"
}

# ------------------------------------------------------ container: Skia

PINNED_SHA=a327e89b244f24cecaa34eb37544bae00d447b96c583d26ed29d6a3ad2e8a8b8

setup_skia() { # tag
  setup_container_side
  mkdir -p "$WORK/src/laf/misc"
  printf '%s\n' "$1" >"$WORK/src/laf/misc/skia-tag.txt"
  x_curl() {
    printf '%s\n' "$*" >>"$T/curl.log"
    local out=""
    while (($#)); do [[ $1 == -o ]] && out=$2; shift; done
    [[ ${CURL_RC:-0} == 0 ]] || { : >"$out"; return 22; }
    printf 'zipdata' >"$out"
  }
  x_unzip() {
    printf '%s\n' "$*" >>"$T/unzip.log"
    [[ $1 == -tq ]] && return "${UNZIP_TEST_RC:-0}"
    local d=${*: -1}
    mkdir -p "$d/out/Release-x64" "$d/include"
    [[ ${SKIA_ZIP_EMPTY:-0} == 1 ]] || : >"$d/out/Release-x64/libskia.a"
  }
  x_sha256sum() { printf '%s  %s\n' "${FAKE_SHA:-$PINNED_SHA}" "$1"; }
}

make_skia_dir() { mkdir -p "$1/include" "$1/out/Release-x64" && : >"$1/out/Release-x64/libskia.a"; }

test_skia_present_is_reused() {
  setup_skia m124-08a5439a6b
  make_skia_dir "$WORK/skia/skia-m124-08a5439a6b"
  capture cstep_skia
  assert_rc 0 "$RC"
  assert_contains "$OUT" "Skia m124-08a5439a6b already present"
  assert_missing "$T/curl.log"
}

test_skia_download_checksum_and_unpack() {
  setup_skia m124-08a5439a6b
  capture cstep_skia
  assert_rc 0 "$RC"
  local zip="$WORK/downloads/m124-08a5439a6b/Skia-Linux-Release-x64.zip"
  assert_contains "$(<"$T/curl.log")" "-fL --retry 3 --retry-delay 2 --connect-timeout 20"
  assert_contains "$(<"$T/curl.log")" "-o $zip.part https://github.com/aseprite/skia/releases/download/m124-08a5439a6b/Skia-Linux-Release-x64.zip"
  assert_exists "$zip"
  assert_missing "$zip.part"
  assert_contains "$(<"$T/unzip.log")" "-tq $zip"
  assert_exists "$WORK/skia/skia-m124-08a5439a6b/out/Release-x64/libskia.a"
  assert_missing "$WORK/skia/skia-m124-08a5439a6b.partial"
  assert_contains "$(<"$LOG_FILE")" "$PINNED_SHA"
}

test_skia_checksum_mismatch_exits_6_and_deletes_the_zip() {
  setup_skia m124-08a5439a6b
  FAKE_SHA=0000000000000000000000000000000000000000000000000000000000000000
  capture cstep_skia
  assert_rc 6 "$RC"
  assert_missing "$WORK/downloads/m124-08a5439a6b/Skia-Linux-Release-x64.zip"
  assert_contains "$OUT" "https://github.com/aseprite/skia/releases/download/m124-08a5439a6b/Skia-Linux-Release-x64.zip"
  assert_missing "$WORK/skia/skia-m124-08a5439a6b"
}

test_skia_other_tag_logs_the_checksum_and_goes_on() {
  setup_skia m125-1234abcd
  FAKE_SHA=abcdef
  capture cstep_skia
  assert_rc 0 "$RC"
  assert_contains "$(<"$LOG_FILE")" "abcdef"
  assert_exists "$WORK/skia/skia-m125-1234abcd/out/Release-x64/libskia.a"
}

test_skia_damaged_or_wrong_zip_exits_6() {
  setup_skia m124-08a5439a6b
  UNZIP_TEST_RC=1
  capture cstep_skia
  assert_rc 6 "$RC" "unzip -t fails"
  assert_missing "$WORK/downloads/m124-08a5439a6b/Skia-Linux-Release-x64.zip"
  UNZIP_TEST_RC=0 SKIA_ZIP_EMPTY=1
  capture cstep_skia
  assert_rc 6 "$RC" "no libskia.a in the zip"
  assert_missing "$WORK/skia/skia-m124-08a5439a6b"
  assert_contains "$OUT" "libskia.a"
}

test_skia_download_failure_exits_6() {
  setup_skia m124-08a5439a6b
  CURL_RC=22
  capture cstep_skia
  assert_rc 6 "$RC"
  assert_missing "$WORK/downloads/m124-08a5439a6b/Skia-Linux-Release-x64.zip.part"
  assert_contains "$OUT" "https://github.com/aseprite/skia/releases/download/m124-08a5439a6b/Skia-Linux-Release-x64.zip"
}

test_skia_existing_zip_is_reused() {
  setup_skia m124-08a5439a6b
  mkdir -p "$WORK/downloads/m124-08a5439a6b"
  printf 'zipdata' >"$WORK/downloads/m124-08a5439a6b/Skia-Linux-Release-x64.zip"
  capture cstep_skia
  assert_rc 0 "$RC"
  assert_missing "$T/curl.log"
}

test_skia_tag_file_missing_exits_6() {
  setup_container_side
  capture cstep_skia
  assert_rc 6 "$RC"
  assert_contains "$OUT" "skia-tag.txt"
}

test_break_skia_points_at_an_empty_folder() {
  setup_skia m124-08a5439a6b
  make_skia_dir "$WORK/skia/skia-m124-08a5439a6b"
  cstep_skia >/dev/null
  assert_eq "$WORK/skia/skia-m124-08a5439a6b" "$SKIA_DIR" "hook unset"
  C_BREAK_SKIA=1
  cstep_skia >/dev/null 2>&1
  assert_eq "$WORK/tmp/empty-skia" "$SKIA_DIR"
  assert_eq "" "$(ls -A "$SKIA_DIR")"
  assert_eq m124-08a5439a6b "$SKIA_TAG"
}

# ----------------------------------------------------- container: build

setup_build() {
  setup_container_side
  C_COMMIT=$SHA_B SKIA_TAG=m124-08a5439a6b SKIA_DIR="$WORK/skia/skia-m124-08a5439a6b"
  mkdir -p "$WORK/src"
  printf 'cmake_minimum_required(VERSION 3.20)\n' >"$WORK/src/CMakeLists.txt"
  CMAKE_FAKE_VERSION=3.28.3
  x_cmake() {
    if [[ $1 == --version ]]; then printf 'cmake version %s\n\nCMake suite\n' "$CMAKE_FAKE_VERSION"; return 0; fi
    printf '%s\n' "$*" >>"$T/cmake.log"
    printf 'CC=%s CXX=%s\n' "${CC:-}" "${CXX:-}" >>"$T/cmake-env.log"
    mkdir -p "$WORK/build"
    echo "-- Configuring done"
    return "${CMAKE_RC:-0}"
  }
  x_ninja() {
    printf '%s\n' "$*" >>"$T/ninja.log"
    printf '[1/2] Building CXX object x.o\n[2/2] Linking CXX executable bin/aseprite\n'
    [[ ${NINJA_RC:-0} == 0 ]] || { echo "error: boom"; return 1; }
  }
}

test_build_runs_the_pinned_cmake_command_then_ninja() {
  setup_build
  capture cstep_build
  assert_rc 0 "$RC"
  assert_eq "-S $WORK/src -B $WORK/build -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_CXX_FLAGS:STRING=-stdlib=libstdc++ -DCMAKE_EXE_LINKER_FLAGS:STRING=-stdlib=libstdc++ -DLAF_BACKEND=skia -DSKIA_DIR=$SKIA_DIR -DSKIA_LIBRARY_DIR=$SKIA_DIR/out/Release-x64 -DSKIA_LIBRARY=$SKIA_DIR/out/Release-x64/libskia.a -DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache" "$(<"$T/cmake.log")"
  assert_eq "CC=clang CXX=clang++" "$(<"$T/cmake-env.log")"
  assert_eq "-C $WORK/build -j 4 aseprite" "$(<"$T/ninja.log")"
  assert_eq "$SHA_B m124-08a5439a6b" "$(<"$WORK/build/.aseprite-installer-stamp")"
  assert_contains "$(<"$C_BUILD_LOG")" "Configuring done"
  assert_contains "$(<"$C_BUILD_LOG")" "[2/2] Linking"
  assert_contains "$(<"$LOG_FILE")" "+ cmake -S $WORK/src"
  assert_contains "$OUT" "Build took"
}

test_build_folder_reuse_follows_the_stamp() {
  setup_build
  mkdir -p "$WORK/build"
  printf '%s\n' "$SHA_B m124-08a5439a6b" >"$WORK/build/.aseprite-installer-stamp"
  : >"$WORK/build/kept.o"
  capture cstep_build
  assert_exists "$WORK/build/kept.o"
  assert_contains "$OUT" "Reusing the build folder"
  printf '%s\n' "$SHA_B m999-other" >"$WORK/build/.aseprite-installer-stamp"
  capture cstep_build
  assert_missing "$WORK/build/kept.o" "a different Skia tag means a fresh build folder"
}

test_cmake_too_old_exits_4() {
  setup_build
  CMAKE_FAKE_VERSION=3.19.8
  capture cstep_build
  assert_rc 4 "$RC"
  assert_contains "$OUT" "3.19.8"
  assert_missing "$T/cmake.log"
}

test_configure_failure_exits_7_with_the_log_tail() {
  setup_build
  CMAKE_RC=1
  capture2 cstep_build
  assert_rc 7 "$RC"
  assert_contains "$ERR_OUT" "Configuring done" "last lines of the build log"
  assert_contains "$ERR_OUT" "$T/hostwork/logs/build.log" "the log path as the host sees it"
  assert_missing "$T/ninja.log"
}

test_compile_failure_exits_7_and_keeps_the_folders() {
  setup_build
  NINJA_RC=1
  capture2 cstep_build
  assert_rc 7 "$RC"
  assert_contains "$ERR_OUT" "error: boom"
  assert_exists "$WORK/src"
  assert_exists "$WORK/build"
}

test_break_skia_build_starts_clean_and_leaves_no_stamp() {
  setup_build
  C_BREAK_SKIA=1
  mkdir -p "$WORK/build"
  printf '%s\n' "$SHA_B m124-08a5439a6b" >"$WORK/build/.aseprite-installer-stamp"
  : >"$WORK/build/kept.o"
  capture cstep_build
  assert_missing "$WORK/build/kept.o"
  assert_missing "$WORK/build/.aseprite-installer-stamp"
}

# Fake ninja that keeps running until the fake sleep releases it.
slow_ninja() {
  x_ninja() {
    printf '[1/2] Building x\n[2/2] Linking aseprite\n'
    while [[ ! -e $T/release ]]; do command sleep 0.01; done
  }
  x_sleep() {
    SLEEPS=$((${SLEEPS:-0} + 1))
    ((SLEEPS < ${RELEASE_AFTER:-3})) || : >"$T/release"
    command sleep 0.01
  }
}

test_ninja_progress_on_a_terminal() {
  setup_build
  slow_ninja
  C_TTY=1 RELEASE_AFTER=5
  capture run_ninja
  assert_rc 0 "$RC"
  assert_contains "$OUT" $'\r   -> [2/2] 100%'
}

test_ninja_progress_every_60_seconds_otherwise() {
  setup_build
  slow_ninja
  C_TTY=0 RELEASE_AFTER=62
  capture run_ninja
  assert_rc 0 "$RC"
  assert_contains "$OUT" "   -> Still building: [2/2] 100%"
  assert_not_contains "$OUT" $'\r'
}

# ----------------------------------------------------- container: check

setup_check() { # version line
  setup_container_side
  mkdir -p "$WORK/build/bin/data"
  printf '#!/bin/sh\necho "%s"\n' "$1" >"$WORK/build/bin/aseprite"
  chmod +x "$WORK/build/bin/aseprite"
  x_readelf() { printf '%s\n' ' 0x0000000000000001 (NEEDED)             Shared library: [libX11.so.6]' ' 0x0000000000000001 (NEEDED)             Shared library: [libc.so.6]'; }
  x_objdump() { printf '%s\n' '0000000000000000      DF *UND*	0000000000000000 (GLIBC_2.34) __libc_start_main'; }
}

test_build_check_accepts_the_tag_version() {
  setup_check "Aseprite 1.3.18.6-dev"
  capture cstep_check
  assert_rc 0 "$RC"
  assert_contains "$OUT" "Aseprite 1.3.18.6-dev"
  assert_exists "$WORK/build/runtime-deps.txt"
  cstep_check >/dev/null
  assert_eq "Aseprite 1.3.18.6-dev" "$C_VERSION_LINE"
  C_REF=main C_REF_KIND=branch
  setup_check "Aseprite 1.x-e593180-dev"
  C_REF=main C_REF_KIND=branch
  capture cstep_check
  assert_rc 0 "$RC" "a branch build only needs an Aseprite line"
}

test_build_check_failures_exit_7() {
  setup_check "Aseprite 1.3.17-dev"
  capture cstep_check
  assert_rc 7 "$RC" "version of another tag"
  setup_check "Something else"
  capture cstep_check
  assert_rc 7 "$RC" "no Aseprite line"
  setup_check "Aseprite 1.3.18.6-dev"
  rmdir "$WORK/build/bin/data"
  capture cstep_check
  assert_rc 7 "$RC" "data/ missing"
  setup_check "Aseprite 1.3.18.6-dev"
  printf '#!/bin/sh\nexit 3\n' >"$WORK/build/bin/aseprite"
  capture cstep_check
  assert_rc 7 "$RC" "--version fails"
  rm -f "$WORK/build/bin/aseprite"
  capture cstep_check
  assert_rc 7 "$RC" "no binary"
}

test_version_matches_tag() {
  version_matches_tag "Aseprite 1.3.18.6-dev" v1.3.18.6 || fail "1.3.18.6-dev vs v1.3.18.6"
  version_matches_tag "Aseprite 1.3.18-beta3-dev" v1.3.18-beta3 || fail "beta tag"
  version_matches_tag "Aseprite 1.3.18.60-dev" v1.3.18.6 && fail "1.3.18.60 matched v1.3.18.6"
  version_matches_tag "Aseprite 1.3.1-dev" v1.3.18 && fail "1.3.1 matched v1.3.18"
  return 0
}

test_ccache_is_set_up_inside_the_work_folder() {
  [[ " ${CONTAINER_PACKAGES[*]} " == *" ccache "* ]] || fail "ccache is not in the container packages"
  WORK=/work
  ccache_env
  assert_eq "/work/ccache" "$CCACHE_DIR"
  assert_eq "content" "$CCACHE_COMPILERCHECK"
  [[ -n $CCACHE_MAXSIZE ]] || fail "CCACHE_MAXSIZE is not set"
  local d
  d=$T
  WORK=$d/work; mkdir -p "$WORK/ccache/a" "$WORK/logs"
  delete_work_folder >/dev/null 2>&1
  [[ ! -e $WORK ]] || fail "--purge left the ccache folder behind"
  return 0
}

test_version_placeholder_for_old_tags() {
  version_is_placeholder "Aseprite 1.x-dev" || fail "1.x-dev is the source placeholder (v1.3.17 and older)"
  version_is_placeholder "Aseprite 1.3.18.6-dev" && fail "a real version is not a placeholder"
  version_is_placeholder "Aseprite 1.x-devX" && fail "only the exact placeholder counts"
  return 0
}

test_readelf_and_objdump_parsing() {
  local readelf=' 0x0000000000000001 (NEEDED)             Shared library: [libX11.so.6]
 0x0000000000000001 (NEEDED)             Shared library: [libstdc++.so.6]
 0x000000000000000e (SONAME)             Library soname: [libfoo.so.1]'
  assert_eq $'libX11.so.6\nlibstdc++.so.6' "$(parse_readelf_needed <<<"$readelf")"
  local objdump='0000000000000000      DF *UND*	0000000000000000 (GLIBC_2.34) __libc_start_main
0000000000000000      DF *UND*	0000000000000000  GLIBC_2.2.5 malloc
0000000000000000      DF *UND*	0000000000000000 (GLIBC_PRIVATE) _dl_x
0000000000000000      DF *UND*	0000000000000000 (GLIBCXX_3.4.30) _ZNSt6thread
0000000000000000      DF *UND*	0000000000000000 (GLIBCXX_3.4.9) _ZSt4cout
0000000000000000      DF *UND*	0000000000000000 (CXXABI_1.3.13) __cxa_x'
  assert_eq 2.34 "$(max_symbol_version GLIBC <<<"$objdump")"
  assert_eq 3.4.30 "$(max_symbol_version GLIBCXX <<<"$objdump")"
}

test_runtime_deps_are_recorded_and_surprises_warned() {
  setup_check "Aseprite 1.3.18.6-dev"
  x_readelf() { printf ' 0x1 (NEEDED) Shared library: [%s]\n' libX11.so.6 libc.so.6 libm.so.6 libXinerama.so.1; }
  x_objdump() { printf '%s\n' 'x (GLIBC_2.38) a' 'x (GLIBC_2.40) b' 'x (GLIBCXX_3.4.33) c'; }
  C_VERSION_LINE="Aseprite 1.3.18.6-dev"
  capture2 record_runtime_deps "$WORK/build/bin/aseprite"
  local deps; deps=$(<"$WORK/build/runtime-deps.txt")
  assert_contains "$deps" "libXinerama.so.1"
  assert_contains "$deps" "GLIBC_2.40"
  assert_contains "$deps" "GLIBCXX_3.4.33"
  assert_contains "$ERR_OUT" "libXinerama.so.1"
  assert_not_contains "$ERR_OUT" "libm.so.6" "glibc's own libraries are expected"
  assert_contains "$ERR_OUT" "GLIBC_2.40"
  assert_contains "$ERR_OUT" "GLIBCXX_3.4.33"
}

# -------------------------------------------------- host: container step

setup_host_container_step() {
  use_test_paths
  init_globals
  resolve_paths
  mkdir -p "$WORK/tmp" "$WORK/logs"
  LOG_FILE="$WORK/logs/run-1.log" LOCK_HELD=1 RUN_STAMP=1
  BUILD_REF=v1.3.18.6 REF_KIND=tag REF_COMMIT=$SHA_B JOBS=2 DOCKER_SECURITY="[name=seccomp]"
}

# docker fake whose `run` plays the container: $1 = bash code run with $W
# set to the mounted host folder.
fake_build_container() {
  fake_docker "if [[ \$1 == run ]]; then
  for ((i = 1; i <= \$#; i++)); do [[ \${!i} == --volume ]] && { j=\$((i + 1)); vol=\${!j}; }; done
  W=\${vol%%:/work*}
  $1
fi
exit 0"
}

test_container_step_runs_docker_and_reads_the_result() {
  setup_host_container_step
  fake_build_container '[[ -f $W/tmp/install-aseprite.sh ]] || exit 99
printf "version_line=Aseprite 1.3.18.6-dev\nskia_tag=m124-08a5439a6b\nbuild_seconds=65\n" >"$W/tmp/build-info"'
  step_container >/dev/null
  assert_eq "Aseprite 1.3.18.6-dev|m124-08a5439a6b|65" "$BUILT_VERSION_LINE|$SKIA_TAG|$BUILD_SECONDS"
  assert_contains "$(<"$T/docker.log")" "run --rm --name aseprite-installer-build-"
  assert_contains "$(<"$LOG_FILE")" "+ docker run --rm --name aseprite-installer-build-"
}

container_step_with_traps() {
  set -Eeuo pipefail
  install_traps
  step_container
}

test_container_step_failure_passes_the_code_and_step_on() {
  setup_host_container_step
  fake_build_container 'printf "6|Building Aseprite (ninja -j 2)\n" >"$W/tmp/container-step"; exit 7'
  capture2 container_step_with_traps
  assert_rc 7 "$RC"
  assert_eq "error: stopped at step [6/9] Building Aseprite (ninja -j 2) (exit 7); log: $LOG_FILE" "$(last_line "$ERR_OUT")"
  assert_contains "$(<"$T/docker.log")" $'\nrm -f aseprite-installer-build-'
  fake_build_container 'exit 125'
  capture2 container_step_with_traps
  assert_rc 4 "$RC" "docker could not start the container"
}

test_container_step_dry_run_prints_the_plan() {
  setup_host_container_step
  LOCK_HELD=0 DRY_RUN=1
  fake_docker
  capture step_container
  assert_rc 0 "$RC"
  assert_contains "$OUT" "[dry-run] docker run --rm --name aseprite-installer-build-"
  assert_contains "$OUT" "[dry-run] git clone --depth 1 --branch v1.3.18.6 --recurse-submodules --shallow-submodules https://github.com/aseprite/aseprite.git /work/src.partial"
  assert_contains "$OUT" "[dry-run] cmake -S /work/src -B /work/build -G Ninja"
  assert_contains "$OUT" "[dry-run] ninja -C /work/build -j 2 aseprite"
  assert_contains "$OUT" "==> [7/9]"
  assert_missing "$T/docker.log"
  assert_missing "$WORK/tmp/install-aseprite.sh"
}

# ------------------------------------------------------------ install (step 8)

# A work folder as it is after a successful container build.
setup_install() {
  use_test_paths
  init_globals
  resolve_paths
  local s="$WORK/src/src/desktop/linux" n
  mkdir -p "$WORK/tmp" "$WORK/logs" "$WORK/build/bin/data" "$s/mime" "$s/gnome" "$WORK/src/data/icons"
  LOG_FILE="$WORK/logs/run-20261126-101500.log" LOCK_HELD=1
  printf '#!/bin/sh\nprintf "%%s|%%s|%%s\\n" "$HOME" "$XDG_CONFIG_HOME" "$ASEPRITE_USER_FOLDER" >"%s/seen-env"\necho "Aseprite 1.3.18.6-dev"\n' "$T" >"$WORK/build/bin/aseprite"
  chmod +x "$WORK/build/bin/aseprite"
  : >"$WORK/build/bin/icudtl.dat"
  : >"$WORK/build/bin/gen"
  : >"$WORK/build/bin/data/pref.xml"
  printf '%s\n' "$DESKTOP_SAMPLE" >"$s/aseprite.desktop"
  printf '%s\n' "$THUMB_SCRIPT_SAMPLE" >"$s/aseprite-thumbnailer"
  printf '%s\n' "$THUMB_ENTRY_SAMPLE" >"$s/gnome/aseprite.thumbnailer"
  printf '<mime-info/>\n' >"$s/mime/aseprite.xml"
  for n in 16 20 24 28 32 48 64 128 256; do : >"$WORK/src/data/icons/ase$n.png"; done
  : >"$WORK/src/data/icons/doc16.png"
  BUILD_REF=v1.3.18.6 REF_KIND=tag REF_COMMIT=$SHA_B SKIA_TAG=m124-08a5439a6b
  BUILT_VERSION_LINE="Aseprite 1.3.18.6-dev" CONTAINER_SECONDS=872
  x_ldd() { printf '%s\n' "$LDD_CLEAN"; }
  refresh_caches() { echo refreshed >>"$T/caches.log"; }
  x_date() { echo 2026-11-26T10:15:00+01:00; }
}

expected_manifest() {
  local n
  printf '%s\n' "$BIN_LINK" "$DESKTOP_FILE"
  for n in 16 20 24 28 32 48 64 128 256; do printf '%s\n' "$ICON_ROOT/${n}x$n/apps/aseprite.png"; done
  printf '%s\n' "$MIME_FILE" "$THUMB_BIN" "$THUMB_ENTRY" "$APP_DIR"
}

test_install_puts_everything_in_place() {
  setup_install
  capture step_install
  assert_rc 0 "$RC"
  assert_exists "$APP_DIR/aseprite"
  assert_exists "$APP_DIR/data/pref.xml"
  assert_exists "$APP_DIR/icudtl.dat"
  assert_exists "$APP_DIR/gen"
  assert_missing "$APP_DIR.new"
  assert_missing "$APP_DIR.old"
  [[ -L $BIN_LINK ]] || fail "bin/aseprite is not a symlink"
  assert_eq "$BIN" "$(readlink "$BIN_LINK")"
  local desktop; desktop=$(<"$DESKTOP_FILE")
  assert_contains "$desktop" $'\nExec='"$BIN"$' %U\n'
  assert_contains "$desktop" $'\nTryExec='"$BIN"$'\n'
  assert_contains "$desktop" $'\nIcon=aseprite\n'
  local n
  for n in 16 20 24 28 32 48 64 128 256; do assert_exists "$ICON_ROOT/${n}x$n/apps/aseprite.png"; done
  assert_exists "$MIME_FILE"
  [[ -x $THUMB_BIN ]] || fail "thumbnailer not executable"
  assert_eq 755 "$(stat -c %a "$THUMB_BIN")" "thumbnailer mode"
  assert_contains "$(<"$THUMB_BIN")" "$BIN -b \"\$1\" --sheet"
  assert_contains "$(<"$THUMB_ENTRY")" "TryExec=$THUMB_BIN"
  assert_contains "$(<"$THUMB_ENTRY")" "Exec=$THUMB_BIN %i %o %s"
  assert_exists "$T/caches.log"
  assert_eq "$(expected_manifest)" "$(<"$MANIFEST_FILE")" "manifest"
  local pair
  for pair in ref=v1.3.18.6 "commit=$SHA_B" version=1.3.18.6-dev skia_tag=m124-08a5439a6b \
    build_base=ubuntu:24.04 installed_at=2026-11-26T10:15:00+01:00 script_version=1.0.0; do
    assert_eq "${pair#*=}" "$(state_get "$STATE_FILE" "${pair%%=*}")" "state ${pair%%=*}"
  done
  assert_contains "$(<"$LOG_FILE")" "+ cp -a -- $WORK/build/bin $APP_DIR.new"
}

test_install_replaces_the_previous_install() {
  setup_install
  mkdir -p "$APP_DIR"
  : >"$APP_DIR/from-the-old-version"
  capture step_install
  assert_rc 0 "$RC"
  assert_missing "$APP_DIR/from-the-old-version"
  assert_eq "aseprite" "$(cd "$PREFIX/opt" && printf '%s ' * | xargs)" "only one opt/aseprite folder"
}

test_install_with_a_missing_library_exits_8_and_keeps_the_old_install() {
  setup_install
  mkdir -p "$APP_DIR"
  : >"$APP_DIR/previous"
  ASEPRITE_TEST_FAKE_MISSING_LIB=libXcursor.so.1
  fake_os_release 'ID=fedora'
  capture2 step_install
  assert_rc 8 "$RC"
  assert_contains "$ERR_OUT" "libXcursor.so.1"
  assert_eq "hint: sudo dnf install libXcursor" "$(hint_line "$ERR_OUT")"
  assert_exists "$APP_DIR/previous"
  assert_missing "$APP_DIR.new"
  assert_missing "$BIN_LINK"
  assert_missing "$DESKTOP_FILE"
}

test_install_refuses_to_replace_a_regular_file_bin() {
  setup_install
  mkdir -p "$PREFIX/bin"
  echo mine >"$BIN_LINK"
  capture step_install
  assert_rc 8 "$RC"
  assert_eq mine "$(<"$BIN_LINK")"
  assert_missing "$APP_DIR"
}

test_install_recovers_a_swap_left_by_a_killed_run() {
  setup_install
  mkdir -p "$APP_DIR.old"
  : >"$APP_DIR.old/previous"
  capture step_install
  assert_rc 0 "$RC"
  assert_exists "$APP_DIR/aseprite"
  assert_missing "$APP_DIR.old"
  assert_missing "$APP_DIR/previous"
}

test_install_dry_run_changes_nothing() {
  setup_install
  DRY_RUN=1 LOCK_HELD=0
  capture step_install
  assert_rc 0 "$RC"
  assert_contains "$OUT" "[dry-run] cp -a -- $WORK/build/bin $APP_DIR.new"
  assert_contains "$OUT" "[dry-run] ldd $APP_DIR.new/aseprite"
  assert_contains "$OUT" "[dry-run] ln -sfn -- $BIN $BIN_LINK"
  assert_missing "$PREFIX"
}

# ------------------------------------------------------------- finish (step 9)

test_finish_checks_the_installed_binary_and_cleans_up() {
  setup_install
  step_install >/dev/null
  mkdir -p "$WORK/downloads/m124-08a5439a6b" "$WORK/skia/skia-m124-08a5439a6b" "$WORK/skia/skia-m100-old"
  IMAGE_STEP_REACHED=1
  fake_docker
  capture step_finish
  assert_rc 0 "$RC"
  assert_missing "$WORK/src"
  assert_missing "$WORK/build"
  assert_missing "$WORK/downloads"
  assert_missing "$WORK/skia/skia-m100-old"
  assert_exists "$WORK/skia/skia-m124-08a5439a6b"
  assert_contains "$(<"$T/docker.log")" "image rm aseprite-installer-builder:ubuntu-24.04"
  assert_sandboxed_env "$(<"$T/seen-env")"
  assert_contains "$OUT" "Aseprite 1.3.18.6-dev installed"
  assert_contains "$OUT" "  binary:   $BIN_LINK -> $BIN"
  assert_contains "$OUT" "  menu:     Aseprite (Graphics)"
  assert_contains "$OUT" "  skia:     m124-08a5439a6b"
  assert_contains "$OUT" "  built in: 14m 32s (ubuntu:24.04 container)"
  assert_contains "$OUT" "  image:    removed (use --keep-image to keep it)"
  assert_contains "$OUT" "  log:      $LOG_FILE"
  assert_contains "$OUT" "Run again any time to update to the newest release."
  assert_contains "$OUT" "is not in your PATH"
}

assert_sandboxed_env() { # "HOME|XDG_CONFIG_HOME|ASEPRITE_USER_FOLDER" as the binary saw them
  local part
  local -a parts
  IFS='|' read -ra parts <<<"$1"
  assert_eq 3 "${#parts[@]}" "sandbox variables set: [$1]"
  for part in "${parts[@]}"; do
    [[ $part == "$WORK/tmp/"* ]] || fail "aseprite ran on the host with [$1]; every folder must be under $WORK/tmp"
  done
}

test_host_runs_of_the_binary_never_see_the_real_config() {
  setup_install
  mkdir -p "$T/home/.config/aseprite"
  : >"$T/home/.config/aseprite/Aseprite.log"
  touch -d '2020-01-01' "$T/home/.config/aseprite/Aseprite.log" "$T/home/.config/aseprite"
  local before; before=$(stat -c '%Y' "$T/home/.config/aseprite" "$T/home/.config/aseprite/Aseprite.log")
  XDG_CONFIG_HOME="$T/home/.config" ASEPRITE_USER_FOLDER="$T/home/.config/aseprite"
  export XDG_CONFIG_HOME ASEPRITE_USER_FOLDER
  capture run_host_binary "$WORK/build/bin/aseprite" --version
  assert_rc 0 "$RC"
  assert_eq "Aseprite 1.3.18.6-dev" "$OUT"
  assert_sandboxed_env "$(<"$T/seen-env")"
  assert_eq "$before" "$(stat -c '%Y' "$T/home/.config/aseprite" "$T/home/.config/aseprite/Aseprite.log")" "the real config folder"
}

test_finish_with_keep_build_and_keep_image() {
  setup_install
  step_install >/dev/null
  OPT_KEEP_BUILD=1 OPT_KEEP_IMAGE=1 IMAGE_STEP_REACHED=1
  fake_docker
  PATH="$PREFIX/bin:$PATH"
  capture step_finish
  assert_rc 0 "$RC"
  assert_exists "$WORK/src"
  assert_exists "$WORK/build"
  [[ ! -e $T/docker.log ]] || assert_not_contains "$(<"$T/docker.log")" "image rm"
  assert_contains "$OUT" "  image:    kept"
  assert_not_contains "$OUT" "is not in your PATH"
}

test_finish_version_mismatch_exits_8() {
  setup_install
  step_install >/dev/null
  BUILT_VERSION_LINE="Aseprite 9.9-dev"
  capture step_finish
  assert_rc 8 "$RC"
  assert_contains "$OUT" "9.9-dev"
}

# --------------------------------------------- Ctrl-C while a container runs

# A docker fake whose `run` blocks like a long container, and whose
# `rm -f` stops it, as the real daemon would.
blocking_docker() {
  fake_docker "case \$1 in
  run) [[ -d $T/work/tmp ]] && printf '6|Building Aseprite (ninja -j 2)\\n' >\"$T/work/tmp/container-step\"
    echo \$\$ >\"$T/run.pid\"; exec sleep 30 ;;
  rm) [[ \$2 == -f && -s $T/run.pid ]] && kill \"\$(<\"$T/run.pid\")\" 2>/dev/null ;;
  image) [[ \$2 == inspect ]] && exit 1 ;;
esac
exit 0"
}

# interrupt_while_running FUNCTION: run it in the background (job control
# on, so SIGINT is not ignored), send SIGINT once the container runs.
interrupt_while_running() {
  local pid i start
  set -m
  ("$1") >"$T/int.out" 2>&1 &
  pid=$!
  set +m
  for ((i = 0; i < 500; i++)); do
    [[ -s $T/run.pid ]] && break
    command sleep 0.01
  done
  [[ -s $T/run.pid ]] || fail "the container never started: $(<"$T/int.out")"
  start=$(date +%s%N)
  kill -INT "$pid"
  wait "$pid"
  RC=$?
  ELAPSED_MS=$((($(date +%s%N) - start) / 1000000))
  OUT=$(<"$T/int.out")
}

test_ctrl_c_during_the_setup_container_removes_it_at_once() {
  setup_image_step
  blocking_docker
  interrupt_while_running image_step_with_traps
  assert_rc 130 "$RC"
  ((ELAPSED_MS < 5000)) || fail "took ${ELAPSED_MS} ms to stop"
  assert_contains "$(<"$T/docker.log")" $'\nrm -f aseprite-installer-setup-'
  kill -0 "$(<"$T/run.pid")" 2>/dev/null && fail "the container process is still running"
  assert_contains "$(last_line "$OUT")" "(exit 130)"
}

test_ctrl_c_during_the_build_container_removes_it_at_once() {
  setup_host_container_step
  blocking_docker
  interrupt_while_running container_step_with_traps
  assert_rc 130 "$RC"
  ((ELAPSED_MS < 5000)) || fail "took ${ELAPSED_MS} ms to stop"
  assert_contains "$(<"$T/docker.log")" $'\nrm -f aseprite-installer-build-'
  kill -0 "$(<"$T/run.pid")" 2>/dev/null && fail "the container process is still running"
  assert_eq "" "$(ls -A "$WORK/tmp")" "tmp emptied"
  assert_contains "$(last_line "$OUT")" "stopped at step [6/9] Building Aseprite (ninja -j 2) (exit 130)" "the step the container was in"
}

# --------------------------------------------------------- -- uninstall

setup_installed() {
  setup_install
  step_install >/dev/null
  mkdir -p "$HOME/.config/aseprite"
  echo "[general]" >"$HOME/.config/aseprite/aseprite.ini"
  refresh_caches() { echo refreshed >>"$T/caches.log"; }
  rm -f "$T/caches.log"
}

test_uninstall_removes_every_manifest_path_and_keeps_the_config() {
  setup_installed
  local -a listed
  mapfile -t listed <"$MANIFEST_FILE"
  capture main --uninstall --yes
  assert_rc 0 "$RC"
  local p
  for p in "${listed[@]}"; do assert_missing "$p"; done
  assert_missing "$ICON_ROOT/16x16/apps" "empty icon folders the script made"
  assert_missing "$ICON_ROOT/16x16"
  assert_eq "[general]" "$(<"$HOME/.config/aseprite/aseprite.ini")"
  assert_contains "$OUT" "~/.config/aseprite/"
  assert_contains "$OUT" "$DESKTOP_FILE"
  assert_exists "$T/caches.log"
  assert_contains "$OUT" "[2/2]"
  capture main --uninstall --yes
  assert_rc 0 "$RC" "second uninstall"
  assert_contains "$OUT" "Aseprite is not installed"
}

test_uninstall_keeps_icon_folders_that_hold_other_icons() {
  setup_installed
  : >"$ICON_ROOT/16x16/apps/other-app.png"
  capture main --uninstall --yes
  assert_rc 0 "$RC"
  assert_exists "$ICON_ROOT/16x16/apps/other-app.png"
}

test_uninstall_without_yes_and_no_terminal_exits_1() {
  setup_installed
  capture main --uninstall
  assert_rc 1 "$RC"
  assert_contains "$OUT" "--yes"
  assert_exists "$BIN"
  assert_exists "$DESKTOP_FILE"
}

test_uninstall_asks_on_the_terminal() {
  setup_installed
  stdin_is_tty() { return 0; }
  read_tty_answer() { printf n; }
  capture main --uninstall
  assert_rc 1 "$RC" "answer n"
  assert_contains "$OUT" "Remove these? [y/N]"
  assert_exists "$BIN"
  read_tty_answer() { printf y; }
  capture main --uninstall
  assert_rc 0 "$RC" "answer y"
  assert_missing "$BIN"
}

test_uninstall_without_manifest_uses_the_fixed_paths() {
  setup_installed
  rm -f "$MANIFEST_FILE"
  capture main --uninstall --yes
  assert_rc 0 "$RC"
  assert_missing "$APP_DIR"
  assert_missing "$BIN_LINK"
  assert_missing "$DESKTOP_FILE"
  assert_missing "$ICON_ROOT/256x256/apps/aseprite.png"
  assert_missing "$MIME_FILE"
  assert_missing "$THUMB_BIN"
  assert_missing "$THUMB_ENTRY"
}

test_uninstall_fallback_keeps_a_bin_that_is_not_ours() {
  setup_installed
  rm -f "$MANIFEST_FILE"
  ln -sfn /usr/bin/true "$BIN_LINK"
  capture main --uninstall --yes
  assert_rc 0 "$RC"
  [[ -L $BIN_LINK ]] || fail "a symlink pointing elsewhere was removed"
  setup_installed
  rm -f "$MANIFEST_FILE" "$BIN_LINK"
  echo mine >"$BIN_LINK"
  capture main --uninstall --yes
  assert_eq mine "$(<"$BIN_LINK")" "a regular file is kept"
}

test_uninstall_ignores_manifest_entries_outside_the_prefix() {
  setup_installed
  : >"$T/outside-file"
  printf '%s\n' "$T/outside-file" /etc/hostname >>"$MANIFEST_FILE"
  capture main --uninstall --yes
  assert_rc 0 "$RC"
  assert_exists "$T/outside-file"
  assert_missing "$APP_DIR"
}

test_uninstall_skips_the_platform_disk_docker_and_library_checks() {
  setup_installed
  fake_platform Darwin FAIL aarch64
  x_df() { return 1; }
  fake_docker 'exit 1'
  check_runtime_libs() { exit 4; }
  capture main --uninstall --yes
  assert_rc 0 "$RC"
  assert_missing "$T/docker.log"
  assert_missing "$APP_DIR"
}

test_uninstall_dry_run_changes_nothing() {
  setup_installed
  local -a listed
  mapfile -t listed <"$MANIFEST_FILE"
  rm -rf "$WORK"
  capture main --uninstall --purge --dry-run
  assert_rc 0 "$RC"
  local p
  for p in "${listed[@]}"; do assert_exists "$p"; done
  assert_contains "$OUT" "[dry-run]"
  assert_contains "$OUT" "$BIN_LINK"
  assert_missing "$WORK" "the work folder is not even created"
  assert_missing "$T/caches.log"
}

test_purge_removes_the_work_folder_and_the_images() {
  setup_installed
  fake_docker
  : >"$WORK/pulled-base"
  mkdir -p "$WORK/skia/skia-m124-08a5439a6b"
  capture main --uninstall --purge --yes
  assert_rc 0 "$RC"
  assert_missing "$WORK"
  local calls; calls=$(<"$T/docker.log")
  assert_contains "$calls" "image rm aseprite-installer-builder:ubuntu-24.04"
  assert_contains "$calls" "image rm ubuntu:24.04"
  assert_missing "$APP_DIR"
}

test_purge_keeps_files_it_did_not_make() {
  setup_installed
  fake_docker
  : >"$WORK/my-notes.txt"
  capture2 main --uninstall --purge --yes
  assert_rc 0 "$RC"
  assert_exists "$WORK/my-notes.txt"
  assert_missing "$WORK/src"
  assert_missing "$WORK/logs"
  assert_missing "$WORK/lock"
  assert_contains "$ERR_OUT" "my-notes.txt"
}

test_purge_with_docker_unreachable_prints_the_command() {
  setup_installed
  fake_docker 'exit 1'
  capture2 main --uninstall --purge --yes
  assert_rc 0 "$RC"
  assert_contains "$ERR_OUT" "docker image rm aseprite-installer-builder:ubuntu-24.04"
  assert_missing "$WORK"
}

test_purge_when_not_installed_still_purges() {
  use_test_paths
  mkdir -p "$T/work/logs" "$T/work/skia/skia-x"
  fake_docker '[[ "$1 $2" == "image inspect" ]] && exit 1; exit 0'
  capture main --uninstall --purge --yes
  assert_rc 0 "$RC"
  assert_contains "$OUT" "Aseprite is not installed"
  assert_missing "$T/work"
}

test_work_folder_default_when_executed_from_another_folder() {
  local before after
  before=$([[ -e $UNIT_REPO/.work ]] && echo yes || echo no)
  mkdir -p "$T/elsewhere"
  capture bash -c 'cd "$1" && bash "$2" --uninstall --dry-run' _ "$T/elsewhere" "$UNIT_SCRIPT"
  assert_rc 0 "$RC"
  assert_contains "$OUT" "Work folder: $UNIT_REPO/.work"
  capture bash -c 'cd "$1/tests" && bash ../install-aseprite.sh --uninstall --dry-run' _ "$UNIT_REPO"
  assert_rc 0 "$RC" "relative path from tests/"
  assert_contains "$OUT" "Work folder: $UNIT_REPO/.work"
  after=$([[ -e $UNIT_REPO/.work ]] && echo yes || echo no)
  assert_eq "$before" "$after" "a dry run does not create the work folder"
}

# ------------------------------------------------------------ whole dry run

test_dry_run_end_to_end_prints_every_step_and_changes_nothing() {
  fake_good_host
  setup_resolve
  fake_docker '[[ $1 == info ]] && { echo "/var/lib/docker|[name=seccomp]"; exit 0; }; [[ "$1 $2" == "image inspect" ]] && exit 1; exit 0'
  capture main --dry-run
  assert_rc 0 "$RC"
  local n
  for n in 1 2 3 4 5 6 7 8 9; do assert_contains "$OUT" "==> [$n/9]"; done
  assert_contains "$OUT" "[dry-run] docker run --rm --name aseprite-installer-build-"
  assert_contains "$OUT" "Dry run: nothing was changed."
  assert_missing "$T/work"
  assert_missing "$T/prefix"
  local line
  while IFS= read -r line; do
    case $line in info* | "image inspect"*) ;; *) fail "dry run ran docker $line" ;; esac
  done <"$T/docker.log"
}

# ================================================================== runner
# (Keep this block last. New tests go above it.)

unit_test_names() {
  local line re='^test_([a-z0-9_]+)\(\)'
  while IFS= read -r line; do
    [[ $line =~ $re ]] && printf '%s\n' "${BASH_REMATCH[1]}"
  done <"${BASH_SOURCE[0]}"
}

unit_make_guards() {
  local g="$UNIT_ROOT/guard-bin" name
  mkdir -p "$g"
  for name in docker sudo curl wget; do
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s $*" >>"${UNIT_GUARD_LOG:-/dev/null}"\nexit 99\n' "$name" >"$g/$name"
    chmod +x "$g/$name"
  done
  # git: local commands pass through to the real git, network ones are refused.
  cat >"$g/git" <<'GIT'
#!/usr/bin/env bash
for a in "$@"; do
  case $a in
    ls-remote|clone|fetch|pull|push|update)
      printf '%s\n' "git $*" >>"${UNIT_GUARD_LOG:-/dev/null}"; exit 99 ;;
  esac
done
exec "$UNIT_REAL_GIT" "$@"
GIT
  chmod +x "$g/git"
}

unit_run_one() { # ut_name -> 0 pass, 1 fail
  local ut_name=$1 ut_dir ut_rc ut_reason
  ut_dir=$(mktemp -d -p "$UNIT_ROOT" "$ut_name.XXXXXX") || return 1
  mkdir -p "$ut_dir/bin" "$ut_dir/home"
  (
    export T="$ut_dir" HOME="$ut_dir/home" UNIT_GUARD_LOG="$ut_dir/.guard.log" UNIT_REAL_GIT
    export PATH="$ut_dir/bin:$UNIT_ROOT/guard-bin:$UNIT_PATH"
    unset ASEPRITE_PREFIX ASEPRITE_WORK_DIR ASEPRITE_TEST_BREAK_SKIA \
      ASEPRITE_TEST_FAKE_MISSING_LIB NO_COLOR
    cd "$ut_dir" || exit 1
    # shellcheck source=install-aseprite.sh
    source "$UNIT_SCRIPT" || exit 1
    "test_$ut_name"
  ) 3>"$ut_dir/.reason" >"$ut_dir/.out" 2>&1 </dev/null
  ut_rc=$?
  ut_reason=$(<"$ut_dir/.reason")
  if [[ $ut_rc == 0 && -s $ut_dir/.guard.log ]]; then
    ut_rc=1
    ut_reason="reached a guarded command: $(<"$ut_dir/.guard.log")"
  fi
  if [[ $ut_rc == 0 ]]; then
    printf 'PASS %s\n' "$ut_name"
    rm -rf -- "$ut_dir"
    return 0
  fi
  [[ -n $ut_reason ]] || ut_reason="exit $ut_rc; output: $(tail -n 5 "$ut_dir/.out" | tr '\n' ' ')"
  printf 'FAIL %s: %s (files kept in %s)\n' "$ut_name" "${ut_reason//$'\n'/ }" "${ut_dir#"$UNIT_REPO"/}"
  return 1
}

unit_main() {
  local -a all=() chosen=()
  local name pass=0 failed=0 start end
  mapfile -t all < <(unit_test_names)
  if [[ ${1:-} == --list ]]; then
    printf '%s\n' "${all[@]}"
    return 0
  fi
  if (( $# )); then
    for name in "$@"; do
      if [[ " ${all[*]} " != *" $name "* ]]; then
        printf 'unit: no test named %s (see --list)\n' "$name" >&2
        return 2
      fi
      chosen+=("$name")
    done
  else
    chosen=("${all[@]}")
  fi
  [[ -f $UNIT_SCRIPT ]] || { printf 'unit: %s not found\n' "$UNIT_SCRIPT" >&2; return 2; }
  mkdir -p "$UNIT_ROOT"
  unit_make_guards
  start=$(date +%s)
  for name in "${chosen[@]}"; do
    if unit_run_one "$name"; then pass=$((pass + 1)); else failed=$((failed + 1)); fi
  done
  end=$(date +%s)
  printf 'unit: %d passed, %d failed, 0 skipped (%ds)\n' "$pass" "$failed" "$((end - start))"
  (( failed == 0 ))
}

unit_main "$@"
