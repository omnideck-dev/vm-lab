#!/usr/bin/env bash

set -Eeuo pipefail

source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
cleanup() { rm -rf -- "$test_root"; }
trap cleanup EXIT

cp "$source_dir/lab.sh" "$test_root/lab.sh"
cp "$source_dir/VERSION" "$test_root/VERSION"
cp "$source_dir/lab-manifest.json" "$test_root/lab-manifest.json"
chmod +x "$test_root/lab.sh"
mkdir -p "$test_root"/{artifacts,base-images,discarded,disks,golden,keys,logs,runtime}

cp "$source_dir/tests/fake-engine.sh" "$test_root/lab-engine.sh"
chmod +x "$test_root/lab-engine.sh"

"$test_root/lab.sh" describe ubuntu --json | python3 -c 'import json,sys; assert json.load(sys.stdin)["vm"] == "appimage"'
"$test_root/lab.sh" baseline ubuntu desktop | grep -Fxq desktop-e2e-v2
"$test_root/lab.sh" profile release-clean ubuntu | grep -Fxq clean
"$test_root/lab.sh" capabilities --json | python3 -c 'import json,sys; assert "artifact-path" in json.load(sys.stdin)["features"]'
"$test_root/lab.sh" artifact-path cli e2e test-run | grep -Fxq "$test_root/artifacts/cli/e2e/test-run"
"$test_root/lab.sh" cache-path cli builder-test | grep -Fxq "$test_root/cache/cli/builder-test"
mkdir -p "$test_root/golden/manifests"
python3 - "$test_root/lab-manifest.json" "$test_root/golden/manifests/appimage-desktop-e2e-v2.json" <<'PY'
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
for path, baseline in ((sys.argv[2], "desktop-e2e-v2"), (sys.argv[2].replace("desktop-e2e-v2", "clean"), "clean")):
    record["baseline"] = baseline
    with open(path, "w") as handle:
        json.dump(record, handle)
PY
"$test_root/lab.sh" preflight desktop dev-fast --lanes appimage --json |
  python3 -c 'import json,sys; assert json.load(sys.stdin)["ready"] is True'
"$test_root/lab.sh" preflight cli release-clean --lanes appimage --json |
  python3 -c 'import json,sys; assert json.load(sys.stdin)["ready"] is True'
if "$test_root/lab.sh" start ubuntu >/dev/null 2>&1; then
  printf 'unleased mutation unexpectedly succeeded\n' >&2
  exit 1
fi
"$test_root/lab.sh" lease ubuntu test successful -- bash -c 'test "$OMNIDECK_VM_LAB_VM" = appimage'
[[ ! -e "$test_root/discarded/runs/successful-appimage" ]]
if "$test_root/lab.sh" lease debian test failed -- bash -c 'exit 9'; then
  printf 'failing leased command unexpectedly succeeded\n' >&2
  exit 1
fi
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
"$test_root/lab.sh" status --json | python3 -c 'import json,sys; assert len(json.load(sys.stdin)) == 5'
mkdir -p "$test_root/cache/cli/expired"
touch -d '10 days ago' "$test_root/cache/cli/expired"
"$test_root/lab.sh" cleanup --apply --cache-retention-hours 1 >/dev/null
[[ ! -e "$test_root/cache/cli/expired" ]]
printf 'lab controller tests passed\n'
