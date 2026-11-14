# 27 — Caídas de SpringBoard y coherencia de caché sin el vaciado antes de WFI, 2026-11-14

Informe fechado. Pregunta: las dos caídas de SpringBoard al relanzarse tras `killall backboardd` (11:41:57 y
15:05:57, hora del teléfono) y las demás anomalías del día, ¿vienen de haber quitado el mantenimiento de caché antes
de WFI (`kern.sweet_idle_cache=0`, 0344, y por defecto desde 0351; informe 16)? Es decir, ¿había código del port que
dependía de que cada núcleo limpiara e invalidara su L1 y la L2 de su cluster miles de veces por segundo? Si lo había,
el riesgo es corrupción silenciosa de datos.

Árbol de referencia: xnu-8796.141.3 con 0001-0342 (`hilos/xnu-0344`, commit `cc07b6a`) más 0343-0353 de
`xnu/patches/` aplicados en orden, un commit por parche (`~/sapphire-angel/research/metal/coherencia/xnu-0353`, HEAD
`3439af8`; `git diff 1b191cb HEAD -- <ruta>` da lo que cambió el port). Rutas de código relativas a ese árbol.
Teléfono: kernel 0353 (arrancado a las 13:25:25), boot-args con `cpus=8 sweetsched=15 gpu_vco2=1 gpu_mhz=820
ipa=1 modem=1 wifi=1 audio=2`; `/redwood/boot.d/80-gfx.sh` pone `kern.sweet_fb_queue=1 kern.sweet_gpu_flush=1
kern.sweet_idle_cache=0` al arrancar.

Convención: **[O]** observación propia (código con `archivo:línea`, binario desensamblado o informe de caída),
**[M]** medida en el teléfono en esta investigación (archivo crudo citado), **[H]** hipótesis sin medir. Las partes
de la auditoría que no re-verifiqué línea a línea se marcan «(auditoría, `agente-*.md`)».

Material (fuera de git): `~/sapphire-angel/research/metal/coherencia/`: `crash-telefono/` (copia de los `.ips` del
teléfono, sin los JetsamEvent ni los dos más grandes), `tools/` (fuentes y binarios de `pairtear`, `objctear`,
`iocheck`, `lsetest`, `exp-coherencia.sh`, `relanzar-sb.sh`; instalados en `/var/root/coherencia/` del teléfono),
`pairtear-idle0-*.txt`, `objctear-idle0.txt`, `lsetest-resultado.txt`, `sysctl-gpu-1545.txt`, `dmesg-1520.txt`,
`parches/` (0390-0392), `scripts/` (`ipsum.py`: resumen de un `.ips`; `sync.sh`: comprobación de sintaxis en C con
stubs), y las notas completas de los cuatro agentes de la auditoría: `agente-nucleo.md`, `agente-almacenamiento.md`,
`agente-radios.md`, `agente-gpu.md`.

## Resultado en breve

1. **La caída de las 11:41:57 (SIGBUS) no depende de la caché.** Es una lectura rota de una entrada de la caché de
   métodos de libobjc: el escritor guarda `{imp ^ clase, sel}` con un `stp` y `objc_msgSend` la lee con un `ldp`;
   en los Cortex-A53/A73 el par se rompe, el lector ve el selector y un imp 0, y salta a la propia clase (datos no
   ejecutables) → SIGBUS. La misma firma exacta está en `seserviced` el 13 nov a las 16:07, un día antes de que
   existiera 0344, con el vaciado en reposo activo; y un programa de prueba la reproduce en segundos (8 de 8
   ejecuciones) con registros idénticos (§1.3-§1.5). Arreglo: 0391.
2. **La caída de las 15:05:57 (SIGSEGV en 0x0, CoreTelephony) no tiene la forma de datos obsoletos de una página:**
   es un nodo de un `std::set` con contenido de memoria ajena (padre 0, valor −3) recorrido en
   `ReregisterClientForAllEvents`. CommCenter llevaba vivo desde el arranque. Causa no establecida, n=1 (§1.6).
3. **Sí hay una dependencia real del vaciado, en la GPU, y es visual, no de ficheros:** con `kern.sweet_gpu_flush=1`
   el kernel solo limpia una IOSurface si se le avisó de un acceso de CPU, y HakiosMetal escribe y lee píxeles por su
   mapeo cacheable sin llamar nunca a `GEM_CPU_PREP`/`GEM_CPU_FINI` (`cpu prep 0` en el teléfono). Antes el vaciado
   empujaba esas líneas a RAM en milisegundos; ahora la GPU puede leer contenido viejo, y la CPU puede leer líneas
   anteriores a lo que dibujó la GPU (§2.5).
4. **Almacenamiento, USB y módem no dependían del vaciado**: el UFS hace bien todo su mantenimiento por dirección
   alrededor de cada comando, el USB activo usa memoria no cacheable bien preparada, y la memoria compartida con el
   módem, el ADSP, IPA y el Wi-Fi está fuera de la RAM del kernel y mapeada sin caché (§2.2-§2.4). Prueba de E/S sin
   page cache: 2 × 64 MB íntegros (n=1, §3).
5. **Defectos latentes del núcleo** que el vaciado tapaba y que hoy no tienen usuario conocido: el mantenimiento
   «bulk» por set/way para DMA de 2 MB o más, y el cambio por lotes de una página cacheable a no cacheable sin
   limpiarla (§2.1). Arreglo: 0392. Además, la emulación de `LDUMIN` del kernel guarda el operando en vez del mínimo
   (medido: 40 049 de 80 000 casos mal; §2.1.6). Arreglo: 0390.
6. **CommCenter** se cae siempre igual, desde el 13 nov y con el vaciado activo: `EXC_BREAKPOINT` en
   `RouterIPCController::engage_sync()` a los 44-64 s de cada arranque (§1.7). No tiene que ver con la caché.

**Riesgo.** No hay indicio de corrupción silenciosa de ficheros: el camino de disco es correcto por código y la prueba
de integridad sale limpia. La corrupción posible hoy es de imagen (texturas o superficies con trozos viejos en la
ruta de la GPU con `gpu_flush=1`). La lectura rota de pares `ldp`/`stp` no es de caché sino de arquitectura y está en
todos los procesos de iOS que usan Objective-C: es la causa de una clase de caídas aleatorias (pc = una clase) que se
da con cualquier valor de `idle_cache`.

## 1. Las caídas

### 1.1 Lo que dicen los dos informes

| | 11:41:57 | 15:05:57 |
|---|---|---|
| Tipo | `EXC_CRASH (SIGBUS)`, códigos 0/0, `byProc: SpringBoard` | `EXC_BAD_ACCESS (SIGSEGV)`, `KERN_INVALID_ADDRESS at 0x0` |
| Tiempo de vida de SpringBoard | 5,8 s (uptime 310 s) | 5,5 s (uptime 6000 s) |
| Hilo marcado | 0, en `__ulock_wait` (esperando `dataBasedPlistLock`) | 0 (principal), `ReregisterClientForAllEvents`+328 |
| Hilo que falló de verdad | 3: pc = `OBJC_CLASS_$___NSCFCharacterSet`, lr = CoreServices+0x2a214 | 0 |
| `far` / `esr` guardados | 0x10281a208 (dentro de `libOSMesa.8.dylib`) / 0x56000080 | 0x1f8284520 (en la caché compartida) / 0x56000080 |

[O] Los dos procesos llevaban inyectado `MobileSafety.dylib` (modo seguro de ElleKit). Su manejador de señales
(desensamblado, `bin/MobileSafety.dylib` 0xf590-0xf5a0) registra «SB crash occured: signal N», escribe su marca,
pone la señal en `SIG_DFL` y llama a `raise`: la señal se vuelve a entregar al volver del manejador. Por eso la
primera sale como `EXC_CRASH` con códigos 0 enviada por el propio proceso, y en las dos el estado del hilo es el de
después del manejador.

### 1.2 El ESR y el FAR de estos informes

- [O] El kernel guarda `ESR_EL1` y `FAR_EL1` en el estado del hilo en **toda** entrada de excepción desde EL0,
  llamadas al sistema incluidas (`SPILL_REGISTERS`, `osfmk/arm64/exception_asm.h:222-226`; el port no toca ese
  archivo, ni `locore.s` ni `status.c`), y `thread_get_state(ARM_EXCEPTION_STATE64)` devuelve esos dos campos
  (`status.c:948-949`).
- [O] 0x56000080 es EC 0x15 (SVC desde AArch64) con ISS 0x80 (`svc #0x80`, la convención de llamada al sistema de
  Darwin): la última excepción que tomaron esos hilos fue una llamada al sistema (la `ulock_wait` del hilo 0 en la
  primera; el `sigreturn` del manejador de MobileSafety en la segunda). «Address size fault» es ReportCrash
  interpretando los 6 bits bajos del ISS como DFSC sin mirar la EC: un artefacto del decodificador, no del port.
- [O] Tras un SVC, `FAR_EL1` conserva la dirección del último aborto que tomó el núcleo: 0x10281a208 y 0x1f8284520 son
  faltas de página ya resueltas, sin relación con la caída.
- [O] Donde no hay manejador intermedio el ESR sale coherente: CommCenter 0xf2000001 (BRK), su SIGSEGV del 14 nov
  07:55 0x92000007 (aborto de datos, fallo de traducción L3), `seserviced` 0x8200000f (aborto de instrucción, permiso
  L3).

### 1.3 La caída de las 11:41:57: el salto a la clase

[O] Desensamblado de la caché compartida instalada (UUID 8F970452-C9E3-3E88-B114-FEB1864BC9E0, la del informe;
CoreServices cargado con un desplazamiento de 0x38fdc000):

- CoreServices `_LSDNCCharacterSetContainsCharacterFromInlineBuffer` (0x181bfe1e8): en 0x181bfe210
  `bl objc_msgSend$characterIsMember:`; la dirección de vuelta es CoreServices+0x2a214, el lr del hilo 3.
- `objc_msgSend` (0x1800ba400): acierto en caché = `ldp x17, x9, [x13]` (imp codificado, sel), `cmp x9, x1`,
  `eor x17, x17, x16` (x16 = la clase), `br x17` (0x1800ba42c-0x1800ba43c). Un cubo vacío tiene sel 0 y va a
  `__objc_msgSend_uncached` (`cbz x9`, 0x1800ba440).
- `cache_t::insert` (0x1800bfc00…) escribe el cubo con un único `stp x9, x19, [x8]` (imp codificado, sel) en
  0x1800bfd3c, y publica los arrays nuevos de cubos (`calloc`, a cero) con `stlr`.

Si el lector ve `sel` ya escrito e `imp` todavía 0, `x17 = 0 ^ clase = clase` y salta a la clase: el pc del hilo 3 es
exactamente `OBJC_CLASS_$___NSCFCharacterSet` + 0, memoria de datos sin permiso de ejecución → aborto de instrucción
por permiso → `KERN_PROTECTION_FAILURE` → SIGBUS. Ningún otro estado del cubo da ese pc. libobjc da por hecho que un
`ldp`/`stp` de 16 bytes alineados es atómico de una sola copia; la arquitectura ARM solo lo garantiza con FEAT_LSE2
(ARMv8.4) y los A53/A73 son ARMv8.0 [ARM ARM B2.2.1, de memoria, no verificado en el texto]. Un dato obsoleto en una
línea de caché no produce este estado: imp y sel están en los mismos 16 bytes de la misma línea, y una línea vieja
entera daría sel 0 (fallo de caché inofensivo).

En ese momento ocho hilos de `com.apple.frontboard.applicationLibrary.asynchronousAppLoader` (un `dispatch_apply`)
llenaban a la vez cachés de métodos recién creadas: el caso de máxima exposición.

### 1.4 La misma caída antes de 0344

[O] `crash-telefono/seserviced-2026-11-13-160709.ips` (13 nov, 16:07, 45 s tras arrancar, sin tweaks inyectados):
`EXC_BAD_ACCESS (SIGBUS) KERN_PROTECTION_FAILURE`, pc = far = `OBJC_CLASS_$___NSCFString` + 0, ESR 0x8200000f, lr
dentro de `-[__NSDictionaryM objectForKey:]`, y **x16 = x17 = la clase, x9 = x1 = el selector**. 0344 se escribió el 14
nov (commit de las 11:27 hora del teléfono): el 13 nov el kernel vaciaba la caché antes de cada WFI. El mecanismo
existe con el vaciado activo.

### 1.5 Medidas: el par se rompe en los dos tipos de núcleo

[M] `pairtear` (`tools/pairtear.c`): un escritor alterna `stp v, v` y `stp xzr, xzr` sobre 256 pares de 16 bytes
alineados; un lector los lee con `ldp` y cuenta los pares con las dos mitades distintas («imp0» = mitad baja 0 y alta
no). Además un paso de mensajes (dato y luego bandera con `stlr`; bandera con `ldar` y luego dato). Lanzado con
`spawnfg`; QoS UI = A73, BG = A53 con `sweetsched=15`; CPU vista por `TPIDR_EL0`. `kern.sweet_idle_cache=0`; 4 s por
ensayo, n=3 (`pairtear-idle0-2.txt`):

| Escritor → lector | Lecturas de pares | Pares rotos (de ellos «imp0») | 1 roto cada |
|---|---|---|---|
| A73 → A73 | 1,16 × 10⁹ ×3 | 160 549 (102 252) · 167 582 (108 156) · 166 361 (107 144) | 6 900-7 250 lecturas |
| A53 → A73 | 1,08 × 10⁹ ×3 | 10 942 (5 340) · 6 766 (3 529) · 6 374 (3 144) | 98 000-169 000 |
| A53 → A53 | 4,6 × 10⁸ ×3 | 343 (156) · 214 (77) · 216 (88) | 1,3-2,1 millones |
| A73 → A53 | 3,1 × 10⁸ ×3 | 10 (10) · 12 (7) · 56 (44) | 5,6-31 millones |
| Paso de mensajes, todas | 2,9 × 10⁸ por ensayo | 0 fallos en los 12 ensayos | — |

Lectura: la coherencia y el orden acquire/release entre núcleos y entre clusters funcionan (0 fallos de paso de
mensajes); lo que falla es la atomicidad del par, que la arquitectura no promete aquí.

[M] `objctear` (`tools/objctear.m`): cada ronda crea una clase con 48 métodos y cuatro hilos llaman a todos a la vez.
Con `idle_cache=0` (`objctear-idle0.txt`): en los A73, SIGBUS en las rondas 23, 365, 216, 41, 23 y 580 (6 de 6, todas
en menos de 30 s); en los A53, rondas 2012, 2762 y 797 (3 de 3). Un informe sin manejador
(`crash-telefono/objctear-2026-11-14-154001.ips`): `KERN_PROTECTION_FAILURE`, ESR 0x8200000f, pc = far = x15 = x16 =
x17 = la clase, x9 = x1 = el selector: la firma de §1.3 y §1.4.

Falta para cerrar la comparación (§3): las mismas dos pruebas con `idle_cache=1`. Predicción: también se rompen.

### 1.6 La caída de las 15:05:57

[O] Hilo principal, `-[SpringBoard _startSystemStatusServerAndFriends]` → `-[STTelephonyStateProvider init]` →
`_CTServerConnectionRegisterForEvent` → `RegisterClientForEvent` → `SendXpcMessageIf` → `_HandlePrepWorkBeforeSend`
(CoreTelephony 0x188157f30: si la conexión no ha hecho el check-in, `_CTServerConnectionCheckIn` y, con el último
argumento a 1, `ReregisterClientForAllEvents`) → `ReregisterClientForAllEvents` (0x188165b1c), que recorre el
`std::set` de eventos del estado de la conexión (`[x19+0x18]`, nodos desde `+0x20`) y vuelve a registrar cada uno.
La falta (0x188165c64, `ldr x10, [x9]`) es el avance del iterador de libc++: el nodo actual (x23 = 0x281d7c030) no
tiene hijo derecho y su puntero al padre (`[x23+0x10]`) es 0. En un árbol de libc++ el padre de la raíz es el nodo
fin, nunca 0: ese nodo no pertenece al árbol. Su valor (`[x23+0x20]`, x1) es 0xfffffffd (−3), que el bucle salta por
ser < −1.

- No es la forma de una página con datos viejos o a cero: un nodo con contenido de otra asignación (padre 0, valor −3)
  dentro de un árbol por lo demás recorrible.
- [O] CommCenter (pid 93) lleva vivo desde el arranque de las 13:25; no hubo reinicio del servidor en ese momento.
  Ningún otro hilo del informe está en CoreTelephony (el estado de los hilos es el de después del manejador).
- Las líneas `CRASH SpringBoard …` que el kernel imprime para cada proceso que muere (`osfmk/kern/exception.c`,
  `sweet_crash_log`, con el mapeo de `far`) ya no están en el `dmesg` (131 KB, rotado) y el ring no se puede leer con
  la raíz montada (`/dev/ufsroot0`: *Resource busy*).

[H] Candidatos, sin medir: (a) una carrera de CoreTelephony entre el registro de eventos en el hilo principal y otro
hilo que libera o sustituye el estado de la conexión (uso tras liberar); (b) otra estructura de Apple que dé por
atómico un par `ldp`/`stp` (como §1.3) dentro de malloc o de libc++, cuyo resultado roto acabe en un nodo ajeno. No
hay ninguna caída equivalente en los registros anteriores. **Causa no establecida (n=1).**

### 1.7 Todas las caídas del teléfono

`scripts/ipsum.py crash-telefono/*.ips` (hora del teléfono):

| Proceso | Fechas | Firma | ¿Caché? |
|---|---|---|---|
| CommCenter | 13 nov 15:49 a 14 nov 11:26 (19 informes, 3 sin fecha de reloj) | `EXC_BREAKPOINT` en `RouterIPCController::engage_sync()`+680 desde `liblinkguard` `engage_later`, a los 44-64 s de cada arranque | No: determinista en cada arranque, antes y después de 0344; desde las 11:26 no hay ninguno |
| CommCenter | 14 nov 07:55 | SIGSEGV en `liblinkguard` `dump_stacks` (su perro guardián) | No |
| seserviced | 13 nov 16:07 | SIGBUS, pc = `OBJC_CLASS_$___NSCFString` | §1.4: lectura rota de objc, con vaciado |
| SpringBoard | 14 nov 11:41, 15:05 | §1.3, §1.6 | No / no establecida |
| mediaserverd | 13 nov 12:44, 12:47 | `abort()` por excepción C++ no capturada | No estudiada |
| Pride/UnityPosterExtension | 13 nov 12:36 | BRK en `PRSPosterPath` | No estudiada |
| memlat | 14 nov 11:18 | SIGILL al leer `CTR_EL0` desde EL0 (16 §7) | No: herramienta |
| lsplug | 14 nov 13:03 | SIGSEGV en `objc_release` desde su `main` | No: herramienta |
| CalendarWidgetExtension | 13-14 nov | límite de CPU (03 M13; 20) | No |

### 1.8 Qué valor tenía `idle_cache` en cada caída

- [O] 0344 entra en la serie a las 11:27 (hora del teléfono). Hubo arranques a las ~11:25 (los CommCenter de 11:25-11:26
  tienen uptime 46-62 s) y a las 11:36:43 (uptime 310 s de la primera caída).
- [O] `/redwood/boot.d/80-gfx.sh`, que pone `kern.sweet_idle_cache=0` al arrancar, se modificó a las 11:43, después de
  la primera caída. Con 0350 el valor al arrancar era 1; si a las 11:41 estaba en 0 dependía de un `sysctl -w` a mano
  en esos cinco minutos (03 M10 describe el A/B 1, 0, 1, 0 y luego el gobernador, sin horas). **No verificado.**
- A las 15:05 el kernel era 0353 (con 0351): 0.

La conclusión de §1.3-§1.5 no depende de esto.

## 2. Auditoría de coherencia del port

Contrato en ARM con dispositivos no coherentes: limpiar a PoC lo que la CPU escribió antes de que el dispositivo lo
lea; invalidar antes de que la CPU lea lo que escribió el dispositivo (y después de que termine, por la especulación);
no mapear la misma RAM con atributos distintos. Lo que hacía el vaciado en reposo: cada núcleo, al dormirse, escribía
a DRAM e invalidaba su L1 y la L2 de su cluster; con miles de entradas por segundo en los dos clusters, ninguna línea
sucia ni vieja vivía más de unos milisegundos. Tapaba todo defecto de «falta un clean» o «falta un invalidate» con
una ventana de ese orden.

### 2.1 Núcleo

[O] El port no define `__ARM_COHERENT_IO__`, `XNU_MONITOR` ni `__ARM_PTE_PHYSMAP__`: el physmap (`phystokv`) es un alias
write-back de toda la RAM cuyos atributos no cambian nunca. Memoria normal y tablas: Outer Shareable, write-back. El
port no toca CPUECTLR/ACTLR/SMPEN (la coherencia entre clusters la pone el firmware PSCI). Detalle en `agente-nucleo.md`.

1. **Límites de 0351.** `CleanPoC/FlushPoC_Dcache` siguen cubriendo L1 y L2 (LoC = 2); `CleanPoU/FlushPoU_Dcache` pasan
   a cubrir solo la L1 (LoUIS = 1), que es su significado arquitectónico. Fuera del reposo nadie del port usa las
   variantes PoU por set/way salvo `dtrace_flush_caches` (`bsd/dev/arm64/dtrace_isa.c:672-679`, riesgo bajo: no se usa
   en el teléfono). Las variantes por dirección (`…Region`, `flush_dcache`, `clean_dcache`, `sweet_dcache_*`) no
   cambian y recorren toda la región con la línea de `CTR_EL0` (auditoría).
2. **Mantenimiento «bulk» por set/way (defecto latente).** [O] `cpuid.c:367` fija `c_bulksize_op` = tamaño de la L2
   (2 MB). Por encima, `dcache_incoherent_io_flush64/store64` (`osfmk/arm/caches.c:153-158`, `214-219`; usados por
   `IOMemoryDescriptor::performOperation` e `IODMACommand`), `flush_dcache_syscall` (`:133`) y
   `platform_cache_flush_wimg` (`:363`, `:372`) hacen `FlushPoC_Dcache`/`CleanPoC_Dcache` por set/way: llegan a la L1
   del núcleo que llama y a la L2 de su cluster, no a las líneas sucias de los otros siete núcleos. Hoy casi nada del
   port pasa por ahí (los drivers usan `flush_dcache64`/`sweet_dcache_*` por dirección; auditoría). Arreglo: 0392.
3. **Cambio por lotes de cacheable a no cacheable (defecto latente).** [O] `pmap_batch_set_cache_attributes`
   (`osfmk/arm/pmap/pmap.c:10353-10375`) cambia PTE y atributo de página, pero la pasada de limpieza (`:10456-10500`)
   solo corre para RT. El camino de una página (`:10593` → `pmap_sync_wimg`, `:10093-10107`) sí limpia. El lote lo usa
   `vm_object_iopl_request` (`osfmk/vm/vm_pageout.c:8884`) para objetos con WIMG distinto del de defecto, que pone a
   cero las páginas por el physmap antes de cambiar su modo (auditoría): esos ceros quedan sucios en una caché y pueden
   escribirse más tarde encima de lo que escribió la CPU por el mapeo no cacheable o un dispositivo. [O] Las
   IOSurface del port no pasan por aquí: las paginables son `kIOMapDefaultCache` (`SweetSurface.cpp:1034`) y las
   write-combined son direcciones físicas sin gestionar (`:440`, `:946`). Sin usuario conocido. Arreglo: 0392.
4. **`io_map`/`ml_io_map*`/`withPhysicalAddress()->map()` sobre RAM gestionada** dejan el PTE no cacheable y el
   atributo de la página en write-back, sin limpiar (auditoría, `agente-nucleo.md` §C). Usuarios: el USB, que limpia
   antes (§2.3); el resto mapea RAM fuera de la del kernel (§2.4, §2.5).
5. **Instrucciones, arranque e IPIs, correctos** (auditoría): `vm_fault` sincroniza la caché de instrucciones de las
   páginas ejecutables (`cache_sync_page`: DC CVAU + IC IALLUIS); `cpu.c:1011-1024` limpia lo que leen los
   secundarios con la MMU apagada; `dsb ishst` antes de `ICC_SGI1R` (`SweetCPU.cpp:270`).
6. **Emulación de LSE.** [O] El kernel emula los atómicos LSE del userland de iOS 16 (`sleh.c` `sweet_emulate_lse`,
   `machine_routines_asm.s` `_sweet_lse_*`, con `ldaxr`/`stlxr`, acquire+release). [M] Con la macro copiada tal cual y
   ejecutada en EL0 en el teléfono (`tools/lsetest/`, 80 000 casos por operación y tamaño, `lsetest-resultado.txt`):
   ADD, CLR, EOR, SET, SMAX, SMIN, UMAX, SWP, CAS y LDAPR sin fallos; **UMIN mal en 40 049 de 80 000**: tras
   `cmp w1, #6` el `csel … lo` de UMIN usa las banderas de esa comparación y guarda siempre el operando. Arreglo: 0390
   (con él, 0 fallos). No tiene relación con la caché; afecta a cualquier `LDUMIN*` del userland.

### 2.2 Almacenamiento (UFS)

[O] `bsd/dev/sweet_ufs.c`: memoria DMA contigua cacheable (`:869-878`), sin alias no cacheable, nunca liberada; regiones
alineadas a 64 B; antes del timbre, clean (escritura) o clean+invalidate (lectura) por dirección y `dsb`
(`:193-214`); tras completar, `dsb` y clean+invalidate otra vez de UTRD, respuesta y buffer de rebote antes de leerlos
(`:244-254`). Los datos llegan a páginas de usuario o del page cache solo por `memcpy` de la CPU desde el rebote, bajo
`sweet_ufs_lock`. Cubre strategy de bloques, page-in de ficheros mapeados, E/S directa, la E/S cruda de 0334, el ring,
la caja negra, el GPT y su perro guardián (auditoría, `agente-almacenamiento.md`; las líneas citadas las leí). Correcto
y sin dependencia del vaciado. Huecos menores: varios errores de strategy (EINVAL, ENOTSUP, EROFS, EIO de `buf_map`,
`:549-566`) no dejan rastro; tras un timeout el slot se reutiliza sin confirmar que el host lo soltó (`:229`).

### 2.3 USB

[O] Ruta de datos v2 (la activa, 0330): limpia e invalida el área y luego la mapea write-combined
(`sweet_usb.c:1925-1935`), el esquema de Linux para DMA no coherente en arm64; `dsb sy` antes de Start Transfer
(`:1395`), `dmb` alrededor del contador de eventos (`:70-74`, `:1746`). Correcto. La ruta vieja (`sweetusb_dp=0`) y la v2
cacheable (`sweetusb_dpnc=0`) comparten líneas de 64 B entre TRBs que escribe la CPU y campos que escribe el
controlador (`:241-255`, `:366-380`): defecto real pero inactivo, independiente del vaciado (auditoría).

### 2.4 Módem, ADSP, IPA, Wi-Fi, Bluetooth, audio, cámara, QSEE

[O] Toda la memoria compartida con otros procesadores se mapea write-combined o como dispositivo
(`TopazModem.cpp:96-104` `map_phys`, `ml_io_map` de registros) y está fuera de la RAM del kernel (que empieza en
0x1_4000_0000 con el ADT `--highmem`): no hay alias cacheable ni líneas que el vaciado pudiera tocar. Ninguno de
esos archivos hace mantenimiento de caché ni cambió entre 0342 y 0353 (auditoría, `agente-radios.md`). Sin dependencia
del vaciado. Hallazgos ajenos a la caché (auditoría; el primero lo leí):

- `q_srv[]` (servicios QRTR) lo amplían el hilo del módem (`TopazModem.cpp:859-866`) y el del ADSP (`:10224-10236`)
  sin cerrojo, y `topaz_qmi_lookup` (`:9252-9262`), que sirve a CommCenter, lo lee sin barrera.
- `svc_rx` corre en los dos hilos sin cerrojo (`:884`, `:10245`); `sq_close` lee el puerto fuera del cerrojo
  (`sweet_qmi_dev.c:188-196`).
- Con `ipa=1` (activo en el teléfono), `gsi_events` lee el puntero de escritura de eventos sin barrera antes de leer
  el anillo (`:8087`, `:8179-8187`).
- Lectura de GLINK RX y SMP2P sin barrera entre índice y datos (`:592-608`, `:9728-9747`, `:469`).

No verificado: que el ADT instalado sea `--highmem` (con `--midmem` el pool del módem en 0xE0000000 caería en RAM
cacheable del kernel y sí habría dependencia). La línea `pool … (kernel RAM %lx-%lx)` del log de arranque lo decide.

### 2.5 GPU, framebuffer e IOSurface

[O] Correcto y sin dependencia (auditoría, `agente-gpu.md` §3): anillo, fences, SQE y tablas de la SMMU (WC + SMMU
no cacheable, `dsb` antes del puntero de escritura); BOs del GPOOL; pool del scanout (WC en todos los mapeos: physmap
no lo cubre, kernel, IOSurface, cliente msm, GPU; nunca vuelve al VM); flip buffers, consola, `video_console`. Las
superficies normales son memoria paginable del kernel, **cacheable**, que la GPU lee y escribe por DMA:

1. **Escrituras de CPU que no se anuncian (dependencia del vaciado, riesgo alto para la imagen).** [O] Con
   `kern.sweet_gpu_flush=1` (`SapphireGpu.cpp:5630-5690`, `msm_surface_sync`) un submit limpia una superficie solo si
   su `cpuEpoch` se movió, y `cpuEpoch` se mueve con lock/unlock de IOSurface, mapear/desmapear, `GEM_CPU_PREP`/`FINI`
   y las copias del kernel. El propio comentario de 0339 (`:5646-5651`) dice que no se entera de lo que un programa
   escribe por el mapeo de su cliente GPU sin bloquear la superficie. [O] HakiosMetal lo hace en `Texture::replace` y
   `Texture::read` (`hakios-metal/src/texture.cpp`, `memcpy` sobre el mapeo) y no llama nunca a `Gpu::cpuPrep` ni a
   `Gpu::cpuFini` (`gpu.cpp:191`, `:196`: sin llamadas en la rama `opcional-puerto`). [M] `kern.sweet_gpu_diag`: `cpu
   prep 0, 0 bytes flushed`; `kern.sweet_gpu_flush_stats`: 54 500 superficies nombradas, 54 275 sin nada que hacer
   (`sysctl-gpu-1545.txt`). Con el vaciado, lo escrito llegaba a RAM en milisegundos; ahora puede quedarse sucio en
   una caché mientras la GPU lee la RAM vieja (trozos de 64 B, o zonas, con contenido anterior), y una línea sucia que
   se expulse después de que la GPU escriba pisa lo que dibujó.
2. **Falta invalidar después de que la GPU escriba (riesgo medio).** [O] En el modo 1 solo se invalida antes del
   submit (`:5679-5683`); el trap de `IOSurfaceLock` solo mueve contadores (`SweetSurface.cpp:1546-1604`, `trapLock` en `:1581`) y nadie llama
   a `GEM_CPU_PREP` (`SapphireGpu.cpp:6559`, que sí espera el fence e invalida). Una línea traída por especulación o prefetch durante
   el dibujo se lee después en lugar de lo que escribió la GPU (capturas, `Texture::read`, procesos que leen la
   superficie). Antes la borraba el vaciado.
3. **Latente:** el modo de caché del mapeo de usuario lo decide quien llama (`IOUserClient.cpp:1953-1955`) y
   HakiosMetal pide solo `kIOMapAnywhere` (auditoría).

Ninguno de los tres explica las caídas de SpringBoard (que no es cliente de la GPU sin `metal_all=1`); son
candidatos para los «trozos viejos», el parpadeo de widgets y el fondo con bloques de 03 M10/M16 (este último, n=1, con
1260 MHz y el gobernador; no explicado).

### 2.6 Resumen

| Camino | Mantenimiento | ¿Correcto? | ¿Lo tapaba el vaciado? |
|---|---|---|---|
| UFS (todas las rutas) | clean / clean+inval por dirección antes y después de cada comando | Sí | No |
| USB v2 | área WC preparada con clean+inval | Sí | No |
| USB v1 / v2 cacheable | líneas compartidas CPU-controlador | No (inactivo) | No |
| Módem, ADSP, IPA, Wi-Fi, BT, audio, cámara, QSEE | memoria fuera de la RAM del kernel, WC/dispositivo | Sí (con `--highmem`) | No |
| GPU: anillo, fences, SMMU, GPOOL, pool del scanout | WC + barreras | Sí | No |
| GPU: IOSurface normales, `gpu_flush=1` | clean/inval solo con acceso anunciado | No: HakiosMetal no anuncia | **Sí** |
| GPU: lectura de CPU tras dibujo de la GPU | ninguno tras el fence | No | **Sí** |
| DMA ≥ 2 MB por `performOperation`/`IODMACommand` | set/way local | No (sin usuario conocido) | Sí |
| Cambio por lotes WB → WC/IO | ninguno | No (sin usuario conocido) | Sí |
| Emulación LSE `LDUMIN` | — | No | No (no es de caché) |
| objc: `ldp`/`stp` de 16 B | — | No en ARMv8.0 | No (§1.4) |

## 3. Experimentos

Herramientas instaladas en `/var/root/coherencia/` del teléfono; guiones en `tools/`. Nada de lo de abajo reinicia el
teléfono; el primero y el segundo cambian `kern.sweet_idle_cache` y lo devuelven.

1. **`exp-coherencia.sh`** (~15 min; bloques alternados 0, 1, 0, 1): por bloque, `pairtear` en las cuatro colocaciones
   (4 s), `objctear` 3 veces en los A73 y 2 en los A53 (30 s como máximo), e `iocheck` de 256 MB × 2 sin page cache con
   dos hilos girando en los A73; `kern.sweet_idle_stats` antes y después. Decide: si con 1 `objctear` sigue cayendo y
   `pairtear` sigue rompiendo pares, la caída de §1.3 es independiente del vaciado (predicción). n = 2 bloques × (5
   `objctear` + 4 colocaciones) por modo.
2. **`relanzar-sb.sh N`** con `idle_cache` fijado antes en 0 y luego en 1: N reinicios de backboardd, 45 s entre uno y
   otro; anota `.ips` nuevos de SpringBoard, líneas `CRASH SpringBoard`/`SWEET OBJC` de `dmesg` tomadas justo después, y
   el contador de 0391. Para separar una tasa de 0,05 por relanzamiento de 0 hace falta N ≈ 60 por modo (P(0 caídas |
   p = 0,05, N = 60) = 0,046); con N = 20 solo se separa p ≥ 0,14. Tras una caída SpringBoard sigue en el modo seguro
   (sin tweaks), lo que cambia las condiciones: anotar cuándo.
3. **GPU** (sin reiniciar): `kern.sweet_gpu_flush=2` durante una sesión normal; cualquier línea de la consola del
   driver que rechace `-replaceRegion:`/`-getBytes:` confirma escrituras/lecturas de CPU sin anunciar en la vida
   real. Después, A/B a la vista en la vista de widgets y el Centro de Control: `gpu_flush=0` frente a `1` con
   `idle_cache=0`, y `gpu_flush=1` con `idle_cache` 0 frente a 1.
4. **Solo lectura**: `kern.sweet_gpu_diag` (`cpu prep`), `kern.sweet_gpu_flush_stats`, `kern.sweet_fb_scanout_diag`
   («refused (full)», «not from the pool»), y con 0391 `kern.sweet_objc_tear_count`.

[M] Hecho ya, con `idle_cache=0`: `pairtear` y `objctear` (§1.5); `iocheck /var/tmp/iocheck.bin 64 2`: 2 rondas de 64
MB sin palabras malas (0,96 s en total). No verificado que la relectura con `F_NOCACHE` llegue al disco y no al page
cache de HFS.

## 4. Arreglos

Parches en `~/sapphire-angel/research/metal/coherencia/parches/`; `git apply --check` y aplicados en orden sobre la
serie hasta 0353 (`3439af8`). Comprobación de sintaxis de `sleh.c`, `cpuid.c` y `pmap.c` con stubs (`scripts/sync.sh`):
sin errores en el código nuevo (los que salen son de cabeceras generadas que faltan, iguales sin los parches).
Sin compilar el kernel completo ni probar en el teléfono.

- **0390** `sapphire-lse-ldumin`: UMIN compara otra vez el valor viejo con el operando antes de su `csel`. Probado en
  EL0 con la macro copiada (§2.1.6).
- **0391** `sapphire-objc-torn-cache-entry`: en un aborto de instrucción de EL0 sin resolver, si pc = far = x17 = x16 =
  x15, x1 ≠ 0 y x9 = x1 (exactamente lo que deja `objc_msgSend` tras leer un cubo roto), en la caché compartida de UUID
  8F970452-… y con tres instrucciones de `__objc_msgSend_uncached` comprobadas (`stp fp, lr`, `mov fp, sp`,
  `mov x16, x15` en +0x30), el hilo sigue en `__objc_msgSend_uncached` (0x1800ba7c0 + slide), que es lo que hacen
  `objc_msgSend` y `objc_msgSendSuper2` cuando no encuentran entrada: busca el método bajo el cerrojo del runtime y lo
  llama con x0-x8, q0-q7 y lr intactos. `kern.sweet_objc_tear` (1 por defecto; 0 deja la falta al proceso),
  `kern.sweet_objc_tear_count` y una línea `SWEET OBJC: …` en las 16 primeras y cada 1024. Es el mismo tipo de
  remedio que la emulación de LSE: el userland de iOS 16 da por hecha una garantía de los núcleos de Apple (FEAT_LSE2)
  que estos núcleos no tienen, y el kernel completa la semántica en el único punto donde falla. La alternativa de
  fondo en userland es parchear libobjc (que el acierto trate imp 0 como fallo) en la caché compartida; queda
  descartada mientras no haya forma de firmarla. Validación: `objctear` con el kernel nuevo no debe caer y el contador
  debe subir. `objc_msgLookup` (devuelve el imp y salta quien llama) no queda cubierto si quien llama pisa x9 o x16.
- **0392** `sapphire-cache-maintenance-by-address`: `c_bulksize_op = 0` en SWEET (todo mantenimiento de DMA, de
  `flush_dcache_syscall` y de cambio de WIMG va por dirección, que llega a las cachés de todos los núcleos), y el cambio
  por lotes de una página cacheable a no cacheable la limpia en la pasada 3, como el camino de una página.

Recomendados, sin parche:

- **GPU (§2.5.1-2), arreglo de fondo en el driver**: HakiosMetal debe rodear todo acceso de CPU a un BO de superficie
  con `GEM_CPU_PREP` (espera el fence y limpia/invalida, ya implementado en `SapphireGpu.cpp:6559-6592`) y
  `GEM_CPU_FINI` (mueve `cpuEpoch`), como exige el contrato msm. En el kernel, `IOSurfaceLock` de lectura de una
  superficie cacheable que la GPU dibujó desde la última invalidación debería esperar su `gpuFence` e invalidarla.
  Mientras tanto, `kern.sweet_gpu_flush=0` (limpia e invalida antes de cada submit toda superficie mapeada: ~1,5 ms por
  submit, 15) es el modo seguro; `80-gfx.sh` pone 1.
- **Módem**: un cerrojo para `q_srv[]` y `svc_rx`; `dmb oshld` tras leer índices de RX (GLINK, SMP2P, `gsi_events`).
- **UFS**: contador y `printf` limitado para los errores de strategy que hoy no dejan rastro.

## 5. No verificado

- El valor de `kern.sweet_idle_cache` a las 11:41 (§1.8).
- El efecto de `idle_cache=1` sobre la tasa de pares rotos (§3.1); el mecanismo no depende de él (§1.4).
- La causa de la caída de las 15:05 (§1.6).
- Que el ADT instalado sea `--highmem` (§2.4); que la relectura de `iocheck` llegue al disco (§3).
- El texto exacto del ARM ARM sobre la atomicidad de `LDP`/`STP` (citado de memoria); la medida de §1.5 es lo que
  cuenta aquí.
- 0390-0392 compilados en el kernel completo y probados en el teléfono.
