#!/usr/bin/env bash
set -euo pipefail

LAB_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
IMAGE_DIR="$LAB_ROOT/base-images"
SEED_DIR="$LAB_ROOT/seeds"
DISK_DIR="$LAB_ROOT/disks"
GOLDEN_DIR="$LAB_ROOT/golden"
RUNTIME_DIR="$LAB_ROOT/runtime"
DISCARDED_DIR="$LAB_ROOT/discarded"
KEY="$LAB_ROOT/keys/id_ed25519"
ATOMIC_KICKSTART="$LAB_ROOT/automation/atomic.ks"
WINDOWS_UNATTEND="$LAB_ROOT/automation/windows/Autounattend.xml"
WINDOWS_PROVISION="$LAB_ROOT/automation/windows/provision.ps1"
WINDOWS_ISO="$IMAGE_DIR/Win11_25H2_English_x64_v2.iso"
SWTPM_ROOT="$LAB_ROOT/tools/swtpm-root"
SWTPM_BIN="$SWTPM_ROOT/usr/bin/swtpm"
SWTPM_LIB="$SWTPM_ROOT/usr/lib/x86_64-linux-gnu"
ALL_VMS=(appimage deb rpm atomic windows)
LAB_ENGINE_VERSION="$(<"$LAB_ROOT/VERSION")"

usage() {
  cat <<'USAGE'
Usage: ./lab.sh COMMAND [VM] [NAME]

Commands:
  init [VM]              Create seed, sparse disk, and UEFI state (default: all)
  start VM               Boot an installed/cloud guest
  install-atomic         Boot the Silverblue installer ISO
  install-windows        Boot the unattended Windows 11 installer
  wait VM                Wait for guest provisioning to finish
  verify VM              Report platform, Podman, and readiness state
  ssh VM                 Open an SSH session
  run VM COMMAND...      Run a noninteractive command over the lab SSH connection
  copy-to VM SRC DEST    Copy one host file into a guest
  copy-from VM SRC DEST  Copy one guest file onto the host
  send-keys VM KEY...    Send QEMU key names to the graphical console in sequence
  screenshot VM DEST    Capture the graphical console as .ppm or .png
  viewer VM              Open the SPICE graphical console
  stop VM                Gracefully power off the guest
  snapshot VM [NAME]     Save a stopped guest as clean or a new named checkpoint
  snapshots VM           List clean and named checkpoints
  reset VM [NAME]        Archive its active overlay and restore clean or named state
  status [VM]            Show one or all VM processes and connection ports

VMs: appimage, deb, rpm, atomic, windows
USAGE
}

resolve_vm() {
  VM="${1:?VM is required}"
  case "$VM" in
    ubuntu) VM=appimage ;;
    debian) VM=deb ;;
    fedora) VM=rpm ;;
    silverblue) VM=atomic ;;
  esac
  CLOUD_GUEST=false
  WINDOWS_GUEST=false
  OVMF_CODE="/usr/share/OVMF/OVMF_CODE_4M.fd"
  OVMF_VARS_TEMPLATE="/usr/share/OVMF/OVMF_VARS_4M.fd"
  case "$VM" in
    appimage)
      VM_NAME="omnideck-appimage-ubuntu-24.04"
      BASE_IMAGE="$IMAGE_DIR/noble-server-cloudimg-amd64.img"
      USER_DATA="$LAB_ROOT/cloud-init/appimage-user-data.yaml"
      SSH_PORT=2221
      SPICE_PORT=5931
      MEMORY_MB=6144
      DISK_GB=50
      CLOUD_GUEST=true
      ;;
    deb)
      VM_NAME="omnideck-deb-debian-13"
      BASE_IMAGE="$IMAGE_DIR/debian-13-genericcloud-amd64.qcow2"
      USER_DATA="$LAB_ROOT/cloud-init/deb-user-data.yaml"
      SSH_PORT=2222
      SPICE_PORT=5932
      MEMORY_MB=6144
      DISK_GB=50
      CLOUD_GUEST=true
      ;;
    rpm)
      VM_NAME="omnideck-rpm-fedora-44"
      BASE_IMAGE="$IMAGE_DIR/Fedora-Cloud-Base-Generic-44-1.7.x86_64.qcow2"
      USER_DATA="$LAB_ROOT/cloud-init/rpm-user-data.yaml"
      SSH_PORT=2223
      SPICE_PORT=5933
      MEMORY_MB=6144
      DISK_GB=50
      CLOUD_GUEST=true
      ;;
    atomic)
      VM_NAME="omnideck-atomic-silverblue-44"
      BASE_IMAGE=""
      USER_DATA=""
      SSH_PORT=2224
      SPICE_PORT=5934
      MEMORY_MB=8192
      DISK_GB=60
      CLOUD_GUEST=false
      ;;
    windows)
      VM_NAME="omnideck-windows-11-25h2"
      BASE_IMAGE=""
      USER_DATA=""
      SSH_PORT=2225
      SPICE_PORT=5935
      MEMORY_MB=8192
      DISK_GB=100
      WINDOWS_GUEST=true
      OVMF_CODE="/usr/share/OVMF/OVMF_CODE_4M.secboot.fd"
      OVMF_VARS_TEMPLATE="/usr/share/OVMF/OVMF_VARS_4M.ms.fd"
      ;;
    *)
      echo "Unknown VM: $VM" >&2
      exit 2
      ;;
  esac

  DISK="$DISK_DIR/${VM}.qcow2"
  GOLDEN_DISK="$GOLDEN_DIR/${VM}-clean.qcow2"
  VARS="$RUNTIME_DIR/${VM}-OVMF_VARS.fd"
  GOLDEN_VARS="$GOLDEN_DIR/${VM}-clean-OVMF_VARS.fd"
  SEED="$SEED_DIR/${VM}-seed.iso"
  PID_FILE="$RUNTIME_DIR/${VM}.pid"
  MONITOR_SOCKET="$RUNTIME_DIR/${VM}.monitor.sock"
  AGENT_SOCKET="$RUNTIME_DIR/${VM}.agent.sock"
  SERIAL_LOG="$LAB_ROOT/logs/${VM}-serial.log"
  QEMU_LOG="$LAB_ROOT/logs/${VM}-qemu.log"
  TPM_STATE="$RUNTIME_DIR/${VM}-tpm"
  GOLDEN_TPM_STATE="$GOLDEN_DIR/${VM}-clean-tpm"
  TPM_SOCKET="$RUNTIME_DIR/${VM}-swtpm.sock"
  TPM_PID_FILE="$RUNTIME_DIR/${VM}-swtpm.pid"
  TPM_LOG="$LAB_ROOT/logs/${VM}-swtpm.log"
}

validate_checkpoint_name() {
  local name="$1"
  [[ "$name" != clean && "$name" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || {
    echo "Invalid checkpoint name: $name (use lowercase letters, numbers, '.', '_' or '-'; 'clean' is reserved)." >&2
    exit 2
  }
}

archive_file() {
  local path="$1"
  [[ -e "$path" ]] || return 0
  local destination_root="$DISCARDED_DIR/legacy"
  if [[ -n "${OMNIDECK_VM_LAB_TRANSACTION_DIR:-}" ]]; then
    case "$OMNIDECK_VM_LAB_TRANSACTION_DIR" in
      "$DISCARDED_DIR"/runs/*) destination_root="$OMNIDECK_VM_LAB_TRANSACTION_DIR/state" ;;
      *) echo "Unsafe transaction directory: $OMNIDECK_VM_LAB_TRANSACTION_DIR" >&2; exit 2 ;;
    esac
  fi
  mkdir -p "$destination_root"
  local stamp destination size kind
  stamp="$(date -u +%Y%m%dT%H%M%S.%NZ)-$$-${RANDOM}"
  destination="$destination_root/$(basename "$path").${stamp}"
  size="$(du -sb -- "$path" 2>/dev/null | awk '{print $1}')"
  [[ -n "$size" ]] || size=0
  if [[ -d "$path" ]]; then kind=directory; else kind=file; fi
  mv -- "$path" "$destination"
  if [[ -n "${OMNIDECK_VM_LAB_TRANSACTION_DIR:-}" ]]; then
    printf '%s\t%s\t%s\t%s\n' "$kind" "$size" "$path" "$destination" >> "$OMNIDECK_VM_LAB_TRANSACTION_DIR/state-index.tsv"
  fi
}

is_running() {
  [[ -f "$PID_FILE" ]] || return 1
  local pid
  pid="$(<"$PID_FILE")"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  [[ -r "/proc/$pid/cmdline" ]] || return 1
  local process_command
  process_command="$(tr '\0' ' ' < "/proc/$pid/cmdline")"
  [[ "$process_command" == *qemu-system-* && "$process_command" == *"$VM_NAME"* ]]
}

rotate_log() {
  local path="$1"
  local maximum_bytes=$((8 * 1024 * 1024))
  local retained_bytes=$((2 * 1024 * 1024))
  [[ -f "$path" ]] || return 0
  local size
  size="$(stat -c %s "$path")"
  ((size <= maximum_bytes)) && return 0
  local temporary
  temporary="$(mktemp "$LAB_ROOT/logs/.rotate.XXXXXX")"
  tail -c "$retained_bytes" -- "$path" > "$temporary"
  mv -- "$temporary" "$path"
}

stop_tpm() {
  [[ "$WINDOWS_GUEST" == true ]] || return 0
  if [[ -f "$TPM_PID_FILE" ]]; then
    local tpm_pid
    tpm_pid="$(<"$TPM_PID_FILE")"
    if [[ "$tpm_pid" =~ ^[0-9]+$ ]] && kill -0 "$tpm_pid" 2>/dev/null; then
      kill -TERM "$tpm_pid" 2>/dev/null || true
      for _ in $(seq 1 20); do
        kill -0 "$tpm_pid" 2>/dev/null || break
        sleep 0.1
      done
    fi
    unlink "$TPM_PID_FILE" 2>/dev/null || true
  fi
  [[ -e "$TPM_SOCKET" ]] && unlink "$TPM_SOCKET"
  return 0
}

init_one() {
  resolve_vm "$1"
  mkdir -p "$SEED_DIR" "$DISK_DIR" "$GOLDEN_DIR" "$RUNTIME_DIR" "$DISCARDED_DIR" "$LAB_ROOT/logs"

  if [[ ! -f "$VARS" ]]; then
    if [[ -f "$GOLDEN_VARS" ]]; then
      cp -- "$GOLDEN_VARS" "$VARS"
    else
      cp -- "$OVMF_VARS_TEMPLATE" "$VARS"
    fi
  fi

  if [[ "$CLOUD_GUEST" == true && ! -f "$SEED" ]]; then
    cloud-localds "$SEED" "$USER_DATA"
  elif [[ "$VM" == atomic && ! -f "$SEED" ]]; then
    [[ -f "$ATOMIC_KICKSTART" ]] || { echo "Missing kickstart: $ATOMIC_KICKSTART" >&2; exit 1; }
    genisoimage -quiet -R -V OEMDRV -o "$SEED" -graft-points "ks.cfg=$ATOMIC_KICKSTART"
  elif [[ "$WINDOWS_GUEST" == true && ! -f "$SEED" ]]; then
    [[ -f "$WINDOWS_UNATTEND" ]] || { echo "Missing answer file: $WINDOWS_UNATTEND" >&2; exit 1; }
    [[ -f "$WINDOWS_PROVISION" ]] || { echo "Missing provisioning script: $WINDOWS_PROVISION" >&2; exit 1; }
    genisoimage -quiet -J -R -V OMNIDECKSEED -o "$SEED" -graft-points \
      "Autounattend.xml=$WINDOWS_UNATTEND" \
      "provision.ps1=$WINDOWS_PROVISION"
  fi

  if [[ "$WINDOWS_GUEST" == true && ! -d "$TPM_STATE" ]]; then
    if [[ -d "$GOLDEN_TPM_STATE" ]]; then
      cp -a -- "$GOLDEN_TPM_STATE" "$TPM_STATE"
    else
      mkdir -p "$TPM_STATE"
    fi
    chmod 700 "$TPM_STATE"
  fi

  if [[ ! -f "$DISK" ]]; then
    if [[ -f "$GOLDEN_DISK" ]]; then
      qemu-img create -q -f qcow2 -F qcow2 -b "$GOLDEN_DISK" "$DISK"
    elif [[ "$CLOUD_GUEST" == true ]]; then
      [[ -f "$BASE_IMAGE" ]] || { echo "Missing base image: $BASE_IMAGE" >&2; exit 1; }
      qemu-img create -q -f qcow2 -F qcow2 -b "$BASE_IMAGE" "$DISK" "${DISK_GB}G"
    else
      qemu-img create -q -f qcow2 "$DISK" "${DISK_GB}G"
    fi
  fi
  chmod 600 "$DISK" "$VARS"
  echo "$VM initialized: $DISK"
}

start_one() {
  resolve_vm "$1"
  local installer="${2:-false}"
  init_one "$VM"
  if is_running; then
    echo "$VM is already running (PID $(<"$PID_FILE"))."
    return 0
  fi
  unlink "$PID_FILE" 2>/dev/null || true
  [[ -e "$MONITOR_SOCKET" ]] && unlink "$MONITOR_SOCKET"
  [[ -e "$AGENT_SOCKET" ]] && unlink "$AGENT_SOCKET"
  rotate_log "$SERIAL_LOG"
  rotate_log "$QEMU_LOG"
  [[ "$WINDOWS_GUEST" == true ]] && rotate_log "$TPM_LOG"

  local -a media_args=()
  if [[ "$CLOUD_GUEST" == true ]]; then
    media_args+=( -drive "file=$SEED,format=raw,if=virtio,readonly=on" )
  elif [[ "$VM" == atomic && "$installer" == true ]]; then
    media_args+=(
      -drive "file=$IMAGE_DIR/Fedora-Silverblue-ostree-x86_64-44-1.7.iso,media=cdrom,readonly=on"
      -drive "file=$SEED,format=raw,media=cdrom,readonly=on"
      -boot order=d,menu=on
    )
  elif [[ "$WINDOWS_GUEST" == true && "$installer" == true ]]; then
    [[ -f "$WINDOWS_ISO" ]] || { echo "Missing Windows ISO: $WINDOWS_ISO" >&2; exit 1; }
    media_args+=(
      -drive "file=$WINDOWS_ISO,media=cdrom,readonly=on"
      -drive "file=$SEED,format=raw,media=cdrom,readonly=on"
      -boot order=d,menu=on
    )
  elif [[ "$WINDOWS_GUEST" == true ]]; then
    media_args+=(
      -drive "file=$SEED,format=raw,media=cdrom,readonly=on"
      -boot order=c,menu=on
    )
  else
    media_args+=( -boot order=c,menu=on )
  fi

  local -a firmware_args=(
    -machine q35,accel=kvm
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE"
    -drive "if=pflash,format=raw,file=$VARS"
  )
  local -a disk_args=( -drive "file=$DISK,format=qcow2,if=virtio,cache=none,discard=unmap" )
  local -a network_args=( -device virtio-net-pci,netdev=net0 )
  local -a input_args=( -device qemu-xhci -device usb-tablet )
  if [[ "$VM" == deb ]]; then
    # Debian's genericcloud kernel disables USB support but includes virtio-input.
    # Use a virtio tablet so SPICE viewers can deliver pointer events to GNOME.
    input_args=( -device virtio-tablet )
  fi
  local -a display_args=(
    -device virtio-vga
    -device virtio-rng-pci
    "${input_args[@]}"
    -device virtio-serial-pci
    -chardev spicevmc,id=vdagent,name=vdagent
    -device virtserialport,chardev=vdagent,name=com.redhat.spice.0
    -chardev "socket,path=$AGENT_SOCKET,server=on,wait=off,id=qga0"
    -device virtserialport,chardev=qga0,name=org.qemu.guest_agent.0
  )
  local -a tpm_args=()

  if [[ "$WINDOWS_GUEST" == true ]]; then
    [[ -x "$SWTPM_BIN" ]] || { echo "Missing lab-local swtpm: $SWTPM_BIN" >&2; exit 1; }
    stop_tpm
    mkdir -p "$TPM_STATE"
    chmod 700 "$TPM_STATE"
    LD_LIBRARY_PATH="$SWTPM_LIB:$SWTPM_LIB/swtpm${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
      "$SWTPM_BIN" socket \
        --tpm2 \
        --tpmstate "dir=$TPM_STATE,mode=0600" \
        --ctrl "type=unixio,path=$TPM_SOCKET,mode=0600" \
        --pid "file=$TPM_PID_FILE" \
        --log "file=$TPM_LOG,level=5" \
        --terminate \
        --daemon
    for _ in $(seq 1 50); do
      [[ -S "$TPM_SOCKET" ]] && break
      sleep 0.1
    done
    [[ -S "$TPM_SOCKET" ]] || { echo "swtpm did not create $TPM_SOCKET" >&2; exit 1; }

    firmware_args=(
      -machine q35,accel=kvm,smm=on
      -global driver=cfi.pflash01,property=secure,value=on
      -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE"
      -drive "if=pflash,format=raw,file=$VARS"
    )
    disk_args=(
      -drive "file=$DISK,format=qcow2,if=none,id=osdisk,cache=none,discard=unmap"
      -device nvme,drive=osdisk,serial=OMNIDECK-WIN11
    )
    network_args=( -device e1000,netdev=net0 )
    display_args=( -device VGA -device qemu-xhci -device usb-tablet )
    tpm_args=(
      -chardev "socket,id=chrtpm,path=$TPM_SOCKET"
      -tpmdev emulator,id=tpm0,chardev=chrtpm
      -device tpm-crb,tpmdev=tpm0
    )
  fi

  if ! qemu-system-x86_64 \
    -name "$VM_NAME" \
    -enable-kvm \
    "${firmware_args[@]}" \
    -cpu host \
    -smp 4 \
    -m "$MEMORY_MB" \
    -nodefaults \
    "${disk_args[@]}" \
    "${media_args[@]}" \
    -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22" \
    "${network_args[@]}" \
    "${display_args[@]}" \
    "${tpm_args[@]}" \
    -spice "addr=127.0.0.1,port=$SPICE_PORT,disable-ticketing=on" \
    -display none \
    -serial "file:$SERIAL_LOG" \
    -monitor "unix:$MONITOR_SOCKET,server=on,wait=off" \
    -D "$QEMU_LOG" \
    -daemonize \
    -pidfile "$PID_FILE"; then
    stop_tpm
    return 1
  fi

  if [[ "$WINDOWS_GUEST" == true && "$installer" == true ]]; then
    command -v socat >/dev/null || { echo "socat is required to start the Windows installer." >&2; exit 1; }
    for _ in $(seq 1 8); do
      sleep 1
      printf 'sendkey spc\n' | socat - UNIX-CONNECT:"$MONITOR_SOCKET" >/dev/null 2>&1 || true
    done
  fi

  echo "$VM started: SSH 127.0.0.1:$SSH_PORT, SPICE 127.0.0.1:$SPICE_PORT"
}

ssh_args() {
  printf '%s\n' -i "$KEY" -p "$SSH_PORT" -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$RUNTIME_DIR/known_hosts"
}

scp_args() {
  printf '%s\n' -i "$KEY" -P "$SSH_PORT" -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$RUNTIME_DIR/known_hosts"
}

ssh_run() {
  local -a args=()
  mapfile -t args < <(ssh_args)
  ssh "${args[@]}" tester@127.0.0.1 "$@"
}

copy_to_one() {
  resolve_vm "$1"
  local source="$2"
  local destination="$3"
  [[ -f "$source" ]] || { echo "Host file does not exist: $source" >&2; exit 1; }
  local -a args=()
  mapfile -t args < <(scp_args)
  scp "${args[@]}" -- "$source" "tester@127.0.0.1:$destination"
}

copy_from_one() {
  resolve_vm "$1"
  local source="$2"
  local destination="$3"
  local -a args=()
  mapfile -t args < <(scp_args)
  scp "${args[@]}" -- "tester@127.0.0.1:$source" "$destination"
}

monitor_command() {
  command -v socat >/dev/null || { echo "socat is required for monitor commands." >&2; exit 2; }
  printf '%s\n' "$1" | socat - "UNIX-CONNECT:$MONITOR_SOCKET" >/dev/null
}

send_keys_one() {
  resolve_vm "$1"
  shift
  is_running || { echo "$VM is not running." >&2; exit 1; }
  [[ "$#" -gt 0 ]] || { echo "At least one KEY is required." >&2; exit 2; }
  local key
  for key in "$@"; do
    [[ "$key" =~ ^[a-zA-Z0-9_+-]+$ ]] || { echo "Invalid QEMU key name: $key" >&2; exit 2; }
    monitor_command "sendkey $key"
    sleep 0.15
  done
}

screenshot_one() {
  resolve_vm "$1"
  local requested="$2"
  is_running || { echo "$VM is not running." >&2; exit 1; }
  [[ "$requested" = /* ]] || { echo "Screenshot destination must be an absolute path." >&2; exit 2; }
  [[ "$requested" != *[[:space:]]* ]] || { echo "Screenshot destination cannot contain whitespace." >&2; exit 2; }
  local destination_dir
  destination_dir="$(dirname "$requested")"
  [[ -d "$destination_dir" ]] || { echo "Screenshot directory does not exist: $destination_dir" >&2; exit 1; }

  case "$requested" in
    *.ppm)
      monitor_command "screendump $requested"
      ;;
    *.png)
      command -v ffmpeg >/dev/null || { echo "ffmpeg is required for PNG screenshots." >&2; exit 2; }
      local temporary
      temporary="$(mktemp "$destination_dir/.omnideck-screen.XXXXXX.ppm")"
      if ! monitor_command "screendump $temporary" ||
        ! ffmpeg -nostdin -loglevel error -y -i "$temporary" "$requested"; then
        unlink "$temporary" 2>/dev/null || true
        return 1
      fi
      unlink "$temporary"
      ;;
    *)
      echo "Screenshot destination must end in .ppm or .png." >&2
      exit 2
      ;;
  esac
  echo "$VM screenshot saved: $requested"
}

wait_one() {
  resolve_vm "$1"
  if [[ "$WINDOWS_GUEST" == true ]]; then
    echo "Waiting for Windows installation and provisioning (typically 15-40 minutes)..."
    local windows_attempt
    for windows_attempt in $(seq 1 360); do
      if ssh_run 'if exist C:\omnideck-lab-ready (exit /b 0) else (exit /b 1)' 2>/dev/null; then
        echo "$VM provisioning complete."
        return 0
      fi
      sleep 10
    done
    echo "Timed out waiting for $VM; use ./lab.sh viewer windows" >&2
    return 1
  fi
  if [[ "$VM" == atomic ]]; then
    echo "Waiting for the installed atomic guest to become ready..."
    local atomic_attempt
    for atomic_attempt in $(seq 1 180); do
      if ssh_run 'test -f /var/lib/omnideck-lab-ready && systemctl is-system-running --wait 2>/dev/null | grep -Eq "^(running|degraded)$"' 2>/dev/null; then
        echo "$VM provisioning complete."
        return 0
      fi
      sleep 2
    done
    echo "Timed out waiting for $VM; use ./lab.sh viewer atomic" >&2
    return 1
  fi
  [[ "$CLOUD_GUEST" == true ]] || { echo "Unsupported wait workflow for $VM."; return 1; }
  echo "Waiting for $VM provisioning (desktop package installation can take 20-40 minutes)..."
  local attempt
  for attempt in $(seq 1 240); do
    if ssh_run 'test -f /var/lib/omnideck-lab-ready && cloud-init status --format json 2>/dev/null | grep -q '"'"'status'"'"'.*'"'"'done'"'"'' 2>/dev/null; then
      echo "$VM provisioning complete."
      return 0
    fi
    sleep 10
  done
  echo "Timed out waiting for $VM; inspect $SERIAL_LOG" >&2
  return 1
}

verify_one() {
  resolve_vm "$1"
  if [[ "$WINDOWS_GUEST" == true ]]; then
    ssh_run powershell.exe -NoProfile -NonInteractive -Command - <<'POWERSHELL'
$os = Get-CimInstance Win32_OperatingSystem
$podman = Get-Command podman -ErrorAction SilentlyContinue
$tpm = Get-Tpm
Write-Output ("os=" + $os.Caption + " " + $os.Version)
Write-Output ("display_version=" + (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').DisplayVersion)
Write-Output ("secure_boot=" + (Confirm-SecureBootUEFI))
Write-Output ("tpm_present=" + $tpm.TpmPresent)
Write-Output ("tpm_ready=" + $tpm.TpmReady)
Write-Output ("podman=" + $(if ($podman) { $podman.Source } else { 'absent' }))
Write-Output ("sshd=" + (Get-Service sshd).Status)
Write-Output ("ready_marker=" + (Test-Path 'C:\omnideck-lab-ready'))
POWERSHELL
    return
  fi
  ssh_run 'set -e; . /etc/os-release; printf "os=%s %s\n" "$NAME" "$VERSION_ID"; printf "desktop_target="; systemctl get-default; printf "display_manager="; systemctl is-enabled display-manager 2>/dev/null || true; printf "podman="; if command -v podman >/dev/null; then command -v podman; else echo absent; fi; printf "ready_marker="; test -f /var/lib/omnideck-lab-ready && echo yes || echo no; printf "cloud_init="; cloud-init status 2>/dev/null || echo n/a'
}

stop_one() {
  resolve_vm "$1"
  if ! is_running; then
    echo "$VM is already stopped."
    return 0
  fi
  local pid
  pid="$(<"$PID_FILE")"
  if [[ "$WINDOWS_GUEST" == true ]]; then
    ssh_run 'shutdown.exe /s /t 0 /f' >/dev/null 2>&1 || kill -TERM "$pid" 2>/dev/null || true
  else
    ssh_run 'sudo systemctl poweroff' >/dev/null 2>&1 || kill -TERM "$pid" 2>/dev/null || true
  fi
  for _ in $(seq 1 60); do
    kill -0 "$pid" 2>/dev/null || { unlink "$PID_FILE" 2>/dev/null || true; stop_tpm; echo "$VM stopped."; return 0; }
    sleep 2
  done
  echo "$VM did not stop within two minutes." >&2
  return 1
}

snapshot_one() {
  resolve_vm "$1"
  stop_one "$VM"
  archive_file "$GOLDEN_DISK"
  archive_file "$GOLDEN_VARS"
  mv -- "$DISK" "$GOLDEN_DISK"
  cp -- "$VARS" "$GOLDEN_VARS"
  if [[ "$WINDOWS_GUEST" == true ]]; then
    archive_file "$GOLDEN_TPM_STATE"
    cp -a -- "$TPM_STATE" "$GOLDEN_TPM_STATE"
  fi
  qemu-img create -q -f qcow2 -F qcow2 -b "$GOLDEN_DISK" "$DISK"
  echo "$VM clean snapshot saved."
}

snapshot_named() {
  resolve_vm "$1"
  local name="$2"
  validate_checkpoint_name "$name"
  local checkpoint_dir="$GOLDEN_DIR/$VM/$name"
  local checkpoint_disk="$checkpoint_dir/disk.qcow2"
  local checkpoint_vars="$checkpoint_dir/OVMF_VARS.fd"
  [[ ! -e "$checkpoint_dir" ]] || {
    echo "Checkpoint already exists: $VM/$name (refusing to overwrite it)." >&2
    exit 1
  }

  stop_one "$VM"
  [[ -f "$DISK" ]] || { echo "No active disk for $VM." >&2; exit 1; }
  [[ -f "$VARS" ]] || { echo "No active UEFI state for $VM." >&2; exit 1; }
  mkdir -p "$GOLDEN_DIR/$VM"
  local temp_dir
  temp_dir="$(mktemp -d "$GOLDEN_DIR/$VM/.${name}.tmp.XXXXXX")"
  if ! cp -- "$DISK" "$temp_dir/disk.qcow2" || ! cp -- "$VARS" "$temp_dir/OVMF_VARS.fd"; then
    rm -rf -- "$temp_dir"
    return 1
  fi
  if [[ "$WINDOWS_GUEST" == true ]]; then
    [[ -d "$TPM_STATE" ]] || { rm -rf -- "$temp_dir"; echo "No active TPM state for $VM." >&2; exit 1; }
    cp -a -- "$TPM_STATE" "$temp_dir/tpm"
  fi
  printf '{\n  "schemaVersion": 1,\n  "vm": "%s",\n  "name": "%s",\n  "createdAt": "%s",\n  "engineVersion": "%s"\n}\n' \
    "$VM" "$name" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LAB_ENGINE_VERSION" > "$temp_dir/metadata.json"
  qemu-img info --output=json "$temp_dir/disk.qcow2" > "$temp_dir/disk-info.json"
  mv -- "$temp_dir" "$checkpoint_dir"
  echo "$VM named snapshot saved: $name."
}

list_snapshots_one() {
  resolve_vm "$1"
  echo "$VM snapshots:"
  echo "clean"
  if [[ -d "$GOLDEN_DIR/$VM" ]]; then
    find "$GOLDEN_DIR/$VM" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort
  fi
}

reset_one() {
  resolve_vm "$1"
  local name="${2:-clean}"
  local source_disk="$GOLDEN_DISK"
  local source_vars="$GOLDEN_VARS"
  local source_tpm="$GOLDEN_TPM_STATE"
  if [[ "$name" != clean ]]; then
    validate_checkpoint_name "$name"
    local checkpoint_dir="$GOLDEN_DIR/$VM/$name"
    source_disk="$checkpoint_dir/disk.qcow2"
    source_vars="$checkpoint_dir/OVMF_VARS.fd"
    source_tpm="$checkpoint_dir/tpm"
  fi
  [[ -f "$source_disk" ]] || { echo "No $name snapshot for $VM." >&2; exit 1; }
  [[ -f "$source_vars" ]] || { echo "No UEFI state for $VM/$name snapshot." >&2; exit 1; }
  if [[ "$WINDOWS_GUEST" == true ]]; then
    [[ -d "$source_tpm" ]] || { echo "No TPM state for $VM/$name snapshot." >&2; exit 1; }
  fi
  stop_one "$VM"
  archive_file "$DISK"
  qemu-img create -q -f qcow2 -F qcow2 -b "$source_disk" "$DISK"
  cp -- "$source_vars" "$VARS"
  if [[ "$WINDOWS_GUEST" == true ]]; then
    archive_file "$TPM_STATE"
    cp -a -- "$source_tpm" "$TPM_STATE"
  fi
  echo "$VM reset to its $name snapshot."
}

status_one() {
  resolve_vm "$1"
  if is_running; then
    echo "$VM running pid=$(<"$PID_FILE") ssh=$SSH_PORT spice=$SPICE_PORT"
  else
    echo "$VM stopped ssh=$SSH_PORT spice=$SPICE_PORT"
  fi
}

command="${1:-}"
case "$command" in
  init)
    if [[ -n "${2:-}" ]]; then init_one "$2"; else for vm in "${ALL_VMS[@]}"; do init_one "$vm"; done; fi
    ;;
  start) start_one "${2:?VM is required}" ;;
  install-atomic) start_one atomic true ;;
  install-windows) start_one windows true ;;
  wait) wait_one "${2:?VM is required}" ;;
  verify) verify_one "${2:?VM is required}" ;;
  ssh)
    resolve_vm "${2:?VM is required}"
    mapfile -t args < <(ssh_args)
    exec ssh "${args[@]}" tester@127.0.0.1
    ;;
  run)
    resolve_vm "${2:?VM is required}"
    shift 2
    [[ "$#" -gt 0 ]] || { echo "COMMAND is required." >&2; exit 2; }
    ssh_run "$@"
    ;;
  copy-to) copy_to_one "${2:?VM is required}" "${3:?SRC is required}" "${4:?DEST is required}" ;;
  copy-from) copy_from_one "${2:?VM is required}" "${3:?SRC is required}" "${4:?DEST is required}" ;;
  send-keys)
    vm="${2:?VM is required}"
    shift 2
    send_keys_one "$vm" "$@"
    ;;
  screenshot) screenshot_one "${2:?VM is required}" "${3:?DEST is required}" ;;
  viewer)
    resolve_vm "${2:?VM is required}"
    exec remote-viewer "spice://127.0.0.1:$SPICE_PORT"
    ;;
  stop) stop_one "${2:?VM is required}" ;;
  snapshot)
    if [[ -n "${3:-}" ]]; then snapshot_named "${2:?VM is required}" "$3"; else snapshot_one "${2:?VM is required}"; fi
    ;;
  snapshots)
    if [[ -n "${2:-}" ]]; then list_snapshots_one "$2"; else for vm in "${ALL_VMS[@]}"; do list_snapshots_one "$vm"; done; fi
    ;;
  reset) reset_one "${2:?VM is required}" "${3:-clean}" ;;
  status)
    if [[ -n "${2:-}" ]]; then status_one "$2"; else for vm in "${ALL_VMS[@]}"; do status_one "$vm"; done; fi
    ;;
  --help|-h|help|'') usage ;;
  *) echo "Unknown command: $command" >&2; usage >&2; exit 2 ;;
esac
