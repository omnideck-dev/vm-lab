# OmniDeck Release Lab Changelog

## 2026-08-23

- Added controller 2.4's explicit product/onboarding profiles, scripted golden
  builders and certification, browser-ready image contract, and deterministic
  single-bundle candidate staging.
- Normalized the fixed disposable Linux tester password in every generated
  baseline and made certification verify its exact hash. This prevents older
  source checkpoints from producing goldens that pass metadata checks but
  reject deterministic PolicyKit automation.
- Versioned the stronger certification contract so metadata preflight rejects
  certificates created before credential and live-runtime verification.
- Made the native macOS permission probe wait for its app-bundle screenshot
  helper to finish, preventing successful checks from racing temporary capture
  cleanup and being reported as false permission failures.

## 2026-08-13

- Hardened controller 2.3.1's native Mac automation: bootstrap is lease-
  serialized and automatic from the aggregate suite, the newest cached DMG is
  selected when exact bytes are not supplied, both consumer lanes always run,
  and aggregate evidence records each result. The host now reports a locked
  GUI session as not ready and keeps the dedicated user's session active after
  the one-time unlock instead of allowing late Accessibility timeouts.
- Added controller 2.3's disposable application baseline for the dedicated M1
  host. Native lanes now install the CLI and Desktop app directly, reset before
  testing, and automatically remove managed application files, state, staging,
  and named OmniDeck containers/volumes when their lease exits. Podman and its
  resource-expensive Linux machine remain warm between runs.
- Added a controller-side aggregate macOS suite that runs the source-built
  Darwin ARM64 CLI release contract, attended TUI, unattended lifecycle, exact
  DMG smoke, Accessibility journeys, Custom App, and native host boundaries in
  one command while retaining per-consumer and aggregate evidence.
- Added controller 2.2's leased `macos-arm64` physical-host lane. It verifies
  the native platform and shared Podman runtime over a deployment-local SSH
  target, supports guarded run/copy operations, and participates in status,
  inventory, evidence, and explicit preflight without pretending that physical
  hardware has QEMU snapshot semantics.
- Added a controller-side, idempotent Apple Silicon bootstrap that stages its
  inputs over the configured SSH connection, installs checksum-verified Node 24
  and a stable native Accessibility driver beneath the test user's home,
  configures the test registry policy, and verifies the product-managed
  `omnideck-runtime` Podman machine.
- Added controller 2.1's declarative VM/provisioning manifest, install
  provenance, strict/deep health checks, baseline fingerprints, deterministic
  `dev-fast` and `release-clean` profiles, and a consumer preflight API.
- Centralized evidence, immutable prepared inputs, and reset transactions under
  controller-issued artifact/cache paths. Routine post-lease cleanup now ages
  evidence and failed state after 48 hours and caches after 168 hours; one
  guarded command can remove every generated lab file.
- Added signal-aware lease cleanup so interrupted automation stops and restores
  its owned guest to the requested baseline.
- Replaced consumer-specific `/tmp` locks with one lab-owned lease per guest.
  Lease status now records the owner, run ID, PID, command, working directory,
  backing image, allocated overlay size, and uptime.
- Added transaction-scoped reset archives. Successful runs remove archived
  disk and TPM state immediately; failures expire after 48 hours unless pinned.
- Added versioned evidence metadata, distro-centric aliases, checkpoint
  inspection/adoption/deletion, `doctor`, JSON inventory/status, marked-run
  purge, and dry-run-first garbage collection.
- Purged the accumulated historical evidence and discarded overlays, reducing
  those stores from roughly 57 GB to empty controller-owned roots, and capped
  the oversized Windows TPM log.
- Adopted explicit legacy provenance metadata for all existing named
  checkpoints without claiming unavailable original creation details.

## 2026-08-12

- Replaced the Windows release lane's focus-sensitive Run-dialog keystrokes
  with a limited scheduled task in the logged-in tester session. The per-run
  driver now launches the internet-zone-marked installer through Windows,
  observes and captures the exact SmartScreen controls, and invokes `More
  info` / `Run anyway` with UI Automation. EdgeDriver selection now follows
  the active EdgeWebView registry `pv` and rejects a major-version mismatch
  instead of selecting an inactive update directory; it also refreshes the
  per-run driver if Evergreen changes the active runtime across the real reboot.
  No golden image or permanent guest dependency changed.
- Expanded the checked-in Desktop Linux and Windows VM journeys with a real
  saved-installation port conflict. Each disposable lane now captures the exact
  inline recovery wording, proves that no user action is required, and verifies
  that Desktop selects, persists, and launches on another port. The fixture and
  evidence stay within the lane's existing single purgeable run directory; no
  golden image or permanent guest dependency changed.

## 2026-08-09

- Added the compressed 815 MB Fedora `desktop-e2e-v2` checkpoint, derived
  from `clean` with Podman still absent. It enables GDM automatic login and
  adds a validated LXPolKit autostart entry for applications launched inside
  the graphical session. The Desktop harness binds a private `pkttyagent` to
  each tested `pkexec` process and supplies the disposable guest password over
  that agent's pseudo-terminal. The existing Fedora WebKitWebDriver, GNOME
  session, ready marker, and Podman-absent state were verified after booting
  the compacted checkpoint. Build overlays and uncompacted intermediates were
  purged after verification.
- Added normal installed-guest readiness polling to `lab.sh wait atomic`, so
  Silverblue can participate in unattended release-test orchestration without
  invoking or depending on its separate installer workflow. The wait requires
  both the lab ready marker and a running or degraded systemd state.
- Added the 68 MB AppImage checkpoint `desktop-e2e-v2`, derived from
  `podman-ready`. It masks `systemd-networkd-wait-online.service` after
  verifying that NetworkManager owns `enp0s1` and networkd reports the link as
  unmanaged, and it includes the stable Ubuntu `WebKitWebDriver` package.
  A reset boot reached lab readiness in 16 seconds with cloud-init, SSH,
  Podman, and the default route verified.
- Fixed mouse input in the Debian 13 viewer lane by using QEMU's virtio tablet
  for the Debian generic-cloud kernel, which does not enable USB support.
- Added this changelog to record lab infrastructure changes separately from
  OmniDeck application and CLI releases.
- Corrected AppImage guest password provisioning so the documented
  `tester` / `omnideck-test` login works on Ubuntu GDM.
- Standardized disposable VM credentials to `tester` / `omnideck-test` across
  Linux and Windows while preserving the existing descriptive display names.
