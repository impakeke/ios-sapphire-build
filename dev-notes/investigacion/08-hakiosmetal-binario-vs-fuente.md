# 08 — `HakiosMetal.bundle`: el binario frente a la fuente, y el bundle propio

Informe fechado (2026-11-14). Objeto: el binario que dibuja la pantalla con `sweetmetal=2`,
`installer/update/files/System/Library/Extensions/HakiosMetal.bundle/HakiosMetal`
(Mach-O arm64, 8 630 976 bytes, sha256 `13bbd7823dd1cb1abc613e3254b275dc6980685e31d2b3a022dfca1ece9e32bc`).
El teléfono del fork lleva ese mismo archivo (sha256 leído por SSH; mtime 2026-11-13 17:23:40 UTC).

Método: todo lo heredado es hipótesis. Cada afirmación lleva su evidencia: offset o símbolo del binario,
`archivo:línea` de una fuente fijada, o la salida de una orden. Lo que no se comprobó está en §9.

Material fuera de git:

| Carpeta | Contenido |
|---|---|
| `~/sapphire-angel/research/metal/binario-vs-fuente/` | Volcados del binario (`nm`, stabs, desensamblado, `fn.angel.json`), `scripts/fncmp.py` (comparador función a función), `scripts/cachekey.py`, `scripts/macho_syms.py`, el diff del plug-in de Angel |
| `~/sapphire-angel/research/metal/rebuild/` | Toolchain (`llvm18/`, `hosttools/`), SDK (`theos-sdks/`), Mesa (`mesa/`), árboles (`hakios-upstream/`, `hakios-angel/`), parches (`patches/`), scripts (`receta.sh`, `build-mesa.sh`, `build-bundle.sh`, `env.sh`), bundles (`out/`) |
| `~/sapphire-angel/research/metal/hakios-xnu-kernel/` | Clon completo de `oosexgang/hakios-xnu-kernel` con el remoto `angel` (el fork) |

## 1. Resumen

1. **La fuente del binario está publicada y es exactamente la del fork de Angel.**
   `github.com/Angelpro09xd/hakios-xnu-kernel`, rama `sapphire-a610` (fork de `oosexgang/hakios-xnu-kernel`
   creado el 2026-11-13 17:58 UTC), sobre `main` de HackiOS en `63fc2b4` (2026-11-06). Reconstruido desde
   `bd4c247` con la misma versión de compilador, **1551 de las 1558 funciones** del plug-in y del núcleo del
   driver salen idénticas al binario, referencias a datos incluidas (97,3 % de sus bytes); las 7 restantes
   difieren en dos cosas explicadas (§2.4). No hay código del driver sin fuente.
2. **El binario se compila en esta Mac** (i5-7500, 4 núcleos) sin Xcode: clang/LLD 18.1.8 de conda-forge, el SDK
   de theos y Mesa 25.0.7. Mesa tarda 1 min 20 s; el núcleo, el plug-in y el enlace con LTO, 2 min 10 s. No hace falta VM
   ni CI.
3. **Tres datos del build no están en ningún repositorio** y se sacan del binario: `-DHAKIOS_CHIP_A610` no lo
   define ningún archivo del fork (va en la línea de órdenes); Mesa se compila con **LTO completo y
   `-mcpu=cortex-a73`**; y el enlace usa LLD contra el SDK de theos con `minos 16.0`.
4. **El bundle propio existe**: `main` de HackiOS fijado en `63fc2b4` más 6 parches pequeños escritos desde
   fuente primaria (§5), compilado y firmado (§7). No depende de ningún commit de Angel.
5. De los cambios de Angel, **lo necesario para el A610 son constantes del chip, el tamaño de hilo de cómputo,
   el nombre del servicio y un arreglo de compilación**; el resto son optimizaciones sin medición, diagnósticos y
   funciones del port que el kernel no exige (§4). Dos valores suyos se corrigen (tamaño de GMEM, `gpu_id`
   redundante) y el port deja sin tocar cuatro supuestos del A635 que Mesa trata distinto en el A610 (§4.3).
6. **Riesgo abierto del bundle propio:** con el plug-in de HackiOS sin cambios, los uber shaders de CoreAnimation
   se sustituyen por la variante "más cercana" de la pipeline library; Angel afirma que eso pinta colores
   erróneos en este teléfono y por eso los compila genéricos. No está verificado. Por eso hay variantes para
   separar las dos cosas en el A/B (§7).

## 2. Procedencia del binario

### 2.1 Lo que dice el propio Mach-O

| Dato | Valor | Cómo se lee |
|---|---|---|
| Enlazador | LLD 18.1.8, `platform 2` (iOS), `minos 16.0`, `sdk 16.4` | `otool -l`: `LC_BUILD_VERSION`, `tool 4` |
| UUID | `4C4C445A-5555-3144-A1D3-E5445ED56403` (prefijo "LLD") | `LC_UUID` |
| SDK | theos `iPhoneOS16.5.sdk`: su `SDKSettings.json` dice `Version 16.4` y sus `.tbd` dan las mismas versiones que `otool -L` (Foundation 1971, Metal 306.5.16, libc++ 1500.65, libSystem 1319.100.3) | `otool -L` frente al SDK |
| libc++ de cabeceras | 15 (la del SDK): 236 símbolos con la etiqueta ABI `B6v15006` | `nm -a` |
| Objetos | 13 `OSO`: `/home/angel/hakios-new/hakios-metal/out/ios/libhakios-metal.a(` c_api, command, compiler, compute, fake_gpu, gpu, iokit_transport, link, metallib, pm4, render, texture `.o)` y `/tmp/HakiosMetalCA-150ec1.o` | stabs `N_OSO` |
| Fuentes | `…/hakios-metal/out/ios/obj/../../../src/<x>.cpp` y `/home/angel/hakios-new/userland/src/HakiosMetalCA.m` | stabs `N_SO` |
| Símbolos | 12 540 (11 607 locales, 541 exportados, 392 importados); 3 775 funciones | `LC_SYMTAB`, `LC_FUNCTION_STARTS` |
| Mesa | 25.0.7, enlazada estáticamente: `../mesa-25.0.7/src/freedreno/ir3/instr-a3xx.h` | `strings` |
| Firma | `CodeDirectory v=20400`, `flags=0x0`, 2091+2 hashes de 4 KB, identificador `HakiosMetal`, sin CMS, `Info.plist` no ligado | `codesign -dvvv` |

El plug-in es `userland/src/HakiosMetalCA.m` (`METAL_PLUGIN=ca` de `userland/build.sh:295-307`), no
`hakios-metal/plugin/HakiosMetal.m`. La ruta `obj/../../../src/` es la de la regla `out/ios/libhakios-metal.a`
del `Makefile` (`hakios-metal/Makefile:110-114`). El objeto temporal `/tmp/HakiosMetalCA-150ec1.o` indica que el
plug-in se compila y enlaza en una sola orden de clang.

Reparto del código (`binario-vs-fuente/stabs.angel.txt`, `funcs.angel.txt`):

| Rango | Qué es | Funciones | Bytes |
|---|---|---|---|
| `0x4000`–`0x22d2c` | `HakiosMetalCA.m` | 613 | 126 252 |
| `0x22d30`–`0xafc7c` | los 12 objetos de `libhakios-metal.a` | 945 | 577 328 |
| `0xafc80`–`0x277214` | Mesa: AIR→NIR (`libair`), NIR, ir3, isaspec, fdl, util | 2 217 | 1 865 108 |

Alineación de funciones a 16 bytes: 100 % en el núcleo y en Mesa, 25 % en el plug-in. Es la huella de
`-mcpu=cortex-a73` (alineación preferida de función 16), que el `Makefile` del fork pone al núcleo
(`hakios-metal/Makefile:95` del fork) y que el plug-in no lleva.

### 2.2 El fork

`gh api repos/Angelpro09xd/hakios-xnu-kernel`: fork de `oosexgang/hakios-xnu-kernel`, rama por defecto
`sapphire-a610`, sin tags ni releases. Seis commits sobre `63fc2b4`:

| Commit | Fecha (UTC) | Qué toca |
|---|---|---|
| `2abd644` | 13 nov 11:05 | El port: `a6xx.hpp`, `command.hpp/.cpp`, `compute`, `compiler`, `fake_gpu`, `iokit_transport`, `pm4`, `render`, `texture`, `c_api`, `Makefile`, fixtures regenerados, `HakiosMetalCA.m` (+618 líneas) |
| `0ecf0f9` | 13 nov 15:09 | Plug-in: diagnósticos `metal_snap`, `metal_watch` |
| `3863f9f` | 13 nov 15:32 | `hakios_metal_cb_wait_scheduled`; `metal_defer` y uber shaders genéricos por defecto |
| `9463d0f` | 13 nov 15:53 | `metal_defer` vuelve a ser opcional |
| `bd4c247` | 13 nov 17:03 | Plug-in: `metal_snap` de superficies, `metal_fc_off` |
| `5c3bd9a` | 13 nov 17:57 | Solo añade `patches-wip/core-opt-2026-11-13.diff`, **no aplicado** |

El binario corresponde a `bd4c247`: contiene `metal_fc_off=` y `metal_fc_off: a fragment constant forced to 0`
(solo desde `bd4c247`), `metal_defer=1` y no `metal_defer=0` (estado de `9463d0f`), y **no** contiene nada del
parche WIP (`metal_rr54`, `hakios-metal.deferred`, `hakios-metal.completions` ausentes de `strings`). El binario
anterior del repo (commit `967466e`, sha256 `78812bd3…`) no lleva stabs ni las cadenas de `0ecf0f9` en adelante.

`github.com/Angelpro09xd/ios-sapphire` (ramas `sapphire`, `topaz`; tag `v0.1.8-test`) no contiene esa fuente:
solo el binario.

### 2.3 Lo que el fork no dice y el binario sí

| Dato | Evidencia |
|---|---|
| `-DHAKIOS_CHIP_A610` se pasa a mano | `grep -r HAKIOS_CHIP_A610` en el fork: solo `#if` en 5 archivos, ningún `-D`. Con el macro, las funciones salen idénticas; sin él no enlaza con `SapphireGPU`. |
| Núcleo: `-O3 -g -mcpu=cortex-a73`, sin `-fno-use-cxa-atexit` | `Makefile:95` del fork; `__GLOBAL__sub_I_command.cpp` llama a `___cxa_atexit` (el envoltorio `xnu-clang++` de HackiOS pondría `_atexit`, `xnu-deps/host/bin/xnu-clang:8`) |
| Plug-in: `-O1 -g`, en la misma orden que el enlace | 607 de 613 funciones idénticas con `-O1` (las otras 6, §2.4); `OSO` en `/tmp` |
| Mesa: `-O3`, **LTO completo**, **`-mcpu=cortex-a73`** | Símbolos locales renombrados por el fusionador de módulos de LLVM (`_emit_atomic.1204`, `_nir_imm_int.316`…: 103 nombres con sufijo `.N`); decenas de símbolos importados sin stub, como `_longjmp`, `_pthread_cond_wait` o `_host_statistics64` (referencias eliminadas tras el LTO); funciones a 16 bytes. Con esas tres opciones el tamaño de todas las secciones salvo `__text` coincide al byte (§2.4) |
| Orden de enlace | `otool -L`: Foundation, CoreFoundation, libobjc, IOKit, IOSurface, Metal, libc++, libz, libSystem |
| Los 5 símbolos de Metal sobre Vulkan quedan débiles | `nm -m`: `_native_bridge_metal_{open,first_problem,status,formats,variant_hook}` "weak external (dynamically looked up)": enlazado sin `M2V=1`, con `-U` o `-undefined dynamic_lookup` |
| HackiOS compila con LLVM 22 | El fixture `null_fs` embebido dice `22.1.8` en upstream y `18.1.8` en el fork. Con clang 18 el upstream no compila (§5, parche 0001) |

### 2.4 Comparación función a función

`scripts/fncmp.py` desensambla con `llvm-objdump`, parte por `LC_FUNCTION_STARTS`, y normaliza: quita
direcciones, nombra destinos de salto y stubs, y sustituye cada par `ADRP`+`ADD/LDR/STR` por lo que hay en la
dirección (cadena, selector, CFString, import, símbolo+desplazamiento o bytes del literal), con un análisis de
flujo por bloques para saber qué página lleva cada registro. Dos funciones son "idénticas" si esa forma
normalizada coincide entera.

Binario de Angel frente a la reconstrucción del fork en `bd4c247` (`rebuild/out/angel-src`, Mesa con LTO y
cortex-a73):

| Rango | Idénticas | Mismas instrucciones, un dato descrito distinto | Distintas | Sin pareja por nombre |
|---|---|---|---|---|
| Plug-in + núcleo (1558) | **1551** (684 772 B, 97,3 %) | 0 | **7** | 0 |
| Mesa (2217) | 1974 (63,6 % de los bytes) | 57 | 83 | 103 |

Tamaños de sección: iguales al byte en `__cstring`, `__gcc_except_tab`, `__objc_*`, `__DATA_CONST,__const`,
`__data`, `__bss`, `__common`, `__thread_*`, `__got`; `__text` 0x273044 frente a 0x273214 (464 bytes).

Las 7 funciones distintas del driver:

- **6 del plug-in, 8 llamadas**: el original llama a `_strlcpy`/`_strlcat` y la reconstrucción a
  `___strlcpy_chk`/`___strlcat_chk` con el tamaño del objeto igual al tamaño pedido (`mov w3, #N` añadido).
  Funciones: `-[HakiosMetalDevice initWithAcceleratorPort:]` y su bloque, `newCommandQueueWithDescriptor:`,
  `newRenderPipelineStateWithDescriptor:error:` (2), `hm_fps_note` (2), `ca_prof_main`. El comportamiento es el
  mismo. En el original la macro de `secure/_string.h:105-113` no está activa para esas dos funciones y sí para
  `memcpy` (hay un `___memcpy_chk` en `__hm_ca_load_block_invoke` en ambos); la causa en el entorno de Angel
  no está identificada (§9).
- **`compileStage` (`0x490a0`)**: las constantes de la clave de la caché de stages. clang pliega el hash de
  `kCacheBuild` y de `sizeof(Stage)`, `sizeof(Kernel)` (1448 y 848) en dos constantes; en el original son
  `0x33d8eb895ee83ddb` y `0x8cf0774e6fe4b6d7`. `scripts/cachekey.py` reproduce las de la reconstrucción a partir
  de su clave, y descarta que la del original sea `__DATE__ " " __TIME__` (ningún segundo del 1 al 14 de
  noviembre de 2026 las da): es el hash de 24 hex de `Makefile:103-106` sobre `compiler.cpp`, las cabeceras y
  los archivos `.a` de Mesa de Angel, no recuperable.

En Mesa, las 83 distintas son en su mayoría de 1 a 30 instrucciones sobre miles con el mismo tamaño (decisiones
del LTO); las 103 sin pareja son las mismas funciones con otro número de sufijo. No se ha buscado la identidad
bit a bit de Mesa: su propio `tools/mk-mesa.sh` avisa de que el build no es reproducible byte a byte.

## 3. Interfaz con el kernel y configuración

### 3.1 Servicio y peticiones

| Lado | Evidencia |
|---|---|
| Driver | `IOServiceMatching(HAKIOS_GPU_SERVICE)`, `IOServiceOpen(tipo 0)`, cada petición es `IOConnectCallStructMethod(selector = número de msm_drm.h)`, la memoria de un buffer es `IOConnectMapMemory64(tipo = handle)` (`hakios-metal/src/iokit_transport.cpp:31-62`) |
| Selectores que usa | `0x09` GEM_CLOSE, `0x40` GET_PARAM, `0x42` GEM_NEW, `0x43` GEM_INFO, `0x44` CPU_PREP, `0x45` CPU_FINI, `0x46` SUBMIT, `0x47` WAIT_FENCE, `0x4a`/`0x4b` SUBMITQUEUE, `0x7e` superficie (`include/hakios-metal/gpu.hpp:22-34`) |
| Kernel de este port | Servicio `SapphireGPU`, cliente `SapphireGPUClient` (`SapphireGpu.cpp:4190-4191` de la reconstrucción de 09); los mismos números (`:3139-3152`) y `struct msm_surface` de 40 bytes (`:3175-3181`) igual que `HakiosSurface` (`gpu.hpp:59`) |
| `GET_PARAM` del kernel | GPU_ID 610, GMEM_SIZE 128 KB, CHIP_ID `0x06010001`, GMEM_BASE `0x100000`, HIGHEST_BANK_BIT 14, FAULTS (`SapphireGpu.cpp:4038-4056`) |

El driver solo lee del kernel el chip id (para negarse con otro Adreno, `c_api.cpp:217-239`) y FAULTS. El resto
de datos del chip son constantes de compilación en `a6xx.hpp`; por eso el port es un cambio de constantes.

### 3.2 Archivos, variables y conmutadores (sin recompilar)

Rutas en el binario de Angel:

| Ruta | Uso |
|---|---|
| `/private/var/db/hakios-metal-cache` | Caché de stages compilados (`HAKIOS_METAL_CACHE`, la fija el plug-in); `/var/tmp/hakios-metal-cache` si no se puede escribir. 202 archivos `<32 hex>.stage` en el teléfono |
| `/redwood/share/hakios-metal-cache` | Semilla de solo lectura (`HAKIOS_METAL_CACHE_SEED`); no existe en el teléfono |
| `<caché>/spec-<16 hex>.keys` | Solo Angel: claves de especialización recordadas por pipeline |
| `/var/tmp/metal.args` | Solo Angel: palabras que se añaden a `kern.bootargs` para los conmutadores `metal_*` |
| `/var/tmp/metal.snap`, `/var/tmp/snap-N.raw`, `/var/tmp/metal.watch`, `/var/tmp/hm-stacks.txt`, `/var/tmp/hm-thread.txt` | Solo Angel: diagnósticos |
| `/System/Library/Frameworks/QuartzCore.framework/default.pipelinelib/{pipelines.desc,functions}` | Variantes de los uber shaders de CoreAnimation |
| `/redwood/share/ca-share/QuartzCore-default.metallib` | Sustituto de HackiOS para un QuartzCore sin `default.metallib`; no existe en el teléfono |
| `/redwood/lib/libvulkan_freedreno.dylib`, `/private/var/db/m2v`, `/private/var/tmp/m2v*` | Metal sobre Vulkan (`metal_m2v=1`), no enlazado |

Conmutadores que lee el plug-in de `kern.bootargs` (y, en el de Angel, de `/var/tmp/metal.args`; cada uno se lee
una vez por proceso, así que hay que reiniciar backboardd):

| Conmutador | Efecto |
|---|---|
| `metal_fps` (`=draws`, `=passes`, `=mainpass`, `=sample`, `=timeline`; Angel: `=thread`) | Contadores y tiempos por frame, por pase y por draw; `=sample` muestrea el hilo dentro de un draw |
| `ca_prof=<µs>` | Muestreador de pila del proceso |
| `touch_lat=1` | Líneas `tl:` de latencia |
| `metal_trace=1`, `metal_trace_release`, `metal_dump=<hash>`, `metal_dump=cfg:<nombre>`, `metal_skip=<palabra>` | Trazas de draws, volcado de AIR, omitir draws |
| `metal_gmem=1`, `metal_gmem_off=<bits>`, `metal_gmem_draws=<n>` | Renderizado por tiles (apagado por defecto) |
| `metal_defer=1` | Grabación diferida en un hilo del driver |
| `metal_noubwc`, `metal_nospec`, `metal_strict`, `metal_all=1`, `metal_luma_boost=1` | Sin UBWC, sin especialización, modo estricto, dispositivo para todo proceso, dibujar luma_boost |
| Solo Angel: `metal_ca_variants`, `metal_fc_off=N[:N]`, `metal_snap`, `metal_watch=<palabra>`, `metal_fbprobe`, `metal_skipgrad=1` | Variantes de la pipeline library en vez de genéricos; diagnósticos |

Variables de entorno del núcleo: `HAKIOS_METAL_CACHE`, `HAKIOS_METAL_CACHE_SEED`, `HAKIOS_METAL_LISTING`,
`HAKIOS_METAL_STRICT`, `HAKIOS_METAL_FAKE` (GPU simulada), `FAKE_FAULTS` (solo Angel), y las de Mesa
(`IR3_SHADER_DEBUG`, `NIR_DEBUG`, `FD_DEV_FEATURES`, `MESA_LOG`, `MESA_LOG_FILE`).

## 4. Auditoría de los cambios de Angel

Clases: **(a)** necesario y correcto según fuente primaria; **(b)** necesario pero con un valor mal o sin
justificar; **(c)** optimización o atajo sin medición; **(d)** función propia del port. Fuentes: Mesa 25.0.7
(la enlazada; el sha256 del tarball es el que fija `tools/mk-mesa.sh`), en particular la fila que su build
genera para el A610, `freedreno_devices.h:67` `{ {610, 0x60100ff}, "FD610", &__info6 }`; Linux v6.12; la
reconstrucción del kernel de este port (informe 09).

### 4.1 Núcleo (`hakios-metal/`)

| Cambio de Angel | Clase | Veredicto y fuente |
|---|---|---|
| `kChipId = 0x06010001` | (a) | Es lo que responde el kernel (`SapphireGpu.cpp:4045`); `hakios_metal_open` rechaza otro id (`c_api.cpp:217-239`). Linux: familia `ADRENO_CHIP_IDS(0x06010000)` (`a6xx_catalog.c:676`) |
| `kHasLpac=false`, `kSupportsDoubleThreadsize=false`, `kInstrCacheSize=64`, `kFibersPerSp=2048`, `kNumSpCores=1`, `kCsSharedMemSize=16384`, `kWaveGranularity=1` | (a) | Coinciden con `__info6` (`freedreno_devices.py:353-369, 445-458`) |
| 12 registros mágicos | (a) | Coinciden uno a uno con `__info6 .a6xx.magic` (`freedreno_devices.py:463-477`) |
| Sin fast clear de GMEM, 1 CCU, cachés de 8 KB, fracción HALF, 16 pipes VSC, rejilla 32×16 / 1024×1008 | (a) | `__info6` |
| `kGmemBase = 0x100000` y su suma en el descriptor de framebuffer fetch (`render.cpp`) | (a) | Kernel `UCHE_GMEM_RANGE_MIN` (`SapphireGpu.cpp:1233`, `:4048`); Linux `adreno_gpu.c:325-330`; turnip `tu_cmd_buffer.cc:1946` |
| `kGmemBytes = 128 KB` | **(b)** | El kernel programa el rango `0x100000`…`+0x21000-1` (`SapphireGpu.cpp:1234`) y Linux da al A610 `.gmem = SZ_128K + SZ_4K` (`a6xx_catalog.c:683`). turnip pone la caché de color de la CCU al final, en `0x20000` (`tu_device.cc:1431-1457`), y usa lo de debajo para tiles (`tu_pass.cc:627-628`). Con 128 KB la caché cae en `0x1f000` y al planificador (`render.cpp:2201-2203`, alineado a 16 KB) le quedan 112 KB en vez de 128. **Valor correcto: `0x21000`.** Solo afecta con `metal_gmem=1` |
| `id.gpu_id = 610` en `compiler.cpp` y `texture.cpp` | (c) | Innecesario: la fila de Mesa lleva `chip_id 0x060100ff` y `dev_id_compare` casa `0x06010001` por el comodín de parche (`freedreno_dev_info.c:38-44`) |
| Cómputo: `THREAD128` en `HLSQ_CS_CNTL_1` y `SP_CS_CTRL_REG0`, tamaño real en `HLSQ_FS_CNTL_0`, copias del SP solo con `has_lpac` | (a) | `fd6_compute.cc:96-127`, `fd6_program.cc:170-180` |
| Filtro bicúbico rechazado | (a) | `has_tex_filter_cubic` solo en gen3 y gen4 (`freedreno_devices.py:396, 419`) |
| Formatos ASTC HDR fuera | (b) | Conservador, sin medición en el A610. Mesa no tiene ASTC HDR para ningún Adreno (`fd6_format_table.c:324-352`) |
| Servicio `SapphireGPU` | (a) | `SapphireGpu.cpp:4191`. Angel lo ata al macro del chip; el nombre es del kernel, no del chip |
| `fui()` con `__builtin_bit_cast` | (a) | Arreglo de compilación: con clang 18 el upstream falla en `a6xx.hpp:3977` (`-Winvalid-constexpr`, `__builtin_signbit`). Basta cambiar una línea |
| `Makefile`: `-O3 -mcpu=cortex-a73`, `-Wno-missing-field-initializers` | (c) | Sin medición. El aviso solo lo provocan sus propios cambios: el upstream compila con `-Wall -Wextra -Werror` |
| `RegShadow` como tabla plana de 512 KB con generaciones y pool de 16 | (c) | Sin medición publicada. Su propio WIP dice que falla la caché y la sustituye por bloques (`patches-wip/…diff`) |
| `Stream::adopt/release/append`, pool de streams, `scratch` y streams `thread_local` en `appendDeduped` y `draw`, `Bindings` `thread_local` en `drawCommon`, `fsDrawn` y rangos `thread_local` en `encodeDraw`, arrays en pila en VFD, cadenas perezosas en `checkTarget`, `push_back` en `Stream::registers` | (c) | Sin medición publicada. Tocan justo la ruta que el perfil señala (`CommandBuffer::draw`, `encodeDraw`, `appendDeduped`) |
| `keep()`/`keepAlive()` con filtro de 64 recientes | (c) | Correcto (el filtro es por buffer de órdenes y lo guardado sigue vivo), sin medición |
| `Buffer::poolable` en `takeBuffer`/`giveBuffer` | (c) | Arregla un SIGSEGV que el upstream no puede tener: allí solo llegan a `giveBuffer` buffers hechos por `takeBuffer` (`command.cpp:88-95, 172-173, 408-409`) |
| `hakios_metal_cb_wait_scheduled` | (d) | Solo lo llama su plug-in; sin `metal_defer=1` vuelve al instante |
| `FAKE_FAULTS`, cambios en `fake_gpu.cpp`, fixtures, `bench_test.cpp`, `probe.cpp` | (d) | Pruebas y diagnóstico |

### 4.2 Plug-in (`userland/src/HakiosMetalCA.m`)

| Cambio de Angel | Clase | ¿Lo exige el kernel? |
|---|---|---|
| `hm_bootargs`: `kern.bootargs` + `/var/tmp/metal.args` | (d) | No. Comodidad para probar conmutadores sin reflashear |
| Uber shaders genéricos por defecto (`metal_ca_variants` vuelve a las variantes) | (d) | No. Es una decisión de corrección de imagen: HackiOS sustituye cada `fixed_*` por la variante de la pipeline library, la "más cercana" si no la nombra; Angel dice que eso da frames azules, rojos o verdes aquí. **No verificado** |
| Especialización: 48 de 52 bytes, hasta 256 por pipeline, claves recordadas en disco, tabla de 512 entradas sin candado, y espera de hasta 3 s a que termine | (d) | No el kernel, pero sí su límite: el comentario dice que el uber shader genérico entero (32 000 instrucciones) sobre un área grande pasa de los 2 s del kernel y la GPU se reinicia. Va unido al punto anterior. **No verificado** |
| `hm_panel_scale`, `hm_panel_part`, `kern.sweet_fb_rscale`, `kern.sweet_fb_ids` | (d) | Solo si `kern.sweet_fb_rscale` < 1000 (parche 0321). En el teléfono vale 1000 (09 §0): inactivo |
| Conversión YCbCr por tablas, en bandas y fuera del hilo de render | (c) | No. Sin medición nuestra |
| `-commit`: los manejadores "scheduled" tras el envío, en una cola propia; `-waitUntilScheduled` espera | (d) | No. Solo cambia algo con `metal_defer=1` |
| `metal_snap`, `metal_watch`, `metal_fc_off`, `metal_fbprobe`, `metal_skipgrad`, `metal_fps=thread`, pilas a `/var/tmp` | (d) | No. Diagnósticos |

### 4.3 Lo que el port no toca y Mesa trata distinto en el A610

Presente igual en el binario de Angel y en el bundle propio. Ninguno se ha probado.

| Supuesto del A635 que queda | Mesa para el A610 |
|---|---|
| `RB_RENDER_CNTL` escrito como registro normal (`render.cpp:1682`: "has_cp_reg_write is false here") | `has_cp_reg_write=True`: turnip lo escribe con `CP_REG_WRITE` y rastreador |
| Cuatro registros de shading rate `0x8a00`…`0x8a30` puestos a 0 (`render.cpp:1960`, `a6xx.hpp:2797`) | `has_legacy_pipeline_shading_rate` es solo de gen4: Mesa no los escribe |
| Hasta 32 atributos de vértice | `vs_max_inputs_count=16` |
| Draws indirectos sin `CP_WAIT_FOR_ME` | `indirect_draw_wfm_quirk=True` |

Del lado del kernel (para 09): no programa `RB/TPL1/SP_NC_MODE_CNTL` ni `UCHE_MODE_CNTL` (Linux
`a6xx_set_ubwc_config`), y responde HIGHEST_BANK_BIT 14 cuando Linux y Mesa dan 13 al A610
(`a6xx_gpu.c:513-517`, `__info6 .highest_bank_bit=13`). El driver toma el valor de Mesa, no el del kernel.

## 5. El parche A610 propio

Base: `oosexgang/hakios-xnu-kernel` `main` en **`63fc2b4633bac3af8e57dadab9f5a8d4cb940438`** (2026-11-06). Es el
`main` más reciente (comprobado con `git fetch` y `gh api` el 14 de noviembre; las ramas `mtk` y
`legacy-hackios` son otras líneas) y es la base del fork de Angel, así que la comparación es directa.

Serie en `rebuild/patches/a610/` (rama `sapphire-a610-propio` de `rebuild/hakios-upstream`):

| Parche | Qué hace | Fuente |
|---|---|---|
| `0001` `fui()` como expresión constante con clang 18 | Una línea: `__builtin_copysignf` en lugar de `__builtin_signbit` | Error de compilación reproducido |
| `0002` Los datos del chip | Bloque `#if defined(HAKIOS_CHIP_A610)` en `a6xx.hpp` con cada valor citado a `__info6`; GMEM `0x100000` + `0x21000`; `RB_CCU_CNTL` según la fracción; 16 pipes; `kGmemBase` en el framebuffer fetch | Mesa 25.0.7, Linux v6.12, kernel del port |
| `0003` Tamaño de hilo de cómputo | `THREAD128` + `HLSQ_FS_CNTL_0`; copias del SP con `has_lpac`; la GPU simulada comprueba lo mismo | `fd6_compute.cc:96-127`, `fd6_program.cc:170-180` |
| `0004` Bicúbico rechazado | | `freedreno_devices.py:396, 419` |
| `0005` Sin ASTC HDR | Conservador | `fd6_format_table.c:324-352` |
| `0006` Servicio y chip desde `make` | `make ios MESA=1 CHIP=a610 GPU_SERVICE=SapphireGPU IOS_EXTRA=…` | `SapphireGpu.cpp:4190-4191` |

Opcionales, en `rebuild/patches/opcional/` (rama `opcional-puerto`), cada uno separado:

| Parche | Clase | Para qué |
|---|---|---|
| `0001` `/var/tmp/metal.args` | (d) | Activar conmutadores en el A/B sin reflashear. Reescrito, no copiado |
| `0002` `hakios_metal_cb_wait_scheduled` | (d) | Solo para enlazar este núcleo con el plug-in de Angel |

Diferencias deliberadas con Angel: GMEM de `0x21000`; sin `gpu_id`; nombre del servicio independiente del chip;
`-O2` de HackiOS en el núcleo (más `-g`); ninguna de sus optimizaciones ni funciones del port.

## 6. Receta

Todo está en `~/sapphire-angel/research/metal/rebuild/`. `receta.sh` hace los pasos de cero; cada paso se ha
ejecutado por separado en esta Mac.

```sh
cd ~/sapphire-angel/research/metal/rebuild
./receta.sh                      # upstream 63fc2b4 + patches/a610      -> out/propio
SRC_KIND=opcional ./receta.sh    # ... + patches/opcional               -> out/propio-args
SRC_KIND=angel ./receta.sh       # fork de Angel en bd4c247             -> out/angel-src
```

| Dependencia | Versión | De dónde |
|---|---|---|
| clang, clang++, ld64.lld, llvm-ar | 18.1.8 | conda-forge con micromamba (prefijo propio `llvm18/`) |
| bison, flex, m4 | 3.8.2, 2.6.4 | conda-forge (`hosttools/`); el bison 2.3 de macOS no lee las gramáticas de Mesa |
| SDK | theos `iPhoneOS16.5.sdk`, commit `0222fd5` de `theos/sdks` | sparse checkout, 260 MB |
| Mesa | 25.0.7, sha256 `592272df…f8a6` | archive.mesa3d.org, con `tools/mesa/*.patch` (8), `hakios-drm` y `air` del árbol |
| meson, mako, pyyaml, packaging | 1.6.1 y actuales | venv de Python 3.12 con `uv` |
| En la máquina | git, curl, make, ninja, uv, codesign | |

Pasos y lo que no es obvio:

1. **Toolchain.** Apartar `llvm18/include/c++`: si está, clang usa la libc++ de conda en vez de la del SDK.
2. **Mesa** (`build-mesa.sh`): opciones de `tools/mk-mesa.sh` más `-Db_lto=true` y `-mcpu=cortex-a73` en el
   archivo cruzado; solo se construyen los 13 `.a` que enlaza el driver (442 pasos, 1 min 20 s). El directorio
   debe llamarse o enlazarse como `mesa/build-softpipe-freedreno` (`tools/compiler.mk`).
3. **Núcleo** (`build-bundle.sh`, paso 1): `make ios MESA=1 HAKIOS=… SDK=… IOS_MESA_ROOT=… IOS_CXX="clang++
   -target arm64-apple-ios16.0 -isysroot …" IOS_AR="llvm-ar --format=darwin rcs"`, con `CHIP=a610
   GPU_SERVICE=SapphireGPU` en el árbol propio o `-DHAKIOS_CHIP_A610` dentro de `IOS_CXX` en el de Angel.
4. **Plug-in y enlace** en una orden: `clang -target arm64-apple-ios16.0 -isysroot … -fuse-ld=lld -O1 -g -bundle
   -framework Foundation -framework CoreFoundation -lobjc -framework IOKit -framework IOSurface -framework Metal
   -DHAKIOS_METAL_GPU -I…/include HakiosMetalCA.m libhakios-metal.a -lc++ <13 .a de Mesa> -lz -lm
   -Wl,-U,_native_bridge_metal_{open,first_problem,status,formats,variant_hook}`.
5. **Firma**: `codesign -f -s - -i HakiosMetal --pagesize 4096` sobre una copia en un directorio vacío (junto a
   `Info.plist`, codesign toma el directorio por un bundle y la verificación falla).

En Linux los pasos son los mismos con `clang-18`/`lld-18` de la distribución y `ldid -S` para firmar; no se ha
ejecutado allí.

**Caché de stages.** Cada build lleva su clave (hash del compilador y de los `.a` de Mesa): un bundle nuevo no
encuentra los 202 stages del teléfono y los recompila en el primer uso (hasta 1 s cada uno según
`compiler.cpp:1105-1114`). Los archivos viejos solo ocupan sitio.

## 7. Bundles construidos

En `rebuild/out/<nombre>/{HakiosMetal,Info.plist}`, firmados ad hoc. Ninguno se ha instalado ni cargado en el
teléfono.

| Nombre | Núcleo | Plug-in | sha256 | Para qué en el A/B |
|---|---|---|---|---|
| `angel-src` | fork `bd4c247` | fork `bd4c247` | `f1ac8ade5f5657cb45b155dcb93157721923dcecc2fba2601050dbd96c46fb3f` | Control: mismo código que `13bbd782`; valida toolchain y receta en el teléfono |
| `propio` | upstream + `a610/` | upstream sin cambios | `9231da46256b67f8fc66589a1c3fddef0bd857f56cc0e7d0f03eee2527201f40` | El bundle propio |
| `propio-args` | upstream + `a610/` + `opcional/` | upstream + `metal.args` | `216cdeedaae68d5431af96a4a35fdb67f2b46349830b313d81227e77799b4bcc` | El propio, con conmutadores por archivo |
| `propio-plugin-angel` | upstream + `a610/` + `opcional/0002` | fork `bd4c247` | `1333623ed4cca795d895383df3b5f7f4a06a50c0d709574ee7447f005512087b` | Aísla el núcleo: mide qué aportan las optimizaciones de Angel con su mismo plug-in |

Comprobado fuera del teléfono en `propio`: `minos 16.0`, `sdk 16.4`, LLD 18.1.8, las mismas 9 bibliotecas en el
mismo orden, las mismas 18 clases ObjC `Hakios*`, 387 símbolos importados frente a 392 (faltan los 7 que solo
usa el código de Angel y sobran los dos `_chk`), firma que `codesign -v` acepta.

Orden sugerido: `angel-src` primero (si no se comporta como `13bbd782`, el fallo es de la receta, no del
parche); después `propio-plugin-angel`; por último `propio` o `propio-args`, mirando colores y reinicios de GPU.

## 8. Código que sirve uno y rechaza el otro

Entre el upstream con el parche propio y el binario de Angel, por cadenas y símbolos (`out/propio/stabs.txt`
frente a `stabs.angel.txt`):

| Qué | Upstream + `a610/` | Binario de Angel |
|---|---|---|
| Otro Adreno que `0x06010001` | Rechazado por nombre | Igual |
| Sampler bicúbico | Rechazado | Rechazado |
| ASTC HDR | Rechazado | Rechazado |
| Especializaciones por pipeline | Hasta 64, por los bytes enteros del buffer | Hasta 256, por 48 de 52 bytes, recordadas en disco |
| Draw con especialización en curso | Se dibuja con el programa de la pipeline | Espera hasta 3 s |
| `fixed_*` de CoreAnimation | Variante de la pipeline library | Genérico con las constantes de la pipeline |
| Funciones solo en Angel | — | Plug-in: `hm_bootargs`, `hm_fbprobe`, `hm_panel_scale`, `hakiosSpecialise:remember:`, `hakiosConvertYCbCrRows` y 7 bloques. Núcleo: `hakios_metal_cb_wait_scheduled`, `RegShadow::take/give/~RegShadow`, el constructor de `CommandBuffer` con pool |

El mensaje de error de Angel sigue diciendo "no HakiosGPU service" aunque busca `SapphireGPU`.

## 9. No verificado

- **Nada se ha ejecutado en el teléfono.** Que los bundles carguen y dibujen es una predicción a partir de la
  comparación de código, de los `.tbd` y de la firma.
- Si el plug-in de HackiOS sin cambios pinta bien en este teléfono (uber shaders por variantes) y si el genérico
  de Angel provoca reinicios de GPU sin la espera de especialización.
- Por qué en el build de Angel `strlcpy`/`strlcat` no pasan por la macro de fortify. Ninguna opción probada lo
  reproduce (`-target` iOS 16.0/16.5/darwin, `-std`, `-ffreestanding`, `-fno-builtin`).
- La clave de caché del build de Angel y, por tanto, si sus stages son reutilizables.
- La identidad bit a bit de la parte de Mesa (83 funciones con diferencias pequeñas).
- Las pruebas del driver (`make test`) con las constantes del A610: los fixtures del upstream son del A635.
- Los cuatro supuestos de §4.3 y el efecto real de `0x21000` de GMEM con `metal_gmem=1`.
- La receta en Linux y `receta.sh` de un tirón desde un directorio vacío.
- Los envoltorios y scripts con los que Angel compila (no publicados): opciones exactas de su `xnu-clang` y de
  su build de Mesa más allá de lo que muestra el binario.
