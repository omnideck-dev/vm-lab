# Evidence retention

The lab optimizes for repeatable reruns rather than long-term raw evidence.

- Successful reset transactions are deleted immediately.
- Failed or explicitly retained transactions expire after 48 hours.
- Marked evidence runs expire after 48 hours.
- Immutable consumer caches expire after 168 hours without use.
- A `.pin` file exempts an evidence run or transaction from routine GC.
- Logs are capped at 8 MiB and compacted to their latest 2 MiB.
- Golden images, named checkpoints, base images, automation, and keys are never
  GC candidates.

Preview routine cleanup:

```sh
./lab.sh cleanup --dry-run
```

The final concurrently running lane also attempts routine GC when its lease
ends, so normal use enforces the window without a separate scheduler.

Apply it only when no lane is leased:

```sh
./lab.sh cleanup --apply
```

For an intentional one-time generated-data reset, preview then remove everything
under `artifacts/`, `cache/`, and `discarded/`:

```sh
./lab.sh cleanup --all-generated --dry-run
./lab.sh cleanup --all-generated --yes --apply
```

Cleanup refuses to apply while any lane is leased. `--all-evidence` leaves the
reusable cache intact. Pin the rare evidence or transaction worth keeping with
`lab.sh runs pin PATH` or a `.pin` marker; `--all-generated` is intentionally
stronger and ignores pins.
