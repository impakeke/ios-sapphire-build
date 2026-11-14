# Investigación de iOS en sapphire — índice

Investigación detrás de los arreglos de USB y UFS del fork (parches 0329-0334) y del trabajo de gráficos
(parches 0336-0338, driver Metal). Todo lo que hay aquí es
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
5. **La GPU corre a 1260,00 MHz** con `gpu_vco2=1 gpu_mhz=1260` (0337; medido con `gxfreq`, 03 M4). Sin
   `gpu_vco2`, `gpu_mhz=1260` la deja a 630,00 MHz (03 M3).
6. **Dónde se va un frame** (03 M1-M2, con el binario heredado y la GPU a 630 MHz): el hilo de render de
   backboardd está saturado de CPU (84-90 %), el 46-60 % en la ruta de draw del driver Metal (~126 µs por
   draw, ~150 draws por frame), y la pasada principal tarda 20-24 ms de GPU. `metal_defer=1` sube los
   buffers por segundo un 18 %.
7. **El driver Metal se compila desde fuente en la Mac** (08): upstream de HackiOS `63fc2b4` más seis parches
   A610 propios; el bundle `propio-args` carga y pinta bien (03 M5).
8. **Siguiente:** ver "Gráficos: siguiente trabajo" abajo.

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
| 03 | [03-experimentos-y-datos.md](03-experimentos-y-datos.md) | Bitácora de mediciones en el teléfono (E0-E7 y muestreo de CPU), con tabla resumen |
| 04 | [04-auditoria-documentacion-heredada.md](04-auditoria-documentacion-heredada.md) | Auditoría del resto de docs: arranque/recovery, **seguridad** (hash en spwd.db, .supdate root sin firma, shell 2323), qué funciona, reproducibilidad, licencias, riesgos |
| 05 | [05-parche-0330-ruta-de-datos.md](05-parche-0330-ruta-de-datos.md) | Parche 0330: ruta de datos v2 — diseño, invariantes, verificación, riesgos, boot-args del A/B |
| 06 | [06-parche-0334-ufs-raw-io.md](06-parche-0334-ufs-raw-io.md) | Parche 0334: panic de `sweet_ufs` en E/S cruda (memcpy del kernel a una VA de usuario vía physio), arreglo con `uiomove` |
| 07 | [07-plan-cpu-stutter.md](07-plan-cpu-stutter.md) | Plan: descartar la CPU como causa del stutter antes de Metal (hipótesis H1-H6 y protocolo) |
| 08 | [08-hakiosmetal-binario-vs-fuente.md](08-hakiosmetal-binario-vs-fuente.md) | El binario `HakiosMetal` frente a la fuente: procedencia, auditoría de los cambios del port al A610, receta de reconstrucción y bundles propios |
| 09 | [09-auditoria-kernel-gpu.md](09-auditoria-kernel-gpu.md) | Auditoría del kernel en la ruta gráfica: buffers, submit, fences, presentación (frames pisados, copia escalada por frame, vsync), parches 0336 y 0338 |
| 10 | [10-auditoria-rendimiento-hakios-metal.md](10-auditoria-rendimiento-hakios-metal.md) | Auditoría de rendimiento del driver Metal: coste de CPU por draw, por qué la pasada principal tarda 20 ms (102 tiles, estado repetido por tile), plan por etapas |
| 11 | [11-gpu-relojes-bus-vs-android.md](11-gpu-relojes-bus-vs-android.md) | Relojes, raíles, bus y memoria de la GPU frente a Android en este teléfono; parche 0337 y su escalera |
| 12 | [12-escena-drivers-metal-alternativos.md](12-escena-drivers-metal-alternativos.md) | Otros proyectos con driver Metal sobre GPU que no es de Apple (búsqueda en curso) |
| — | [../../tools/perf/README.md](../../tools/perf/README.md) | Herramientas de medición: perfil de hilos, contadores del driver, arnés A/B, frecuencia de la GPU, capturas |
| — | [../OPERACION.md](../OPERACION.md) | Runbook: herramientas de la Mac, acceso, ciclo CI → flash → ensayo → ring, fallos |
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

## Gráficos: siguiente trabajo

Decisión del proyecto: el driver Metal parte del upstream de HackiOS con soporte A610 propio; del port heredado
solo se conserva lo que una fuente primaria justifica (08 §4). Metal sobre Vulkan (Turnip) está descartado como
base. Árbol de trabajo y bundles: `~/sapphire-angel/research/metal/rebuild/` (`receta.sh`, `patches/a610/`,
`out/`); se instalan con `medicion/bundle.sh NOMBRE` (`angel` restaura el heredado, que queda en el teléfono
como `HakiosMetal.angel`).

1. Con la GPU a 1260 MHz: medir la pasada principal y los fps con `tools/perf/ab.sh` (n≥3), vigilar la
   temperatura, y leer `kern.sweet_fb_diag` (frames pisados, intervalo real entre flips) y `kern.sweet_gpu_diag`.
2. Probar `kern.sweet_fb_hold_ms=40` (0338): si los frames pisados son frecuentes, diseñar la cola de
   presentación con contrapresión (09 P1).
3. Driver: etapas A y B de 10 §2.6 (coste de CPU por draw) y G1-G4 de 10 §3.8 (tiles, estado por tile,
   framebuffer fetch), validando con los tests de host antes del teléfono.
4. Kernel: presentación sin la copia escalada por frame (09 §4.3), caché de buffers (09 P2), voto del DDR (11).
5. Guion de carga verificado con capturas: `swipetest.sh` no desbloquea (03 M1); hace falta uno que llegue al home.
6. Radios: probar las imágenes `noradio` y de control (03 M5).

## Pendientes

- Plan 07: la parte de CPU queda respondida por 03 M1 (el límite es CPU del driver y tiempo de GPU); H5 (USB) y H6 (compilador) siguen sin medir.
- USB: prueba larga (horas, reconexión del cable, reposo y despertar); afinar `qdrop` bajo TCP intenso;
  α frente a β en la ruta vieja nunca se discriminó (sin interés práctico con 0330).
- Escritura cruda en UFS con `ufsrw=1` tras 0334 (sin probar).
- Confirmar a la vista que con cmdline ≤ 575 vuelve la imagen de arranque (03 E6).
- Fuentes primarias de ABL (agente de 02, reanudable desde el 19 nov, 11:00): `PreparePlatformHardware`
  y qué toca el deinit de `UsbConfigDxe` en ExitBootServices.
- `xbl_a` ≠ `xbl_b` (iOS arranca con el XBL del slot a): variable sin controlar.
- Seguridad: lo pendiente de [../seguridad.md](../seguridad.md) (`.supdate` sin firma, shell 2323).
