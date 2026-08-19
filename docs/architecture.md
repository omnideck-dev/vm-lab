# Architecture and ownership

The lab separates durable inputs and generated data:

- `base-images/` and `golden/` are durable, reviewed inputs.
- `disks/`, `runtime/`, and `logs/` are current machine state.
- `artifacts/`, `cache/`, and `discarded/runs/` are the generated evidence,
  immutable prepared inputs, and retained reset state.

`lab.sh` is the only public controller. `lab-engine.sh` contains QEMU-specific
mechanics, while `lab-host.sh` contains SSH mechanics for physical hosts.
Neither backend is called directly by operators or consumer scripts.

## Leases

`lab.sh lease VM OWNER RUN_ID -- COMMAND...` takes the single lock for a lane,
records owner metadata under `runtime/leases/`, verifies that the guest was
stopped while holding the lock, and invokes the command with lease and
transaction environment variables. Descendants, including QEMU, inherit the
lock descriptor. Consumer scripts therefore re-execute themselves through the
lease before checking state or resetting a guest.

Manual and automated work use the same API. Private `/tmp` lock names are not
part of the contract.

The `macos-arm64` physical-host lease uses the same ownership lock and metadata
but does not create a disk transaction. Its SSH alias and remote PATH live in
the deployment-only `hosts/macos-arm64.json`. Its `runtime-ready` reset is a
guarded application-level rollback: it removes the expected OmniDeck bundle,
the checksum-marked lab CLI, known application state and explicitly named
OmniDeck containers/volumes while retaining Podman and its Linux machine. A
cleanup-owning lease runs this rollback after success, failure, or interruption.
Physical hardware has no snapshot, start, stop, or viewer operation.

## Reset transactions

Every archived disk, UEFI, or TPM object produced under a lease is placed in:

```text
discarded/runs/<run-id>-<vm>/
  metadata.json
  state-index.tsv
  state/
```

Successful runs delete this directory immediately. Failure or `--keep-state`
retains it until the configured 48-hour GC boundary. This replaces directory
before/after comparisons and pairs Windows disk and TPM state transactionally.

## Capacity

The complete five-VM configuration requests 34 GiB of guest RAM and 20 virtual
CPUs. The Mac contributes its own 8 GiB physical capacity and therefore should
not run overlapping CLI and Desktop jobs. Run only the lanes required by the
current matrix. `status` shows ownership, while `doctor` reports health and
low-space conditions.

## Controller contract

`lab-manifest.json` versions the VM resources, provisioning inputs and hashes,
storage policy, and deterministic profiles. `install.sh` copies that contract
and writes `controller-install.json` with the source commit, dirty state, and
SHA-256 of every installed controller/provisioning file. Consumers require
controller capabilities and call `preflight`
before doing expensive work or acquiring a guest.

`release-clean` resolves VM lanes to `clean` and the physical Mac to `ready`;
the Mac consumer then requests the stronger `runtime-ready` cleanup contract on
its lease. `dev-fast` never silently falls back from its declared mapping.
Every accepted clean or named baseline has a SHA-256 fingerprint manifest under
`golden/manifests/`. The record describes the baseline disk, UEFI state, TPM
state, and QEMU image metadata; it is not coupled to the mutable controller
manifest. `doctor` validates the current controller and provisioning contract
separately, while `doctor --deep` re-hashes accepted clean images when byte-level
integrity must be re-established.
