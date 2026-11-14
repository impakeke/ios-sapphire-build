# 15 — Kernel: limpieza de caché por submit, presentación sin frames pisados, TLB y caché de buffers (2026-11-14)

- **Autor:** agente Claude Fable 5.2, esfuerzo máximo.
- **Alcance:** cuatro parches nuevos del kernel sobre la serie hasta 0338, cada uno tras un sysctl conmutable en
  caliente: 0339 (limpieza de caché de superficies), 0340 (cola de presentación), 0341 (TLB del SMMU de la GPU) y
  0342 (caché de buffers del pool).
- **Estado:** escritos y verificados en la Mac (§5). **Sin compilar en CI y sin ejecutar en el teléfono.**
- **Parches:** `~/sapphire-angel/research/metal/kernel-gpu/parches-nuevos/` (fuera de `xnu/patches/`; los integra
  el coordinador). El borrador `relojes/parche/0339-sapphire-gpu-clocks-diag.patch.borrador` usa el mismo número
  que el primero de estos: hay que renumerar uno. Aplica antes o después de 0339-0341 sin conflicto.
- **Convenciones:** `G`/`F`/`S` son líneas de `SapphireGpu.cpp`, `SweetFramebuffer.cpp` y `SweetSurface.cpp` del
  árbol a 0338 (4915, 2615 y 1533 líneas; sha256 `6b9380fd…`, `ccff7c94…`, `173e098f…`), no las de 09.
  El árbol `relojes/xnu-serie` coincide con `xnu/patches` hasta 0338: revertir 0338, 0337 y 0336 del repo deja
  los tres archivos con los sha256 de 09 (`6f108354…`, `5058a6c2…`, `173e098f…`), y reaplicarlos lo reproduce.

## Resultado en breve

| Parche | Interruptor (boot-arg) | Por defecto | Qué cambia al activarlo | Dónde se mide |
|---|---|---|---|---|
| 0339 | `kern.sweet_gpu_flush` (`gpu_flush`) | **0**: como antes | 1: una superficie se limpia de caché solo si un procesador pudo tocarla desde la última limpieza. La del frame deja de limpiarse en cada submit (1,5 ms → una comparación de dos palabras) | `cache flush` de `kern.sweet_gpu_diag`; `surface cleans` de `kern.sweet_fb_diag`; `kern.sweet_gpu_flush_stats` |
| 0340 | `kern.sweet_fb_queue` (`sweetfb_queue`) | **0**: como antes | 1: el frame se presenta en `SwapEnd`, tres flip buffers y cola de (buffer, fence), flip por un hilo en cuanto la copia termina, espera acotada en `SwapEnd` | `overwritten`, `flip interval`, `swap to flip` de `kern.sweet_fb_diag`; `kern.sweet_fb_queue_diag` |
| 0341 | `kern.sweet_gpu_tlb` (`gpu_tlb`) | **3**: activo | bit 0: sin invalidar la TLB al solo mapear; bit 1: espera de TLBSTATUS sin dormir | `tlb flush … slept` de `kern.sweet_gpu_diag`; `kern.sweet_gpu_tlb_stats` |
| 0342 | `kern.sweet_gpu_bocache` (`gpu_bocache`) | **0**: como antes | 1: los buffers del pool que un cliente cierra se le guardan y se le reentregan (borrados de nuevo); 2: sin borrar | `new … mapping ns`, `freeing ns`, `zeroing ns` de `kern.sweet_gpu_diag`; `kern.sweet_gpu_bocache_stats` |

Tres hallazgos cambian lo que se daba por sabido:

1. **`SwapEnd` no presenta en su hilo en este teléfono**: lo hace el temporizador de 120 Hz en su siguiente tick
   (§0.1). `kern.sweet_fb_hold_ms` (0338) es código muerto aquí y no puede decidir nada.
2. **La limpieza de 1,5 ms por submit es la superficie del frame, y se debe a que el driver mapea toda superficie
   que importa** (§0.2): `mapped` es cierto para todas y el kernel limpia entera cada superficie mapeada en cada
   submit, aunque solo la toque la GPU.
3. **Con carga sostenida de GPU el camino actual puede no presentar nada**: el flip espera a la fence de la
   **última** copia encolada, que cada swap renueva. Un modelo del camino actual con la GPU a 25-45 ms por frame
   y el compositor a 8-16 ms enseña 1 frame de 600 (§2.4). En la medición hay 663 flips a 13 refrescos o más del
   anterior frente a 558 swaps con esa separación: la diferencia es compatible con rachas de frames pisados
   (hipótesis; el resto son pausas sin swaps).

## 0. Hallazgos previos al diseño

### 0.1 `SwapEnd` no presenta en su hilo: lo hace el temporizador

Medido en el teléfono (kernel 0338, `kern.sweet_fb_diag`, 22 min de arranque):
`swaps 6996 flips 5926 (by swap 0, by tick 5920)`, `present: 0, 0 us in all`, `hold … 0 swaps waited`.

- `present: N` solo se cuenta en `presentNow()` (F1176). Con 6996 swaps vale 0: `presentNow()` no se ejecuta.
- Causa: `swap()` decide `now = fNow && !fPowerOff && fFadeOrig == NULL` (F1105). `fFadeOrig` se reserva junto a
  los flip buffers (F701-708) y este teléfono los tiene desde 0233. `now` es falso siempre.
- Camino real:
  1. `SwapEnd` copia el swap a `fPending` y vuelve (F1149-1156). Si había otro sin presentar, lo sustituye: ese
     frame no llega a copiarse (no lo cuenta nadie; `swaps − copy` da 138 de 6996, que incluye los swaps con la
     pantalla apagada).
  2. El tick siguiente lo recoge (F967-978), hace `flipWhenCopied(false)` (F986-995) y llama a `present()`
     (F1000-1008), que encola la copia de la GPU sobre `fFlipPhys[fFlipIdx ^ 1]`, el único buffer trasero.
  3. Un tick posterior escribe el flip cuando la fence de la **última** copia encolada está hecha.
- Consecuencias:
  - El experimento de 0338 está dentro de `if (now)` (F1135-1145): aquí no se ejecuta. El mecanismo de 0286
    tampoco.
  - `swap to flip` de 0336 se mide desde que el tick encola la copia (F1986), no desde `SwapEnd`: le falta la
    espera del tick, 0-8,33 ms.
  - Una superficie queda en uso desde `SwapEnd` hasta un tick después de presentarse el frame **siguiente**
    (F1010-1012, F980-984), sin relación con la GPU.
  - 09 §2.1 describe el camino `presentNow()`: vale para un teléfono sin flip buffers, no para este.

### 0.2 Qué limpia cada submit y por qué

Medido (`kern.sweet_gpu_diag`): 5 520 submits, 5 675 limpiezas, 28 014 264 320 bytes: 1,03 limpiezas de
4,94 MB por submit. Es la superficie del frame (4 997 120 bytes) cada vez: si cada submit la limpia una vez,
quedan 155 limpiezas de 2,8 MB de media para otras superficies.

- Regla del código (G4561-4589): por cada buffer de `bos[]` con memoria del kernel, si es una superficie se limpia
  **e invalida** entera (`dc civac`, G4586) cuando su seed cambió **o cuando `mapped`** (G4577). `mapped` se pone
  en `clientMemoryForType` (G4299) y no se borra nunca.
- HakiosMetal mapea toda superficie en el momento de importarla: `Gpu::surfaceBo()` llama a `map()` en la línea
  que construye el `Bo` (`hakios-metal/src/gpu.cpp:76-91`, árbol `rebuild/hakios-upstream`). `mapped` es cierto
  para todas las superficies de todos los procesos que usan el driver.
- El kernel de HackiOS hace lo mismo (`hakios.gpu.cpp:997-1042`: "A surface this program has mapped, every
  time", más una ventana de 4 ms): no hay un diseño mejor que copiar de ahí.
- El driver dice por buffer si el submit lo lee o lo escribe (`gpu.cpp:147-160`, `MSM_SUBMIT_BO_READ`/`WRITE`); el
  kernel ignora esos flags.
- `IOSurfaceLock` e `IOSurfaceUnlock` son traps de IOKit en este kernel (S1429-1452): el kernel ve cada uno. El
  seed solo lo mueve el kernel, en el unlock de un lock de escritura (S1400-1403, S1449-1450); la página de estado
  se mapea de solo lectura en los programas (S665).
- El "mapeo msm" de una superficie es, en la práctica, el mismo mapeo que el de IOSurface.framework:
  `createMappingInTask` devuelve un mapeo compatible ya existente del mismo descriptor en la misma tarea
  (`IOMemoryDescriptor.cpp:5540-5585`, `copyCompatible`), y el proceso que importa una superficie ya la tiene
  mapeada por IOSurface. No hay una segunda dirección que vigilar.
- Quién toca la memoria de una superficie con la CPU, visto en el código:
  - el kernel: el `bzero` al crearla (S880, S912), la copia por CPU de `present()` cuando la GPU rechaza la copia
    o hay varias capas (F1967-1971) y la de `directPresent()` para superficies de scanout (F1709-1718; no existen
    con `sweetfb_direct=0`). `kernelAddress()` tiene seis usos y los demás son para limpiar caché o para la
    memoria del panel;
  - los programas por el mapeo de IOSurface, con lock y unlock (traps);
  - el driver por su mapeo, **sin lock**: `Texture::replace` y `Texture::read` (`texture.cpp:648-721`), que son
    `-replaceRegion:` y `-getBytes:` de una textura hecha directamente sobre una IOSurface (filas múltiplo de 64
    bytes; las demás van por una copia con lock, `HakiosMetalCA.m:4365-4513`). El driver nunca llama a
    `GEM_CPU_PREP` (medido: `cpu prep 0`).
- La limpieza de `present()` antes de la copia al panel (F1854-1860) ocurre en 1446 de 6996 swaps (1,88 ms cada
  una, en el hilo del temporizador y con `fPresentLock`). Hipótesis, sin verificar: son frames que no pasan por un
  submit (6758 swaps frente a 5520 submits en la medición de M6): CoreAnimation presenta directamente una
  superficie dibujada con CPU. La regla actual vuelve a limpiarla en cada swap aunque nadie la haya tocado.

## 1. Parche 0339: cuenta de lo que las cachés guardan de cada superficie

`0339-sapphire-gpu-surface-cache-account.patch` (14 hunks; `SapphireGpu.cpp`, `SweetFramebuffer.cpp`,
`SweetSurface.cpp`, `SweetSurface.h`).

### 1.1 Los peligros

La GPU lee y escribe RAM por detrás de las cachés de la CPU. Para una memoria cacheable hay tres:

| | Situación | Consecuencia | Remedio |
|---|---|---|---|
| H1 | La GPU **lee** memoria de la que una caché guarda una línea sucia | la GPU ve el contenido viejo | limpiar (`dc cvac`) antes |
| H2 | La GPU **escribe** memoria de la que una caché guarda una línea sucia | la línea se escribe después sobre lo que dibujó la GPU | limpiar antes |
| H3 | La GPU **escribe** memoria de la que una caché guarda una línea limpia | la CPU lee después la línea vieja | invalidar (`dc civac`) antes, o antes de leer |

Lo que escribe la GPU no pone ninguna línea en ninguna caché. Una superficie que solo toca la GPU necesita una
limpieza con invalidación, una vez.

### 1.2 Estado y reglas

En `SweetSurface` (compartido por todos los clientes y por el framebuffer), tres palabras de 32 bits:

- `cpuEpoch`: se incrementa (atómico) en cada acceso a los píxeles **del que el kernel se entera**:
  - trap de `IOSurfaceLock` y de `IOSurfaceUnlock`, de lectura o de escritura (`sweet_surface_seed_out`);
  - `clientMemoryForType` del buffer de la superficie (mapeo o desmapeo por el cliente de la GPU);
  - `GEM_CPU_PREP` (tras su `dc civac`) y `GEM_CPU_FINI`;
  - las copias por CPU de `present()` y de `directPresent()`.
- `cleanEpoch`: `cpuEpoch` leído **antes** de la última pasada de `dc cvac` o `dc civac` sobre toda la superficie.
- `invalEpoch`: lo mismo para la última pasada de `dc civac`.
- Al crearse: `cpuEpoch = 1`, las otras dos a 0 (el `bzero` deja líneas sucias).

Con `kern.sweet_gpu_flush` 1 o 2:

| Quién | Condición | Acción |
|---|---|---|
| Submit que **escribe** el buffer (flag `WRITE`, o ninguno de los dos) | `invalEpoch != cpuEpoch` | `dc civac` de toda la superficie; `invalEpoch = cleanEpoch = e` |
| Submit que solo lo **lee** (flag `READ` sin `WRITE`) | `cleanEpoch != cpuEpoch` | `dc cvac`; `cleanEpoch = e` |
| Copia al panel (`present()`, la GPU lee) | `cleanEpoch != cpuEpoch` | `dc cvac` de toda la memoria; `cleanEpoch = e` |
| Cualquiera de los tres | iguales | nada |

`e` es el valor leído antes de empezar la pasada. Superficies write-combined (la del panel) no se limpian. Las
envueltas sobre memoria de un programa (`wrapped`) siguen la regla antigua en `present()`: se escriben sin lock.

Con `kern.sweet_gpu_flush=0` las pasadas son exactamente las de antes; la cuenta se mantiene igualmente (cada
`dc civac` antiguo actualiza las dos palabras), así que cambiar de modo en caliente cuesta como mucho una pasada
de más.

`kern.sweet_gpu_flush=2` añade: `clientMemoryForType` rechaza mapear el buffer de una superficie que aún no está
mapeada. El desmapeo de una ya mapeada pasa (IOKit vuelve a preguntar por el descriptor al desmapear,
`IOUserClient.cpp:4782-4840`).

### 1.3 Por qué no se pierde coherencia (modo 1)

Supuestos, todos explícitos:

- **A1.** Todo lock y unlock de IOSurface llega al kernel como trap. Verificado del lado del kernel (S1429-1452;
  el seed no puede moverse de otro modo, S665). Que IOSurface.framework no se salte el trap en locks de lectura
  **no está verificado**.
- **A2.** Un programa no toca los píxeles por su mapeo de IOSurface fuera de un par lock/unlock. Es el contrato de
  IOSurface y es lo que el kernel ya supone desde 0165 para toda superficie no mapeada por el cliente de la GPU.
- **A3.** Un programa no toca los píxeles por el mapeo del cliente de la GPU sin lock. **HakiosMetal lo incumple**
  en `Texture::replace`/`read` (§0.2). Si alguna ruta del teléfono llega ahí no se sabe: por eso el modo 1 no es
  el modo por defecto.
- **A4.** Los flags `READ`/`WRITE` del submit son ciertos. Sin flags se trata como escritura.

Razonamiento:

1. *La pasada cubre lo anunciado hasta `e`.* Cada pasada recorre toda la superficie después de leer `e`. Todo
   acceso anunciado con época ≤ `e` empezó antes; lo que escribió hasta el inicio de la pasada queda limpio. Un
   lock anuncia **antes** del primer acceso y el unlock **después** del último: si la pasada cae dentro del par,
   el unlock sube la época y la siguiente comprobación vuelve a pasar.
2. *H1.* La GPU lee tras comprobar `cleanEpoch == cpuEpoch`: no hay acceso anunciado posterior a la última
   pasada, y por A2-A3 no los hay sin anunciar: ninguna línea sucia.
3. *H2 y H3.* La GPU escribe tras comprobar `invalEpoch == cpuEpoch`: la última pasada invalidó y nadie ha tocado
   desde entonces: no hay ninguna línea, ni sucia ni limpia. Las escrituras de la GPU no crean líneas. La
   primera lectura posterior de la CPU va a RAM.
4. *Dos pasadas a la vez* (un submit bajo `service_lock` y `present()` bajo `fPresentLock`): cada hilo guarda la
   época que él leyó antes de su propia pasada completa. Si queda la más antigua de las dos, la siguiente
   comprobación hace una pasada de más; nunca una de menos.
5. *Lo que no cubre, igual que antes:* un programa que lee la superficie mientras la GPU aún la escribe (sin
   esperar a la fence) puede quedarse con líneas a medias; y un submit hecho con el lock de escritura todavía
   tomado puede no ver lo último escrito. Las dos carreras existen igual con la limpieza por submit.

Frente al comportamiento anterior: con A2-A3 ciertos, el `dc civac` que antes se hacía en cada submit sobre una
superficie que nadie tocó no encontraba ninguna línea: no hacía nada salvo tardar 1,5 ms.

### 1.4 El hueco (A3) y cómo cerrarlo

- **Experimento que lo decide:** arrancar con `gpu_flush=2` (o `sysctl -w kern.sweet_gpu_flush=2` y reiniciar
  backboardd) y leer la consola del driver (`tools/perf/conscat`). Con la superficie sin mapear, el driver rechaza
  por su nombre cualquier `-replaceRegion:` o `-getBytes:` sobre ella: `IOSurface N's memory is mapped nowhere in
  this process by the driver` (`texture.cpp:680, 710`). Una sesión de uso normal sin esa línea dice que el modo 1
  no pierde nada en esa sesión. `mappings refused` de `kern.sweet_gpu_flush_stats` cuenta los rechazos.
- **Arreglo en su sitio (driver, fuera de este parche):** que `-replaceRegion:` y `-getBytes:` de una textura
  directa sobre IOSurface tomen `IOSurfaceLock`/`IOSurfaceUnlock` (o `GEM_CPU_PREP`/`FINI`), y que
  `Gpu::surfaceBo()` no mapee hasta que haga falta. Con eso A3 es cierto por construcción y el modo 1 puede ser
  el modo por defecto.

### 1.5 Candados

- `cpuEpoch`: solo incrementos atómicos, sin candado.
- `cleanEpoch`, `invalEpoch`: escrituras de una palabra bajo `service_lock` (submit, `CPU_PREP`) o bajo
  `fPresentLock` (`present()`); ver el punto 4 de §1.3.
- `gflush` (contadores) y `mapped`: bajo `service_lock`.
- Nada nuevo duerme. Las pasadas de caché siguen dentro de `service_lock`, como antes; son menos.

### 1.6 Riesgos, síntomas y cómo desactivarlo

Solo con `kern.sweet_gpu_flush` distinto de 0:

- **Modo 1, si A3 falla** (el driver escribe o lee por CPU una textura sobre IOSurface): una textura que no se
  actualiza o se actualiza a trozos, filas viejas dentro de una imagen recién dibujada, o un `-getBytes:` que
  devuelve partes del frame anterior. En pantalla: zonas de una ventana o de una miniatura con contenido antiguo,
  que se corrigen solas al redibujar. No hay cuelgue ni pánico posibles por esta vía.
- **Modo 2:** contenido que falta donde el driver rechaza la llamada (una textura que se queda sin rellenar), con
  su línea `refused:` en la consola del driver.
- **Si A1 falla** (un lock de lectura no llega por trap): lecturas de CPU con líneas viejas tras dibujar la GPU
  (capturas de pantalla con partes del frame anterior).
- **Desactivar:** `sysctl -w kern.sweet_gpu_flush=0`, efecto inmediato. En el arranque, no pasar `gpu_flush`.

### 1.7 Cómo medirlo

`kern.sweet_gpu_diag`, línea `submit ns`: `cache flush N NS MAX, B bytes`. Por submit: ΔNS/Δsubmits (hoy
1,57 ms) y ΔB/Δsubmits (hoy 4,9-5,1 MB). Con el modo 1 y el compositor dibujando, las dos deben caer a ~0 tras
el primer submit. `kern.sweet_gpu_flush_stats`: `named`, `nothing to do`, `cleaned`, `cleaned and invalidated`.
`kern.sweet_fb_diag`: `surface cleans N, US`: deja de crecer en swaps de una superficie que nadie tocó.

## 2. Parche 0340: cola de presentación

`0340-sapphire-fb-frame-queue.patch` (14 hunks; `SweetFramebuffer.cpp` y dos funciones en `SapphireGpu.cpp`).

### 2.1 Diseño

Con `kern.sweet_fb_queue=1`:

- **Se presenta en `SwapEnd`.** La copia se encola en el acto, detrás del dibujo que hizo el frame (el orden
  observado es submit y después swap, 09 §1). Desaparece la espera del tick (0-8,3 ms).
- **Tres flip buffers y una cola de (buffer, fence, superficies).** El tercero sale del pool bajo al arrancar
  (10,4 MB; quedan libres unos 8 de 48). La copia va a un buffer que no es el que lee el MDP, ni uno que pueda estar
  leyendo hasta que tome el último flip, ni el de un frame que espera. Ningún frame se copia encima de otro y no
  se escribe en lo que el panel enseña.
- **Un hilo hace el flip en cuanto la fence de la copia está hecha.** Duerme mientras no hay nada que esperar;
  con un frame en cola mira cada `kern.sweet_fb_queue_poll_us` (500 µs). Los ticks del temporizador miran también
  (respaldo si el hilo no arranca).
- **Un flip por refresco.** El siguiente flip no se escribe hasta que el MDP ha tomado el anterior:
  `INTF_FRAME_COUNT` ha avanzado desde que se escribió (dos veces si se escribió en el último dieciseisavo del
  refresco, donde puede llegar tarde al vsync; 34 ms si el contador no se mueve). Dos flips en un refresco dejan
  el primero sin verse.
- **Las superficies del frame siguen en uso hasta su flip.** Quien dibuja no puede adelantarse más que sus
  superficies. Hoy se sueltan un tick después de presentarse el frame siguiente, sin mirar a la GPU.
- **Espera acotada en `SwapEnd`.** Si no hay buffer libre, o ya esperan `kern.sweet_fb_queue_depth` (2) frames,
  `SwapEnd` espera hasta `kern.sweet_fb_queue_hold_ms` (50 ms; tope 200). Si vence, el frame más nuevo de la cola
  cede su buffer al que llega y no se enseña (cuenta en `overwritten`): el último frame de una ráfaga siempre
  queda en pantalla y el llamante nunca se bloquea más.

`present()` no se toca. La cola pone el buffer elegido en el hueco donde `present()` busca el buffer trasero
(`fFlipIdx ^ 1`) y recoge el flip que `present()` deja pendiente (`fFlipWait`). `scanFrom()` anota, en todos los
modos, qué buffer está dejando el MDP y dónde iba el barrido.

### 2.2 Frente al framebuffer de HackiOS

| | HackiOS (`MiniIOMobileFramebuffer.cpp`) | 0340 |
|---|---|---|
| Qué llega al panel | copia por CPU a un único buffer, detrás de la línea de barrido | copia por GPU a un buffer trasero y flip |
| Cola | 2 swaps (`fb_queue`, L215); `SwapEnd` se retiene si está llena (L1274-1291) | 2 frames (`depth`), cada uno con su buffer; `SwapEnd` se retiene si no hay buffer |
| Tope de la retención | 700 ms; al vencer se pierde el frame **nuevo** (L1278) | 50 ms; al vencer cede el **más nuevo de la cola**: el último frame siempre se ve |
| Quién espera a la GPU | un hilo que espera la superficie y luego copia (L1437) | un hilo que sondea la fence de la copia |
| Cadencia | compás propio (`fb_beat`) | un flip por refresco, con el contador del INTF |
| Superficies | en uso hasta que sus píxeles están en el panel | en uso hasta el flip |

Por qué no copiar su diseño tal cual: su presentador hace la copia con la CPU y por eso puede esperar a la GPU
antes de copiar; aquí la copia es otro trabajo de la GPU, encolado en el mismo ring, y lo que hay que ordenar son
buffers de destino. De ahí el tercer buffer: sin él, cada `SwapEnd` que llega con la copia anterior pendiente
tendría que esperar (lo que HackiOS mide como peor: 33 % de frames largos con cola de 1 frente a 28 % con 2,
L363-365). Con él, ese caso (el 13,8 % medido) no espera ni pisa.

Perder el frame nuevo al vencer la espera, como HackiOS, deja en pantalla un frame viejo si era el último de una
animación. Ceder el más nuevo de la cola degrada, en el peor caso, al comportamiento actual.

### 2.3 Invariantes

Con `fPresentLock`:

1. Una copia nunca se encola sobre el buffer que el MDP lee, ni sobre uno que pueda estar leyendo, ni sobre el de
   un frame en cola. Única excepción: `kern.sweet_fb_queue_hold_ms=0` (contador `forced`).
2. Los flips se escriben en el orden de los `SwapEnd`.
3. No se escribe un flip sobre otro que el MDP no ha tomado (salvo los frames que copia la CPU, que hacen el flip
   en el acto como antes).
4. Todo frame encolado se enseña, o se cuenta: `timed out` (cedió su buffer), `dropped` (pantalla apagada, o un
   frame de CPU posterior ya está en pantalla), `drained`.
5. Las superficies de cada frame se sueltan exactamente una vez.
6. `SwapEnd` espera como mucho `hold_ms`, más hasta 34 ms si solo falta el vsync que libera el buffer saliente
   (solo posible con dos flip buffers).
7. El hueco `fFlipIdx` de `fFlip[]` contiene el buffer al que apunta el MDP; el código antiguo sigue valiendo en
   cualquier momento.

Cambio de modo en caliente: al activar, la copia que el camino antiguo dejó pendiente pasa a ser el primer frame
de la cola; al desactivar, el camino antiguo vacía la cola antes de presentar (`queueDrain()`), y los ticks siguen
enseñando lo que quede.

### 2.4 Simulación en el host

`parches-nuevos/sim-0340/` (`sim.cpp`, `extract.py`, `run.log`). `extract.py` recorta del `SweetFramebuffer.cpp`
parcheado las funciones de la cola y `scanFrom()` **tal cual** (solo quita las dos barreras `dsb`); `sim.cpp` las
compila contra un modelo: reloj virtual, GPU que ejecuta en orden, panel que toma el flip en su vsync, el
temporizador, el hilo de la cola y un compositor que dibuja y llama a `SwapEnd`. Comprueba los invariantes 1-6.

- 19 escenarios × 300 semillas × 600 frames: **todos pasan** (ninguna copia sobre lo que el panel lee, ningún
  flip sobre otro sin tomar, orden, todo frame enseñado o contado, superficies soltadas).
- Tres mutaciones del código (sin comprobar el buffer saliente, sin la cadencia, sin esperar la fence): las tres
  se detectan en todas las ejecuciones.
- No cubre: `presentNow()`, `swap()`, `vsyncFired()`, el hilo real ni el cambio de modo (revisados a mano).

Cifras del modelo (semilla 1; "sin cola" es un modelo del camino actual, no su código):

| Escenario (CPU / GPU por frame) | | Enseñados | `SwapEnd`→panel, media | Notas |
|---|---|---|---|---|
| Teléfono: 25-40 / 14-24 ms | cola | 600/600 | 26,0 ms | sin esperas en `SwapEnd` |
| | sin cola | 596/600 | 31,8 ms | 86 copias sobre el buffer que el panel lee |
| Ligero: 2-7 / 1-4 ms | cola | 600/600 | 19,9 ms | `SwapEnd` espera ≤ 6,5 ms: el panel da 120 por segundo |
| | sin cola | 298/600 | 16,8 ms | 274 sustituidos antes de copiarse; 296 copias sobre lo que el panel lee |
| GPU: 8-16 / 25-45 ms | cola, `depth` 2 | 600/600 | 99 ms | el compositor va dos frames por delante |
| | cola, `depth` 1 | 600/600 | 67 ms | uno por delante |
| | sin cola | 1/600 | — | el flip espera siempre a la última copia |
| Ráfagas: 1-60 / 1-60 ms | cola | 592/600 | 66 ms | 8 cedieron su buffer tras 50 ms |
| | sin cola | 1/600 | — | |

Con dos superficies y `depth` 2, el caso de GPU da 67 ms: las superficies en uso frenan al compositor.
En el régimen del teléfono (CPU del driver como límite) la cola no añade latencia: quita la espera de un tick.
Con carga sostenida de GPU la latencia la fija cuántos frames por delante va el compositor: `depth` la elige.

### 2.5 Candados

- Todo lo de la cola (cola, huecos de `fFlip[]`, estado del latch) bajo `fPresentLock`, que es un mutex.
- `SwapEnd` espera con `IOLockSleepDeadline` (suelta el mutex mientras duerme); el hilo duerme igual. Nadie
  espera con un candado girando.
- Orden sin cambios: `fPresentLock` → `service_lock` (dentro de `present()`); `fLock` nunca está tomado al tomar
  `fPresentLock`.
- `queueDrain()` espera con `IODelay(100)` hasta 20 ms con el mutex, igual que `flipWhenCopied(true)`. Solo antes
  de un frame que copia la CPU y al desactivar la cola.
- `scanFrom()` se llama también sin `fPresentLock` desde el apagado de pantalla y la consola de pánico, como
  antes: el estado que anota son unas palabras que se releen en la siguiente mirada.

### 2.6 Riesgos, síntomas y cómo desactivarlo

Solo con `kern.sweet_fb_queue=1`:

| Si falla… | Síntoma | Qué mirar |
|---|---|---|
| El hilo no hace flips (fence que nunca se da por hecha) | pantalla congelada con el sistema vivo; `SwapEnd` tarda 50 ms | `flips` parado y `timed out` creciendo en `kern.sweet_fb_queue_diag` |
| El contador del INTF no sirve para el latch | 29 fps como mucho | `flips taken by time` creciendo |
| El latch se da por tomado antes de tiempo | tearing: una franja del frame siguiente | `flip interval` con valores en el cubo 0 |
| Orden de buffers mal llevado | animación que salta atrás un frame | — |
| CoreAnimation no lleva bien las superficies retenidas | menos swaps por segundo que sin la cola | `swaps` por segundo; `swap interval` |
| El tercer buffer no cabe en el pool | funciona con dos: más esperas | línea `SWEET FB: frame queue … 2 flip buffers` del arranque |

- **Desactivar:** `sysctl -w kern.sweet_fb_queue=0`, efecto en el siguiente swap o tick. Si la pantalla está
  congelada, por SSH. En el arranque, no pasar `sweetfb_queue`.
- Ajustes: `kern.sweet_fb_queue_depth` (1 o 2), `kern.sweet_fb_queue_hold_ms`, `kern.sweet_fb_queue_poll_us`.

### 2.7 Cómo medirlo

`kern.sweet_fb_diag`: `overwritten`/`swaps` (hoy 13,8 %) debe quedar en ~0; `flip interval` debe perder la cola
larga (hoy 663 de 5925 flips a 13 refrescos o más) sin valores en el cubo 0; `flips` ≈ `swaps`.

La latencia no se compara con `swap to flip` a secas: sin la cola ese histograma empieza en el tick que encola
la copia (le faltan 0-8,3 ms); con la cola empieza en `SwapEnd`. Para comparar: sumar 4,2 ms a la media sin cola,
o usar `arrival to flip` de `kern.sweet_fb_queue_diag`, que cuenta desde la entrada de `SwapEnd` con las esperas.
`present` pasa a ser el tiempo de `SwapEnd` (hoy 0: no se ejecuta). `swaps that waited`, `timed out` y `depth
max` dicen cuánto se frenó al compositor.

## 3. Parche 0341: TLB del SMMU de la GPU

`0341-sapphire-gpu-tlb-no-flush-on-map-spin-sync.patch` (4 hunks; `SapphireGpu.cpp`). Activo por defecto
(`kern.sweet_gpu_tlb=3`); 0 es el código anterior.

Medido: 13 358 invalidaciones, 0,97 s, 73 µs cada una con `service_lock`; 13 251 durmieron.

- **Bit 1 (valor 2): la espera no duerme.** Tras `TLBSYNC`, `tlb_flush()` mira `TLBSTATUS` sin dormir hasta
  200 µs y solo entonces cae a `poll()`. `poll()` espera con `IODelay(1)` (G455), que en este port bloquea el
  hilo (`clock.c:1584`: `ml_delay_should_spin()` es falso porque `cpu_idle_latency` vale 0,
  `machine_routines.c:2360-2373`). Linux gira antes de retrasar (`arm-smmu.c`, `__arm_smmu_tlb_sync`;
  `arm-smmu-qcom.c`, `qcom_smmu_tlb_sync`).
- **Bit 0 (valor 1): sin invalidar al solo mapear.** `place()` (G4135-4158) no invalida tras mapear un buffer.
  Las entradas que escribe eran inválidas, un SMMU no guarda una traducción que no pudo hacer, y un rango de
  direcciones de GPU solo se reparte de nuevo después de que `freeBo()` lo desmapee e invalide (G4195-4199; las
  tablas de páginas no se liberan nunca). Linux hace lo mismo en este SMMU:
  `msm_iommu_pagetable_map()` no invalida y `msm_iommu_pagetable_unmap()` llama a `iommu_flush_iotlb_all()`
  (`msm_iommu.c:91-150`). Siguen invalidando: `map_window()` (sustituye entradas vivas), `map_identity()`, la
  salida por error de `place()` y todo desmapeo.
- **Red de seguridad:** una invalidación que no se vio terminar deja `tlb_stale`, y mientras esté puesto
  `place()` invalida antes de volver.
- **Candados:** `tlb_flush()` corre bajo `service_lock` (mutex) o en el arranque con un solo hilo; `tlb_stale` y
  los contadores, bajo el mismo. Gira con el mutex tomado, con expulsión permitida, 200 µs como mucho.
- **Riesgo:** si este SMMU guardara fallos de traducción, un buffer recién mapeado daría fallo al usarlo: GPU
  colgada 2 s y recuperación (`*** msm: the GPU was reset`), con `SMMU … FSR` distinto de 0 en el log. Ningún
  dato apunta a ello. **Desactivar:** `sysctl -w kern.sweet_gpu_tlb=2` (solo la espera) o `0`; boot-arg `gpu_tlb`.
- **Medir:** en `kern.sweet_gpu_diag`, `tlb flush N NS MAX, slept S`: N por `GEM_NEW` debe pasar de 2 a 1, NS/N
  de 73 µs a unos pocos, S a ~0; `mapping ns` de `new` baja. `kern.sweet_gpu_tlb_stats`: `looks` por invalidación
  dice cuánto tarda de verdad la sincronización; `fell back on sleeping` debe ser ~0.

## 4. Parche 0342: caché de buffers del pool por cliente

`0342-sapphire-gpu-keep-pool-buffers.patch` (11 hunks; `SapphireGpu.cpp`). Apagada por defecto.

Medido: 6 575 `GEM_NEW` y 6 670 liberaciones en 15 min: 1,44 s borrando, 0,79 s mapeando, 0,85 s liberando
(3,1 s en total; 0341 quita parte de lo segundo). Es el menor de los costes medidos.

- **Qué hace** (`kern.sweet_gpu_bocache` 1 o 2): un buffer del pool que su cliente cierra, cuando la GPU ha
  terminado con él, se guarda **para ese cliente** con su descriptor, sus páginas del pool y sus entradas del
  SMMU (`keepBo()`, llamado desde `drop()` y `reap()`). Un `GEM_NEW` del mismo cliente y del mismo tamaño exacto
  lo recibe con un handle nuevo (`gemNew()`): sin buscar en el pool, sin `place()`, y sin `freeBo()` ni su
  invalidación al otro extremo. Es el `keep`/`dropKept` de `hakios.gpu.cpp:389-411, 686-768`.
- **Límites:** 32 buffers y 64 MB por cliente, ninguno de más de 16 MB, 2 s como mucho cada uno (se mira en
  `reap()`, es decir, en cada submit del cliente). Se liberan todos al cerrar el cliente y cuando el pool no
  tiene sitio para un buffer nuevo.
- **Borrado:** con 1 el buffer reutilizado se borra otra vez (lo que `GEM_NEW` ha contestado siempre): ahorra el
  mapeo y la liberación, no el `bzero`. Con 2 no se borra: el programa encuentra lo que tenía un buffer suyo
  anterior, nunca de otro proceso. Es el modo que más ahorra y el que hay que probar con cuidado: Metal promete
  buffers a cero y 0215 documenta frames blancos y la pantalla amarilla al dejar de borrar los grandes.
- **Cuentas:** un buffer guardado se descuenta de `fCount`/`fBytes` como uno de la lista `fLeft` y se vuelve a
  contar al reutilizarlo o al liberarlo; sigue en el censo del pool (`SWEET MEM`) mientras está guardado.
- **Candados:** la lista, sus tiempos y los contadores, bajo `service_lock`, como la tabla de handles. El borrado
  al reutilizar se hace fuera del candado, como el de un buffer nuevo.
- **Riesgos y síntomas:** con 2, contenido de un buffer anterior donde el programa espera ceros (frames blancos
  o de color, texturas con restos). Con 1 o 2, si la cuenta de páginas fallara, dos buffers sobre la misma
  memoria: corrupción de texturas. Memoria: hasta 64 MB del pool por cliente retenidos 2 s tras el último submit
  de un cliente que deja de dibujar (hasta que cierra). **Desactivar:** `sysctl -w kern.sweet_gpu_bocache=0`; lo
  guardado se libera al cerrar cada cliente o por edad en su siguiente submit.
- **Medir:** `kern.sweet_gpu_bocache_stats` (`kept`, `handed out again`, `freed for their age`, `freed to make
  room`); en `kern.sweet_gpu_diag`, `new … mapping ns` y `freeing ns` bajan con la fracción reutilizada, `tlb
  flush` también, y `zeroing ns` solo con 2.

## 5. Verificación

Hecha en la Mac, con las herramientas en `parches-nuevos/work/verif/`:

- **`git apply --check` y `git apply` en orden** sobre un checkout limpio de la serie a 0338
  (`check-apply.sh`): los cuatro aplican, y el resultado es idéntico al árbol de trabajo del que salieron.
- **Independencia:** las quince combinaciones de los cuatro (cada uno solo, pares, tríos, todos) aplican en orden
  sobre 0338 y pasan la comprobación de sintaxis (`combos.sh`). Se pueden integrar por separado.
- **`clang++ -fsyntax-only`** con `syn.sh` y los stubs de `kernel-gpu/verificacion/`: 0 errores en los tres
  archivos en las quince combinaciones.
- **Los bloques nuevos se compilan de verdad:** doce errores inyectados en bloques de los cuatro parches se
  detectan todos.
- **Avisos** (`warn.sh`: `-Weverything` con la lista `-Wno` del kernel): en las 893 líneas añadidas a los tres
  `.cpp` solo salen los de las macros `SYSCTL_*` e `IONew` y un `-Wcast-align` de la lectura del seed, los mismos
  que ya da el código vecino.
- **Simulación de 0340:** §2.4.
- **`gfxdiag-diff.py`** resta bien las líneas de los sysctl nuevos (probado con los de 0339-0341).

**No verificado:** compilación y enlazado en el CI; ejecución en el teléfono; los supuestos A1 y A3 de §1.3; que
`INTF_FRAME_COUNT` sirva como señal de flip tomado con el margen elegido; el comportamiento de CoreAnimation con
superficies retenidas hasta el flip; 0342 solo tiene revisión de código (no hay simulación de sus cuentas).

**Sin tocar:** el defecto D2 de 09 (con `sweetfb_scale=2`, un swap sin exactamente una capa hace el flip de un
buffer que no se ha escrito) sigue igual en los dos modos; con la cola el buffer es uno libre, con un frame más
antiguo.

## 6. Orden de prueba propuesto

Todo en caliente, con el kernel que lleve los cuatro parches. Lectura antes y después de cada prueba:

```sh
L='sysctl -n kern.sweet_fb_diag kern.sweet_gpu_diag kern.sweet_gpu_flush_stats kern.sweet_fb_queue_diag kern.sweet_gpu_tlb_stats kern.sweet_gpu_bocache_stats'
ssh sapphire "PATH=/var/jb/usr/bin:/var/jb/usr/sbin:\$PATH; $L" > antes.txt     # … prueba … > despues.txt
~/sapphire-angel/research/metal/kernel-gpu/verificacion/gfxdiag-diff.py antes.txt despues.txt
```

1. **Arranque sin tocar nada.** 0341 va activo: comprobar que arranca y pinta, y `tlb flush … slept`. Si la GPU
   se cuelga al crear buffers: `kern.sweet_gpu_tlb=2`.
2. **`kern.sweet_fb_queue=1`** con la carga de siempre: `overwritten`, `flip interval`, `arrival to flip`,
   swaps por segundo, y el ojo. Después `kern.sweet_fb_queue_depth=1`.
3. **`kern.sweet_gpu_flush=1`**: `cache flush` por submit y el ojo (texturas o miniaturas con contenido viejo).
4. **`gpu_flush=2` desde el arranque** y `conscat`: buscar `mapped nowhere in this process`. Sin esas líneas, el
   modo 1 es candidato a modo por defecto.
5. **`kern.sweet_gpu_bocache=1`**, y solo si va bien, `=2` mirando la pantalla (frames blancos o con restos).

Boot-args equivalentes: `sweetfb_queue=1 gpu_flush=1 gpu_bocache=1` (y `gpu_tlb=N`, `sweetfb_queue_hold=N`).

## Material

- `~/sapphire-angel/research/metal/kernel-gpu/parches-nuevos/`: los cuatro parches; `sim-0340/`; `work/xnu`
  (árbol con un commit por parche sobre el commit de la serie a 0338), `work/verif/` (`check-apply.sh`,
  `combos.sh`, `warn.sh`, `syn.sh`), `work/headers/` (las descripciones), `work/mkpatch.sh`, `work/regen.sh`.
- Fuentes: Linux v6.12 y HackiOS en `kernel-gpu/ref/` y `metal/hakios-xnu-kernel/`; el driver en
  `metal/rebuild/hakios-upstream/hakios-metal/`.
