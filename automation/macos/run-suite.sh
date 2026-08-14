#!/usr/bin/env bash

set -Eeuo pipefail

lab_root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
cli_repo="${OMNIDECK_CLI_WORKTREE:-}"
desktop_repo="${OMNIDECK_DESKTOP_WORKTREE:-}"
artifact="${OMNIDECK_DESKTOP_MACOS_ARTIFACT:-}"

usage() {
  cat <<'EOF'
Usage: run-suite.sh --cli-repo PATH --desktop-repo PATH --artifact PATH.dmg

Run the complete native Apple Silicon release-test lane: CLI release contract,
ready-runtime first-run and management TUI, unattended CLI lifecycle, packaged
Desktop smoke, Accessibility setup/recovery, Custom App, and native host-boundary
journeys. Podman installation is intentionally excluded; bootstrap-host.sh owns
that one-time host prerequisite.
EOF
}

while (($#)); do
  case "$1" in
    --cli-repo) cli_repo="${2:?--cli-repo requires a path}"; shift 2 ;;
    --desktop-repo) desktop_repo="${2:?--desktop-repo requires a path}"; shift 2 ;;
    --artifact) artifact="${2:?--artifact requires a path}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

for value in "$cli_repo" "$desktop_repo" "$artifact"; do [[ -n "$value" ]] || { usage >&2; exit 2; }; done
cli_repo="$(realpath -e "$cli_repo")"
desktop_repo="$(realpath -e "$desktop_repo")"
artifact="$(realpath -e "$artifact")"
[[ -x "$cli_repo/tests/e2e/run-macos-lab.sh" ]] || { printf 'CLI worktree lacks tests/e2e/run-macos-lab.sh: %s\n' "$cli_repo" >&2; exit 2; }
[[ -x "$desktop_repo/desktop/tests/e2e/run-macos-lab.sh" ]] || { printf 'Desktop worktree lacks the macOS E2E runner: %s\n' "$desktop_repo" >&2; exit 2; }
[[ -f "$artifact" && "$artifact" == *.dmg ]] || { printf 'Desktop artifact must be an existing DMG.\n' >&2; exit 2; }

export OMNIDECK_VM_LAB_DIR="${OMNIDECK_VM_LAB_DIR:-$lab_root}"
[[ "$(realpath -e "$OMNIDECK_VM_LAB_DIR")" == "$lab_root" ]] || {
  printf 'run-suite.sh must execute from the deployed lab selected by OMNIDECK_VM_LAB_DIR.\n' >&2
  exit 2
}

run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
output_dir="$("$lab_root/lab.sh" artifact-path macos aggregate "$run_id")"
mkdir -p "$output_dir"
started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
current=cli-tui
status=failed
cli_commit="$(git -C "$cli_repo" rev-parse HEAD)"
desktop_commit="$(git -C "$desktop_repo" rev-parse HEAD)"
"$lab_root/lab.sh" evidence-init "$output_dir" macos aggregate "$run_id" \
  "${cli_commit:0:12}+${desktop_commit:0:12}" macos-arm64 runtime-ready \
  "cliCommit=$cli_commit" "desktopCommit=$desktop_commit" \
  "podmanSetup=excluded-ready-runtime" "desktopArtifact=$artifact"

finish() {
  local exit_code=$?
  set +e
  python3 - "$output_dir/summary.json" "$status" "$current" "$started_at" "$artifact" <<'PY'
import datetime, hashlib, json, sys
path, status, last, started, artifact = sys.argv[1:]
with open(artifact, 'rb') as stream: digest=hashlib.sha256(stream.read()).hexdigest()
with open(path, 'w', encoding='utf-8') as stream:
    json.dump({'schemaVersion':1,'status':status,'lastLane':last,'target':'macos-arm64','podmanSetup':'excluded-ready-runtime','desktopArtifact':artifact,'desktopArtifactSha256':digest,'startedAt':started,'finishedAt':datetime.datetime.now(datetime.timezone.utc).isoformat().replace('+00:00','Z')}, stream, indent=2)
    stream.write('\n')
PY
  "$lab_root/lab.sh" evidence-finish "$output_dir" "$status" >/dev/null 2>&1 || true
  exit "$exit_code"
}
trap finish EXIT

"$cli_repo/tests/e2e/run-macos-lab.sh" 2>&1 | tee "$output_dir/cli-tui.log"
current=desktop
"$desktop_repo/desktop/tests/e2e/run-macos-lab.sh" --artifact "$artifact" 2>&1 | tee "$output_dir/desktop.log"
current=complete
status=passed
printf 'PASS: complete macOS ARM64 CLI/TUI and Desktop suite.\nEvidence: %s\n' "$output_dir"
