---
type: fixed
area: baselines
---

Linux onboarding baselines now clear saved omnideck desktop and CLI
configuration while preserving unrelated tester settings. Certification rejects
leftover application state so a fresh-install test cannot silently use an old
instance or enter recovery for missing data volumes. Rebuild contaminated
checkpoints under a new immutable name and certify them before selecting them
in a profile. Linux onboarding and release-clean profiles select new `onboarding-clean-v2` checkpoints; existing checkpoints are preserved.
