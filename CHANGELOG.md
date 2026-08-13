# OmniDeck Release Lab Changelog

## 2026-08-13

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
