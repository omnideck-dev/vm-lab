---
type: fixed
area: windows
---

Windows product and clean-machine onboarding tests use refreshed checkpoints
whose disposable test accounts do not expire, preventing old snapshots from
blocking console sign-in without skipping prerequisite-installation coverage.
Baseline certification establishes the interactive test session before checking
Podman's WSL networking.
