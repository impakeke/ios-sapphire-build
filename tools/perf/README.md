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

## Contadores del driver Metal y ensayos A/B

`HakiosMetal` añade el contenido de `/var/tmp/metal.args` a los boot-args que lee (`_hm_bootargs`), así que
sus opciones (`metal_fps=1`, `metal_defer=1`, `metal_gmem_off=N`…) se cambian sin tocar la imagen de arranque;
se aplican al reiniciar backboardd (`killall backboardd`). Sus líneas de diagnóstico van al stderr de
backboardd, que es `/dev/null`, y de ahí a `/dev/console`:

| Herramienta | Qué hace |
|---|---|
| `conscat SALIDA [SEGUNDOS]` | Toma la consola (`TIOCCONS` sobre un pty) y guarda lo que los procesos escriben en `/dev/console` |
| `ab-phone.sh ETIQUETA "ARGS"` | En el teléfono: escribe `metal.args` (`metal_fps=1` + ARGS), reinicia backboardd, captura la consola durante `swipetest.sh 5` |
| `ab.sh ETIQUETA "ARGS"` | En la Mac: lanza el ensayo, trae los datos y los resume |
| `ab-sum.py CONSOLA...` | Resume las líneas `fps:` de los periodos con movimiento (≥ 15 buffers/s) |

## Capturas de pantalla

`fbshot PREFIJO` (teléfono) vuelca las IOSurface de 750x1624 del doble buffer de la pantalla; `shot.sh NOMBRE`
(Mac) las trae y las convierte a PNG (`raw2png.py`); `sheet.py` hace una hoja de contacto. Con el panel dormido
no se dibuja nada y la captura es la del último frame: despertar antes con `hidtouch press 0`. Tras despertar,
el panel se apaga a los ~6 s si sigue en la pantalla de bloqueo.

`swipetest.sh` no desbloquea el teléfono en el estado actual (verificado con capturas): sus gestos actúan sobre
la pantalla de bloqueo.
