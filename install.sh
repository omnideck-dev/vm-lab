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

mkdir -p "$target/docs" "$target/runtime/leases" "$target/discarded/runs" "$target/cache" \
  "$target/cloud-init" "$target/automation/windows" "$target/automation/macos" "$target/automation/baselines" "$target/hosts"
install -m 0755 "$source_dir/lab-engine.sh" "$target/.lab-engine.sh.new"
install -m 0755 "$source_dir/lab-host.sh" "$target/.lab-host.sh.new"
install -m 0755 "$source_dir/lab.sh" "$target/.lab.sh.new"
mv -- "$target/.lab-engine.sh.new" "$target/lab-engine.sh"
mv -- "$target/.lab-host.sh.new" "$target/lab-host.sh"
mv -- "$target/.lab.sh.new" "$target/lab.sh"
install -m 0644 "$source_dir/README.md" "$target/README.md"
install -m 0644 "$source_dir/CHANGELOG.md" "$target/CHANGELOG.md"
install -m 0644 "$source_dir/lab-manifest.json" "$target/lab-manifest.json"
install -m 0644 "$source_dir/VERSION" "$target/VERSION"
for document in "$source_dir"/docs/*.md; do
  install -m 0644 "$document" "$target/docs/$(basename "$document")"
done
for user_data in "$source_dir"/cloud-init/*.yaml; do
  install -m 0644 "$user_data" "$target/cloud-init/$(basename "$user_data")"
done
install -m 0644 "$source_dir/automation/atomic.ks" "$target/automation/atomic.ks"
install -m 0755 "$source_dir/automation/configure-firefox-desktop.sh" "$target/automation/configure-firefox-desktop.sh"
install -m 0755 "$source_dir/automation/baselines/onboarding-clean-linux.sh" "$target/automation/baselines/onboarding-clean-linux.sh"
install -m 0755 "$source_dir/automation/baselines/product-ready-linux.sh" "$target/automation/baselines/product-ready-linux.sh"
install -m 0644 "$source_dir/automation/windows/Autounattend.xml" "$target/automation/windows/Autounattend.xml"
install -m 0644 "$source_dir/automation/windows/provision.ps1" "$target/automation/windows/provision.ps1"
install -m 0755 "$source_dir/automation/macos/prepare-host.sh" "$target/automation/macos/prepare-host.sh"
install -m 0755 "$source_dir/automation/macos/reset-host.sh" "$target/automation/macos/reset-host.sh"
install -m 0755 "$source_dir/automation/macos/allow-downloads.sh" "$target/automation/macos/allow-downloads.sh"
install -m 0755 "$source_dir/automation/macos/run-suite.sh" "$target/automation/macos/run-suite.sh"
install -m 0755 "$source_dir/automation/macos/install-driver.sh" "$target/automation/macos/install-driver.sh"
install -m 0755 "$source_dir/automation/macos/install-input-extension.sh" "$target/automation/macos/install-input-extension.sh"
install -m 0755 "$source_dir/automation/macos/verify-driver.sh" "$target/automation/macos/verify-driver.sh"
install -m 0755 "$source_dir/automation/macos/bootstrap-host.sh" "$target/automation/macos/bootstrap-host.sh"
install -m 0644 "$source_dir/automation/macos/OmnideckLabDriver.m" "$target/automation/macos/OmnideckLabDriver.m"
install -m 0644 "$source_dir/automation/macos/OmnideckLabInput.m" "$target/automation/macos/OmnideckLabInput.m"
install -m 0644 "$source_dir/automation/macos/dev.omnideck.lab-awake.plist" "$target/automation/macos/dev.omnideck.lab-awake.plist"
install -m 0644 "$source_dir/hosts/macos-arm64.example.json" "$target/hosts/macos-arm64.example.json"
source_commit="$(git -C "$source_dir" rev-parse --verify HEAD 2>/dev/null || printf unknown)"
source_dirty=false
[[ -z "$(git -C "$source_dir" status --porcelain=v1 --untracked-files=normal 2>/dev/null)" ]] || source_dirty=true
python3 - "$target/controller-install.json" "$($target/lab.sh --version | awk '{print $2}')" "$source_commit" "$source_dirty" <<'PY'
import datetime, hashlib, json, os, sys, tempfile
path, version, commit, dirty = sys.argv[1:]
root = os.path.dirname(path)
installed = [
    "VERSION", "lab.sh", "lab-engine.sh", "lab-host.sh", "lab-manifest.json",
    "automation/macos/prepare-host.sh", "automation/macos/reset-host.sh",
    "automation/macos/allow-downloads.sh",
    "automation/macos/run-suite.sh",
    "automation/macos/bootstrap-host.sh", "automation/macos/install-driver.sh",
    "automation/macos/install-input-extension.sh",
    "automation/macos/verify-driver.sh",
    "automation/macos/OmnideckLabDriver.m", "automation/macos/OmnideckLabInput.m",
    "automation/macos/dev.omnideck.lab-awake.plist",
    "hosts/macos-arm64.example.json",
    "automation/atomic.ks", "automation/configure-firefox-desktop.sh",
    "automation/baselines/onboarding-clean-linux.sh",
    "automation/baselines/product-ready-linux.sh",
    "automation/windows/Autounattend.xml",
    "automation/windows/provision.ps1", "cloud-init/appimage-user-data.yaml",
    "cloud-init/deb-user-data.yaml", "cloud-init/rpm-user-data.yaml",
]
record = {
    "schemaVersion": 1,
    "version": version,
    "sourceCommit": commit,
    "sourceDirty": dirty == "true",
    "installedAt": datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z"),
    "installedFilesSha256": {
        relative: hashlib.sha256(open(os.path.join(root, relative), "rb").read()).hexdigest()
        for relative in installed
    },
}
fd, temporary = tempfile.mkstemp(prefix=".controller-install.", dir=os.path.dirname(path), text=True)
with os.fdopen(fd, "w") as handle:
    json.dump(record, handle, indent=2, sort_keys=True)
    handle.write("\n")
os.replace(temporary, path)
PY
printf 'Installed OmniDeck VM lab controller %s into %s\n' "$($target/lab.sh --version | awk '{print $2}')" "$target"
