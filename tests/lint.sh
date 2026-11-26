#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# tests/lint.sh: static checks: shellcheck and bash -n on every script.
#
#   tests/lint.sh [--list] [test...]
#
# Tests:
#   - syntax: `bash -n` on every shell script in the repo
#   - shellcheck: `shellcheck -x` on install-aseprite.sh, tests/*.sh and the
#     shell scripts in tests/fakes/; it must report nothing
#
# Which shellcheck: a local `shellcheck` if there is one. Otherwise the pinned
# image koalaman/shellcheck:v0.10.0 runs with the repo mounted read-only. If lint
# pulled that image, it removes it afterwards, unless LINT_KEEP_IMAGE=1.
# Nothing is installed on the host and nothing in the repo is written.
set -Euo pipefail

REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SC_IMAGE=koalaman/shellcheck:v0.10.0
ALL_TESTS=(syntax shellcheck)
declare -A DESC=(
  [syntax]='bash -n passes on every script'
  [shellcheck]='shellcheck -x install-aseprite.sh tests/*.sh tests/fakes/* reports nothing'
)

PASSED=0 FAILED=0 SKIPPED=0
PULLED=0

pass() { echo "PASS $1"; PASSED=$((PASSED + 1)); }
fail() { echo "FAIL $1: $2"; FAILED=$((FAILED + 1)); }
skip() { echo "SKIP $1: $2"; SKIPPED=$((SKIPPED + 1)); }
note() { printf '# %s\n' "$@"; }

cleanup() {
  if ((PULLED)) && [[ ${LINT_KEEP_IMAGE:-} != 1 ]]; then
    if docker image rm "$SC_IMAGE" >/dev/null 2>&1; then
      note "removed $SC_IMAGE (lint pulled it; set LINT_KEEP_IMAGE=1 to keep it)"
    else
      note "could not remove $SC_IMAGE; remove it with: docker image rm $SC_IMAGE"
    fi
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Shell scripts, as paths relative to the repo: install-aseprite.sh, tests/*.sh,
# every other *.sh outside .git/.work/.test, and files in tests/fakes/ whose
# first line is a sh/bash shebang. Symlinks are skipped (their target is checked).
list_scripts() {
  local f first
  {
    [[ -e $REPO/install-aseprite.sh ]] && echo install-aseprite.sh
    (cd -- "$REPO" && find . \( -path ./.git -o -path ./.work -o -path ./.test \) -prune \
      -o -type f -name '*.sh' -print | sed 's#^\./##')
    if [[ -d $REPO/tests/fakes ]]; then
      for f in "$REPO"/tests/fakes/*; do
        [[ -f $f && ! -L $f ]] || continue
        IFS= read -r first <"$f" || true
        [[ $first =~ ^\#!.*(/|[[:space:]])(ba)?sh([[:space:]]|$) ]] && echo "tests/fakes/${f##*/}"
      done
    fi
  } | sort -u
}

t_syntax() {
  local f out bad=()
  if [[ ! -f $REPO/install-aseprite.sh ]]; then
    fail syntax "install-aseprite.sh not found"
    return
  fi
  while IFS= read -r f; do
    if ! out=$(bash -n "$REPO/$f" 2>&1); then
      bad+=("$f")
      note "bash -n $f:" "${out//$'\n'/$'\n'# }"
    fi
  done < <(list_scripts)
  if ((${#bad[@]})); then
    fail syntax "bash -n failed on: ${bad[*]}"
  else
    pass syntax
  fi
}

shellcheck_targets() {
  local f
  while IFS= read -r f; do
    case $f in
      install-aseprite.sh | tests/*.sh | tests/fakes/*) echo "$f" ;;
    esac
  done < <(list_scripts)
}

t_shellcheck() {
  local files=() out rc
  mapfile -t files < <(shellcheck_targets)
  if [[ ! -f $REPO/install-aseprite.sh ]]; then
    fail shellcheck "install-aseprite.sh not found"
    return
  fi
  note "shellcheck -x on: ${files[*]}"

  if command -v shellcheck >/dev/null 2>&1; then
    note "using local $(shellcheck --version | sed -n 's/^version: /shellcheck /p')"
    out=$(cd -- "$REPO" && shellcheck -x "${files[@]}" 2>&1)
    rc=$?
  else
    if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
      fail shellcheck "no local shellcheck, and Docker is not usable to run $SC_IMAGE"
      return
    fi
    if ! docker image inspect "$SC_IMAGE" >/dev/null 2>&1; then
      note "pulling $SC_IMAGE"
      if ! docker pull -q "$SC_IMAGE" >/dev/null; then
        fail shellcheck "could not pull $SC_IMAGE"
        return
      fi
      PULLED=1
    fi
    note "using $SC_IMAGE in a container (repo mounted read-only)"
    out=$(docker run --rm --security-opt label=disable \
      -v "$REPO:/mnt:ro" -w /mnt "$SC_IMAGE" -x "${files[@]}" 2>&1)
    rc=$?
  fi

  if ((rc == 0)) && [[ -z $out ]]; then
    pass shellcheck
  else
    [[ -n $out ]] && note "${out//$'\n'/$'\n'# }"
    local n
    n=$(grep -cE '^In .* line [0-9]+:' <<<"$out" || true)
    fail shellcheck "shellcheck exit $rc, $n finding(s) (see above)"
  fi
}

usage() {
  echo "usage: tests/lint.sh [--list] [test...]"
  echo "tests: ${ALL_TESTS[*]}"
}

main() {
  local selected=() t arg
  for arg in "$@"; do
    case $arg in
      --list)
        for t in "${ALL_TESTS[@]}"; do printf '%-11s %s\n' "$t" "${DESC[$t]}"; done
        return 0
        ;;
      -h | --help) usage; return 0 ;;
      -*) usage >&2; return 2 ;;
      *)
        if [[ -z ${DESC[$arg]+x} ]]; then
          echo "unknown test: $arg" >&2
          usage >&2
          return 2
        fi
        selected+=("$arg")
        ;;
    esac
  done
  ((${#selected[@]})) || selected=("${ALL_TESTS[@]}")

  for t in "${selected[@]}"; do "t_$t"; done
  echo "lint: $PASSED passed, $FAILED failed, $SKIPPED skipped"
  ((FAILED == 0))
}

main "$@"
