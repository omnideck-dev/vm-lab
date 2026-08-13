# Architecture and ownership

The lab has three storage classes:

- `base-images/` and `golden/` are durable, reviewed inputs.
- `disks/`, `runtime/`, and `logs/` are current machine state.
- `discarded/runs/` and `artifacts/` are short-lived run output.

`lab.sh` is the only public controller. `lab-engine.sh` contains QEMU-specific
mechanics and is not called directly by operators or consumer scripts.

## Leases

`lab.sh lease VM OWNER RUN_ID -- COMMAND...` takes the single lock for a lane,
records owner metadata under `runtime/leases/`, verifies that the guest was
stopped while holding the lock, and invokes the command with lease and
transaction environment variables. Descendants, including QEMU, inherit the
lock descriptor. Consumer scripts therefore re-execute themselves through the
lease before checking state or resetting a guest.

Manual and automated work use the same API. Private `/tmp` lock names are not
part of the contract.

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

The complete five-lane configuration requests 34 GiB of guest RAM and 20
virtual CPUs. Run only the lanes required by the current matrix. `status` shows
ownership, while `doctor` reports health and low-space conditions.
