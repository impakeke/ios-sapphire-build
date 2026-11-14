# 12 — Escena de drivers Metal alternativos sobre GPU no-Apple

Informe fechado (2026-11-14). Pregunta: además de hakios-metal, ¿existe otra escena, fork o repositorio —lo más
independiente posible de HackiOS— cuyo fin sea que Metal.framework / CoreAnimation / QuartzCore de iOS o macOS
rendericen sobre una GPU que no es de Apple? Objetivo práctico: decidir sobre qué base se escribe un driver Metal
rápido para el Adreno 610 (SM6225).

Método: zero-trust. Un README no es evidencia. Cada proyecto se abre (árbol, commits, tamaño, shaders y pipelines
reales o stubs, evidencia de ejecución en hardware). Convención: **[O]** observado en código o fuente primaria por
quien redacta, con URL + commit/fecha; **[S]** lo leyó un subagente en fuente primaria y no se ha recomprobado;
**[README]** solo lo afirma el proyecto (README, documentos o mensajes de commit); **[HEREDADO]** lo afirma la
documentación de HackiOS y no se ha vuelto a medir; **NO VERIFICADO** lo que no se pudo comprobar. Metadatos de
repos (creación, último push, tamaño, estrellas) leídos de la API de GitHub el 2026-11-14.

Clasificación por cercanía: **(A)** driver Metal directo sobre GPU no-Apple en un Darwin real; **(B)** Metal
traducido a otra API (Vulkan/GLES); **(C)** paravirtualizado o simulador; **(D)** solo framebuffer/CPU;
**(E)** ingeniería inversa, documentación o herramientas útiles sin driver.

Material pesado (fuera de git): clones en `~/sapphire-angel/research/metal/escena/`; resultados crudos de las
búsquedas, lista de candidatos y cruce de hashes en `~/sapphire-angel/research/metal/escena/_busqueda/`.

> Estado: la búsqueda se interrumpe el 2026-11-14 con parte de la verificación sin terminar. Lo que falta está en
> §13; las tablas distinguen lo verificado de lo solo identificado.

## 1. Resumen

1. **La escena no es pequeña ni converge en HackiOS.** Buscando por el símbolo que todo plug-in Metal toca
   (`MetalPluginClassName`) salen 252 repositorios; se analizó el árbol de 230, creados casi todos entre el
   2026-09-27 y el 2026-11-14. Solo 4 son forks de GitHub: el parentesco se midió por hash de archivo (§2.2).
2. **Arquitecturas que existen con código abierto y leído:**
   - (A) PM4 directo sobre Adreno: **hakios-metal** (a6xx, userland 16.5, `_MTLDevice`) y **Snapintosh/SnapMetal**
     (a8xx, macOS 26, `IOGPUMetalDevice`), independientes entre sí.
   - (A) Metal sobre Gallium: `air_metal.c` de HackiOS y sus copias (**Chlorophyll** en a630; panfrost en Mali-G52).
   - (B) Metal → metal2vulkan → driver Vulkan de Mesa portado a Darwin: UniXNU/AdrenoMetal (Turnip) y 39 repos
     derivados; la misma receta sobre PanVK, NVK, RADV, ANV y pvr.
   - (C) GPU virtual: reims-vgpu y otras tres reimplementaciones del host de ParavirtualizedGraphics, DroidVM, x86sim.
   - CoreAnimation en modo OpenGL ES sobre Mesa freedreno (sin Metal): HackiOS, ios-topaz, ios-citrus.
3. **Para Mali, PowerVR, Tegra, NVIDIA, AMD e Intel nadie escribe un driver Metal directo**: todos van por Vulkan.
   Directo solo hay en Adreno.
4. **En el Adreno 610** hay cinco ports hermanos (§3.5). Los dos con cifras usan GLES sobre freedreno: 25-35 fps
   (ios-topaz) y ~50 fps a 1080×2340 limitado por relleno de GPU (ios-citrus). De la ruta Vulkan en a610 no hay
   ninguna cifra publicada.
5. **Veredicto provisional (§10):** hakios-metal sigue siendo la base. Snapintosh es el único driver directo ajeno,
   pero es de otra generación (a8xx), solo renderiza en sysmem y depende de la mitad de kernel de IOGPU de Apple,
   que un XNU de fuente no tiene. Quedan tres candidatos sin abrir (§13).
6. **Blobs de Android desde Darwin (§8):** nadie lo hace ni lo propone. Es posible, pero cuesta lo mismo que la
   ruta Vulkan y no elimina la traducción desde Metal; el blob sirve como oráculo en Android.

## 2. Mapa de la escena

### 2.1 Tamaño y fechas

- **[O]** `MetalPluginClassName` da 902 resultados en 252 repos. Sumando las demás búsquedas por símbolo (§11.1) y
  quitando volcados de cabeceras, SDK, perfiles de sandbox y navegadores quedan 230 repos con el árbol analizado.
- **[O]** Creación de esos 230: 137 en octubre de 2026, 53 en la primera mitad de noviembre, 8 en septiembre, 4 en
  agosto, 4 en julio; 21 son anteriores (herramientas de AIR/metallib, Darling, emuladores).
- **[O]** Muchos traen `AGENTS.md` y decenas de commits por día: gran parte del código lo generan agentes. El
  volumen y las estrellas no prueban que algo corra.

### 2.2 Parentesco medido

Cruce del hash git de cada archivo con el historial completo de seis raíces (método en §11.3). «Raíz» es la que
aporta más archivos idénticos, con un mínimo de 15.

| Raíz | Repos | Con más de 200 KB de código de GPU que no está en ninguna raíz | Creados |
|---|---|---|---|
| HackiOS (`oosexgang`) | 40 | 20 | 2026-09-18 … 2026-11-14 |
| UniXNU | 39 | 19 | 2026-10-20 … 2026-11-11 |
| ios-sweet / Bergamota | 27 | 18 | 2026-10-18 … 2026-11-11 |
| DroidVM | 1 | 1 | 2026-11-11 |
| Ninguna de las seis | 123 | 72 | 2017 … 2026-11-13 |

Los 123 sin raíz son la escena de PC (x86), los emuladores y GPU virtuales, las herramientas de AIR y unos pocos
ports a teléfonos con código propio. 21 repos mezclan dos raíces (`_busqueda/lineage.json`).

### 2.3 Cronología de las raíces

| Fecha | Hecho | Fuente |
|---|---|---|
| 2026-04-20 | `MattJackson/libapplegfx-vulkan`: host de ParavirtualizedGraphics sobre Vulkan | creación del repo |
| 2026-07-22 / 07-26 | `steelbrain/metal2vulkan` y `steelbrain/reims-vgpu` | creación de los repos |
| 2026-09-27 … 10-07 | drivers Metal de terceros para macOS en PC: `RX4Darwin/AMDRadeonRDNA4.kext`, `Almosst-DEV/Cobalt64`, `nullmoth/nvidia-macos-driver` | creación de los repos |
| 2026-10-12 | «Darwin on redwood» (HackiOS): GLES de CoreAnimation sobre Mesa freedreno | `hakios-metal` `9e7db76`, `c501212` |
| 2026-10-14 | `dipa-studio/ios-sweet` (sin GPU) | creación del repo |
| 2026-10-19 | front end AIR→NIR de HackiOS | `hakios-xnu-kernel` `6e55a9f` |
| 2026-10-20 | `UniXNU/AdrenoMetal` | `5a34e35` |
| 2026-10-21 | Snapintosh, con su driver Metal directo | `SnapMetal` `3ecaf54` |
| 2026-10-23 | Chlorophyll | `c851cb4` |
| 2026-10-27 | hakios-metal: primer commit del driver directo en C++ | `hakios-metal` `9006143` |
| 2026-11-01 | plug-in de CoreAnimation de HackiOS (`HakiosMetalCA.m`) | `hakios-xnu-kernel` `f693d9d` |
| 2026-11-03 | HackiOS porta también la ruta Vulkan de UniXNU | `95bc3b2`, `4eb6776` |

### 2.4 Kernel de Apple o XNU propio

- **Con el kernelcache de Apple** (UniXNU, DroidVM, Snapintosh, drivers de macOS en PC, reims-vgpu): existen
  IOGPUFamily, IOSurface e IOMobileGraphicsFamily. El driver puede ser subclase de `IOGPUMetalDevice` o de
  `MTLIOAccelDevice` con un kext subclase de las familias de Apple.
- **Con XNU construido de fuente** (ios-sweet y sus ports, HackiOS, este fork): no hay kexts de Apple. El plug-in es
  subclase de `_MTLDevice` con user client propio; IOSurface e IOMobileFramebuffer son reimplementaciones. **[O]**
  `ShueiTsuki/data-a-live` `docs/GPU_PLAN.md` (`d2c7089`): en iOS 16 el descubrimiento va por el bundle de respaldo
  y al kernel le basta una clase `IOAcceleratorES` vacía; `_MTLDevice` mide 528 bytes (536 en iPadOS 17).

## 3. Tabla de proyectos

Fechas: creación del repo / último push (API de GitHub).

### 3.1 Clase A — driver Metal directo a la GPU (sin Vulkan)

| Proyecto | URL | Licencia | Lenguaje | Creado / último | GPU y sistema | Arquitectura | Shaders | Estado verificado | Relación con HackiOS |
|---|---|---|---|---|---|---|---|---|---|
| hakios-metal | https://github.com/oosexgang/hakios-xnu-kernel (`hakios-metal/`, `userland/src/HakiosMetalCA.m`) | MIT | C++ / ObjC | 2026-10-22 / 2026-11-10 | Adreno 642L, userland 16.5, XNU propio | PM4 propio; `_MTLDevice`; user client propio | AIR→NIR→ir3 en proceso | referencia (informes 08-10) | — |
| hakios-metal, port a610 | https://github.com/Angelpro09xd/hakios-xnu-kernel (rama `sapphire-a610`) | MIT | C++ / ObjC | 2026-11-13 / 2026-11-13 | Adreno 610, este teléfono | igual | igual | [O] 766 blobs idénticos a HackiOS, 112 archivos de GPU modificados | fork |
| hakios-metal, port a640 | https://github.com/telegdyd/ios-vayu (`vayu-dev`, `4fdd5be`) | sin SPDX | C++ / ObjC | 2026-11-06 / 2026-11-07 | Adreno 640, Poco X3 Pro | igual (`docs/vayu-patches/0040-hakios-metal-a640-gen2-port.patch`) | igual | [O] 1033 blobs idénticos; ejecución NO VERIFICADA | copia modificada |
| SnapMetal + SnapAdreno + air2ir3 | https://github.com/Snapintosh/SnapMetal · https://github.com/Snapintosh/SnapAdreno · https://github.com/Snapintosh/air2ir3 | MIT | ObjC / C++ | 2026-10-23 / 2026-10-25 | Adreno X2-90 (a8xx), macOS 26 con kernel de Apple bajo un monitor EL2 | PM4 a mano; `AdrenoMTLDevice : IOGPUMetalDevice`; kext subclase de IOGPUFamily | AIR (leído con LLVM) →NIR→ir3 | [O] código real (plug-in ~21 k líneas, kext ~10 k); ejecución [README]; sin commits desde el 2026-10-25 | independiente: 0 blobs comunes |
| Chlorophyll | https://github.com/ry-diffusion/Chlorophyll (`787338f`) | MIT con NOTICE | C / ObjC | 2026-10-24 / 2026-10-26 | Adreno 630, iOS 18 (Poco F1) | Metal sobre Gallium freedreno | AIR→NIR→ir3 | [O] código real y registros del teléfono en `results/`; 69 commits en dos días | comparte código (front end AIR y `air_metal.c`) |
| «libredwoodair» de HackiOS | https://github.com/oosexgang/hakios-xnu-kernel (rama `mtk`, `a962798`, `tools/mesa/air/air_metal.c`) | MIT | C | 2026-10-22 / 2026-11-10 | Mali-G52 (MT6768) vía panfrost | Metal sobre Gallium | AIR→NIR→driver Gallium | [README]; captura `docs/x6826b-metal-mali.png` | es HackiOS |
| SapphireMetal, ios-miatoll | https://github.com/Angelpro09xd/ios-sapphire · https://github.com/samrat1games/ios-miatoll | sin SPDX | C / ObjC | 2026-10-19 … | Adreno 610 / 618 | `air_metal.c` de HackiOS en ports de ios-sweet | AIR→NIR→ir3 | [O] `air_metal.c` y `air_to_nir.c` modificados de HackiOS | comparte código |
| fiio-jm21-xnu | https://github.com/soumarcelino/fiio-jm21-xnu (`6f8cb22`) | sin SPDX | C | 2026-11-01 / 2026-11-01 | Adreno 610 (SM6225), userland 16.5 | `HakiosMetal.m` + `tools/mesa/air/hakios_gallium.c` + driver de kernel a610 propio | AIR→NIR→Gallium | [README] acelerado; 2 commits | copia modificada (243 blobs) |
| Stela | https://github.com/tylertms/Stela (`9840885`) | GPL-2.0 | Rust / C | 2026-10-12 / 2026-11-14 | NVIDIA, macOS Apple Silicon traducido en PC x86 | [S] bundle invitado `StelaGPUDevice : _MTLDevice` + driver NVIDIA propio | [S] AIR→NIR→NAK; `air_to_nir.c` (448 KB) con el mismo nombre que el de HackiOS | parentesco con HackiOS NO VERIFICADO | sin comprobar |
| ios_sagit | https://github.com/MC-XiaoXiao/ios_sagit (`673f850`) | sin SPDX | ObjC++ / C++ | 2026-10-23 / 2026-11-04 | Adreno 540 (a5xx), Xiaomi 6 | NO VERIFICADO: `drivers/gpu/QcomMTL/QcomMTL.mm` (430 KB), `tools/gpu-compiler/AIR.cpp`, `AdrenoPipeline.h`; 2,6 MB de GPU propio | NO VERIFICADO | NO VERIFICADO | casi sin blobs comunes |
| Veerhooda/iOS | https://github.com/Veerhooda/iOS (`5e6bafa`) | sin SPDX | ObjC / C++ | 2026-11-01 / 2026-11-13 | NO VERIFICADO | `userland/OP2Metal/OP2Metal.m` (118 KB), `OP2GPU.cpp`; `userland/op2gpu/` con nombres de archivo de hakios-metal | NO VERIFICADO | NO VERIFICADO | probable derivado |

### 3.2 Clase B — Metal sobre Vulkan

| Proyecto | URL | Creado / último | GPU | Pila | Nivel |
|---|---|---|---|---|---|
| metal2vulkan | https://github.com/steelbrain/metal2vulkan (`7ef1749`, rama `development`) | 2026-07-22 / 2026-11-12 | Vulkan 1.2 | Rust, `GPL-2.0+ OR LGPL-3.0+`; lector AIR y emisor SPIR-V propios; runtime Metal sobre `ash` | [O] |
| UniXNU AdrenoMetal + Adreno740 | https://github.com/UniXNU/AdrenoMetal (`73d582f`) · https://github.com/UniXNU/Adreno740 | 2026-10-20 / 2026-11-14 | Adreno 740, iPadOS 17/27 | `_MTLDevice` → metal2vulkan → Turnip → kext; MIT | [O] estructura; ejecución [README] |
| port M2V de HackiOS | https://github.com/oosexgang/hakios-xnu-kernel (`tools/mk-m2v.sh`) | 2026-11-03 | Adreno 642L | AdrenoMetal `243d63c` + metal2vulkan `624bab3` + Turnip 25.0.7 | [HEREDADO] |
| data-a-live | https://github.com/ShueiTsuki/data-a-live (`d2c7089`) | 2026-10-21 / 2026-11-04 | Adreno 840, iOS 16, XNU propio | NativeMetal de UniXNU + metal2vulkan parcheado + Turnip + kext propio | [README] |
| ios-fuxi, UniXNU-houji, UniXNU-OnePlus13T, UniXNU_marble y otros 35 | lista en `_busqueda/lineage.json` | 2026-10-20 … | Adreno 725-840 | copias de la pila de UniXNU; `Chengdong-Yu/pong-adreno-metal` es copia exacta (104 de 106 blobs) | [O] parentesco; ejecución NO VERIFICADA |
| G1UltraMetal | https://github.com/tosasitill/G1UltraMetal (`b50131c`) | 2026-11-03 | Mali-G1 Ultra (MT6993), iOS 16 | frontend de UniXNU → metal2vulkan → PanVK → transporte de kernel propio | [O] estructura |
| macos-pixel8a, hackios-pixel7pro, UniXNU-opi5plus, MaliMetal | https://github.com/Rubanoxd/macos-pixel8a · https://github.com/Kaydn913/hackios-pixel7pro · https://github.com/Hange777/UniXNU-opi5plus · https://github.com/Ken-u/MaliMetal | 2026-10 … 11 | Mali-G715, G710, G610 | metal2vulkan → PanVK (o panfrost) con kext Mali propio | [S] |
| UniXNU-a04br3 | https://github.com/mouseos/UniXNU-a04br3 | 2026-10-22 / 2026-11-02 | PowerVR GE8300 (MT8167) | kext `NativePowerVR` + Mesa pvr con winsys Darwin + plug-in Metal, sin terminar | [S] |
| ios-on-switch-lmao | https://github.com/brunostjohn/ios-on-switch-lmao | 2026-11-05 / 2026-11-14 | Tegra X1 (GM20B) | `drivers/TegraGM20BMetal/TegraGM20BMetalPlugin.mm`, frontend de UniXNU modificado, metal2vulkan, Mesa NVK | [O] archivos; ejecución NO VERIFICADA |
| NullMoth y copias | https://github.com/nullmoth/nvidia-macos-driver (`87e524a`); copias: `OakRoller/SiliconWing`, `watchthelight-labs/WTLNvidiaGfx`, `WTLIntelGfx`, `zep245/IrisXe-macos-driver`, `leolivm/vermilion`, `Johncall20/GreenMetal`, `luuumi-dev/nullarc` | 2026-10-07 / 2026-11-14 | NVIDIA (y AMD, Intel en las copias), macOS en PC y eGPU | [S] `NVMTLDevice : MTLIOAccelDevice`, PolyForm-NC; plug-in `nvmtl_vk.c` sobre Vulkan, kext NVRM, metal2vulkan vendorizado | [S] genealogía; ejecución NO VERIFICADA |
| Cobalt64 | https://github.com/Almosst-DEV/Cobalt64 (`d1f7bad`); copia `Frame121/CherryRed` | 2026-10-02 / 2026-10-15 | AMD RDNA4, macOS en PC | [S] `Navi48Device : MTLIOAccelDevice`, MIT; metal2vulkan → RADV portado | [S] genealogía; ejecución NO VERIFICADA |
| Otros de PC sin abrir | `RX4Darwin/AMDRadeonRDNA4.kext`, `VedCloud/Meteor-Lake-Xe-LPG-Metal-Graphics`, `Helemen7/RedNavi`, `imrasalghul/HackyNavi`, `pawan295/Appleinteltgldriver.kext`, `Asada8851/StrixArc`, `yusufklncc/intel-gpu-macos-driver` | 2026-07 … 11 | AMD, Intel | NO VERIFICADO | NO VERIFICADO |

### 3.3 Clase C — paravirtualizado o simulador

| Proyecto | URL | Creado / último | Qué es | Nivel |
|---|---|---|---|---|
| reims-vgpu | https://github.com/steelbrain/reims-vgpu (`1fe0acb` master; `5809271` development) | 2026-07-26 / 2026-11-12 | `master` reimplementa el host de ParavirtualizedGraphics (el invitado usa el driver de Apple); `development` trae kext y bundle propios (`RgfxMetalDevice : IOGPUMetalDevice`, 54 k líneas). Traducción a Vulkan en el host | [S]; 154 issues de terceros |
| libapplegfx-vulkan | https://github.com/MattJackson/libapplegfx-vulkan (`7574eac`) | 2026-04-20 / 2026-09-06 | host PG en C, MIT, con lector de bitcode y AIR→SPIR-V propios; solo lavapipe | [S] |
| Henge / Menhir | https://github.com/Leviidev/Henge · https://github.com/shirishpothi/Menhir | 2026 / 2026-11-13 | host PG propio (`pvg_lite.c`, `pvg_metal.m`); Menhir reprodujo una grabación en un Adreno 750 | [S]; ejecución [README] |
| apple-silicon-anyos-project | https://github.com/medfa12/apple-silicon-anyos-project (`59fd73a`) | 2026-05-28 / 2026-08-17 | copia renombrada de reims-vgpu y metal2vulkan en `vendor/` (entran el 2026-08-17) | [S] |
| vphone-linux, asoft-ios-android | https://github.com/YahiaAngelo/vphone-linux · https://github.com/alpersamur3/asoft-ios-android | 2026-11 | iOS 26/27 con el driver PG de Apple sobre un fork de reims; el segundo sobre Turnip en un Adreno 830 dentro de una app Android. iOS 16.7.16 ahí pinta por CPU | [S]; ejecución [README] |
| x86sim | https://github.com/x86sim/x86sim (`ee06119`) | 2026-10-28 / 2026-11-14 | simulador de iOS en Linux: MTLSimDriver de Apple → XPC → `host/metalhostd/vkmtl.m` → metal2vulkan → Vulkan | [S] |
| macOS-DroidVM, UniXNU-droidvm | https://github.com/Droid-VM/macOS-DroidVM (`9db2f6f`) · https://github.com/Droid-VM/UniXNU-droidvm (`06c78e6`) | 2026-10-21 / 2026-11-14 | macOS 27 e iPadOS 17 invitados en crosvm sobre Gunyah; pila de UniXNU en el invitado y el KGSL de Android en el host | [O] estructura; ejecución [README] |
| QEMU `apple-gfx` | upstream de QEMU | — | usa ParavirtualizedGraphics.framework; solo con host macOS | [S] |

### 3.4 Clases D y E

| Proyecto | URL | Clase | Qué aporta | Nivel |
|---|---|---|---|---|
| ios-sweet y la mayoría de sus 27 derivados; Bergamota según su README | https://github.com/dipa-studio/ios-sweet | D | CoreAnimation por CPU, 20-30 fps | [README] |
| Inferno, qemu-t8030 | https://github.com/ChefKissInc/Inferno | D | sin GPU; quita `gfx-asc` del árbol de dispositivos | [S] |
| WhateverGreen, NootedRed, WhateverXe | https://github.com/acidanthera/WhateverGreen | — | parchean los kexts de Apple; no son un backend Metal nuevo | [S] |
| MacWSBootingGuide | https://github.com/khanhduytran0/MacWSBootingGuide | E | qué exige WindowServer a un dispositivo Metal ajeno (offsets de iOS 16.5) | [S] |
| agx-re | https://github.com/ADevWithAnIdea/agx-re | E | ingeniería inversa de AGX G16/G17 | NO VERIFICADO |
| LLAIR, lvslang, rosemetal, darling-metal, indium | https://github.com/gzorin/LLAIR · https://github.com/darlinghq/darling-metal | E / B | bibliotecas de AIR y reimplementaciones de Metal fuera de Darwin | [S] una línea |
| Project-Cascadia | https://github.com/rzxvx/Project-Cascadia | E | Linux en iPhones A5-A13: driver DRM `apple-sgx` y trazas del GPU de iOS (sentido inverso) | NO VERIFICADO |

### 3.5 Mismo SoC o misma GPU que sapphire (Adreno 610)

| Proyecto | URL | SoC | Creado / último | Qué hay | Ruta gráfica | Estado |
|---|---|---|---|---|---|---|
| ios-topaz | https://github.com/MakrSas/ios-topaz (`e477291`) | SM6225 | 2026-10-18 / 2026-10-22 | `TopazAdreno` (kernel) + EAGL sobre Mesa freedreno | GLES de CoreAnimation | [README] 25-35 fps en animaciones |
| ios-sapphire | https://github.com/Angelpro09xd/ios-sapphire | SM6225 (este teléfono) | 2026-10-19 / 2026-11-13 | port de ios-topaz; `SapphireMetal`; port de hakios-metal | GLES; Metal directo | base de este fork |
| UniXNU-tb128fu + Adreno610 | https://github.com/xVanTuring/UniXNU-tb128fu (`a9c3863`) · https://github.com/xVanTuring/Adreno610 (`4384823`) | SM6225 (tablet) | 2026-10-22 / 2026-10-26 | iPadOS 17.7.11; kext del a610 derivado de UniXNU/Adreno740 (80 de 93 blobs idénticos) | Metal→metal2vulkan→Turnip | contradictorio: el README dice «still draws on the CPU»; la ficha de UniXNU (`docs/devices/tb128fu.md`, `0c1bac3`) dice que el plug-in presenta frames con pases sysmem. Sin cifras |
| fiio-jm21-xnu | https://github.com/soumarcelino/fiio-jm21-xnu | SM6225 (750×1334) | 2026-11-01 | HackiOS + `drivers/gpu/hakios.jm21_a610.c` | GLES y Metal sobre Gallium | [README] acelerado; sin cifras |
| ios26-sapphire | https://github.com/HouseOfBalance/ios26-sapphire (`c5cbd52`) | SM6225 (este teléfono), iOS 26 | 2026-11-02 / 2026-11-11 | 844 blobs de HackiOS; parches de la pila Vulkan en `gpu2/` | — | el README describe un «Adreno 830»: texto copiado de otro port. Sin evidencia de GPU en el a610 |
| ios-citrus | https://github.com/ezariago/ios-citrus (`d68733d`) | SM6115 | 2026-10-25 / 2026-10-30 | iOS 16.7.16, kernel de 4 KiB, driver de kernel propio | GLES sobre Mesa freedreno | [README] ~50 fps a 1080×2340 con la GPU a 950 MHz; en pausa |
| willowios | https://github.com/FoxxoOwO/willowios (`ac55bd7`) | SM6125 | 2026-10-24 / 2026-11-14 | port de ios-topaz con Bergamota | GLES | NO VERIFICADO |

## 4. Fichas

### 4.1 hakios-metal y su genealogía

- **[O]** HackiOS nace como «Darwin on redwood»: el primer commit (`9e7db76`, 2026-10-12) trae el GLES de
  CoreAnimation sobre Mesa freedreno (`c501212`). El front end AIR→NIR entra el 2026-10-19 (`6e55a9f`); el commit
  `09ebcf8` lo atribuye a `vcvkk`. Los repos de origen ya no existen: `vcvkk/darwin-redwood` devuelve 404 y
  `oosexgang/hackios-xnu-userland` tiene tamaño 0.
- **[O]** Sobre ese front end hay dos runtimes de la misma casa: `air_metal.c` (Metal sobre Gallium; hoy en la rama
  `mtk` con panfrost) y hakios-metal (PM4 directo, desde el 2026-10-27). Todo lo que usa `air_metal.c` fuera de
  HackiOS es el mismo código.

### 4.2 Snapintosh (SnapMetal, SnapAdreno, air2ir3)

- **[O]** Publicación `3ecaf54` (2026-10-21), seis días antes del primer commit de hakios-metal. Cero blobs en común
  con las seis raíces. Es el único driver de clase A con PM4 propio que no deriva de HackiOS.
- **[O]** `AdrenoMetal/AdrenoMTLDevice.h:7`: `@interface AdrenoMTLDevice : IOGPUMetalDevice <MTLDeviceSPI>`; cola,
  command buffer, encoders, buffer y textura son subclases de `IOGPUMetal*` (`AdrenoMTLObjects.h:22-28`).
- **[O]** Emite PM4 siguiendo a Mesa función por función (`AdrenoDrawCommands/SharedPassState.m`). Renderiza solo en
  sysmem (`emit_gmem_cache_cntl_sysmem`, `emit_static_binning_regs(gmem=false)`): sin GMEM ni binning.
- **[O]** Coste por draw según su código: «A draw section is about 550 dwords, 20-40 relocations and a few hundred
  data bytes» (`AdrenoDrawCommands/RenderPass.m:162-166`); las reubicaciones las valida el kext.
- **[O]** `air2ir3`: caché offline de pipelines direccionada por contenido (unas 35 000 claves, 15 000 blobs,
  `CACHE-FORMAT.md`), ABI de bindings (`BINDING-ABI.md`) y pruebas diferenciales contra Metal (`COVERAGE.md`:
  32 125 de 32 136 variantes de WindowServer; 18 de 18 pipelines de CoreAnimation; 46 kernels de imageblock rechazados).
- **[README]** Escritorio de macOS a 46-60 presentaciones por segundo a 2880×1800 (`Snapintosh/docs/STATUS.md`, `940eeb9`).

### 4.3 Chlorophyll

- **[O]** `air/` y `air/air_metal.c` proceden de `oosexgang/hackios-xnu-userland@29eef72` (`NOTICE.md`; commit
  `c623062`). Comparado con `tools/mesa/air/` de HackiOS: `air_bitcode.c`, `air_layout.c`, `air_metallib.c`,
  `air_module.h` y `air_print.c` tienen el 100 % de sus líneas en la copia de HackiOS.
- **[O]** Lo propio es el dispositivo (`src/bgmtl.m`, 2045 líneas), la inyección en backboardd y los parches a
  freedreno (`patches/fd-bo-cache-*.patch`, `fd6-fb-barrier-reorder.patch`).
- **[O]** `docs/FIXES.md` (2026-10-24): de 20,8 a 28,4 fps en un swipe; codificación de unos 12 ms por frame.
- **[O]** El README de Bergamota (`37a7a7a`, 2026-10-26) dice «CPU rendering, no GPU yet»: los dos documentos se
  contradicen. La evidencia de ejecución son los registros `results/spike*-adreno630.txt`.

### 4.4 metal2vulkan y AdrenoMetal (identificación)

`steelbrain/metal2vulkan` (Rust, `GPL-2.0-or-later OR LGPL-3.0-or-later`, «Beta» según su README) son tres crates:
el front end de AIR, el traductor AIR→SPIR-V con el plan de bindings y un runtime que ofrece la API Metal sobre un
dispositivo Vulkan. `UniXNU/AdrenoMetal` (ObjC++ y Rust, MIT, 296 commits) es el plug-in que lo usa: una subclase
dinámica de `_MTLDevice` (`NativeBridgeMetalFrontend.mm`, 5651 líneas) sobre ese runtime con 40 parches propios,
Turnip portado a Darwin y el kext `UniXNU/Adreno740`. Es la pila que más se copia. `UniXNU/AirNir` y
`UniXNU/AdrenoPM4` son restos de una ruta nativa que no dibuja (`AirNir/README.md`: «The runtime uses metal2vulkan
and Turnip»).

## 5. Cifras de rendimiento publicadas

Ninguna medida aquí. Sirven para ordenar las rutas, no para comparar teléfonos distintos.

| Ruta | Proyecto y GPU | Cifra | Fuente | Nivel |
|---|---|---|---|---|
| Metal → PM4 directo | hakios-metal, Adreno 642L, 1125×2436 | 100-104 fps en swipes, 89-91 en scroll | `docs/reference/metal-measurements.md` (2026-11-04) | HEREDADO |
| Metal → metal2vulkan → Turnip | port de HackiOS, mismo teléfono | 50-57 en swipes, 41 en scroll, GPU 14-21 ms por frame | mismo documento (2026-11-03) | HEREDADO |
| Metal → metal2vulkan → Turnip | UniXNU sheng, Adreno 740 | media 72,1 y 68,2 fps; mínimos 41,5 y 35,2 | `UniXNU/docs/devices/sheng.md:612` (`0c1bac3`) | README |
| Metal → metal2vulkan → Turnip | data-a-live, Adreno 840, iOS 16 | «unos 110 fps de media» en swipes a 120 Hz | README (`d2c7089`) | README |
| Metal → metal2vulkan → Turnip (invitado) | DroidVM, macOS 27 | arrastre de ventana 80-109 fps | `macOS-DroidVM/docs/k27-virtio-gpu-3d-plan.md` (2026-11-02) | README |
| Metal → Gallium freedreno | Chlorophyll, Adreno 630 | 20,8 → 28,4 fps en swipe | `Chlorophyll/docs/FIXES.md` | README |
| Metal → Gallium panfrost | HackiOS `mtk`, Mali-G52, 720×1640 | 92-96 % de frames dentro de 18 ms | `docs/metal-x6826b-plan.md` (rama `mtk`) | README |
| GLES de CoreAnimation → freedreno | HackiOS, Adreno 642L | scroll de Settings 107-114 fps | `metal-measurements.md` (2026-10-31) | HEREDADO |
| GLES de CoreAnimation → freedreno | ios-topaz, **Adreno 610** | 25-35 fps en animaciones | README (`e477291`) | README |
| GLES de CoreAnimation → freedreno | ios-citrus, **Adreno 610** a 950 MHz, 1080×2340 | ~50 fps en scroll, limitado por GPU | README y `AGENTS.md` (`d68733d`) | README |
| Metal → PM4 directo | Snapintosh, Adreno X2-90, 2880×1800 | 46-60 presentaciones por segundo | `docs/STATUS.md` (`940eeb9`) | README |

- **[README]** `ios-citrus/AGENTS.md:378-420`: a 950 MHz y resolución nativa, unas 1400 entregas en 5 s cuestan
  8,0 ms de GPU cada una; «the Adreno 610 is saturated on ~93 draws + 10 clears over 10 MiB surfaces (~85 us a
  draw = fill/bandwidth bound)». Su estimación: 1,5-2 Gpix/s de relleno con mezcla. Una pantalla de bloqueo en
  reposo son 4 draws por frame; un scroll, 65-136.
- **[O]** Dos ports hermanos programan el PLL de la GPU al doble de la frecuencia pedida:
  `fiio-jm21-xnu/drivers/gpu/hakios.jm21_a610.c:427-429` («PLL0 output /2») y
  `ios-citrus/research/CITRUS-CLOCK-SPEED.md:82-91` («950 MHz = PLL0 1900 MHz OUT_AUX2 / 2»). Coincide con el
  informe 11. El port de FiiO lee el speed bin del fusible (`0x01b46000+4`, bits 28:21) y vota el raíl CX por RPM.
- **[S]** En Linux no hay ninguna cifra pública de UI en a610 con freedreno o Turnip: la wiki de postmarketOS solo
  da estados.

## 6. Adreno 610 en Mesa y en drm/msm: referencia para un driver directo

Todo **[S]** salvo indicación. Mesa `767fbf7c` (2026-11-13); Linux `97d73c82` (2026-11-13). «L» = línea de
`src/freedreno/common/freedreno_devices.py`.

- Mesa trata el a610 como `[a6xx_base, a6xx_gen1_low]` (L283-299). No existe ningún `is_a610`: todo cuelga de props.

| Propiedad | a610 | a642L | Línea |
|---|---|---|---|
| GMEM (kernel, `a6xx_catalog.c:747`) | 0x21000 (128K + 4K) | 512K | — |
| num_ccu; tile_align_w/h; tile máx. | 1; 32/16; 1024×1024 | 2; 32/16; igual | L288-292 |
| num_vsc_pipes; cs_shared_mem_size; wave_granularity | 16; 16K; 1 | 32; 32K; 2 | L293-295 |
| reg_size_vec4; instr_cache_size | 48; 64 | 64; 127 | L151-152 |
| has_gmem_fast_clear | no | sí | L158 |
| multiview HW, sampler minmax, ASTC HDR, prefetch de texturas en FS | no | sí | L159-162 |
| sysmem_per_ccu color/depth; fracción de caché de color en GMEM | 8K/8K; HALF | 64K/64K; QUARTER | L164-166 |
| vs_max_inputs_count; supports_double_threadsize | 16; no | 32; sí | L167-168 |
| has_cp_reg_write; has_8bpp_ubwc | sí; sí | no; no | L117-118, L233-234 |
| quirks `indirect_draw_wfm`, `draw_auto_stale_stride`, `predicated_binning`, `depth_bounds_require_depth_test` | sí | no | L153-156 |
| LRZ con feedback, seguimiento de dirección, fast clear; `Z24_UINT_S8_UINT` | no | sí | L223-261 |
| ir3: `getfiberid`, `movs`, `dp2acc/dp4acc`, ALU escalar, `isam.v`, `sad` | no | sí | L223-261 |
| fallback UBWC: hbb, swizzle, macrotile | 13, 0x7, 0 | 14, 0x6, 1 | L297-299 |

- **Compilar con ir3 exige el `fd_dev_info` del a610.** Con el del a642L el shader puede usar instrucciones que el
  a610 no tiene y un regfile de 64 vec4 en lugar de 48.
- **Registros mágicos distintos** (L267-280): `PC_MODE_CNTL` 0xf (0x1f en a642L), `TPL1_DBG_ECO_CNTL` 0,
  `SP_CHICKEN_BITS` 0, `UCHE_UNKNOWN_0E12` 0x10000000, `RB_RBP_CNTL` 1, `RB_DBG_ECO_CNTL` 0x04100000.
- **CCU**: en sysmem depth en 0 y color en 0x2000; en GMEM el color va en 0x20000 (los 4K extra del GMEM).
  `RB_CCU_CNTL` lleva `GMEM_FAST_CLEAR_DISABLE=1` (`fd6_emit.cc:817-833`).
- **`RB_RENDER_CNTL` se escribe con `CP_REG_WRITE(TRACK_RENDER_CNTL)`** (`fd6_gmem.cc:657-673`); el a642L lo
  escribe directo.
- **Binning**: hay que programar los 16 `VSC_PIPE_CONFIG_REG`. Binning por hardware solo con 32 tiles por pipe como
  mucho (tope de 512 bins). Commit `05fffc7b253`: «Pointing multiple VSC pipes at the same bin makes the hw angry».
  Con el número de pipes mal, 1,5 fps y hangchecks (MR !20966).
- **UBWC**: color, R8 y NV12 sí; Z24X8 solo sin MSAA; Z24S8 no. hbb, swizzle y macrotile salen del kernel.
- **LRZ**: activo con límites. Sin feedback (`FORCE_LRZ_WRITE_DIS=1`, `LRZ_FEEDBACK_NONE` en el pase de render), la
  dirección se sigue en CPU y el clear es un blit 2D; solo vale tras un clear de depth.
- **Incidencias**: #10354 abierta (device loss con 16 bindings de vértices); #12627 cerrada (direcciones de VSC tras
  una preempción, `49191f46e60`). No hay a610 en el CI de freedreno. **[O del subagente]** Entrega 991 de Khronos:
  Adreno 610, Vulkan 1.3, CTS 1.4.6.1, Android 16, «Mesa Turnip», 2026-09-06.
- **drm/msm**: entrada del a610 en `a6xx_catalog.c:740-773` (chip 0x06010000, `a630_sqe.fw`, zap `a610_zap.mdt`,
  hwcg `a612_hwcg`, protect `a630_protect`, sin GMU). **No soporta SM6225**: falta su chip id (0x06010001) y sus
  speed bins (235, 216); el comentario del catálogo dice «we don't support khaje upstream yet».
  `a6xx_gpu_sw_reset` no hace nada en el a610 («11nm chips … have hw issues with the reset line!»).
- **hbb**: drm/msm programa 14 para sm6115 y el fallback de Mesa dice 13; kgsl 4.19 usa 13 y kgsl 5.10 usa 14. El
  valor real de este teléfono está sin leer.

## 7. Chromium y ANGLE: a qué driver se refieren sus workarounds de Adreno

**[S]** Chromium `114f7fa6d7` y ANGLE `99a746a` (2026-11-14); las expresiones de los JSON se reevaluaron con un
evaluador propio.

- **Chromium: driver propietario.** Las 12 entradas de `gpu_driver_bug_list.json` que alcanzan a un 610 (49, 125,
  127, 212, 272, 280, 290, 314, 365, 476, 480, 489; todas `os: android`) casan con `gl_vendor: Qualcomm.*` o
  `gl_renderer: Adreno …`, cadenas que solo da el blob. freedreno se anuncia como `freedreno` / `FD610`
  (`freedreno_screen.c:94-104`) y casa 0 de 12. Las entradas de Mesa (373, 409, 509) son `gl_vendor: freedreno` y
  solo de ChromeOS.
- **ANGLE: mixto.** `isQualcommProprietary = isQualcomm && !isQualcommOpenSource` (`vk_renderer.cpp:5814-5817`).
  30 features son solo del propietario; 17 alcanzan también a Turnip/freedreno (3 por vendorID, 4 por clase tiler,
  9 por `isQualcomm`, 1 por número de modelo).
- Ninguna de las dos fuentes nombra el 610. Describen fallos del blob y del uso que Chrome hace de él: no sirven
  como lista de erratas del hardware.

## 8. Blobs de Adreno de Android desde un userspace Darwin

**[S]** No existe y nadie lo propone en público. Es posible técnicamente, pero no compensa.

- **Búsquedas sin resultado**: issues y código con `hybris`, `libgsl`, `libGLESv2_adreno`, `vulkan.adreno` en
  oosexgang, UniXNU, ios-sweet, Bergamota, Chlorophyll y HouseOfBalance; repos «libhybris darwin|xnu|ios» y «kgsl
  xnu|iokit»; código `IOCTL_KGSL IOUserClient`. Entre los 230 repos analizados ninguno carga los blobs.
- **Precedente de userland**: mcpelauncher porta el linker de AOSP a macOS arm64
  (`minecraft-linux/android_bionic` `d68c05161`, 2023-05-15): reserva con `MAP_JIT`, copia los segmentos y reescribe
  `mrs tpidr_el0` por `mrs tpidrro_el0`. Carga un juego, no drivers; exige ejecutar código sin firmar.
- **Lado Darwin** (xnu-8796): el kernel escribe el número de CPU en `TPIDR_EL0` en cada cambio de contexto
  (`osfmk/arm64/cswitch.s:182-183`), así que el TLS de bionic no funciona sin reescribir los binarios; x18 se pone a
  cero al volver a EL0 (`locore.s:975-976`); `ioctl` invierte los bits de dirección y solo admite 13 bits de tamaño
  (`bsd/sys/ioccom.h:74-87`).
- **Los blobs de sapphire** (7 ELF del árbol de vendor de crDroid 15, análisis estático): no usan x18, no tienen
  ELF-TLS ni syscalls directas; leen `tpidr_el0` 439 veces, siempre para el canario de pila; todos los segmentos
  van alineados a 4K. `libGLESv2_adreno` + `libgsl` no dependen de binder; `vulkan.adreno` sí depende de
  `libhidlbase`, del mapper de gralloc y de `libnativewindow`.
- **Interfaz de kernel**: `msm_kgsl.h` define 65 ioctls; `libgsl.so` usa al menos 41 (Turnip usa 11), con `mmap`
  por id, dma-buf/ion y fences como descriptores. El driver real son unas 108 000 líneas GPL atadas a Linux y no
  hay ninguna reimplementación fuera de Linux.
- **Capa de API y licencia**: los blobs dan GLES y Vulkan con WSI solo de Android, así que la traducción desde
  Metal no desaparece. No traen licencia de redistribución; la de la variante para Linux prohíbe la ingeniería
  inversa.
- **Veredicto**: meses de trabajo para acabar en una ruta equivalente a Metal→Vulkan→Turnip. Quien quiso el kernel
  del vendor (DroidVM) dejó Android debajo y aun así eligió Turnip: `droidvm-meta-repo/5_prepare_turnip.sh:8-11`
  dice que con el blob cerrado la pantalla queda en negro. El uso razonable del blob es como oráculo en Android:
  capturar sus command streams y registros y compararlos con los del driver propio, que es el método de freedreno.
- **Tamaño de página, sin resolver**: `AGENTS.md` dice que el teléfono corre el kernel de 4 KiB (`xnu-4k`); el
  subagente leyó 16K en `pexpert/pexpert/arm64/SWEET.h:42` de un árbol que estaba cambiando. Con 4 KiB los
  segmentos de los blobs se mapean sin trucos; con 16K hace falta el modo de compatibilidad del cargador.
- Material: `escena/blobs-sapphire-crdroid15/` contiene los 7 binarios propietarios de Qualcomm descargados para el
  análisis. No se redistribuyen ni entran en ningún commit.
- **[O]** Lo más cercano usa el driver de kernel de Android, no los blobs: `Droid-VM/virglrenderer` («KGSL
  native-context backend (turnip-in-guest over vdrm)») ejecuta en el KGSL del teléfono lo que Turnip emite dentro
  del invitado.
- **[S]** Con KGSL el a610 no admite memoria cached-coherent (Mesa `7395ae7494d`).

## 9. Ideas, diseños y código aprovechables

De la escena (leído aquí, [O]):

1. **Caché de pipelines precompilada y direccionada por contenido** (`air2ir3/CACHE-FORMAT.md`): clave por hash de
   AIR + constantes + clase de formato; blobs compartidos entre claves.
2. **Pruebas diferenciales contra el Metal de un Mac**: `SnapMetal/harness/`, `AdrenoMetal/bridge/*_host.mm`,
   `air2ir3/COVERAGE.md` (llvmpipe frente a Metal). Rechazo tipado en vez de degradación silenciosa.
3. **Plan por programa** (`SnapMetal/AdrenoDrawCommands/DrawPlan.m`): lo que depende solo del programa se graba una
   vez y se reproduce en cada draw.
4. **Lo que exige iOS 16 a un dispositivo ajeno** (`data-a-live/docs/GPU_PLAN.md`): `supportsNativeHardwareFP16`
   a YES; consultas `isMsaa32bSupported`, `isFloat32FilteringSupported`, `supportsASTCTextureCompression`,
   `supportsBCTextureCompression`; preferencias de backboardd antes del descubrimiento (sin compresión de
   framebuffer ni de IOSurface, sin DeepFramebuffer); Core Image de iOS 16 no tiene respaldo por CPU.
5. **Errores ya pagados de Metal sobre freedreno** (`Chlorophyll/docs/FIXES.md`): constantes sin tamaño (subir
   4 KB, no el buffer entero), caché de importaciones de IOSurface, líneas de 1 píxel para las máscaras, draws con
   framebuffer fetch en sysmem, un draw rechazado se salta sin fallar el command buffer.
6. **Coste por draw en la ruta Vulkan** (`data-a-live/tools/metal/m2v/0002`, `0004`, `0005`): el runtime de
   metal2vulkan hace 24,6 asignaciones de memoria por draw y baja a 13,5 con tres parches (medido en lavapipe).
7. **Reloj de la GPU del a610**: receta de PLL y speed bin del port de FiiO (§5).

De la familia de emuladores y GPU virtuales ([S]):

8. **Referencia pública del protocolo ParavirtualizedGraphics**: `reims-vgpu` `master`, `docs/testing.md` §6.
9. **SPI privada que llaman QuartzCore, SkyLight y Core Image**, con codificaciones medidas:
   `reims-vgpu` `development`, `guest/bundle/src/RgfxMetalPrivate.h` (macOS 26/27; contrastar con iOS 16.7).
10. **Qué pide CoreAnimation**: `x86sim/docs/METAL.md` (27 pipelines, 3 IOSurface de swapchain, sin fence, solo
    regiones dañadas: la presentación debe esperar a la GPU). Responder NO a `supportsTileShaders` y
    `supportsImageBlocks` evita los kernels de imageblock.
11. **Identidad del dispositivo**: `targetDeviceArchitecture` no nulo, `acceleratorPort` no cero, tablas de límites
    no nulas; `iosurfaceTextureAlignmentBytes` (Metal responde 16, CoreAnimation redondea filas a 64 como mínimo).
12. **Churn de pipelines**: SpringBoard libera y recrea cientos (231 en 26 s al paginar); conviene conservar los
    liberados (`metal2vulkan` `runtime/src/pipeline/kept.rs`) además de la caché en disco.
13. **Lectores de AIR alternativos**: `air2ir3` (MIT, con LLVM), `metal2vulkan-air` (Rust, GPL/LGPL),
    `libapplegfx-vulkan` (C, MIT), `Stela` `air_to_nir.c` (GPL-2.0).

De freedreno, Asahi y los binarios de Apple ([S]; Mesa `767fbf7c`; lo de CoreAnimation sale de QuartzCore 1195.14.4
de macOS 26.7.1, misma base de código `ogl-metal.mm`, sin confirmar en iOS 16.7):

14. **Grupos de estado con bits sucios y objetos de estado hechos al crear el pipeline**, en vez de codificar todo
    y filtrar. freedreno: `a6xx/fd6_emit.h:24-58` (30 grupos), `:108-140` (un `CP_SET_DRAW_STATE`, 3 palabras por
    grupo sucio), `fd6_draw.cc:362-375`. hakios-metal construye las palabras de cada draw y después compara
    registro a registro con una sombra (`hakios-metal/src/render.cpp:2725-2760`); `CP_SET_DRAW_STATE` solo aparece
    como «disable all» (`:1159`). En Metal el estado es inmutable por objeto: con el patrón de CoreAnimation un draw
    típico solo ensucia el buffer de vértices y las constantes.
15. **IB condicionales por tile**: `a6xx/fd6_gmem.cc:955-992` (`CP_REG_TEST` sobre `VSC_CHANNEL_VISIBILITY` +
    `CP_COND_REG_EXEC`) para saltar load, draw y store en tiles sin geometría. No está en `render.cpp`.
16. **Fusión de pases por destino** (`freedreno_batch_cache.c:22-60`, `:233-252`): si al volver a un destino con
    `Load` nadie lo leyó entre medias, los draws se añaden al pase abierto y se ahorra un store y un load de tiles.
17. **Cómo dibuja CoreAnimation**: la ruta caliente son cinco selectores con IMP cacheado
    (`setVertexBuffer:offset:atIndex:`, `setVertexBufferOffset:atIndex:`, `setFragmentBuffer:offset:atIndex:`,
    `setFragmentBufferOffset:atIndex:`, `drawIndexedPrimitives:…`). Vértices y uniforms van en buffers de un pool
    y por draw solo cambia el offset; `setVertexBytes:` no aparece. Los pipelines se buscan en un mapa por
    especificación, los über-shaders se especializan con function constants y se compilan en una cola aparte; los
    offscreens salen de `MTLHeap`. `flush` usa `commit` o `commitAndWaitUntilSubmitted` y `addScheduledHandler:`:
    «scheduled» debe señalarse en cuanto el kernel acepta.
18. **Mandos de CoreAnimation**: el SDK de iOS 16.5 exporta `CAGetDebugOptionEnvVariableName`, `CASetDebugOption`,
    `CARenderServerSetDebugOption` y `CARenderServerGetPerformanceInfo`, con los que se enumeran las opciones
    `CA_*` del sistema. Candidatas por nombre: `CA_DISABLE_GENERIC_SHADERS`, `CA_DISABLE_TILE_SHADERS`,
    `CA_DISABLE_LOW_LATENCY`, `CA_DISABLE_PRESENT_ON_FINISH`, `CA_PRINT_OFFSCREENS`, `CA_PERF_HUD`.
19. **IOGPU frente a `_MTLDevice`**: nadie reimplementa la ABI de kernel de IOGPU; quien usa `IOGPUMetal*` o
    `MTLIOAccel*` carga la familia de Apple. `IOGPUMetalRenderCommandEncoder` no implementa ni `set*` ni `draw*`:
    la ganancia por draw de cambiar de superclase es nula. El simulador de Apple (`MTLSimDevice`) cuelga directo de
    `_MTLDevice`.
20. **Petición de swap de IOMobileFramebuffer**: `dcp_swap` de Asahi (`drivers/gpu/drm/apple/iomfb_template.h:20-83`,
    AsahiLinux/linux `6ba0637d1ed9`) coincide campo a campo con la petición de 0x46c bytes que lee HackiOS. Campos
    que HackiOS no lee: marcas de tiempo (0x00, 0x08, 0x30), flags (0x40, 0x48), `bg_color` (0x10c) y regiones
    activas (0x140, 0x150). El SDK exporta `IOMobileFramebufferSwapDirtyRegion`. La superficie saliente debe seguir
    viva hasta que se completa el swap que la retira.
21. **Tiempos reales de GPU**: el bloque de finalización de CoreAnimation lee `GPUStartTime`, `GPUEndTime`,
    `kernelStartTime` y `kernelEndTime`; HackiOS devuelve la hora del commit (`HakiosMetalCA.m:5237-5241`).
22. **Asahi** documenta la ABI de usuario de IOGPU (`src/asahi/lib/wrap.c:36-93` en Mesa; ciclo completo en
    `agx_device_macos.c`, padre del commit `afe134a4`) y poco más trasladable a Adreno. **Darling** (`indium`,
    0BSD) es Metal sobre Vulkan con un traductor AIR→SPIR-V que cubre 44 intrínsecos: menos que el front end de
    HackiOS.

## 10. Veredicto (provisional)

**¿Hay una base mejor que hakios-metal para empezar con reglas propias?** Con lo verificado, no.

- **Snapintosh/SnapMetal** es el único driver directo independiente, y sirve como segunda opinión y como fuente de
  herramientas (§9.1-3), no como base: es de a8xx, no tiene GMEM ni binning, cada draw son unas 550 palabras con
  20-40 reubicaciones que valida el kernel, y su mitad de kernel es IOGPUFamily de Apple, que aquí no existe.
- **Metal sobre Gallium** (Chlorophyll, `air_metal.c`) hereda de freedreno GMEM, binning, LRZ y autotune, pero es
  el mismo front end de HackiOS y la única cifra publicada en Adreno es de 20-28 fps con 12 ms de codificación por
  frame.
- **Metal sobre Vulkan** está descartado por el proyecto. La evidencia va en la misma dirección: en el mismo
  teléfono HackiOS mide la mitad de fps que con su driver directo [HEREDADO]; UniXNU publica ~70 fps de media en un
  Adreno 740; nadie publica una cifra en a610; y el enlace estático de metal2vulkan arrastra GPL/LGPL.
- Quedan sin abrir `MC-XiaoXiao/ios_sagit` (a5xx, 430 KB de driver propio), `Veerhooda/iOS` y `tylertms/Stela`.

**Coste de CPU por draw.**

| | Directo (hakios-metal) | Vulkan (metal2vulkan + Turnip) |
|---|---|---|
| Capas por draw | plug-in ObjC → C++ → PM4 | frontend ObjC → runtime Rust → API Vulkan → seguimiento de estado de Turnip → PM4 |
| Dato disponible | en este teléfono: ~126 µs por draw, ~150 draws por frame, hilo de render al 84-90 % (INDICE, 03 M1-M2) | 24,6 asignaciones por draw en el runtime antes de parches de terceros, 13,5 después [O, lavapipe]; ~107 IB y 7 idas y vueltas al kernel por frame en DroidVM [README] |
| Trabajo pendiente | bajar el coste por draw y el estado repetido por tile (informe 10) | portar y validar Turnip y el kext en a610 (sin precedente con cifras), afinar el runtime, resolver la licencia |

**Advertencia para el a610.** El dato más directo de un port hermano dice que a resolución nativa el límite es el
relleno de la GPU (8 ms de GPU por entrega a 950 MHz), no la CPU. Aquí la pasada principal tarda 20-24 ms de GPU
(INDICE). Bajar el coste de CPU por draw es necesario, pero el presupuesto de GPU del a610 pesa igual.

## 11. Cómo se buscó

### 11.1 Búsqueda de código en GitHub por artefactos técnicos (API `search/code`, 2026-11-14)

| Consulta | Resultados | Repos distintos en lo leído |
|---|---|---|
| `MetalPluginClassName` | 902 | 252 |
| `initWithAcceleratorPort` | 992 | 168 |
| `"@interface _MTLDevice"` | 220 | 140 |
| `": IOGPUMetalDevice"` | 30 | 22 |
| `": MTLIOAccelDevice"` | 48 | 23 |
| `IOAcceleratorES NOT sandbox` | 1024 | 131 |
| `MetalPluginName NOT MetalPluginClassName` | 834 | 122 |
| `MTLSimDevice` | 257 | 79 |
| `AppleParavirtGPU` | 1174 | 80 |
| `air.sample_texture_2d` | 1064 | 43 |
| `"air.vertex_output"` (C / C++ / Rust) | 44 / 96 / 138 | 36 / 43 / 16 |
| `metallib nir_shader` | 163 | 41 |
| `metallib AIR spirv bitcode` | 307 | 85 |
| `IOMobileFramebuffer mdss` | 211 | 59 |
| `IOMobileFramebuffer dpu` | 1694 | 52 |
| `IOSurface kgsl` | 510 | 91 |
| `MTLCompilerService` | 6728 | 51 (solo la primera página) |

La API devuelve como máximo 1000 resultados por consulta; de `MetalPluginClassName` se leyeron las diez páginas, de
las demás entre una y cinco.

### 11.2 Otras búsquedas

- Hechas: listado de repos de 16 cuentas y organizaciones de la escena; lectura de `devices.toml` de UniXNU (374
  entradas: 54 con `AdrenoMetal`, 3 de SM6225, 4 de SM6115); seguimiento de los enlaces de los README (así salen
  Droid-VM, Snapintosh y data-a-live).
- Sin resultado: GitLab **[S]**; Codeberg respondió 429 **[S]**; ninguna entrada de Chromium ni feature de ANGLE
  nombra el 610; ninguna cifra de UI en a610 bajo Linux.
- Pendientes: ver §13.

### 11.3 Cruce de hashes

Para cada repo candidato se pide el árbol completo (`git/trees/<rama por defecto>?recursive=1`) y se compara el
hash git de cada blob con el conjunto de todos los blobs del historial de las raíces: HackiOS
(`oosexgang/hakios-xnu-kernel` con sus ramas `main`, `legacy-hackios` y `mtk`, `hakios-metal`, `hakios-sm7325`,
`hakios-mt6768`), UniXNU (`UniXNU`, `UniXNU-sheng`, `AdrenoMetal`, `Adreno740`, `GopFramebuffer`, `AirNir`,
`AdrenoPM4`, `AdrenoFirmware`), ios-sweet, Bergamota, Chlorophyll y DroidVM: 13 067 blobs distintos. Una
coincidencia es una copia exacta. Se descuenta el ruido de los archivos vacíos. Los archivos de GPU que no
coinciden se separan en «mismo nombre que uno de una raíz» (copia modificada) y «nombre propio». Límites: solo la
rama por defecto; `UniXNU/UniXNU` y Bergamota publican un único commit aplastado; un archivo copiado y retocado
cuenta como modificado. Snapintosh, NullMoth, Cobalt64 y metal2vulkan no están entre las raíces: los parentescos
con ellos salen de la lectura, no del cruce.

## 12. No verificado

- Toda ejecución en hardware marcada [README] o [HEREDADO]: nada se ha corrido aquí.
- Qué son de verdad `ios_sagit`, `Veerhooda/iOS`, `akshaynexus/iOSPlus10`, `ETCHDEV/IOS-LISA` y los ports a Exynos,
  Helio y Tensor (`danstronics/ios-s9plus-exynos`, `squeeeezy/HelioDarwin`, `TheAndersMadsen/ios-on-pixel-10`).
- Si el `air_to_nir.c` de Stela deriva del de HackiOS.
- El estado real del Metal del a610 en `UniXNU-tb128fu` (sus dos fuentes se contradicen).
- Que la SPI y los requisitos descritos para macOS 26/27 e iPadOS 17 valgan para iOS 16.7.
- hbb real, speed bin y versión de `a630_sqe.fw` de este teléfono (§6).
- Lo marcado [S]: lo leyó un subagente y no se ha recomprobado.

## 13. Estado al cerrar

Trabajo lanzado y sin resultado al interrumpir la búsqueda:

1. **Tamaño de página del kernel de este teléfono** (§8): leer `sysctl hw.pagesize` y resolver la contradicción
   entre `AGENTS.md` (4 KiB) y la cabecera leída (16K).
2. **Confirmar en iOS 16.7 lo observado de CoreAnimation en macOS 26** (§9.17-18): contar selectores en el plug-in
   y enumerar las opciones `CA_*` con `CAGetDebugOptionEnvVariableName`. Los volcados de QuartzCore están en
   `_busqueda/ca-metal/`.
3. **Verificación de la escena de PC** (familias NullMoth, Cobalt64, Intel; Stela; agx-re): solo consta la
   genealogía de §3.2.
4. **Verificación de los ports a teléfonos con código de GPU propio** (lista de §12).
5. **Descubrimiento fuera de GitHub**: canales de Telegram y Discord, Bilibili, 4PDA, XDA, foros chinos y rusos,
   Gitee/GitCode, búsquedas en chino, ruso, ucraniano, español, vietnamita e indonesio; Cider/Cycada; Corellium;
   precedentes (QuartzCore de Apple en Windows, WinObjC, PureDarwin, ravynOS); evidencia independiente de que la
   escena de PC funciona.
6. **Búsquedas de código no hechas**: `AGXMetal`, `default.metallib` con QuartzCore, `IOGPUMetalDevice` y
   `MTLIOAccelDevice` sin los dos puntos, `ParavirtualizedGraphics`, `apple-gfx`, topics de GitHub, y las páginas
   no leídas de las consultas de §11.1.

Datos para retomar: `_busqueda/cand1.txt` y `cand2.txt` (candidatos), `triage1.jsonl` y `triage2.jsonl` (árbol y
parentesco de cada repo), `lineage.json`, `r_*.txt` (resultados crudos por consulta), `queries.log`.
