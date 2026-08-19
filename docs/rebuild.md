# Rebuild and provenance

Before rebuilding a guest, record:

- source URL, filename, upstream checksum and signature result;
- host QEMU, kernel and firmware versions;
- provisioning source commit and exact command;
- guest OS version and update date;
- `qemu-img info --backing-chain` output;
- post-build `lab.sh verify` output and image SHA-256.

The upstream base filename, digest algorithm/value, and signed verification
record are declared per VM in `lab-manifest.json`. Strict doctor validates that
binding; deep doctor also re-hashes the local multi-gigabyte base images.

Keep those fields in a machine-readable manifest beside the clean golden. Base
image checksum files and verified markers remain in `base-images/`; `doctor`
must be clean before a rebuilt image is accepted.

Capture the controller-owned manifest immediately after accepting a baseline:

```sh
./lab.sh provenance capture appimage clean
./lab.sh provenance capture appimage desktop-e2e-v2
./lab.sh doctor --strict
```

The capture records baseline disk, UEFI, TPM, and QEMU image metadata. A
controller-manifest hash may be retained as capture-time diagnostics, but it is
not a validity gate: changing controller configuration cannot change the bytes
of an already captured baseline. `doctor` validates current controller and
provisioning inputs independently.

`doctor --deep` additionally re-hashes the clean golden disks. Run it after a
rebuild or suspected storage corruption; routine consumers use `--strict` and
validate the recorded manifest without paying that hashing cost.

Build through a dedicated lease, save a new named checkpoint first, boot and
verify it after a reset, and only then schedule clean-golden replacement. Never
rewrite a backing image while an active or named overlay depends on it.
