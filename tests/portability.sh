#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# tests/portability.sh: runtime checks in throwaway distro containers.
#
#   tests/portability.sh [--list] [--app-dir DIR] [test-or-distro...]
#
# Nothing runs on the host except docker. Each distro gets one `docker run -d --rm`
# container (root inside it is fine) with install-aseprite.sh mounted read-only and,
# when there is one, the built app folder mounted read-only. The suite sources the
# script there and calls check_platform / check_runtime_libs.
# For the install test it runs the printed `hint:` command without
# sudo, after refreshing the package lists, with the package manager's
# non-interactive flag added right after its name.
#
# Per glibc distro (debian13 ubuntu2404 fedora45 arch tumbleweed):
#   platform_<d>  check_platform succeeds silently (positive control for 3.)
#   hint_<d>      check_runtime_libs exits 4, names every missing library and
#                 prints the hint for this distro's package manager
#   install_<d>   that command installs; then check_runtime_libs reports nothing missing
#   app_<d>       ldd on a copy of the app finds every library, and
#                 aseprite --version prints the expected version (needs the app)
# Also: glibc_old_debian12 (glibc 2.36 -> exit 1, "too old") and
#       glibc_none_alpine (musl, bash added -> exit 1, no glibc).
# A distro name (e.g. fedora45) selects all of its tests.
#
# The app folder: --app-dir DIR, else $APP_DIR, else ~/.local/opt/aseprite if it
# exists, else .test/e2e/prefix/opt/aseprite. When there is none, app_* SKIP.
# The expected version comes from <app>/.aseprite-installer/state (version=),
# else $PORT_EXPECTED_VERSION, else the app's own --version run on the host
# (sandboxed HOME, no DISPLAY).
#
# Images: the suite notes which ones are present first, pulls the rest, and at the
# end removes only those it pulled (PORT_KEEP_IMAGES=1 keeps them). Results and logs
# go to .test/portability/.
# Do not run at the same time as tests/e2e.sh (both use ubuntu:24.04).
set -uo pipefail

REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT=$REPO/install-aseprite.sh
OUTDIR=$REPO/.test/portability
IN_SCRIPT=/opt/test/install-aseprite.sh
IN_APP=/opt/app

LIBS=(libstdc++.so.6 libgcc_s.so.1 libX11.so.6 libXcursor.so.1 libXi.so.6 libXrandr.so.2 libGL.so.1 libfontconfig.so.1)
GLIBC_DISTROS=(debian13 ubuntu2404 fedora45 arch tumbleweed)
declare -A IMAGE=([debian13]=debian:13 [ubuntu2404]=ubuntu:24.04 [fedora45]=fedora:45
  [arch]=archlinux:latest [tumbleweed]=opensuse/tumbleweed [debian12]=debian:12 [alpine]=alpine:latest)
declare -A FAMILY=([debian13]=debian [ubuntu2404]=debian [fedora45]=fedora [arch]=arch [tumbleweed]=suse)
declare -A HINT_HEAD=([debian]='apt install' [fedora]='dnf install' [arch]='pacman -S --needed' [suse]='zypper install')
# README runtime table, per family, in LIBS order (for the report only; the tests use the hint)
declare -A EXPECTED_PKGS=(
  [fedora]='libstdc++ libgcc libX11 libXcursor libXi libXrandr libglvnd-glx fontconfig'
  [debian]='libstdc++6 libgcc-s1 libx11-6 libxcursor1 libxi6 libxrandr2 libgl1 libfontconfig1'
  [arch]='gcc-libs gcc-libs libx11 libxcursor libxi libxrandr libglvnd fontconfig'
  [suse]='libstdc++6 libgcc_s1 libX11-6 libXcursor1 libXi6 libXrandr2 libGL1 libfontconfig1'
)

TESTS=()
declare -A DESC=()
for d in "${GLIBC_DISTROS[@]}"; do
  TESTS+=("platform_$d" "hint_$d" "install_$d" "app_$d")
  DESC[platform_$d]="${IMAGE[$d]}: check_platform succeeds silently"
  DESC[hint_$d]="${IMAGE[$d]}: check_runtime_libs exits 4, lists the missing libs, prints the '${HINT_HEAD[${FAMILY[$d]}]}' hint"
  DESC[install_$d]="${IMAGE[$d]}: run that hint command (needs hint_$d); then nothing is missing"
  DESC[app_$d]="${IMAGE[$d]}: ldd on a copy of the app finds every library; --version as expected (needs install_$d and the app)"
done
TESTS+=(glibc_old_debian12 glibc_none_alpine)
DESC[glibc_old_debian12]='debian:12 (glibc 2.36): check_platform exits 1 and says the glibc is too old'
DESC[glibc_none_alpine]='alpine:latest (musl, bash added): check_platform exits 1 and says no glibc was found'

PASSED=0 FAILED=0 SKIPPED=0
declare -A SEL=() STATUS=()
PULLED=() CONTAINERS=()
C='' D='' XRC=0 XOUT='' XERR=''
APP_DIR_ARG='' APP='' EXPECTED=''
HINT_LINE=''

ts() { date +%H:%M:%S; }
log() { printf '# %s %s\n' "$(ts)" "$*"; }
indent() { sed 's/^/#            /'; }

result() { # PASS|FAIL|SKIP test [reason]
  STATUS[$2]=$1
  if [[ -z ${SEL[$2]:-} ]]; then
    [[ $1 == PASS ]] || log "(prerequisite, not selected) $1 $2: ${3:-}"
    return 0
  fi
  case $1 in
    PASS) echo "PASS $2"; PASSED=$((PASSED + 1)) ;;
    FAIL) echo "FAIL $2: $3"; FAILED=$((FAILED + 1)) ;;
    SKIP) echo "SKIP $2: $3"; SKIPPED=$((SKIPPED + 1)) ;;
  esac
}

# ---------------------------------------------------------------- docker helpers

image_present() { docker image inspect "$1" >/dev/null 2>&1; }

ensure_image() {
  image_present "$1" && return 0
  log "pulling $1 (not present before; will be removed at the end)"
  docker pull -q "$1" >/dev/null || return 1
  PULLED+=("$1")
}

cleanup() {
  local c i
  for c in "${CONTAINERS[@]}"; do docker kill "$c" >/dev/null 2>&1; done
  if ((${#PULLED[@]})); then
    if [[ ${PORT_KEEP_IMAGES:-} == 1 ]]; then
      log "keeping the images this run pulled (PORT_KEEP_IMAGES=1): ${PULLED[*]}"
    else
      for i in "${PULLED[@]}"; do
        if docker image rm "$i" >/dev/null 2>&1; then
          log "removed $i (pulled by this run)"
        else
          log "could not remove $i; remove it with: docker image rm $i"
        fi
      done
    fi
  fi
}

start_container() { # distro
  local d=$1 mounts=(-v "$SCRIPT:$IN_SCRIPT:ro")
  [[ -n $APP ]] && mounts+=(-v "$APP:$IN_APP:ro")
  ensure_image "${IMAGE[$d]}" || return 1
  C=aseprite-portability-$d-$$
  D=$OUTDIR/$d
  rm -rf -- "${D:?}"
  mkdir -p -- "$D"
  # --rm: the container is removed when it stops; sleep is a fail-safe if this suite dies.
  docker run -d --rm --name "$C" --security-opt label=disable "${mounts[@]}" \
    "${IMAGE[$d]}" sleep 7200 >/dev/null || return 1
  CONTAINERS+=("$C")
  if [[ $d == alpine ]]; then
    log "$d: apk add bash"
    docker exec "$C" apk add --no-cache bash >"$D/apk.log" 2>&1 || return 1
  fi
}

stop_container() {
  [[ -n $C ]] && docker kill "$C" >/dev/null 2>&1
  C=''
}

xc() { # name cmd... : run in the container, capture rc/stdout/stderr
  XOUT=$D/$1.out
  XERR=$D/$1.err
  shift
  docker exec -e DEBIAN_FRONTEND=noninteractive "$C" "$@" >"$XOUT" 2>"$XERR"
  XRC=$?
}

src_call() { # name function
  xc "$1" bash -c "source $IN_SCRIPT && $2"
}

not_defined() { grep -q "$1: command not found" "$XERR"; }

short() { tr '\n' ' ' <"$1" | cut -c1-200; }

lib_re() { # a soname as an ERE (escape . and +)
  local r=${1//./\\.}
  printf '%s' "${r//+/\\+}"
}

ldconfig_list() { docker exec "$C" sh -c 'ldconfig -p 2>/dev/null || /sbin/ldconfig -p' 2>/dev/null; }

missing_libs() { # libraries from LIBS that ldconfig -p in the container does not list
  local list l
  list=$(ldconfig_list)
  for l in "${LIBS[@]}"; do
    grep -Eq "^[[:space:]]*$(lib_re "$l") \(.*x86-64" <<<"$list" || echo "$l"
  done
}

owner_report() { # which package owns each library (compared with the expected table)
  local list l path owner row=() fam=${FAMILY[$1]} i=0 spec=()
  read -ra spec <<<"${EXPECTED_PKGS[$fam]}"
  list=$(ldconfig_list)
  for l in "${LIBS[@]}"; do
    path=$(grep -E "^[[:space:]]*$(lib_re "$l") \(.*x86-64" <<<"$list" | head -n 1 | sed 's/.*=> //')
    owner='?'
    if [[ -n $path ]]; then
      case $fam in
        debian)
          # shellcheck disable=SC2016 # the container's sh expands these
          owner=$(docker exec "$C" sh -c 'p=$1; r=$(readlink -f "$p"); for q in "$p" "$r" "/usr$p" "${p#/usr}" "/usr$r" "${r#/usr}"; do dpkg -S "$q" 2>/dev/null && break; done' _ "$path" |
            head -n 1 | cut -d: -f1) ;;
        fedora | suse) owner=$(docker exec "$C" rpm -qf --qf '%{NAME}\n' "$path" 2>/dev/null | head -n 1) ;;
        arch) owner=$(docker exec "$C" pacman -Qqo "$path" 2>/dev/null | head -n 1) ;;
      esac
    fi
    if [[ ${owner:-?} == "${spec[$i]}" ]]; then
      row+=("$l=$owner")
    else
      row+=("$l=${owner:-?}(expected:${spec[$i]})")
    fi
    i=$((i + 1))
  done
  log "$1: package that owns each library: ${row[*]}"
}

# ---------------------------------------------------------------- phases

phase_platform() { # distro
  local d=$1
  src_call platform check_platform
  if not_defined check_platform; then
    result FAIL "platform_$d" "check_platform is not defined in install-aseprite.sh"
  elif ((XRC == 0)) && [[ ! -s $XOUT && ! -s $XERR ]]; then
    result PASS "platform_$d"
  else
    result FAIL "platform_$d" "exit $XRC (want 0, silent); stdout: $(short "$XOUT") stderr: $(short "$XERR")"
  fi
}

phase_hint() { # distro ; sets HINT_LINE
  local d=$1 fam=${FAMILY[$1]} missing=() l why=() hints
  HINT_LINE=''
  mapfile -t missing < <(missing_libs)
  log "$d: libraries missing in the bare image (ldconfig -p): ${missing[*]:-none}"
  src_call hint check_runtime_libs
  if not_defined check_runtime_libs; then
    result FAIL "hint_$d" "check_runtime_libs is not defined in install-aseprite.sh"
    return
  fi
  indent <"$XERR"
  ((${#missing[@]})) || why+=("the bare image already has every library, so there is nothing to report")
  ((XRC == 4)) || why+=("exit $XRC, expected 4")
  for l in "${missing[@]}"; do
    grep -qF -- "$l" "$XOUT" "$XERR" || why+=("does not name missing $l")
  done
  hints=$(grep -c '^hint:' "$XERR")
  if ((hints != 1)); then
    grep -q '^hint:' "$XOUT" && why+=("the hint line is on stdout, the contract says stderr")
    why+=("expected exactly one 'hint:' line on stderr, found $hints")
  else
    HINT_LINE=$(grep '^hint:' "$XERR")
    local re
    re="^hint: sudo ${HINT_HEAD[$fam]}( [^ ]+)+\$"
    [[ $HINT_LINE =~ $re ]] ||
      why+=("hint line '$HINT_LINE' is not 'hint: sudo ${HINT_HEAD[$fam]} <packages>' with single spaces")
  fi
  if ((${#why[@]})); then
    result FAIL "hint_$d" "$(printf '%s; ' "${why[@]}" | sed 's/; $//')"
    HINT_LINE=''
  else
    log "$d: $HINT_LINE"
    log "$d: README table for $fam: ${EXPECTED_PKGS[$fam]}"
    result PASS "hint_$d"
  fi
}

phase_install() { # distro
  local d=$1 fam=${FAMILY[$1]} words=() refresh=() install=() why=() left
  if [[ ${STATUS[hint_$d]:-} != PASS || -z $HINT_LINE ]]; then
    result FAIL "install_$d" "needs hint_$d to pass first (it did not)"
    return
  fi
  read -ra words <<<"${HINT_LINE#hint: }"
  # words: sudo <manager> <args...>: drop sudo, add the non-interactive flag after the manager
  case $fam in
    debian) refresh=(apt-get update) install=(apt -y "${words[@]:2}") ;;
    fedora) refresh=(dnf -y makecache) install=(dnf -y "${words[@]:2}") ;;
    arch) refresh=(pacman -Sy --noconfirm) install=(pacman --noconfirm "${words[@]:2}") ;;
    suse) refresh=(zypper --non-interactive refresh) install=(zypper --non-interactive "${words[@]:2}") ;;
  esac
  log "$d: running: ${refresh[*]} && ${install[*]}"
  xc refresh "${refresh[@]}"
  ((XRC == 0)) || why+=("'${refresh[*]}' failed (exit $XRC): $(tail -n 3 "$XERR" | tr '\n' ' ')")
  if ((${#why[@]} == 0)); then
    xc install "${install[@]}"
    if ((XRC != 0)); then
      why+=("'${install[*]}' failed (exit $XRC): $(cat "$XERR" "$XOUT" | grep -v '^$' | tail -n 4 | tr '\n' ' ')")
    fi
  fi
  if ((${#why[@]} == 0)); then
    src_call recheck check_runtime_libs
    ((XRC == 0)) || why+=("after the install check_runtime_libs exits $XRC: $(short "$XERR")")
    grep -q '^hint:' "$XERR" "$XOUT" && why+=("after the install it still prints a hint")
    left=$(missing_libs | tr '\n' ' ')
    [[ -z $left ]] || why+=("still missing per ldconfig -p: $left")
    owner_report "$d"
  fi
  if ((${#why[@]})); then
    result FAIL "install_$d" "$(printf '%s; ' "${why[@]}" | sed 's/; $//')"
  else
    result PASS "install_$d"
  fi
}

phase_app() { # distro
  local d=$1 why=() nf first
  if [[ -z $APP ]]; then
    result SKIP "app_$d" "no built app folder (use --app-dir or APP_DIR)"
    return
  fi
  if [[ ${STATUS[install_$d]:-} != PASS ]]; then
    result FAIL "app_$d" "needs install_$d to pass first (it did not)"
    return
  fi
  xc copy cp -a "$IN_APP" /root/aseprite
  if ((XRC != 0)); then
    result FAIL "app_$d" "could not copy the app in the container: $(short "$XERR")"
    return
  fi
  xc ldd ldd /root/aseprite/aseprite
  nf=$(grep -i 'not found' "$XOUT" "$XERR" | sed 's/^[^:]*://' | tr -s ' \t' ' ' | tr '\n' ';')
  ((XRC == 0)) || why+=("ldd exited $XRC")
  [[ -z $nf ]] || why+=("ldd: $nf")
  xc version env -u DISPLAY -u WAYLAND_DISPLAY HOME=/root /root/aseprite/aseprite --version
  first=$(head -n 1 "$XOUT")
  log "$d: aseprite --version: ${first:-<nothing>} (exit $XRC)"
  ((XRC == 0)) || why+=("--version exited $XRC: $(short "$XERR")")
  [[ $first == "Aseprite $EXPECTED" ]] || why+=("--version printed '$first', expected 'Aseprite $EXPECTED'")
  if ((${#why[@]})); then
    result FAIL "app_$d" "$(printf '%s; ' "${why[@]}" | sed 's/; $//')"
  else
    result PASS "app_$d"
  fi
}

run_glibc_distro() { # distro
  local d=$1 t any=0 need_hint=0 need_install=0
  for t in platform hint install app; do [[ -n ${SEL[${t}_$d]:-} ]] && any=1; done
  ((any)) || return 0
  [[ -n ${SEL[hint_$d]:-} ]] && need_hint=1
  [[ -n ${SEL[install_$d]:-} ]] && need_hint=1 need_install=1
  if [[ -n ${SEL[app_$d]:-} ]]; then
    if [[ -n $APP ]]; then
      need_hint=1 need_install=1
    elif ((need_hint == 0)) && [[ -z ${SEL[platform_$d]:-} ]]; then
      result SKIP "app_$d" "no built app folder (use --app-dir or APP_DIR)"
      return 0
    fi
  fi
  log "=== $d (${IMAGE[$d]})"
  if ! start_container "$d"; then
    for t in platform hint install app; do
      [[ -n ${SEL[${t}_$d]:-} ]] && result FAIL "${t}_$d" "could not pull or start ${IMAGE[$d]}"
    done
    stop_container
    return 0
  fi
  [[ -n ${SEL[platform_$d]:-} ]] && phase_platform "$d"
  ((need_hint)) && phase_hint "$d"
  ((need_install)) && phase_install "$d"
  if [[ -n ${SEL[app_$d]:-} ]]; then phase_app "$d"; fi
  stop_container
}

run_glibc_check() { # test distro version-to-mention
  local t=$1 d=$2 err_line why=()
  [[ -n ${SEL[$t]:-} ]] || return 0
  log "=== $d (${IMAGE[$d]})"
  if ! start_container "$d"; then
    result FAIL "$t" "could not pull or start ${IMAGE[$d]}"
    stop_container
    return 0
  fi
  log "$d: getconf GNU_LIBC_VERSION -> $(docker exec "$C" getconf GNU_LIBC_VERSION 2>&1)"
  src_call platform check_platform
  stop_container
  if not_defined check_platform; then
    result FAIL "$t" "check_platform is not defined in install-aseprite.sh"
    return 0
  fi
  err_line=$(grep '^error:' "$XERR" | head -n 1)
  log "$d: check_platform exit $XRC: ${err_line:-<no error: line>}"
  ((XRC == 1)) || why+=("exit $XRC, expected 1")
  [[ -n $err_line ]] || why+=("no 'error:' line on stderr")
  grep -qi 'glibc' <<<"$err_line" || why+=("the error line does not mention glibc")
  if [[ -n $3 ]]; then
    grep -qF "$3" <<<"$err_line" || why+=("the error line does not name the glibc found ($3)")
  fi
  if ((${#why[@]})); then
    result FAIL "$t" "$(printf '%s; ' "${why[@]}" | sed 's/; $//')"
  else
    result PASS "$t"
  fi
}

# ---------------------------------------------------------------- app and main

find_app() {
  local a=${APP_DIR_ARG:-${APP_DIR:-}}
  if [[ -z $a ]]; then
    if [[ -d $HOME/.local/opt/aseprite ]]; then
      a=$HOME/.local/opt/aseprite
    else
      a=$REPO/.test/e2e/prefix/opt/aseprite
    fi
  fi
  if [[ -x $a/aseprite ]]; then
    APP=$(cd -- "$a" && pwd -P)
  else
    APP=''
    log "no built app at $a: the app_* tests will SKIP"
    return 0
  fi
  if [[ -f $APP/.aseprite-installer/state ]]; then
    EXPECTED=$(sed -n 's/^version=//p' "$APP/.aseprite-installer/state" | head -n 1)
  fi
  [[ -z $EXPECTED ]] && EXPECTED=${PORT_EXPECTED_VERSION:-}
  if [[ -z $EXPECTED ]]; then
    local home=$OUTDIR/home
    mkdir -p -- "$home/tmp"
    EXPECTED=$(timeout 60 env -u DISPLAY -u WAYLAND_DISPLAY HOME="$home" XDG_CONFIG_HOME="$home/.config" \
      ASEPRITE_USER_FOLDER="$home/aseprite-user" TMPDIR="$home/tmp" \
      "$APP/aseprite" --version 2>/dev/null </dev/null | head -n 1)
    EXPECTED=${EXPECTED#Aseprite }
  fi
  log "app: $APP (expected --version: Aseprite ${EXPECTED:-?})"
}

usage() {
  echo "usage: tests/portability.sh [--list] [--app-dir DIR] [test-or-distro...]"
  echo "distros: ${GLIBC_DISTROS[*]} debian12 alpine"
}

main() {
  local want=() t arg d
  while (($#)); do
    arg=$1
    shift
    case $arg in
      --list)
        for t in "${TESTS[@]}"; do printf '%-22s %s\n' "$t" "${DESC[$t]}"; done
        return 0
        ;;
      --app-dir)
        (($#)) || { usage >&2; return 2; }
        APP_DIR_ARG=$1
        shift
        ;;
      --app-dir=*) APP_DIR_ARG=${arg#--app-dir=} ;;
      -h | --help) usage; return 0 ;;
      -*) usage >&2; return 2 ;;
      *)
        if [[ -n ${DESC[$arg]+x} ]]; then
          want+=("$arg")
        elif [[ -n ${IMAGE[$arg]+x} ]]; then
          for t in "${TESTS[@]}"; do [[ $t == *_"$arg" ]] && want+=("$t"); done
        else
          echo "unknown test or distro: $arg" >&2
          usage >&2
          return 2
        fi
        ;;
    esac
  done
  ((${#want[@]})) || want=("${TESTS[@]}")
  for t in "${want[@]}"; do SEL[$t]=1; done

  if [[ ! -f $SCRIPT ]]; then
    echo "FAIL setup: $SCRIPT not found"
    return 1
  fi
  if ! docker info >/dev/null 2>&1; then
    echo "FAIL setup: docker is not usable by this user"
    return 1
  fi
  mkdir -p -- "$OUTDIR"
  trap cleanup EXIT
  trap 'log interrupted; exit 130' INT TERM
  log "portability: ${#want[@]} test(s); logs in $OUTDIR"
  find_app

  for d in "${GLIBC_DISTROS[@]}"; do run_glibc_distro "$d"; done
  run_glibc_check glibc_old_debian12 debian12 2.36
  run_glibc_check glibc_none_alpine alpine ''

  echo "portability: $PASSED passed, $FAILED failed, $SKIPPED skipped"
  ((FAILED == 0))
}

main "$@"
