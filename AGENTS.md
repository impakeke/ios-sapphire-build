# Working on ios-sapphire

- Read `README.md` and the newest entries of `NOTES.md` first: hardware facts, what works,
  boot args, the current blocker and the next concrete action.
- After each milestone and before stopping, add a dated entry to `NOTES.md`: commits, kernel
  build IDs (Codemagic or GitHub Actions), exact boot args and results, unfinished work.
  Distinguish observations from guesses.
- Commit completed changes. Kernels build on Codemagic (`codemagic.yaml`) or GitHub Actions
  (`.github/workflows/xnu-4k.yml` is the kernel the phone runs; `xnu.yml` is the 16K one). The
  original author's release kernels were built locally (`tools/xnu-linux`), not on CI.
- Boot rules (dual boot, corrected 2026-11-14): the installer flashes `boot_<iOS slot>`. To test a
  kernel use `fastboot boot` (RAM only; the image needs the ARM64 kernel header) or
  `fastboot set_active <iOS slot>` + `continue`/`reboot` after flashing `boot_<iOS slot>`; **never
  write `boot_<Android slot>`** (see `RECOVERY.md`; on the fork's phone iOS = `a`, Android = `b`).
  The iOS root lives in the `iosroot` partition (`ufsroot=iosroot`), not `userdata`; keep
  bootloaders, recovery, modem, persist, EFS (`modemst1/2`, `fsg`, `fsc`), `metadata`, the GPTs
  and backups intact, and confirm each destructive step with the user before running it.
- Keep device dumps, serial numbers, boot logs and downloaded Apple artifacts out of git.
