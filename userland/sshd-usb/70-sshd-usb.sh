# com.sapphire.sshd-usb: sshd by key only, on the USB net (192.168.7.2) only; outside launchd's cache, loaded at every boot
launchctl list com.sapphire.sshd-usb >/dev/null 2>&1 || launchctl load /redwood/launchd/com.sapphire.sshd-usb.plist
