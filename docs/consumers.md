# Consumer matrix

| Consumer | Guests | Baseline | Scope |
|---|---|---|---|
| CLI/TUI E2E | Ubuntu, Debian, Fedora, Windows | `release-clean` profile | Real install, guided TUI, lifecycle and runtime proof |
| Desktop full E2E | Ubuntu, Debian, Fedora, Silverblue, Windows | Explicit `dev-fast` or `release-clean` profile | Packaged launch, setup, hosted app, recovery and lifecycle journeys |
| Desktop package smoke | Any Linux guest selected independently of package type | Explicit profile | Launch-only AppImage, DEB, RPM, or Flatpak compatibility proof |
| Published qualification | Selected full lanes plus optional cross-distro smoke | `release-clean` | Published bytes, provenance, native journeys and optional compatibility cells |
| Native macOS ARM64 | Disposable physical `macos-arm64` host | `ready` plus `runtime-ready` lease cleanup | Direct CLI/app install, native lifecycle, evidence, and scoped rollback |

VM identity describes the distribution. Package identity is separate metadata;
an RPM smoke on Ubuntu is therefore represented as `distro=ubuntu` and
`packageKind=rpm`, not as an RPM VM.

Consumers obtain ports and SSH paths through `lab.sh describe VM --shell`, the
baseline through `lab.sh profile PROFILE VM`, generated paths through
`artifact-path` and `cache-path`, and ownership through `lab.sh lease`. They do
not invent storage paths or scan and delete generated roots directly.

Builds, downloads, and version-coupled drivers finish before the lease is
requested. Their immutable cache keys include source content and pinned build
environment inputs. The guest phase only copies the prepared input, resets,
starts, verifies, tests, and restores clean. `lease --cleanup-baseline clean`
also restores clean after an interrupted consumer.

Every run uses `lab.sh evidence-init`, `evidence-set`, and `evidence-finish`.
The required `run.json` fields are schema version, owner, suite, run ID, source
commit, VM, distro, baseline, start/end times, and final status.

Canonical matrix entry points are `tests/e2e/matrix.sh` for CLI and
`desktop/tests/e2e/candidate-matrix.sh` for Desktop. Cross-distribution Desktop
smoke leases and boots each selected guest once, then runs all selected package
cells against that boot.

The Mac is dedicated to the lab and disposable at the application layer.
Consumers acquire its lease with `--cleanup-baseline runtime-ready`, reset it
before installing exact artifacts, copy evidence back to the controller root,
and rely on the lease to remove the installed app, checksum-marked CLI,
OmniDeck state, staging directories, and explicitly named containers/volumes.
The expensive Podman installation and `omnideck-runtime` Linux machine stay
warm. This is clean-application coverage, not clean-OS or Gatekeeper-download
coverage.

The canonical controller-side entry point is
`automation/macos/run-suite.sh --cli-repo PATH --desktop-repo PATH [--artifact
PATH.dmg]`. It lease-serializes an idempotent host bootstrap, selects the newest
cached DMG when exact bytes are not supplied, and runs both CLI/TUI and Desktop
consumers sequentially because they share the same 8 GB host and warm runtime.
Both consumers run even if the first fails, and the aggregate records each lane
status plus the exact DMG digest under `artifacts/macos/aggregate/`.
