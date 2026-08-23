#!/usr/bin/env bash

set -Eeuo pipefail

if ! command -v firefox >/dev/null 2>&1 && command -v firefox-esr >/dev/null 2>&1; then
  ln -s "$(command -v firefox-esr)" /usr/local/bin/firefox
fi
firefox_bin="$(command -v firefox || true)"
[[ -n "$firefox_bin" ]] || {
  printf 'Firefox is missing from the guest image.\n' >&2
  exit 1
}

desktop_entry=/var/lib/snapd/desktop/applications/firefox_firefox.desktop
install -d -m 0755 "$(dirname "$desktop_entry")"
if [[ ! -e "$desktop_entry" ]]; then
  cat > "$desktop_entry" <<EOF
[Desktop Entry]
Name=Firefox
Comment=Web Browser
Exec=${firefox_bin} %u
Terminal=false
Type=Application
MimeType=x-scheme-handler/http;x-scheme-handler/https;text/html;
Categories=Network;WebBrowser;
StartupNotify=true
EOF
fi
if [[ -w /usr/share/applications ]]; then
  install -m 0644 "$desktop_entry" /usr/share/applications/firefox_firefox.desktop
  if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database /usr/share/applications || true
  fi
fi

install -d -o tester -g tester /home/tester/.config
cat > /home/tester/.config/mimeapps.list <<'EOF'
[Default Applications]
x-scheme-handler/http=firefox_firefox.desktop
x-scheme-handler/https=firefox_firefox.desktop
text/html=firefox_firefox.desktop
EOF
chown tester:tester /home/tester/.config/mimeapps.list
