# Investigación USB de iOS en sapphire — índice rápido

Criterio: confianza casi nula en las notas o el código anteriores (escritos con modelos más débiles).
Todo es **observación medida**, **fuente primaria citada** o **hipótesis marcada**.

## Estado en 5 líneas (2026-11-14, medido)
1. **El USB de iOS enumera en arranque normal**: 8/8 arranques con la corrección UTMI-como-reloj-PIPE
   (0331/0332/0333), frente a 0/3 sin ella. Causa: el reloj PIPE del PHY USB3 está apagado si no se pasa
   por fastboot (E2, código de ABL en 02).
2. **El enlace aguanta carga** con la ruta de datos v2 (0330, por defecto): 20×30 MB íntegros y 0 rechazos.
   La ruta vieja (0327) moría a los 192 KiB por la doble toma de HWO más el bucle de `printf`.
3. **Panic de `sweet_ufs` en E/S cruda arreglado** (0334): `memcpy` a una VA de usuario vía physio, validado (E7).
4. **Acceso**: SSH persistente solo con clave en 192.168.7.2, reinicio remoto a fastboot (`kern.sweet_reboot_mode=2`)
   y bucle de ensayos automático (`~/adb-bridge/exp-loop.sh`).
5. **Contradichas** por la evidencia: "se pierden eventos", "0327 lo cura", "toolchain roto", "`fastboot boot` brickea",
   "mobile/root sin contraseña", "parche USB probado correcto". Hipótesis propias descartadas: la de 0332 (E5) y la de PAN (06).

## Documentos
| # | Archivo | Qué es |
|---|---|---|
| 01 | [01-auditoria-sweet_usb.md](01-auditoria-sweet_usb.md) | Auditoría completa del driver: mecanismo del fallo con números de línea, 16 defectos, tabla de afirmaciones, diseño e instrumentación, experimentos |
| 02 | [02-fuentes-primarias-dwc3-abl.md](02-fuentes-primarias-dwc3-abl.md) | Fuentes primarias: Linux/U-Boot dwc3, código y binarios de ABL, PHY femto, DT de khaje, erratas |
| 03 | [03-experimentos-y-datos.md](03-experimentos-y-datos.md) | Bitácora de mediciones en el teléfono (E0, carga, E1 R/C, E2) |
| 04 | [04-auditoria-documentacion-heredada.md](04-auditoria-documentacion-heredada.md) | Auditoría del resto de docs: arranque/recovery, **seguridad** (hash en spwd.db, .supdate root sin firma, shell 2323), qué funciona, reproducibilidad, licencias, correcciones y riesgos |
| 05 | [05-parche-0330-ruta-de-datos.md](05-parche-0330-ruta-de-datos.md) | Parche 0330: ruta de datos v2 tras `sweetusb_dp=2` — diseño, invariantes, verificación, riesgos, boot-args del A/B |
| 06 | [06-parche-0334-ufs-raw-io.md](06-parche-0334-ufs-raw-io.md) | Parche 0334: panic de `sweet_ufs` en E/S cruda (memcpy a VA de usuario vía physio; no es PAN), arreglo con `uiomove` |
| 07 | [07-plan-cpu-stutter.md](07-plan-cpu-stutter.md) | **Siguiente sesión**: plan para descartar CPU como causa del stutter antes de Metal (hipótesis H1-H6 y protocolo) |
| — | [../acceso-al-telefono.md](../acceso-al-telefono.md) | Receta para entrar: `fastboot continue`, 192.168.7.x, `nc 2323`, `ssh sapphire` |
| — | [../angel.cmdline](../angel.cmdline) · [../bootargs.py](../bootargs.py) | Boot-args reales de expG y el extractor |

## Anexos en el repo (`anexos/`)
- `sweet_usb_design_sketch.c`: boceto del driver corregido (pseudo-C, no compila).
- `usbsim_dp.py`: modelo DES de la máquina de estados del 0330 con controlador adversarial.
- `usbsim.py`, `storm.py`: modelo de eventos discretos de la ruta TX (comprobación de coherencia).
- `replay-parches-apply.log`: replay del CI (322 parches aplican en orden).

## Material pesado (fuera de git): `~/sapphire-angel/research/`
| Carpeta | Contenido |
|---|---|
| `auditoria-sweet_usb/` | Mach-O de expG reconstruido (`kern/`), `ud_thread.dis`, fuentes de referencia fijadas (`ref/`), árbol de replay, `0329-borrador-descartado.patch`, transcripción del agente |
| `investigacion-dwc3-abl/` | Transcripción del agente Fable (`.jsonl`), extracción buscable `tr.txt` + `idx.txt` |
| `fuente-reconstruida/` | `sweet_usb.post-0328.c` (lo que corre en expG) y `sweet_usb.con-0329.c` |
| `auditoria-docs/` | Assets de la release v0.1.8 descargados (kernel, recovery zip con `sapphire.sh` no versionado, overlay) — **ovl/ contiene un hash de contraseña: no publicar** |
| `logs-telefono/` | Ring-logs (13 nov malo, R1), log UDP 5140, sesión 2323, monitores de enumeración, `exp1.txt` |
| `../backups/` | `boot_a-expG-…img` (respaldo de boot_a), ring tails |

## Pendientes
- Reanudar el agente Fable de fuentes primarias (límite hasta el 19 nov, 11:00): ABL
  `PreparePlatformHardware`, el deinit de `UsbConfigDxe` en ExitBootServices y la dependencia de VBUS.
- R2/R3 y C2/C3 (n=3).
- E2 con el kernel 0329; luego la init propia del PHY y el rediseño de la ruta de datos.
