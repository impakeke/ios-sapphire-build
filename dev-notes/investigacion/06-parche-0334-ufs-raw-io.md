# 06 — Parche 0334: E/S cruda de UFS sin memcpy a memoria de usuario (2026-11-14)

**Autor:** agente Claude Opus 5.5. Revisión: sesión principal. **Bug:** panic de E5 (`03-experimentos-y-datos.md`).

## Qué es el fallo

- **Sin PAN.** Los Cortex-A53/A73 son ARMv8.0 y no tienen PAN: el parche 0081 quita `__ARM_PAN_AVAILABLE__` y `pexpert/pexpert/arm64/SWEET.h:37` lo dice expresamente ("Cortex-A53/A73 have no PAN").
- **Qué dice la ESR 0x9600004f:** EC 0x25 (data abort en EL1), WnR=1 (escritura), DFSC 0x0f (permission fault de nivel 3). El kernel escribió en una página de usuario cuya PTE era RO en ese instante.
- **La zona del log se lee del disco.** `sweet_log_ring` solo se usa para append, copy y flush; ninguna lectura se sirve desde el ring en memoria.

## Causa raíz

Rutas del replay `~/sapphire-angel/research/auditoria-sweet_usb/replay/xnu`:

1. `sweet_ufs_read`/`write` (`bsd/dev/sweet_ufs.c:667-680`) llaman a `physio(sweet_ufs_strategy, …)`.
2. `physio` (`bsd/kern/kern_physio.c:152, 175, 191, 199`) usa `B_PHYS|B_RAW`, pone `buf_setdataptr(bp, uio_curriovbase(uio))` (VA de usuario), hace `vslock` y llama a strategy en el mismo hilo.
3. `buf_map_range_internal` (`bsd/vfs/vfs_bio.c:1166-1168`) devuelve `b_datap` tal cual si el buf no tiene `B_CLUSTER`.
4. `sweet_ufs_strategy` hace `memcpy(vaddr + done, …)` (sweet_ufs.c:567 en lectura, 575 en escritura), un acceso directo a la VA de usuario fuera de copyio.
5. `handle_kernel_abort` (`osfmk/arm64/sleh.c:1588`) solo recupera faults de copyio (`recover`). En otro caso usa `kernel_map`, `arm_fast_fault` y `vm_fault` fallan, y termina en `panic "Kernel data abort."` (1713).
6. **Por qué es intermitente.** El pmap emula el bit de modificado poniendo páginas escribibles como RO + `PP_ATTR_MODFAULT` (`osfmk/arm/pmap/pmap.c:5787-5801`, `phys_attribute_clear` 6974-7001). Con `copyout`, `arm_fast_fault` lo resuelve sobre el pmap de usuario; con `memcpy`, es un panic. FAR = x0 está alineado a página, así que falló la primera escritura de esa página.
   - No determinado: qué evento dejó la PTE en RO esa vez, si `vslock` cablea RW (`bsd/vm/vm_unix.c:546-552`).

## Arreglo

- **`sweet_ufs_rw(uio, rd)` reemplaza a physio:**
  - trozos de hasta `BOUNCE_SIZE` (1 MiB);
  - `ufs_read_blocks`/`ufs_write_blocks` bajo `sweet_ufs_lock`, con leer-fusionar-escribir para bloques parciales de 4 KiB;
  - un buffer `kalloc_data` como intermedio;
  - `uiomove()` con el mutex **liberado**, porque un fault puede hacer page-in desde este mismo disco;
  - soporta varios iovecs y `UIO_SYSSPACE`.
- **Validaciones nuevas:**
  - `ENXIO` si el dispositivo no está listo, `EROFS` si no es escribible;
  - `EINVAL` si el offset no está alineado a `secsize` (antes physio lo redondeaba en silencio);
  - EOF al final de la partición;
  - una escritura que no cabe se rechaza entera.
- **Defensa en strategy:** un buf con `B_PHYS` y sin `B_CLUSTER` devuelve `ENOTSUP`. `B_PHYS|B_CLUSTER` (E/S directa de cluster, `vfs_cluster.c:1385-1386`) sigue funcionando porque `buf_map` mapea su UPL en el kernel.
- **Sin cambios:** el camino de bloque y cluster, el log persistente y la serialización.

## Verificación

- 0329-0333 solo tocan `sweet_usb.c`.
- 0334 pasa `git apply --check` en el replay y, en orden, 0329→0334 sobre una copia; el resultado es idéntico al fichero editado.
- `clang -fsyntax-only` (Apple clang 21, `-target arm64-apple-ios16.0`, macros de kernel, cabeceras del replay): rc=0, sin avisos nuevos con `-Wextra -Wshorten-64-to-32 -Wsign-compare -Wconversion`. Se confirmó que el bloque se compila de verdad inyectando un error.
- CI: run 43570770230, compila y enlaza (kernel sha `ffcc981f…`).
- En el teléfono (03 E7): el `dd` de E5 completa 30/30 sin panic; lecturas de 4 MiB ×4 (10/10) y de 1 MiB ×64 completas; offset desalineado → EINVAL.

## Riesgos

- Errores a mitad de transferencia: write(2) devuelve -1 aunque se hayan movido datos; EFAULT como antes.
- Semántica nueva en los bordes: EOF, EINVAL por desalineación, rechazo de escrituras que no caben. fsck y newfs usan offsets alineados.
- `kalloc_data` de hasta 1 MiB (ENOMEM bajo presión de memoria). Rendimiento igual o mejor: comandos de 1 MiB frente a 64 KiB.
- Un `dd` de la zona del log puede ver una instantánea a medias, igual que antes.
- No probado en el teléfono: escritura cruda con `ufsrw=1`.
