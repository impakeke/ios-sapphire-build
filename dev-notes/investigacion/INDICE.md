# Investigación de iOS en sapphire — índice

Investigación detrás de los arreglos de USB y UFS del fork (parches 0329-0334) y del trabajo de gráficos
(parches 0336-0352, driver Metal). Todo lo que hay aquí es
**observación medida** (03), **fuente primaria citada** (02) o **auditoría fechada** de lo heredado (01, 04).
Cómo operar el teléfono: [../OPERACION.md](../OPERACION.md).

## Estado actual (medido)

1. **El USB de iOS enumera en arranque normal**, sin pasar por fastboot: 8/8 arranques con UTMI como reloj
   PIPE (0331; por defecto desde 0332/0333), 0/3 sin ello. En arranque normal el reloj PIPE del PHY USB3
   está apagado (03 E2); el ABL solo arranca el USB dentro de fastboot (02 §P4).
2. **El enlace aguanta carga** con la ruta de datos v2 (0330; por defecto desde 0332/0333): 20×30 MB
   íntegros y 0 Start Transfer rechazados. La ruta 0327 moría a los 192 KiB por la doble toma de la
   finalización (HWO + evento) más el bucle de `printf` (01 §1).
3. **La E/S cruda de `sweet_ufs` no escribe en memoria de usuario desde el kernel** (0334, validado en 03 E7).
4. **Acceso:** SSH persistente solo con clave en 192.168.7.2, vuelta remota a fastboot
   (`kern.sweet_reboot_mode=2`) y bucle de ensayos automático (`~/adb-bridge/exp-loop.sh`).
5. **Frecuencia de la GPU:** con `gpu_vco2=1`, `gpu_mhz` es la frecuencia real del núcleo (0337; `gxfreq`: 820,00 y
   1260,00 MHz, 03 M4, M7, M10); sin `gpu_vco2`, `gpu_mhz=1260` la deja a 630,00 MHz, 15/15 (03 M3; 11). Se cambia
   en caliente con `kern.sweet_gpu_khz` (0345: 312-1344 µs por cambio) y hay gobernador (0346; en reposo baja a
   320 MHz) (03 M10; 17). El DDR corre a 1555,2 MHz bajo iOS, 7/7 (17 §4.3; 03 M10).
6. **"La GPU está limitada por el ancho de banda de memoria" no se sostiene**: la pasada principal mueve menos de
   25 MB en 18-24 ms (1,0-1,4 GB/s), y el argumento era que subir el reloj no cambiaba nada cuando el reloj no subía
   (11 §9, §14; 09 §8).
7. **El driver Metal se compila desde fuente en la Mac** (08): upstream de HackiOS `63fc2b4` más parches A610 propios.
   Ramas `cpu-draw` (13) y `gpu-pass` (14); el bundle fusionado `merge-3` es el instalado (03 M9-M12). Se instala por
   renombrado y se comprueba que backboardd es cliente de `SapphireGPU`: copiado encima de otro, el driver no carga y
   CoreAnimation compone por software (03 M8; 14; [../OPERACION.md](../OPERACION.md) §9.3). El instalador lleva ese mismo build; su
   fuente (serie de parches sobre el upstream y receta) está en [`metal/hakios-metal/`](../../metal/hakios-metal/README.md).
8. **Kernel de la presentación y del submit** (0339-0342; 03 M7; 15): con la cola `kern.sweet_fb_queue=1` ningún frame
   se pisa (10,6 % → 0) y con `kern.sweet_gpu_flush=1` la limpieza de caché por submit pasa de 1,70 a 0,01 ms. La línea
   `SWEET FB: 5 s … N by the GPU` cuenta swaps, no frames mostrados, y sus tiempos salen a 0 con `sweetfb_scale=2` (09).
9. **CPU:** XNU vaciaba la L2 del cluster A73 antes de cada WFI (16 §4). Con `kern.sweet_idle_cache=0` (0344; 0351, sin probar, lo hace el valor por defecto) el
   driver baja de 62-68 a 25-26 µs por draw y los command buffers por segundo pasan de 29,6-31,6 a 44,0-46,9 (n=2,
   03 M10). En XNU las CPU 0-3 son los A73 y las 4-7 los A53, al revés que en Linux (16 §1; 03 M8).
10. **Ningún recurso está saturado:** por frame, la GPU trabaja 8,3 ms dibujando y 4,15 ms en la copia escalada al
    panel (12,5 ms, medidos con su propio contador), y el hilo de render gasta ~13,7 ms de CPU y espera su tick el
    23 % del tiempo (n=1, 03 M11). De commit a fin pasan 23-27 ms (03 M10): es latencia con colas, no tiempo de GPU.
    Lo que fija los frames por segundo es cómo se encadenan CPU, GPU, copia y presentación. Siguiente: "Gráficos:
    siguiente trabajo" abajo.

## Reglas para agentes

- **Comprobar que el parche se aplicó en el CI.** darwin-xnu-build salta en silencio los parches que no
  aplican (`build.sh` L472-478): mirar el log de la ejecución, o `git apply --check` en orden antes de subirlo.
- **Leer el ring por `/dev/ufsroot0`** (dispositivo de bloques). `/dev/rufsroot0` provoca panic en kernels sin 0334 (03 E5).
- **Nunca escribir `boot_b`** ni ninguna partición de Android. iOS va solo en `boot_a`.
- **Ninguna afirmación heredada vale sin medición o fuente primaria.** Lo ya auditado está en 01 §4 y 04.
- **n≥3 por condición** antes de concluir; anotar ruta de arranque (R/C), kernel y parches de cada ensayo en 03.
- **En `dd` del teléfono, tamaños en bytes:** no acepta sufijos como `4m`.

## Documentos

| # | Archivo | Qué es |
|---|---|---|
| 01 | [01-auditoria-sweet_usb.md](01-auditoria-sweet_usb.md) | Auditoría del driver USB post-0328: mecanismo del fallo bajo carga con números de línea, 16 defectos, tabla de afirmaciones, diseño corregido e instrumentación |
| 02 | [02-fuentes-primarias-dwc3-abl.md](02-fuentes-primarias-dwc3-abl.md) | Fuentes primarias: Linux/U-Boot dwc3, código y binarios de ABL, PHY femto, DT de khaje, erratas |
| 03 | [03-experimentos-y-datos.md](03-experimentos-y-datos.md) | Bitácora de mediciones en el teléfono: USB y UFS (E0-E7), muestreo de CPU y gráficos (M1-M11) |
| 04 | [04-auditoria-documentacion-heredada.md](04-auditoria-documentacion-heredada.md) | Auditoría del resto de docs: arranque/recovery, **seguridad** (hash en spwd.db, .supdate root sin firma, shell 2323), qué funciona, reproducibilidad, licencias, riesgos |
| 05 | [05-parche-0330-ruta-de-datos.md](05-parche-0330-ruta-de-datos.md) | Parche 0330: ruta de datos v2 — diseño, invariantes, verificación, riesgos, boot-args del A/B |
| 06 | [06-parche-0334-ufs-raw-io.md](06-parche-0334-ufs-raw-io.md) | Parche 0334: panic de `sweet_ufs` en E/S cruda (memcpy del kernel a una VA de usuario vía physio), arreglo con `uiomove` |
| 07 | [07-plan-cpu-stutter.md](07-plan-cpu-stutter.md) | CPU y tirones al deslizar: H1-H4 respondidas con mediciones (render saturado en el driver, L2 vaciada, frames pisados); H5 y H6 sin medir |
| 08 | [08-hakiosmetal-binario-vs-fuente.md](08-hakiosmetal-binario-vs-fuente.md) | El binario `HakiosMetal` frente a la fuente: procedencia, auditoría de los cambios del port al A610, receta de reconstrucción y bundles propios |
| 09 | [09-auditoria-kernel-gpu.md](09-auditoria-kernel-gpu.md) | Auditoría del kernel en la ruta gráfica: buffers, submit, fences, presentación (frames pisados, copia escalada por frame, vsync), parches 0336 y 0338 |
| 10 | [10-auditoria-rendimiento-hakios-metal.md](10-auditoria-rendimiento-hakios-metal.md) | Auditoría de rendimiento del driver Metal: coste de CPU por draw, por qué la pasada principal tarda 20 ms (102 tiles, estado repetido por tile), plan por etapas |
| 11 | [11-gpu-relojes-bus-vs-android.md](11-gpu-relojes-bus-vs-android.md) | Relojes, raíles, bus y memoria de la GPU frente a Android en este teléfono; parche 0337 y su escalera |
| 12 | [12-escena-drivers-metal-alternativos.md](12-escena-drivers-metal-alternativos.md) | Otros proyectos con driver Metal sobre GPU que no es de Apple: mapa de la escena, cifras publicadas, veredicto |
| 13 | [13-driver-cpu-por-draw.md](13-driver-cpu-por-draw.md) | Driver: coste de CPU por draw, rama `cpu-draw` (etapas A y B de 10 §2.7): punto de partida, suite de host con las constantes del A610, arreglo de la palabra de desbordamiento del VSC. **En curso** |
| 14 | [14-driver-gmem-tiles-estado.md](14-driver-gmem-tiles-estado.md) | Driver: pasada GMEM, estado por tile, geometría de tiles y GMEM o sysmem por pasada (rama `gpu-pass`); por qué un bundle copiado encima no carga; medido en el teléfono (78 tiles, 13 ms); notas para la fusión |
| 15 | [15-kernel-cache-y-presentacion.md](15-kernel-cache-y-presentacion.md) | Kernel: parches 0339-0342 (limpieza de caché por cuenta, cola de presentación, TLB, caché de BOs); `SwapEnd` no presentaba en su hilo |
| 16 | [16-planificador-e-hilos.md](16-planificador-e-hilos.md) | Planificador, hilos y caché de los A73: topología en XNU, dónde corren los hilos de un frame, la L2 vaciada antes de cada WFI (0344, 0351), despertares de hilos del kernel |
| 17 | [17-gpu-escalado-termica-ddr.md](17-gpu-escalado-termica-ddr.md) | GPU: parches 0343 y 0345-0348 (relojes y temperaturas, cambio de nivel en caliente, gobernador, voto del DDR, clock gating); DDR y temperaturas medidas frente a Android |
| 18 | [18-display-scanout-directo.md](18-display-scanout-directo.md) | Display: qué hace el port con el DPU y scanout directo con el escalador del VIG0 (en el repo, 0349, 0350 y las correcciones de 0352; el informe llama 0347 y 0348 a los dos primeros). **En curso** |
| 19 | [19-como-dibuja-ios.md](19-como-dibuja-ios.md) | Cómo dibuja iOS: el camino de un frame, el contrato de CoreAnimation con Metal, no conformidades del driver y diagnóstico de los fallos visibles. **En curso** |
| — | [../../GPU-ROADMAP.md](../../GPU-ROADMAP.md) | Gráficos: estado y plan, en inglés |
| — | [../../tools/perf/README.md](../../tools/perf/README.md) | Herramientas de medición: perfil de hilos, contadores del driver, arnés A/B, frecuencia de la GPU, capturas |
| — | [../OPERACION.md](../OPERACION.md) | Runbook: herramientas de la Mac, acceso, ciclo CI → flash → ensayo → ring, fallos; §9 gráficos (driver, medición, boot-args y sysctls) |
| — | [../angel.cmdline](../angel.cmdline) · [../bootargs.py](../bootargs.py) · [../repack-boot.py](../repack-boot.py) | Boot-args de expG, su extractor y el empaquetador de imágenes |

## Anexos en el repo (`anexos/`)

- `sweet_usb_design_sketch.c`: boceto del driver corregido (pseudo-C, no compila).
- `usbsim_dp.py`: modelo DES de la máquina de estados de 0330 con controlador adversarial.
- `usbsim.py`, `storm.py`: modelo de eventos discretos de la ruta TX vieja (comprobación de coherencia).
- `replay-parches-apply.log`: replay del CI (322 parches aplican en orden).

## Material pesado (fuera de git): `~/sapphire-angel/research/`

| Carpeta | Contenido |
|---|---|
| `auditoria-sweet_usb/` | Mach-O de expG reconstruido (`kern/`), `ud_thread.dis`, fuentes de referencia fijadas (`ref/`), árbol de replay, modelos (`sim/`), `0329-borrador-descartado.patch`, transcripción del agente |
| `investigacion-dwc3-abl/` | Transcripción del agente de 02 (`.jsonl`), extracción buscable `tr.txt` + `idx.txt` |
| `fuente-reconstruida/` | `sweet_usb.post-0328.c` (lo que corre en expG) y `sweet_usb.con-0329.c` |
| `parche-0330/` | Árbol de trabajo de 0330 y transcripción del agente |
| `auditoria-docs/` | Assets de la release v0.1.8 (kernel, recovery zip con `sapphire.sh` no versionado, overlay) — **`ovl/` contiene un hash de contraseña: no publicar** |
| `logs-telefono/` | Datos de 03: ring-logs, volcados USBDIAG de E2, carpetas por serie (`e3-n3-*`, `e4-*`, `e5-*`, `e6-*`, `carga-dp2-*`, `cpu-0334-*`), sesión 2323 |
| `../backups/` | `boot_a-expG-…img` (base de `repack-boot.py`), `particiones-20261114-0110/` (particiones y GPT), rings (`ring-R1`, `ring-E2R1`, `ring-E5`, `ring-panic2` = e3-n3 ensayo 1) |
| `metal/rebuild/` | Toolchain, SDK, Mesa, árboles del driver (`hakios-upstream` con las ramas `cpu-draw`, `gpu-pass`, `opcional-puerto`; worktrees `wt-cpu`, `wt-gpu`; `hakios-angel`), `receta.sh`, `build-bundle.sh`, bundles en `out/` (`propio`, `propio-args`, `cpu-A-wip`, `gpu-G*`, `merge-1`…), `gpu-tools/` (prueba de firma `cs-test`, `driver-en-uso.sh`) (08, 13, 14) |
| `metal/medicion/` | Copias de trabajo de `tools/perf`, ensayos A/B (`ab/`), capturas (`shots/`), crash logs (`crash/`) (03 M1-M10) |
| `metal/binario-vs-fuente/` | Volcados del binario heredado y comparador función a función (08) |
| `metal/auditoria-userland/` | `framecount`, desensamblado y caché de stages del teléfono (10) |
| `metal/kernel-gpu/` | Fuentes reconstruidas del kernel gráfico, referencias fijadas y borradores de 0336-0342 (09, 15) |
| `metal/relojes/` | DT de Android, referencias de stock (kgsl, gpucc, TSENS), `gxfreq`, árboles `xnu-serie`/`xnu-0342`, lecturas del teléfono, borradores de 0337 y 0343-0348 (11, 17) |
| `metal/hilos/` | Datos de planificación y caché (`datos/`), herramientas, árboles `xnu-0342`/`xnu-0344`, 0344 y **0351** (16) |
| `metal/display/` | Referencias del DPU (Linux, SDE, SDM), lecturas del teléfono, borradores del scanout (18) |
| `metal/ios-graficos/` | Material extraído de iOS 20H392 (fuera de git), no conformidades del driver, bibliografía (19) |
| `metal/escena/` | Clones de los proyectos con drivers Metal no-Apple (12) |
| `metal/android/` | Lecturas de Android en este teléfono: topología, temperaturas (03 M8) |
| `metal/hakios-xnu-kernel/`, `metal/hakios-metal/`, `metal/hakios-sm7325/` | Clon de HackiOS con el remoto del fork de Angel; copia de `hakios-metal`; árbol de HackiOS para otro SoC |

## Gráficos: siguiente trabajo

Decisiones del proyecto: el driver Metal parte del upstream de HackiOS con soporte A610 propio y nada del Metal
heredado es base (08); nada de atajos sobre CoreAnimation: se busca qué exige CoreAnimation de un driver Metal
correcto y se arregla en el driver o en el kernel (19); Metal sobre Vulkan (Turnip) está descartado (12 §10). Cómo
compilar, instalar, comprobar y medir: [../OPERACION.md](../OPERACION.md) §9. Objetivo: 120 Hz en el panel (8,33 ms
por frame).

1. **Ritmo del frame:** 12,5 ms de GPU (8,3 dibujando + 4,15 de copia al panel) y ~13,7 ms de CPU del hilo de render
   por frame, por encima de los 8,33 ms de 120 Hz y por debajo de dos refrescos (03 M11, n=1). Quitar la copia (punto
   4), bajar los 8,3 ms de GPU (`metal_fps=passes`/`timeline`, elección GMEM/sysmem, 14 §8) y el coste de QuartzCore y
   del driver en el hilo de render; medir cómo se encadenan con n≥3.
2. **Incidencia con el gobernador y la GPU a 1260 MHz** (SIGBUS de SpringBoard, fondo con bloques descolocados; n=1,
   sin causa; 03 M10): repetir con cada factor por separado (1260 MHz fijos, gobernador, `kern.sweet_idle_cache=0`).
3. **0351**, el arreglo definitivo de la L2 (nada antes de WFI por defecto y el límite correcto en los bucles por
   set/way): en la serie (run de CI 43635044868 con 0351 y 0352), sin probar en el teléfono (16 §5.1).
4. **Scanout directo** (0350 con las correcciones de 0352, `kern.sweet_fb_scanout`; `kern.sweet_fb_flush_taken`):
   quita los 4,15 ms de copia por frame; en la serie, sin probar en el teléfono (18).
5. **Calor:** iOS está ~20 °C por encima de Android en reposo (17 §4.4); los hilos del kernel que sondean despiertan a
   los A73 3600-4100 veces por segundo (16 §1 punto 7, §5.2); `CalendarWidgetExtension` gira al 57-100 % de un núcleo
   (03 M5; 17 §4.2). Después, el voto del DDR (0347) y el clock gating (0348), sin probar en el teléfono (17 §11).
6. **Destellos de colores al abrir apps:** sin captura ni traza; hipótesis y protocolo en 19 §4.2.
7. **Conformidad del driver con Metal** (trabajo omitido sin error, variantes sustituidas, `waitUntilScheduled`
   prematuro…): 19 §2.9.
8. **Radios:** probar las imágenes `noradio` y de control (03 M5).

## Pendientes

- 07: H5 (tráfico USB) y H6 (compilador del kernel) sin medir.
- USB: prueba larga (horas, reconexión del cable, reposo y despertar); afinar `qdrop` bajo TCP intenso;
  α frente a β en la ruta vieja nunca se discriminó (sin interés práctico con 0330).
- Escritura cruda en UFS con `ufsrw=1` tras 0334 (sin probar).
- Confirmar a la vista que con cmdline ≤ 575 vuelve la imagen de arranque (03 E6).
- Fuentes primarias de ABL (agente de 02, reanudable desde el 19 nov, 11:00): `PreparePlatformHardware`
  y qué toca el deinit de `UsbConfigDxe` en ExitBootServices.
- `xbl_a` ≠ `xbl_b` (iOS arranca con el XBL del slot a): variable sin controlar.
- Seguridad: lo pendiente de [../seguridad.md](../seguridad.md) (`.supdate` sin firma, shell 2323).
