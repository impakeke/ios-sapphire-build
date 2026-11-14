# El driver Metal del port: hakios-metal sobre el Adreno 610

`HakiosMetal.bundle` es el driver Metal que carga backboardd (`sweetmetal=2`): CoreAnimation dibuja con él
directamente en la GPU, a través del servicio `SapphireGPU` del kernel. Se construye entero desde fuente:

- **Base:** [oosexgang/hakios-xnu-kernel](https://github.com/oosexgang/hakios-xnu-kernel) en el commit `63fc2b4`
  (hakios-metal y su plug-in `userland/src/HakiosMetalCA.m`, licencia MIT).
- **Serie del port:** `patches/`, 29 parches que se aplican en orden con `git apply` sobre ese commit y dan
  exactamente el árbol del que sale el binario del instalador (`4e0a51a` en el árbol de trabajo). Contienen el
  soporte del A610 escrito desde Mesa 25.0.7 y el kernel del port, la lectura de opciones de
  `/var/tmp/metal.args`, el coste de CPU por draw (estado guardado por programa, sin asignaciones en el camino
  de draw) y las pasadas en tiles (grupos de draw state, bins de turnip, elección de tiles o sysmem por contenido).
  El diseño y las mediciones están en `dev-notes/investigacion/` (08, 10, 13, 14).
- **Compilador de shaders:** Mesa 25.0.7 (ir3) enlazado estáticamente, con los parches de `userland/mesa/`.

## Construir

`build/receta.sh` monta de cero el entorno (clang y lld 18.1.8, SDK de iPhoneOS 16.5, Mesa) y `build/build-bundle.sh`
enlaza el bundle; `build/env.sh` fija las rutas. En una Mac sin Xcode tarda unos minutos. La receta paso a paso
está en `dev-notes/investigacion/08-hakiosmetal-binario-vs-fuente.md`.

```sh
git clone https://github.com/oosexgang/hakios-xnu-kernel && cd hakios-xnu-kernel && git checkout 63fc2b4
for p in <repo>/metal/hakios-metal/patches/*.patch; do git apply --index "$p"; done
SRC=$PWD <repo>/metal/hakios-metal/build/build-bundle.sh out/HakiosMetal
```

Los tests de host (`make -C hakios-metal test`, GPU simulada) pasan con las constantes del A635 y del A610.

## Instalar

El instalador copia `installer/update/files/System/Library/Extensions/HakiosMetal.bundle/`. En un teléfono en marcha
se instala **por renombrado** y se comprueba que el driver está cargado: `tools/perf/README.md`.
