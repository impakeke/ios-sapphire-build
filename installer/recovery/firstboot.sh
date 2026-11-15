#!/var/jb/bin/bash
# sapphire-firstboot: the first boot of a fresh install (launchd job com.sapphire.firstboot, once).
# iOS makes mobileactivationd's data container during that boot; until its data ark says "Activated",
# fairplayd starts and quits every 10 s without answering, locationd waits on it, and SpringBoard waits
# on locationd (Weather asks for the location synchronously): the Apple logo for ever. The ark is
# seeded as tools/sweet-root-tweaks.py did on the image, then the three are restarted.
export PATH=/var/jb/usr/bin:/var/jb/bin:/var/jb/usr/sbin:/usr/bin:/bin:/usr/sbin:/sbin
DONE=/var/root/.sapphire-firstboot-done
log() { echo "firstboot: $*"; echo "firstboot: $*" > /dev/console 2>/dev/null; }
# The jailbreak's runtime directories, left out of the overlay (overlay/exclude.txt), made again at every
# boot: without them Sileo dies at launch (its database lives in /var/jb/var/mobile) and apt cannot download
# (cache/apt/archives/partial). Only what is missing is made; nothing is overwritten.
J=/var/jb/var
mkdir -p $J/cache/apt/archives/partial $J/lib/apt/lists/partial $J/log/apt $J/run $J/root \
    "$J/mobile/Library/Caches" "$J/mobile/Library/Preferences" "$J/mobile/Library/Application Support" \
    $J/mobile/Documents /var/jb/Library/Preferences
[ -d $J/tmp ] || { mkdir -p $J/tmp; chmod 1777 $J/tmp; }
[ -e /var/jb/tmp ] || ln -s var/tmp /var/jb/tmp 2>/dev/null
chown -R 501:501 $J/mobile
chown 1001 $J/cache/apt/archives/partial $J/lib/apt/lists/partial 2>/dev/null   # _apt
chmod 700 $J/cache/apt/archives/partial $J/lib/apt/lists/partial
# Tweaks: rootless packages install into /var/jb/Library/MobileSubstrate/DynamicLibraries, which must be a
# link to ElleKit's /var/jb/usr/lib/TweakInject. Missing, dpkg makes a plain directory there and ElleKit never
# sees what goes in it: its contents are moved to TweakInject (nothing overwritten) and the link made.
D=/var/jb/Library/MobileSubstrate/DynamicLibraries
T=/var/jb/usr/lib/TweakInject
mkdir -p /var/jb/Library/MobileSubstrate $T
if [ -d $D ] && [ ! -L $D ]; then
	cp -an $D/. $T/ && rm -rf $D && log "tweaks moved from $D to $T"
fi
[ -L $D ] || ln -s $T $D
# Updates left in the inbox by the installer's update mode (userland/update/sapphire-update.sh), then the
# per-boot steps updates bring (/redwood/boot.d/*.sh, in name order). Not while an update runs this script.
if [ -z "$SAPPHIRE_UPDATING" ]; then
	[ -x /redwood/bin/sapphire-update.sh ] && SAPPHIRE_UPDATING=1 bash /redwood/bin/sapphire-update.sh
	for s in /redwood/boot.d/*.sh; do
		[ -f "$s" ] && bash "$s" && log "boot.d: $s"
	done
fi
[ -f $DONE ] && exit 0
VERSION=@VERSION@      # filled in by recovery/sapphire.sh from the IPSW
BUILD=@BUILD@
for i in $(seq 1 600); do
	for m in /var/containers/Data/System/*/.com.apple.mobile_container_manager.metadata.plist; do
		[ -f "$m" ] || continue
		if grep -q "com.apple.mobileactivationd" "$m"; then
			c=${m%/*}
			ark=$c/Library/internal/data_ark.plist
			if [ ! -s "$ark" ]; then
				mkdir -p "$c/Library/internal"
				cat > "$ark" <<-EOF
				<?xml version="1.0" encoding="UTF-8"?>
				<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
				<plist version="1.0">
				<dict>
					<key>-ActivationState</key><string>Activated</string>
					<key>-BrickState</key><false/>
					<key>-BuildVersion</key><string>$BUILD</string>
					<key>-ProductVersion</key><string>$VERSION</string>
					<key>-DataMigrationCompleted</key><true/>
					<key>-PreSydroDataMigrationCompleted</key><true/>
				</dict>
				</plist>
				EOF
				chown 501:501 "$c/Library" "$c/Library/internal" "$ark"
				chmod 755 "$c/Library/internal"
				chmod 600 "$ark"
				log "data ark seeded in $c"
			fi
			killall -9 mobileactivationd fairplayd.H2 locationd 2>/dev/null
			log "mobileactivationd, fairplayd and locationd restarted after ${i} s"
			# the jailbreak's apps (/var/jb/Applications: Sileo, Zebra, Filza, SnowBoard...) are on the
			# home screen only once registered: uicache, when SpringBoard is up
			for j in $(seq 1 60); do
				killall -0 SpringBoard 2>/dev/null && break
				sleep 5
			done
			sleep 60
			uicache -a && log "jailbreak apps registered (uicache)"
			touch $DONE
			exit 0
		fi
	done
	sleep 1
done
log "no mobileactivationd container after 10 minutes"
exit 1
