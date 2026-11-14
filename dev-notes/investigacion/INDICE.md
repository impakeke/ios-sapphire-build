# Investigación de iOS en sapphire — índice

Investigación detrás de los arreglos de USB y UFS del fork (parches 0329-0334). Todo lo que hay aquí es
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
5. **Siguiente:** descartar la CPU como causa del stutter (07) y después auditar Metal.

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

## Pendientes

- Plan 07 (CPU y stutter); después Metal (`HakiosMetal.bundle` está en el repo sin fuente, 04).
- USB: prueba larga (horas, reconexión del cable, reposo y despertar); afinar `qdrop` bajo TCP intenso;
  α frente a β en la ruta vieja nunca se discriminó (sin interés práctico con 0330).
- Escritura cruda en UFS con `ufsrw=1` tras 0334 (sin probar).
- Confirmar a la vista que con cmdline ≤ 575 vuelve la imagen de arranque (03 E6).
- Fuentes primarias de ABL (agente de 02, reanudable desde el 19 nov, 11:00): `PreparePlatformHardware`
  y qué toca el deinit de `UsbConfigDxe` en ExitBootServices.
- `xbl_a` ≠ `xbl_b` (iOS arranca con el XBL del slot a): variable sin controlar.
- Seguridad: lo pendiente de [../seguridad.md](../seguridad.md) (`.supdate` sin firma, shell 2323).
