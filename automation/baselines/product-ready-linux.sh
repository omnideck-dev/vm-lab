#!/usr/bin/env bash

set -Eeuo pipefail

# Keep the fixed disposable credential deterministic even when this profile is
# rebuilt from a historical onboarding checkpoint.
usermod --password '$6$SRTdHbBlz5uKrH7M$bIpFx8CSO1te/doj.Tk445gUl7SzvU8./gnsmJHIpd9U/9850k/QNRQYtS8pvn8/N061rjBi9xvBnp1UAUHBJ.' tester

. /etc/os-release
if ! command -v podman >/dev/null 2>&1; then
  case "$ID" in
    debian|ubuntu)
      apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        podman uidmap slirp4netns fuse-overlayfs passt
      rm -rf /var/lib/apt/lists/*
      ;;
    fedora)
      dnf -y --setopt=install_weak_deps=False install \
        podman fuse-overlayfs slirp4netns shadow-utils-subid
      dnf clean all
      ;;
    *)
      printf 'No scripted Podman installation is defined for %s.\n' "$ID" >&2
      exit 1
      ;;
  esac
fi

sudo -u tester podman info >/dev/null
test ! -e /opt/omnideck
test ! -e /usr/local/bin/omnideck
install -d -m 0755 /var/lib/omnideck-lab
printf 'product-ready-v2\n' > /var/lib/omnideck-lab/baseline-contract
