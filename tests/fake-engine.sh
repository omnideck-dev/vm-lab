#!/usr/bin/env bash

set -euo pipefail

case "$1" in
  status)
    case "$2" in
      appimage|ubuntu) echo 'appimage stopped ssh=2221 spice=5931' ;;
      deb|debian) echo 'deb stopped ssh=2222 spice=5932' ;;
      rpm|fedora) echo 'rpm stopped ssh=2223 spice=5933' ;;
      atomic|silverblue) echo 'atomic stopped ssh=2224 spice=5934' ;;
      windows) echo 'windows stopped ssh=2225 spice=5935' ;;
    esac
    ;;
  snapshots) printf 'appimage snapshots:\nclean\ndesktop-e2e-v2\npodman-ready\n' ;;
  *) printf 'engine %s\n' "$*" ;;
esac
