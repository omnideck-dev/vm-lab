# Consumer matrix

| Consumer | Guests | Baseline | Scope |
|---|---|---|---|
| CLI/TUI E2E | Ubuntu, Debian, Fedora, Windows | `clean` | Real install, guided TUI, lifecycle and runtime proof |
| Desktop full E2E | Ubuntu, Debian, Fedora, Silverblue, Windows | Recommended Desktop checkpoint, falling back to `clean` | Packaged launch, setup, hosted app, recovery and lifecycle journeys |
| Desktop package smoke | Any Linux guest selected independently of package type | Recommended Desktop checkpoint | Launch-only AppImage, DEB, RPM, or Flatpak compatibility proof |
| Published qualification | Selected full lanes plus optional cross-distro smoke | Qualification policy, with Windows and Silverblue clean | Published bytes, provenance, native journeys and optional compatibility cells |

VM identity describes the distribution. Package identity is separate metadata;
an RPM smoke on Ubuntu is therefore represented as `distro=ubuntu` and
`packageKind=rpm`, not as an RPM VM.

Consumers obtain ports and SSH paths through `lab.sh describe VM --shell`, the
baseline through `lab.sh baseline VM cli|desktop`, and ownership through
`lab.sh lease`. They do not scan or delete `discarded/` directly.

Every run uses `lab.sh evidence-init`, `evidence-set`, and `evidence-finish`.
The required `run.json` fields are schema version, owner, suite, run ID, source
commit, VM, distro, baseline, start/end times, and final status.
