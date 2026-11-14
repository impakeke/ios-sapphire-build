# Installing Sapphire (iOS + Android dual boot)

Sapphire puts iOS 16.7.16 next to Android on the **Redmi Note 13 4G** (codename **sapphire**, also
**sapphiren**). Android stays the main system; iOS lives in its own partition and its own boot slot, and you
switch between them with an app on each side.

> **Test release.** The current version is 0.1.8 (`installer/VERSION`; GitHub tag `v0.1.8-test`). Expect
> rough edges. Back up everything you care about on Android before you start.
>
> This guide follows the installer's code and the 0.1.8 release assets
> (`dev-notes/investigacion/04-auditoria-documentacion-heredada.md`).

---

## 1. Before you start

### You need
| | |
|---|---|
| Phone | Redmi Note 13 4G (sapphire / sapphiren) |
| Bootloader | **Unlocked** (Xiaomi's official unlock) |
| Recovery | **OrangeFox Recovery** installed |
| Android | A working Android (HyperOS or a custom ROM), **USB debugging** enabled |
| PC | Windows 10 (1903 or newer) or Windows 11, a good USB cable |
| iOS | The IPSW `iPhone10,3,iPhone10,6_16.7.16_20H392_Restore.ipsw` (iPhone X, iOS 16.7.16, ~6 GB) |
| Time | About 30 minutes |

Sapphire never ships Apple's files: you download the IPSW yourself (search for the exact file name; Apple
serves it from its own servers). Any other IPSW is refused by the installer.

### What the installer changes
- **Your phone's storage is split in two**: Android's `userdata` and a new `iosroot` partition.
  - **The first install has to shrink Android's data partition, which ERASES ANDROID**: apps, photos,
    messages, everything. Back up first.
  - Installing again later with the **same split** leaves Android alone.
  - Changing the split later erases Android again.
- **iOS's boot slot** (the A/B slot Android is not using) gets the iOS kernel in `boot_<that slot>`, and
  the installer makes it the active slot with `fastboot set_active` (which also swaps the A/B partitions'
  GPT type GUIDs and attributes, as the bootloader does; `installer/windows/src/Installer.cs`).
- When the split is made or changed: both copies (primary and backup) of the GPT of LUN 0 are rewritten
  (`installer/part/sapphire-part.c`), and the first 64 MiB of `userdata` **and of `metadata`** (where
  Android keeps its encryption keys) are zeroed, as `fastboot -w` does (`installer/recovery/sapphire.sh`,
  `cmd_format_data`).
- It never writes `persist`, the modem or RPMB. It only **reads** your phone's sensor calibration from
  `persist` (read-only) so iOS can use it.
- It installs an **unauthenticated root shell** on the USB network (`192.168.7.2:2323`,
  `org.sapphire.usbshell`). Anyone with the phone plugged into their computer while iOS runs gets root.
  Do not plug it into machines you do not trust. Whether it answers over Wi-Fi was not checked.

### Sizes
iOS needs at least **24 GB** (the system takes about 14 GB). Android needs at least **16 GB**.
40 GB for iOS is a good default.

---

## 2. Install

> The installer and the apps follow your system's language: Spanish if it is Spanish, English otherwise.
> Button names are given in English, with the Spanish label in brackets.

1. **Download `SapphireInstaller.exe`** from the [latest release](https://github.com/Angelpro09xd/ios-sapphire/releases)
   and run it. It is small: it downloads adb/fastboot from Google and everything else from the release by
   itself. Windows SmartScreen may warn about an unknown app: *More info → Run anyway*.
2. **Phone.** Connect the phone with Android running and USB debugging on (accept the prompt on the phone).
   The installer reboots it into OrangeFox and loads Sapphire there: the phone's screen shows Sapphire's
   logo and *"Complete the steps on the PC"*.
   - Already in OrangeFox or in fastboot? That works too.
3. **iOS.** Pick the IPSW (*Choose IPSW…* [*Elegir IPSW…*]). Leave *Use the kernel from the Sapphire release*
   [*Usar el kernel de la release de Sapphire*] checked.
4. **Storage** [*Espacio*]. Drag the slider to split the space. A red warning means **Android will be erased**.
5. **Confirm** [*Confirmar*]. Read the summary, tick the boxes, choose what to boot when it is done:
   - *Boot Android and install the Sapphire Dual Boot app* (recommended)
     [*Arrancar Android e instalar la app Sapphire Dual Boot*], or
   - *Boot iOS right away* [*Arrancar iOS directamente*].
6. **Install.** Do not unplug the cable. The phone's screen shows each step with a progress bar.
   It takes about 15 minutes: ~4 to send iOS to the phone, ~7 to build it there.

### The first boot of iOS
The first boot is **slow**. iOS creates all its data, and Sapphire finishes its setup:
- it can stay on the boot logo or the Apple logo for **up to 15 minutes**;
- **do not restart it** during that time;
- still stuck after 20 minutes? Restart once (hold Power): the second boot is normal.

Once on the home screen, give it another minute: the jailbreak's apps (Sileo, Zebra) appear by themselves.

---

## 3. Everyday use

| From | To | How |
|---|---|---|
| Android | iOS | Open **Sapphire Dual Boot** → *Restart to iOS* [*Reiniciar en iOS*]. The phone stays in iOS until you switch back. |
| iOS | Android | Open the **Android** app → *Reiniciar en Android*. |

Sapphire Dual Boot (Android) can also browse iOS's files and photos and show the iOS kernel's log
(*Tools → iOS log* [*Herramientas → Registro de iOS*]).

### After installing
- **Tweaks**: Cylinder, SnowBoard, Filza and others are **not** included (they are not ours to
  redistribute). Install them from Sileo: the usual repos are already added.
- **Passwords**: the 0.1.8 overlay locks `root` (`!`), but its `/var/jb/etc/spwd.db` still holds a real
  password hash for `mobile`, from the phone the overlay was taken from (`master.passwd` is scrubbed to
  `*`, but libiosexec only reads `pwd.db`/`spwd.db`), so `mobile` is not passwordless. Setting your own with
  `passwd` from a root shell has not been verified to update `spwd.db`.
- **SSH**: the release's sshd has no launchd job, no host keys and no `authorized_keys`, so it does not
  run; its `sshd_config` has `PermitRootLogin yes` and `UsePAM yes`. The fork giovannipodesta adds a
  key-only sshd that listens only on `192.168.7.2` (`userland/sshd-usb/`); it is not in the 0.1.8 release.
- **Fingerprint**: enroll your fingers in the **Huella** app (experimental).
- **SIM**: iOS asks for the SIM's PIN on the lock screen, like an iPhone.

---

## 4. Troubleshooting

**The installer cannot find the phone.**
Use another USB port/cable. In Android, check *Developer options → USB debugging* and accept the prompt.

**"This IPSW is for …" / "is iOS X".**
Only `iPhone10,3,iPhone10,6_16.7.16_20H392_Restore.ipsw` works.

**The install stopped with an error.**
Android is not affected (unless it was erasing it for a new split). The phone stays in OrangeFox: run the
install again. If it keeps failing, copy the log from the installer's window into a GitHub issue, after
removing private data: logs can contain nearby Wi-Fi network names and device identifiers.

**iOS boots to the Xiaomi logo / fastboot instead of iOS.**
Put the phone in fastboot (Power + Volume down) and make **Android's** slot active, then `fastboot reboot`.
Android's slot is the one the installer did *not* write: after the install the active slot is iOS's, so
`fastboot getvar current-slot` shows iOS's letter and Android is the other one (on the fork's phone iOS is
`a` and Android `b`: `fastboot set_active b`). Do not assume `a`. If you are not sure, check from Android
before installing (`getprop ro.boot.slot_suffix`). Android boots. Then run the installer again.

**Stuck on the Apple logo for a long time on the first boot.**
See *The first boot of iOS* above.

**No sound / no SIM / no fingerprint in iOS.**
These come from the modem partition of your Android firmware, read by name, so any HyperOS version should
work. If one of them is missing, open an issue with your HyperOS version and the iOS kernel log
(Sapphire Dual Boot → *Tools* → *iOS log* → *Share*). Read the log first: it can contain Wi-Fi network
names and device identifiers. Never put `wifi_pass=` in the boot-args: it stays readable in
the boot image and in `kern.bootargs` (patch 0144 only wipes its own copy).

---

## 5. Going back

### Remove iOS
Boot Android. In Sapphire Dual Boot you can keep using Android only; to give the space back, a later
release will offer it in the installer. Until then iOS just stays unused in its partition.

### Re-install iOS
Run the installer again with the same split: iOS is erased and installed from scratch, Android is kept.

---

## 6. Credits
Sapphire: Angelpro09xd and contributors. XNU (Apple, APSL). OrangeFox. Magisk (libbootctl, GPLv3).
Procursus, ElleKit, Sileo, Zebra. apfs-fuse. hfsprogs. libheif and libde265. Sapphire is not affiliated
with Apple or Xiaomi.
