# Evidence retention

The lab optimizes for repeatable reruns rather than long-term raw evidence.

- Successful reset transactions are deleted immediately.
- Failed or explicitly retained transactions expire after 48 hours.
- Marked evidence runs expire after 48 hours.
- A `.pin` file exempts an evidence run or transaction from routine GC.
- Logs are capped at 8 MiB and compacted to their latest 2 MiB.
- Golden images, named checkpoints, base images, automation, and keys are never
  GC candidates.

Preview routine cleanup:

```sh
./lab.sh gc --dry-run
```

The final concurrently running lane also attempts routine GC when its lease
ends, so normal use enforces the window without a separate scheduler.

Apply it only when no lane is leased:

```sh
./lab.sh gc --apply
```

For an intentional one-time evidence reset, `--all-evidence` selects everything
under `artifacts/` and `discarded/`, while still refusing to run if a lease is
held. Pin the rare run worth keeping with `lab.sh runs pin PATH`.
