#!/usr/bin/env bash

set -Eeuo pipefail

LAB_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ENGINE="$LAB_ROOT/lab-engine.sh"
HOST_ENGINE="$LAB_ROOT/lab-host.sh"
RUNTIME_DIR="$LAB_ROOT/runtime"
LEASE_DIR="$RUNTIME_DIR/leases"
DISCARDED_DIR="$LAB_ROOT/discarded"
TRANSACTION_ROOT="$DISCARDED_DIR/runs"
ARTIFACT_ROOT="$LAB_ROOT/artifacts"
CACHE_ROOT="$LAB_ROOT/cache"
LOG_DIR="$LAB_ROOT/logs"
MANIFEST="$LAB_ROOT/lab-manifest.json"
LAB_VERSION="$(<"$LAB_ROOT/VERSION")"
DEFAULT_RETENTION_HOURS="${OMNIDECK_VM_LAB_RETENTION_HOURS:-48}"
DEFAULT_CACHE_RETENTION_HOURS="${OMNIDECK_VM_LAB_CACHE_RETENTION_HOURS:-168}"
ALL_VMS=(appimage deb rpm atomic windows)
ALL_HOSTS=(macos-arm64)
ALL_TARGETS=("${ALL_VMS[@]}" "${ALL_HOSTS[@]}")

usage() {
  cat <<'EOF'
Usage: ./lab.sh COMMAND [ARGS...]

Ownership and lifecycle:
  lease TARGET OWNER [RUN_ID] [--keep-state] -- COMMAND...
  status [TARGET] [--verbose|--json]
  describe TARGET [--shell|--json]
  inventory [--json]
  baseline VM cli|desktop
  profile PROFILE VM
  capabilities [--json]
  paths [--shell|--json]
  artifact-path OWNER SUITE RUN_ID
  cache-path OWNER KEY
  preflight SUITE PROFILE [--lanes CSV] [--json]

Guest commands (must run inside `lease`):
  init [VM]              Initialize one or all guests
  start VM               Start an installed guest
  install-atomic         Start the Silverblue installer
  install-windows        Start the Windows installer
  wait|verify VM         Wait for or inspect guest readiness
  ssh VM                 Open an interactive guest shell
  run VM COMMAND...      Run a guest command
  copy-to VM SRC DEST    Copy one file into the guest
  copy-from VM SRC DEST  Copy one file out of the guest
  send-keys VM KEY...    Send QEMU console keys
  screenshot VM DEST     Capture the graphical console
  viewer VM              Open the SPICE viewer
  stop VM                Stop the guest
  reset TARGET [NAME]    Reset a VM overlay or disposable host application state

Physical-host commands (must run inside `lease`):
  reset macos-arm64 runtime-ready
  verify macos-arm64
  ssh macos-arm64
  run macos-arm64 COMMAND...
  copy-to macos-arm64 SRC DEST
  copy-from macos-arm64 SRC DEST

Snapshots and maintenance:
  snapshot VM NAME       Create a named checkpoint; clean replacement is disabled
  snapshots [VM]         List checkpoints
  checkpoint inspect VM NAME
  checkpoint adopt VM NAME
  checkpoint delete VM NAME
  doctor
  doctor [--strict|--deep]
  provenance capture VM [NAME]
  gc [--dry-run|--apply] [--retention-hours N] [--cache-retention-hours N]
     [--all-evidence|--all-generated --yes]
  cleanup [--dry-run|--apply]
  runs list
  runs inspect|pin|unpin|purge PATH [--yes]

Evidence API:
  evidence-init DIR OWNER SUITE RUN_ID COMMIT VM BASELINE [KEY=VALUE...]
  evidence-set DIR KEY=VALUE...
  evidence-finish DIR passed|failed|blocked|canceled

Canonical guests are ubuntu, debian, fedora, silverblue, and windows. Legacy
aliases appimage, deb, rpm, and atomic remain supported.

The physical Apple Silicon lane is macos-arm64 (alias: macos). Its machine-
specific SSH target is configured in hosts/macos-arm64.json.
EOF
}

canonical_vm() {
  case "${1:?VM is required}" in
    appimage|ubuntu) printf 'appimage\n' ;;
    deb|debian) printf 'deb\n' ;;
    rpm|fedora) printf 'rpm\n' ;;
    atomic|silverblue) printf 'atomic\n' ;;
    windows) printf 'windows\n' ;;
    *) printf 'Unknown VM: %s\n' "$1" >&2; return 2 ;;
  esac
}

canonical_target() {
  case "${1:?TARGET is required}" in
    macos|macos-arm64) printf 'macos-arm64\n' ;;
    *) canonical_vm "$1" ;;
  esac
}

target_kind() {
  case "$1" in
    macos-arm64) printf 'host\n' ;;
    *) printf 'vm\n' ;;
  esac
}

distro_name() {
  case "$1" in
    appimage) printf 'ubuntu\n' ;;
    deb) printf 'debian\n' ;;
    rpm) printf 'fedora\n' ;;
    atomic) printf 'silverblue\n' ;;
    windows) printf 'windows\n' ;;
    macos-arm64) printf 'macos\n' ;;
  esac
}

validate_identifier() {
  local label="$1" value="$2"
  [[ "$value" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || {
    printf 'Unsafe %s: %s\n' "$label" "$value" >&2
    return 2
  }
}

ensure_layout() {
  mkdir -p "$LEASE_DIR" "$TRANSACTION_ROOT" "$ARTIFACT_ROOT" "$CACHE_ROOT" "$LOG_DIR"
}

lease_file_for() {
  printf '%s/%s.lock\n' "$LEASE_DIR" "$1"
}

lease_metadata_for() {
  printf '%s/%s.json\n' "$LEASE_DIR" "$1"
}

lease_is_held() {
  local vm="$1" lease_file probe_fd
  lease_file="$(lease_file_for "$vm")"
  exec {probe_fd}>"$lease_file"
  if flock -n "$probe_fd"; then
    flock -u "$probe_fd"
    exec {probe_fd}>&-
    return 1
  fi
  exec {probe_fd}>&-
  return 0
}

require_lease() {
  local vm="$1"
  [[ "${OMNIDECK_VM_LAB_LEASED:-}" == 1 ]] || {
    printf 'Refusing an unleased lab mutation. Use: ./lab.sh lease %s manual -- COMMAND...\n' "$vm" >&2
    exit 2
  }
  [[ "${OMNIDECK_VM_LAB_VM:-}" == "$vm" ]] || {
    printf 'The active lease owns %s, not %s.\n' "${OMNIDECK_VM_LAB_VM:-unknown}" "$vm" >&2
    exit 2
  }
}

require_vm_lease() {
  local vm="$1"
  require_lease "$vm"
  [[ "$(target_kind "$vm")" == vm && -n "${OMNIDECK_VM_LAB_TRANSACTION_DIR:-}" ]] || {
    printf 'The active lease has no transaction directory.\n' >&2
    exit 2
  }
}

write_lease_metadata() {
  local path="$1" vm="$2" owner="$3" run_id="$4" token="$5" kind
  kind="$(target_kind "$vm")"
  shift 5
  python3 - "$path" "$vm" "$(distro_name "$vm")" "$kind" "$owner" "$run_id" "$token" "$$" "$PWD" "$@" <<'PY'
import datetime, json, os, sys, tempfile
path, vm, distro, kind, owner, run_id, token, pid, cwd, *command = sys.argv[1:]
record = {
    "schemaVersion": 1,
    "vm": vm,
    "distro": distro,
    "kind": kind,
    "owner": owner,
    "runId": run_id,
    "token": token,
    "pid": int(pid),
    "cwd": cwd,
    "command": command,
    "startedAt": datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z"),
}
directory = os.path.dirname(path)
fd, temporary = tempfile.mkstemp(prefix=".lease.", dir=directory, text=True)
try:
    with os.fdopen(fd, "w") as handle:
        json.dump(record, handle, indent=2, sort_keys=True)
        handle.write("\n")
    os.replace(temporary, path)
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
PY
}

write_transaction_metadata() {
  local path="$1" vm="$2" owner="$3" run_id="$4" status="$5" expires_at="$6"
  python3 - "$path" "$vm" "$(distro_name "$vm")" "$owner" "$run_id" "$status" "$expires_at" <<'PY'
import datetime, json, os, sys, tempfile
path, vm, distro, owner, run_id, status, expires_at = sys.argv[1:]
record = {}
if os.path.exists(path):
    with open(path) as handle:
        record = json.load(handle)
record.update({
    "schemaVersion": 1,
    "vm": vm,
    "distro": distro,
    "owner": owner,
    "runId": run_id,
    "status": status,
})
now = datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z")
if "startedAt" not in record:
    record["startedAt"] = now
if status != "running":
    record["finishedAt"] = now
    record["expiresAtEpoch"] = int(expires_at)
directory = os.path.dirname(path)
fd, temporary = tempfile.mkstemp(prefix=".transaction.", dir=directory, text=True)
try:
    with os.fdopen(fd, "w") as handle:
        json.dump(record, handle, indent=2, sort_keys=True)
        handle.write("\n")
    os.replace(temporary, path)
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
PY
}

lease_command() {
  local requested_vm="${1:?TARGET is required}" owner="${2:?OWNER is required}"
  shift 2
  local vm kind run_id="" keep_state=0 cleanup_baseline="" lease_signal=""
  vm="$(canonical_target "$requested_vm")"
  kind="$(target_kind "$vm")"
  validate_identifier owner "$owner"
  if [[ "${1:-}" != "--" && "${1:-}" != --* ]]; then
    run_id="$1"
    shift
  fi
  if [[ -z "$run_id" ]]; then
    run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  fi
  validate_identifier run-id "$run_id"
  while [[ "${1:-}" != "--" && -n "${1:-}" ]]; do
    case "$1" in
      --keep-state) keep_state=1; shift ;;
      --cleanup-baseline) cleanup_baseline="${2:?value required}"; validate_identifier cleanup-baseline "$cleanup_baseline"; shift 2 ;;
      *) printf 'Unknown lease option: %s\n' "$1" >&2; exit 2 ;;
    esac
  done
  [[ "${1:-}" == "--" ]] || { printf 'lease requires -- before COMMAND.\n' >&2; exit 2; }
  shift
  (($#)) || { printf 'lease requires COMMAND.\n' >&2; exit 2; }
  if [[ "$kind" == host && "$keep_state" == 1 ]]; then
    printf 'Physical-host leases do not retain state.\n' >&2
    exit 2
  fi
  if [[ "$kind" == host && -n "$cleanup_baseline" && "$cleanup_baseline" != runtime-ready ]]; then
    printf 'Physical-host cleanup baseline must be runtime-ready.\n' >&2
    exit 2
  fi

  ensure_layout
  local lease_file metadata token transaction_dir expires_at result
  lease_file="$(lease_file_for "$vm")"
  metadata="$(lease_metadata_for "$vm")"
  token="${run_id}-${vm}-$$-${RANDOM}"
  transaction_dir="$TRANSACTION_ROOT/${run_id}-${vm}"
  [[ ! -e "$transaction_dir" ]] || { printf 'Transaction already exists: %s\n' "$transaction_dir" >&2; exit 1; }
  exec 9>"$lease_file"
  if ! flock -n 9; then
    printf 'The %s lane is already leased.\n' "$vm" >&2
    [[ -f "$metadata" ]] && cat "$metadata" >&2
    fuser -v "$lease_file" >&2 2>/dev/null || true
    exit 1
  fi
  if [[ "$kind" == vm ]] && "$ENGINE" status "$vm" | grep -Eq "^${vm} running "; then
    printf 'The %s guest is already running; refusing to claim an ambiguous owner.\n' "$vm" >&2
    exit 1
  fi

  if [[ "$kind" == vm ]]; then
    mkdir -p "$transaction_dir/state"
    : > "$transaction_dir/state-index.tsv"
    write_transaction_metadata "$transaction_dir/metadata.json" "$vm" "$owner" "$run_id" running 0
  else
    transaction_dir=""
  fi
  write_lease_metadata "$metadata" "$vm" "$owner" "$run_id" "$token" "$@"
  export OMNIDECK_VM_LAB_LEASED=1
  export OMNIDECK_VM_LAB_VM="$vm"
  export OMNIDECK_VM_LAB_OWNER="$owner"
  export OMNIDECK_VM_LAB_RUN_ID="$run_id"
  export OMNIDECK_VM_LAB_LEASE_TOKEN="$token"
  export OMNIDECK_VM_LAB_TRANSACTION_DIR="$transaction_dir"

  trap 'lease_signal=INT' INT
  trap 'lease_signal=TERM' TERM
  trap 'lease_signal=HUP' HUP
  set +e
  "$@"
  result=$?
  set -e
  trap - INT TERM HUP
  if [[ -n "$lease_signal" && "$result" == 0 ]]; then
    case "$lease_signal" in INT) result=130 ;; TERM) result=143 ;; HUP) result=129 ;; esac
  fi
  if [[ "$kind" == vm && -n "$cleanup_baseline" && "$result" -ge 128 ]]; then
    if "$ENGINE" status "$vm" | grep -Eq "^${vm} running "; then
      "$ENGINE" stop "$vm" || result=1
    fi
    if [[ "$keep_state" == 0 ]]; then
      "$ENGINE" reset "$vm" "$cleanup_baseline" || result=1
    fi
  fi
  if [[ "$kind" == vm ]]; then
    expires_at="$(( $(date +%s) + DEFAULT_RETENTION_HOURS * 3600 ))"
    if [[ "$result" == 0 && "$keep_state" == 0 ]]; then
      rm -rf -- "$transaction_dir"
    else
      if [[ "$result" == 0 ]]; then
        write_transaction_metadata "$transaction_dir/metadata.json" "$vm" "$owner" "$run_id" retained "$expires_at"
      else
        write_transaction_metadata "$transaction_dir/metadata.json" "$vm" "$owner" "$run_id" failed "$expires_at"
      fi
      printf 'Retained transaction state until GC expiry: %s\n' "$transaction_dir" >&2
    fi
  fi
  if [[ "$kind" == host && -n "$cleanup_baseline" ]]; then
    if ! "$HOST_ENGINE" reset "$vm" "$cleanup_baseline"; then result=1; fi
  fi
  if [[ -f "$metadata" ]] && grep -Fq "\"token\": \"$token\"" "$metadata"; then
    unlink "$metadata"
  fi
  flock -u 9
  exec 9>&-
  # The final concurrent lane performs routine retention cleanup. If another
  # lane is still active, GC safely refuses and a later lease completion tries
  # again.
  gc_command --apply >/dev/null 2>&1 || true
  return "$result"
}

describe_vm() {
  local vm format="${2:---shell}" ssh_port spice_port memory disk distro
  vm="$(canonical_vm "$1")"
  distro="$(distro_name "$vm")"
  case "$vm" in
    appimage) ssh_port=2221; spice_port=5931; memory=6144; disk=50 ;;
    deb) ssh_port=2222; spice_port=5932; memory=6144; disk=50 ;;
    rpm) ssh_port=2223; spice_port=5933; memory=6144; disk=50 ;;
    atomic) ssh_port=2224; spice_port=5934; memory=8192; disk=60 ;;
    windows) ssh_port=2225; spice_port=5935; memory=8192; disk=100 ;;
  esac
  case "$format" in
    --shell)
      printf 'LAB_TARGET=%q\n' "$vm"
      printf 'LAB_TARGET_KIND=vm\n'
      printf 'LAB_VM=%q\n' "$vm"
      printf 'LAB_VM_DISTRO=%q\n' "$distro"
      printf 'LAB_VM_SSH_PORT=%q\n' "$ssh_port"
      printf 'LAB_VM_SPICE_PORT=%q\n' "$spice_port"
      printf 'LAB_VM_KEY=%q\n' "$LAB_ROOT/keys/id_ed25519"
      printf 'LAB_VM_KNOWN_HOSTS=%q\n' "$RUNTIME_DIR/known_hosts"
      ;;
    --json)
      printf '{"schemaVersion":1,"vm":"%s","distro":"%s","sshPort":%s,"spicePort":%s,"memoryMiB":%s,"diskGiB":%s}\n' \
        "$vm" "$distro" "$ssh_port" "$spice_port" "$memory" "$disk"
      ;;
    *) printf 'Unknown describe format: %s\n' "$format" >&2; exit 2 ;;
  esac
}

describe_host() {
  local host format="${2:---shell}" config ssh_target="" remote_path="" configured=false
  host="$(canonical_target "$1")"
  [[ "$(target_kind "$host")" == host ]] || { printf 'Not a physical host: %s\n' "$1" >&2; return 2; }
  config="$LAB_ROOT/hosts/${host}.json"
  if [[ -f "$config" ]]; then
    configured=true
    IFS=$'\t' read -r ssh_target remote_path < <(python3 - "$config" <<'PY'
import json, sys
with open(sys.argv[1]) as handle:
    config = json.load(handle)
print(config["sshTarget"], config.get("path", "/usr/bin:/bin:/usr/sbin:/sbin"), sep="\t")
PY
)
  fi
  case "$format" in
    --shell)
      printf 'LAB_TARGET=%q\n' "$host"
      printf 'LAB_TARGET_KIND=host\n'
      printf 'LAB_VM=%q\n' "$host"
      printf 'LAB_VM_DISTRO=macos\n'
      printf 'LAB_HOST_OS=macos\n'
      printf 'LAB_HOST_ARCH=arm64\n'
      printf 'LAB_HOST_CONFIGURED=%q\n' "$configured"
      printf 'LAB_HOST_SSH_TARGET=%q\n' "$ssh_target"
      printf 'LAB_HOST_REMOTE_PATH=%q\n' "$remote_path"
      ;;
    --json)
      python3 - "$host" "$configured" "$ssh_target" "$remote_path" "$config" <<'PY'
import json, sys
host, configured, ssh_target, remote_path, config = sys.argv[1:]
print(json.dumps({
    "schemaVersion": 1,
    "target": host,
    "vm": host,
    "kind": "host",
    "distro": "macos",
    "os": "macos",
    "architecture": "arm64",
    "memoryMiB": 8192,
    "configured": configured == "true",
    "sshTarget": ssh_target or None,
    "remotePath": remote_path or None,
    "configuration": config,
}, sort_keys=True))
PY
      ;;
    *) printf 'Unknown describe format: %s\n' "$format" >&2; exit 2 ;;
  esac
}

describe_target() {
  local target
  target="$(canonical_target "${1:?TARGET is required}")"
  if [[ "$(target_kind "$target")" == host ]]; then
    describe_host "$target" "${2:---shell}"
  else
    describe_vm "$target" "${2:---shell}"
  fi
}

status_host() {
  local host="$1" format="${2:---verbose}" basic metadata lease_file
  host="$(canonical_target "$host")"
  basic="$($HOST_ENGINE status "$host")"
  metadata="$(lease_metadata_for "$host")"
  lease_file="$(lease_file_for "$host")"
  if [[ "$format" == --json ]]; then
    python3 - "$host" "$basic" "$metadata" <<'PY'
import json, os, re, sys
host, basic, metadata = sys.argv[1:]
match = re.match(r"^\S+ (ready|unavailable|unconfigured|incompatible)(?: ssh=(\S+))?(?: os=(\S+) arch=(\S+))?", basic)
record = {
    "schemaVersion": 1,
    "target": host,
    "vm": host,
    "kind": "host",
    "distro": "macos",
    "state": match.group(1) if match else "unknown",
    "sshTarget": match.group(2) if match else None,
    "os": match.group(3) if match else None,
    "architecture": match.group(4) if match else None,
    "lease": None,
}
if os.path.exists(metadata):
    try:
        with open(metadata) as handle:
            record["lease"] = json.load(handle)
    except (OSError, json.JSONDecodeError):
        record["lease"] = {"status": "unreadable"}
print(json.dumps(record, sort_keys=True))
PY
    return
  fi
  printf '%s\n' "$basic"
  if lease_is_held "$host"; then
    if [[ -f "$metadata" ]]; then
      python3 - "$metadata" <<'PY'
import json, sys
with open(sys.argv[1]) as handle:
    lease = json.load(handle)
print("  lease owner={owner} run={runId} pid={pid} cwd={cwd}".format(**lease))
PY
    else
      printf '  lease held; metadata missing (inspect with fuser %s)\n' "$lease_file"
    fi
  elif [[ -f "$metadata" ]]; then
    printf '  stale lease metadata: %s\n' "$metadata"
  fi
}

status_one() {
  local vm="$1" format="${2:---verbose}" basic metadata lease_file
  vm="$(canonical_target "$vm")"
  if [[ "$(target_kind "$vm")" == host ]]; then
    status_host "$vm" "$format"
    return
  fi
  basic="$("$ENGINE" status "$vm")"
  metadata="$(lease_metadata_for "$vm")"
  lease_file="$(lease_file_for "$vm")"
  if [[ "$format" == "--json" ]]; then
    python3 - "$vm" "$(distro_name "$vm")" "$basic" "$metadata" "$lease_file" <<'PY'
import json, os, re, subprocess, sys
vm, distro, basic, metadata, lease_file = sys.argv[1:]
match = re.search(r"^(\w+) (running|stopped)(?: pid=(\d+))? ssh=(\d+) spice=(\d+)$", basic)
record = {
    "schemaVersion": 1,
    "target": vm,
    "vm": vm,
    "kind": "vm",
    "distro": distro,
    "state": match.group(2) if match else "unknown",
    "pid": int(match.group(3)) if match and match.group(3) else None,
    "sshPort": int(match.group(4)) if match else None,
    "spicePort": int(match.group(5)) if match else None,
    "lease": None,
}
if os.path.exists(metadata):
    try:
        with open(metadata) as handle:
            record["lease"] = json.load(handle)
    except (OSError, json.JSONDecodeError):
        record["lease"] = {"status": "unreadable"}
print(json.dumps(record, sort_keys=True))
PY
    return
  fi
  printf '%s\n' "$basic"
  local active_disk allocated backing uptime=""
  active_disk="$LAB_ROOT/disks/${vm}.qcow2"
  if [[ -f "$active_disk" ]]; then
    allocated="$(du -h "$active_disk" | awk '{print $1}')"
    backing="$(qemu-img info --output=json "$active_disk" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("full-backing-filename", "none"))' 2>/dev/null || printf unknown)"
    if [[ -f "$RUNTIME_DIR/${vm}.pid" ]]; then
      local vm_pid
      vm_pid="$(<"$RUNTIME_DIR/${vm}.pid")"
      [[ "$vm_pid" =~ ^[0-9]+$ && -r "/proc/$vm_pid/stat" ]] && uptime=" uptimeSeconds=$(ps -o etimes= -p "$vm_pid" | tr -d ' ')"
    fi
    printf '  disk allocated=%s backing=%s%s\n' "$allocated" "$backing" "$uptime"
  fi
  if lease_is_held "$vm"; then
    if [[ -f "$metadata" ]]; then
      python3 - "$metadata" <<'PY'
import json, sys
with open(sys.argv[1]) as handle:
    lease = json.load(handle)
print("  lease owner={owner} run={runId} pid={pid} cwd={cwd}".format(**lease))
PY
    else
      printf '  lease held; metadata missing (inspect with fuser %s)\n' "$lease_file"
    fi
  elif [[ -f "$metadata" ]]; then
    printf '  stale lease metadata: %s\n' "$metadata"
  fi
}

inventory_command() {
  local format="${1:---text}" vm
  if [[ "$format" == "--json" ]]; then
    printf '['
    local separator=""
    for vm in "${ALL_TARGETS[@]}"; do
      printf '%s' "$separator"
      describe_target "$vm" --json | tr -d '\n'
      separator=,
    done
    printf ']\n'
    return
  fi
  printf 'target\tkind\tplatform\tconnection\tmemoryMiB\tstorageGiB\n'
  for vm in "${ALL_VMS[@]}"; do
    eval "$(describe_vm "$vm" --shell)"
    case "$vm" in
      appimage|deb|rpm) printf '%s\tvm\t%s/x86_64\tssh:%s spice:%s\t6144\t50\n' "$vm" "$LAB_VM_DISTRO" "$LAB_VM_SSH_PORT" "$LAB_VM_SPICE_PORT" ;;
      atomic) printf '%s\tvm\t%s/x86_64\tssh:%s spice:%s\t8192\t60\n' "$vm" "$LAB_VM_DISTRO" "$LAB_VM_SSH_PORT" "$LAB_VM_SPICE_PORT" ;;
      windows) printf '%s\tvm\t%s/x86_64\tssh:%s spice:%s\t8192\t100\n' "$vm" "$LAB_VM_DISTRO" "$LAB_VM_SSH_PORT" "$LAB_VM_SPICE_PORT" ;;
    esac
  done
  for vm in "${ALL_HOSTS[@]}"; do
    eval "$(describe_host "$vm" --shell)"
    printf '%s\thost\tmacos/arm64\t%s\t8192\tphysical\n' "$vm" "${LAB_HOST_SSH_TARGET:-unconfigured}"
  done
}

baseline_command() {
  local vm suite candidate
  vm="$(canonical_target "${1:?TARGET is required}")"
  suite="${2:?SUITE is required}"
  if [[ "$(target_kind "$vm")" == host ]]; then
    case "$suite" in cli|desktop) printf 'ready\n' ;; *) printf 'Unknown suite: %s\n' "$suite" >&2; return 2 ;; esac
    return
  fi
  case "$suite" in
    cli) printf 'clean\n' ;;
    desktop)
      if [[ "$vm" == atomic ]]; then
        printf 'clean\n'
        return
      fi
      for candidate in desktop-e2e-v2 podman-ready clean; do
        if "$ENGINE" snapshots "$vm" | grep -Fx "$candidate" >/dev/null; then
          printf '%s\n' "$candidate"
          return
        fi
      done
      printf 'No usable Desktop baseline for %s.\n' "$vm" >&2
      return 1
      ;;
    *) printf 'Unknown suite: %s\n' "$suite" >&2; return 2 ;;
  esac
}

profile_command() {
  local profile="${1:?PROFILE is required}" vm
  vm="$(canonical_target "${2:?TARGET is required}")"
  [[ -f "$MANIFEST" ]] || { printf 'Missing lab manifest: %s\n' "$MANIFEST" >&2; return 1; }
  python3 - "$MANIFEST" "$profile" "$vm" <<'PY'
import json, sys
path, profile, vm = sys.argv[1:]
with open(path) as handle:
    manifest = json.load(handle)
try:
    print(manifest["profiles"][profile][vm])
except KeyError:
    raise SystemExit(f"Unknown profile or VM mapping: {profile}/{vm}")
PY
}

capabilities_command() {
  local format="${1:---json}"
  case "$format" in
    --json)
      printf '{"schemaVersion":1,"controllerApi":3,"labVersion":"%s","features":["artifact-path","cache-path","capabilities","cleanup","disposable-hosts","evidence-v1","lease-cleanup","paths","preflight","profiles","provenance","remote-hosts","strict-doctor"]}\n' "$LAB_VERSION"
      ;;
    --text)
      printf '%s\n' artifact-path cache-path capabilities cleanup disposable-hosts evidence-v1 lease-cleanup paths preflight profiles provenance remote-hosts strict-doctor
      ;;
    *) printf 'Unknown capabilities format: %s\n' "$format" >&2; return 2 ;;
  esac
}

paths_command() {
  local format="${1:---shell}"
  case "$format" in
    --shell)
      printf 'OMNIDECK_VM_LAB_ARTIFACT_ROOT=%q\n' "$ARTIFACT_ROOT"
      printf 'OMNIDECK_VM_LAB_CACHE_ROOT=%q\n' "$CACHE_ROOT"
      printf 'OMNIDECK_VM_LAB_TRANSACTION_ROOT=%q\n' "$TRANSACTION_ROOT"
      ;;
    --json)
      python3 - "$ARTIFACT_ROOT" "$CACHE_ROOT" "$TRANSACTION_ROOT" <<'PY'
import json, sys
print(json.dumps({
    "schemaVersion": 1,
    "artifactRoot": sys.argv[1],
    "cacheRoot": sys.argv[2],
    "transactionRoot": sys.argv[3],
}, sort_keys=True))
PY
      ;;
    *) printf 'Unknown paths format: %s\n' "$format" >&2; return 2 ;;
  esac
}

artifact_path_command() {
  local owner="${1:?OWNER is required}" suite="${2:?SUITE is required}" run_id="${3:?RUN_ID is required}"
  validate_identifier owner "$owner"
  validate_identifier suite "$suite"
  validate_identifier run-id "$run_id"
  printf '%s/%s/%s/%s\n' "$ARTIFACT_ROOT" "$owner" "$suite" "$run_id"
}

cache_path_command() {
  local owner="${1:?OWNER is required}" key="${2:?KEY is required}"
  validate_identifier owner "$owner"
  validate_identifier cache-key "$key"
  printf '%s/%s/%s\n' "$CACHE_ROOT" "$owner" "$key"
}

golden_paths() {
  local vm="$1" name="$2"
  if [[ "$name" == clean ]]; then
    GOLDEN_CAPTURE_DISK="$LAB_ROOT/golden/${vm}-clean.qcow2"
    GOLDEN_CAPTURE_VARS="$LAB_ROOT/golden/${vm}-clean-OVMF_VARS.fd"
    GOLDEN_CAPTURE_TPM="$LAB_ROOT/golden/${vm}-clean-tpm"
  else
    GOLDEN_CAPTURE_DISK="$LAB_ROOT/golden/$vm/$name/disk.qcow2"
    GOLDEN_CAPTURE_VARS="$LAB_ROOT/golden/$vm/$name/OVMF_VARS.fd"
    GOLDEN_CAPTURE_TPM="$LAB_ROOT/golden/$vm/$name/tpm"
  fi
}

tree_digest() {
  local directory="$1"
  if [[ ! -d "$directory" ]]; then
    printf 'none\n'
    return
  fi
  find "$directory" -type f -printf '%P\0' | sort -z | while IFS= read -r -d '' relative; do
    printf '%s  %s\n' "$(sha256sum "$directory/$relative" | awk '{print $1}')" "$relative"
  done | sha256sum | awk '{print $1}'
}

provenance_capture_one() {
  local vm="$1" name="$2" destination disk_sha vars_sha tpm_sha
  golden_paths "$vm" "$name"
  [[ -f "$GOLDEN_CAPTURE_DISK" ]] || { printf 'Missing golden disk: %s\n' "$GOLDEN_CAPTURE_DISK" >&2; return 1; }
  [[ -f "$GOLDEN_CAPTURE_VARS" ]] || { printf 'Missing golden UEFI state: %s\n' "$GOLDEN_CAPTURE_VARS" >&2; return 1; }
  if [[ "$vm" == windows && ! -d "$GOLDEN_CAPTURE_TPM" ]]; then
    printf 'Missing golden TPM state: %s\n' "$GOLDEN_CAPTURE_TPM" >&2
    return 1
  fi
  printf 'Fingerprinting %s/%s (this can take several minutes)...\n' "$vm" "$name" >&2
  disk_sha="$(sha256sum "$GOLDEN_CAPTURE_DISK" | awk '{print $1}')"
  vars_sha="$(sha256sum "$GOLDEN_CAPTURE_VARS" | awk '{print $1}')"
  tpm_sha="$(tree_digest "$GOLDEN_CAPTURE_TPM")"
  mkdir -p "$LAB_ROOT/golden/manifests"
  destination="$LAB_ROOT/golden/manifests/${vm}-${name}.json"
  python3 - "$destination" "$vm" "$(distro_name "$vm")" "$name" "$disk_sha" "$vars_sha" "$tpm_sha" "$LAB_VERSION" "$MANIFEST" "$GOLDEN_CAPTURE_DISK" <<'PY'
import datetime, hashlib, json, os, subprocess, sys, tempfile
path, vm, distro, name, disk_sha, vars_sha, tpm_sha, version, config_path, disk_path = sys.argv[1:]
config_sha = hashlib.sha256(open(config_path, "rb").read()).hexdigest() if os.path.exists(config_path) else None
qemu_info = json.loads(subprocess.check_output(["qemu-img", "info", "--output=json", disk_path]))
record = {
    "schemaVersion": 1,
    "vm": vm,
    "distro": distro,
    "baseline": name,
    "capturedAt": datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z"),
    "provenance": "captured-current-state",
    "controllerVersion": version,
    "labManifestSha256": config_sha,
    "diskSha256": disk_sha,
    "uefiVarsSha256": vars_sha,
    "tpmTreeSha256": tpm_sha,
    "qemuImage": qemu_info,
}
fd, temporary = tempfile.mkstemp(prefix=".provenance.", dir=os.path.dirname(path), text=True)
with os.fdopen(fd, "w") as handle:
    json.dump(record, handle, indent=2, sort_keys=True)
    handle.write("\n")
os.replace(temporary, path)
PY
  printf '%s\n' "$destination"
}

provenance_command() {
  local action="${1:?ACTION is required}"
  shift
  case "$action" in
    capture)
      local requested="${1:?VM or --all is required}" name="${2:-clean}" vm
      if [[ "$requested" == --all ]]; then
        for vm in "${ALL_VMS[@]}"; do
          [[ "$("$ENGINE" status "$vm")" == "${vm} stopped "* ]] || { printf '%s is running.\n' "$vm" >&2; return 1; }
          lease_is_held "$vm" && { printf '%s is leased.\n' "$vm" >&2; return 1; }
        done
        for vm in "${ALL_VMS[@]}"; do provenance_capture_one "$vm" clean; done
      else
        vm="$(canonical_vm "$requested")"
        [[ "$("$ENGINE" status "$vm")" == "${vm} stopped "* ]] || { printf '%s is running.\n' "$vm" >&2; return 1; }
        lease_is_held "$vm" && { printf '%s is leased.\n' "$vm" >&2; return 1; }
        provenance_capture_one "$vm" "$name"
      fi
      ;;
    *) printf 'Unknown provenance action: %s\n' "$action" >&2; return 2 ;;
  esac
}

provenance_metadata_valid() {
  local path="$1" vm="$2" baseline="$3"
  python3 - "$path" "$MANIFEST" "$vm" "$baseline" <<'PY'
import hashlib, json, re, sys
path, config_path, vm, baseline = sys.argv[1:]
try:
    with open(path) as handle:
        record = json.load(handle)
    with open(config_path, "rb") as handle:
        config_sha = hashlib.sha256(handle.read()).hexdigest()
    assert record["schemaVersion"] == 1
    assert record["vm"] == vm
    assert record["baseline"] == baseline
    assert record["labManifestSha256"] == config_sha
    assert re.fullmatch(r"[0-9a-f]{64}", record["diskSha256"])
    assert re.fullmatch(r"[0-9a-f]{64}", record["uefiVarsSha256"])
    assert record["tpmTreeSha256"] == "none" or re.fullmatch(r"[0-9a-f]{64}", record["tpmTreeSha256"])
    assert isinstance(record["qemuImage"], dict)
except (AssertionError, KeyError, OSError, ValueError, json.JSONDecodeError):
    raise SystemExit(1)
PY
}

preflight_command() {
  local suite="${1:?SUITE is required}" profile="${2:?PROFILE is required}" lanes_csv="" baseline_override="" format=--text
  shift 2
  while (($#)); do
    case "$1" in
      --lanes) lanes_csv="${2:?value required}"; shift 2 ;;
      --baseline) baseline_override="${2:?value required}"; validate_identifier baseline "$baseline_override"; shift 2 ;;
      --json) format=--json; shift ;;
      *) printf 'Unknown preflight argument: %s\n' "$1" >&2; return 2 ;;
    esac
  done
  case "$suite" in cli|desktop) ;; *) printf 'Unknown suite: %s\n' "$suite" >&2; return 2 ;; esac
  [[ -n "$lanes_csv" ]] || { if [[ "$suite" == cli ]]; then lanes_csv=appimage,deb,rpm,windows; else lanes_csv=appimage,deb,rpm,atomic,windows; fi; }
  local -a lanes=()
  IFS=',' read -r -a lanes <<<"$lanes_csv"
  local temporary errors=0 requested vm kind baseline status manifest_path
  temporary="$(mktemp "$RUNTIME_DIR/.preflight.XXXXXX")"
  for requested in "${lanes[@]}"; do
    vm="$(canonical_target "$requested")" || { errors=$((errors + 1)); continue; }
    kind="$(target_kind "$vm")"
    if [[ -n "$baseline_override" ]]; then baseline="$baseline_override"; else baseline="$(profile_command "$profile" "$vm")" || { errors=$((errors + 1)); continue; }; fi
    if [[ "$kind" == host ]]; then
      manifest_path="$LAB_ROOT/hosts/${vm}.json"
      status="$($HOST_ENGINE status "$vm")"
      if [[ "$baseline" != ready ]]; then
        printf '%s\t%s\t%s\tunsupported-baseline\t%s\n' "$vm" "$(distro_name "$vm")" "$baseline" "$manifest_path" >> "$temporary"
        errors=$((errors + 1))
      elif [[ "$status" != "${vm} ready "* ]]; then
        printf '%s\t%s\t%s\t%s\t%s\n' "$vm" "$(distro_name "$vm")" "$baseline" "$(awk '{print $2}' <<<"$status")" "$manifest_path" >> "$temporary"
        errors=$((errors + 1))
      else
        printf '%s\t%s\t%s\tready\t%s\n' "$vm" "$(distro_name "$vm")" "$baseline" "$manifest_path" >> "$temporary"
      fi
      continue
    fi
    status="$("$ENGINE" status "$vm")"
    manifest_path="$LAB_ROOT/golden/manifests/${vm}-${baseline}.json"
    if [[ "$status" != "${vm} stopped "* ]]; then
      printf '%s\t%s\t%s\trunning\t%s\n' "$vm" "$(distro_name "$vm")" "$baseline" "$manifest_path" >> "$temporary"
      errors=$((errors + 1))
    elif ! "$ENGINE" snapshots "$vm" | grep -Fx "$baseline" >/dev/null; then
      printf '%s\t%s\t%s\tmissing-baseline\t%s\n' "$vm" "$(distro_name "$vm")" "$baseline" "$manifest_path" >> "$temporary"
      errors=$((errors + 1))
    elif [[ ! -f "$manifest_path" ]]; then
      printf '%s\t%s\t%s\tmissing-provenance\t%s\n' "$vm" "$(distro_name "$vm")" "$baseline" "$manifest_path" >> "$temporary"
      errors=$((errors + 1))
    elif ! provenance_metadata_valid "$manifest_path" "$vm" "$baseline"; then
      printf '%s\t%s\t%s\tinvalid-provenance\t%s\n' "$vm" "$(distro_name "$vm")" "$baseline" "$manifest_path" >> "$temporary"
      errors=$((errors + 1))
    else
      printf '%s\t%s\t%s\tready\t%s\n' "$vm" "$(distro_name "$vm")" "$baseline" "$manifest_path" >> "$temporary"
    fi
  done
  if [[ "$format" == --json ]]; then
    python3 - "$suite" "$profile" "$lanes_csv" "$errors" "$temporary" <<'PY'
import json, sys
suite, profile, lanes, errors, path = sys.argv[1:]
records = []
with open(path) as handle:
    for line in handle:
        vm, distro, baseline, status, provenance = line.rstrip("\n").split("\t")
        records.append({"vm": vm, "distro": distro, "baseline": baseline, "status": status, "provenance": provenance})
print(json.dumps({"schemaVersion": 1, "suite": suite, "profile": profile, "lanes": lanes.split(","), "ready": int(errors) == 0, "results": records}, sort_keys=True))
PY
  else
    printf 'vm\tdistro\tbaseline\tstatus\tprovenance\n'
    cat "$temporary"
    printf 'preflight summary: suite=%s profile=%s errors=%s\n' "$suite" "$profile" "$errors"
  fi
  unlink "$temporary"
  ((errors == 0))
}

safe_artifact_dir() {
  local requested="$1" resolved
  resolved="$(realpath -m "$requested")"
  case "$resolved" in
    "$ARTIFACT_ROOT"/*) printf '%s\n' "$resolved" ;;
    *) printf 'Evidence path must be below %s: %s\n' "$ARTIFACT_ROOT" "$requested" >&2; return 2 ;;
  esac
}

evidence_init() {
  (($# >= 7)) || { printf 'evidence-init requires DIR OWNER SUITE RUN_ID COMMIT VM BASELINE.\n' >&2; exit 2; }
  local directory owner suite run_id commit vm baseline
  directory="$(safe_artifact_dir "$1")"; owner="$2"; suite="$3"; run_id="$4"; commit="$5"
  if [[ "$6" == multi ]]; then vm=multi; else vm="$(canonical_target "$6")"; fi
  baseline="$7"
  shift 7
  validate_identifier owner "$owner"; validate_identifier suite "$suite"; validate_identifier run-id "$run_id"
  mkdir -p "$directory"
  : > "$directory/.lab-run"
  local evidence_distro
  if [[ "$vm" == multi ]]; then evidence_distro=multi; else evidence_distro="$(distro_name "$vm")"; fi
  python3 - "$directory/run.json" "$owner" "$suite" "$run_id" "$commit" "$vm" "$evidence_distro" "$baseline" "$@" <<'PY'
import datetime, json, os, sys, tempfile
path, owner, suite, run_id, commit, vm, distro, baseline, *pairs = sys.argv[1:]
record = {
    "schemaVersion": 1,
    "owner": owner,
    "suite": suite,
    "runId": run_id,
    "sourceCommit": commit,
    "vm": vm,
    "distro": distro,
    "baseline": baseline,
    "status": "running",
    "startedAt": datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z"),
}
for pair in pairs:
    key, separator, value = pair.partition("=")
    if not separator or not key:
        raise SystemExit(f"invalid metadata pair: {pair}")
    record[key] = value
with open(path, "w") as handle:
    json.dump(record, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
}

evidence_set() {
  local directory
  directory="$(safe_artifact_dir "${1:?DIR is required}")"
  shift
  (($#)) || { printf 'evidence-set requires KEY=VALUE.\n' >&2; exit 2; }
  [[ -f "$directory/run.json" && -f "$directory/.lab-run" ]] || { printf 'Not a marked lab run: %s\n' "$directory" >&2; exit 2; }
  python3 - "$directory/run.json" "$@" <<'PY'
import json, os, sys, tempfile
path, *pairs = sys.argv[1:]
with open(path) as handle:
    record = json.load(handle)
for pair in pairs:
    key, separator, value = pair.partition("=")
    if not separator or not key:
        raise SystemExit(f"invalid metadata pair: {pair}")
    record[key] = value
fd, temporary = tempfile.mkstemp(prefix=".run.", dir=os.path.dirname(path), text=True)
with os.fdopen(fd, "w") as handle:
    json.dump(record, handle, indent=2, sort_keys=True)
    handle.write("\n")
os.replace(temporary, path)
PY
}

evidence_finish() {
  local directory status
  directory="$(safe_artifact_dir "${1:?DIR is required}")"
  status="${2:?STATUS is required}"
  case "$status" in passed|failed|blocked|canceled) ;; *) printf 'Invalid evidence status: %s\n' "$status" >&2; exit 2 ;; esac
  evidence_set "$directory" "status=$status" "finishedAt=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

runs_command() {
  local action="${1:-list}"
  shift || true
  case "$action" in
    list)
      find "$ARTIFACT_ROOT" -type f -name run.json -print0 2>/dev/null | sort -z | while IFS= read -r -d '' manifest; do
        python3 - "$manifest" <<'PY'
import json, os, sys
try:
    with open(sys.argv[1]) as handle:
        run = json.load(handle)
    print(f"{run.get('status', 'unknown')}\t{run.get('owner', 'unknown')}/{run.get('suite', 'unknown')}\t{run.get('runId', 'unknown')}\t{os.path.dirname(sys.argv[1])}")
except (OSError, json.JSONDecodeError) as error:
    print(f"invalid\tunknown\tunknown\t{sys.argv[1]} ({error})")
PY
      done
      ;;
    inspect)
      local directory; directory="$(safe_artifact_dir "${1:?PATH is required}")"
      [[ -f "$directory/run.json" ]] || { printf 'Missing run.json: %s\n' "$directory" >&2; exit 1; }
      cat "$directory/run.json"
      du -sh -- "$directory"
      ;;
    pin|unpin)
      local directory; directory="$(safe_artifact_dir "${1:?PATH is required}")"
      [[ -f "$directory/.lab-run" ]] || { printf 'Not a marked lab run: %s\n' "$directory" >&2; exit 2; }
      if [[ "$action" == pin ]]; then : > "$directory/.pin"; else unlink "$directory/.pin" 2>/dev/null || true; fi
      ;;
    purge)
      local directory confirmation="${2:-}"
      directory="$(safe_artifact_dir "${1:?PATH is required}")"
      [[ -f "$directory/.lab-run" && -f "$directory/run.json" ]] || { printf 'Not a marked lab run: %s\n' "$directory" >&2; exit 2; }
      du -sh -- "$directory"
      if [[ "$confirmation" != --yes ]]; then
        [[ -t 0 ]] || { printf 'Pass --yes in noninteractive mode.\n' >&2; exit 2; }
        printf 'Type %s to purge: ' "$(basename "$directory")"
        read -r typed
        [[ "$typed" == "$(basename "$directory")" ]] || { printf 'Canceled.\n'; exit 1; }
      fi
      rm -rf -- "$directory"
      ;;
    *) printf 'Unknown runs action: %s\n' "$action" >&2; exit 2 ;;
  esac
}

doctor_command() {
  local mode="${1:---standard}"
  case "$mode" in --standard|--strict|--deep) ;; *) printf 'Unknown doctor mode: %s\n' "$mode" >&2; return 2 ;; esac
  ensure_layout
  local errors=0 warnings=0 dependency vm disk golden count size
  for dependency in bash flock python3 qemu-img qemu-system-x86_64 ssh scp; do
    if ! command -v "$dependency" >/dev/null 2>&1; then
      printf 'ERROR missing dependency: %s\n' "$dependency"
      errors=$((errors + 1))
    fi
  done
  if [[ ! -f "$MANIFEST" ]]; then
    printf 'ERROR missing declarative lab manifest: %s\n' "$MANIFEST"
    errors=$((errors + 1))
  elif ! python3 -m json.tool "$MANIFEST" >/dev/null 2>&1; then
    printf 'ERROR invalid declarative lab manifest: %s\n' "$MANIFEST"
    errors=$((errors + 1))
  fi
  for vm in "${ALL_VMS[@]}"; do
    local basic_status
    basic_status="$("$ENGINE" status "$vm")"
    status_one "$vm" --verbose
    if [[ -f "$RUNTIME_DIR/${vm}.pid" && "$basic_status" == "${vm} stopped "* ]]; then
      printf 'WARN stale or mismatched PID file: %s\n' "$RUNTIME_DIR/${vm}.pid"
      warnings=$((warnings + 1))
    fi
    disk="$LAB_ROOT/disks/${vm}.qcow2"
    golden="$LAB_ROOT/golden/${vm}-clean.qcow2"
    if [[ ! -f "$golden" ]]; then
      printf 'ERROR missing clean golden: %s\n' "$golden"
      errors=$((errors + 1))
      continue
    fi
    if [[ "$basic_status" == "${vm} stopped "* && -f "$disk" ]] && ! qemu-img info --output=json "$disk" >/dev/null; then
      printf 'ERROR unreadable active disk: %s\n' "$disk"
      errors=$((errors + 1))
    fi
    if ! qemu-img info --output=json "$golden" >/dev/null; then
      printf 'ERROR unreadable clean golden: %s\n' "$golden"
      errors=$((errors + 1))
    fi
  done
  for vm in "${ALL_HOSTS[@]}"; do
    local host_status
    host_status="$($HOST_ENGINE status "$vm")"
    status_host "$vm" --verbose
    case "$host_status" in
      "$vm ready "*)
        if ! "$HOST_ENGINE" verify "$vm"; then
          printf 'ERROR physical host verification failed: %s\n' "$vm"
          errors=$((errors + 1))
        fi
        ;;
      "$vm unconfigured")
        printf 'WARN optional physical host is not configured: %s\n' "$vm"
        warnings=$((warnings + 1))
        ;;
      *)
        printf 'ERROR physical host is configured but not ready: %s\n' "$vm"
        errors=$((errors + 1))
        ;;
    esac
  done
  if [[ "$mode" == --strict || "$mode" == --deep ]]; then
    local install_record="$LAB_ROOT/controller-install.json"
    if [[ ! -f "$install_record" ]]; then
      printf 'ERROR missing controller install provenance: %s\n' "$install_record"
      errors=$((errors + 1))
    elif ! python3 - "$LAB_ROOT" "$install_record" <<'PY'
import hashlib, json, os, re, sys
root, path = sys.argv[1:]
try:
    with open(path) as handle:
        record = json.load(handle)
    assert record["schemaVersion"] == 1
    assert record["version"]
    files = record["installedFilesSha256"]
    assert files
    for relative, expected in files.items():
        assert not os.path.isabs(relative) and ".." not in relative.split(os.sep)
        assert re.fullmatch(r"[0-9a-f]{64}", expected)
        with open(os.path.join(root, relative), "rb") as handle:
            assert hashlib.sha256(handle.read()).hexdigest() == expected
except (AssertionError, KeyError, OSError, ValueError, json.JSONDecodeError):
    raise SystemExit(1)
PY
    then
      printf 'ERROR installed controller files differ from controller-install.json\n'
      errors=$((errors + 1))
    fi
    if [[ -f "$MANIFEST" ]]; then
      while IFS=$'\t' read -r vm dependency expected; do
        local actual
        if [[ ! -f "$LAB_ROOT/$dependency" ]]; then
          printf 'ERROR %s provisioning input is missing: %s\n' "$vm" "$LAB_ROOT/$dependency"
          errors=$((errors + 1))
          continue
        fi
        actual="$(sha256sum "$LAB_ROOT/$dependency" | awk '{print $1}')"
        if [[ "$actual" != "$expected" ]]; then
          printf 'ERROR %s provisioning digest mismatch: %s\n' "$vm" "$dependency"
          errors=$((errors + 1))
        fi
      done < <(python3 - "$MANIFEST" <<'PY'
import json, sys
with open(sys.argv[1]) as handle:
    manifest = json.load(handle)
for vm, spec in sorted(manifest["vms"].items()):
    print(f"{vm}\t{spec['provisioning']}\t{spec['provisioningSha256']}")
    if "unattend" in spec:
        print(f"{vm}\t{spec['unattend']}\t{spec['unattendSha256']}")
PY
      )
      while IFS=$'\t' read -r vm base upstream verification algorithm expected; do
        if [[ ! -f "$LAB_ROOT/base-images/$base" ]]; then
          printf 'ERROR %s base image is missing: %s\n' "$vm" "$base"
          errors=$((errors + 1))
        fi
        if [[ ! -f "$LAB_ROOT/$verification" ]]; then
          printf 'ERROR %s base verification record is missing: %s\n' "$vm" "$verification"
          errors=$((errors + 1))
        elif ! grep -F "$expected" "$LAB_ROOT/$verification" | grep -F "$upstream" >/dev/null; then
          printf 'ERROR %s base verification record does not bind %s to its declared digest\n' "$vm" "$upstream"
          errors=$((errors + 1))
        fi
        if [[ "$mode" == --deep && -f "$LAB_ROOT/base-images/$base" ]]; then
          local actual_base
          if [[ "$algorithm" == sha256 ]]; then
            actual_base="$(sha256sum "$LAB_ROOT/base-images/$base" | awk '{print $1}')"
          else
            actual_base="$(sha512sum "$LAB_ROOT/base-images/$base" | awk '{print $1}')"
          fi
          if [[ "$actual_base" != "$expected" ]]; then
            printf 'ERROR base-image digest mismatch: %s\n' "$vm"
            errors=$((errors + 1))
          fi
        fi
      done < <(python3 - "$MANIFEST" <<'PY'
import json, sys
with open(sys.argv[1]) as handle:
    manifest = json.load(handle)
for vm, spec in sorted(manifest["vms"].items()):
    algorithm, digest = spec["baseImageDigest"].split(":", 1)
    print(f"{vm}\t{spec['baseImage']}\t{spec['baseImageUpstreamName']}\t{spec['baseImageVerificationRecord']}\t{algorithm}\t{digest}")
PY
      )
    fi
    for vm in "${ALL_VMS[@]}"; do
      local provenance="$LAB_ROOT/golden/manifests/${vm}-clean.json"
      if [[ ! -f "$provenance" ]]; then
        printf 'ERROR missing clean-golden provenance: %s\n' "$provenance"
        errors=$((errors + 1))
      elif ! provenance_metadata_valid "$provenance" "$vm" clean; then
        printf 'ERROR invalid clean-golden provenance: %s\n' "$provenance"
        errors=$((errors + 1))
      elif [[ "$mode" == --deep ]]; then
        local expected_disk actual_disk
        expected_disk="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["diskSha256"])' "$provenance")"
        actual_disk="$(sha256sum "$LAB_ROOT/golden/${vm}-clean.qcow2" | awk '{print $1}')"
        if [[ "$expected_disk" != "$actual_disk" ]]; then
          printf 'ERROR clean-golden digest mismatch: %s\n' "$vm"
          errors=$((errors + 1))
        fi
      fi
    done
  fi
  for dependency in \
    "$LAB_ROOT/base-images/Fedora-Cloud-44-1.7-x86_64-CHECKSUM.verified" \
    "$LAB_ROOT/base-images/Fedora-Silverblue-44-1.7-x86_64-CHECKSUM.verified" \
    "$LAB_ROOT/base-images/ubuntu-noble-SHA256SUMS.gpg" \
    "$LAB_ROOT/base-images/debian-trixie-SHA512SUMS" \
    "$LAB_ROOT/base-images/Win11_25H2_English_x64_v2-SHA256"; do
    if [[ ! -f "$dependency" ]]; then
      printf 'WARN missing base-image verification record: %s\n' "$dependency"
      warnings=$((warnings + 1))
    fi
  done
  count="$(find "$DISCARDED_DIR" -mindepth 1 -maxdepth 1 ! -name runs | wc -l)"
  size="$(du -sh "$DISCARDED_DIR" 2>/dev/null | awk '{print $1}')"
  if ((count > 0)); then
    printf 'WARN legacy discarded entries=%s size=%s; gc can remove them.\n' "$count" "$size"
    warnings=$((warnings + 1))
  fi
  while IFS= read -r metadata; do
    printf 'WARN checkpoint lacks metadata: %s\n' "$(dirname "$metadata")"
    warnings=$((warnings + 1))
  done < <(find "$LAB_ROOT/golden" -mindepth 3 -maxdepth 3 -name disk.qcow2 -printf '%h/metadata.json\n' | while read -r path; do [[ -f "$path" ]] || printf '%s\n' "$path"; done)
  local available_kib
  available_kib="$(df -Pk "$LAB_ROOT" | awk 'NR==2 {print $4}')"
  if ((available_kib < 20 * 1024 * 1024)); then
    printf 'WARN less than 20 GiB free under %s.\n' "$LAB_ROOT"
    warnings=$((warnings + 1))
  fi
  printf 'doctor summary: errors=%s warnings=%s labVersion=%s mode=%s\n' "$errors" "$warnings" "$LAB_VERSION" "${mode#--}"
  ((errors == 0))
}

gc_command() {
  local apply=0 all_evidence=0 all_generated=0 confirmed=0 retention_hours="$DEFAULT_RETENTION_HOURS" cache_retention_hours="$DEFAULT_CACHE_RETENTION_HOURS"
  while (($#)); do
    case "$1" in
      --dry-run) apply=0; shift ;;
      --apply) apply=1; shift ;;
      --all-evidence) all_evidence=1; shift ;;
      --all-generated) all_generated=1; shift ;;
      --yes) confirmed=1; shift ;;
      --retention-hours) retention_hours="${2:?value required}"; shift 2 ;;
      --cache-retention-hours) cache_retention_hours="${2:?value required}"; shift 2 ;;
      *) printf 'Unknown gc argument: %s\n' "$1" >&2; exit 2 ;;
    esac
  done
  [[ "$retention_hours" =~ ^[0-9]+$ ]] || { printf 'Retention hours must be numeric.\n' >&2; exit 2; }
  [[ "$cache_retention_hours" =~ ^[0-9]+$ ]] || { printf 'Cache retention hours must be numeric.\n' >&2; exit 2; }
  if ((apply && all_generated && ! confirmed)); then
    printf 'Applying --all-generated requires --yes.\n' >&2
    exit 2
  fi
  ensure_layout
  if ((apply)); then
    local vm
    for vm in "${ALL_VMS[@]}"; do
      if lease_is_held "$vm"; then
        printf 'Refusing GC while %s is leased.\n' "$vm" >&2
        return 1
      fi
    done
  fi
  local cutoff_minutes=$((retention_hours * 60)) cache_cutoff_minutes=$((cache_retention_hours * 60)) candidate
  local -a candidates=()
  if ((all_generated)); then
    while IFS= read -r -d '' candidate; do candidates+=("$candidate"); done < <(find "$ARTIFACT_ROOT" -mindepth 1 -maxdepth 1 -print0)
    while IFS= read -r -d '' candidate; do candidates+=("$candidate"); done < <(find "$DISCARDED_DIR" -mindepth 1 -maxdepth 1 -print0)
    while IFS= read -r -d '' candidate; do candidates+=("$candidate"); done < <(find "$CACHE_ROOT" -mindepth 1 -maxdepth 1 -print0)
  elif ((all_evidence)); then
    while IFS= read -r -d '' candidate; do candidates+=("$candidate"); done < <(find "$ARTIFACT_ROOT" -mindepth 1 -maxdepth 1 -print0)
    while IFS= read -r -d '' candidate; do candidates+=("$candidate"); done < <(find "$DISCARDED_DIR" -mindepth 1 -maxdepth 1 -print0)
  else
    while IFS= read -r -d '' candidate; do
      [[ -f "$candidate/.pin" ]] || candidates+=("$candidate")
    done < <(find "$TRANSACTION_ROOT" -mindepth 1 -maxdepth 1 -type d -mmin "+$cutoff_minutes" -print0 2>/dev/null)
    while IFS= read -r -d '' candidate; do
      [[ "$candidate" == "$TRANSACTION_ROOT" ]] || candidates+=("$candidate")
    done < <(find "$DISCARDED_DIR" -mindepth 1 -maxdepth 1 -mmin "+$cutoff_minutes" -print0 2>/dev/null)
    while IFS= read -r -d '' candidate; do
      local run_directory
      run_directory="$(dirname "$candidate")"
      [[ -f "$run_directory/.pin" ]] || candidates+=("$run_directory")
    done < <(find "$ARTIFACT_ROOT" -type f -name run.json -mmin "+$cutoff_minutes" -print0 2>/dev/null)
    while IFS= read -r -d '' candidate; do
      [[ -f "$candidate/.pin" ]] || candidates+=("$candidate")
    done < <(find "$CACHE_ROOT" -mindepth 2 -maxdepth 2 -type d -mmin "+$cache_cutoff_minutes" -print0 2>/dev/null)
  fi
  if ((${#candidates[@]} == 0)); then
    printf 'GC found nothing eligible (retention=%sh).\n' "$retention_hours"
  else
    printf 'GC candidates (apply=%s artifactRetention=%sh cacheRetention=%sh):\n' "$apply" "$retention_hours" "$cache_retention_hours"
    printf '%s\n' "${candidates[@]}" | sort -u | while IFS= read -r candidate; do
      case "$candidate" in
        "$ARTIFACT_ROOT"/*|"$DISCARDED_DIR"/*|"$CACHE_ROOT"/*) ;;
        *) printf 'Refusing unsafe GC candidate: %s\n' "$candidate" >&2; exit 2 ;;
      esac
      du -sh -- "$candidate" 2>/dev/null || printf 'missing\t%s\n' "$candidate"
      if ((apply)) && [[ -e "$candidate" ]]; then rm -rf -- "$candidate"; fi
    done
  fi
  while IFS= read -r log; do
    printf 'oversize-log\t%s\n' "$log"
    if ((apply)); then
      local temporary
      temporary="$(mktemp "$LOG_DIR/.gc-log.XXXXXX")"
      tail -c $((2 * 1024 * 1024)) -- "$log" > "$temporary"
      mv -- "$temporary" "$log"
    fi
  done < <(find "$LOG_DIR" -maxdepth 1 -type f -size +8M -print 2>/dev/null)
}

checkpoint_command() {
  local action="${1:?ACTION is required}" vm name directory
  vm="$(canonical_vm "${2:?VM is required}")"
  name="${3:?NAME is required}"
  validate_identifier checkpoint "$name"
  [[ "$name" != clean ]] || { printf 'The clean checkpoint cannot be changed through checkpoint commands.\n' >&2; exit 2; }
  directory="$LAB_ROOT/golden/$vm/$name"
  case "$action" in
    inspect)
      [[ -d "$directory" ]] || { printf 'Missing checkpoint: %s/%s\n' "$vm" "$name" >&2; exit 1; }
      [[ -f "$directory/metadata.json" ]] && cat "$directory/metadata.json"
      qemu-img info --backing-chain "$directory/disk.qcow2"
      ;;
    adopt)
      [[ -d "$directory" && -f "$directory/disk.qcow2" ]] || { printf 'Missing checkpoint: %s/%s\n' "$vm" "$name" >&2; exit 1; }
      [[ ! -e "$directory/metadata.json" ]] || { printf 'Checkpoint metadata already exists: %s/%s\n' "$vm" "$name" >&2; exit 1; }
      printf '{\n  "schemaVersion": 1,\n  "vm": "%s",\n  "name": "%s",\n  "createdAt": null,\n  "adoptedAt": "%s",\n  "provenance": "legacy-checkpoint; original creation metadata unavailable",\n  "engineVersion": "%s"\n}\n' \
        "$vm" "$name" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LAB_VERSION" > "$directory/metadata.json"
      qemu-img info --output=json "$directory/disk.qcow2" > "$directory/disk-info.json"
      printf 'Adopted legacy checkpoint metadata: %s/%s\n' "$vm" "$name"
      ;;
    delete)
      require_lease "$vm"
      [[ -d "$directory" ]] || { printf 'Missing checkpoint: %s/%s\n' "$vm" "$name" >&2; exit 1; }
      if qemu-img info --output=json "$LAB_ROOT/disks/$vm.qcow2" | grep -Fq "$directory/disk.qcow2"; then
        printf 'The active overlay still depends on %s; reset to clean first.\n' "$directory" >&2
        exit 1
      fi
      rm -rf -- "$directory"
      ;;
    *) printf 'Unknown checkpoint action: %s\n' "$action" >&2; exit 2 ;;
  esac
}

ensure_layout
command="${1:-}"
case "$command" in
  lease) shift; lease_command "$@" ;;
  status)
    shift
    if [[ "${1:-}" == --json ]]; then
      printf '['; separator=""
      for vm in "${ALL_TARGETS[@]}"; do printf '%s' "$separator"; status_one "$vm" --json | tr -d '\n'; separator=,; done
      printf ']\n'
    elif [[ -n "${1:-}" ]]; then
      vm="$1"; shift
      status_one "$vm" "${1:---verbose}"
    else
      for vm in "${ALL_TARGETS[@]}"; do status_one "$vm" --verbose; done
    fi
    ;;
  describe) describe_target "${2:?TARGET is required}" "${3:---shell}" ;;
  inventory) inventory_command "${2:---text}" ;;
  baseline) baseline_command "${2:?VM is required}" "${3:?SUITE is required}" ;;
  profile) profile_command "${2:?PROFILE is required}" "${3:?VM is required}" ;;
  capabilities) capabilities_command "${2:---json}" ;;
  paths) paths_command "${2:---shell}" ;;
  artifact-path) artifact_path_command "${2:?OWNER is required}" "${3:?SUITE is required}" "${4:?RUN_ID is required}" ;;
  cache-path) cache_path_command "${2:?OWNER is required}" "${3:?KEY is required}" ;;
  preflight) shift; preflight_command "$@" ;;
  provenance) shift; provenance_command "$@" ;;
  doctor) doctor_command "${2:---standard}" ;;
  gc) shift; gc_command "$@" ;;
  cleanup) shift; gc_command "$@" ;;
  runs) shift; runs_command "$@" ;;
  evidence-init) shift; evidence_init "$@" ;;
  evidence-set) shift; evidence_set "$@" ;;
  evidence-finish) shift; evidence_finish "$@" ;;
  checkpoint) shift; checkpoint_command "$@" ;;
  snapshot)
    [[ -n "${3:-}" ]] || { printf 'Replacing clean snapshots is disabled; provide a new named checkpoint.\n' >&2; exit 2; }
    vm="$(canonical_vm "${2:?VM is required}")"; require_vm_lease "$vm"; "$ENGINE" snapshot "$vm" "$3"
    ;;
  snapshots) "$ENGINE" "$@" ;;
  reset)
    vm="$(canonical_target "${2:?TARGET is required}")"
    require_lease "$vm"
    if [[ "$(target_kind "$vm")" == host ]]; then
      "$HOST_ENGINE" reset "$vm" "${3:?BASELINE is required}"
    else
      require_vm_lease "$vm"
      "$ENGINE" reset "$vm" "${3:-clean}"
    fi
    ;;
  start|stop|wait|send-keys|screenshot|viewer)
    vm="$(canonical_vm "${2:?VM is required}")"; require_vm_lease "$vm"; "$ENGINE" "$command" "$vm" "${@:3}"
    ;;
  verify|ssh|run|copy-to|copy-from)
    vm="$(canonical_target "${2:?TARGET is required}")"; require_lease "$vm"
    if [[ "$(target_kind "$vm")" == host ]]; then
      "$HOST_ENGINE" "$command" "$vm" "${@:3}"
    else
      require_vm_lease "$vm"
      "$ENGINE" "$command" "$vm" "${@:3}"
    fi
    ;;
  install-atomic)
    require_vm_lease atomic; "$ENGINE" install-atomic
    ;;
  install-windows)
    require_vm_lease windows; "$ENGINE" install-windows
    ;;
  init)
    if [[ -n "${2:-}" ]]; then vm="$(canonical_vm "$2")"; require_vm_lease "$vm"; "$ENGINE" init "$vm"; else printf 'Initialize guests one at a time under their leases.\n' >&2; exit 2; fi
    ;;
  --version) printf 'omnideck-vm-lab %s\n' "$LAB_VERSION" ;;
  --help|-h|help|'') usage ;;
  *) printf 'Unknown command: %s\n' "$command" >&2; usage >&2; exit 2 ;;
esac
