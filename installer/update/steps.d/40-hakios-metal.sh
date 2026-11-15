# The Metal driver (HakiosMetal.bundle, built from metal/hakios-metal: HackiOS's hakios-metal plus the port's series for
# the Adreno 610) draws the screen (kernel sweetmetal=2). Its compiled shader stages and CoreAnimation specialisations
# are kept here across boots; backboardd, the only process that is shown the device, runs as mobile and owns the
# directory.
mkdir -p /private/var/db/hakios-metal-cache
chown mobile:mobile /private/var/db/hakios-metal-cache
chmod 755 /private/var/db/hakios-metal-cache
chmod 755 /System/Library/Extensions/HakiosMetal.bundle/HakiosMetal
