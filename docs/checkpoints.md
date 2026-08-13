# Checkpoints

`clean` is an immutable baseline through the public controller. The unsafe
legacy form `lab.sh snapshot VM` is disabled. Create named checkpoints inside a
lease:

```sh
./lab.sh lease fedora checkpoint-build build-20260812 -- bash -c \
  './lab.sh reset fedora clean && ./lab.sh start fedora && ./lab.sh wait fedora && ./lab.sh snapshot fedora desktop-e2e-v3'
```

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
