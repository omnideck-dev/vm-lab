#!/usr/bin/env bash

set -Eeuo pipefail
export LANG=C
export LC_ALL=C

[[ "$(uname -s)/$(uname -m)" == Darwin/arm64 ]] || exit 2
script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
source_file="$script_dir/OmnideckLabDriver.m"
application="$HOME/Applications/Omnideck Lab Driver.app"
executable="$application/Contents/MacOS/omnideck-lab-driver"
source_digest="$(shasum -a 256 "$source_file" | awk '{print $1}')"
digest_file="$application/Contents/Resources/source.sha256"

if [[ -x "$executable" && -f "$digest_file" && "$(<"$digest_file")" == "$source_digest" ]]; then
  printf 'Accessibility driver already current: %s\n' "$application"
  exit 0
fi

temporary="$(mktemp -d /private/tmp/omnideck-lab-driver.XXXXXX)"
trap 'rm -rf -- "$temporary"' EXIT
mkdir -p "$temporary/Omnideck Lab Driver.app/Contents/MacOS" "$temporary/Omnideck Lab Driver.app/Contents/Resources"
/usr/bin/clang -O2 -fobjc-arc -framework AppKit -framework ApplicationServices \
  -o "$temporary/Omnideck Lab Driver.app/Contents/MacOS/omnideck-lab-driver" "$source_file"
cat > "$temporary/Omnideck Lab Driver.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>omnideck-lab-driver</string>
  <key>CFBundleIdentifier</key><string>dev.omnideck.lab-driver</string>
  <key>CFBundleName</key><string>Omnideck Lab Driver</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSBackgroundOnly</key><true/>
</dict></plist>
PLIST
printf '%s\n' "$source_digest" > "$temporary/Omnideck Lab Driver.app/Contents/Resources/source.sha256"
/usr/bin/codesign --force --sign - "$temporary/Omnideck Lab Driver.app"
rm -rf -- "$application"
/usr/bin/ditto "$temporary/Omnideck Lab Driver.app" "$application"
printf 'Installed stable Accessibility driver: %s\n' "$application"
