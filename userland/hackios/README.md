# From HackiOS

Files here and in `userland/mesa/` come from HackiOS by OOSEX GANG
(<https://github.com/oosexgang/hackios-xnu-userland>, commit 906425b75e02), MIT License (`LICENSE` here).
Changes for sapphire are marked where they are made; the main one: the GPU service is
`SapphireGPU` (xnu patch 0149) instead of `RedwoodGPU`.

The Metal driver that draws CoreAnimation (`HakiosMetal.bundle`, `sweetmetal=2`) is not here: it is HackiOS's
`hakios-metal` (`oosexgang/hakios-xnu-kernel`, MIT, `main` at `63fc2b4`) with the fork's A610 patches, built out of
git (`dev-notes/investigacion/08`, `GPU-ROADMAP.md`). The binary under `installer/update/files/` is the original
author's build of his fork of that source.
