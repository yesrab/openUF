# openuf/rrb: the 802.11r translator for genuine UniFi APs

`rrb-unifi.uc` is d-malinowski's **rrb-unifi** translator, vendored into openUF
from https://github.com/d-malinowski/unifi-openwrt-roaming at version 1.3
(commit `767a28c`, taken 2026-10-25). It runs as the `openuf-rrb` service
(`openuf/etc/init.d/openuf-rrb`) and is what makes openUF's `unifi_ft_interop`
switch work against real UniFi access points: UniFi's hostapd frames the
inter-AP key exchange (RRB, ethertype 0x88b7) with 12 extra bytes, and this
daemon converts between the two framings on a veth pair that openUF creates
(`ucihelper.ensure_ft_veth`). It also speaks UniFi's roam announcements.

**Upstream is that repository, not a fork.** Fixes and updates are taken from
it; the local clone at `../unifi-openwrt-roaming` carries it as the `upstream`
remote. Every change made here is marked `// openUF:` in the file so a diff
against upstream stays readable. The changes:

- `RRB_WAIT=0` (the service always sets it) waits for the veth pair and for a
  BSS on it indefinitely instead of exiting; openUF creates the veth on the
  first config push that carries an FT WLAN.
- `RRB_PEERS_FILE` (`/var/run/openuf/rrb-peers.json`): every UniFi BSSID heard
  on the LAN is recorded as JSON, with its mobility domain once a roam
  announcement verified with that WLAN's key names it. `ftinterop.lua` reads it
  and writes those BSSes into hostapd's key holders on the next push, so nobody
  has to read them off the UniFi AP over SSH. `openuf rrb collect` still exists
  for that, as a check.
- `check` prints the version first.

Both daemon changes were offered to upstream as a pull request on 2026-10-25
(from the fork `yesrab/unifi-openwrt-roaming`, branch `feature/openUFHook`), in
the same form minus this header and the version line: `option wait '0'` and
`option peers_file`. Once merged there, the next re-vendoring carries only the
header and the version line as local differences.

The standalone setup tool (`rrb-unifi-setup`) is not vendored: `install`,
`apply`, `uninstall` and `confirm` are openUF's job here, and its `collect`,
`verify` and `peers` live on as `openuf rrb collect|verify|peers`
(`openuf/hook/openuf-rrb.sh`, adapted from it).

License: GPL-3.0-or-later, the same as the rest of openUF since 2026-10-25
(the repository's LICENSE; the copyright holders are listed in NOTICE).
