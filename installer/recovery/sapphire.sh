#!/system/bin/sh
# sapphire.sh: the phone's half of the Sapphire installer, run in OrangeFox from /tmp/sapphire (the ZIP puts
# it there). The Windows app drives it over adb, one command at a time:
#
#   info                  KEY=value lines: device, slots, the split of LUN 0
#   check                 the tools run, the disk is as expected
#   screen TEXT [FRAC]    the phone's status line (and progress bar, 0..1)
#   screen-on             the installer's own screen instead of OrangeFox's
#   part BYTES            iosroot BYTES, userdata the rest (Android's data is lost; restart the recovery after)
#   format-data           a fresh userdata for Android (after part, in the restarted recovery)
#   format                a fresh HFSX volume on iosroot (iOS erased)
#   recv NAME SIZE        the PC sends (sapphire-recv, adb forward) to: the disk image NAME (root|sysos|appos, kept in the volume's free tail)
#                         or overlay (the release's files, to /tmp)
#   build                 iOS's root built: the IPSW images + Sapphire's files + the recipes
#   kernel SIZE           the PC sends: the boot image for iOS's slot (padded, os_version set)
#   rtc EPOCH             the RTC's offset from the PC's clock, for rtcd
#   update NAME SIZE      the PC sends an update (NAME.supdate): into the inbox, applied by iOS at its next boot
#   finish                everything unmounted and synced
#
# Output for the PC: "STEP text", "PROGRESS done total", "ERROR text" (exit 1), other lines are log.
# Never touches: persist, modem, RPMB, the other LUNs; on LUN 0 only iosroot/userdata (part) and their data.

# Offsets here are tens of GB: the shell must do 64-bit arithmetic. Android's mksh (OrangeFox's /system/bin/sh)
# does 32-bit ($((43084775424 - 1)) gives 135102463): run again under busybox's ash, which does 64.
if [ "$((1 << 40))" != 1099511627776 ]; then
	for bb in busybox /system/bin/busybox /sbin/busybox /system/xbin/busybox; do
		if command -v $bb >/dev/null 2>&1 && [ "$($bb sh -c 'echo $((1 << 40))')" = 1099511627776 ]; then
			exec $bb sh "$0" "$@"
		fi
	done
	echo "ERROR el shell del recovery no hace cuentas de 64 bits y no hay busybox"
	exit 1
fi

S=${SAPPHIRE_DIR:-/tmp/sapphire}
B=$S/bin
export PATH=$B:/system/bin:/sbin:/bin:$PATH
IOS=${SAPPHIRE_IOS:-/dev/block/by-name/iosroot}       # (tests on a PC: an image file)
DISK=${SAPPHIRE_DISK:-/dev/block/sda}
command -v getprop >/dev/null 2>&1 || getprop() { eval echo "\${SAPPHIRE_PROP_$(echo "$1" | tr . _):-}"; }
LOG_BYTES=4198400                       # the iOS kernel's console ring at the partition's end (1025 x 4 KiB)
INBOX=134217728                         # the IPA inbox after the volume (Android app <-> iOS)
MIB=1048576
RELEASE=$(cat $S/VERSION 2>/dev/null || echo 0.1)   # this Sapphire release (installer/VERSION)
PORT=5550                               # sapphire-recv: the PC sends through adb forward tcp:5550 tcp:5550

step() { echo "STEP $*"; screen_set "$*"; }
fail() { echo "ERROR $*"; screen_set "Error: $*"; exit 1; }
screen_set() { printf '%s\n%s\n' "$1" "${2:-}" > $S/status.tmp && mv $S/status.tmp $S/status; }

# the PC's language (sapphire.sh lang es|en, sent when the ZIP is loaded): t ES EN prints the right one
LANG_CODE=$(cat $S/lang 2>/dev/null)
t() { if [ "$LANG_CODE" = en ]; then echo "$2"; else echo "$1"; fi; }

# a tool's "PROGRESS done total" lines: passed on to the PC, and to the phone's screen as TITLE · NN %
# with its bar (redrawn only when the percentage changes); other lines pass through
progress() {
	TITLE=$1
	last=-1
	while IFS= read -r line; do
		case "$line" in
		"PROGRESS "*)
			echo "$line"
			set -- $line
			if [ "${3:-0}" -gt 0 ] 2>/dev/null; then
				pct=$(( $2 * 100 / $3 ))
				if [ $pct != $last ]; then
					last=$pct
					screen_set "$TITLE · $pct %" "$(( pct / 100 )).$(printf %02d $(( pct % 100 )))"
				fi
			fi
			;;
		*) echo "$line" ;;
		esac
	done
}

size_of() {
	if [ -b "$1" ]; then
		blockdev --getsize64 "$1" 2>/dev/null
	else
		stat -L -c %s "$1"        # an image file (tests)
	fi
}

# the HFS volume's size: the partition minus the console ring and the inbox, MiB-aligned
volume_size() {
	p=$(size_of $IOS) || return 1
	echo $(( (p - LOG_BYTES - INBOX) / MIB * MIB ))
}

ios_slot() {
	case "$(getprop ro.boot.slot_suffix)" in
	_a) echo b ;;
	_b) echo a ;;
	*) echo "" ;;
	esac
}

cmd_info() {
	echo "device=$(getprop ro.product.device)"
	echo "slot=$(getprop ro.boot.slot_suffix | tr -d _)"
	echo "android_slot=$(getprop ro.boot.slot_suffix | tr -d _)"
	echo "ios_slot=$(ios_slot)"
	sapphire-part $DISK info
	echo "ram_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)"
	echo "tmp_free_kb=$(df -k /tmp | awk 'NR==2 {print $4}')"
}

cmd_check() {
	step "$(t "Comprobando el teléfono" "Checking the phone")"
	case "$(getprop ro.product.device)$(getprop ro.boot.hwname)" in
	*sapphire*) ;;
	*) fail "$(t "este teléfono no es un Redmi Note 13 4G (sapphire)" "this phone is not a Redmi Note 13 4G (sapphire)")" ;;
	esac
	[ -n "$(ios_slot)" ] || fail "$(t "no se sabe qué slot usa Android (ro.boot.slot_suffix vacío)" "Android's slot is unknown (ro.boot.slot_suffix is empty)")"
	for t in sapphire-part sapphire-loop sapphire-recv sapphire-untar mkhfs mkfs.hfsplus apfs-fuse plistop; do
		[ -x $B/$t ] || fail "$(t "falta $t en el ZIP" "$t is missing from the ZIP")"
	done
	[ -e /dev/fuse ] || fail "$(t "el recovery no tiene FUSE (/dev/fuse)" "the recovery has no FUSE (/dev/fuse)")"
	sapphire-part $DISK info >/dev/null || fail "$(t "la tabla de particiones no es la esperada" "the partition table is not the expected one")"
	# Baseband Guard (an LSM in some custom kernels, e.g. with KernelSU/SukiSU): the recovery runs on the boot
	# partition's kernel, and with it no write to the disk or to iosroot gets through (EPERM)
	if grep -qs baseband /sys/kernel/security/lsm || dmesg 2>/dev/null | grep -q baseband_guard ||
	    [ -d /sys/module/baseband_guard ]; then
		fail "$(t "el kernel de Android de este teléfono (kernel custom) tiene Baseband Guard, que bloquea la instalación. Flashea el boot.img original de tu ROM en el slot de Android, instala Sapphire y luego vuelve a poner tu kernel" "this phone's Android kernel (a custom kernel) has Baseband Guard, which blocks the install. Flash your ROM's original boot.img to the Android slot, install Sapphire, then put your kernel back")"
	fi
	echo "OK"
}

cmd_screen_on() {
	# OrangeFox's UI holds the display: stopped (adbd is its own service and stays)
	[ -f $S/status ] || screen_set "$(t "Completa los pasos en el PC" "Complete the steps on the PC")"
	setprop ctl.stop recovery 2>/dev/null
	sleep 1
	pkill -f sapphire-screen 2>/dev/null
	setsid sapphire-screen $S/screen/bg-${LANG_CODE:-es}.raw $S/screen/font.bin $S/status </dev/null >$S/screen.log 2>&1 &
	# keep the panel lit
	for b in /sys/class/backlight/*/brightness; do
		[ -w "$b" ] && echo 1200 > "$b" 2>/dev/null
	done
	echo "OK"
}

cmd_part() {
	want=$1
	[ -n "$want" ] || fail "$(t "part: falta el tamaño" "part: the size is missing")"
	step "$(t "Repartiendo el espacio" "Splitting the storage")"
	# nothing of LUN 0's userdata may be in use
	for m in /data /sdcard /data/media; do
		umount $m 2>/dev/null
	done
	if grep -q " /data " /proc/mounts; then
		fail "$(t "no se pudo desmontar /data" "/data could not be unmounted")"
	fi
	# the recovery may leave the disk read-only: made writable as `blockdev --setrw` (sapphire-part does it too)
	blockdev --setrw $DISK 2>/dev/null
	sapphire-part $DISK split "$want"
	rc=$?
	[ $rc = 3 ] || fail "$(t "no se pudo cambiar la tabla de particiones ($rc)" "the partition table could not be changed ($rc)")"
	echo "REBOOT"
}

cmd_format_data() {
	step "$(t "Formateando Android (userdata)" "Formatting Android (userdata)")"
	# What `fastboot -w` does: the start of userdata and of metadata (the keys of its encryption) erased.
	# Android's fstab marks both "formattable": its first boot makes them again, with its own encryption
	# options. (Not OrangeFox's Format Data: its UI is stopped while the installer holds the screen, and
	# `twrp format data` would wait for it for ever.)
	for m in /data /sdcard /data/media /metadata; do
		umount $m 2>/dev/null
	done
	for p in userdata metadata; do
		d=/dev/block/by-name/$p
		[ -b $d ] || fail "$(t "no existe la partición $p" "the $p partition does not exist")"
		grep -q "^$(readlink -f $d) " /proc/mounts && fail "$(t "$p sigue montada" "$p is still mounted")"
		sz=$(size_of $d)
		n=$(( sz / MIB < 64 ? sz / MIB : 64 ))
		dd if=/dev/zero of=$d bs=$MIB count=$n conv=notrunc,fsync 2>/dev/null || fail "$(t "no se pudo borrar $p" "$p could not be erased")"
		echo "$p: $(t "borrado (Android la formatea al arrancar)" "erased (Android formats it when it starts)")"
	done
	echo "OK"
}

cmd_format() {
	step "$(t "Borrando iOS" "Erasing iOS")"
	[ -b $IOS ] || [ -n "$SAPPHIRE_IOS" -a -f "$SAPPHIRE_IOS" ] || fail "$(t "no existe la partición iosroot" "the iosroot partition does not exist")"
	grep -q "$(readlink -f $IOS)" /proc/mounts && fail "$(t "iosroot está montada" "iosroot is mounted")"
	V=$(volume_size) || fail "$(t "no se pudo leer el tamaño de iosroot" "the size of iosroot could not be read")"
	[ "$V" -gt $((20 * 1024 * MIB)) ] || fail "$(t "iosroot es demasiado pequeña" "iosroot is too small")"
	dd if=/dev/zero of=$IOS bs=$MIB count=2 conv=notrunc,fsync 2>/dev/null
	L=$(sapphire-loop $IOS 0 $V) || fail "$(t "no se pudo crear el loop" "the loop device could not be made")"
	mkfs.hfsplus -s -J -v iOSRoot $L >$S/mkfs.log 2>&1
	rc=$?
	sapphire-loop -d $L
	[ $rc = 0 ] || { cat $S/mkfs.log; fail "$(t "mkfs.hfsplus falló" "mkfs.hfsplus failed")"; }
	echo $V > $S/V
	echo $(( V - MIB )) > $S/dmgtop  # images go below the alternate volume header, downwards
	: > $S/dmgs
	echo "volume=$V"
	echo "OK"
}

cmd_recv() {
	name=$1 size=$2
	[ -n "$size" ] || fail "$(t "recv: falta el tamaño" "recv: the size is missing")"
	case $name in
	overlay)
		step "$(t "Recibiendo los archivos de Sapphire" "Receiving Sapphire's files")"
		rm -f $S/overlay.tar.gz
		{ sapphire-recv $PORT $S/overlay.tar.gz 0 "$size"; echo $? > $S/rc; } | progress "$(t "Recibiendo los archivos de Sapphire" "Receiving Sapphire's files")"
		[ "$(cat $S/rc)" = 0 ] || fail "$(t "el overlay no llegó entero" "Sapphire's files did not arrive complete")"
		[ "$(stat -c %s $S/overlay.tar.gz)" = "$size" ] || fail "$(t "el overlay llegó incompleto" "Sapphire's files arrived incomplete")"
		;;
	root|sysos|appos)
		[ -f $S/V ] || fail "$(t "recv antes de format" "recv before format")"
		top=$(cat $S/dmgtop)
		off=$(( (top - size) / MIB * MIB ))           # where the image starts (MiB-aligned)
		[ $(( off - MIB )) -gt $(( $(cat $S/V) / 2 )) ] || fail "$(t "no caben las imágenes de iOS" "iOS's images do not fit")"
		# a loop's size is whole 512-byte sectors and a UDIF image keeps its trailer in its last 512 bytes:
		# PAD zero bytes go before the image, so loop = PAD + image ends exactly at the trailer
		pad=$(( (512 - size % 512) % 512 ))
		step "$(t "Recibiendo $name ($((size / MIB)) MB)" "Receiving $name ($((size / MIB)) MB)")"
		dd if=/dev/zero of=$IOS bs=$MIB seek=$((off / MIB - 1)) count=1 conv=notrunc 2>/dev/null
		# the bytes straight to the volume's free tail (mkhfs -r keeps it untouched)
		{ sapphire-recv $PORT $IOS $off "$size"; echo $? > $S/rc; } | progress "$(t "Recibiendo $name" "Receiving $name")"
		[ "$(cat $S/rc)" = 0 ] || fail "$(t "la imagen $name no llegó entera" "the image $name did not arrive complete")"
		sync
		if [ $pad -gt 0 ]; then
			sapphire-loop -k $IOS $(( off + size - 512 )) $pad || fail "$(t "la imagen $name no es UDIF y su tamaño no es múltiplo de 512" "the image $name is not UDIF and its size is not a multiple of 512")"
		fi
		echo "$name $(( off - pad )) $(( size + pad ))" >> $S/dmgs
		echo $(( off - MIB )) > $S/dmgtop
		;;
	*) fail "$(t "recv: $name desconocido" "recv: unknown $name")" ;;
	esac
	echo "OK"
}

mounts=""
loops=""
cleanup() {
	for m in $mounts; do
		umount $m 2>/dev/null || umount -l $m 2>/dev/null
	done
	for l in $loops; do
		sapphire-loop -d $l 2>/dev/null
	done
}

dmg_mount() {   # NAME: its loop as NAME.dmg (apfs-fuse picks UDIF by the name), mounted at $S/m/NAME
	set -- $(grep "^$1 " $S/dmgs)
	[ -n "$3" ] || fail "$(t "falta la imagen $1" "the image $1 is missing")"
	l=$(sapphire-loop $IOS $2 $3) || fail "$(t "loop de $1" "loop for $1")"
	loops="$loops $l"
	ln -sf $l $S/$1.dmg
	mkdir -p $S/m/$1
	apfs-fuse -o allow_other $S/$1.dmg $S/m/$1 >$S/apfs-$1.log 2>&1 || { cat $S/apfs-$1.log; fail "$(t "no se pudo abrir la imagen $1" "the image $1 could not be opened")"; }
	mounts="$S/m/$1 $mounts"
	[ -d $S/m/$1/root ] || fail "$(t "la imagen $1 no tiene raíz" "the image $1 has no root")"
}

# copy a file of the IPSW's tree into the change layer (mode/owner kept): VPATH SRC
mod_copy() {
	mkdir -p "$S/mod$(dirname "$1")"
	cp -p "$2" "$S/mod$1"
}

# a dict merged into a mobile preference (made if missing), as sweet-root-tweaks.py's merge_pref
pref() {   # NAME XMLFILE
	p=/private/var/mobile/Library/Preferences/$1.plist
	mkdir -p "$S/mod$(dirname $p)"
	[ -f "$OS$p" ] && cp "$OS$p" "$S/mod$p"
	plistop "$S/mod$p" merge "$2" || fail "$(t "preferencia $1" "preference $1")"
	chown 501:501 "$S/mod$p"
	chmod 600 "$S/mod$p"
}

xmlplist() {   # stdin (the dict's inside) -> FILE
	{ echo '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>'; cat; echo '</dict></plist>'; } > "$1"
}

# persist (read-only) in $sens: where OrangeFox has it, else mounted read-only here (umounted by cleanup)
persist_dir() {
	sens=""
	for p in /mnt/vendor/persist /persist; do
		[ -d $p/sensors ] && sens=$p && return
	done
	if [ -b /dev/block/by-name/persist ]; then
		mkdir -p $S/persist
		mount -t ext4 -o ro /dev/block/by-name/persist $S/persist 2>/dev/null && mounts="$S/persist $mounts" && sens=$S/persist
	fi
}

# the fingerprint sensor's factory calibration (Goodix, per unit: persist/goodix/gf_*.so, never the *_bak
# copies) into DIR (/var/root/fp: fpd loads every *.so there into the TA; without them every touch is 1004)
fp_calibration() {
	n=0
	if [ -n "$sens" ] && [ -d $sens/goodix ]; then
		mkdir -p "$1"
		for f in $sens/goodix/gf_*.so; do
			[ -f "$f" ] || continue
			cp "$f" "$1/" && n=$((n + 1))
		done
		chown -R 0:0 "$1"
		chmod 700 "$1"
		chmod 600 "$1"/*.so 2>/dev/null
	fi
	if [ $n -gt 0 ]; then
		echo "$(t "huella: calibración de fábrica de este teléfono copiada ($n archivos)" "fingerprint: this phone's factory calibration copied ($n files)")"
	else
		echo "$(t "huella: sin calibración de fábrica en persist (la huella no funcionará)" "fingerprint: no factory calibration in persist (the fingerprint will not work)")"
	fi
}

recipes() {
	OS=$S/m/root/root
	APP=$S/m/appos/root
	R=$S/recipes
	rm -rf $S/mod
	mkdir -p $S/mod
	: > $S/excl
	MOVES=""

	step "$(t "Ajustando launchd" "Adjusting launchd")"
	L=/System/Library/xpc/launchd.plist
	mod_copy $L "$OS$L"
	plistop "$S/mod$L" rename-each LaunchDaemons _PanicOnCrash _PanicOnCrasX del-each LaunchDaemons Label com.apple.CommCenter || fail "launchd.plist"
	for r in $R/launchd/*.plist; do
		k=$(plistop "$r" get Key) || fail "$(t "receta $r" "recipe $r")"
		# this phone's Bluetooth address where the recipe has @BDADDR@ (bluetoothd, btshim)
		sed "s/@BDADDR@/$BDADDR/g" "$r" > $S/recipe.plist
		plistop "$S/mod$L" put "LaunchDaemons:$k" $S/recipe.plist Job || fail "$(t "receta $r" "recipe $r")"
	done
	if [ -f $R/launchd-remove.txt ]; then
		while read -r label; do
			[ -n "$label" ] && plistop "$S/mod$L" del-each LaunchDaemons Label "$label"
		done < $R/launchd-remove.txt
	fi

	step "$(t "Activando 120 Hz en las apps" "Turning on 120 Hz in the apps")"
	n=0
	# the apps iOS stages for its first boot become system apps in /Applications (sapphire-apps-gl.sh)
	for a in "$OS"/private/var/staged_system_apps/*.app; do
		[ -d "$a" ] || continue
		b=${a##*/}
		[ -e "$OS/Applications/$b" ] && continue
		echo "/private/var/staged_system_apps/$b" >> $S/excl
		MOVES="$MOVES -g /Applications/$b=$a"
	done
	for a in "$OS"/Applications/*.app "$APP"/Applications/*.app "$OS"/private/var/staged_system_apps/*.app; do
		[ -f "$a/Info.plist" ] || continue
		b=${a##*/}
		mod_copy "/Applications/$b/Info.plist" "$a/Info.plist"
		plistop "$S/mod/Applications/$b/Info.plist" set CADisableMinimumFrameDurationOnPhone bool true || fail "$(t "Info.plist de $b" "Info.plist of $b")"
		n=$((n + 1))
	done
	# SpringBoard and the other system UI apps of CoreServices too (the phone's list)
	while read -r a; do
		[ -f "$OS$a/Info.plist" ] || continue
		mod_copy "$a/Info.plist" "$OS$a/Info.plist"
		plistop "$S/mod$a/Info.plist" set CADisableMinimumFrameDurationOnPhone bool true || fail "$(t "Info.plist de $a" "Info.plist of $a")"
		n=$((n + 1))
	done < $R/120hz-extra.txt
	echo "$(t "$n apps a 120 Hz" "$n apps at 120 Hz")"

	step "$(t "Audio, extensiones y servicios" "Audio, extensions and services")"
	# audio: Apple's HAL plug-ins aside (no AOP, no CarPlay...; Bluetooth's retried bluetoothd 110 times
	# a second), ours (RedwoodAudio.driver, in the overlay) alone in HAL
	h=/System/Library/Audio/Plug-Ins
	for d in "$OS$h"/HAL/*.driver; do
		[ -d "$d" ] || continue
		b=${d##*/}
		echo "$h/HAL/$b" >> $S/excl
		case $b in
		BTAudioHALPlugin.driver) MOVES="$MOVES -g $h/HAL.disabled/$b=$d" ;;
		*) MOVES="$MOVES -g $h/HAL.apple/$b=$d" ;;
		esac
	done
	# widgets and speech extensions that crash-loop without Metal, the modem's data or speech assets
	while read -r p; do
		[ -n "$p" ] && echo "$p" >> $S/excl
	done < $R/appex-remove.txt
	# CommCenter's bridge to our modem: Apple's optional /usr/appleinternal/lib/liblinkguard.dylib
	cc=$S/ovl/redwood/lib/ccbridge.dylib.pre-naspoll
	[ -f "$cc" ] || cc=$S/ovl/redwood/lib/ccbridge.dylib
	[ -f "$cc" ] || fail "$(t "falta ccbridge en los archivos de Sapphire" "ccbridge is missing from Sapphire's files")"
	mkdir -p $S/mod/usr/appleinternal/lib
	cp "$cc" $S/mod/usr/appleinternal/lib/liblinkguard.dylib
	chmod 755 $S/mod/usr/appleinternal/lib/liblinkguard.dylib
	# the first boot's activation fix (firstboot.sh), launched by the recipe com.sapphire.firstboot
	mkdir -p $S/mod/redwood/bin
	sed "s/@VERSION@/$VERSION/; s/@BUILD@/$BUILD/" $S/firstboot.sh > $S/mod/redwood/bin/sapphire-firstboot.sh
	chmod 755 $S/mod/redwood/bin/sapphire-firstboot.sh
	# the updater: the inbox's updates applied at every boot (from firstboot.sh)
	cp $S/ios/sapphire-update.sh $S/ios/sapphire-inboxcat $S/ios/sapphire-appwatch.sh $S/mod/redwood/bin/
	chmod 755 $S/mod/redwood/bin/sapphire-update.sh $S/mod/redwood/bin/sapphire-inboxcat $S/mod/redwood/bin/sapphire-appwatch.sh
	# iOS's dual-boot app, this release's (Restart into Android / Update Sapphire), over the overlay's
	if [ -d $S/ios/Android.app ]; then
		rm -rf $S/ovl/Applications/Android.app
		mkdir -p $S/mod/Applications
		cp -rp $S/ios/Android.app $S/mod/Applications/
		chmod 755 $S/mod/Applications/Android.app/Android
	fi
	echo "$RELEASE" > $S/mod/redwood/version
	# this release's files over the overlay's (boot.d scripts, the app loader)
	if [ -d $S/ios/files ]; then
		cp -a $S/ios/files/. $S/mod/
		chown -R 0:0 $S/mod/redwood
	fi
	# Sapphire's tweaks of this release (SapphireSafari: Safari's container), over the overlay's
	if [ -d $S/ios/tweaks ]; then
		mkdir -p $S/mod/private/var/jb/usr/lib/TweakInject
		cp $S/ios/tweaks/* $S/mod/private/var/jb/usr/lib/TweakInject/
		chmod 755 $S/mod/private/var/jb/usr/lib/TweakInject/*.dylib
	fi
	# the RTC's offset from real time (rtcd): from the PC's clock, so the first boot is not in 1970
	if [ -s $S/rtc_offset ]; then
		mkdir -p $S/mod/private/var/root
		cp $S/rtc_offset $S/mod/private/var/root/rtc_offset
		chmod 644 $S/mod/private/var/root/rtc_offset
	fi

	step "$(t "Ajustes de Sapphire" "Sapphire's settings")"
	# containers live on the data volume on iOS: made here
	for d in "Bundle 33" "Data/System 0" "Shared/SystemGroup 0" "Temp 0"; do
		set -- $d
		mkdir -p "$S/mod/private/var/containers/$1"
		chown $2:$2 "$S/mod/private/var/containers/$1"
		chmod 755 "$S/mod/private/var/containers/$1"
	done
	# logd's stores and the plain system keybag (mkiosroot.sh)
	db=$S/mod/private/var/db
	mkdir -p $db/diagnostics/timesync $db/uuidtext $S/mod/private/var/keybags
	for d in diagnostics uuidtext diagnostics/timesync; do
		: > $db/$d/.migrated
		chown 272:272 $db/$d $db/$d/.migrated
		chmod 644 $db/$d/.migrated
	done
	chmod 751 $db/diagnostics
	chmod 755 $db/uuidtext $db/diagnostics/timesync
	xmlplist $S/mod/private/var/keybags/systembag.kb <<-'EOF'
	<key>KeyBagKeys</key><data>U1dFRVQ=</data>
	EOF
	chmod 700 $S/mod/private/var/keybags
	chmod 600 $S/mod/private/var/keybags/systembag.kb
	# activation: mobileactivationd's data ark (its container, if the image has it)
	for meta in "$OS"/private/var/containers/Data/System/*/.com.apple.mobile_container_manager.metadata.plist; do
		[ -f "$meta" ] || continue
		if [ "$(plistop "$meta" get MCMMetadataIdentifier 2>/dev/null)" = com.apple.mobileactivationd ]; then
			c=${meta%/*}
			c=${c#$OS}
			mkdir -p "$S/mod$c/Library/internal"
			xmlplist "$S/mod$c/Library/internal/data_ark.plist" <<-EOF
			<key>-ActivationState</key><string>Activated</string><key>-BrickState</key><false/>
			<key>-BuildVersion</key><string>$BUILD</string><key>-ProductVersion</key><string>$VERSION</string>
			<key>-DataMigrationCompleted</key><true/><key>-PreSydroDataMigrationCompleted</key><true/>
			EOF
			plistop -b "$S/mod$c/Library/internal/data_ark.plist" set _ bool true del _
			chown -R 501:501 "$S/mod$c/Library"
			chmod 755 "$S/mod$c/Library/internal"
			chmod 600 "$S/mod$c/Library/internal/data_ark.plist"
		fi
	done
	# Files' "On My iPhone": the overlay's LocalStorageFileProvider is lswrap (userland/tweaks/fileprovider), which
	# loads libsapphire-fpfix and execs Apple's binary kept next to it as .pre-files: that one comes from the IPSW
	# (without it the extension never starts: no "On My iPhone", downloads cannot be moved there)
	f=/System/Library/Frameworks/FileProvider.framework/PlugIns/LocalStorageFileProvider.appex/LocalStorageFileProvider
	[ -f "$OS$f" ] && mod_copy "$f.pre-files" "$OS$f"
	# audio: VirtualAudio's HAL plug-in stays where it is: it makes iOS's routes (Speaker, Receiver) over
	# RedwoodAudio's devices; without it iOS has no output at all (AudioQueueStart -66680, no sound anywhere).
	# (An early port had it crash mediaserverd, before RedwoodAudio answered its properties.)
	for c in "$OS"/System/Library/Frameworks/MediaToolbox.framework/*/SubServerConfiguration.plist; do
		[ -f "$c" ] || continue
		mod_copy "${c#$OS}" "$c"
		plistop -x "$S/mod${c#$OS}" set StartRecorderServer bool false
	done
	# Setup skipped, no migration on every boot, no watchdogs (sweet-root-tweaks.py)
	t=$S/p.plist
	xmlplist $t <<-EOF
	<key>LastSystemVersion</key><string>$BUILD</string>
	<key>DMUserDataDisposition</key><dict><key>SyntheticDidUpgrade</key><false/><key>buildVersion</key><string>$BUILD</string></dict>
	EOF
	pref com.apple.migration $t
	xmlplist $t <<-'EOF'
	<key>BKNoWatchdogs</key><true/>
	<key>FBLaunchWatchdogExceptions</key><dict><key>com.apple.purplebuddy</key><real>100</real></dict>
	<key>MCForceShowCloudConfigurationUI</key><false/>
	EOF
	pref com.apple.springboard $t
	xmlplist $t <<-'EOF'
	<key>SetupDone</key><true/><key>SetupFinishedAllSteps</key><true/><key>SetupVersion</key><integer>11</integer>
	<key>daemonizeNeedsToRun</key><false/>
	EOF
	pref com.apple.purplebuddy $t
	xmlplist $t <<-'EOF'
	<key>ShouldRunDiagnosticsMiniBuddy</key><false/><key>ShouldRunHSA2MiniBuddy</key><false/>
	<key>ShouldRunKeychainSyncMiniBuddy</key><false/><key>ShouldRunMesaMiniBuddy</key><false/>
	<key>ShouldRunPaymentMiniBuddy</key><false/><key>ShouldRunStandardMiniBuddy</key><false/>
	<key>SilentICDPUpgrade</key><false/>
	EOF
	pref com.apple.purplebuddy.notbackedup $t
	xmlplist $t <<-'EOF'
	<key>LockdownActivationIndicatesCloudConfigurationAvailable</key><false/>
	EOF
	pref com.apple.managedconfiguration.notbackedup $t
	# the mobile folders the preferences made: owned by mobile
	chown 501:501 $S/mod/private/var/mobile $S/mod/private/var/mobile/Library $S/mod/private/var/mobile/Library/Preferences 2>/dev/null

	# further recipes from the release (sh fragments: they may use OS, APP, mod_copy, plistop, MOVES, excl)
	for f in $R/recipes.d/*.sh; do
		[ -f "$f" ] || continue
		echo "$(t receta recipe) ${f##*/}"
		. "$f"
	done
}

cmd_build() {
	[ -f $S/V ] && [ -s $S/dmgs ] || fail "$(t "faltan las imágenes de iOS" "iOS's images are missing")"
	V=$(cat $S/V)
	trap cleanup EXIT
	step "$(t "Abriendo la IPSW" "Opening the IPSW")"
	dmg_mount root
	dmg_mount sysos
	dmg_mount appos
	OS=$S/m/root/root
	VERSION=$(plistop "$OS/System/Library/CoreServices/SystemVersion.plist" get ProductVersion)
	BUILD=$(plistop "$OS/System/Library/CoreServices/SystemVersion.plist" get ProductBuildVersion)
	echo "iOS $VERSION ($BUILD)"
	case "$VERSION" in 16.*) ;; *) fail "$(t "la IPSW es de iOS $VERSION: hace falta iOS 16" "the IPSW is iOS $VERSION: iOS 16 is needed")" ;; esac

	step "$(t "Preparando los archivos de Sapphire" "Preparing Sapphire's files")"
	rm -rf $S/ovl
	mkdir -p $S/ovl
	if [ -f $S/overlay.tar.gz ]; then
		sapphire-untar $S/overlay.tar.gz $S/ovl 2>$S/untar.log || { tail -5 $S/untar.log; fail "$(t "el overlay no se pudo descomprimir" "Sapphire's files could not be unpacked")"; }
		rm -f $S/overlay.tar.gz
	fi
	# this phone's Bluetooth address: a static random one (top bits 11) made from its serial number, so the
	# same phone always gets the same one (the overlay and the recipes have @BDADDR@ where it goes)
	h=$(printf 'sapphire-bt-%s' "$(getprop ro.serialno)" | md5sum | cut -c1-12)
	BDADDR=$(printf '%02x:%s:%s:%s:%s:%s' $(( 0x$(echo $h | cut -c1-2) | 0xc0 )) $(echo $h | cut -c3-4) \
	    $(echo $h | cut -c5-6) $(echo $h | cut -c7-8) $(echo $h | cut -c9-10) $(echo $h | cut -c11-12))
	echo "bluetooth=$BDADDR"
	grep -rl '@BDADDR@' $S/ovl 2>/dev/null | while read -r f; do
		sed -i "s/@BDADDR@/$BDADDR/g" "$f"
	done
	recipes
	# this phone's sensor calibration (factory, per unit), from its persist partition mounted read-only
	persist_dir
	if [ -n "$sens" ] && [ -d $sens/sensors ]; then
		mkdir -p $S/mod/private/var/root/sensfiles/mnt/vendor/persist
		cp -rp $sens/sensors $S/mod/private/var/root/sensfiles/mnt/vendor/persist/
		chown -R 0:0 $S/mod/private/var/root/sensfiles
		echo "$(t "sensores: calibración de este teléfono copiada" "sensors: this phone's calibration copied")"
	else
		echo "$(t "sensores: sin persist legible, sin calibración de fábrica" "sensors: no readable persist, no factory calibration")"
	fi
	fp_calibration $S/mod/private/var/root/fp

	step "$(t "Construyendo iOS" "Building iOS")"
	top=$(sort -n -k2 $S/dmgs | head -1 | cut -d' ' -f2)
	reserve=$(( V - top ))
	L=$(sapphire-loop $IOS 0 $V) || fail "$(t "loop del volumen" "loop for the volume")"
	loops="$loops $L"
	{
		mkhfs $L $OS \
		    -u /private/preboot/Cryptexes/OS=$S/m/sysos/root \
		    -u /private/preboot/Cryptexes/App=$S/m/appos/root \
		    $MOVES -o $S/ovl -o $S/mod -x $S/excl -r $reserve -p 2>$S/mkhfs.log
		echo $? > $S/rc
	} | progress "$(t "Construyendo iOS" "Building iOS")"
	rc=$(cat $S/rc)
	grep -v "^mkhfs: skipped" $S/mkhfs.log | tail -5
	[ $rc = 0 ] || { tail -20 $S/mkhfs.log; fail "$(t "mkhfs falló" "mkhfs failed")"; }
	cleanup
	trap - EXIT
	mounts=""
	loops=""
	echo "OK"
}

cmd_kernel() {
	size=$1
	slot=$(ios_slot)
	[ -n "$slot" ] || fail "$(t "no se sabe el slot de iOS" "iOS's slot is unknown")"
	step "$(t "Instalando el kernel en el slot $slot" "Installing the kernel in slot $slot")"
	rm -f $S/kernel.img
	{ sapphire-recv $PORT $S/kernel.img 0 "$size"; echo $? > $S/rc; } | progress "$(t "Recibiendo el kernel" "Receiving the kernel")"
	[ "$(cat $S/rc)" = 0 ] || fail "$(t "el kernel no llegó entero" "the kernel did not arrive complete")"
	[ "$(stat -c %s $S/kernel.img)" = "$size" ] || fail "$(t "el kernel llegó incompleto" "the kernel arrived incomplete")"
	[ "$(head -c 8 $S/kernel.img)" = "ANDROID!" ] || fail "$(t "el kernel no es una imagen de arranque" "the kernel is not a boot image")"
	# os_version 16.0.0 / 2026-09 (0x200001a9): the bootloader wants one; header v3+ has it at 16, older at 44
	hv=$(od -An -tu4 -j40 -N4 $S/kernel.img | tr -d ' ')
	ov=44
	[ "$hv" -ge 3 ] 2>/dev/null && ov=16
	printf '\251\001\000\040' | dd of=$S/kernel.img bs=1 seek=$ov conv=notrunc 2>/dev/null
	# zero-padded to 128 MiB: the whole partition, no stale tail
	truncate -s 134217728 $S/kernel.img 2>/dev/null || dd if=/dev/zero of=$S/kernel.img bs=1 count=0 seek=134217728 2>/dev/null
	t=/dev/block/by-name/boot_$slot
	[ -b $t ] || fail "$(t "no existe boot_$slot" "boot_$slot does not exist")"
	[ "$(size_of $t)" -ge 134217728 ] || fail "$(t "boot_$slot es más pequeña que la imagen" "boot_$slot is smaller than the image")"
	dd if=$S/kernel.img of=$t bs=$MIB conv=fsync 2>/dev/null || fail "$(t "no se pudo escribir boot_$slot" "boot_$slot could not be written")"
	rm -f $S/kernel.img
	echo "OK"
}

# the RTC's offset from real time for rtcd (/var/root/rtc_offset): EPOCH is the PC's clock (UTC seconds);
# the RTC is the PMIC counter Android's driver shows as rtc0 (rtcd reads the same registers)
cmd_rtc() {
	now=$1
	r=$(cat /sys/class/rtc/rtc0/since_epoch 2>/dev/null)
	if [ -z "$now" ] || [ -z "$r" ]; then
		echo "$(t "sin RTC: la hora se pondrá desde la red" "no RTC: the time will come from the network")"
		echo "OK"
		return
	fi
	echo $(( now - r )) > $S/rtc_offset
	echo "rtc_offset=$(cat $S/rtc_offset)"
	echo "OK"
}

# update mode: the PC sends an update (installer/update/make-update.sh) and it goes to the inbox after iOS's
# volume; iOS applies it at its next boot (sapphire-update.sh). iOS, its apps and data are not touched.
cmd_update() {
	name=$1 size=$2
	case "$name" in *.supdate) ;; *) fail "update: $name" ;; esac
	[ -n "$size" ] || fail "$(t "update: falta el tamaño" "update: the size is missing")"
	[ -b $IOS ] || [ -n "$SAPPHIRE_IOS" -a -f "$SAPPHIRE_IOS" ] || fail "$(t "iOS no está instalado" "iOS is not installed")"
	step "$(t "Recibiendo la actualización" "Receiving the update")"
	rm -f $S/update.bin
	{ sapphire-recv $PORT $S/update.bin 0 "$size"; echo $? > $S/rc; } | progress "$(t "Recibiendo la actualización" "Receiving the update")"
	[ "$(cat $S/rc)" = 0 ] || fail "$(t "la actualización no llegó entera" "the update did not arrive complete")"
	[ "$(stat -c %s $S/update.bin)" = "$size" ] || fail "$(t "la actualización llegó incompleta" "the update arrived incomplete")"
	step "$(t "Guardando la actualización para iOS" "Leaving the update for iOS")"
	sapphire-inbox $IOS put "$name" $S/update.bin || fail "$(t "no se pudo guardar la actualización" "the update could not be stored")"
	rm -f $S/update.bin
	# this phone's own calibration files, as an update of their own (iOS copies only what it lacks):
	# installs made before they were copied at install (v0.1-test) get them this way
	trap cleanup EXIT
	persist_dir
	rm -rf $S/cal
	mkdir -p $S/cal
	fp_calibration $S/cal/fp
	if ls $S/cal/fp/*.so >/dev/null 2>&1; then
		cat > $S/cal/update.sh <<-'EOF'
		#!/var/jb/bin/bash
		# this phone's factory calibration (installer update mode): copied only where missing
		D=$1
		mkdir -p /var/root/fp
		chmod 700 /var/root/fp
		n=0
		for f in $D/fp/*.so; do
			b=${f##*/}
			[ -e /var/root/fp/$b ] && continue
			cp $f /var/root/fp/$b && chmod 600 /var/root/fp/$b && n=$((n + 1))
		done
		echo "fingerprint calibration: $n files added"
		[ $n -gt 0 ] && launchctl kickstart -k system/com.sapphire.fpd
		exit 0
		EOF
		chmod 755 $S/cal/update.sh
		(cd $S/cal && tar -cf - update.sh fp | gzip -c > $S/cal.tgz) && sync && [ -s $S/cal.tgz ] || fail "$(t "no se pudo empaquetar la calibración" "the calibration could not be packed")"
		sapphire-inbox $IOS put sapphire-calibration.supdate $S/cal.tgz || fail "$(t "no se pudo guardar la calibración" "the calibration could not be stored")"
	fi
	rm -rf $S/cal $S/cal.tgz
	cleanup
	trap - EXIT
	mounts=""
	sync
	echo "OK"
}

cmd_finish() {
	step "$(t "Terminando" "Finishing")"
	sync
	echo "OK"
}

c=$1
shift
case "$c" in
info) cmd_info ;;
check) cmd_check ;;
lang) echo "$1" > $S/lang; echo OK ;;
screen) screen_set "$1" "$2"; echo OK ;;
screen-on) cmd_screen_on ;;
part) cmd_part "$1" ;;
format-data) cmd_format_data ;;
format) cmd_format ;;
recv) cmd_recv "$1" "$2" ;;
build) cmd_build ;;
kernel) cmd_kernel "$1" ;;
rtc) cmd_rtc "$1" ;;
update) cmd_update "$1" "$2" ;;
finish) cmd_finish ;;
*) echo "usage: sapphire.sh info|check|screen|screen-on|part|format-data|format|recv|build|kernel|finish"; exit 2 ;;
esac
