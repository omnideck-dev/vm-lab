#!/usr/bin/env bash

set -Eeuo pipefail

[[ "$(uname -s)/$(uname -m)" == Darwin/arm64 ]] || exit 2
script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
source_file="$script_dir/OmnideckLabInput.m"
install_root="$HOME/.omnideck-lab/input"
library="$install_root/omnideck-lab-input.dylib"
digest_file="$install_root/source.sha256"
source_digest="$(shasum -a 256 "$source_file" | awk '{print $1}')"

if [[ -f "$library" && -f "$digest_file" && "$(<"$digest_file")" == "$source_digest" ]]; then
  printf 'Trusted-input extension already current: %s\n' "$library"
  exit 0
fi

temporary="$(mktemp -d /private/tmp/omnideck-lab-input.XXXXXX)"
trap 'rm -rf -- "$temporary"' EXIT
/usr/bin/clang -O2 -fobjc-arc -dynamiclib -framework AppKit -framework ApplicationServices \
  -o "$temporary/omnideck-lab-input.dylib" "$source_file"
/usr/bin/codesign --force --sign - "$temporary/omnideck-lab-input.dylib"
mkdir -p "$install_root"
/usr/bin/ditto "$temporary/omnideck-lab-input.dylib" "$library"
printf '%s\n' "$source_digest" > "$digest_file"
printf 'Installed trusted-input extension without changing the Accessibility helper: %s\n' "$library"
