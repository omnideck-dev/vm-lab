# Rebuild and provenance

Before rebuilding a guest, record:

- source URL, filename, upstream checksum and signature result;
- host QEMU, kernel and firmware versions;
- provisioning source commit and exact command;
- guest OS version and update date;
- `qemu-img info --backing-chain` output;
- post-build `lab.sh verify` output and image SHA-256.

Keep those fields in a machine-readable manifest beside the clean golden. Base
image checksum files and verified markers remain in `base-images/`; `doctor`
must be clean before a rebuilt image is accepted.

Build through a dedicated lease, save a new named checkpoint first, boot and
verify it after a reset, and only then schedule clean-golden replacement. Never
rewrite a backing image while an active or named overlay depends on it.
