#!/bin/bash
# Restart the phone (iOS on sapphire, kernel 0221+) into fastboot, recovery or the system:
# "system" is a normal boot of the GPT's active slot, i.e. iOS again when iOS's
# slot is active (the installed layout); it is not "boot Android".
#   tools/sapphire-reboot.sh [bootloader|recovery|system]     (default bootloader)
# Runs over the USB network from WSL; iOS shuts down cleanly (journal closed) first.
set -e
case "${1:-bootloader}" in
bootloader) m=2 ;; recovery) m=1 ;; system) m=0 ;;
*) echo "usage: $0 [bootloader|recovery|system]" >&2; exit 2 ;;
esac
ssh -i ~/.ssh/sapphire_phone root@192.168.7.2 "/var/jb/usr/sbin/sysctl kern.sweet_reboot_mode=$m && /var/jb/sbin/reboot"
