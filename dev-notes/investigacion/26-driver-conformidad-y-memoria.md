# 26 — Driver Metal: memoria compartida, compilación antes de la interfaz y conformidad (rama `cpu-draw`)

Informe del trabajo sobre el driver Metal propio (núcleo `hakios-metal` y plug-in `userland/src/HakiosMetalCA.m`, rama
`cpu-draw` del árbol `~/sapphire-angel/research/metal/rebuild/wt-cpu`) y del kernel que necesita (parche 0380). Continúa
el relevo de 13 §11; las no conformidades son las de 19 §2.9.

Etiquetas: **[O]** visto en el código o en un binario (con archivo:línea o dirección), **[M]** medido (en el host o en el
teléfono, con n), **[H]** hipótesis. Lo que no está verificado se dice.

## Resultado en breve

1. **Causa de los widgets invisibles de `merge-6` (N-12, N-07): demostrada.** QuartzCore toma una imagen como *client
   storage* —un buffer *no-copy* sobre sus propias páginas y una textura sobre sus filas— cuando el puntero y las filas
   son múltiplos de `deviceLinearReadOnlyTextureAlignmentBytes`, y desde entonces no vuelve a subir esa imagen. La
   respuesta que lo dispara es la pareja de IOSurface (`metal_align=1`), que eleva la alineación con que CoreAnimation
   dispone todos sus bitmaps; el driver copiaba el buffer *no-copy* al crearlo, así que lo escrito después en la imagen
   no llegaba a la GPU (§1.1-§1.2). [M] El A/B del teléfono lo confirma: `metal_align=1` pierde los widgets como
   `merge-6`; `metal_align=2` no.
2. **Un buffer *no-copy* es la memoria del llamante** (`merge-8` y siguientes): el kernel la cablea y la mapea en la GPU
   (petición 0x7d, parche 0380) y mantiene las cachés por página, limpiando solo las páginas que una CPU escribió desde
   la vez anterior, con un *test-and-clear* del bit *modified* del pmap hecho sin carrera (§1.3-§1.4). Sin 0380 el
   driver devuelve `nil` (fallo conforme: QuartzCore sube la imagen) en lugar de una copia. La alineación de 64 B se
   declara cuando el kernel comparte memoria (§1.5).
3. **Los accesos de CPU del driver a superficies se avisan al kernel** (`GEM_CPU_PREP`/`GEM_CPU_FINI` en
   `-replaceRegion:`/`-getBytes:` de texturas sobre IOSurface), como exige la cuenta de 0339 con
   `kern.sweet_gpu_flush=1` (27 §2.5) (§2).
4. **Nada compilado en uso tras un cambio de compilador:** cada stage y cada kernel compilado deja su receta
   (independiente de la build) y el dispositivo compila al crearse, antes del primer frame, las recetas que la build no
   tiene. [M, host] 388 recetas recompiladas en 5,7 s, idénticas byte a byte; con todo archivado, 31,6 ms (§3).
5. **Fondo corrupto en modo seguro:** las trazas capturadas no muestran el estado corrupto; el fondo son 5 texturas UBWC
   (no *client storage*). Pendiente de una captura en el estado corrupto y del A/B `metal_noubwc` (§4).

## 1. Memoria sin copia (N-12) y alineación declarada (N-07)

### 1.1 Lo que hace CoreAnimation [O, QuartzCore 20H392, desensamblado `ios-20H392/desensamblado/QuartzCore.named.s.gz`]

- `CA::OGL::MetalContext::copy_image_to_texture(CA::Render::Image*, CA::OGL::MetalImage*)` (0x18848426c) es el único
  sitio de QuartzCore que llama a `newBufferWithBytesNoCopy:length:options:deallocator:` (`QuartzCore.msgsend_callsites.txt`:
  1 sitio). Pide a la vez `deviceLinearReadOnlyTextureAlignmentBytes` (0x188484300) y exige que el puntero de los píxeles
  y sus *row bytes* sean múltiplos de esa respuesta (0x188484304-0x188484318). Si lo son, redondea el puntero a página
  (`min(vm_page_size, vm_kernel_page_size)`) y la longitud a página (0x188484358-0x188484374), crea el buffer *no-copy*
  con opciones 0 y *deallocator* nulo (0x18848438c; etiqueta `com.apple.coreanimation.buffer-client-storage`), copia al
  descriptor el `cpuCacheMode` y el `storageMode` del buffer, crea sobre él una textura lineal con offset
  (`newLinearTextureWithDescriptor:offset:bytesPerRow:bytesPerImage:`, 0x1884843f4; etiqueta
  `com.apple.coreanimation.image-client-storage`) y marca la imagen con el bit 0x200 (0x188484424-0x18848442c). Si el buffer
  sale `nil` registra «nil buffer from memory: …» y devuelve 0: la imagen se sube por la ruta normal.
- `CA::OGL::MetalContext::update_image` (0x18835728c) llama a `copy_image_to_texture` al crear la textura de una imagen y,
  cuando la imagen cambia (otra *seed*), vuelve a subirla con `replaceRegion` **salvo que tenga el bit 0x200**
  (0x1883574dc-0x1883574e0: `tbnz w8, #9`): para una textura *client storage* solo apunta la *seed* nueva. CoreAnimation
  cuenta con que esa textura es la memoria de la imagen.
- `iosurfaceReadOnlyTextureAlignmentBytes` → `CADeviceSetMinimumAlignment` (0x188488ac4), que eleva a ese valor como
  mínimo las cuatro alineaciones de `CADeviceInfo` (`alignment_values`, 0x188393ed8): la de la base de la imagen y la de
  sus filas. Las usan `CA::Render::format_rowbytes` (redondea las filas, 0x1882f993c) y `CA::Render::Shmem::new_bitmap`
  (la cabecera de 36 B del bitmap redondeada a la alineación, 0x18834a898), además de `copy_image`,
  `create_image_from_image_data`, `Surface::Surface` e `is_iosurface_aligned`. `init_alignment` las toma de la propiedad
  `BaseAddressAlignmentRequirement` del servicio `AGXAccelerator`, que este teléfono no tiene.
- `minimumLinearTextureAlignmentForPixelFormat:` solo la usa `CAMetalTextureGetBytesPerRow` (0x18847b35c), para leer
  texturas de vuelta; no interviene en la ruta de imágenes.

### 1.2 La causa de los widgets invisibles

- [O] Respuestas de la clase base con `merge-7` (`metal_align=0`), en la consola que guardó el ring
  (`display/telefono/ring-20261114/ring.txt:18605`, `:19950`, `:21087`): `iosurfaceReadOnlyTextureAlignmentBytes` = 4 y
  `deviceLinearReadOnlyTextureAlignmentBytes` = 64. `-[_MTLDevice deviceLinearReadOnlyTextureAlignmentBytes]` existe en
  Metal (0x181aae78c, `Metal.symaddr.txt`), y la textura lineal de `AGXA11FamilyDevice` también lo define.
- [O] Con 4, `Shmem::new_bitmap` pone los píxeles a 36 B del principio de su página: ninguna imagen de esa ruta pasa la
  prueba de 64. Con 64 (bit 1 de `metal_align`), las pasan todas.
- [M, trazas] *Client storage* por command buffer: 7,4-29,4 MB en las trazas de `merge-6` (`capturas-merge6/1093-1,-2,-3`;
  hasta 93 texturas y 32 MB en un buffer) frente a 0,12-0,21 MB con `merge-5`/`merge-7` (`capturas-recientes`,
  `capturas-blur`, `capturas-merge7`). En `merge-6` las imágenes subidas (`image`) son 0.
- [M, teléfono, coordinador, `medicion/shots/hoja-align.png`] `merge-7` con `metal_align=1` (solo la pareja de IOSurface a
  64): widgets de fondo opaco invisibles, como `merge-6`; con `metal_align=2` (solo las lineales): los cuatro visibles.
- Conclusión: el disparador es el bit 1; el defecto es N-12 (un buffer *no-copy* era una copia hecha al crearlo) más
  `update_image`, que no vuelve a subir una imagen *client storage*. Lo que muestre la imagen después de crear su
  buffer —un bitmap que otro proceso rellena, una memoria reutilizada— no llegaba nunca a la GPU.

### 1.3 Qué exige Metal y cómo lo cumple ahora el driver

[D, documentación de Metal] Un buffer de `newBufferWithBytesNoCopy:` **es** la memoria del llamante: lo que el llamante
escribe antes de confirmar un command buffer lo lee la GPU, lo que la GPU escribe lo ve el llamante cuando el command
buffer termina, y el *deallocator* se llama cuando el buffer se libera (después de los command buffers que lo usan). El
llamante da memoria alineada a página y de páginas enteras.

Núcleo (`hakios-metal`):

| Función | Archivo:línea | Qué hace |
|---|---|---|
| `Gpu::sharesMemory` | `src/gpu.cpp:113` | Pregunta una vez `GET_PARAM 0x1001` (`kParamUserMemory`): si el kernel sirve la petición 0x7d |
| `Gpu::userBo` | `src/gpu.cpp:123` | Petición 0x7d (`struct UserMemory`, 24 B) con el rango del programa; el `Bo` tiene `cpu()` = el puntero del llamante, no se mapea ni se desmapea nada (`Bo::mapped_`) y no cuenta en `allocatedBytes` |
| `newBufferNoCopy` | `src/command.cpp:75` | Rechaza por su frase memoria fuera de página o un kernel sin 0x7d; el `Buffer` lleva la llamada de liberación (el *deallocator*), que corre al destruirse, después del último command buffer que lo guardó |
| `hakios_metal_buffer_new_nocopy`, `hakios_metal_device_shares_memory`, `hakios_metal_buffer_is_program_memory`, `hakios_metal_texture_is_program_memory` | `src/c_api.cpp:396` y vecinas | La interfaz C para el plug-in |
| `FakeGpu`: `kUserMemory`, `setSharesMemory` | `src/fake_gpu.cpp:2886` | El fake sirve 0x7d sobre la propia memoria del programa (`Buffer::program`) y contesta 0x1001; `setSharesMemory(false)` es un kernel sin 0380 |

Plug-in:

| Función | Línea | Qué hace |
|---|---|---|
| `-newBufferWithBytesNoCopy:…` | `CA.m:3964` | Con un kernel que comparte memoria, el buffer es las páginas del llamante (`hm_nocopy_buffer`, `CA.m:603`); sin él, `nil` y una línea una vez; almacenamiento privado, `nil` |
| `hm_nocopy_released`, `struct hm_nocopy` | `CA.m:556-575` | El *deallocator* lo llama el núcleo al destruirse el buffer; `armed = NO` para memoria que vuelve al llamante sin llamada |
| `-cpuCacheMode`, `-resourceOptions` de un buffer | `CA.m:5562` | `DefaultCache` para memoria del programa (QuartzCore lo copia a su textura), `WriteCombined` para la del driver |
| `-newTextureWithBytesNoCopy:…` | `CA.m:4020` | Sin comprimir, en páginas enteras y con filas múltiplo de 64: una textura sobre un buffer *no-copy*; comprimida o en otra disposición: copia al crear, dicha una vez |
| `hm_nocopy_copies` (`metal_nocopy=0`) | `CA.m:3951` | Interruptor: la copia de antes, para el A/B |
| Traza | `CA.m:5824` | `program=1` en la línea `tex` de una textura sobre memoria del programa |
| Consola `fps:` | — | «N over the program's own memory (KB)» en la línea de buffers |

### 1.4 El kernel: parche 0380 (petición 0x7d y cuenta por página)

Fichero: `~/sapphire-angel/research/metal/conformidad/parches-nuevos/0380-sapphire-gpu-user-memory.patch` (19 hunks;
`iokit/Kernel/arm/SapphireGpu.cpp`, `osfmk/arm/pmap/pmap.c`, `osfmk/vm/pmap.h`). Árbol de trabajo
`conformidad/xnu-0380`, rama `serie-0370`.

- **La petición** (`SapphireGPUClient::userMemory`, `SapphireGpu.cpp:6746` en el árbol con la serie hasta 0370):
  `IOMemoryDescriptor::withAddressRange` sobre la tarea del cliente y `prepare(kIODirectionInOut)`, que cablea las
  páginas y [O, `osfmk/vm/vm_pageout.c:9754-9755`] las marca *dirty* para la VM (`SET_PAGE_DIRTY` cuando la petición no es
  `UPL_COPYOUT_FROM`): lo que la VM sabe del contenido de esas páginas no depende del bit *modified* del pmap mientras el
  buffer las tiene. Solo páginas que el pmap gestiona; direcciones de GPU página a página (`place`); como mucho 512 MB
  por cliente; `clientMemoryForType` la rechaza (el programa ya la tiene mapeada).
- **La coherencia.** [O] La GPU no es coherente con las cachés de CPU (el nodo `kgsl-smmu` del DT de este teléfono no
  tiene `dma-coherent`, `relojes/dtb/merged-khaje24a-sapphire.dts:8706-8720`), y la memoria del programa es cacheable en
  todos sus mapeos. Limpiarla entera en cada submit costaría 2-9 ms por submit con los 7-29 MB de *client storage* de las
  trazas de `merge-6` (a los ~3 GB/s de `dc civac` que midió 0336) [H por cuenta]. Por eso cada página lleva su cuenta:
  - `pmap_test_and_clear_modify` (`pmap.c:7290`, nueva): bajo el *PV lock* de la página, si el bit *modified* está
    puesto, protege contra escritura todos sus mapeos (`arm_force_fast_fault_with_flush_range` con
    `PMAP_OPTIONS_FF_LOCKED`, que invalida la TLB) y borra el bit; devuelve si estaba puesto. Primer vistazo sin cerrojo
    (una escritura que causó fallo antes de la llamada puso el bit antes).
  - **Por qué una función nueva** [O, `pmap.c:6952-7015`]: `pmap_clear_modify` protege los mapeos bajo el cerrojo y
    borra el bit **después** de soltarlo; un fallo de escritura en otro núcleo entre medias (`arm_fast_fault`, que pone el
    bit y vuelve a dar escritura bajo el mismo cerrojo) quedaría con el mapeo escribible y el bit borrado, y esa página no
    volvería a verse escrita. [M, modelo] `conformidad/modelo/modified_race.py` (todos los entrelazados de un escritor
    con dos almacenamientos frente al servicio): con `pmap_is_modified` + `pmap_clear_modify`, 168 de 835 entrelazados
    (página limpia al empezar) y 120 de 559 (página ya escrita) dejan la página sucia, escribible y sin marcar; con la
    función nueva, 0 de 365 y 0 de 223 (`modified_race.out`).
  - **En cada submit** (`msm_user_sync`, `SapphireGpu.cpp:6030`): para un buffer que el submit lee, cada página escrita
    desde la vez anterior se limpia (`dc cvac`); para uno que escribe, se limpia e invalida (`dc civac`). Por la
    dirección del mapa físico del kernel, línea a línea, con un `dsb` antes y después del buffer.
  - **Después de que la GPU escribe** (`msm_user_settle`, `:6056`): el buffer entero se limpia e invalida antes de que el
    programa lo lea —una línea traída durante el dibujo sería lo que lee— en el primer `WAIT_FENCE` o `CPU_PREP` del
    cliente que lo encuentra hecho, o al liberarlo.
  - **Al crearlo:** la cuenta de cada página empieza y todo el buffer se limpia e invalida. **Al liberarlo**
    (`msm_user_free`, `:6072`): se devuelve el bit a la VM (`pmap_set_modify`) y se descablea.
- **Interruptores:** `kern.sweet_gpu_usermem` (boot-arg `gpu_usermem`, 1): 0 rechaza la petición y `GET_PARAM 0x1001`
  contesta 0 (el driver da `nil`). `kern.sweet_gpu_usermem_track` (1): 0 mantiene todas las páginas en cada submit, la
  regla simple contra la que comparar. `kern.sweet_gpu_usermem_stats`: buffers hechos, rechazados y liberados, bytes,
  páginas miradas, limpiadas e invalidadas, y tiempos.
- **Lo que no cubre:** una CPU escribiendo las páginas mientras la GPU las lee (nada ordena las dos cosas, tampoco en
  Metal), y una página con un mapeo cableado en el pmap (`mlock`), que no se puede proteger: contesta «escrita» siempre
  y se mantiene siempre.
- **Verificación:** `conformidad/verif/check-0380.sh` (log `check-0380.log`) clona el árbol a 0342 del coordinador
  (`kernel-gpu/parches-nuevos/work/xnu`, `04d564f`), aplica en orden con `git apply --check` antes de cada uno 0343-0354,
  0360-0362, 0370 y 0380 (los 17 aplican), compila con `-fsyntax-only` `SapphireGpu.cpp` (0 errores) y `pmap.c` (los 3
  errores de cabeceras generadas que faltan, iguales sin el parche; `conformidad/verif/syn-c.sh`), y comprueba con un
  identificador no declarado inyectado que las 8 funciones nuevas de `SapphireGpu.cpp` se compilan de verdad (8 de 8);
  la de `pmap.c` se comprobó igual. **Sin probar en el teléfono.**

### 1.5 La alineación declarada

`hm_align` (`CA.m:3784`) y las seis respuestas (`CA.m:3816` y vecinas): sin `metal_align`, 64 para la pareja de IOSurface
y para las lineales cuando el kernel comparte memoria, y las de la clase base si no (como `merge-7`); `metal_align=N`
fuerza los bits (1 la pareja de IOSurface, 2 las lineales; 0 ninguna). La línea de la primera cola dice las respuestas
en vigor, la de la clase base y si el kernel comparte memoria.

Con 64 declarado, CoreAnimation dispone sus IOSurfaces con filas múltiplo de 64 (`Surface::Surface` usa las mismas
alineaciones, §1.1) [H, sin medir]: deben desaparecer para ellas las copias por CPU de N-06 (filas de 2 848 B). Las
superficies de otros procesos siguen por la copia.

### 1.6 Pruebas de host

`tests/nocopy_test.cpp`, cada una con un gemelo hecho a la manera de antes (una copia tomada al crear el buffer):

| Prueba | Qué comprueba |
|---|---|
| `a_no_copy_buffer_is_the_programs_own_memory` | La GPU lee lo escrito después de crear el buffer (el gemelo lee los ceros de entonces) y lo que escribe queda en la memoria del programa |
| `a_no_copy_buffer_off_a_page_is_refused_by_name` | Memoria fuera de página: rechazo por su frase, sin pedir nada al kernel |
| `without_the_kernels_sharing_a_no_copy_buffer_is_refused_not_copied` | Un kernel sin 0x7d: rechazo por su frase (`ENOSYS`), sin copia |
| `the_deallocator_runs_after_the_last_command_buffer_that_used_it` | Con la GPU detenida, el *deallocator* no corre al soltar el buffer; corre al completarse el command buffer |
| `a_texture_over_a_no_copy_buffer_reads_the_programs_rows` | Una textura sobre el buffer con la cabecera y las filas de un bitmap de `Shmem` lee lo escrito después de crearla |

## 2. Accesos de CPU del driver a superficies

[O, 27 §2.5] Con `kern.sweet_gpu_flush=1` (0339) el kernel limpia o invalida una superficie solo alrededor de los
accesos de CPU de los que se entera (lock/unlock de IOSurface, mapeo, `GEM_CPU_PREP`/`GEM_CPU_FINI`). El driver escribía
y leía filas de superficies por su mapeo cacheable (`Texture::replace`/`read`) sin avisar (`cpu prep 0` en el teléfono).

- `Bo::cpuBegin`/`cpuEnd` (`src/gpu.cpp:105-111`): para el buffer de una superficie (`surfaceBo`, `Bo::surface()`),
  `GEM_CPU_PREP` (lectura, o lectura y escritura; espera a la GPU, y 0339 limpia e invalida) antes y `GEM_CPU_FINI` (mueve
  `cpuEpoch`) después. Nada para memoria WC del driver ni para memoria del programa (0380 lleva su cuenta).
- `CpuAccess` (`src/texture.cpp:654`) alrededor de las copias de `Texture::replace`, `read`, `replaceSlices` y
  `readSlices`; un rechazo previo no avisa de nada.
- Auditado sin cambio: las copias de superficies de N-06 y la conversión YCbCr de N-05 van con `IOSurfaceLock`/`Unlock`
  (traps que el kernel ve; `CA.m`, `-hakiosRefreshShadow`, `-hakiosWriteBackShadow`); la *staging* de las texturas UBWC,
  todos los buffers y lo que lee la traza son memoria WC del driver.
- Prueba: `tests/cpu_access_test.cpp` (el fake cuenta `cpuPreps`/`cpuFinis`: un PREP y un FINI por escritura y por
  lectura de una superficie; ninguno en una textura propia ni en un rechazo).
- Interruptor: `metal_cpuprep=0` (`hm_cpu_access_switch`, `CA.m:3066`).
- Verificación en el teléfono: `kern.sweet_gpu_diag` («cpu prep N») crece cuando hay `-replaceRegion:`/`-getBytes:` de
  superficies; `kern.sweet_gpu_flush=2` no sirve para esto (sigue negando el mapeo aunque los accesos vayan avisados).
- Fuera del driver, del kernel: un `IOSurfaceLock` de lectura de **otro** proceso tras dibujar la GPU no invalida (27
  §2.5.2); haría falta esperar `gpuFence` e invalidar en el trap.

## 3. Nada compilado en uso: recetas y precalentamiento

### 3.1 Qué se compilaba y cuándo [O, 13 §10.6, §11.6 b]

Los stages se archivaban solo como resultado, con la clave de la build (`stageCacheName`). Con un compilador nuevo (otra
clave) ninguno valía, y cada uno se compilaba cuando la interfaz lo pedía: el genérico de CoreAnimation 0,43-1,1 s por
configuración en la cola de fondo, y los módulos propios en el hilo de render. Los kernels de cómputo (`compileAir`) no
tenían caché: cada proceso los compilaba.

### 3.2 Recetas

`recipeNote` (`src/compiler.cpp:1555`): cada compilación que da resultado, compilada o encontrada, deja
`recipes/<hash>.recipe` en la caché escribible, con el bitcode por su hash (`recipes/<hash>.air`, una vez), las
constantes tal como se pasaron, `IBO_BASE` y, para un buffer conocido, su *binding*, la máscara de bytes leídos y sus
valores (0 fuera de la máscara: lo no leído no decidió nada, y compilar solo los valores da el mismo stage y la misma
máscara). La receta no depende de la build. Formato con *magic* `HMRC`, versión y longitudes comprobadas al leer
(`recipeParse`, `:1524`).

Los kernels se archivan como los stages (`kernelCacheName`, `:1591`; `compileAir`, `:1738`, sin el cerrojo del
compilador para mirar la caché).

Los ficheros `.stage` y `.kernel` se escriben con los punteros (`words`, `immediates`, `name`, `source`) y el id de los
samplers en línea a 0 (`fileStage`, `:1228`): la misma compilación da el mismo fichero en cualquier proceso. Los
ficheros escritos antes se siguen cargando (esos campos se rehacen al cargar); la clave no cambia.

### 3.3 Precalentamiento

`warmUp()` (`src/compiler.cpp:1831`): recorre las recetas de la caché escribible y de cada semilla y compila, en el hilo
que llama, las que no tienen su resultado archivado para esta build (para un buffer conocido, también por su índice,
`knownIndexHas`, `:1720`). `hakios_metal_warmup` lo lleva al plug-in, que lo ejecuta al final de
`-initWithAcceleratorPort:` (`hm_warm_up`, `CA.m:3078`): en backboardd, antes de su primer frame, con la pantalla de
arranque puesta y fuera del hilo de render. Consola: «warm-up: N recipes, F filed already, C compiled in X ms, K
failed, Y ms in all». Interruptor: `metal_warmup=0`. `tools/warmup.cpp`: el precalentamiento solo, para el host.

### 3.4 Medida en host [M, i5-7500, `conformidad/tools/warmup-host.sh`, log `conformidad/medida-warmup.log`]

| Qué | Resultado |
|---|---|
| Recetas de los 451 módulos de variante de la pipeline library de QuartzCore y del genérico para las 11 configuraciones del índice del teléfono | 388 recetas, 377 bitcodes, 4,6 MB; 388 stages, 3,6 MB |
| Precalentamiento sin ningún stage (como tras una clave nueva) | 388 compilados en 5,7 s, 0 fallos |
| Los stages recompilados frente a los compilados uno a uno | Idénticos byte a byte (375 contenidos distintos, todos en los dos) |
| Precalentamiento con todo archivado (lo que cuesta cada arranque) | 31,6 ms |

[H] En el teléfono el compilador fue 2-6 veces más lento que el host para el genérico (13 §10.6): 11-35 s para este
conjunto la primera vez tras un cambio de compilador.

### 3.5 Lo que falta

- **Un pipeline visto por primera vez** se compila cuando se pide (los módulos propios, en el hilo de render), y deja su
  receta. No compilar ni eso pide servirlo sin bloquear con un equivalente: para el uber shader, el genérico (`_gen`) con
  un `FragmentShaderConfig` hecho de las constantes; requiere la correspondencia constante → bytes de la configuración y
  el cambio de las etapas de vértice (atributos frente a *vertex pulling*). No estudiado.
- **El catálogo entero** (1 079 pipelines de `default.pipelinelib`) se puede recorrer en el teléfono con el propio
  plug-in (abrir la pipeline library y pedir cada nombre deja la receta de cada uno). No activado.
- **La semilla de instalación** (P1 de 22): con las recetas, puede ser solo entradas (recetas y bitcode) que el teléfono
  compila en su primer arranque; sus `.stage` valen si coinciden byte a byte, comprobable ahora. Coordinado con el
  agente del blur.
- **Recogida:** los `.stage` de claves anteriores y los duplicados por bytes de relleno quedan inertes en el directorio.

## 4. Fondo corrupto en modo seguro

[M, coordinador] En modo seguro de ElleKit (barra roja), el fondo de pantalla sale con bloques rectangulares negros y
trozos descolocados en la mitad inferior; fuera de él, bien con el mismo bundle (`medicion/shots/v-align2-home-0.png`,
`hoja-v2.png`).

- [O, cadenas de ElleKit 0.4.5 del teléfono] El modo seguro se activa con `/var/mobile/.eksafemode` y un reinicio de
  SpringBoard, o con volumen arriba al arrancar SpringBoard.
- [O, `trace/capturas-modoseguro/2380-1,-2,-3`] En las tres trazas el fondo son 5 texturas HEIC (Body 1271×1823, Arm
  1326×1326, Leg 1326×1160, Head 1105×1160, Head Mask 650×683) con `origin=compressed`, es decir UBWC: el plug-in hace
  UBWC toda textura RGBA8/BGRA8 de solo lectura de 256×256 o más (`hm_compress`) y la rellena por una *staging* lineal
  más una copia del motor 2D antes del primer draw que la muestrea (`CommandBuffer::freshen`). No son *client storage*.
  Las capturas de pantalla de esa sesión (`sf-lock-0.png`, `sf-home-0.png`) no muestran barra roja ni corrupción: el
  estado corrupto no está capturado.
- [H] Bloques negros más bloques descolocados es la forma de una lectura UBWC mal emparejada (disposición o banco entre
  la escritura del 2D y la lectura del TP, o banderas por bloque). Lo decide: el estado corrupto capturado (traza y
  consola) y el A/B con `metal_noubwc`.

## 5. Parpadeo del widget de Tiempo y destellos al abrir apps

Pendiente. Hipótesis de partida en 13 §11.7 (H1-H5). Candidatos nuevos tras §1 y §2: imágenes *client storage* copiadas
al crear (con `merge-7`, un tercio de las imágenes), y accesos de CPU a superficies sin avisar con
`kern.sweet_gpu_flush=1`; los dos quedan corregidos en `merge-9`.

## 6. Interruptores

| Interruptor | Por defecto | Qué hace |
|---|---|---|
| `metal_nocopy=0` | comparte | Un buffer *no-copy* es una copia hecha al crearlo (como hasta `merge-7`) |
| `metal_align=N` | 64 si el kernel comparte memoria; si no, la clase base | Bits: 1 la pareja de IOSurface, 2 las lineales; 0 ninguna |
| `metal_cpuprep=0` | avisa | Los accesos de CPU a filas de superficies no se avisan al kernel |
| `metal_warmup=0` | precalienta | No compila recetas al crear el dispositivo |
| `metal_noubwc` | UBWC | Todas las texturas lineales (heredado; diagnóstico del §4) |
| `kern.sweet_gpu_usermem` (`gpu_usermem`) | 1 | 0: la petición 0x7d rechazada y `GET_PARAM 0x1001` = 0 |
| `kern.sweet_gpu_usermem_track` (`gpu_usermem_track`) | 1 | 0: toda página de un buffer del programa mantenida en cada submit |

## 7. Bundles

En `~/sapphire-angel/research/metal/rebuild/out/NOMBRE/`, construidos con la receta de 13 §11.2 (`CACHE_BUILD`
`24ed84207640dc54c2b865f7`):

| Bundle | Commit | Bytes | sha256 | Qué añade |
|---|---|---|---|---|
| `merge-8` | `2a99fa0` | 8 799 632 | `15e556280bcfc7d4…` | Buffers *no-copy* compartidos (o `nil`), alineación con el kernel |
| `merge-9` | `145ed5b` | 8 828 608 | `d93a36832cc9cc4e…` | `merge-8` más recetas y precalentamiento, caché de kernels, ficheros deterministas, accesos de CPU a superficies avisados |

Suite de host en `145ed5b`: 290 pruebas sin fallos con las constantes de los dos chips, golden por las tres vías y de las
escenas con los stages del teléfono (`rebuild/cpu-tools/check.sh`). Los golden cambian solo en las líneas añadidas de las
pruebas nuevas. [M] `render_test.cpp:4242` (`a_command_buffer_released_in_flight_gives_its_buffers_back`, que cuenta
buffers vivos justo tras la espera) falló una vez en ~13 pasadas bajo carga y pasa 30 de 30 aislada, con y sin estos
cambios: comprobación dependiente del momento, anterior a este trabajo.

## 8. Cómo construir y probar

```sh
R=~/sapphire-angel/research/metal/rebuild; C=~/sapphire-angel/research/metal/conformidad
$R/cpu-tools/check.sh 2>&1 | grep -v 'left out'                 # suite y golden, los dos chips
$C/tools/build-hostwarm.sh                                      # stagecc y warmup con el Mesa nativo
$C/tools/warmup-host.sh $C/medida-warmup                        # la medida del §3.4
bash $C/verif/check-0380.sh                                     # 0380 sobre la serie del repo, sintaxis e inyección
python3 -I $C/modelo/modified_race.py                           # el modelo de la carrera del bit modified
cd $R && SRC=$R/wt-cpu IOS_EXTRA="-g" CACHE_BUILD=24ed84207640dc54c2b865f7 ./build-bundle.sh $R/out/NOMBRE
```

## 9. No verificado

- 0380 en el teléfono: que la petición cablee y mapee bien, que la cuenta por página no pierda escrituras (A/B
  `kern.sweet_gpu_usermem_track` 1 frente a 0) y su coste por submit (`kern.sweet_gpu_usermem_stats`).
- Que con 64 declarado desaparezcan las copias de N-06 para las superficies de CoreAnimation.
- El precalentamiento en el teléfono: tiempo de la primera vez tras un cambio de compilador, y que los stages que compila
  el teléfono sean idénticos a los del host.
- La causa del fondo corrupto en modo seguro (§4).

## 10. Dónde está cada cosa

| Ruta | Qué es |
|---|---|
| `rebuild/wt-cpu` (rama `cpu-draw`) | El driver; commits `ca279ab` … `145ed5b` |
| `conformidad/xnu-0380` (rama `serie-0370`) | El árbol del kernel con la serie del repo hasta 0370 y 0380 |
| `conformidad/parches-nuevos/0380-*.patch`, `0380-header.txt` | El parche y su texto |
| `conformidad/verif/` | `syn.sh`, `syn-c.sh`, stubs, `check-0380.sh` y su log |
| `conformidad/modelo/modified_race.py`, `.out` | El modelo de entrelazados del bit *modified* |
| `conformidad/tools/build-hostwarm.sh`, `warmup-host.sh`; `conformidad/medida-warmup/`, `medida-warmup.log` | Herramientas y medida del precalentamiento |
| `ios-graficos/ios-20H392/desensamblado/QuartzCore.named.s.gz` | El desensamblado de QuartzCore de las citas del §1.1 |
