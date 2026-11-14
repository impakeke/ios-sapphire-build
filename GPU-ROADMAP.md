# Graphics on the Adreno 610: state and plan

What draws the screen on sapphire today, what is measured, and the work that is left. The evidence is in
[`dev-notes/investigacion/`](dev-notes/investigacion/INDICE.md): the lab log
[03](dev-notes/investigacion/03-experimentos-y-datos.md) (entries M1-M10) and the reports 08-19. How to build,
install and measure: [`dev-notes/OPERACION.md`](dev-notes/OPERACION.md) §9. The dated log is `NOTES.md`.

## 1. How a frame reaches the panel

```
app ─ CoreAnimation transaction ─> backboardd (render server, thread com.apple.coreanimation.display.primary)
  └─ Metal ─> HakiosMetal.bundle (named by the accelerator with sweetmetal=2, patch 0319)
       └─ SapphireGPU (xnu 0149, msm-style interface: GEM_NEW, SUBMIT, WAIT_FENCE, IOSurface import)
            └─ Adreno 610: render passes in GMEM tiles or in system memory
  └─ IOMobileFramebuffer SwapEnd (SweetFramebuffer)
       └─ the GPU copies the 750×1624 surface, scaled ×1.5, into a 1080×2400 flip buffer
            └─ the display engine (MDP, VIG0 plane) is pointed at it; the panel refreshes at 120 Hz
```

- iOS draws at 2x (750×1624); the kernel crops and scales the panel's window of it by 1.5 (report
  [18](dev-notes/investigacion/18-display-scanout-directo.md) §1).
- The bootloader sets up the display (continuous splash); the kernel only repoints the plane at each flip (18 §1).
- Fences are polled: the GPU interrupt is masked and the port handles no device interrupt
  ([09](dev-notes/investigacion/09-auditoria-kernel-gpu.md) §3.2).
- backboardd never asks the kernel for vsync notifications; CoreAnimation paces itself at the rate the kernel
  publishes (`sweetfb_hz`, 120 on the image in use) (09 §2.4).
- The frame's path and what CoreAnimation expects of a Metal driver: report
  [19](dev-notes/investigacion/19-como-dibuja-ios.md) (in progress).

## 2. The Metal driver

- **Source.** The driver is `hakios-metal` from HackiOS (`oosexgang/hakios-xnu-kernel`, MIT), `main` at `63fc2b4`,
  plus the fork's own A610 patches written from primary sources (Mesa, Linux), built on the Mac without Xcode
  (clang/LLD 18, theos SDK, Mesa 25.0.7): report [08](dev-notes/investigacion/08-hakiosmetal-binario-vs-fuente.md)
  §5-§6. Nothing of the inherited port's driver is used as a base; only what a primary source justifies is kept (08 §4).
- **Branches** (out of git, `~/sapphire-angel/research/metal/rebuild/hakios-upstream`):
  - `cpu-draw`: CPU cost per draw (report [13](dev-notes/investigacion/13-driver-cpu-por-draw.md), in progress);
  - `gpu-pass`: GMEM pass, per-tile state, tile geometry, GMEM or sysmem per pass
    (report [14](dev-notes/investigacion/14-driver-gmem-tiles-estado.md));
  - the merged bundle `merge-1` (`cpu-draw` + `gpu-pass`, merge commit `98d2c3c`) is the one installed (03 M10).
- **Installation** is by rename (a new file, then `mv`) and is followed by a check that backboardd is a client of
  `SapphireGPU`. Copying a binary over the loaded one leaves the driver unloaded whenever the new binary's code
  signature starts further into the file than the first one loaded in that boot: dyld refuses it, Metal gets no
  device and CoreAnimation composes on the CPU (flat materials, dark striped blurs, backboardd on several cores, no
  `fps:` lines). Mechanism reproduced on the Mac (14, "Lo primero"; 03 M8).
- **The inherited binary** `installer/update/files/System/Library/Extensions/HakiosMetal.bundle/HakiosMetal`
  (sha256 `13bbd782…`) is the original author's build of his fork of the same source (08 §1). It is what the
  installer puts on a phone; it is not the driver the fork runs or measures.
- **`metal/SapphireMetal`** is an earlier, separate plug-in (patch 0147, `sweetmetal=1`): a device that logs every
  message Metal sends it and, with `sweetgl=1`, makes no Metal device so that CoreAnimation in backboardd falls
  back to OpenGL ES through Mesa and the EAGL bridge (`metal/SapphireMetal/SapphireMetal.m`). With `sweetmetal=2`
  it is not loaded. `metal/ir3`, `metal/capture` and `metal/tools` are the shader-assembler and command-capture
  tools of the kernel's GPU bring-up (`gpu_cs=1`, `gpu_3d=1`).

## 3. Measured state

Home-screen page swipes (`tools/perf/homeswipe.sh 8`), driver `merge-1` loaded and checked, kernel with 0336-0350,
`kern.sweet_fb_queue=1 kern.sweet_gpu_flush=1`. Small samples: n is given in each row.

| What | Value | Source |
|---|---|---|
| GPU core clock with `gpu_vco2=1 gpu_mhz=N` | N (820.00 and 1260.00 MHz measured with `gxfreq`) | 03 M4, M7, M10; report [11](dev-notes/investigacion/11-gpu-relojes-bus-vs-android.md) |
| GPU core clock with `gpu_mhz=1260` and no `gpu_vco2` | 630.00 MHz (15/15): `gpu_mhz` then sets the PLL's VCO and the core runs at half | 03 M3; 11 §1 |
| DDR under iOS | 1555.2 MHz (7/7); nothing votes the bus | report [17](dev-notes/investigacion/17-gpu-escalado-termica-ddr.md) §4.3; 03 M10 |
| Command buffers a second, 820 MHz, `kern.sweet_idle_cache=0` | 44.0-46.9 (n=2); 48.0 at 1260 MHz (n=1) | 03 M10 |
| CPU per draw on the render thread | 25-26 µs (n=2); 62-68 µs with the cache maintenance before WFI (n=2); 142 µs for the base bundle before `cpu-draw` (n=1) | 03 M9, M10 |
| GPU time per command buffer (commit → end) | 26.7-27.6 ms at 820 MHz (n=2), 23.0 ms at 1260 MHz (n=1): **the GPU is the limit** | 03 M10 |
| Main compositor pass | ~22 ms in 102 tiles (base) → 13.3-13.5 ms in 78 tiles (`gpu-pass`) at 820 MHz (n=1) | 03 M9; 14 |
| Frames drawn and never shown | 10.6 % → 0 with the presentation queue (0340) | 03 M7; report [15](dev-notes/investigacion/15-kernel-cache-y-presentacion.md) |
| Cache maintenance per submit | 1.70 ms → 0.01 ms with the surface account (0339) | 03 M7; 15 |
| Temperature at rest (820 MHz fixed) | GPU 61.4-61.7 °C, CPU 64.8-67.5 °C: about 20 °C above Android at rest on the same phone | 17 §4.4 |

Kernel findings behind those numbers:

- **CPU.** Before every WFI, XNU cleaned and invalidated by set/way the core's L1 and also the A73 cluster's shared
  L2; the cluster idles thousands of times a second, so its 2 MB L2 held almost nothing. `kern.sweet_idle_cache=0`
  (0344) removes it: 62-68 → 25-26 µs per draw and +50 % command buffers a second (report
  [16](dev-notes/investigacion/16-planificador-e-hilos.md) §4; 03 M10). In XNU the logical CPUs 0-3 are the A73 and
  4-7 the A53, the reverse of Linux (16 §1).
- **Presentation.** `SwapEnd` did not present in its thread; the 120 Hz timer did, and a frame whose copy was still
  pending was copied over (15 §0.1). The queue of 0340 presents in `SwapEnd`, uses three flip buffers and flips
  as soon as each copy's fence is done.
- **Submit.** Every submit cleaned and invalidated the frame's whole surface (1.5 ms) because the driver maps every
  surface it imports (15 §0.2); 0339 keeps an account of what the CPU caches can hold. 0341 (TLB) and 0342 (buffer
  cache) are smaller.
- **Clocks.** 0345 changes the GPU level while the system runs (312-1344 µs a change, 03 M10), 0346 is a governor by
  busy time with a temperature cap, 0343 reads clocks, DDR and the 16 TSENS sensors; 0347 (DDR vote) and 0348 (clock
  gating) are off by default and not yet tried on the phone (17).

Inherited claims that do not hold:

- "The GPU is bound by memory bandwidth": the main pass moves under 25 MB in 18-24 ms (1.0-1.4 GB/s), a small
  fraction of what the DDR gives; the argument behind it was that raising the clock changed nothing, and the clock
  had not risen (11 §9, §14; 09 §8).
- "`SWEET FB: 5 s … N by the GPU`" frames: it counts swaps, not frames shown, and with `sweetfb_scale=2` (every
  image in use) its times always print 0 (09 §1 point 5). The frame figures are `kern.sweet_fb_diag` (0336) and the
  driver's `fps:` lines.
- "The GPU copy costs ~110 µs" or "~0.5 ms": CPU time to queue it, not GPU time (09 §8).

## 4. Decisions

- The driver starts from HackiOS's upstream with the fork's own A610 support; nothing of the inherited Metal port is
  a base (08).
- No workarounds on CoreAnimation: the work is to find what CoreAnimation requires of a correct Metal driver and fix
  the driver or the kernel (19).
- Metal over Vulkan (Turnip) is ruled out as a base (report
  [12](dev-notes/investigacion/12-escena-drivers-metal-alternativos.md) §10).

## 5. Work left

In order; the list the agents keep current is in
[`INDICE.md`](dev-notes/investigacion/INDICE.md) ("Gráficos: siguiente trabajo").

1. **GPU time per frame (23-27 ms).** Separate where it goes (CP, per-tile cost, sysmem passes, pixels) with the
   driver's `metal_fps=passes`/`timeline` and finish the GMEM/sysmem choice (14 §8).
2. **Incidents at 1260 MHz with the governor on** (SpringBoard SIGBUS, wallpaper with misplaced blocks; n=1, no
   cause established): repeat with each factor alone (1260 MHz fixed, governor, `kern.sweet_idle_cache=0`) (03 M10).
3. **0351**, the lasting L2 fix (nothing before WFI by default, the right bound in the set/way loops), written and
   checked with `git apply`, not in the series (16 §5.1).
4. **Direct scanout** (0350, `kern.sweet_fb_scanout`): the display engine scales the surface itself and the GPU copy
   disappears; in the series, never switched on (18).
5. **Heat:** iOS sits ~20 °C above Android at rest; kernel threads that poll keep the A73 cluster waking 3600-4100
   times a second (16 §1 point 7); `CalendarWidgetExtension` spins at ~57-100 % of a core (03 M5; 17 §4.2). Then the
   DDR vote (0347) and clock gating (0348).
6. **Coloured flashes when opening apps:** no capture or trace yet; hypotheses and protocol in 19 §4.2.
7. **Conformance of the driver** with Metal (silent skips, substituted pipelines, early `waitUntilScheduled`;
   19 §2.9).
8. **Radios:** the `noradio` and control images are built and not tried (03 M5).
9. **Target:** 120 Hz on the panel (8.33 ms a frame).
