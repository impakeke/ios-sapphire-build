# 12 — Escena de drivers Metal alternativos sobre GPU no-Apple

Informe fechado (2026-11-14). Pregunta: además de hakios-metal, ¿existe otra escena, fork o repositorio —lo más
independiente posible de HackiOS— cuyo fin sea que Metal.framework / CoreAnimation / QuartzCore de iOS o macOS
rendericen sobre una GPU que no es de Apple? Objetivo práctico: decidir sobre qué base se escribe un driver Metal
rápido para el Adreno 610 (SM6225).

Método: zero-trust. Un README no es evidencia. Cada proyecto se abre (árbol, commits, tamaño, shaders y pipelines
reales o stubs, evidencia de ejecución en hardware). Convención: **[O]** observado en código o fuente primaria con
URL + commit/fecha; **[README]** solo lo afirma el proyecto; **[HEREDADO]** lo afirma la documentación de HackiOS y
no se ha vuelto a medir; **NO VERIFICADO** lo que no se pudo comprobar. Metadatos de repos (fechas, tamaño, forks)
leídos de la API de GitHub el 2026-11-14.

Clasificación por cercanía: **(A)** driver Metal directo sobre GPU no-Apple en un Darwin real; **(B)** Metal
traducido a otra API (Vulkan/GLES); **(C)** paravirtualizado o simulador; **(D)** solo framebuffer/CPU;
**(E)** ingeniería inversa o documentación útil sin driver.

Material pesado (fuera de git): clones en `~/sapphire-angel/research/metal/escena/`; resultados crudos de las
búsquedas y del cruce de hashes en `~/sapphire-angel/research/metal/escena/_busqueda/`.

> Estado del documento: en elaboración. Las secciones marcadas «(en curso)» se completan en este mismo archivo.

## 1. Resumen (en curso)

1. **La escena no es pequeña ni converge en HackiOS.** Una búsqueda de código por el símbolo que todo plug-in Metal
   tiene que tocar (`MetalPluginClassName`) devuelve 902 resultados en 252 repositorios; quitando volcados de
   cabeceras, perfiles de sandbox y navegadores quedan unos 230 repos de ports y drivers creados casi todos entre
   el 2026-09-27 y el 2026-11-14 (§9).
2. **Casi ninguno es un fork de GitHub**: son repos nuevos con el código copiado, así que las redes de forks no los
   muestran. El parentesco se midió cruzando el hash git de cada archivo con el historial completo de seis raíces
   (HackiOS, UniXNU, ios-sweet, Bergamota, Chlorophyll, DroidVM) (§9.3).
3. **Arquitecturas que existen de verdad** (código abierto y leído):
   - (A) PM4 directo sobre Adreno: **hakios-metal** (a6xx, iOS 16.5, `_MTLDevice`) y **Snapintosh/SnapMetal**
     (a8xx, macOS 26, `IOGPUMetalDevice`), independientes entre sí.
   - (A) Metal sobre Gallium/freedreno: **Chlorophyll** (a630, iOS 18), que hereda el front end AIR de HackiOS.
   - (B) Metal→metal2vulkan→driver Vulkan de Mesa portado a Darwin: UniXNU/AdrenoMetal (Turnip) y sus decenas de
     derivados; la misma receta sobre PanVK (Mali), NVK (Tegra, NVIDIA), RADV (AMD) y ANV (Intel).
   - (C) GPU virtual: DroidVM (macOS 27 e iPadOS 17 invitados sobre crosvm/Gunyah con el KGSL del teléfono),
     reims-vgpu.
4. El resto de secciones se completa según termina la verificación de cada grupo.

## 2. Tabla de proyectos (en curso)

Fechas de la API de GitHub (creación del repo / último push) salvo que se indique commit. «Raíz» = de qué código
deriva según el cruce de hashes (§9.3) y la lectura del código, no según el README.

### 2.1 Clase A — driver Metal directo

| Proyecto | URL | Autor | Licencia | Lenguaje | Creado / último | GPU y sistema | Shaders | Estado verificado | Relación con HackiOS |
|---|---|---|---|---|---|---|---|---|---|
| hakios-metal | https://github.com/oosexgang/hakios-xnu-kernel (`hakios-metal/`, `userland/src/HakiosMetalCA.m`) | oosexgang | MIT | C++ / ObjC | 2026-10-22 / 2026-11-10; primer commit del driver `9006143` 2026-10-27 | Adreno 642L (a6xx gen3), userland 16.5; subclase de `_MTLDevice`, user client propio | AIR→NIR→ir3 en proceso | referencia (informes 08-10) | — |
| SnapMetal + SnapAdreno + air2ir3 | https://github.com/Snapintosh/SnapMetal · /SnapAdreno · /air2ir3 | Snapintosh | MIT | ObjC / C++ | 2026-10-23 / 2026-10-25; primer commit `3ecaf54` 2026-10-21 | Adreno X2-90 (a8xx), macOS 26 con kernel de Apple; `AdrenoMTLDevice : IOGPUMetalDevice`, kext subclase de IOGPUFamily | AIR (LLVM) →NIR→ir3 | código real (23 k líneas el plug-in, 10 k el kext); evidencia de ejecución solo [README] | independiente: 0 blobs comunes |
| Chlorophyll | https://github.com/ry-diffusion/Chlorophyll | ry-diffusion | MIT (con NOTICE) | C / ObjC | 2026-10-24 / 2026-10-26; commits `c851cb4` 2026-10-23 … `787338f` 2026-10-24 | Adreno 630, iOS 18 (Poco F1); Metal sobre Gallium freedreno | AIR→NIR→ir3 | código real; evidencia de ejecución solo en mensajes de commit | comparte código: `air/` es el front end AIR de HackiOS |

### 2.2 Clase B — Metal sobre Vulkan (identificados; verificación de detalle en curso)

| Proyecto | URL | Creado / último | GPU | Pila | Raíz |
|---|---|---|---|---|---|
| metal2vulkan | https://github.com/steelbrain/metal2vulkan | 2026-07-22 / 2026-11-12 | cualquier Vulkan | Rust: AIR→SPIR-V + API Metal sobre Vulkan | raíz del traductor |
| UniXNU AdrenoMetal | https://github.com/UniXNU/AdrenoMetal | 2026-10-20 / 2026-11-14 | Adreno 740 | frontend ObjC++ → metal2vulkan → Turnip → kext Adreno740 | raíz de la ruta Vulkan en teléfonos |
| G1UltraMetal | https://github.com/tosasitill/G1UltraMetal | 2026-11-03 / 2026-11-03 | Mali-G1 Ultra (MT6993) | frontend de UniXNU → metal2vulkan → PanVK → transporte de kernel propio | UniXNU |
| NullMoth | https://github.com/nullmoth/nvidia-macos-driver | 2026-10-07 / 2026-11-14 | NVIDIA, macOS x86 | plug-in `NVMTL*` → Vulkan (NVK) + kext NVRM | raíz en x86 (en verificación) |
| Cobalt64 | https://github.com/Almosst-DEV/Cobalt64 | 2026-10-02 / 2026-10-15 | AMD RDNA4, macOS x86 | `Navi48Device` → metal2vulkan → RADV | raíz en x86 (en verificación) |

### 2.3 Clase C — paravirtualizado

| Proyecto | URL | Creado / último | Qué es |
|---|---|---|---|
| macOS-DroidVM / UniXNU-droidvm | https://github.com/Droid-VM/macOS-DroidVM · /UniXNU-droidvm | 2026-10-25 / 2026-11-12 | macOS 27 e iPadOS 17 invitados en crosvm sobre Gunyah; la pila Metal de UniXNU dentro del invitado y el KGSL de Android en el host |
| reims-vgpu | https://github.com/steelbrain/reims-vgpu | 2026-07-26 / 2026-11-12 | GPU virtual para invitados macOS en hosts no-Apple (en verificación) |

### 2.4 Mismo SoC o misma GPU que sapphire

| Proyecto | URL | Creado / último | Qué hay | Estado |
|---|---|---|---|---|
| UniXNU-tb128fu + Adreno610 | https://github.com/xVanTuring/UniXNU-tb128fu · https://github.com/xVanTuring/Adreno610 | 2026-10-22 / 2026-10-26 | iPadOS 17.7.11 en SM6225 (tablet Lenovo TB128FU); driver de kernel del Adreno 610 derivado de UniXNU/Adreno740 (80 de 93 blobs idénticos, 9 archivos modificados) | [README] «still draws on the CPU»; el userland Metal (Turnip, metal2vulkan) sin construir |

## 3. Fichas por proyecto (en curso)

### 3.1 Snapintosh (SnapMetal, SnapAdreno, air2ir3)

- **[O]** Publicación inicial `3ecaf54` (2026-10-21), seis días antes del primer commit de hakios-metal
  (`9006143`, 2026-10-27). Cero blobs en común con HackiOS, UniXNU, ios-sweet, Bergamota y Chlorophyll.
- **[O]** `AdrenoMetal/AdrenoMTLDevice.h:7`: `@interface AdrenoMTLDevice : IOGPUMetalDevice <MTLDeviceSPI>`; cola,
  command buffer, encoders, buffer y textura son subclases de `IOGPUMetal*` (`AdrenoMTLObjects.h:22-28`). El kext
  `AdrenoX2` es un acelerador de IOGPUFamily y `AdrenoDisplay` un IOMobileFramebuffer (`SnapAdreno/README.md`).
  Corre con el kernelcache de Apple: reutiliza la mitad de kernel de IOGPU en vez de un user client propio.
- **[O]** Emite PM4 a mano siguiendo a Mesa función por función (`SharedPassState.m`: `fd6_emit_restore<A8XX>`,
  `fd6_emit_static_regs`, `fd6_clear_surface`). Solo renderiza en sysmem (`emit_gmem_cache_cntl_sysmem`,
  `emit_static_binning_regs(gmem=false)`); no hay ruta GMEM ni binning.
- **[O]** Coste por draw declarado en su propio código: «A draw section is about 550 dwords, 20-40 relocations»
  (`AdrenoDrawCommands/RenderPass.m:162-166`), con reubicaciones validadas en el kext.
- **[README]** Escritorio de macOS acelerado en el ASUS A16, 46-60 presentaciones por segundo a 2880×1800
  (`Snapintosh/docs/STATUS.md`, 2026-10-25). Sin evidencia independiente revisada.

### 3.2 Chlorophyll

- **[O]** `air/` (front end AIR→NIR) y `air/air_metal.c` proceden de `oosexgang/hackios-xnu-userland@29eef72`
  (`NOTICE.md`; commit `c623062`). Comprobado por comparación: `air_bitcode.c`, `air_layout.c`, `air_metallib.c`,
  `air_module.h` y `air_print.c` tienen el 100 % de sus líneas en la copia de HackiOS (`tools/mesa/air/`).
- **[O]** Arquitectura distinta de hakios-metal: los objetos Metal (`src/bgmtl.m`, 2045 líneas) llaman a Gallium
  (freedreno, Mesa 25.0.7 como submódulo). Parches propios a freedreno: caché de BOs, barrera de framebuffer fetch
  (`patches/fd-*.patch`, `fd6-fb-barrier-reorder.patch`).
- **[O]** Actividad: 69 commits en dos días (2026-10-23 y 24), ninguno después.

### 3.3 UniXNU (AdrenoMetal, Adreno740, AirNir, AdrenoPM4)

- **[O]** La ruta en ejecución es Vulkan: `AirNir/README.md` «The runtime uses metal2vulkan and Turnip». `AirNir`
  (880 líneas, usa LLVM, 31 intrínsecos `air.*`) y `AdrenoPM4` (unos cientos de líneas) son restos de una ruta
  nativa que no es la que dibuja.
- **[O]** `AdrenoMetal` (296 commits, 2026-10-20 … 2026-11-12): `NativeBridgeMetalFrontend.mm` (5651 líneas,
  subclase dinámica de `_MTLDevice`) + puente Rust a metal2vulkan con 40 parches propios.

### 3.4 DroidVM

- **[O]** `Droid-VM/macOS-DroidVM` (`9db2f6f`, 2026-11-11): kernel de macOS 27 en crosvm sobre Gunyah, kexts
  nativos (`overlay/kext/DroidVMDisplay`, `DroidVMGpuKext.cpp`) y plug-in Metal (`overlay/metal/`). El host ejecuta
  las peticiones del invitado en el KGSL del teléfono (`docs/TODO-gpu.md`).

## 4. Adreno 610 en Mesa y en drm/msm: referencia para un driver directo (en curso)

## 5. Chromium y ANGLE: a qué driver se refieren sus workarounds de Adreno (en curso)

## 6. Blobs de Adreno de Android desde un userspace Darwin (en curso)

## 7. Ideas, diseños y código aprovechables (en curso)

## 8. Veredicto (en curso)

## 9. Cómo se buscó (en curso)

### 9.1 Búsqueda de código en GitHub por artefactos técnicos (API `search/code`, 2026-11-14)

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

### 9.2 Lo que no dio resultados (en curso)

### 9.3 Cruce de hashes

Para cada repo candidato se pide el árbol completo (`git/trees/<rama>?recursive=1`) y se compara el hash git de
cada blob con el conjunto de todos los blobs que han existido en el historial de las raíces: HackiOS
(`oosexgang/hakios-xnu-kernel` con todas sus ramas, `hakios-metal`, `hakios-sm7325`, `hakios-mt6768`), UniXNU
(`UniXNU`, `UniXNU-sheng`, `AdrenoMetal`, `Adreno740`, `GopFramebuffer`, `AirNir`, `AdrenoPM4`, `AdrenoFirmware`),
ios-sweet, Bergamota, Chlorophyll y DroidVM: 13 067 blobs distintos. Una coincidencia de hash es una copia exacta
del archivo; uno o dos aciertos por repo son ruido (archivos triviales). Los archivos de GPU que no coinciden se
separan en «mismo nombre que uno de una raíz» (copia modificada) y «nombre propio» (código propio).

## 10. No verificado (en curso)
