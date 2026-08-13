# Recovery

Start with read-only inspection:

```sh
./lab.sh status --json
./lab.sh doctor
./lab.sh gc --dry-run
```

If status reports stale lease metadata but the lock is free, remove only the
reported JSON file. If a lock is held without metadata, inspect the exact lock
with `fuser -v` and the owning process before taking action.

If a PID file exists but its process is not the expected QEMU guest, `doctor`
reports it as stopped; remove the stale PID only while holding that lane's
maintenance lease.

An interrupted reset leaves archived state inside one transaction directory.
Its metadata and `state-index.tsv` identify the original paths. Prefer resetting
from the verified checkpoint instead of manually restoring partial state.

When space is low, apply routine GC first. Use `--all-evidence` only when no
lane is leased and raw historical evidence is intentionally disposable. Never
delete `base-images/`, `golden/`, `disks/`, `keys/`, or active runtime state as
part of evidence cleanup.
