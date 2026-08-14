#!/usr/bin/env bash

set -Eeuo pipefail

root="$(cd "$(dirname "$0")" && pwd)"
command="${1:-}"
host="${2:-}"

case "$command" in
  status)
    if [[ -f "$root/hosts/${host}.json" ]]; then
      printf '%s ready ssh=fake-mac os=Darwin arch=arm64\n' "$host"
    else
      printf '%s unconfigured\n' "$host"
    fi
    ;;
  verify) printf 'host=Darwin/arm64 memoryBytes=8589934592 node=v24.0.0 podman=podman-version machine=omnideck-runtime-ready\n' ;;
  reset) printf 'reset %s %s\n' "$host" "${3:-}" >> "$root/runtime/fake-actions.log" ;;
  run) shift 2; "$@" ;;
  copy-to|copy-from) cp -R -- "$3" "$4" ;;
  ssh) exit 0 ;;
  *) printf 'unsupported fake host command: %s\n' "$command" >&2; exit 2 ;;
esac
