#!/usr/bin/env bash

set -Eeuo pipefail
export LANG=C
export LC_ALL=C

[[ "$(uname -s)/$(uname -m)" == Darwin/arm64 ]] || exit 2
application="$HOME/Applications/Omnideck Lab Driver.app"
driver="$application/Contents/MacOS/omnideck-lab-driver"
input_extension="$HOME/.omnideck-lab/input/omnideck-lab-input.dylib"
target_application="/System/Applications/System Settings.app"
target_executable="$target_application/Contents/MacOS/System Settings"

[[ -x "$driver" ]] || { printf 'Accessibility driver is not installed: %s\n' "$application" >&2; exit 1; }
[[ -f "$input_extension" ]] || { printf 'Trusted-input extension is not installed: %s\n' "$input_extension" >&2; exit 1; }

preflight="$("$driver" preflight 2>&1 || true)"
[[ "$preflight" == *'accessibility=true'* ]] || {
  printf '%s\n' "$preflight" >&2
  printf 'Grant Omnideck Lab Driver access in Privacy & Security > Accessibility.\n' >&2
  exit 3
}

temporary="$(mktemp -d /private/tmp/omnideck-lab-driver-check.XXXXXX)"
target_was_running=false
pgrep -f "^$target_executable$" >/dev/null 2>&1 && target_was_running=true
cleanup() {
  if [[ "$target_was_running" == false ]]; then pkill -f "^$target_executable$" >/dev/null 2>&1 || true; fi
  rm -rf -- "$temporary"
}
trap cleanup EXIT

/usr/bin/open -g -a "$target_application"
"$driver" wait "$target_executable" 10 >/dev/null
# Screen Recording is granted to the app bundle. Launch Services must start the
# helper for this check; invoking its Mach-O directly through ssh has the ssh
# process's capture context and returns a false negative on macOS 15.
/usr/bin/open -n -a "$application" --args screenshot "$target_executable" "$temporary"
capture=''
for _ in 1 2 3 4 5 6 7 8 9 10; do
  capture="$(find "$temporary" -maxdepth 1 -type f -name 'window-*.png' -size +0c -print -quit)"
  [[ -z "$capture" ]] || break
  sleep 0.2
done
[[ -n "$capture" ]] || {
  printf 'Grant Omnideck Lab Driver access in Privacy & Security > Screen & System Audio Recording.\n' >&2
  exit 3
}

printf 'Desktop driver permissions verified: accessibility=true screenRecording=true\n'
