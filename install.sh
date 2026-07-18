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

case "$1" in

	# ────────────────────────────────────────────────────────────────────────
	install)
		echo "Installing openUF to $INSTALL_DIR ..."

		# Check required apk packages (OpenWrt 25.12+ uses apk, not opkg).
		# lua-openssl provides AES-128-CBC/GCM (luacrypto was dropped from the feeds);
		# there is no Lua zlib binding in 25.12, so inform-response decompression is
		# handled in-tree by openuf/inflate.lua and no zlib package is required.
		MISSING=""
		for pkg in lua lua-cjson luasocket lua-openssl luabitop iw lldpd openssl-util; do
			if ! apk info -e "$pkg" >/dev/null 2>&1; then
				MISSING="$MISSING $pkg"
			fi
		done
		if [ -n "$MISSING" ]; then
			echo "WARNING: missing apk packages:$MISSING"
			echo "  Install them with: apk update && apk add$MISSING"
		fi

		# usteer (Band Steering) + a full wpad build (BSS Transition /
		# Band Steering both need real 802.11k/v support -- wpad-basic-*
		# lacks bss_transition entirely and errors with "unknown
		# configuration item 'bss_transition'"). Unlike the base packages
		# above, these are actually installed (not just warned about) so
		# both features work out of the box.
		if ! apk info -e usteer >/dev/null 2>&1; then
			echo "Installing usteer (Band Steering support) ..."
			apk add usteer \
				|| echo "WARNING: failed to install usteer -- Band Steering will not function."
		fi

		if ! apk info -e wpad-wolfssl >/dev/null 2>&1 && ! apk info -e wpad-openssl >/dev/null 2>&1; then
			echo "Installing a full wpad build (required for BSS Transition / Band Steering) ..."
			apk add wpad-wolfssl \
				|| apk add wpad-openssl \
				|| echo "WARNING: failed to install a full wpad build -- BSS Transition and Band Steering will not function (wpad-basic-* lacks 802.11v support)."
		fi

		# Copy Lua source. etc/ is excluded deliberately: the init script
		# belongs in /etc/init.d (installed further down) and a second copy
		# under $INSTALL_DIR would never be executed.
		mkdir -p "$INSTALL_DIR"
		cp -r openuf/* "$INSTALL_DIR/"
		rm -rf "$INSTALL_DIR/etc"

		# Release tarballs arrive already comment-stripped (tools/dist.sh).
		# When installing from a git clone, strip on the way in using the same
		# tool so the device gets the same lean tree -- roughly half the bytes,
		# and flash is scarce. conf.lua and the modelmaps keep their comments:
		# they are the files meant to be hand-edited on the device.
		if [ -f tools/strip.lua ] && command -v lua >/dev/null 2>&1; then
			echo "Stripping comments from installed Lua ..."
			for f in $(find "$INSTALL_DIR" -name '*.lua' \
				! -name conf.lua ! -path "$INSTALL_DIR/modelmap/*"); do
				lua tools/strip.lua "$f" > "$f.stripped" \
					&& mv "$f.stripped" "$f"
			done
		fi

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

		# ── Optional: --bootstrap-adopt ──────────────────────────────────
		# Creates a temporary, non-root SSH account (ubnt/ubnt) matching real
		# Ubiquiti hardware's factory-default login, so first adoption can
		# complete without presetting a root password. Scoped to only ever
		# run `syswrapper.sh set-adopt` (see hook/adopt-shell.sh) and only
		# able to write $STATE_DIR -- no other privilege. Self-locks once the
		# device is adopted and re-enables on factory reset (see
		# inform.lua's M._sync_bootstrap_account). See USAGE.md.
		if [ "$2" = "--bootstrap-adopt" ]; then
			echo "Setting up SSH bootstrap adoption account (ubnt/ubnt) ..."

			ALREADY_ADOPTED=0
			if [ -f "$STATE_DIR/state.json" ] \
				&& grep -q '"adopted":true' "$STATE_DIR/state.json"; then
				ALREADY_ADOPTED=1
			fi

			if [ "$ALREADY_ADOPTED" = "1" ]; then
				echo "  Device is already adopted -- skipping account creation."
			elif grep -q "^ubnt:" /etc/passwd 2>/dev/null; then
				echo "  ubnt account already exists -- leaving as-is."
			else
				# Dedicated group so $STATE_DIR can be made group-writable by
				# the bootstrap account without granting it anything else.
				BA_GID=900
				while grep -q "^[^:]*:[^:]*:$BA_GID:" /etc/group 2>/dev/null; do
					BA_GID=$((BA_GID + 1))
				done
				echo "openuf:x:$BA_GID:" >> /etc/group

				BA_UID=900
				while awk -F: -v id="$BA_UID" \
					'$3==id{f=1} END{exit !f}' /etc/passwd 2>/dev/null; do
					BA_UID=$((BA_UID + 1))
				done

				ADOPT_SHELL="$INSTALL_DIR/hook/adopt-shell.sh"
				chmod +x "$ADOPT_SHELL"

				echo "ubnt:x:$BA_UID:$BA_GID:openuf bootstrap adoption:$STATE_DIR:$ADOPT_SHELL" \
					>> /etc/passwd
				HASH=$(openssl passwd -6 ubnt)
				echo "ubnt:$HASH:::::::" >> /etc/shadow

				chgrp "$BA_GID" "$STATE_DIR"
				chmod g+w "$STATE_DIR"

				# Group-writable directory alone only covers *creating* a new
				# state.json. If one somehow already exists owned by root
				# (e.g. an admin ran `syswrapper.sh reset-inform` by hand
				# before ever using this account), ubnt can't write to it --
				# opening an existing file for writing needs permission on
				# the file itself, not just the directory. Pre-create it
				# group-writable so this works regardless of which side
				# (root or ubnt) writes to it first and thereafter.
				[ -f "$STATE_DIR/state.json" ] || : > "$STATE_DIR/state.json"
				chgrp "$BA_GID" "$STATE_DIR/state.json"
				chmod 664 "$STATE_DIR/state.json"

				# Tell the running daemon this account exists and should be
				# locked/unlocked to track adopted state.
				sed -i 's/bootstrap_adopt_user = nil/bootstrap_adopt_user = "ubnt"/' \
					"$INSTALL_DIR/conf.lua"

				echo "  Created non-root 'ubnt' account (password: ubnt),"
				echo "  restricted to running 'syswrapper.sh set-adopt' only."
				echo "  It self-locks once the device is adopted and"
				echo "  re-enables on factory reset."
			fi
		fi

		echo "Done.  Check status with: logread -e openuf"
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

		# Remove the SSH bootstrap account/group if present (hygiene --
		# symmetric with what install --bootstrap-adopt added, regardless of
		# whether that flag is passed here).
		if grep -q "^ubnt:" /etc/passwd 2>/dev/null; then
			sed -i '/^ubnt:/d' /etc/passwd
			sed -i '/^ubnt:/d' /etc/shadow
			echo "Removed SSH bootstrap account 'ubnt'."
		fi
		if grep -q "^openuf:" /etc/group 2>/dev/null; then
			sed -i '/^openuf:/d' /etc/group
		fi

		# Remove installed files (leave state dir so authkey is preserved)
		rm -rf "$INSTALL_DIR"

		echo "Done.  State dir $STATE_DIR left intact (remove manually if needed)."
		;;

	# ────────────────────────────────────────────────────────────────────────
	*)
		echo ""
		echo "Usage: $0 <install|uninstall> [--bootstrap-adopt]"
		echo ""
		echo "  install    Copy files to $INSTALL_DIR, create init.d service,"
		echo "             symlink syswrapper.sh to $BIN_LINK"
		echo ""
		echo "  install --bootstrap-adopt"
		echo "             Also create a temporary, non-root SSH account"
		echo "             (ubnt/ubnt) restricted to running 'set-adopt' only,"
		echo "             so first adoption works without presetting a root"
		echo "             password. Self-locks once adopted. See USAGE.md."
		echo ""
		echo "  uninstall  Remove installed files and service."
		echo "             State directory ($STATE_DIR) is preserved."
		echo "             Removes the bootstrap account if present."
		echo ""
		;;
esac
