#!/usr/bin/env bash

set -Eeuo pipefail

# Linux SSH clients commonly forward C.UTF-8, which macOS does not provide and
# which makes its Perl-backed shasum abort before checking the download.
export LANG=C
export LC_ALL=C

[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || {
  printf 'This bootstrap supports only native Apple Silicon macOS hosts.\n' >&2
  exit 2
}

local_bin="$HOME/.local/bin"
local_opt="$HOME/.local/opt"
local_libexec="$HOME/.local/libexec/omnideck-lab"
mkdir -p "$local_bin" "$local_opt"

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
reset_source="$script_dir/reset-host.sh"
downloads_permission_source="$script_dir/allow-downloads.sh"
driver_installer="$script_dir/install-driver.sh"
input_installer="$script_dir/install-input-extension.sh"
driver_verifier="$script_dir/verify-driver.sh"
awake_source="$script_dir/dev.omnideck.lab-awake.plist"
[[ -f "$reset_source" ]] || {
  printf 'Missing reset helper beside prepare-host.sh: %s\n' "$reset_source" >&2
  exit 1
}
[[ -x "$downloads_permission_source" ]] || {
  printf 'Missing Downloads permission helper beside prepare-host.sh: %s\n' "$downloads_permission_source" >&2
  exit 1
}
[[ -x "$driver_installer" && -x "$input_installer" && -x "$driver_verifier" && \
   -f "$script_dir/OmnideckLabDriver.m" && -f "$script_dir/OmnideckLabInput.m" && -f "$awake_source" ]] || {
  printf 'Missing macOS lab driver sources beside prepare-host.sh.\n' >&2
  exit 1
}
mkdir -p "$local_libexec"
install -m 0755 "$reset_source" "$local_libexec/reset-host.sh"
install -m 0755 "$downloads_permission_source" "$local_libexec/allow-downloads.sh"
"$driver_installer"
"$input_installer"

launch_agents="$HOME/Library/LaunchAgents"
awake_agent="$launch_agents/dev.omnideck.lab-awake.plist"
mkdir -p "$launch_agents"
install -m 0644 "$awake_source" "$awake_agent"
launch_domain="gui/$(id -u)"
/bin/launchctl bootout "$launch_domain/dev.omnideck.lab-awake" >/dev/null 2>&1 || true
/bin/launchctl bootstrap "$launch_domain" "$awake_agent"
/bin/launchctl enable "$launch_domain/dev.omnideck.lab-awake"
/bin/launchctl kickstart "$launch_domain/dev.omnideck.lab-awake"

node_series="${OMNIDECK_LAB_NODE_SERIES:-24}"
distribution_url="https://nodejs.org/dist/latest-v${node_series}.x"
temporary="$(mktemp -d "${TMPDIR:-/tmp}/omnideck-macos-host.XXXXXX")"
cleanup() { rm -rf -- "$temporary"; }
trap cleanup EXIT

curl --fail --location --silent --show-error \
  "$distribution_url/SHASUMS256.txt" --output "$temporary/SHASUMS256.txt"
archive="$(awk '/node-v[0-9.]+-darwin-arm64\.tar\.gz$/ {print $2; exit}' "$temporary/SHASUMS256.txt")"
[[ -n "$archive" ]] || { printf 'Node.js ARM64 archive was not listed by %s.\n' "$distribution_url" >&2; exit 1; }
node_version="${archive#node-}"
node_version="${node_version%-darwin-arm64.tar.gz}"
versioned_node="$local_opt/node-$node_version"
if [[ ! -d "$versioned_node" ]]; then
  curl --fail --location --silent --show-error \
    "$distribution_url/$archive" --output "$temporary/$archive"
  (
    cd "$temporary"
    grep -F "  $archive" SHASUMS256.txt | shasum -a 256 --check
  )
  tar -xzf "$temporary/$archive" -C "$temporary"
  mv -- "$temporary/${archive%.tar.gz}" "$versioned_node"
fi

current_link="$local_opt/node-v${node_series}"
if [[ -e "$current_link" && ! -L "$current_link" ]]; then
  printf 'Refusing to replace non-symlink Node path: %s\n' "$current_link" >&2
  exit 1
fi
ln -sfn "node-$node_version" "$current_link"
for executable in node npm npx corepack; do
  [[ -x "$current_link/bin/$executable" ]] || continue
  destination="$local_bin/$executable"
  if [[ -e "$destination" && ! -L "$destination" ]]; then
    printf 'Refusing to replace non-symlink executable: %s\n' "$destination" >&2
    exit 1
  fi
  ln -sfn "$current_link/bin/$executable" "$destination"
done

profile="$HOME/.zprofile"
touch "$profile"
path_line='export PATH="$HOME/.local/bin:/opt/podman/bin:$PATH"'
if ! grep -Fqx "$path_line" "$profile"; then
  printf '\n# OmniDeck native test host\n%s\n' "$path_line" >> "$profile"
fi

export PATH="$local_bin:/opt/podman/bin:$PATH"
command -v podman >/dev/null 2>&1 || {
  printf 'Podman is not installed. Launch omnideck once and approve its supported runtime setup.\n' >&2
  exit 1
}
podman info >/dev/null || {
  printf 'Podman is installed but not ready. Launch omnideck and complete setup first.\n' >&2
  exit 1
}
[[ "$(podman machine list --format json | jq -r 'map(select(.Name == "omnideck-runtime" and .Running == true)) | length')" == 1 ]] || {
  printf 'The omnideck-runtime Podman machine is not running.\n' >&2
  exit 1
}


# The CLI hardware lane uses one fixed loopback-only registry port. Podman's
# macOS client talks to a long-running service inside the VM, so that service
# must see the setting at machine startup; per-command host config is too late.
registry_port="${OMNIDECK_LAB_REGISTRY_PORT:-46864}"
[[ "$registry_port" =~ ^[0-9]+$ ]] && ((registry_port >= 1024 && registry_port <= 65535)) || {
  printf 'OMNIDECK_LAB_REGISTRY_PORT must be a number from 1024 through 65535.\n' >&2
  exit 2
}
registry_config="/var/home/core/.config/containers/registries.conf.d/omnideck-lab.conf"
desired_registry_config="$(printf '[[registry]]\nlocation = "localhost:%s"\ninsecure = true\n' "$registry_port")"
current_registry_config="$(podman machine ssh omnideck-runtime cat "$registry_config" 2>/dev/null || true)"
if [[ "$current_registry_config" != "$desired_registry_config" ]]; then
  podman machine ssh omnideck-runtime mkdir -p /var/home/core/.config/containers/registries.conf.d
  printf '%s\n' "$desired_registry_config" |
    podman machine ssh omnideck-runtime tee "$registry_config" >/dev/null
  printf 'Restarting omnideck-runtime once to activate the loopback test registry policy.\n'
  podman machine stop omnideck-runtime
  podman machine start omnideck-runtime
  podman info >/dev/null
fi

printf 'macOS ARM64 host ready: node=%s podman=%s registry=localhost:%s\n' \
  "$(node --version)" "$(podman --version)" "$registry_port"
driver="$HOME/Applications/Omnideck Lab Driver.app/Contents/MacOS/omnideck-lab-driver"
if ! "$driver_verifier"; then
  "$driver" preflight --prompt >/dev/null 2>&1 || true
  printf '%s\n' \
    'Desktop E2E permissions are not granted yet.' \
    'On the Mac, add "Omnideck Lab Driver" to Privacy & Security > Accessibility and Screen & System Audio Recording.'
fi
