# Credits and licences

## HackiOS (OOSEX GANG)

Much of the GPU, display, audio, Wi-Fi glue and sandbox work here started from **HackiOS**, which
boots XNU and the iOS 16.5 user space on the POCO X5 Pro (redwood):

- kernel: <https://github.com/oosexgang/hackios-xnu-kernel> — Apple Public Source License 2.0
- user space: <https://github.com/oosexgang/hackios-xnu-userland> — MIT License, Copyright (c) 2026 OOSEX GANG

Until HackiOS published its source (2026-10-22) these parts were kept in a private tree; they are
now here, with our changes for the Redmi Note 12 4G (topaz, SM6225 / Adreno 610).

### Kernel patches derived from HackiOS (APSL 2.0)

`xnu/patches/0900-*` and `0901-*` … `0947-*` contain, adapted and modified for topaz:

*(This repository has no `09xx` patches; the numbers are probably those of the topaz tree this text came
from, unverified. Here the patches that name HackiOS as the origin of their code are 0149, 0150, 0155, 0156,
0200, 0301, 0319 and 0323; 0324 follows a HackiOS input filter with code of its own; 0321, 0338, 0339, 0342 and
0350 mention HackiOS's design or its Metal driver only as a reference or as the client they serve. Which patches carry
`kern.exec_inject` and the minisandbox container path is not verified.)*
`RedwoodGPU.cpp` (msm-style GPU client), the `MiniIOMobileFramebuffer` presentation ideas
(SwapEnd handed to a presenter thread, vsync notification layout), `redwood_apple80211` /
`redwood_sta` / `redwood_net` (Apple80211 for wifid), the `/dev/redwood-audio` interface, the
minisandbox container path, and `kern.exec_inject`. Like XNU itself, these files are under the
APSL 2.0; every patch records what we changed in its commit message.

### User space derived from HackiOS (MIT)

`userland/gpu/eagl.c`, `userland/gpu/gl_osmesa.c`, `userland/gpu/inject.c`,
`userland/mesa/*` (freedreno Darwin patches, `redwood-drm`) and `userland/audio/*`
(the RedwoodAudio HAL plug-in) are based on HackiOS user space (the MIT licence below).

### The Metal driver (MIT)

The Metal driver that draws CoreAnimation, `HakiosMetal.bundle`, is HackiOS's `hakios-metal`
(<https://github.com/oosexgang/hakios-xnu-kernel>, `hakios-metal/LICENSE`: MIT, Copyright (c) 2025-2026 the
HakiOS authors) with the fork's A610 patches; it is built outside this repository
(`dev-notes/investigacion/08`). The binary under `installer/update/files/` is the original author's build of
his fork of the same source. HackiOS's user space licence:

```
MIT License

Copyright (c) 2026 OOSEX GANG

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Others

- **ios-sweet** (dipa-studio): the XNU port this tree is built on.
- **Mesa / freedreno**: the OpenGL ES driver for the Adreno, and the shader compiler (NIR, ir3) linked into the
  Metal driver.
- **blacktop/darwin-xnu-build**: the XNU build scripts.
