# Repository guide

- This repository contains controller source only. Never commit deployed lab state, images, credentials, keys, or non-example host configuration.
- Run `./tests/lab_test.sh` before handoff.
- For live lab work, set `OMNIDECK_VM_LAB_DIR=/mnt/data/VMs/omnideck-release-lab`, run strict preflight, and perform guest or host mutations only through a cleanup-owning `lab.sh lease`. See `README.md` and `docs/consumers.md` for the consumer test entry points.
