# installer/recovery (restaurado desde la release)

Hasta el 14 nov 2026 este directorio no estaba en git: la regla `recovery/` del `.gitignore` (pensada para
volcados de la partición recovery en la raíz) también excluía `installer/recovery/`. Ahora la regla es
`/recovery/` y estos archivos se versionan.

Los scripts se copiaron byte a byte desde el asset `sapphire-recovery.zip` de la release v0.1.8-test
del repo original (sha256 del zip: `d9ec53d78824299a5ad1801b75fb844b063f52530b5597807a7bb0caadd8dd49`).
Ese zip trae `sapphire/VERSION` = `0.1.7`.

| Archivo | Ruta en el zip | sha256 |
|---|---|---|
| `sapphire.sh` | `sapphire/sapphire.sh` | `2d2c2ff932c688b9b5440b40c8538401a732e7cc9dbad3f0d8513c778c8c29b5` |
| `firstboot.sh` | `sapphire/firstboot.sh` | `36b8cd3caa8f004ca1aa279e6619d39614c3652344a04daa18dae158e455f169` |
| `update-binary` | `META-INF/com/google/android/update-binary` | `14bc7b53906c67eb2f89588f6c078523c45240aebb512bce648ff8e5576a03bb` |
| `updater-script` | `META-INF/com/google/android/updater-script` | `1c29012f6d7bc4dd871f31eafa9bbb50514f35630bc12c7d6666159290a08a68` |

Antes de añadirlos se revisó que no contienen hashes, claves, seriales, SSIDs ni rutas personales. La
dirección Bluetooth no está en ellos: `sapphire.sh` la calcula en el teléfono a partir de `ro.serialno`.

Lo demás del zip ya está en el repo y es idéntico: `sapphire/recipes/` = `installer/recipes/`,
`sapphire/ios/sapphire-update.sh` y `sapphire-appwatch.sh` = `userland/update/`.

**Falta todavía.** `installer/README.md` cita `screen.c`, `loop.c`, `recv.c`, `untar.c`, `mkscreen.py` y
`build-zip.sh`. El zip solo trae sus binarios estáticos aarch64 (`sapphire/bin/*`) y los datos de pantalla
(`sapphire/screen/*`), no el código fuente. Por eso no se pueden reconstruir aquí y
`bash recovery/build-zip.sh` sigue sin poder ejecutarse. `installer/update/make-update.sh` sí usa
`recovery/firstboot.sh`, que ahora está.
