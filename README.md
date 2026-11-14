# ios-sapphire

**Apple's iOS 16 running on a Redmi Note 13 4G.**

A port of [MakrSas/ios-topaz](https://github.com/MakrSas/ios-topaz) (itself a port of [dipa-studio/ios-sweet](https://github.com/dipa-studio/ios-sweet)) to the Xiaomi **Redmi Note 13 4G** (`sapphire` / `sapphiren`, Qualcomm **SM6225 "khaje"** / Snapdragon 685). Apple's open-source XNU kernel (xnu-8796) boots through a UEFI stage and a small boot shim, and on top of it runs the **unmodified iOS 16.7.16 (20H392) userland of the iPhone X**: launchd, the system daemons, backboardd and SpringBoard.

The Redmi Note 12 4G (topaz) and the Redmi Note 13 4G share the SoC, the memory carve-outs and most of the board, so this fork follows the topaz branch and adds what differs on sapphire (patches 0140–0154, the shim's DDR handling and the tools below).

> Experimental bring-up, not a usable phone OS. Many things are missing or stubbed, and Apple's security model is mostly switched off. The installer (`docs/INSTALL.md`) puts iOS in its own `iosroot` partition next to Android; the first install shrinks `userdata` and so **erases Android's user data**. It flashes the iOS kernel into `boot_<the slot Android is not using>`; `fastboot boot` (RAM only) is for testing kernels.
>
> Where a claim rests only on commit messages or release notes (versions 0.1.7/0.1.8; `NOTES.md` has no entries for them), this README says "no recorded measurement". Sources: `NOTES.md`, `dev-notes/investigacion/` (03: measurements, 04: audit of these docs). The fork's development loop is in `dev-notes/OPERACION.md`; agents start at `AGENTS.md`.

## What works on sapphire

| Area | State |
| --- | --- |
| Boot | Stock Xiaomi ABL (unlocked) → BootShim → UEFI (Mu-Silicium, `uefi/`) → SapphireXnuBoot → shim → XNU on all **8 cores** (4 KiB-page kernel, workflow `xnu-4k`; `NOTES.md` "ALL EIGHT CORES"). The shim fits the RAM to the DDR bank ABL reports. Installed into `boot_<iOS slot>` |
| Storage | UFS host driver; the iOS root is a journaled HFS+ volume in the `iosroot` partition (`ufsroot=iosroot`), read/write. Shutdown from Settings unmounts it cleanly |
| GUI | Apple logo, lock screen with passcode, home screen, apps. CoreAnimation draws on the Adreno 610 through a Metal driver (`sweetmetal=2`): HackiOS's `hakios-metal` with the fork's A610 patches, built from source. Home-screen swipes: 44-48 command buffers a second with the GPU as the limit (23-27 ms per frame), n=1-2 (`dev-notes/investigacion/03` M10; state and plan in `GPU-ROADMAP.md`). Whether third-party Metal apps draw: not measured. OpenGL ES apps drew through Mesa and an EAGL bridge (`NOTES.md` 2026-10-22 to 10-27; not re-measured by the fork) |
| Touch | FocalTech FT3519T (chip id `54:52`) on QUP0 SE2, calibrated for sapphire by boot args (patch 0140) |
| USB | DWC3 in device mode as a CDC-ECM network card: `192.168.7.2` on the phone. Enumerates on a normal boot (`set_active` + reboot) with patches 0331-0333 (UTMI as the PIPE clock, on by default): 8 of 8 normal boots on the fork's phone, 0 of 3 without them. Data path 0330 (on by default): 20 × 30 MB transfers intact. Small samples; see `dev-notes/investigacion/03`. Release 0.1.8 does not include these patches: there the USB only enumerates when iOS is started from fastboot |
| Modem | Firmware read from the stock `modem_a`, authenticated by TrustZone, modem up with its QMI services (patch 0143); SIM PIN, signal, SMS, calls with audio, LTE data for every app (`NOTES.md` 2026-10-25 to 10-28). "Other carriers via APN": no recorded measurement |
| Wi-Fi | WCN3988; joins WPA2-PSK networks and auto-joins after the first unlock (`NOTES.md` 2026-10-20, 2026-11-04). "Wi-Fi seconds after boot" (0.1.8): no recorded measurement |
| Audio | Playback through the RedwoodAudio HAL plug-in, call audio both ways, microphones (`NOTES.md` 2026-10-28) |
| Clock | Set from the PM6125 RTC at boot (`userland/rtcd`, `NOTES.md` 2026-11-04) |

## What does not work (yet), or is not measured

- **Bluetooth**: "headphones tested" (release notes) has no recorded measurement; the last log entry (`NOTES.md` 2026-11-04) says it is still to be tried with headphones.
- **Camera, battery charge counting** (0.1.7/0.1.8): no recorded measurement.
- **Graphics**: the GPU takes 23-27 ms per frame, longer than the 16.7 ms of 60 Hz and the 8.3 ms of the panel's 120 Hz; coloured flashes when an app opens (not yet captured or traced); with the GPU at 1260 MHz and the governor on, one SpringBoard SIGBUS and a corrupted wallpaper (n=1, cause unknown). The image in use runs the GPU at 820 MHz. Details: `GPU-ROADMAP.md`.
- **GPS**: not working (`dev-notes/gps-plan.md`). No SEP.
- **Security is off**: permissive AMFI and sandbox, a stand-in AppleKeyStore (the passcode lock works, but the keychain wrapping "protects nothing", `NOTES.md` 2026-10-23), no data protection. An **unauthenticated root shell** listens on `192.168.7.2:2323` over USB (`org.sapphire.usbshell`, installed by the installer). SSH: see `docs/INSTALL.md`.

## How it boots

```
ABL (stock Xiaomi bootloader, unlocked)
  -> boot_<iOS slot>  (boot image v4 with an ARM64 kernel header; or `fastboot boot` of it, RAM only)
     -> BootShim -> UEFI (Mu-Silicium, uefi/) -> SapphireXnuBoot
        -> shim: brings up the cores, GIC setup, DDR bank from ABL's DTB, payload behind _end
           -> XNU Mach-O + Apple Device Tree (ADT) + boot-args
              -> XNU -> UFS driver -> HFS+ root in iosroot
                 -> dyld + shared cache -> launchd -> backboardd + SpringBoard
```

There is no serial console. The kernel keeps a persistent log ring at the end of its root partition, `iosroot` in the dual-boot layout (1025 × 4 KiB; `userdata` on the early single-boot setup). `tools/sweet-log-pull.sh` reads only the end of `userdata`; in the dual-boot layout read the last 1025 blocks of `iosroot` from recovery, or use the Sapphire Dual Boot app's iOS log (`docs/INSTALL.md`). With `sweetusb=2` the kernel also streams its console over USB. With `--console`, `tools/sapphire-boot.sh` also draws it over the GUI.

## How to do it yourself

The supported way is the installer, `docs/INSTALL.md`. The steps below are the original single-boot bring-up (root in `userdata`), kept for reference.

You need a Redmi Note 13 4G (`sapphire`/`sapphiren`) with an **unlocked bootloader**, a recovery with a root adb shell (OrangeFox), a Linux machine (or WSL2) and a way to build the kernel on macOS. **Everything on `userdata` is lost.**

### 1. Build the kernel

Ways to build it:

- **GitHub Actions** (`.github/workflows/xnu-4k.yml`, the 4 KiB-page kernel the phone runs): macos-15 with the oldest Xcode 16.x on the runner (16.0, 16A242d); a successful run takes about 6-9 minutes (`dev-notes/investigacion/03`). `.github/workflows/xnu.yml` builds the older 16K-page, Gold-only kernel the same way.

  ```sh
  gh workflow run xnu-4k.yml -R YOU/ios-sapphire --ref sapphire
  gh run download RUN_ID -R YOU/ios-sapphire -n xnu-kernel-4k -D xnu/out
  ```
- **Codemagic** (`codemagic.yaml`, workflows `xnu` and `xnu-4k`, free personal tier: 500 macOS minutes a month): start it on `sapphire`, download the kernel zip. It uses Xcode 16.0; patch 0141 makes the kernel build with it.
- **Locally on Linux/WSL** (`tools/xnu-linux/`, LLVM clang 18 patched with Apple's builtins, iig-lite): this is how the original author built kernels from 0241 on, including the 0.1.8 release kernel (`NOTES.md` 2026-10-28; audit in `dev-notes/investigacion/04` §4: the release kernel cannot be reproduced exactly from the tagged tree).
- **Locally on macOS**: Apple clang 21 / SDK 26.x from the Command Line Tools (`dev-notes/build-recipes.md`).

### 2. Build the iOS root image

Download the iPhone X (iPhone10,3) iOS 16.7.16 (20H392) IPSW from Apple and extract the D22AP Erase identity's OS, Cryptex1 SystemOS and AppOS disk images (with `apfs-fuse`/`ipsw`). Then, on Linux or WSL2 as root (WSL2 needs an `hfsplus.ko` built for its kernel):

```sh
sudo tools/sapphire-root.sh OS.dmg SystemOS.dmg AppOS.dmg OUTDIR [hfsplus.ko]
# -> OUTDIR/ios16-root.img (16 GB) and ios16-root.simg
```

The device tree builder copies `/product` from the real iPhone X device tree: take `Firmware/all_flash/DeviceTree.d22ap.im4p` from the IPSW, decompress it (`ipsw img4 im4p extract`) and save it as `research/ipsw-x/d22ap.adt`.

### 3. Build the boot image

Needs `aarch64-linux-gnu-gcc` and AOSP `mkbootimg.py` (`MKBOOTIMG=...`).

```sh
tools/sapphire-boot.sh xnu/out/kernel.development.sweet sapphire-boot.img            # GUI
tools/sapphire-boot.sh xnu/out/kernel.development.sweet sapphire-usb.img "sweetusb=2" # + USB network
tools/sapphire-boot.sh xnu/out/kernel.development.sweet sapphire-wifi.img "sweetusb=2 modem=1 wifi=1"
```

| Boot-arg | Effect |
| --- | --- |
| `rd=ufsroot0 ufsrw=1 rootrw=1` | Root on `userdata`, writable (`--readonly` drops the last two). The installed dual boot uses `ufsroot=iosroot` |
| `cpus=4` | The four Gold cores (16K kernel); the 4 KiB kernel runs `cpus=8` |
| `sweetfb_noconsole=1` | No kernel text over the GUI (default; `--console` keeps it) |
| `sweetfb_hz=120` | Refresh rate the kernel publishes to CoreAnimation, which paces itself by it, and the period of the kernel's display timer. The panel refreshes at 120 Hz whatever the value (`dev-notes/investigacion/09` §2.4-2.5) |
| `sweettouch_rx=8640 sweettouch_ry=9600` | sapphire's raw touch range (X 0..2159, Y 0..2399, 2 fraction bits) |
| `sweetusb=1` / `sweetusb=2` | USB: report the controller state / start the CDC-ECM device |
| `modem=1 wifi=1` | Boot the modem from `modem_a` and bring up the WLAN firmware (read-only on the phone's partitions) |
| `gpu=1` / `2` / `3` | Adreno 610: log the clock tree / also power it up and read it / also run a command on it. `gpu_delay`, `gpu_slow`, `gpu_div` and `gpu_smmu_early` go with them (see "GPU bring-up") |
| `gpu_vco2=1 gpu_mhz=N` | GPU core clock of N MHz, a row of the stock table (patch 0337; measured with `gxfreq`). Without `gpu_vco2=1`, `gpu_mhz` sets the PLL's VCO and the core runs at half (`gpu_mhz=1260` → 630 MHz) |
| `sweetmetal=2` | Metal loads `HakiosMetal.bundle` for CoreAnimation (patch 0319); `1` names the older `SapphireMetal` (`metal/`). The fork's graphics boot-args and sysctls: `dev-notes/OPERACION.md` §9 |
| `launchd_unsecure_cache=1`, `wdt=-1 wdt_test=no_user_checkin` | launchd without AMFI; no hardware watchdog |

### 4. Put the root on the phone and boot

`fastboot flash userdata` of a sparse image wrote the upper part of `userdata` incorrectly on sapphire's ABL, so copy the raw image from recovery instead (root shell, `userdata` = `/dev/block/by-name/userdata`):

```sh
adb shell 'dd of=/dev/block/by-name/userdata bs=1M' < ios16-root.img    # Linux adb; verify with md5sum
adb reboot bootloader
fastboot boot sapphire-boot.img
```

Use the Linux `adb` for this: piping binary data into Windows' `adb.exe shell` corrupts it. From Windows, `adb push` the image in pieces and `dd` them on the phone. Check the result by comparing md5 sums of 1 MB blocks on both sides.

In this single-boot setup `fastboot boot` (RAM only) keeps the recovery: on sapphire the recovery runs with the kernel in the active slot's `boot`. In the dual-boot layout the installer flashes `boot_<iOS slot>` instead; never write `boot_<Android slot>` (see `RECOVERY.md`). A black screen after `fastboot boot` is not a brick: `fastboot reboot bootloader` recovers it (`uefi/README.md`). The first boot spends a while on the Apple logo; the lock screen follows after a few minutes. To leave iOS cleanly use Settings → General → Shut Down (the HFS+ journal stays clean), then Power + Volume down.

### USB network and live log

With `sweetusb=2` the phone appears as "Sweet iOS (USB Ethernet)". Windows has no CDC-ECM driver; pass it to WSL2 with [usbipd-win](https://github.com/dorssel/usbipd-win) (`usbipd bind --busid X` once, `usbipd attach --wsl --busid X` per boot), then in Linux:

```sh
sudo ip addr add 192.168.7.1/24 dev enx02005e77ee01 && sudo ip link set enx02005e77ee01 up
ping 192.168.7.2
nc -ukl 5140          # live kernel console
```

### Changing files on the phone without a full copy

`tools/hfs-push-ranges.py` and `tools/sapphire-ssh-install.sh` edit the root without rewriting 16 GB: copy the phone's HFS+ metadata ranges (volume headers, journal header, catalog, extents, attributes, bitmap) into the image on the PC, change files there (new files only, replace through new file + rename), and write back only the newly allocated blocks plus the metadata, with `adb push` + `dd` on the phone. The journal must be clean first (shut down from Settings). `tools/bplist-same-size.py` drops launchd jobs from `launchd.plist` in place.

## sapphire patches and tools

| # / file | What |
| --- | --- |
| 0140 | Focaltech raw format and range from boot args, first raw contacts logged, out-of-range positions clamped instead of dropped |
| 0141 | `IORPC.kernelContent` backport so the kernel builds with Xcode 16's `iig` |
| 0142 | sweet's DWC3/CDC-ECM USB device on the SM6225 addresses; opt-in with `sweetusb` |
| 0143 | sapphire's modem_a tables (modem image for PAS, all files for the tftp server and WLAN board data), picked by the `modem.mdt` CRC so topaz keeps working |
| 0144 | Join the network named by boot args `wifi_ssid=` / `wifi_pass=` through upstream's WLAN station (0129/0130), for testing |
| 0145 | Adreno 610 bring-up staged by boot-arg `gpu=N`: clock tree, power-up, zap shader through TrustZone, identity SMMU bank, SQE microcode and a command the GPU executes (powered and answering on the phone; the command stages are blocked by the panic below) |
| 0146 | Black box: a kernel panic writes the console ring (with the panic text) to the end of `userdata` before the panic path spins, since this board has no iBoot panic region. `tools/sweet-log.py` reports it as a PANIC flush |
| 0147 | AppleCLCD frame timing (every 5 s: direct, CPU-composed and GPU-composed frames with the average time of each part; `sweetfb_stats=0` turns it off), and with `sweetfb_gpucopy=1` the GPU copy of single-layer frames |
| 0148 | the GPU for user space: `IOServiceOpen` type `'SGPU'` on IOAcceleratorES gives buffers (mapped write-combined, at GPU addresses 0x01000000–0x10000000), IOSurface import, cache sync and submit with a fence; needs `gpu_service` up. Used by `metal/SapphireMetal/sgpu.c`; a development interface, no register protection yet |
| 0149 | SapphireGPU: the Adreno for Mesa's freedreno through Linux's msm DRM interface, with HackiOS's ABI (request number = selector, client memory = buffer handle, 0x7e = IOSurface as a buffer). Kernel-chosen GPU addresses 0x60000000–0xE0000000, cacheable buffers cleaned before submits, page tables grown into a second low-bank region. Needs `gpu_service` up |
| 0150 | Wi-Fi for iOS, from HackiOS: `en0` (interface KPI), the station thread, Apple80211 answered in the kernel for wifid and Settings, and the registry entries configd and wifid look for; fed by upstream's WCN3988 station (`bsd/dev/sapphire_wlan.c`). Boot arg `wifi=1` |
| 0151 | Asynchronous msm submissions with fences, buffers given back while in use freed at their fence, up to 256 command buffers per submission; Mesa's buffers from the unused DDR at 0x1_0000_0000 (1 GB) mapped write-combined (no cache maintenance; `gpu_pool=0` turns it off); the display skips cleaning surfaces the GPU drew; no per-submission log lines |
| 0152 | Display frame copies handed to the GPU without waiting (`gpu_copy_async=0` waits); `gpu_div=1` runs the GPU at 600 MHz for a test |
| 0153 | msm fences in a slot of their own; an idle GPU with its ring read is never taken for hung (that false alarm stopped the service and crashed backboardd); frame-copy windows not remapped under a queued copy |
| 0154 | GPU fences write their sequence number: the TIMESTAMP bit made every fence the GPU's clock (done for the first ~112 s of a boot, never after) |
| 0329-0334 | The fork's USB and UFS fixes: UTMI as the PIPE clock, data path v2, raw UFS I/O without a kernel `memcpy` into user memory (`dev-notes/README.md`) |
| 0336-0350 | The fork's graphics work: diagnostics of the GPU and the presentation path, the GPU's PLL as Android runs it, presentation queue, cache maintenance by account, GPU TLB and buffer cache, clocks and temperatures, cache maintenance before WFI as a switch, GPU level changes at run time and a governor, DDR vote, clock gating, display diagnostics and direct scanout. Each new behaviour sits behind a sysctl or a boot-arg, most off by default (`dev-notes/OPERACION.md` §9) |
| `shim/` | DDR bank end from ABL's `/memory` node; RAM size clamped to it |
| `tools/mkadt.py` | sapphire identity in the ADT |
| `tools/sapphire-boot.sh`, `sapphire-root.sh` | Boot image and root image for sapphire |
| `tools/fwtable-modem.py` | Generates the modem_a tables from a dump of the partition |
| `tools/fwtable-file.py` | Where a file lies inside a partition, for a driver that reads it directly (the GPU firmware table) |
| `tools/sapphire-touch-kpatch.sh`, `kpatch.py` | Binary fix of the touch scaling in a built kernel (used before a build was possible) |

## GPU bring-up (patch 0145)

The Adreno 610 v2 in this phone (`chip id 0x06010001`, registers at `0x5900000`) has no GMU, so
the host powers it up itself, as Linux does through its "GMU wrapper". Patch 0145 follows what
[topaz-woa](https://github.com/MakrSas/topaz-woa) `docs/P8_gpu.md` established on the same SoC
under Windows, on this kernel and with the pieces `TopazModem` already brings: TrustZone calls,
an identity SMMU bank and RAM below 4 GB that the kernel does not manage.

Reading a GPU register while its power domain or its clocks are off hangs the bus, so the work is
staged by `gpu=N` and each stage is meant to be read in the kernel log before going further:

| Stage | What it does | What to look for |
| --- | --- | --- |
| `gpu=1` | Maps GCC and the GPU CC and logs the clock tree. Never touches `0x5900000` | the bootloader leaves everything collapsed and off |
| `gpu=2` | Powers up (GPLL0 vote, CX GDSC, cxo/ahb, GMU RCG, SMMU vote, GX GDSC, core clock at 300 MHz), then reads the GPU | `RBBM_STATUS`, and `CP_ALWAYS_ON_COUNTER` growing by ~192000 in 10 ms (19.2 MHz) |
| `gpu=3` | Zap shader through TrustZone (PAS 13, region `0x55A15000` from the device tree), identity SMMU bank for the GPU's stream (SID 0 mask 1, as `gfx3d_user` in the device tree), SQE microcode, 32 KB ring, `CP_ME_INIT`, `CP_SET_SECURE_MODE 0`, `CP_MEM_WRITE` | `*** the GPU executes commands ***`, with `c0ffee00` read back from RAM |
| `gpu=4` | The same without the zap shader: leaves secure mode by writing `RBBM_SECVID_TRUST_CNTL`, as Linux does for a device that has no zap firmware. A first test with only the open microcode, and a gamble Linux warns about: if the bootloader left the GPU secure, that write is refused | the same, or a permissions violation |

Every image in use boots stage 3 with `gpu_mmu=1 gpu_service=1`: the GPU stays up as the service that the
display copy, Mesa and the Metal driver use (patches 0148-0154, 0319). The stages and the arguments below remain for
bring-up and debugging; `gpu_slow`, `gpu_div` and `gpu_smmu_early` default to the behaviour that has already run,
so a boot changes one thing:

| Arg | What it does |
| --- | --- |
| `gpu_delay=N` | wait N seconds before starting, so the bring-up log goes out over the live USB console instead of only into the ring at the end of `userdata` |
| `gpu_slow=N` | wait N ms after every step (1200 works), so the once-a-second log writer puts each step on disk before the next one runs |
| `gpu_div=N` | run the core at GPLL0/N: 2 = 300 MHz (the default), 8 = 75 MHz. `gpu_vco2=1` with `gpu_mhz=N` replaces it with the stock PLL path (patch 0337) |
| `gpu_smmu_early=1` | program the identity SMMU bank as soon as its clock is voted, before the GX domain, so the GPU never sees the bus without a context bank |
| `gpu_stop=N` | end stage 3 early: 1 after the zap shader, 2 once the SQE runs, 3 after `CP_ME_INIT`, 4 after `CP_SET_SECURE_MODE` |
| `gpu_keep=1` | leave the GPU running at the end; by default it is parked (GBIF bus drained, GX and CX collapsed) |
| `gpu_draw=0` | skip the first draw (a 256×256 solid fill with the 2D blitter, read back by the CPU) that stage 3 now does after its test |
| `gpu_demo=1` | after the fill, the GPU paints three bars (red, green, blue) onto the boot framebuffer the panel scans out; with a small `gpu_delay` they appear over the Apple logo and stay until SpringBoard's first frame |
| `gpu_bench=1` | after the fill, time a full-frame copy by the GPU (CoreAnimation-like cached source, 4608-byte rows, into the panel's 4320-byte layout) against the CPU memcpy and the cache maintenance either path needs, and check it row by row |
| `gpu_mmu=1` | GPU virtual memory: stage-1 page tables in the GPU's SMMU context bank instead of the identity bank, then a test that maps 256 KB of scattered kernel memory at one GPU address, fills it with the blitter and checks it from the CPU |
| `gpu_service=1` | with `gpu_mmu=1` and every test passed, the GPU is not parked: it stays up as a service that takes copies from the rest of the kernel (`sapphire_gpu_copy`) |
| `sweetfb_gpucopy=1` | AppleCLCD hands the GPU the copy of every single-layer frame into the panel's back buffer, reading CoreAnimation's scattered surface through the GPU's page tables; any failure falls back to the CPU |
| `sweetmetal=1` / `2` | the accelerator service names a Metal driver, so Metal loads its bundle from `/System/Library/Extensions`: `1` SapphireMetal (built from `metal/`, installed with `tools/sapphire-root-install.sh`; a device that logs what Metal asks of it and, with `sweetgl=1`, hands CoreAnimation to OpenGL ES), `2` HakiosMetal, the driver that draws CoreAnimation on the GPU (patch 0319, `GPU-ROADMAP.md`) |
| `gpu_cs=1` | after the fill, run the first shader: a 64-invocation compute kernel (`metal/ir3/shaders/first.asm`, assembled with `metal/ir3/sapphire-ir3as`) that stores `0xc0de0000 + id` per invocation, checked by the CPU |
| `gpu_3d=1` | with `gpu_mmu=1`: replay turnip's first 3D submit (clear, textured blended quad, blit; `metal/capture/`), check all 2 × 65536 pixels on the CPU and show the 256 × 256 result in the centre of the panel for ten seconds |
| `gpu_irq=1` | leave the GPU's interrupt (SPI 177, INTID 209) alone. By default it is masked in the GIC distributor before anything is powered, and at the GPU once its registers answer: it is level triggered and nothing here handles it |

Both `gpu=3` and `gpu=4` need the microcode `a630_sqe.fw`, and `gpu=3` also needs this phone's
signed `a610_zap` shader. Both come off the phone's own `/vendor/firmware`, which is an EROFS
logical partition in `super`, in slot `_b` on this device (`HANDOFF.md` has the three commands);
the microcode is also in [linux-firmware](https://gitlab.com/kernel-firmware/linux-firmware) as
`qcom/a630_sqe.fw`, in a different build (34188 bytes against the vendor's 32504). Neither is in
this repository, and neither should be put in it. The simplest way to give them to the driver is
to put them in the boot image's device tree:

```sh
tools/sapphire-boot.sh --gpu-fw ~/gpu-fw xnu/out/kernel.development.sweet sapphire-gpu.img "gpu=4"
```

where `~/gpu-fw` holds `a630_sqe.fw` (and `a610_zap.mdt` / `a610_zap.b02` for `gpu=3`). Otherwise
the driver reads them from a stock partition: fill `gpu_fw[]` in `SapphireGpu.cpp` with
`tools/fwtable-file.py`, pointing it at the files in a mounted copy of that partition.

What came after (the GPU service, the Metal driver behind CoreAnimation) and what is left: `GPU-ROADMAP.md`.

## Repository layout

| Path | What |
| --- | --- |
| `shim/` | Bare-metal boot shim (C + asm), boot image v4, Gold hand-off, GIC setup, payload loader |
| `xnu/patches/` | XNU patch series, applied in order: sweet's 0001–0079, topaz's 0080–0139, sapphire's 0140+ |
| `codemagic.yaml`, `.github/workflows/xnu-4k.yml`, `xnu.yml` | Kernel builds (`xnu-4k`: the 4 KiB kernel the phone runs) |
| `tools/` | ADT, payload, root image, boot image, log, modem and HFS+ tools; `tools/perf/`: the fork's measuring tools (thread profiles, driver counters, A/B harness, GPU clock, screenshots) |
| `metal/` | The older `SapphireMetal` plug-in (`sweetmetal=1`), the ir3 assembler and the turnip capture/replay tools of the GPU bring-up. The Metal driver in use is built out of git (`GPU-ROADMAP.md` §2) |
| `GPU-ROADMAP.md` | Graphics: how a frame reaches the panel, what is measured, the work left |
| `NOTES.md` | Engineering log (sweet, topaz, sapphire) |
| `dev-notes/` | The fork's notes (Spanish): `OPERACION.md` (development loop), `investigacion/INDICE.md` (state, measurements, audits) |
| `RECOVERY.md` | Getting back to recovery / Android on sapphire |

Not in git: partition dumps, live device trees, Apple firmware and root images, boot logs, build trees.

## Key hardware facts (sapphire)

- SoC SM6225 "khaje": 4× Kryo 260 Silver (A53 class, MPIDR `0x0`–`0x3`) + 4× Kryo 260 Gold (A73 class, `0x100`–`0x103`). Only Gold has the 16K granule. In XNU the logical CPUs 0-3 are the Gold cores and 4-7 the Silver ones, the reverse of Linux (`dev-notes/investigacion/16` §1).
- GPU Adreno 610 v2 (`chip id 0x06010001`), core clock from `gpu_cc_pll0` (the core runs at the VCO / 2). Under iOS the DDR runs at 1555.2 MHz, where the boot leaves it (`dev-notes/investigacion/17` §4.3).
- DDR banks of the tested phone (from ABL's DTB): `0x40000000`+`0x3cc00000`, `0x80000000`+1 GiB, `0xc0000000`+4 GiB. XNU gets 2 GiB at `0x1_40000000`.
- GICv3 at `0xf200000` (redistributors `0xf300000`), UFS at `0x4804000`, splash framebuffer at `0x5c000000` (1080×2400, DSI video mode with DSC).
- Touch: FocalTech FT3519T at `0x38` on QUP0 SE2 (IRQ GPIO80, reset GPIO86), raw range 2160×2400.
- USB: DWC3 at `0x4e00000` (QSCRATCH `+0xf8800`), Synopsys femto HS PHY at `0x1613000`, USB30_PRIM GDSC at GCC `0x1400000` + `0x1a004`.
- Modem carve-out `0x4ab00000`+`0x6900000`, WLAN MSA `0x51900000`+`0x100000`, SMEM `0x46000000`; WCN3988 (`chip_id 150`) behind the modem.

## Credits

Based on [MakrSas/ios-topaz](https://github.com/MakrSas/ios-topaz) and [dipa-studio/ios-sweet](https://github.com/dipa-studio/ios-sweet), which did the hard part: XNU on a Qualcomm phone with the iPhone X userland, the topaz port of the same SoC, its modem and Wi-Fi work. Built on Apple's open-source releases (xnu, IOHIDFamily, libpthread, hfs), [BearSSL](https://bearssl.org), [blacktop/darwin-xnu-build](https://github.com/blacktop/darwin-xnu-build), [ipsw](https://github.com/blacktop/ipsw), [Procursus](https://github.com/ProcursusTeam/Procursus), Qualcomm/Xiaomi's published Linux kernel sources, and the hardware work in [MakrSas/topaz-woa](https://github.com/MakrSas/topaz-woa). The Metal driver is HackiOS's [hakios-metal](https://github.com/oosexgang/hakios-xnu-kernel) (MIT) with the fork's A610 patches. sapphire port by [Angelpro09xd](https://github.com/Angelpro09xd). iOS itself is Apple's and is not distributed here.
