# QEMU — investigación para emular/depurar sin hardware

Meta: poder iterar el kernel/shim **sin flashear el teléfono cada vez** (ciclo lento
y arriesgado), idealmente con gdb. Resumen: en este Mac (Intel/x86_64, macOS 26)
**no hubo un QEMU usable listo**, y aun con uno, **QEMU no modela el SoC SM6225**,
así que la emulación es parcial. Camino recomendado al final.

## Qué se probó (y por qué falló aquí)
| Vía | Resultado |
|---|---|
| `brew install qemu` | **falla**: en Intel/macOS 26 cae a compilar desde fuente y `autoreconf`/deps rompen. |
| QEMU del **Android SDK** (`emulator/`) | inservible: faltan dylibs, es el fork **ranchu**, no un `qemu-system-aarch64` genérico. |
| **UTM** | trae QEMU como **librería (framework)**, no un binario `qemu-system-aarch64` invocable desde CLI con nuestros args. |

## Límite de fondo (aunque tengas QEMU)
QEMU `virt`/`sbsa` **no es sapphire**: no hay DWC3 de Qualcomm, ni la UFS/PHY, ni el
GIC/mapeo de este SoC. Por eso **el USB (nuestro objetivo) no se puede probar en QEMU**
— justo los periféricos que nos importan no están modelados. QEMU sólo serviría para:
- validar el **handoff del shim** y la entrada temprana de XNU (hasta donde no toque HW),
- correr lógica aislada (parsers, ADT, formatos) fuera del kernel.

## Camino recomendado
1. **Linux box / VM** (o CI) con `apt install qemu-system-arm gdb-multiarch` — ahí sí
   hay binario genérico. Útil para el handoff del shim + entrada de XNU con `-s -S` + gdb.
   No para USB.
2. Para **el USB** no hay atajo de emulación: el ciclo real es
   `editar → compilar → flash boot_a → set_active a → reboot → leer ring-log`.
   Acelerarlo: ccache (rebuild del kernel en segundos) + el **ring-log persistente**
   como “printf debugging” fiable (no depende del USB, se lee desde OrangeFox).
3. Opción a futuro: compilar `qemu-system-aarch64` a mano en el Mac (sin brew) o usar
   un contenedor Linux (Docker/Lima) con QEMU para la parte de arranque. Baja prioridad
   frente a arreglar el USB real.

## Conclusión
QEMU **no desbloquea el trabajo de USB** (el periférico no está modelado). La mejor
“máquina de depurar” que tenemos para el USB es el **ring-log persistente** + ccache.
Si se quiere QEMU para el handoff del shim, hacerlo en Linux/CI, no en este Mac Intel.
