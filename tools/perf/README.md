# Herramientas de medición en el teléfono

Se compilan en la Mac con el clang de CommandLineTools y un SDK de iPhoneOS (p. ej. `theos/sdks`,
`iPhoneOS16.5.sdk`), y se firman ad hoc:

```sh
SDK=~/sapphire-angel/toolchain/sdks/iPhoneOS16.5.sdk
clang -target arm64-apple-ios16.0 -isysroot $SDK -O2 -o psamp psamp.c && codesign -f -s - psamp
scp psamp sapphire:/var/root/
```

| Herramienta | Qué mide |
|---|---|
| `thrtop PID SEGUNDOS` | CPU (usuario y sistema) por hilo de un proceso durante el intervalo |
| `psamp PID SEGUNDOS NOMBRE_HILO SALIDA [PERIODO_US]` | Pila (pc + marcos por frame pointer) de un hilo cada 0,5 ms, más la lista de imágenes del proceso |
| `symb.py SALIDA_PSAMP BINARIO_HakiosMetal` | En la Mac: perfil por imagen, self e inclusivo, simbolizando HakiosMetal con `nm` |

La carga reproducible es `userland/tests/swipetest.sh N` (deslizamientos del home y Centro de Control
con `hidtouch`).
