#!/usr/bin/env bash

set -Eeuo pipefail

source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
cleanup() { rm -rf -- "$test_root"; }
trap cleanup EXIT

cp "$source_dir/lab.sh" "$test_root/lab.sh"
cp "$source_dir/lab-host.sh" "$test_root/lab-host.sh"
cp "$source_dir/VERSION" "$test_root/VERSION"
cp "$source_dir/lab-manifest.json" "$test_root/lab-manifest.json"
chmod +x "$test_root/lab.sh"
mkdir -p "$test_root"/{artifacts,base-images,discarded,disks,golden,hosts,keys,logs,runtime}

cp "$source_dir/tests/fake-engine.sh" "$test_root/lab-engine.sh"
cp "$source_dir/tests/fake-host.sh" "$test_root/lab-host.sh"
chmod +x "$test_root/lab-engine.sh"
chmod +x "$test_root/lab-host.sh"
cp "$source_dir/hosts/macos-arm64.example.json" "$test_root/hosts/macos-arm64.json"

"$test_root/lab.sh" describe ubuntu --json | python3 -c 'import json,sys; assert json.load(sys.stdin)["vm"] == "appimage"'
"$test_root/lab.sh" baseline ubuntu desktop | grep -Fxq product-ready-v2
"$test_root/lab.sh" profile release-clean ubuntu | grep -Fxq onboarding-clean-v1
"$test_root/lab.sh" describe macos --json | python3 -c 'import json,sys; data=json.load(sys.stdin); assert data["kind"] == "host" and data["architecture"] == "arm64"'
"$test_root/lab.sh" profile onboarding-clean macos | grep -Fxq ready
touch "$test_root/runtime/fake-host-locked"
"$test_root/lab.sh" status macos --json | python3 -c 'import json,sys; assert json.load(sys.stdin)["state"] == "locked"'
rm "$test_root/runtime/fake-host-locked"
"$test_root/lab.sh" capabilities --json | python3 -c 'import json,sys; features=json.load(sys.stdin)["features"]; assert "artifact-path" in features and "stage-v1" in features and "golden-browser-contract" in features'
"$test_root/lab.sh" artifact-path cli e2e test-run | grep -Fxq "$test_root/artifacts/cli/e2e/test-run"
"$test_root/lab.sh" cache-path cli builder-test | grep -Fxq "$test_root/cache/cli/builder-test"
mkdir -p "$test_root/golden/manifests"
python3 - "$test_root/lab-manifest.json" "$test_root/golden/manifests/appimage-product-ready-v2.json" <<'PY'
import hashlib, json, sys
with open(sys.argv[1], "rb") as handle:
    config_sha = hashlib.sha256(handle.read()).hexdigest()
record = {
        "schemaVersion": 1,
        "vm": "appimage",
        "labManifestSha256": config_sha,
        "diskSha256": "a" * 64,
        "uefiVarsSha256": "b" * 64,
        "tpmTreeSha256": "none",
        "qemuImage": {},
}
for path, baseline, contract in (
    (sys.argv[2], "product-ready-v2", "product-ready"),
    (sys.argv[2].replace("product-ready-v2", "onboarding-clean-v1"), "onboarding-clean-v1", "onboarding-clean"),
):
    record["baseline"] = baseline
    with open(path, "w") as handle:
        json.dump(record, handle)
    with open(path.replace(".json", ".certification.json"), "w") as handle:
        json.dump({
            "schemaVersion": 2,
            "contractRevision": 2,
            "vm": "appimage",
            "baseline": baseline,
            "contract": contract,
            "provenanceDiskSha256": record["diskSha256"],
        }, handle)
PY
"$test_root/lab.sh" preflight desktop product-ready --lanes appimage --json |
  python3 -c 'import json,sys; assert json.load(sys.stdin)["ready"] is True'
"$test_root/lab.sh" preflight cli onboarding-clean --lanes appimage --json |
  python3 -c 'import json,sys; assert json.load(sys.stdin)["ready"] is True'
python3 - "$test_root/lab-manifest.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as handle:
    manifest = json.load(handle)
manifest["profiles"]["dev-fast"]["deb"] = "desktop-e2e-v4"
with open(path, "w") as handle:
    json.dump(manifest, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
"$test_root/lab.sh" preflight desktop product-ready --lanes appimage --json |
  python3 -c 'import json,sys; assert json.load(sys.stdin)["ready"] is True'
python3 - "$test_root/lab-manifest.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as handle:
    manifest = json.load(handle)
manifest["vms"]["appimage"]["memoryMiB"] += 1
with open(path, "w") as handle:
    json.dump(manifest, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
"$test_root/lab.sh" preflight cli onboarding-clean --lanes appimage --json |
  python3 -c 'import json,sys; assert json.load(sys.stdin)["ready"] is True'
python3 - "$test_root/golden/manifests/appimage-onboarding-clean-v1.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as handle:
    record = json.load(handle)
record["diskSha256"] = "not-a-digest"
with open(path, "w") as handle:
    json.dump(record, handle)
PY
if malformed_fingerprint_result="$("$test_root/lab.sh" preflight cli onboarding-clean --lanes appimage --json)"; then
  printf 'Malformed baseline fingerprint unexpectedly passed preflight\n' >&2
  exit 1
fi
python3 -c 'import json,sys; assert json.load(sys.stdin)["ready"] is False' <<<"$malformed_fingerprint_result"
"$test_root/lab.sh" preflight cli onboarding-clean --lanes macos-arm64 --json |
  python3 -c 'import json,sys; assert json.load(sys.stdin)["ready"] is True'
if "$test_root/lab.sh" start ubuntu >/dev/null 2>&1; then
  printf 'unleased mutation unexpectedly succeeded\n' >&2
  exit 1
fi
"$test_root/lab.sh" lease ubuntu test successful -- bash -c 'test "$OMNIDECK_VM_LAB_VM" = appimage'
[[ ! -e "$test_root/discarded/runs/successful-appimage" ]]
"$test_root/lab.sh" lease ubuntu test no-lock-leak -- bash -c 'test ! -e /proc/$$/fd/9'
"$test_root/lab.sh" lease ubuntu test successful-cleanup --cleanup-baseline clean -- true
grep -Fxq 'reset appimage clean' "$test_root/runtime/fake-actions.log"
[[ ! -e "$test_root/discarded/runs/successful-cleanup-appimage" ]]
stage_source="$test_root/stage-source"
mkdir -p "$stage_source/nested"
printf 'payload\n' > "$stage_source/nested/file.txt"
first_stage="$("$test_root/lab.sh" lease ubuntu test stage-one -- "$test_root/lab.sh" stage ubuntu "$stage_source" /tmp/omnideck-stage-test)"
second_stage="$("$test_root/lab.sh" lease ubuntu test stage-two -- "$test_root/lab.sh" stage ubuntu "$stage_source" /tmp/omnideck-stage-test)"
[[ "$first_stage" == "$second_stage" ]]
grep -Fq 'copy-to appimage' "$test_root/runtime/fake-actions.log"
"$test_root/lab.sh" lease macos test host-successful -- "$test_root/lab.sh" run macos true
[[ ! -e "$test_root/discarded/runs/host-successful-macos-arm64" ]]
if "$test_root/lab.sh" lease macos test host-cleanup-failed --cleanup-baseline runtime-ready -- bash -c 'exit 7'; then
  printf 'failing physical-host lease unexpectedly succeeded\n' >&2
  exit 1
fi
grep -Fxq 'reset macos-arm64 runtime-ready' "$test_root/runtime/fake-actions.log"
if "$test_root/lab.sh" lease debian test failed --cleanup-baseline clean -- bash -c 'exit 9'; then
  printf 'failing leased command unexpectedly succeeded\n' >&2
  exit 1
fi
grep -Fxq 'reset deb clean' "$test_root/runtime/fake-actions.log"
[[ -f "$test_root/discarded/runs/failed-deb/metadata.json" ]]

"$test_root/lab.sh" lease fedora test held -- bash -c 'sleep 2' &
held_pid=$!
for _ in $(seq 1 20); do
  [[ -f "$test_root/runtime/leases/rpm.json" ]] && break
  sleep 0.05
done
if "$test_root/lab.sh" lease fedora test collision -- true >/dev/null 2>&1; then
  printf 'concurrent lease unexpectedly succeeded\n' >&2
  exit 1
fi
# A physical-host lease may finish while an unrelated VM lane is active. The
# routine GC refusal must not replace the successful host command's status.
"$test_root/lab.sh" lease macos test concurrent-host -- true
wait "$held_pid"

if "$test_root/lab.sh" lease ubuntu test interrupted --cleanup-baseline clean -- bash -c 'kill -TERM "$PPID"; sleep 0.1'; then
  printf 'interrupted lease unexpectedly succeeded\n' >&2
  exit 1
fi
grep -Fxq 'reset appimage clean' "$test_root/runtime/fake-actions.log"
python3 - "$test_root/discarded/runs/interrupted-appimage/metadata.json" <<'PY'
import json, sys
with open(sys.argv[1]) as handle:
    record = json.load(handle)
assert record["status"] == "failed", record
PY

run_dir="$test_root/artifacts/cli/e2e/test-run"
"$test_root/lab.sh" evidence-init "$run_dir" cli e2e test-run abc123 ubuntu clean expectedVersion=test
"$test_root/lab.sh" evidence-finish "$run_dir" passed
python3 - "$run_dir/run.json" <<'PY'
import json, sys
with open(sys.argv[1]) as handle:
    run = json.load(handle)
assert run["schemaVersion"] == 1
assert run["distro"] == "ubuntu"
assert run["status"] == "passed"
PY

"$test_root/lab.sh" gc --dry-run --all-evidence >/dev/null
"$test_root/lab.sh" gc --apply --all-evidence >/dev/null
[[ -z "$(find "$test_root/artifacts" -mindepth 1 -print -quit)" ]]
[[ -z "$(find "$test_root/discarded" -mindepth 1 -print -quit)" ]]
"$test_root/lab.sh" status --json | python3 -c 'import json,sys; data=json.load(sys.stdin); assert len(data) == 6; assert data[-1]["state"] == "ready"'
mkdir -p "$test_root/cache/cli/expired"
touch -d '10 days ago' "$test_root/cache/cli/expired"
"$test_root/lab.sh" cleanup --apply --cache-retention-hours 1 >/dev/null
[[ ! -e "$test_root/cache/cli/expired" ]]

permission_test_root="$test_root/downloads-permission"
mkdir -p "$permission_test_root"
permission_driver="$permission_test_root/driver"
permission_notification="$permission_test_root/UserNotificationCenter"
permission_log="$permission_test_root/driver.log"
cat > "$permission_driver" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >> "${OMNIDECK_LAB_DRIVER_LOG:?}"
case "${1:-}" in
  wait-text)
    [[ "${2:-}" == "$OMNIDECK_LAB_NOTIFICATION_CENTER" ]]
    [[ "${3:-}" == '“Omnideck Lab” would like to access files in your Downloads folder.' ]]
    [[ "${OMNIDECK_LAB_FAKE_PROMPT:-1}" == 1 ]]
    ;;
  click)
    [[ "${2:-}" == "$OMNIDECK_LAB_NOTIFICATION_CENTER" ]]
    [[ "${3:-}" == Allow ]]
    ;;
  *) exit 2 ;;
esac
SH
touch "$permission_notification"
chmod 755 "$permission_driver" "$permission_notification"
permission_result="$(
  OMNIDECK_LAB_DRIVER="$permission_driver" \
  OMNIDECK_LAB_DRIVER_LOG="$permission_log" \
  OMNIDECK_LAB_NOTIFICATION_CENTER="$permission_notification" \
    "$source_dir/automation/macos/allow-downloads.sh" 'Omnideck Lab' 2
)"
grep -Fq 'downloadsPermission=granted' <<<"$permission_result"
[[ "$(wc -l < "$permission_log" | tr -d '[:space:]')" == 3 ]]
: > "$permission_log"
permission_result="$(
  OMNIDECK_LAB_DRIVER="$permission_driver" \
  OMNIDECK_LAB_DRIVER_LOG="$permission_log" \
  OMNIDECK_LAB_NOTIFICATION_CENTER="$permission_notification" \
  OMNIDECK_LAB_FAKE_PROMPT=0 \
    "$source_dir/automation/macos/allow-downloads.sh" 'Omnideck Lab' 0
)"
grep -Fq 'downloadsPermission=not-requested' <<<"$permission_result"
[[ "$(wc -l < "$permission_log" | tr -d '[:space:]')" == 1 ]]
if OMNIDECK_LAB_DRIVER="$permission_driver" \
   OMNIDECK_LAB_DRIVER_LOG="$permission_log" \
   OMNIDECK_LAB_NOTIFICATION_CENTER="$permission_notification" \
   "$source_dir/automation/macos/allow-downloads.sh" $'Omnideck Lab\nAllow everything' 1 >/dev/null 2>&1; then
  printf 'Downloads permission helper accepted an unsafe application name\n' >&2
  exit 1
fi

install_root="$(mktemp -d)"
mkdir -p "$install_root"/{base-images,disks,golden}
"$source_dir/install.sh" "$install_root" >/dev/null
[[ -x "$install_root/automation/macos/bootstrap-host.sh" ]]
[[ -x "$install_root/automation/baselines/onboarding-clean-linux.sh" ]]
[[ -x "$install_root/automation/baselines/product-ready-linux.sh" ]]
grep -Fq "usermod --password '\$6\$SRTdHbBlz5uKrH7M\$" "$install_root/automation/baselines/onboarding-clean-linux.sh"
grep -Fq "usermod --password '\$6\$SRTdHbBlz5uKrH7M\$" "$install_root/automation/baselines/product-ready-linux.sh"
grep -Fq 'actual_password_hash=' "$install_root/lab.sh"
[[ -x "$install_root/automation/macos/prepare-host.sh" ]]
[[ -x "$install_root/automation/macos/run-suite.sh" ]]
[[ -x "$install_root/automation/macos/reset-host.sh" ]]
[[ -x "$install_root/automation/macos/allow-downloads.sh" ]]
[[ -x "$install_root/automation/macos/verify-driver.sh" ]]
[[ -x "$install_root/automation/macos/install-input-extension.sh" ]]
[[ -f "$install_root/automation/macos/OmnideckLabDriver.m" ]]
[[ -f "$install_root/automation/macos/OmnideckLabInput.m" ]]
[[ -f "$install_root/automation/macos/dev.omnideck.lab-awake.plist" ]]
grep -Fq 'lease "$host" macos-bootstrap' "$install_root/automation/macos/bootstrap-host.sh"
grep -Fq 'Using newest cached Desktop DMG' "$install_root/automation/macos/run-suite.sh"
grep -Fq "'lanes':{'cli':cli_status,'desktop':desktop_status}" "$install_root/automation/macos/run-suite.sh"
grep -Fq 'for desktop_executable in omnideck-desktop omnideck' "$install_root/automation/macos/reset-host.sh"
python3 - "$install_root/controller-install.json" <<'PY'
import json, sys
with open(sys.argv[1]) as handle:
    record = json.load(handle)
assert "automation/macos/bootstrap-host.sh" in record["installedFilesSha256"]
assert "automation/macos/run-suite.sh" in record["installedFilesSha256"]
assert "automation/macos/reset-host.sh" in record["installedFilesSha256"]
assert "automation/macos/allow-downloads.sh" in record["installedFilesSha256"]
assert "automation/macos/verify-driver.sh" in record["installedFilesSha256"]
assert "automation/macos/install-input-extension.sh" in record["installedFilesSha256"]
assert "automation/macos/OmnideckLabDriver.m" in record["installedFilesSha256"]
assert "automation/macos/OmnideckLabInput.m" in record["installedFilesSha256"]
assert "automation/macos/dev.omnideck.lab-awake.plist" in record["installedFilesSha256"]
assert "automation/baselines/onboarding-clean-linux.sh" in record["installedFilesSha256"]
assert "automation/baselines/product-ready-linux.sh" in record["installedFilesSha256"]
PY
rm -rf -- "$install_root"
printf 'lab controller tests passed\n'
