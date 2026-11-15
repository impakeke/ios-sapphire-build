# Working on ios-sapphire

Entry point for agents. The fork's working docs are in Spanish.

## Read first

1. [`dev-notes/OPERACION.md`](dev-notes/OPERACION.md): the full development loop with exact commands
   (host tools, phone layout, access, CI kernel → repack → flash → test → read the ring, failure modes).
2. [`dev-notes/investigacion/INDICE.md`](dev-notes/investigacion/INDICE.md): current state, measurements,
   audits and the next work.
3. The newest entries of [`NOTES.md`](NOTES.md): the dated engineering log.

## Hard rules

- **Never write `boot_b` or any Android partition** during iOS work. iOS is `boot_a`; Android
  (Infinity-X) is slot `b`. The only exception is restoring Android with its own ROM's images, with the
  user's confirmation (`OPERACION.md` §8.4).
- Keep intact: bootloaders, recovery, modem, `persist`, EFS (`modemst1/2`, `fsg`, `fsc`), `metadata`,
  the GPTs, `iosroot`, `userdata` and the backups in `~/sapphire-angel/backups/`.
- **Confirm every destructive step with the user** before running it.
- On this Mac, native `fastboot`/`adb` cannot open USB devices: use `~/adb-bridge/fbusb` and
  `adbbridge` (`tools/hackintosh-usb/`).
- **No personal data in the repo**: no emails, serial numbers, SSIDs, passwords or hashes, device
  dumps, boot logs or Apple artifacts. Raw logs and dumps go to `~/sapphire-angel/` (outside git).
- **Do not trust inherited claims** (notes, comments, commit messages, release notes) without
  evidence: a measurement on the phone or a primary source.

- **Old patch descriptions (the text above `---` in `xnu/patches/*.patch`) are not authoritative.**
  Several state wrong causes (e.g. 0224, 0289, 0291, 0327, 0328, 0331, 0333, 0307). The code, patch
  0335's comments and `dev-notes/investigacion/` are the reference. Do not edit old patches: a changed
  line can break the context of a later patch, which darwin-xnu-build then skips silently; fix code or
  comments with a new patch at the end of the series.

## Working method

- **Measure before assuming.** n≥3 per condition before concluding; say the n when it is smaller.
- In the lab log (`dev-notes/investigacion/03-experimentos-y-datos.md`) **separate observation from
  hypothesis**: date, image (sha), boot path, raw result, then the interpretation, marked as such.
- **Verify the patch was applied in CI**: `dev-notes/fetch-ci-kernel.sh` with `PATCH=<your patch>`.
  darwin-xnu-build skips failing patches silently.
- **Save findings promptly** in `dev-notes/investigacion/` (a new numbered file or an entry in 03) and
  add it to `INDICE.md`. After each milestone add a dated entry to `NOTES.md` (commits, CI run ids,
  exact boot-args, results, unfinished work).
- **Docs state the current truth in present tense.** No changelog text ("corrected on…", "previously
  believed…", "update:"); history lives in git. When a fact changes, rewrite the sentence. Exceptions:
  `NOTES.md` and the lab log 03 are dated by design; the numbered audit reports are dated records.
- Commit completed changes. Kernels build on GitHub Actions (`xnu-4k`, the 4 KiB kernel the phone
  runs) or Codemagic (`codemagic.yaml`).
