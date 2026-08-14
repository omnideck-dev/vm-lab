# Checkpoints

`clean` is an immutable baseline through the public controller. The unsafe
legacy form `lab.sh snapshot VM` is disabled. Create named checkpoints inside a
lease:

```sh
./lab.sh lease fedora checkpoint-build build-20260812 \
  --cleanup-baseline clean -- bash
./lab.sh start fedora
./lab.sh wait fedora
# Prepare and verify the intended reusable prerequisite state.
./lab.sh stop fedora
./lab.sh snapshot fedora desktop-e2e-v3
exit
./lab.sh provenance capture fedora desktop-e2e-v3
```

Provenance capture intentionally runs after the lease releases because it
refuses running or leased guests.

New checkpoints contain `metadata.json` and captured `qemu-img` information.
Use `checkpoint adopt` once for a pre-controller checkpoint; it records that
the original creation metadata is unavailable instead of inventing provenance.
Inspect or remove a named checkpoint with:

```sh
./lab.sh checkpoint inspect fedora desktop-e2e-v3
./lab.sh checkpoint adopt fedora legacy-checkpoint
./lab.sh lease fedora maintenance -- \
  ./lab.sh checkpoint delete fedora desktop-e2e-v3
```

Deletion refuses a checkpoint still used by the active overlay. Clean-golden
replacement is an image-rebuild operation and requires updating the tracked
provenance, independently verifying the result, and deploying it outside this
public snapshot interface.

Test the checkpoint first with an explicit `preflight --baseline NAME`. If it is
then selected by a shared profile, update `lab-manifest.json` and run `install.sh`
against the deployed lab. Recapture provenance only when that VM's image or
provisioning contract changes. Profile-only changes do not invalidate baseline
provenance. Then run `lab.sh doctor --strict` and the exact consumer/profile
`lab.sh preflight`.
