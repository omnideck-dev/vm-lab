#!/usr/bin/env bash

set -Eeuo pipefail

export LANG=C
export LC_ALL=C

application_name="${1:?Application name is required}"
timeout="${2:-15}"
case "$application_name" in
  ''|*$'\n'*|*$'\r'*)
    printf 'Application name must be one non-empty line.\n' >&2
    exit 2
    ;;
esac
[[ "$timeout" =~ ^[0-9]+([.][0-9]+)?$ ]] || {
  printf 'Timeout must be a non-negative number of seconds.\n' >&2
  exit 2
}

driver="${OMNIDECK_LAB_DRIVER:-$HOME/Applications/Omnideck Lab Driver.app/Contents/MacOS/omnideck-lab-driver}"
notification_center="${OMNIDECK_LAB_NOTIFICATION_CENTER:-/System/Library/CoreServices/UserNotificationCenter.app/Contents/MacOS/UserNotificationCenter}"
[[ -x "$driver" ]] || { printf 'Accessibility driver is unavailable: %s\n' "$driver" >&2; exit 1; }
[[ -x "$notification_center" ]] || {
  printf 'UserNotificationCenter is unavailable: %s\n' "$notification_center" >&2
  exit 1
}

prompt="“${application_name}” would like to access files in your Downloads folder."
if ! "$driver" wait-text "$notification_center" "$prompt" "$timeout" >/dev/null 2>&1; then
  printf 'downloadsPermission=not-requested app=%q\n' "$application_name"
  exit 0
fi

# Re-check the exact privacy text immediately before pressing the alert's
# button. Never click an unqualified system-wide Allow control.
"$driver" wait-text "$notification_center" "$prompt" 1 >/dev/null
"$driver" click "$notification_center" Allow 2 >/dev/null
printf 'downloadsPermission=granted app=%q\n' "$application_name"
