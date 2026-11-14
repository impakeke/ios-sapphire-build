# 07 — CPU y tirones al deslizar: qué se midió

Pregunta: ¿la CPU es la causa de que el deslizamiento del home vaya lento y a tirones? Respuesta medida: sí, y no
por falta de núcleos o de frecuencia. El hilo de render de CoreAnimation estaba saturado de CPU en la ruta de draw
del driver Metal, y los A73 trabajaban casi sin L2 porque XNU la vaciaba antes de cada WFI. Con eso corregido, el
hilo de render deja de estar saturado y ningún recurso lo está: por frame gasta ~13,7 ms de CPU y la GPU 12,5 ms
(8,3 dibujando y 4,15 en la copia al panel), y los frames por segundo los fija cómo se encadenan (03 M11). El
estado de gráficos y el siguiente trabajo están en [INDICE.md](INDICE.md) y en [../../GPU-ROADMAP.md](../../GPU-ROADMAP.md).

| # | Hipótesis | Resultado | Evidencia |
|---|---|---|---|
| H1 | Los hilos de dibujo caen en los núcleos pequeños o compiten | **Descartada para el hilo de render**: prioridad fija 54, corre el 100 % en los A73. `sweetsched=15` manda a los A53 los hilos de QoS por defecto; el A/B 15 frente a 13 no separa (n=3) | [16](16-planificador-e-hilos.md) §2.4, §3.2-3.3 |
| H2 | La frecuencia no sube | **Descartada**: A73 a 2786-2803 MHz y A53 a 1854-1901 MHz medidos | 16 §3.1; [03](03-experimentos-y-datos.md) M10 (`kern.sweet_gpu_clocks`) |
| H3 | Picos de CPU de otros hilos | **El coste está en el propio hilo de render**: 84-90 % de CPU, la mitad en la ruta de draw del driver (126 µs por draw, ~150 draws por frame). Los hilos del kernel que sondean despiertan a los A73 3600-4100 veces por segundo, y cada entrada en reposo vaciaba la L2 del cluster: quitar ese vaciado (`kern.sweet_idle_cache=0`, 0344) baja el driver de 62-68 a 25-26 µs por draw y sube los buffers por segundo un 50 % (n=2) | 03 M1, M2, M10; 16 §1, §4 |
| H4 | Ritmo de presentación | **Contribuía**: el 10,6-13,8 % de los frames dibujados se pisaba antes de llegar al panel; la cola de 0340 lo deja en 0 | 03 M6, M7; [15](15-kernel-cache-y-presentacion.md) §0.1 |
| H5 | El driver USB v2 gira mientras hay tráfico | Sin medir | — |
| H6 | El compilador del kernel (Xcode 16 frente a Apple clang 21) | Sin medir | — |

Lo que se sabía antes y no se sostiene:

- `SWEET FB: 5 s … N by the GPU` no mide frames mostrados: cuenta swaps, y con `sweetfb_scale=2` sus tiempos salen
  siempre a 0 ([09](09-auditoria-kernel-gpu.md) §1). Los frames que llegan al panel los da `kern.sweet_fb_diag` (0336).
- `gpu_mhz=1260` sin `gpu_vco2=1` deja el núcleo de la GPU a 630 MHz (03 M3).
- El teléfono sí se calienta: en calma, iOS está unos 20 °C por encima del reposo de Android
  ([17](17-gpu-escalado-termica-ddr.md) §4.4).
- El driver Metal tiene fuente publicada y se compila en la Mac ([08](08-hakiosmetal-binario-vs-fuente.md)).

Datos de reposo (CPU-0334 en 03): load de 1 min 1,1-2,6 con 8 núcleos tras arrancar, sin un proceso dominante.
