#!/bin/sh
# openuf-convert -- turn this OpenWrt router into a pure access point, or back.
#
#   openuf-convert --check
#       Prints JSON: {"state":"router"|"ap","reasons":[...],"converted":{...}|null}
#       "router" while anything a router does is still switched on.
#   openuf-convert --convert [--address dhcp|<ip>/<prefix>] [--gateway <ip>]
#                            [--dns "<ip> <ip>"] [--keep-wan-socket]
#       The conversion setup.sh's last phase performs, as a command: the WAN
#       interfaces go, the WAN socket joins the LAN (inside the switch on a
#       swconfig board where the profile's geometry allows it, else into the
#       bridge), the LAN takes a DHCP address (or the static one given), the
#       DHCP server is switched off, firewall/dnsmasq/odhcpd are stopped and
#       disabled, the resolver stops pointing at dnsmasq, lldpd's chassis id
#       follows the LAN, and every radio is enabled. Committed, NOT applied:
#       the caller reboots, which is the only safe way to apply a network
#       teardown you are connected through. A backup of the config files and
#       a stamp (uci openuf.convert) make --revert possible.
#   openuf-convert --revert
#       Puts the backed-up config files back and re-enables the services that
#       were enabled before. Also takes effect at the next reboot.
#
# Every unknown is a refusal: a wrong guess here is a device that does not
# come back from the reboot.
set -u

BACKUP=/etc/openuf/convert-backup.tgz
CFGS="network dhcp firewall wireless lldpd"
SERVICES="firewall dnsmasq odhcpd"

say()  { printf '%s\n' "$*"; }
die()  { printf 'openuf-convert: %s\n' "$*" >&2; exit 1; }

json_str() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\n'; }

# ── --check ────────────────────────────────────────────────────────────────
check() {
	reasons=""
	uci -q get network.wan >/dev/null 2>&1 && reasons="$reasons|network.wan exists (a router uplink)"
	uci -q get network.wan6 >/dev/null 2>&1 && reasons="$reasons|network.wan6 exists"
	for svc in $SERVICES; do
		if [ -x "/etc/init.d/$svc" ] && "/etc/init.d/$svc" enabled 2>/dev/null; then
			reasons="$reasons|$svc is enabled at boot"
		fi
	done
	if [ -x /etc/init.d/dnsmasq ] && [ -f /etc/config/dhcp ] \
		&& [ "$(uci -q get dhcp.lan.ignore 2>/dev/null)" != 1 ]; then
		reasons="$reasons|the DHCP server answers on lan"
	fi
	state=ap; [ -n "$reasons" ] && state=router
	printf '{"state":"%s","reasons":[' "$state"
	first=1
	IFS='|'; for r in $reasons; do
		[ -n "$r" ] || continue
		[ $first = 1 ] || printf ','
		printf '"%s"' "$(json_str "$r")"; first=0
	done; unset IFS
	printf ']'
	when=$(uci -q get openuf.convert.when 2>/dev/null)
	if [ -n "$when" ]; then
		printf ',"converted":{"when":%s,"backup":"%s","backup_present":%s}' "$when" \
			"$(json_str "$(uci -q get openuf.convert.backup)")" \
			"$([ -f "$(uci -q get openuf.convert.backup)" ] && echo true || echo false)"
	else
		printf ',"converted":null'
	fi
	printf '}\n'
}

# ── helpers for --convert ──────────────────────────────────────────────────
prefix_to_netmask() {
	p=$1
	case "$p" in ''|*[!0-9]*) return 1 ;; esac
	[ "$p" -ge 0 ] && [ "$p" -le 32 ] || return 1
	m=$(( 0xFFFFFFFF << (32 - p) & 0xFFFFFFFF ))
	printf '%d.%d.%d.%d\n' $(( m >> 24 & 255 )) $(( m >> 16 & 255 )) $(( m >> 8 & 255 )) $(( m & 255 ))
}

is_ipv4() {
	printf '%s' "$1" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || return 1
	IFS='.'; for o in $1; do [ "$o" -le 255 ] || { unset IFS; return 1; }; done; unset IFS
	return 0
}

# The profile's switch geometry, from the daemon's own description of the
# resolved configuration (openuf probe status), so this script and the daemon
# can never disagree about which port is the CPU's.
probe_field() {
	[ -n "${PROBE:-}" ] || PROBE=$(openuf probe status 2>/dev/null)
	[ -n "$PROBE" ] || return 1
	jsonfilter -s "$PROBE" -e "@.$1" 2>/dev/null
}

# Move the WAN socket into the LAN VLAN inside the switch (swconfig). Returns 1,
# changing nothing, unless every fact needed is known -- see setup.sh's
# absorb_wan_swconfig, which this is.
absorb_wan_swconfig() {
	lan_vid=$(probe_field modelmap.lan_vlanid); cpu_lan=$(probe_field modelmap.vlan.cpu_lan)
	cpu_wan=$(probe_field modelmap.vlan.cpu_wan)
	[ -n "$lan_vid" ] && [ -n "$cpu_lan" ] || { say "  profile declares no switch geometry; not touching the VLANs"; return 1; }
	secs=$(uci show network 2>/dev/null | sed -n "s/^network\.@switch_vlan\[\([0-9]*\)\]\.vlan='*\([0-9]*\)'*\$/\1:\2/p")
	[ -n "$secs" ] || return 1
	lan_idx=""; wan_idx=""; wan_vid=""; lan_n=0; wan_n=0
	for e in $secs; do
		i=${e%%:*}; v=${e##*:}
		if [ "$v" = "$lan_vid" ]; then lan_idx=$i; lan_n=$((lan_n + 1)); else wan_idx=$i; wan_vid=$v; wan_n=$((wan_n + 1)); fi
	done
	[ "$lan_n" = 1 ] && [ "$wan_n" = 1 ] || { say "  $lan_n LAN and $wan_n other switch VLANs: too unusual to rewrite"; return 1; }
	[ "$(uci -q get "network.@switch_vlan[$lan_idx].device")" = "$(uci -q get "network.@switch_vlan[$wan_idx].device")" ] \
		|| { say "  the LAN and WAN VLANs are on different switches; not rewriting"; return 1; }
	lan_ports=$(uci -q get "network.@switch_vlan[$lan_idx].ports"); wan_ports=$(uci -q get "network.@switch_vlan[$wan_idx].ports")
	[ -n "$lan_ports" ] && [ -n "$wan_ports" ] || return 1
	move=""
	for p in $wan_ports; do
		bare=${p%t}; bare=${bare%u}
		[ "$bare" = "$cpu_lan" ] && continue
		[ -n "$cpu_wan" ] && [ "$bare" = "$cpu_wan" ] && continue
		move="${move:+$move }$bare"
	done
	[ -n "$move" ] || { say "  the WAN VLAN holds only CPU ports; nothing to move"; return 1; }
	added=""
	for p in $move; do
		case " $lan_ports " in *" $p "*|*" ${p}t "*) continue ;; esac
		lan_ports="$lan_ports $p"; added="${added:+$added }$p"
	done
	[ -n "$added" ] || return 1
	uci set "network.@switch_vlan[$lan_idx].ports=$lan_ports"
	uci delete "network.@switch_vlan[$wan_idx]"
	say "  switch port(s) $added moved into VLAN $lan_vid; VLAN $wan_vid deleted"
	return 0
}

# ── --convert ──────────────────────────────────────────────────────────────
convert() {
	[ "$(id -u)" = 0 ] || die "must run as root"
	command -v uci >/dev/null 2>&1 || die "uci not found"
	case "$ADDR" in
		dhcp) ;;
		*/*) is_ipv4 "${ADDR%%/*}" || die "bad address: $ADDR"; prefix_to_netmask "${ADDR##*/}" >/dev/null || die "bad prefix: ${ADDR##*/}" ;;
		*) die "--address must be dhcp or <ip>/<prefix>" ;;
	esac
	[ -z "$GATEWAY" ] || is_ipv4 "$GATEWAY" || die "bad gateway: $GATEWAY"
	for d in $DNS; do is_ipv4 "$d" || die "bad DNS server: $d"; done

	# Backup first: what --revert restores.
	mkdir -p "$(dirname "$BACKUP")"
	files=""
	for c in $CFGS; do [ -f "/etc/config/$c" ] && files="$files etc/config/$c"; done
	# shellcheck disable=SC2086
	tar -C / -czf "$BACKUP" $files || die "could not write $BACKUP"
	enabled=""
	for svc in $SERVICES; do
		[ -x "/etc/init.d/$svc" ] && "/etc/init.d/$svc" enabled 2>/dev/null && enabled="$enabled $svc"
	done
	say "backup: $BACKUP"

	# Router interfaces go first: a netdev that is network.wan's and a bridge
	# port at the same time is a conflict netifd resolves by breaking one.
	WAN_DEV=$(uci -q get network.wan.device || uci -q get network.wan.ifname || true)
	for s in wan wan6; do
		uci -q get "network.$s" >/dev/null 2>&1 && { uci -q delete "network.$s"; say "  removed network.$s"; }
	done
	for s in $(uci show network 2>/dev/null | sed -n "s/^network\.\([^.=]*\)=interface$/\1/p"); do
		case "$s" in lan|loopback|globals) continue ;; esac
		case "$(uci -q get "network.$s.proto")" in
			pppoe|pppoa|3g|qmi|ncm|wwan|dhcpv6|modemmanager)
				say "  note: network.$s looks like another router uplink; left alone" ;;
		esac
	done

	# The WAN socket joins the LAN side (two different jobs, see setup.sh).
	has_swconfig=0
	command -v swconfig >/dev/null 2>&1 && swconfig list 2>/dev/null | grep -q Found && has_swconfig=1
	if [ "$KEEP_WAN" = 1 ]; then
		say "  WAN socket left out of the LAN as asked"
	elif [ "$has_swconfig" = 1 ] && absorb_wan_swconfig; then
		:
	elif [ -n "$WAN_DEV" ]; then
		LAN_DEV=$(uci -q get network.lan.device || true)
		BR_SECTION=""
		[ -n "$LAN_DEV" ] && BR_SECTION=$(uci show network 2>/dev/null | sed -n "s/^network\.\([^.=]*\)\.name='${LAN_DEV}'$/\1/p" | head -1)
		if [ -n "$BR_SECTION" ]; then
			case " $(uci -q get "network.$BR_SECTION.ports") " in
				*" $WAN_DEV "*) say "  $WAN_DEV is already in $LAN_DEV" ;;
				*) uci add_list "network.$BR_SECTION.ports=$WAN_DEV"; say "  $WAN_DEV added to the $LAN_DEV bridge" ;;
			esac
		elif [ "$(uci -q get network.lan.type)" = bridge ]; then
			CURIF=$(uci -q get network.lan.ifname || true)
			case " $CURIF " in
				*" $WAN_DEV "*) say "  $WAN_DEV is already bridged into lan" ;;
				*) uci set "network.lan.ifname=$CURIF $WAN_DEV"; say "  $WAN_DEV added to the lan bridge" ;;
			esac
		else
			say "  warning: no LAN bridge found; $WAN_DEV is not part of the LAN"
		fi
	else
		say "  no WAN device to absorb"
	fi

	# Management address.
	if [ "$ADDR" = dhcp ]; then
		uci set network.lan.proto=dhcp
		for o in ipaddr netmask gateway dns ip6assign ip6addr; do uci -q delete "network.lan.$o"; done
		say "  lan takes its address by DHCP"
	else
		uci set network.lan.proto=static
		uci set "network.lan.ipaddr=${ADDR%%/*}"
		uci set "network.lan.netmask=$(prefix_to_netmask "${ADDR##*/}")"
		uci -q delete network.lan.gateway; uci -q delete network.lan.dns
		[ -n "$GATEWAY" ] && uci set "network.lan.gateway=$GATEWAY"
		for d in $DNS; do uci add_list "network.lan.dns=$d"; done
		uci -q delete network.lan.ip6assign
		say "  lan is static: $ADDR${GATEWAY:+ via $GATEWAY}"
	fi
	uci commit network

	# DHCP server off (ignore=1: the canonical dumb-AP setting, one line to undo).
	if [ -f /etc/config/dhcp ]; then
		uci -q set dhcp.lan.ignore=1 2>/dev/null || true
		uci -q delete dhcp.wan
		uci commit dhcp
		say "  DHCP server disabled on lan"
	fi
	for svc in $SERVICES; do
		if [ -x "/etc/init.d/$svc" ]; then
			"/etc/init.d/$svc" disable >/dev/null 2>&1
			"/etc/init.d/$svc" stop >/dev/null 2>&1
			say "  $svc stopped and disabled"
		fi
	done
	mkdir -p /tmp/resolv.conf.d
	touch /tmp/resolv.conf.d/resolv.conf.auto
	ln -sf /tmp/resolv.conf.d/resolv.conf.auto /tmp/resolv.conf

	# lldpd's chassis id follows the LAN, or the controller shows a wrong Parent Device.
	if [ -f /etc/config/lldpd ]; then
		lan_name=$(probe_field modelmap.lan_name); [ -n "$lan_name" ] || lan_name=lan
		uci set "lldpd.config.cid_interface=$lan_name"; uci commit lldpd
		say "  lldpd chassis id follows '$lan_name'"
	fi

	# Radios: a fresh OpenWrt ships them disabled, and openUF writes that
	# option only when the controller pushes a radio status.
	enabled_radios=""
	for r in $(uci show wireless 2>/dev/null | sed -n "s/^wireless\.\([^.=]*\)=wifi-device$/\1/p"); do
		if [ "$(uci -q get "wireless.$r.disabled")" = 1 ]; then
			uci -q delete "wireless.$r.disabled"; enabled_radios="$enabled_radios $r"
		fi
	done
	[ -n "$enabled_radios" ] && { uci commit wireless; say "  enabled radios:$enabled_radios"; }

	# The stamp --check and --revert read.
	[ -f /etc/config/openuf ] || : > /etc/config/openuf
	uci -q delete openuf.convert
	uci set openuf.convert=convert
	uci set "openuf.convert.when=$(date +%s)"
	uci set "openuf.convert.backup=$BACKUP"
	for svc in $enabled; do uci add_list "openuf.convert.enabled_before=$svc"; done
	uci commit openuf
	say "converted: the changes are committed and take effect at the next reboot"
}

# ── --revert ───────────────────────────────────────────────────────────────
revert() {
	[ "$(id -u)" = 0 ] || die "must run as root"
	backup=$(uci -q get openuf.convert.backup 2>/dev/null)
	[ -n "$backup" ] || die "this device was not converted by openuf-convert (no stamp)"
	[ -f "$backup" ] || die "the backup $backup is gone; restore /etc/config by hand"
	tar -C / -xzf "$backup" || die "could not extract $backup"
	for svc in $(uci -q get openuf.convert.enabled_before 2>/dev/null); do
		[ -x "/etc/init.d/$svc" ] && "/etc/init.d/$svc" enable >/dev/null 2>&1 && say "  $svc enabled again"
	done
	uci -q delete openuf.convert
	uci commit openuf
	say "reverted: the router configuration is back and takes effect at the next reboot"
}

# ── main ───────────────────────────────────────────────────────────────────
MODE=""; ADDR=dhcp; GATEWAY=""; DNS=""; KEEP_WAN=0
while [ $# -gt 0 ]; do
	case "$1" in
		--check)   MODE=check ;;
		--convert) MODE=convert ;;
		--revert)  MODE=revert ;;
		--address) shift; [ $# -gt 0 ] || die "--address needs a value"; ADDR=$1 ;;
		--gateway) shift; [ $# -gt 0 ] || die "--gateway needs a value"; GATEWAY=$1 ;;
		--dns)     shift; [ $# -gt 0 ] || die "--dns needs a value"; DNS=$1 ;;
		--keep-wan-socket) KEEP_WAN=1 ;;
		-h|--help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) die "unknown option: $1" ;;
	esac
	shift
done
case "$MODE" in
	check)   check ;;
	convert) convert ;;
	revert)  revert ;;
	*)       sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
