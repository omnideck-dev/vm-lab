# OmniDeck VM lab controller

This standalone repository is the versioned source for the shared, disposable
release-test lab. Its controller owns
guest leases, reset transactions, checkpoints, evidence metadata, retention,
and health checks. VM images and runtime state remain in a separate deployed
lab directory and must never be added to this repository.

Install or update an existing lab:

```sh
./tests/lab_test.sh
./install.sh /mnt/data/VMs/omnideck-release-lab
export OMNIDECK_VM_LAB_DIR=/mnt/data/VMs/omnideck-release-lab
```

Run `lab.sh status` before using a lane. Every command that can touch a guest
must execute under one lab-owned lease:

```sh
cd "$OMNIDECK_VM_LAB_DIR"
./lab.sh lease ubuntu manual -- bash
./lab.sh start ubuntu
./lab.sh wait ubuntu
./lab.sh verify ubuntu
./lab.sh viewer ubuntu
./lab.sh stop ubuntu
./lab.sh reset ubuntu clean
exit
```

The lease owns a reset transaction. Successful automation deletes its archived
overlays immediately. Failed or explicitly retained state expires after 48
hours unless pinned. Run `./lab.sh gc --dry-run` before applying routine GC.

Useful read-only commands:

```sh
./lab.sh inventory
./lab.sh status --json
./lab.sh describe ubuntu --shell
./lab.sh snapshots
./lab.sh doctor
./lab.sh runs list
./lab.sh gc --dry-run
```

The canonical guest names are `ubuntu`, `debian`, `fedora`, `silverblue`, and
`windows`. Historical aliases `appimage`, `deb`, `rpm`, and `atomic` remain
accepted so older release commands continue to be understandable.

See [architecture](docs/architecture.md), [consumers](docs/consumers.md),
[retention](docs/retention.md), [checkpoints](docs/checkpoints.md),
[rebuild](docs/rebuild.md), and [recovery](docs/recovery.md).
