#!/bin/sh
# openUF install/uninstall script
#
# Installs the Lua emulator onto a writable OpenWrt device.
# Run from the project root after transferring files to the device.
#
# Usage:
#   ./install.sh install    — copy files, enable service
#   ./install.sh uninstall  — remove files, disable service

INSTALL_DIR=/opt/openuf
STATE_DIR=/etc/openuf
BIN_LINK=/usr/bin/syswrapper.sh
INIT_SCRIPT=/etc/init.d/openuf
LOG_FILE=/var/log/openuf.log

case "$1" in

	# ────────────────────────────────────────────────────────────────────────
	install)
		echo "Installing openUF to $INSTALL_DIR ..."

		# Check required opkg packages
		MISSING=""
		for pkg in lua lua-cjson lua-lzlib luacrypto iw lldpd; do
			if ! opkg list-installed 2>/dev/null | grep -q "^$pkg "; then
				MISSING="$MISSING $pkg"
			fi
		done
		if [ -n "$MISSING" ]; then
			echo "WARNING: missing opkg packages:$MISSING"
			echo "  Install them with: opkg update && opkg install$MISSING"
		fi

		# Copy Lua source
		mkdir -p "$INSTALL_DIR"
		cp -r openuf/* "$INSTALL_DIR/"

		# Create state directory
		mkdir -p "$STATE_DIR"

		# Symlink syswrapper.sh into PATH
		ln -sf "$INSTALL_DIR/hook/syswrapper.sh" "$BIN_LINK"
		chmod +x "$BIN_LINK"

		# Install init.d service
		cp openuf/etc/init.d/openuf "$INIT_SCRIPT"
		chmod +x "$INIT_SCRIPT"

		# Enable and start services
		"$INIT_SCRIPT" enable 2>/dev/null
		"$INIT_SCRIPT" start

		# Enable lldpd
		if [ -f /etc/init.d/lldpd ]; then
			/etc/init.d/lldpd enable
			/etc/init.d/lldpd start
		else
			echo "WARNING: lldpd init script not found; install lldpd and run:"
			echo "  /etc/init.d/lldpd enable && /etc/init.d/lldpd start"
		fi

		echo "Done.  Check $LOG_FILE for status."
		echo ""
		echo "Next steps:"
		echo "  1. If controller is on a different subnet:"
		echo "       syswrapper.sh set-inform http://<controller>:8080/inform"
		echo "  2. Open the UniFi controller → Devices → click Adopt"
		;;

	# ────────────────────────────────────────────────────────────────────────
	uninstall)
		echo "Uninstalling openUF ..."

		# Stop and disable service
		if [ -f "$INIT_SCRIPT" ]; then
			"$INIT_SCRIPT" stop  2>/dev/null
			"$INIT_SCRIPT" disable 2>/dev/null
			rm -f "$INIT_SCRIPT"
		fi

		# Remove symlink
		rm -f "$BIN_LINK"

		# Remove installed files (leave state dir so authkey is preserved)
		rm -rf "$INSTALL_DIR"

		echo "Done.  State dir $STATE_DIR left intact (remove manually if needed)."
		;;

	# ────────────────────────────────────────────────────────────────────────
	*)
		echo ""
		echo "Usage: $0 <install|uninstall>"
		echo ""
		echo "  install    Copy files to $INSTALL_DIR, create init.d service,"
		echo "             symlink syswrapper.sh to $BIN_LINK"
		echo ""
		echo "  uninstall  Remove installed files and service."
		echo "             State directory ($STATE_DIR) is preserved."
		echo ""
		;;
esac
