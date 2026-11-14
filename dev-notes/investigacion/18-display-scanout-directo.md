# 18 — Display: scanout directo de la superficie de iOS con el escalador del DPU (2026-11-14)

- **Autor:** agente Claude Opus 5.5, esfuerzo máximo.
- **Alcance:** la presentación del kernel frente al DPU (MDSS) del SM6225: qué hace hoy el port con el plano, diseño
  del scanout directo de la superficie de 750×1624 por el VIG0 con su escalador QSEED3LITE, y dos parches al final
  de la serie: 0347 (diagnóstico, solo lectura) y 0348 (scanout directo, apagado por defecto).
- **Estado:** en redacción.

## Convenciones

`F`, `S` y `G` son líneas de `SweetFramebuffer.cpp`, `SweetSurface.cpp` y `SapphireGpu.cpp` del árbol a 0342
(3118, 1533+ y 4990+ líneas; sha256 `b8fee873…`, `b3b6c97d…`, `83dc20e2…`), reconstruido aplicando 0339-0342 de
`xnu/patches/` sobre `relojes/xnu-serie` (serie a 0338): coincide byte a byte con `relojes/xnu-0342`.
No son las líneas de 09 ni de 15.
