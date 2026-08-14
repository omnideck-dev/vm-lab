#!/usr/bin/env bash

set -Eeuo pipefail

export LANG=C
export LC_ALL=C

action="${1:-inventory}"
baseline="${2:-runtime-ready}"
[[ "$baseline" == runtime-ready ]] || {
  printf 'Unsupported macOS host baseline: %s\n' "$baseline" >&2
  exit 2
}
[[ "$(uname -s)/$(uname -m)" == Darwin/arm64 ]] || {
  printf 'The disposable host reset supports only Apple Silicon macOS.\n' >&2
  exit 2
}

managed_root="$HOME/.omnideck-lab"
cli_path="$managed_root/bin/omnideck"
cli_marker="$managed_root/managed-cli.sha256"
application="$HOME/Applications/Omnideck Lab.app"
bundle_identifier=dev.omnideck.desktop
cli_e2e_marker="$managed_root/state/cli-e2e-instance"

state_paths=(
  "$HOME/Library/Application Support/omnideck-release-testing"
  "$HOME/Library/Caches/omnideck-release-testing"
  "$managed_root/state"
  "$managed_root/config"
  "$managed_root/downloads"
)

find_podman() {
  local candidate
  for candidate in /opt/podman/bin/podman /opt/homebrew/bin/podman /usr/local/bin/podman; do
    [[ -x "$candidate" ]] && { printf '%s\n' "$candidate"; return 0; }
  done
  return 1
}

is_owned_container() {
  case "$1" in
    omnideck-hw-*|omnideck-desktop-release-test-*) return 0 ;;
  esac
  if [[ -f "$cli_e2e_marker" && "$1" == "$(tr -d '[:space:]' < "$cli_e2e_marker")" && "$1" =~ ^omnideck[0-9]*$ ]]; then
    return 0
  fi
  return 1
}

is_owned_volume() {
  case "$1" in
    omnideck-hw-*-home|omnideck-hw-*-state|omnideck-desktop-home-release-test-*|omnideck-desktop-state-release-test-*) return 0 ;;
  esac
  if [[ -f "$cli_e2e_marker" ]]; then
    local marked
    marked="$(tr -d '[:space:]' < "$cli_e2e_marker")"
    if [[ "$marked" =~ ^omnideck[0-9]*$ && ( "$1" == "$marked-home" || "$1" == "$marked-state" ) ]]; then return 0; fi
  fi
  return 1
}

list_owned_resources() {
  local podman name
  podman="$(find_podman || true)"
  [[ -n "$podman" ]] || return 0
  while IFS= read -r name; do
    if [[ -n "$name" ]] && is_owned_container "$name"; then printf 'container\t%s\n' "$name"; fi
  done < <("$podman" ps --all --format '{{.Names}}' 2>/dev/null || true)
  while IFS= read -r name; do
    if [[ -n "$name" ]] && is_owned_volume "$name"; then printf 'volume\t%s\n' "$name"; fi
  done < <("$podman" volume ls --format '{{.Name}}' 2>/dev/null || true)
  return 0
}

application_is_owned() {
  [[ -d "$application" ]] || return 1
  [[ "$(defaults read "$application/Contents/Info" CFBundleIdentifier 2>/dev/null || true)" == "$bundle_identifier" ]]
}

inventory() {
  local path
  if [[ -e "$application" ]]; then
    if application_is_owned; then printf 'application\tREMOVE\t%s\n' "$application"; else printf 'application\tREFUSE\t%s\n' "$application"; fi
  fi
  if [[ -e "$cli_path" || -L "$cli_path" ]]; then
    if [[ -f "$cli_marker" ]] && shasum -a 256 --check "$cli_marker" >/dev/null 2>&1; then
      printf 'cli\tREMOVE\t%s\n' "$cli_path"
    else
      printf 'cli\tREFUSE\t%s\n' "$cli_path"
    fi
  fi
  for path in "${state_paths[@]}"; do [[ -e "$path" ]] && printf 'state\tREMOVE\t%s\n' "$path"; done
  list_owned_resources | while IFS=$'\t' read -r kind name; do printf '%s\tREMOVE\t%s\n' "$kind" "$name"; done
  find /private/tmp -mindepth 1 -maxdepth 1 -type d \
    \( -name 'omnideck-cli-macos-*' -o -name 'omnideck-desktop-macos-*' -o -name 'omnideck-dmg.*' \) \
    -print 2>/dev/null | while IFS= read -r path; do printf 'staging\tREMOVE\t%s\n' "$path"; done
}

verify_clean() {
  local path residue
  [[ ! -e "$application" ]] || { printf 'Managed application remains: %s\n' "$application" >&2; return 1; }
  if [[ -f "$cli_marker" || -e "$cli_path" || -L "$cli_path" ]]; then
    printf 'Managed CLI or marker remains: %s\n' "$cli_path" >&2
    return 1
  fi
  for path in "${state_paths[@]}"; do
    [[ ! -e "$path" ]] || { printf 'Managed state remains: %s\n' "$path" >&2; return 1; }
  done
  residue="$(list_owned_resources)"
  [[ -z "$residue" ]] || { printf 'Managed Podman resources remain:\n%s\n' "$residue" >&2; return 1; }
  find_podman >/dev/null || { printf 'Podman is not installed.\n' >&2; return 1; }
  "$(find_podman)" info >/dev/null || { printf 'Podman is not ready.\n' >&2; return 1; }
  printf 'macOS host baseline verified: %s\n' "$baseline"
}

reset_host() {
  local path podman name
  if [[ -e "$application" ]] && ! application_is_owned; then
    printf 'Refusing to remove an unexpected application at %s.\n' "$application" >&2
    exit 1
  fi
  if [[ -e "$cli_path" || -L "$cli_path" ]]; then
    [[ -f "$cli_marker" ]] && shasum -a 256 --check "$cli_marker" >/dev/null 2>&1 || {
      printf 'Refusing to remove an unmarked or changed CLI: %s\n' "$cli_path" >&2
      exit 1
    }
  fi

  if [[ -x "$application/Contents/MacOS/omnideck" ]]; then
    pkill -f "^$application/Contents/MacOS/omnideck$" >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5; do
      pgrep -f "^$application/Contents/MacOS/omnideck$" >/dev/null 2>&1 || break
      sleep 1
    done
    if pgrep -f "^$application/Contents/MacOS/omnideck$" >/dev/null 2>&1; then
      pkill -KILL -f "^$application/Contents/MacOS/omnideck$" >/dev/null 2>&1 || true
    fi
  fi
  pkill -f '^/private/tmp/omnideck-cli-macos-[[:alnum:]_.-]*/bin/omnideck([[:space:]]|$)' >/dev/null 2>&1 || true
  pkill -f '^/tmp/omnideck-cli-macos-[[:alnum:]_.-]*/bin/omnideck([[:space:]]|$)' >/dev/null 2>&1 || true

  podman="$(find_podman || true)"
  if [[ -n "$podman" ]]; then
    while IFS= read -r name; do
      if [[ -n "$name" ]] && is_owned_container "$name"; then "$podman" rm --force --volumes "$name" >/dev/null; fi
    done < <("$podman" ps --all --format '{{.Names}}' 2>/dev/null || true)
    while IFS= read -r name; do
      if [[ -n "$name" ]] && is_owned_volume "$name"; then "$podman" volume rm --force "$name" >/dev/null; fi
    done < <("$podman" volume ls --format '{{.Name}}' 2>/dev/null || true)
  fi

  [[ ! -e "$application" ]] || rm -rf -- "$application"
  if [[ -e "$cli_path" || -L "$cli_path" ]]; then rm -f -- "$cli_path"; fi
  rm -f -- "$cli_marker"
  for path in "${state_paths[@]}"; do [[ ! -e "$path" ]] || rm -rf -- "$path"; done
  find /private/tmp -mindepth 1 -maxdepth 1 -type d \
    \( -name 'omnideck-cli-macos-*' -o -name 'omnideck-desktop-macos-*' -o -name 'omnideck-dmg.*' \) \
    -exec rm -rf -- {} +
  verify_clean
}

case "$action" in
  inventory) inventory ;;
  verify) verify_clean ;;
  reset) reset_host ;;
  *) printf 'Usage: %s inventory|verify|reset [runtime-ready]\n' "$0" >&2; exit 2 ;;
esac
