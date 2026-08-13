#!/usr/bin/env bash

set -Eeuo pipefail

source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
target="${1:-${OMNIDECK_VM_LAB_DIR:-}}"
[[ -n "$target" ]] || { printf 'Usage: %s /absolute/path/to/lab\n' "$0" >&2; exit 2; }
[[ "$target" = /* ]] || { printf 'Lab path must be absolute.\n' >&2; exit 2; }
target="$(realpath -e "$target")"
[[ -d "$target/golden" && -d "$target/disks" && -d "$target/base-images" ]] || {
  printf 'Target does not look like an OmniDeck VM lab: %s\n' "$target" >&2
  exit 2
}

mkdir -p "$target/docs" "$target/runtime/leases" "$target/discarded/runs"
install -m 0755 "$source_dir/lab-engine.sh" "$target/.lab-engine.sh.new"
install -m 0755 "$source_dir/lab.sh" "$target/.lab.sh.new"
mv -- "$target/.lab-engine.sh.new" "$target/lab-engine.sh"
mv -- "$target/.lab.sh.new" "$target/lab.sh"
install -m 0644 "$source_dir/README.md" "$target/README.md"
install -m 0644 "$source_dir/CHANGELOG.md" "$target/CHANGELOG.md"
for document in "$source_dir"/docs/*.md; do
  install -m 0644 "$document" "$target/docs/$(basename "$document")"
done
printf 'Installed OmniDeck VM lab controller %s into %s\n' "$($target/lab.sh --version | awk '{print $2}')" "$target"
