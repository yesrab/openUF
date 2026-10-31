#!/bin/sh
# openuf-bootstrap.sh -- create the bootstrap adoption account, ubnt/ubnt.
#
# L2 adoption works by the controller SSHing into the device and running
# `syswrapper.sh set-adopt <url> <key>`. Real Ubiquiti hardware ships an
# ubnt/ubnt login for exactly that; this creates a locked-down copy of it: a
# non-root account whose shell (hook/adopt-shell.sh) permits that one command
# and refuses everything else. The daemon locks the account once the device
# is adopted and re-enables it on a factory reset (bootstrap_adopt_user).
#
# Run by setup.sh after a package install, and as `openuf bootstrap-account`.
# install.sh does the same for a file install, inline. Nothing happens when
# the device is already adopted; an account that exists is left as it is,
# except that its shell is registered in /etc/shells when it is missing
# there (the repair for an account made before that was known to matter).
#
#   openuf-bootstrap.sh            the account for the install that runs
#   openuf-bootstrap.sh --dir DIR  the install under DIR
#
# POSIX sh: this runs under busybox ash.

set -u

DIR=""
STATE_DIR=/etc/openuf
SHELLS=/etc/shells
while [ $# -gt 0 ]; do
	case "$1" in
		--dir) shift; DIR=${1:-} ;;
		-h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) echo "openuf-bootstrap: unknown option: $1" >&2; exit 2 ;;
	esac
	shift
done
if [ -z "$DIR" ]; then
	for d in /usr/lib/openuf /opt/openuf; do
		if [ -f "$d/inform.lua" ]; then DIR=$d; break; fi
	done
fi
[ -n "$DIR" ] && [ -f "$DIR/hook/adopt-shell.sh" ] \
	|| { echo "openuf-bootstrap: no openUF install found (hook/adopt-shell.sh)" >&2; exit 1; }

# dropbear checks a login's shell against /etc/shells (getusershell(3))
# BEFORE it looks at the password, and OpenWrt ships that file with /bin/ash
# alone. An unlisted shell is "User 'ubnt' has invalid shell, rejected" in
# the log: the controller's three SSH attempts fail and the mobile app asks
# for the root credentials instead ("advanced adoption") -- AP2, 2026-10-25.
# The validation container's OpenSSH has no such check, which is how the
# account passed there and never on a device. So the forced shell is
# registered here, for a new account and for one that exists already.
register_shell() {
	if [ ! -f "$SHELLS" ]; then
		# No file: dropbear falls back to its built-in list (/bin/ash and
		# /bin/sh on OpenWrt). A file holding the adoption shell alone would
		# lock root out, so that list goes in first.
		printf '/bin/ash\n/bin/sh\n' > "$SHELLS"
	fi
	grep -qxF "$1" "$SHELLS" && return 0
	# A last line without its newline would swallow the entry (install.sh's
	# sysupgrade.conf lesson): `tail -c1` is empty exactly when the file
	# ends in a newline, since command substitution strips it.
	if [ -s "$SHELLS" ] && [ -n "$(tail -c1 "$SHELLS")" ]; then
		echo >> "$SHELLS"
	fi
	echo "$1" >> "$SHELLS"
}

# /etc/shadow is never edited in place: the new contents go to a temp file
# beside it and are renamed over it (rename(2) is atomic), so a reader never
# sees half a file and a failed write leaves the old one. Under busybox's
# `lock` where the image has it, so two runs cannot interleave.
SHADOW_LOCK=/var/lock/openuf-shadow.lock
shadow_lock()   { command -v lock >/dev/null 2>&1 && lock "$SHADOW_LOCK"; return 0; }
shadow_unlock() { command -v lock >/dev/null 2>&1 && lock -u "$SHADOW_LOCK"; return 0; }
# stdin -> /etc/shadow. An empty result (a failed sed) is refused.
shadow_replace() {
	_t="/etc/shadow.openuf.$$"
	( umask 077; cat > "$_t" ) && [ -s "$_t" ] && mv -f "$_t" /etc/shadow \
		|| { rm -f "$_t"; echo "openuf-bootstrap: /etc/shadow not updated" >&2; return 1; }
}
shadow_append() {
	shadow_lock
	{
		cat /etc/shadow
		# A last line without its newline would swallow the entry.
		[ -s /etc/shadow ] && [ -n "$(tail -c1 /etc/shadow)" ] && echo
		echo "$1"
	} | shadow_replace
	shadow_unlock
}

if grep -q '^ubnt:' /etc/passwd 2>/dev/null; then
	# Whatever shell the account has (a file install's is under /opt/openuf):
	# every account made before 2026-10-25 is missing from /etc/shells, and
	# `openuf bootstrap-account` is the documented way to put that right.
	_cur=$(awk -F: '$1=="ubnt"{print $7}' /etc/passwd)
	if [ -n "$_cur" ] && ! grep -qxF "$_cur" "$SHELLS" 2>/dev/null; then
		register_shell "$_cur"
		echo "  the ubnt account already exists; registered its shell in $SHELLS"
	else
		echo "  the ubnt account already exists; left as it is"
	fi
	exit 0
fi
if [ -f "$STATE_DIR/state.json" ] && grep -q '"adopted":true' "$STATE_DIR/state.json" 2>/dev/null; then
	echo "  the device is already adopted; no bootstrap account is needed"
	exit 0
fi
# A group of its own, so the state directory can be made writable for this
# account without granting it anything else.
GID=900
while grep -q "^[^:]*:[^:]*:$GID:" /etc/group 2>/dev/null; do GID=$((GID + 1)); done
echo "openuf:x:$GID:" >> /etc/group

UID_=900
while awk -F: -v id="$UID_" '$3==id{f=1} END{exit !f}' /etc/passwd 2>/dev/null; do UID_=$((UID_ + 1)); done

SHELL_="$DIR/hook/adopt-shell.sh"
chmod +x "$SHELL_"
echo "ubnt:x:$UID_:$GID:openuf bootstrap adoption:$STATE_DIR:$SHELL_" >> /etc/passwd
# Locked ("!") until a hash is in: an image without the openssl CLI used to
# get an EMPTY hash here, which is an account with no password at all.
shadow_append "ubnt:!:::::::"
register_shell "$SHELL_"

# The hash, from whatever the image has: the openssl CLI (openssl-util);
# busybox passwd, which reads the new password from stdin once setsid has
# taken the terminal away (with a tty it would ask there); uhttpd's -m, the
# md5 crypt LuCI uses for its own HTTP passwords. Any of them beats a locked
# account, and a locked account beats an open one.
set_hash() { shadow_lock; sed "s|^ubnt:[^:]*:|ubnt:$1:|" /etc/shadow | shadow_replace; shadow_unlock; }
HASHED=0
if command -v openssl >/dev/null 2>&1; then
	_h=$(openssl passwd -6 ubnt 2>/dev/null)
	[ -n "$_h" ] && { set_hash "$_h"; HASHED=1; }
fi
if [ "$HASHED" = 0 ] && command -v setsid >/dev/null 2>&1 && command -v passwd >/dev/null 2>&1; then
	printf 'ubnt\nubnt\n' | setsid passwd -a sha512 ubnt >/dev/null 2>&1
	grep -q '^ubnt:!' /etc/shadow || HASHED=1
fi
if [ "$HASHED" = 0 ] && command -v uhttpd >/dev/null 2>&1; then
	_h=$(uhttpd -m ubnt 2>/dev/null | head -1)
	case "$_h" in \$*) set_hash "$_h"; HASHED=1 ;; esac
fi

mkdir -p "$STATE_DIR"
chgrp "$GID" "$STATE_DIR"
chmod g+w "$STATE_DIR"
# A group-writable directory only covers creating state.json. One that exists
# already, owned by root, must be writable for the account too: opening an
# existing file for writing needs permission on the file itself.
[ -f "$STATE_DIR/state.json" ] || : > "$STATE_DIR/state.json"
chgrp "$GID" "$STATE_DIR/state.json"
# 660, not 664: the authkey stays off world read. (state.save replaces the
# file by rename, so later copies take the writer's umask.)
chmod 660 "$STATE_DIR/state.json"

# Tell the daemon the account exists, so it locks and unlocks it with the
# adoption state: in UCI where UCI is in charge (a `main` section), else in
# conf.lua.
if uci -q get openuf.main >/dev/null 2>&1; then
	uci set openuf.main.bootstrap_adopt_user=ubnt
	uci commit openuf
elif [ -f "$DIR/conf.lua" ]; then
	sed -i 's/bootstrap_adopt_user = nil/bootstrap_adopt_user = "ubnt"/' "$DIR/conf.lua"
fi

if [ "$HASHED" = 1 ]; then
	echo "  created the non-root account ubnt (password ubnt), restricted to"
	echo "  'syswrapper.sh set-adopt' and listed in $SHELLS for dropbear; it locks"
	echo "  itself once the device is adopted and comes back on a factory reset"
else
	echo "  created the account ubnt, but LOCKED: nothing on this image can hash" >&2
	echo "  its password (no openssl, passwd or uhttpd). Set it by hand, as ubnt:" >&2
	echo "    passwd ubnt" >&2
	exit 1
fi
