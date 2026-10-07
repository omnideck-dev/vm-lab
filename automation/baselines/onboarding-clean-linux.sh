#!/usr/bin/env bash

set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$script_dir/configure-firefox-desktop.sh"

# Baselines may be derived from older installer checkpoints. Normalize the
# disposable tester credential here so every profile has the same known PAM
# password, independent of the age of its source checkpoint.
usermod --password '$6$SRTdHbBlz5uKrH7M$bIpFx8CSO1te/doj.Tk445gUl7SzvU8./gnsmJHIpd9U/9850k/QNRQYtS8pvn8/N061rjBi9xvBnp1UAUHBJ.' tester

. /etc/os-release
if command -v podman >/dev/null 2>&1 && [[ "${VARIANT_ID:-}" != silverblue ]]; then
  sudo -u tester podman system reset --force >/dev/null 2>&1 || true
  case "$ID" in
    debian|ubuntu) DEBIAN_FRONTEND=noninteractive apt-get remove -y podman ;;
    fedora) dnf -y remove podman ;;
    *) printf 'No scripted Podman removal is defined for %s.\n' "$ID" >&2; exit 1 ;;
  esac
  hash -r
  command -v podman >/dev/null 2>&1 && {
    printf 'Podman remained installed after onboarding baseline cleanup.\n' >&2
    exit 1
  }
fi
# Historical checkpoints may retain setup state and saved CLI instances even
# after Podman is removed. This recipe runs only in the disposable tester VM.
# Certification separately checks these paths without modifying them.
python3 "$script_dir/linux-app-state.py" clean

test ! -e /opt/omnideck
test ! -e /usr/local/bin/omnideck
install -d -m 0755 /var/lib/omnideck-lab
printf 'onboarding-clean-v1\n' > /var/lib/omnideck-lab/baseline-contract
