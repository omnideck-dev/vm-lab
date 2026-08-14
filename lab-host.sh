#!/usr/bin/env bash

set -Eeuo pipefail

LAB_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
HOST_CONFIG_DIR="$LAB_ROOT/hosts"

usage() {
  cat <<'EOF'
Usage: ./lab-host.sh COMMAND HOST [ARGS...]

Commands:
  status HOST              Probe SSH and report platform readiness
  verify HOST              Verify macOS, ARM64, Node, and Podman readiness
  reset HOST BASELINE      Restore the disposable application-clean baseline
  ssh HOST                 Open an interactive shell
  run HOST COMMAND...      Run a noninteractive command
  copy-to HOST SRC DEST    Copy one local file or directory to the host
  copy-from HOST SRC DEST  Copy one host file or directory locally
EOF
}

resolve_host() {
  local requested="${1:?HOST is required}"
  case "$requested" in
    macos|macos-arm64) HOST=macos-arm64 ;;
    *) printf 'Unknown physical host: %s\n' "$requested" >&2; exit 2 ;;
  esac

  HOST_CONFIG="$HOST_CONFIG_DIR/${HOST}.json"
  [[ -f "$HOST_CONFIG" ]] || {
    printf 'Physical host %s is not configured: %s\n' "$HOST" "$HOST_CONFIG" >&2
    exit 3
  }

  eval "$(python3 - "$HOST_CONFIG" <<'PY'
import json, shlex, sys

with open(sys.argv[1]) as handle:
    config = json.load(handle)
assert config.get("schemaVersion") == 1
target = config["sshTarget"]
remote_path = config.get("path", "/usr/bin:/bin:/usr/sbin:/sbin")
assert target and not any(character.isspace() for character in target)
assert remote_path and "\n" not in remote_path
print(f"SSH_TARGET={shlex.quote(target)}")
print(f"REMOTE_PATH={shlex.quote(remote_path)}")
PY
)"
}

ssh_base() {
  SSH_ARGS=(-o BatchMode=yes -o ConnectTimeout=8)
}

remote_script() {
  local script="${1:?SCRIPT is required}"
  ssh_base
  ssh "${SSH_ARGS[@]}" "$SSH_TARGET" "/usr/bin/env LANG=C LC_ALL=C PATH=$(printf '%q' "$REMOTE_PATH") /bin/zsh -c $(printf '%q' "$script")"
}

status_one() {
  local requested="${1:?HOST is required}" probe
  if ! resolve_host "$requested" 2>/dev/null; then
    case "$requested" in macos|macos-arm64) printf 'macos-arm64 unconfigured\n'; return 0 ;; esac
    return 2
  fi
  if ! probe="$(remote_script '
locked=false
/usr/sbin/ioreg -n Root -d1 | grep -Eq '\''"(CGSSessionScreenIsLocked|IOConsoleLocked)"[[:space:]]*=[[:space:]]*Yes'\'' && locked=true
printf "%s\t%s\t%s\n" "$(uname -s)" "$(uname -m)" "$locked"
' 2>/dev/null)"; then
    printf '%s unavailable ssh=%s\n' "$HOST" "$SSH_TARGET"
    return 0
  fi
  local os arch locked
  IFS=$'\t' read -r os arch locked <<<"$probe"
  if [[ "$os" == Darwin && "$arch" == arm64 ]]; then
    if [[ "$locked" == true ]]; then
      printf '%s locked ssh=%s os=%s arch=%s reason=gui-session-locked\n' "$HOST" "$SSH_TARGET" "$os" "$arch"
    else
      printf '%s ready ssh=%s os=%s arch=%s\n' "$HOST" "$SSH_TARGET" "$os" "$arch"
    fi
  else
    printf '%s incompatible ssh=%s os=%s arch=%s\n' "$HOST" "$SSH_TARGET" "$os" "$arch"
  fi
}

verify_one() {
  resolve_host "${1:?HOST is required}"
  remote_script '
set -Eeuo pipefail
os="$(uname -s)"
arch="$(uname -m)"
[[ "$os" == Darwin ]] || { printf "Expected Darwin, found %s\n" "$os" >&2; exit 1; }
[[ "$arch" == arm64 ]] || { printf "Expected arm64, found %s\n" "$arch" >&2; exit 1; }
console_user="$(stat -f %Su /dev/console)"
[[ "$console_user" == "$(id -un)" ]] || { printf "The macOS lab user is not signed in at the console.\n" >&2; exit 1; }
if /usr/sbin/ioreg -n Root -d1 | grep -Eq '\''"(CGSSessionScreenIsLocked|IOConsoleLocked)"[[:space:]]*=[[:space:]]*Yes'\''; then
  printf "The macOS lab GUI session is locked; unlock it once before running native UI tests.\n" >&2
  exit 1
fi
command -v node >/dev/null 2>&1 || { printf "Node.js is missing from the configured host PATH.\n" >&2; exit 1; }
command -v podman >/dev/null 2>&1 || { printf "Podman is missing from the configured host PATH.\n" >&2; exit 1; }
podman info >/dev/null
machine="$(podman machine list --format json | jq -r '\''map(select(.Name == "omnideck-runtime" and .Running == true)) | length'\'')"
[[ "$machine" == 1 ]] || { printf "The omnideck-runtime Podman machine is not running.\n" >&2; exit 1; }
registry_config="$(podman machine ssh omnideck-runtime cat /var/home/core/.config/containers/registries.conf.d/omnideck-lab.conf 2>/dev/null || true)"
[[ "$registry_config" == *'\''location = "localhost:46864"'\''* && "$registry_config" == *'\''insecure = true'\''* ]] || {
  printf "The loopback hardware-test registry policy is missing; rerun prepare-host.sh.\n" >&2
  exit 1
}
reset_helper="$HOME/.local/libexec/omnideck-lab/reset-host.sh"
[[ -x "$reset_helper" ]] || { printf "The disposable-host reset helper is missing; rerun prepare-host.sh.\n" >&2; exit 1; }
driver="$HOME/Applications/Omnideck Lab Driver.app/Contents/MacOS/omnideck-lab-driver"
[[ -x "$driver" ]] || { printf "The Accessibility driver is missing; rerun the macOS bootstrap.\n" >&2; exit 1; }
"$reset_helper" verify runtime-ready >/dev/null
printf "host=%s/%s memoryBytes=%s node=%s podman=%s machine=omnideck-runtime-ready accessibilityDriver=installed\n" \
  "$os" "$arch" "$(sysctl -n hw.memsize)" "$(node --version)" "$(podman --version)"
'
}

reset_one() {
  resolve_host "${1:?HOST is required}"
  local baseline="${2:?BASELINE is required}"
  [[ "$baseline" == runtime-ready ]] || { printf 'Unsupported host baseline: %s\n' "$baseline" >&2; exit 2; }
  remote_script '"$HOME/.local/libexec/omnideck-lab/reset-host.sh" reset runtime-ready'
}

run_one() {
  resolve_host "${1:?HOST is required}"
  shift
  (($#)) || { printf 'run requires COMMAND.\n' >&2; exit 2; }
  local command
  printf -v command '%q ' "$@"
  remote_script "$command"
}

ssh_one() {
  resolve_host "${1:?HOST is required}"
  ssh_base
  exec ssh "${SSH_ARGS[@]}" "$SSH_TARGET"
}

copy_to_one() {
  resolve_host "${1:?HOST is required}"
  local source="${2:?SRC is required}" destination="${3:?DEST is required}"
  [[ -e "$source" ]] || { printf 'Copy source does not exist: %s\n' "$source" >&2; exit 1; }
  ssh_base
  scp -r "${SSH_ARGS[@]}" -- "$source" "$SSH_TARGET:$destination"
}

copy_from_one() {
  resolve_host "${1:?HOST is required}"
  local source="${2:?SRC is required}" destination="${3:?DEST is required}"
  ssh_base
  scp -r "${SSH_ARGS[@]}" -- "$SSH_TARGET:$source" "$destination"
}

command="${1:-}"
case "$command" in
  status) status_one "${2:?HOST is required}" ;;
  verify) verify_one "${2:?HOST is required}" ;;
  reset) reset_one "${2:?HOST is required}" "${3:?BASELINE is required}" ;;
  ssh) ssh_one "${2:?HOST is required}" ;;
  run) shift; run_one "$@" ;;
  copy-to) copy_to_one "${2:?HOST is required}" "${3:?SRC is required}" "${4:?DEST is required}" ;;
  copy-from) copy_from_one "${2:?HOST is required}" "${3:?SRC is required}" "${4:?DEST is required}" ;;
  --help|-h|help|'') usage ;;
  *) printf 'Unknown host command: %s\n' "$command" >&2; usage >&2; exit 2 ;;
esac
