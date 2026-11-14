# Correcciones a las notas de la release v0.1.8-test (texto propuesto)

Las notas de la release están en GitHub (`Angelpro09xd/ios-sapphire`, tag `v0.1.8-test`) y este fork no
puede editarlas. Aquí está el texto corregido, listo para pegar si se publica una release desde el fork o
se propone al autor original. Las notas están en inglés, así que el texto propuesto también.

Fuentes: [investigacion/04](investigacion/04-auditoria-documentacion-heredada.md) (auditoría, con los
assets de la release descargados en solo lectura), [investigacion/03](investigacion/03-experimentos-y-datos.md)
(mediciones del 13-14 nov), el código del instalador (`installer/`) y `git log`.

## Qué cambia y por qué

| Afirmación de la release | Corrección | Evidencia |
|---|---|---|
| "The `mobile` and `root` accounts have no password" | `root` está bloqueada (`!`), pero `mobile` tiene un hash `$6$` real en `/var/jb/etc/spwd.db`, que es lo único que lee libiosexec | 04 §2; `installer/overlay/scrub.py` solo limpiaba `master.passwd` |
| "if you use SSH … set one with `passwd`" | El sshd de la release no tiene job de launchd, ni claves de host, ni `authorized_keys`: no arranca. `PermitRootLogin yes`, `UsePAM yes` | 04 §2; medido el 13 nov (`acceso-al-telefono.md`) |
| (no lo dice) | Shell root **sin autenticación** en `192.168.7.2:2323` | `installer/recipes/launchd/org.sapphire.usbshell.plist` |
| (no lo dice) | Cualquier `*.supdate` del inbox de `iosroot` se ejecuta como root en cada arranque, sin firma | 04 §2 (`sapphire-update.sh` del zip) |
| Fila `SHA256SUMS` en la tabla de archivos | Ese asset no existe | lista de assets de la release |
| `sapphire-kernel.img` = "Apple's open-source XNU with Sapphire's patches" | Es un build local (WSL, clang 18 parcheado + iig-lite, `tools/xnu-linux`), con firma `Fri Nov 13 17:37:11 CET 2026`: 7 min antes del commit 1cdcbfb (17:44:34) que añade 0323-0325 y 51 min antes del tag (be9c5aa, 18:28:09). Se reempaquetó sobre un `BASE.img` local que no está en el repo. No se puede reproducir exactamente desde el tag | 04 resumen punto 4; `git log` |
| "No USB link to the PC while iOS runs from the phone's storage (only when booted with `fastboot boot`)" | Cierto para 0.1.8. Medido: el USB enumera saliendo de fastboot (`continue`) y no en arranque normal. Arreglado en el fork con 0331-0333, que **no** están en 0.1.8 | 03 E1, E3, E4, E6 |
| "Wi-Fi works seconds after boot", "Bluetooth … headphones tested", "Mobile data on other carriers", "Battery percentage from real charge counting", "Real Metal on the GPU" | Sin medición registrada: `NOTES.md` acaba el 2026-11-08 y solo los commits lo respaldan. La última entrada sobre BT dice "to be tried with headphones" | 04 §3 |

## Texto propuesto (inglés)

### Sustituye a la viñeta de contraseñas de "Important"

> - **Accounts:** `root` is locked, but this release's `/var/jb/etc/spwd.db` still carries a password hash
>   for `mobile` from the phone the overlay was taken from, so `mobile` is *not* passwordless. SSH is not
>   running out of the box (no launchd job, no host keys, no `authorized_keys`).
> - **Root shell on USB:** while iOS runs, an unauthenticated root shell listens on `192.168.7.2:2323`
>   (USB network). Do not plug the phone into computers you do not trust.
> - **Updates run as root:** any `*.supdate` file placed in the update inbox of `iosroot` is run as root at
>   the next boot. Its only check is a sha256 in its own header; it is not signed.

### Sustituye a la línea de USB de "Known issues"

> - No USB link to the PC when iOS boots normally from its boot slot; it works when iOS is started from
>   fastboot (`fastboot boot` or `fastboot continue`). (Fixed after 0.1.8 by patches 0331-0333 in the fork
>   giovannipodesta; not part of this release.)

### Sustituye a la tabla de archivos (quitar la fila `SHA256SUMS`)

> There is no `SHA256SUMS` file. The sha256 of each asset, as GitHub reports it:
>
> | File | sha256 |
> |---|---|
> | SapphireInstaller.exe | `10b13ddafe8532e656b8f2aadd66cf58290ba6b38291a664d53d4225f03bf3cd` |
> | sapphire-recovery.zip | `d9ec53d78824299a5ad1801b75fb844b063f52530b5597807a7bb0caadd8dd49` |
> | sapphire-overlay.tar.gz | `9f2e85a697c7590499a21a5eaab8e115fda13cfa9f4a9444ddb55b571386a056` |
> | sapphire-kernel.img | `2c7ed6ff97f4d784dab3562e562021be93dfed5776c0ba2db2e5d114c811dd0c` |
> | SapphireDualBoot.apk | `5c16efe4a29470a06e8b633ac82824adb3f88831c93748c09f885b613bb4a9f1` |
> | sapphire-update-0.1.8.supdate | `1dbc42d0f6919f3d447c722dd72ed9a301585ece65d9f19b51491d0502e020d4` |
> | sapphire-install.sh | `19f63564b84d6630814c2ed96ecb961a0b6263b3ec5c94d9f9a101bd5c4e45e8` |
> | Sapphire-v0.1.8-test.zip | `e3c5c16e7c3ee51103bd5f957f22d5d70efa27184e3484e6fba3bfef60c74ced` |
> | Sapphire-v0.1.8-test-linux.zip | `4475bc0b9d748c854d9c3d9b5335c69a134361d5f97d447130c7d5a2225eeeb6` |
>
> `sapphire-kernel.img` is a local build (Linux/WSL toolchain in `tools/xnu-linux`, LLVM clang 18 with
> Apple's builtins, iig-lite) made on 2026-11-13 at 17:37 CET, minutes before the commit that adds patches
> 0323-0325 (1cdcbfb) and before the tag (be9c5aa). It was repacked over a local base image that is not in
> the repository, so it cannot be rebuilt bit for bit from the tag.

(Los sha256 son los `digest` que da la API de GitHub para cada asset, consultados el 2026-11-14.)

### Añadir debajo de "What's new in 0.1.8" y de "What's new in 0.1.7"

> These items are based on the author's commits; there is no recorded measurement for: Wi-Fi seconds after
> boot, Bluetooth with headphones, mobile data on other carriers, battery charge counting and Metal on the
> GPU.
