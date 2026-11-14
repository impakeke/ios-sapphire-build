# 07 — Plan: CPU y stutter antes de atacar Metal (pendiente, 2026-11-14)

**Pregunta del usuario.** El deslizamiento del home "debería" ir a 20-35 fps según Angel, pero se siente mucho peor y con tirones (stutter). El teléfono no se calienta. Antes de tocar Metal hay que descartar la CPU.

**Criterio.** Mismo método que con el USB: medir antes de suponer, n≥3 y separar observación de hipótesis.

## Lo que ya se sabe (observado, sin analizar)

- Kernel: `SWEET FB: 5 s: 0 direct frames …, 0 composed by the CPU, 131 by the GPU`, es decir ~26 fps de media en 5 s. La media no mide stutter: hace falta la **distribución del intervalo entre frames** (p50/p95/p99, frames de más de 33 ms o más de 50 ms).
- `SWEET CPUFREQ: gold perf state 8 -> 8 (2803 MHz), silver perf state 6 -> 6 (1900 MHz)` al arrancar: ¿la frecuencia queda fija o cambia después? Boot-args relevantes:
  - `cpus=8`;
  - `sweetsched=15` (¿qué hace? buscarlo en los parches);
  - `sweetfb_hz=120`;
  - `gpu_mhz=1260`;
  - `glwait=0`.
- Muestreo de 10 min (20 muestras cada 30 s) tras arrancar con 0334 (`~/sapphire-angel/research/logs-telefono/cpu-0334-*`): load de 1 min 4,8 → **1,1-2,6 en reposo** (8 núcleos); ningún proceso de usuario dominante (cfprefsd ~12 % al inicio, notifyd ~4 %). **No hay carga de fondo constante.** Falta medir *durante* el deslizamiento (picos/latencia), que es lo que importa para el stutter.
- El kernel actual (0334) sale de CI con **Xcode 16**; el expG que el usuario usaba antes, de Apple clang 21. El usuario nota el teléfono más fluido hoy, sin medición. Candidatos: el compilador, las cachés de shaders ya completas tras muchos arranques, o percepción.

## Hipótesis a discriminar

| # | Hipótesis | Qué la confirma | Qué la descarta |
|---|---|---|---|
| H1 | Los hilos de dibujo (backboardd/SpringBoard/CA render) caen en los núcleos silver o compiten con otros | tiempo en cpu silver / migraciones durante el deslizamiento; mejora fijando afinidad o cambiando `sweetsched` | no hay correlación núcleo↔frame lento |
| H2 | La frecuencia no sube o hay throttling por software (no térmico) | perf state o MHz reales durante la carga por debajo del máximo | MHz al máximo durante el stutter |
| H3 | Picos de CPU periódicos (algún hilo del kernel o daemon) roban ciclos | picos en `top` (o `kern.*` stats) alineados con los frames lentos | carga plana durante el stutter |
| H4 | Es pacing de presentación/vsync (pantalla 120 Hz, `sweetfb_hz=120`, `glwait=0`), no CPU | intervalos múltiplos de 8,3/16,7 ms con la CPU ociosa | — |
| H5 | El driver USB v2 gira hasta 50 µs por vuelta mientras hay tráfico (0330) | stutter peor con tráfico USB que sin cable | igual con y sin cable |
| H6 | Diferencia de compilador (Xcode 16 vs clang 21) en el kernel | fps/stutter distintos entre expG y 0334 con el mismo protocolo | iguales |

## Protocolo propuesto

1. **Instrumentar sin recompilar primero.** Ver qué exponen los sysctl y logs que ya existen (`SWEET FB`, `SWEET MEM`, `SWEET CPUFREQ`, `kern.sweet_*`) y si `top -l` / `ps` dan uso por núcleo. Si falta algo, escribir un parche **diagnóstico** (como 0329): histograma de intervalos de frame en el kernel de FB, más un muestreo de perf state y MHz por cluster.
2. **Carga reproducible.** Un deslizamiento automático del home, mediante una entrada sintética si existe un camino (el driver de touch `SWEET HID`), o un script fijo hecho por el usuario.
3. **A/B con n≥3 arranques cada uno** con `~/adb-bridge/exp-loop.sh`:
   - expG frente a 0334 (H6);
   - con y sin cable USB (H5);
   - variantes de `sweetsched` o afinidad (H1).
4. Solo después de descartar o confirmar la CPU, auditar Metal. Aviso: `HakiosMetal.bundle` está en el repo **sin código fuente** (04), así que primero hay que averiguar de dónde sale y si existe la fuente.
