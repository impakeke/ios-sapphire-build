# Where this port stands, and how to pick it up again

Everything in this file is about **sapphire / sapphiren** (Redmi Note 13 4G, SM6225 "khaje"), the phone
this fork targets. `README.md` explains the port itself; `NOTES.md` is the dated engineering log, newest
entry first. For the fork's day-to-day loop (host tools, flashing, testing, reading the kernel log) see
`dev-notes/OPERACION.md`; for the current state and next work, `dev-notes/investigacion/INDICE.md`.
This file covers what lives outside git and the original author's setup.

## What works on the phone

The table in `README.md` ("What works on sapphire") is the reference, with its sources. In short:
iOS boots to the home screen on 8 cores through our UEFI with touch, GPU (Adreno 610, Mesa/turnip +
EAGL bridge), sound, battery, Wi-Fi, telephony and LTE data, and a USB network (`192.168.7.2`) that
enumerates on a normal boot and holds under load (patches 0330-0333).

## The pieces outside this repository

The original author keeps these in a backup of their build server ("the server backup"). The fork's own
out-of-git files are listed in `dev-notes/OPERACION.md` §2.

| What | Where the original author keeps it | How to get it again |
| --- | --- | --- |
| The iOS root image (16 GB) and its sparse copy | the user's WSL, `~/ios-build/` | rebuild with `tools/sapphire-root.sh` from the iPhone X 16.7.16 IPSW |
| `research/ipsw-x/d22ap.adt` | in the server backup | `ipsw img4 im4p extract` on the IPSW's DeviceTree.d22ap.im4p |
| Built kernels (`xnu/out-cm*/`) | in the server backup, the newest one | a Codemagic build of this branch, about 4 minutes |
| `a630_sqe.fw`, `a610_zap.*` | in the server backup under `gpu-fw/vendor/` | the phone's own `/vendor/firmware`, see below (linux-firmware's `qcom/a630_sqe.fw` also works, probably) |
| The phone's device trees (`ios-sapphire-research/`) | in the server backup | dump them from the phone again |
| topaz-woa (reference for the hardware) | cloned under `ios-sapphire-research/` | `git clone https://github.com/MakrSas/topaz-woa` |
| The signed `a610_zap` shader | **found**, in the server backup under `gpu-fw/vendor/` | see "Getting the GPU firmware off the phone" |

## The original author's machines

- These are the original author's tools; the fork works from a Mac (`dev-notes/OPERACION.md`).
- The **server** holds this repository, the research dumps and the built kernels, and reaches the
  phone and the user's WSL through two reverse SSH tunnels the user opens from their PC:
  `.adb.sock` (adb) and `.wsl.sock` (their WSL). `tools/bin/adbt` and `tools/bin/wsl` use them.
- **Windows adb** is at `/mnt/c/adb/adb.exe` inside WSL. Do not pipe binary data into
  `adb.exe shell`: it corrupts it. Use `adb push` and `dd` on the phone, and add `< /dev/null`
  to any `adb.exe` call inside a `while read` loop, or it eats the loop's input.
- **USB to WSL** needs usbipd-win on the PC: `usbipd bind --force --busid <id>` once, then
  `usbipd attach --wsl --busid <id>` after every boot. In WSL the interface shows up as `enx...`
  and needs `ip addr add 192.168.7.1/24` each time.
- **Kernels**: the original author builds on Codemagic (`codemagic.yaml`, free macOS minutes) or
  locally (`tools/xnu-linux`); the fork uses GitHub Actions (`xnu-4k`). On Codemagic the user starts a
  build and pastes its SSH-access line;
  the kernel is at `~/clone/dxb/fakeroot/System/Library/Kernels/` and can be fetched over that
  SSH before the build's long cleanup, which the user then cancels to save minutes.

## Working on the phone without copying 16 GB

The iOS root is a journaled HFS+ volume in its own `iosroot` partition (`ufsroot=iosroot`). To change
a file in it:

1. Shut the phone down from **Settings → General → Shut Down** so the journal is clean
   (`tools/hfs-journal-replay.py` replays it offline if a crash left it dirty), then boot recovery.
2. Copy the phone's HFS+ metadata ranges into a copy of the image on the PC, change files there,
   and write back only the newly allocated blocks plus the metadata
   (`tools/hfs-push-ranges.py`, `tools/sapphire-ssh-install.sh` does the whole thing for sshd).
3. `tools/mbhash.c` hashes every MiB of a partition in one pass (16 GB in under 30 s on the
   phone), which is how the root was once reset to its original image by writing only 1.9 GB.

## Getting the GPU firmware off the phone

Qualcomm's GPU firmware is not in this repository and must not be put in it. It lives in the
phone's own `/vendor/firmware`, which recovery cannot mount: `vendor` is a logical partition
inside `super`, EROFS, and **the live one is in slot `_b`** (recovery only maps the `_a` set, and
those extents hold stale bytes that look like noise, which is misleading). From recovery:

```sh
adb shell lpdump -s 1 /dev/block/sda8     # slot 1: vendor_b, "linear super <first sector>", 1100984 sectors
adb exec-out "dd if=/dev/block/sda8 bs=512 skip=5760040 count=1100984 2>/dev/null" > vendor_b.img
fsck.erofs --extract=vendor-extract --no-preserve --overwrite vendor_b.img   # erofs-utils, no --path in 1.7.1
```

`vendor-extract/firmware/` then has `a610_zap.mdt`, `.b00`, `.b01`, `.b02`, `.elf` and the
phone's own `a630_sqe.fw` (32504 bytes; linux-firmware's is 34188, and topaz-woa preferred the
vendor's). Check the sector offset with `lpdump` instead of trusting the number above. The mdt
has three program headers: a 148-byte PT_NULL, the hash segment (`.b01`, segment type 2 in the
flags) and one PT_LOAD at `0x5000`, 2096 bytes, which is `.b02` — so `zap_load()` loading only
`.b02` at `p_paddr` and asking TrustZone for `max_addr - min_addr` = 0x1000 is right, and matches
Linux `qcom_mdt_load`.

## Booting

The installer flashes the iOS kernel into `boot_<iOS slot>` (the slot Android is not using; on the
fork's phone `boot_a` = iOS, `boot_b` = Android). To test a kernel, use `fastboot boot <image>` (RAM
only; the image needs the ARM64 kernel header, see `NOTES.md` "through our own UEFI") or flash
`boot_<iOS slot>` after backing it up and boot it with `set_active` + `continue`/`reboot`. Never write
an iOS image into `boot_<Android slot>`: the recovery runs with the active slot's `boot`, and
`RECOVERY.md` has the way back. The fork's loop (CI kernel, `repack-boot.py`, flash, test) is in
`dev-notes/OPERACION.md`.

```sh
tools/sapphire-boot.sh --gpu-fw ../gpu-fw xnu/out-cm6/kernel.development.sweet out.img \
    "sweetusb=2 gpu=2 gpu_delay=60"
```

## Open items

Current priorities are in `dev-notes/investigacion/INDICE.md` ("Pendientes"). Open items from the
original author's log, not re-measured by the fork: the black panel between the Apple logo and the end
of the boot, SMS and calls in the apps, and CommCenter's own data contexts (4G icon, per-app cellular
policy).
