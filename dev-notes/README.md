# dev-notes — ios-sapphire (fork giovannipodesta)

Notas de desarrollo del port iOS 16.7.16 (userland del iPhone10,3 + XNU) sobre el
**Redmi Note 13 4G "sapphire"** (Qualcomm SM6225 / Snapdragon 685). Criterio del fork: todo
compilado desde fuente, sin reusar binarios de Angel, y ninguna afirmación sin medición o fuente
primaria. Las reglas para agentes están en [../AGENTS.md](../AGENTS.md).

| Doc | Qué cubre |
|---|---|
| [OPERACION.md](OPERACION.md) | **Empieza aquí.** El ciclo completo: herramientas USB de la Mac, particiones y respaldos, acceso a iOS (red USB, SSH, 2323), kernel de CI → empaquetado → flasheo → ensayos → ring, diagnóstico USB, fallos, y gráficos (driver Metal, mediciones, boot-args y sysctls de la GPU y la pantalla). |
| [investigacion/INDICE.md](investigacion/INDICE.md) | Estado actual, mediciones (03), auditorías (01, 04, 09), fuentes primarias (02), parches del USB y del UFS (05, 06), gráficos (07-19) y el trabajo siguiente. |
| [../GPU-ROADMAP.md](../GPU-ROADMAP.md) | Gráficos: cómo llega un frame al panel, lo medido y el plan (en inglés). |
| [continuar-en-otra-maquina.md](continuar-en-otra-maquina.md) | Montar el entorno en otra máquina: qué instalar y qué descargar (IPSW, KDK, zig, DXB). |
| [build-recipes.md](build-recipes.md) | Compilar en local: kernel XNU (DXB), shim (zig), ADT y payload, imagen de arranque. |
| [seguridad.md](seguridad.md) | Amenazas (`.supdate` sin firma, shell 2323, `wifi_pass`, datos en logs, descargas del instalador) y mitigaciones propuestas. |
| [release-notes-corrections.md](release-notes-corrections.md) | Texto propuesto para las notas de la release v0.1.8-test. |
| [qemu-findings.md](qemu-findings.md) | QEMU para depurar sin hardware: qué funciona y qué no. |
| [gps-plan.md](gps-plan.md) | Plan GPS (QMI LOC 0x10 sobre QRTR). |
| [coarseloc-outofscope.md](coarseloc-outofscope.md) | Fuera de alcance: posición aproximada por celda o Wi-Fi. |

Herramientas de este directorio: `fetch-ci-kernel.sh` (baja y verifica un kernel de CI),
`repack-boot.py` (mete un kernel en una `boot_a` buena), `bootargs.py` (lee los boot-args de una
imagen), `read-ring.py` (parsea el ring del log), `shim-build-mac.sh` (shim con zig),
`angel.cmdline` (boot-args de la imagen base). Su uso está en OPERACION.md.

## Parches propios (`xnu/patches/`)

| Parche | Qué hace |
|---|---|
| 0327 | Reclama por HWO en cada poll (un TRB por endpoint). Consume dos veces la finalización y mata el enlace bajo carga (investigacion/01). Solo actúa con la ruta antigua (`sweetusb_dp=0`). |
| 0328 | Limpia SUSPHY/ENBLSLPM y sube el timeout de ep0. No basta para enumerar en arranque normal (investigacion/03, E1). |
| 0329 | Diagnóstico de solo lectura de PHY/QSCRATCH/GCC/DWC3 (`SWEET USBDIAG`) y gate `sweetusb_reclaim`. |
| 0330 | Ruta de datos v2 (`sweetusb_dp=2`): un dueño por endpoint, sin reclamar por HWO, sin `printf`, DMA no cacheable (investigacion/05). |
| 0331 | UTMI como reloj PIPE (`sweetusb_utmipipe=1`, como `dwc3_qcom_select_utmi_clk` de Linux). |
| 0332, 0333 | 0331 y 0330 activos por defecto, desactivables por boot-arg; el valor `dp=2` se elige en `gadget_start`. |
| 0334 | E/S cruda de `sweet_ufs` sin `memcpy` del kernel a memoria de usuario (investigacion/06). |
| 0335 | Solo comentarios: lo que dicen el código y las mediciones. |
| 0336 | Diagnóstico de solo lectura de la GPU y de la presentación (`kern.sweet_fb_diag`, `kern.sweet_gpu_diag`) (investigacion/09). |
| 0337 | `gpu_vco2=1`: el PLL de la GPU como Android, `gpu_mhz` pasa a ser la frecuencia del núcleo (investigacion/11). |
| 0338 | Experimento de retener `SwapEnd` (`kern.sweet_fb_hold_ms`); sin efecto en este teléfono (investigacion/15 §0.1). |
| 0339-0342 | Limpieza de caché de superficies por cuenta, cola de presentación, TLB del SMMU sin invalidar al mapear, caché de buffers (investigacion/15). |
| 0343, 0345-0347 | Relojes, DDR y temperaturas (solo lectura), cambio de nivel de la GPU en caliente, gobernador, voto del DDR (investigacion/17). |
| 0344 | Mantenimiento de caché antes de WFI conmutable (`kern.sweet_idle_cache`): XNU vaciaba la L2 del cluster A73 en cada reposo (investigacion/16). |
| 0348 | Clock gating por hardware de la GPU (investigacion/17). |
| 0349, 0350 | Diagnóstico del DPU y scanout directo con el escalador del VIG0 (investigacion/18). |
| 0351 | Nada antes de WFI por defecto y límite de niveles correcto en el mantenimiento por set/way (investigacion/16). |
| 0352 | Correcciones del scanout directo y flips tomados por `CTL_FLUSH` (`kern.sweet_fb_flush_taken`). |

Los conmutadores de 0336-0352 y su valor por defecto están en OPERACION.md §9.6. 0351 y 0352 están sin probar en el
teléfono.

## Estado

Medido en el teléfono del fork (datos en [investigacion/03](investigacion/03-experimentos-y-datos.md)):
- iOS arranca desde fuente (kernel de CI + shim zig) hasta la pantalla de bloqueo.
- El USB de iOS enumera en arranque normal (`set_active a` + reboot): 8/8 arranques con 0331-0333,
  0/3 sin ellos.
- Bajo carga, la ruta 0330 pasa 20 × 30 MB con SHA-256 iguales, sin rechazos de Start Transfer
  (n=1 arranque).
- La E/S cruda de `sweet_ufs` funciona con 0334 (30/30 lecturas del ring, EINVAL en offsets desalineados).
- CoreAnimation dibuja en la GPU por el driver Metal compilado desde fuente (bundle `merge-1`): 44-48 command buffers
  por segundo en el home (n=1-2); por frame, 8,3 ms de GPU dibujando más 4,15 ms de copia al panel y ~13,7 ms de CPU
  del hilo de render (n=1) (investigacion/03 M10-M11).
- Siguiente: [investigacion/INDICE.md](investigacion/INDICE.md), "Gráficos: siguiente trabajo".
