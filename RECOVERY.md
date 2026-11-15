# sapphire: getting back to recovery

Redmi Note 13 4G (`sapphire` / `sapphiren`), SM6225, A/B slots, unlocked bootloader. All steps
run in **fastboot** (Power + Volume down).

## Layout (dual boot)

- The installer writes the iOS kernel into `boot_<the slot Android is not using>` (installer
  `sapphire.sh`, `ios_slot()`, from the release's `sapphire-recovery.zip`).
- The iOS root is the **`iosroot`** partition (boot-arg `ufsroot=iosroot`); `userdata` holds Android's
  data. The iOS kernel's log ring is at the end of `iosroot`.
- On the fork's phone **`boot_a` = iOS** and **`boot_b` = Android** (Infinity-X). Other phones may differ:
  find Android's slot first (in Android, `getprop ro.boot.slot_suffix`, or `fastboot getvar current-slot`
  right after Android booted).
- On a Mac where native `fastboot`/`adb` cannot open USB devices, use `fbusb` and `adbbridge`
  (`dev-notes/OPERACION.md` §1); the commands below map one to one (`fastboot getvar X` →
  `fbusb getvar:X`).

## Before touching anything

Back up, from OrangeFox and read-only, `boot_a`, `boot_b` and the GPT (header and entries, primary
and backup) of `sda` and `sde` (the A/B LUN). Keep the copies off the phone. A GPT whose A/B
attributes and type GUIDs disagree can stop the bootloader from loading anything
(`android/dualboot/src/com/sapphire/dualboot/Gpt.java`, comment on `withActive`; not verified on
this phone).

## How ABL boots recovery (observed on the original author's phone, single boot, n=1)

- In recovery mode ABL boots the **kernel in `boot`** of the active slot:
  - with an iOS shim image flashed into `boot`, `fastboot reboot recovery` started iOS;
  - with a kernel from a different ROM build (Xiaomi.eu `boot.img` while another ROM was
    installed), recovery showed the logo for an instant and fell back to fastboot;
  - flashing the **`boot.img` of the installed ROM** (here Lunaris 3.12, extracted from its zip's
    `payload.bin`) into `boot_a` brought OrangeFox back.
- Not checked against ABL's source. In the dual-boot layout of the fork's phone, OrangeFox is
  reached with the Android slot active: `fastboot set_active b` + `fastboot reboot recovery`.
- Each slot has a retry counter (7, per `Gpt.java` and `userland/dualboot/sweet_slot.h`); a failed boot
  uses one up, and once it runs out on both slots ABL goes straight to fastboot
  (`slot-unbootable:a/b: yes`). Whether the iOS slot gets marked successful (and so
  stops counting down) was not verified.
- `recovery_a` is `0x6400000` bytes. Recovery images built for another phone (for example the
  upstream topaz OrangeFox) did not boot with `fastboot boot`; use a sapphire build.

## Diagnose

```sh
fastboot getvar current-slot
fastboot getvar slot-unbootable:a
fastboot getvar slot-retry-count:a
fastboot getvar slot-unbootable:b
fastboot getvar slot-retry-count:b
```

## Fix (only when the *Android* slot's `boot` is broken)

Write the ROM's own `boot.img` into **Android's** slot only (here `b`; check yours as above):

```sh
fastboot set_active b                      # Android's slot, NOT the iOS one
fastboot flash boot_b ROM-boot.img         # boot.img of the ROM installed in that slot
fastboot reboot recovery
```

**Never** flash the ROM's `boot.img` into the iOS slot (here `set_active a` + `flash boot_a`): that
overwrites the iOS kernel, and the installer, which takes as the iOS slot the one opposite to the slot
the recovery runs in, would then write iOS over the real Android on the next install.

If Android itself does not boot, restore all of the installed ROM's boot images into Android's slot
(`boot`, `vendor_boot`, `dtbo`, `init_boot` if the ROM has it, `vbmeta`); `dev-notes/OPERACION.md` §8.4.

If you only have the ROM zip, extract `boot.img` from `payload.bin` (AOSP
`system/update_engine/scripts/update_payload`, or any payload dumper).

Do not wipe or format data in recovery: `userdata` is Android's data, and do not format `iosroot`
(the iOS root and its log ring).

## Booting iOS without losing recovery

- Installed iOS: `fastboot set_active <iOS slot>` + `fastboot reboot` (or `fastboot continue`);
  back to Android with `fastboot set_active <Android slot>`. Never write `boot_<Android slot>` with an
  iOS image.
- Testing a kernel: `fastboot boot img` runs it from RAM and writes nothing. This ABL only boots v4
  images that carry an ARM64 kernel header (`NOTES.md`, entry "through our own UEFI"); an image
  without it gives a black screen, not a brick. `fastboot reboot bootloader` brings fastboot back
  (`uefi/README.md`). Otherwise flash `boot_<iOS slot>` after backing it up.
- Leaving iOS: Settings → General → Shut Down (keeps the HFS+ journal clean), then Power + Volume
  down. From a root shell, `sysctl -w kern.sweet_reboot_mode=2; reboot` restarts into fastboot.
