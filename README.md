# OmniDeck VM lab controller

This standalone repository is the versioned source for the shared, disposable
release-test lab. Its controller owns
guest leases, reset transactions, checkpoints, evidence metadata, retention,
health checks, and a leased native Apple Silicon host. VM images, physical-host
connection settings, and runtime state remain in a separate deployed lab
directory and must never be added to this repository.

Install or update an existing lab:

```sh
./tests/lab_test.sh
./install.sh /mnt/data/VMs/omnideck-release-lab
export OMNIDECK_VM_LAB_DIR=/mnt/data/VMs/omnideck-release-lab
```

Configure the optional native Mac after installation. Keep its SSH target in
the deployed lab only:

```sh
cp hosts/macos-arm64.example.json hosts/macos-arm64.json
# Edit sshTarget and PATH for this lab, then bootstrap and verify it over SSH.
./automation/macos/bootstrap-host.sh macos-arm64
./automation/macos/run-suite.sh \
  --cli-repo /path/to/omnideck-cli \
  --desktop-repo /path/to/omnideck
./lab.sh preflight desktop release-clean --lanes macos-arm64
./lab.sh lease macos-arm64 manual --cleanup-baseline runtime-ready -- bash
./lab.sh reset macos-arm64 runtime-ready
./lab.sh verify macos-arm64
exit
```

The complete suite bootstraps by default and selects the newest DMG already in
the lab's Desktop cache; pass `--artifact` to pin exact bytes or
`--no-bootstrap` after an intentional separate bootstrap. Bootstrap is
idempotent and lease-serialized. It installs a user-local Node.js ARM64 toolchain, the
lab reset helper, the stable `~/Applications/Omnideck Lab Driver.app`, and a
separate trusted-input extension used for native controls that expose no AXPress
action, then
checks the existing Podman installation and `omnideck-runtime` machine. For
unattended desktop UI tests, grant that driver Accessibility and Screen & System
Audio Recording access once in macOS Privacy & Security. An unchanged driver is
not reinstalled, so those grants survive later bootstrap runs. The input
extension can be updated without changing the helper's permission identity. It also installs
a user LaunchAgent that runs `caffeinate -dimsu` while the dedicated test user is
logged in, keeping the physical lane reachable during long unattended suites.
Unlock the dedicated user's GUI session once before a native run; status,
verification, and strict doctor checks reject a locked session immediately.

Run the strict preflight before using a lane. Every command that can touch a guest
must execute under one lab-owned lease:

```sh
cd "$OMNIDECK_VM_LAB_DIR"
./lab.sh doctor --strict
./lab.sh preflight cli release-clean --lanes appimage,deb,rpm,windows
./lab.sh lease ubuntu manual --cleanup-baseline clean -- bash
./lab.sh start ubuntu
./lab.sh wait ubuntu
./lab.sh verify ubuntu
./lab.sh viewer ubuntu
# Exit after the test; the lease restores the clean baseline even on interruption.
exit
```

The lease owns a reset transaction. Successful automation deletes its archived
overlays immediately. Failed or explicitly retained state and evidence expire
after 48 hours; content-addressed build caches expire after 168 hours. Routine
GC runs after the final lease ends.

All generated lab data has one root and three storage classes:

```text
$OMNIDECK_VM_LAB_DIR/
  artifacts/       run evidence and reports
  cache/           immutable prepared binaries, drivers, and candidates
  discarded/runs/  retained reset transactions
```

Preview or apply cleanup without guessing paths:

```sh
./lab.sh paths --shell
./lab.sh cleanup --dry-run
./lab.sh cleanup --apply
./lab.sh cleanup --all-generated --yes --apply
```

Useful read-only commands:

```sh
./lab.sh inventory
./lab.sh capabilities --json
./lab.sh paths --json
./lab.sh status --json
./lab.sh describe ubuntu --shell
./lab.sh snapshots
./lab.sh doctor --strict
./lab.sh preflight desktop dev-fast --lanes appimage,deb,rpm,atomic,windows
./lab.sh runs list
./lab.sh cleanup --dry-run
```

The canonical guest names are `ubuntu`, `debian`, `fedora`, `silverblue`, and
`windows`. Historical aliases `appimage`, `deb`, `rpm`, and `atomic` remain
accepted so older release commands continue to be understandable.
The physical Apple Silicon target is `macos-arm64`, with `macos` accepted as an
alias. It is a dedicated disposable application host: `reset` removes only the
lab app (`~/Applications/Omnideck Lab.app`), lab-managed CLI, namespaced lab
state, test staging, and namespaced lab containers/volumes. A normal OmniDeck
app, CLI, state, container, and volumes are preserved. Podman and its Linux
machine remain installed and warm. A host lease with
`--cleanup-baseline runtime-ready` runs that reset after success, failure, or
interruption. Physical hardware still has no snapshot, start, stop, or viewer
operation.

`automation/macos/run-suite.sh` is the canonical complete Mac command. It runs
the native CLI/TUI qualification and exact-DMG Desktop Accessibility
qualification, even when the first lane fails, preserving both child logs plus
one aggregate per-lane summary under `artifacts/macos/aggregate/`.

See [architecture](docs/architecture.md), [consumers](docs/consumers.md),
[retention](docs/retention.md), [checkpoints](docs/checkpoints.md),
[rebuild](docs/rebuild.md), and [recovery](docs/recovery.md).
