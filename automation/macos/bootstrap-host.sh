#!/usr/bin/env bash

set -Eeuo pipefail

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
lab_root="$(CDPATH= cd -- "$script_dir/../.." && pwd)"
host="${1:-macos-arm64}"
host_engine="$lab_root/lab-host.sh"
host="$("$lab_root/lab.sh" describe "$host" --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["target"])')"

if [[ "${OMNIDECK_VM_LAB_LEASED:-}" != 1 ]]; then
  run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  exec "$lab_root/lab.sh" lease "$host" macos-bootstrap "$run_id" -- "$0" "$host"
fi

[[ "${OMNIDECK_VM_LAB_VM:-}" == "$host" ]] || {
  printf 'The active lease does not own %s.\n' "$host" >&2
  exit 2
}

[[ -x "$host_engine" ]] || { printf 'Missing physical-host controller: %s\n' "$host_engine" >&2; exit 1; }
for source in prepare-host.sh reset-host.sh allow-downloads.sh install-driver.sh install-input-extension.sh verify-driver.sh OmnideckLabDriver.m OmnideckLabInput.m dev.omnideck.lab-awake.plist; do
  [[ -f "$script_dir/$source" ]] || { printf 'Missing macOS bootstrap input: %s\n' "$script_dir/$source" >&2; exit 1; }
done

remote_root="$($host_engine run "$host" /usr/bin/mktemp -d /private/tmp/omnideck-lab-bootstrap.XXXXXX)"
[[ "$remote_root" == /private/tmp/omnideck-lab-bootstrap.* && "$remote_root" != *$'\n'* ]] || {
  printf 'Mac returned an unsafe bootstrap staging path: %q\n' "$remote_root" >&2
  exit 1
}
cleanup() { "$host_engine" run "$host" /bin/rm -rf -- "$remote_root" >/dev/null 2>&1 || true; }
trap cleanup EXIT

for source in prepare-host.sh reset-host.sh allow-downloads.sh install-driver.sh install-input-extension.sh verify-driver.sh OmnideckLabDriver.m OmnideckLabInput.m dev.omnideck.lab-awake.plist; do
  "$host_engine" copy-to "$host" "$script_dir/$source" "$remote_root/$source"
done
"$host_engine" run "$host" /bin/chmod 755 \
  "$remote_root/prepare-host.sh" "$remote_root/reset-host.sh" "$remote_root/allow-downloads.sh" \
  "$remote_root/install-driver.sh" "$remote_root/install-input-extension.sh" "$remote_root/verify-driver.sh"
"$host_engine" run "$host" /bin/bash "$remote_root/prepare-host.sh"
"$host_engine" verify "$host"

printf 'Bootstrapped and verified physical host: %s\n' "$host"
