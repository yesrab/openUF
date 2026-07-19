# openUF — Usage Guide

## 1. Dependencies

Install the following apk packages on the OpenWrt device before running openUF.
OpenWrt 25.12 replaced `opkg` with `apk`; on 24.10 and earlier substitute
`opkg update` / `opkg install`.

```sh
apk update
apk add lua lua-cjson luasocket lua-openssl luabitop iw lldpd openssl-util nftables usteer wpad-wolfssl
```

| Package | Purpose |
|---|---|
| `lua` | Lua 5.1 runtime |
| `lua-cjson` | Fast JSON encode/decode |
| `luasocket` | TCP client for HTTP POST to controller |
| `lua-openssl` | AES-128-CBC **and AES-128-GCM** (replaces `luacrypto`, which was dropped from the 25.12 feeds). Effectively mandatory — see the GCM note below |
| `luabitop` | bit operations for Lua 5.1 |
| `iw` | Radio and station statistics |
| `lldpd` | LLDP topology announcement and neighbor discovery |
| `openssl-util` | `openssl` CLI — last-resort AES-**CBC** fallback if `lua-openssl` is unavailable. This path cannot do GCM, so it is not sufficient to complete adoption on its own |
| `nftables` | Client block/unblock enforcement (`openuf/firewall.lua`) |
| `usteer` | Band Steering (Behavior Controls) — ubus-based client-steering daemon, driven by `openuf/usteer.lua` |
| `wpad-wolfssl` (or `wpad-openssl`) | Full hostapd build with 802.11k/v support — required for BSS Transition and Band Steering. `wpad-basic-*` lacks `bss_transition` entirely and errors with "unknown configuration item 'bss_transition'" |

`install.sh install` installs `usteer` and a full `wpad` build automatically if
either is missing (falling back from `wpad-wolfssl` to `wpad-openssl`), so a
manual `apk add` is only needed if you're not using the installer.

`hostapd_cli` (used to immediately deauthenticate a just-blocked wireless client,
and to enforce Minimum RSSI) is not a separate dependency — any device running a
wireless AP already has `hostapd` providing it.

> **AES-GCM is required for adoption.** UniFi Network Application 10.4.57 will
> not finish provisioning a device until it has received a genuine
> AES-128-GCM-encrypted inform; a device that can only do CBC stays stuck at
> "Adopting" indefinitely. openUF's GCM support needs a `lua-openssl` build with
> AEAD/GCM available — the `openssl-util` CLI fallback above is CBC-only and will
> not get you adopted. See PROTOCOL-VALIDATION.md's "The GCM provisioning gate".

There is no Lua zlib binding in the OpenWrt 25.12 feeds. openUF therefore sends
inform payloads uncompressed and decompresses zlib-compressed controller
responses with a bundled pure-Lua inflater (`openuf/inflate.lua`), so no zlib
package is required.

Only required if your inform URL uses `https://` (uncommon — the UniFi default
is `http://…:8080/inform`): `apk add luasec` for the TLS client. Without it, an
`https://` URL fails with a clear error instead of connecting in cleartext.

---

## 2. Installation

Download the latest release directly on the device over SSH — no git client or scp required:

```sh
# On the OpenWrt device
mkdir openuf-install && cd openuf-install
wget https://github.com/jonasevcik/openUF/releases/latest/download/openuf.tar.gz
tar xzf openuf.tar.gz
sh install.sh install
```

Optionally verify the download before installing:

```sh
wget https://github.com/jonasevcik/openUF/releases/latest/download/openuf.tar.gz.sha256
sha256sum -c openuf.tar.gz.sha256
```

Releases are tagged `vX.Y.Z`; each tag push builds and publishes a new `openuf.tar.gz` via
GitHub Actions. If you're working from a git checkout instead (e.g. for development), the old
transfer-then-install flow still works:

```sh
# From your development machine
scp -r openuf/ install.sh root@<device-ip>:/tmp/openuf/
ssh root@<device-ip> "cd /tmp/openuf && sh install.sh install"
```

What `install.sh install` does:
- Copies `openuf/` to `/opt/openuf/`
- Creates `/etc/openuf/` (state directory)
- Symlinks `/opt/openuf/hook/syswrapper.sh` → `/usr/bin/syswrapper.sh`
- Creates `/etc/init.d/openuf` with two procd service instances (announce + inform)
- Enables and starts the service
- Enables and starts `lldpd`

To uninstall:
```sh
sh install.sh uninstall
```

---

## 3. Configuration

### Hardware model map (`openuf/conf.lua`)

Select the modelmap that matches your hardware:

```lua
-- For TP-Link WDR3500, Archer C5 v1, or any dual-band OpenWrt AP:
dev = dofile("modelmap/generic-dualband-ap.lua")

-- For TP-Link WR1043ND v2 (single-band):
dev = dofile("modelmap/tl-wr1043ndv2.lua")
```

The modelmap sets:
- `dev.conf.net.lan_cpueth` — LAN CPU ethernet port (e.g. `eth1`); also the trunk port
  used to create VLAN-tagged sub-interfaces (`eth1.<vlanid>`) for controller-pushed VLAN SSIDs
- `dev.conf.net.wan_iface`  — WAN interface (e.g. `eth0`)
- `dev.conf.switch`         — Switch device name (e.g. `switch0`)
- `dev.conf.led`            — status LED, driven by the controller's Locate action and its
  **Manage → LED** toggle. Accepts a full sysfs path (`/sys/class/leds/tp-link:green:wlan`)
  or a bare LED name (`tp-link:green:wlan`). `nil` by default, since a generic profile can't
  know the board's LED — LED control is a silent no-op until you set it. Find yours with
  `ls /sys/class/leds`
- `dev.openuf.uap.ufmodel`  — Which ufmodel file to load (e.g. `"u6iw"`)
- `dev.openuf.uap.hwassign` — Radio names (e.g. `{"radio0", "radio1"}`)

### Device identity (`openuf/ufmodel/u6iw.lua`)

The U6-InWall identity is configured in `ufmodel/u6iw.lua`.  The firmware version
(`fw.ver`) must be accepted by your controller.  If the controller rejects the
device with "firmware too old" or similar, increment `fw.ver` and try again.

```lua
uap = {
    platform = "U6IW",
    model    = "U6IW",
    fw = {
        pre        = "U6IW.",
        ver        = "6.6.55",    -- tune this if the controller rejects the device
        buildtime  = "230801.1200",
        factoryver = "6.5.28"
    },
    ...
}
```

### Paths and options (`openuf/conf.lua`)

```lua
config = {
    use_only_unifi_wlan = true,  -- disable non-openuf_ SSIDs during provisioning
    inform_url  = "http://unifi:8080/inform",   -- default URL (overwritten at adoption)
    state_file  = "/etc/openuf/state.json",
    debug_dump_file = nil,       -- see below
    bootstrap_adopt_user = nil,  -- see below
}
```

`debug_dump_file` — opt-in, off by default. When set to a path (e.g.
`"/var/log/openuf-informs.log"`), every decrypted controller inform response is
appended verbatim, with a UTC timestamp, before it's dispatched. Used to capture
ground-truth payload shapes when validating field assumptions (`system_cfg`,
`cmd` dispatch, etc.) against a real UniFi controller — see
[PROTOCOL-VALIDATION.md](PROTOCOL-VALIDATION.md).

The same flag also turns on a **dropped-key report** on stderr: one line per
config blob listing the keys no parser consumed, collapsed to key shapes with
counts, e.g.

```
inform: mgmt_cfg: 5 dropped key(s): capability x1, mgmt_url x1, report_crash x1, selfrun_guest_mode x1, stun_url x1
inform: system_cfg: 12 dropped key(s): switch.port.<n>.name x5, switch.vlan.<n>.id x4, ...
```

Most of what it lists is dropped deliberately (each case is explained in
PROTOCOL-VALIDATION.md's `system_cfg` section) — its value is showing you when
the controller starts sending something openUF has *never* seen, which is how
two whole features sat unnoticed in every capture for months. Key names and
counts only: these blobs carry passphrases and the adoption key, so no value is
ever logged.

`bootstrap_adopt_user` — set by `install.sh install --bootstrap-adopt`, not by
hand. Names the temporary SSH bootstrap account (see § SSH prerequisite below)
that `inform.lua` should lock/unlock as the device's adopted state changes.

---

## 4. Adoption flow

### SSH prerequisite

The controller SSHes into the device as `root` to run `syswrapper.sh set-adopt` during adoption.  **SSH must be accessible and the root password must be set** before clicking Adopt:

```sh
# On the OpenWrt device — set a root password if not already done
passwd root
```

Confirm SSH works from the controller's network before attempting adoption.  A fresh OpenWrt install often has a blank root password and SSH enabled; set the password first.

> **Security note:** openUF accepts a new `authkey` from the `mgmt_cfg` payload
> only while **not yet adopted** (needed for L3 adoption to complete at all — see
> the L3 section below and [PROTOCOL-VALIDATION.md](PROTOCOL-VALIDATION.md)).
> Once adopted, that field is ignored — key rotation only happens via the SSH
> `set-adopt` path from that point on, matching real L2 hardware behavior.

#### Optional: zero-touch bootstrap adoption (`--bootstrap-adopt`)

Real Ubiquiti hardware ships a factory-default `ubnt`/`ubnt` SSH account
specifically so first adoption works without presetting anything — live testing
against a real controller (see PROTOCOL-VALIDATION.md) confirmed the controller's
SSH client tries exactly that account for L2-discovered, not-yet-adopted devices,
regardless of any admin-configured "Device SSH Authentication" credentials.
`install.sh install --bootstrap-adopt` sets up the same thing, scoped as tightly
as this project can manage:

```sh
sh install.sh install --bootstrap-adopt
```

- The account is **non-root**, a member of a dedicated `openuf` group with
  write access to `/etc/openuf` only — no other privilege, ever, even
  transiently.
- Its login shell (`openuf/hook/adopt-shell.sh`) is a forced-command wrapper
  that permits exactly one thing: running `syswrapper.sh set-adopt <url>
  <key>`. Any other command, or a plain interactive login attempt, is refused
  outright — the account can never be used as a general-purpose shell.
- Once the device is adopted, `inform.lua` locks the account (`passwd -l`) —
  it detects this within one poll interval (~10s) of the SSH-driven
  `set-adopt` writing new state. It re-enables the account automatically on
  a factory reset (`reset-inform`, or a controller-initiated "Forget Device"),
  so re-adoption after a reset works the same zero-touch way.
- This is entirely opt-in: a plain `install.sh install` (no flag) never
  creates this account and behaves exactly as documented above — the admin
  sets their own root password.

`uninstall` always removes the bootstrap account if present, regardless of
whether `--bootstrap-adopt` is passed to it.

### L2 adoption (device and controller on the same subnet)

1. Start openUF (`/etc/init.d/openuf start` or `sh install.sh install`)
2. The `announce.lua` process sends UDP broadcasts to port 10001 every 10 seconds
3. The device appears in **UniFi Discover** with model "U6IW"
4. Click **Adopt** in the controller
5. The controller SSHes into the device and runs:
   ```sh
   syswrapper.sh set-adopt http://<controller>:8080/inform <32-char-hex-key>
   ```
6. `syswrapper.lua` stores the new authkey and sets `adopted = true` in `/etc/openuf/state.json`
7. The device appears as **Connected** in the controller

### L3 adoption (device and controller on different subnets)

1. Manually point the device at the controller:
   ```sh
   syswrapper.sh set-inform http://<controller-ip>:8080/inform
   ```
2. The device starts sending inform packets to the controller
3. It appears as **Pending** in the controller
4. Click **Adopt**

> **No SSH is involved in L3 adoption.** For **L3-discovered** devices the
> controller explicitly logs `discovered via L3 inform, skip SSH adoption` and
> never attempts SSH at all — unlike the L2 flow documented above. It delivers
> the new `authkey` directly in the `mgmt_cfg` field of the `setparam` response
> sent right after the Adopt click — confirmed against a real controller
> (`linuxserver/unifi-network-application:10.4.57`), reproduced from a clean
> environment. openUF's `inform.lua` accepts this only while unadopted, matching
> `amd989/unifi-gateway`'s reference behavior. Adoption completes to
> **Connected** — provided the device can encrypt with AES-GCM (see § 1). An
> earlier version of this guide reported every newly-adopted device getting stuck
> at "Adopting"; that was the missing GCM backend, not a controller-side issue,
> and it is resolved — see [PROTOCOL-VALIDATION.md](PROTOCOL-VALIDATION.md).

---

## 5. State file

Persistent state is stored at `/etc/openuf/state.json`:

```json
{
  "adopted":    false,
  "authkey":    "ba86f2bbe107c7c57eb5f2690775c712",
  "cfgversion": "",
  "inform_url": "http://unifi:8080/inform",
  "use_gcm":    false,
  "upgrade_requested_version": "",
  "upgrade_requested_url":     "",
  "blocked_stas": []
}
```

| Field | Description |
|---|---|
| `adopted` | `true` after successful adoption; `false` resets `authkey` to default on load |
| `authkey` | 32 hex chars (16-byte AES-128 key); default = pre-adoption key |
| `cfgversion` | Opaque string the controller uses to push config updates |
| `upgrade_requested_version` / `upgrade_requested_url` | Set when the controller sends an `upgrade` command; stored for visibility only — openUF never downloads or flashes firmware (see below) |
| `inform_url` | URL for the 10-second inform heartbeat |
| `use_gcm` | `true` when the controller has requested AES-128-GCM encryption (`use_aes_gcm=true` in mgmt_cfg) |
| `blocked_stas` | MACs blocked from the controller's Clients view; re-applied to nftables on startup so blocks survive restarts |
| `swvlan_backup` | Original `ports` strings of the stock `switch_vlan` sections, snapshotted before per-port VLAN assignment first modifies them; used to restore them (see § 6) |
| `ip_mode`, `static_ip`, `static_netmask`, `static_gateway`, `static_dns` | The last "IP Settings" push. `ip_mode` is `"static"` or `"dhcp"`; the `static_*` fields are set only in static mode and cleared on a revert to DHCP. `static_dns` is an array in the controller's primary/secondary order, written to `/etc/resolv.conf`. On DHCP, DNS is left to the lease and openUF does not touch `resolv.conf` |

To reset to factory defaults:
```sh
syswrapper.sh reset-inform
```

---

## 6. WiFi provisioning

When the controller pushes a config, `ucihelper.lua` applies it via OpenWrt UCI.  Only sections prefixed with `openuf_` are created or deleted.

`use_only_unifi_wlan` (default `true`) additionally sets `disabled=1` on every *other* `wifi-iface`, so the radios carry only what the controller provisioned.  openUF stamps each SSID it turns off with `openuf_autodisabled=1`; setting the option back to `false` re-enables exactly those and leaves everything else as-is, so an SSID you had disabled yourself is never switched back on.  Set it to `false` from the start to keep hand-configured SSIDs broadcasting alongside the controller's.

Settings carried through from the controller:

| Controller setting | Applied as |
|---|---|
| SSID, passphrase, security | `wifi-iface` ssid/key/encryption |
| Hide WiFi Name | `hidden` (hostapd `ignore_broadcast_ssid`) |
| MAC Address Filter | `macfilter` (`disable`/`allow`/`deny`) + `maclist` |
| WiFi Speed Limit | `tc` shaping per VAP, not a hostapd option (plus `openuf_ratelimit_down`/`openuf_ratelimit_up` on the section for visibility) |
| WPA2 / WPA3 / WPA2-WPA3 mixed | derived from the pushed AKM set, not a single flag |
| WPA-Enterprise (802.1X) | **not supported** — the WLAN is skipped and logged. The wire protocol carries no RADIUS server/port/secret to write, so there is nothing openUF could provision |
| PMF (802.11w) | `ieee80211w` (0 disabled / 1 optional / 2 required) |
| Fast Roaming (802.11r) | `ieee80211r` |
| BSS Transition (802.11v) | `bss_transition` — **needs a full `wpad` build** |
| Band Steering | `usteer` config, not a hostapd option |
| Auto/Custom DTIM Period | `dtim_period` |
| Multicast Enhancement | `multicast_to_unicast` |
| Minimum Data Rate | per-**radio** `basic_rate` / `supported_rates` / `legacy_rates` / `beacon_rate` |
| Multicast and Broadcast Blocker | nftables rules, not a hostapd option (plus `openuf_bcfilt`/`openuf_bcfilt_macs` on the section for visibility) |
| Proxy ARP | `proxy_arp` — **needs a full `wpad` build** |
| Client Isolation | `isolate` (hostapd `ap_isolate`) |
| Network / VLAN assignment | a `br0.<vlan>` bridge + tagged sub-interface |
| Channel, TX power | `wifi-device` channel/txpower |
| Radio enable/disable (TX Power → Disabled) | `wifi-device` `disabled`; the radio's WLANs get `wifi-iface` `disabled` too, keeping their config for a later re-enable |
| Channel width | `wifi-device` htmode, from the radio's `ieee_mode` token |
| IoT Optimization: Lock 2.4 GHz to Channel 6 | nothing new — arrives as `channel=6` on the 2.4 GHz radio |
| IoT Optimization: DTIM Interval Lock | nothing new — arrives as `dtim_period=3` on the 2.4 GHz SSID |
| IoT Optimization: Force WiFi 4 Mode | `bss_load_update_period=0` (suppresses the QBSS Load IE) + an `openuf_iot` marker |
| Minimum RSSI | per-**radio**; enforced by openUF deauthenticating clients below the threshold, not by hostapd |
| Per-port VLAN (Ports → *port* → Native VLAN) | swconfig `switch_vlan` sections named `openuf_swvlan<id>` — see below |

**Per-port VLAN assignment** must be switched on twice: once on the device
(Devices → *AP* → Settings → IP Settings → **Port VLAN**, which is what flips the wire's
`switch.status`/`switch.vlan.status` gates), then per port under **Ports**. Until the
device-level box is ticked the per-port VLAN controls stay greyed out and nothing reaches
the wire.

openUF applies it only on **swconfig** boards (ath79-era). It writes one
`config switch_vlan` section per VLAN, named `openuf_swvlan<id>`, translating the
controller's `untagged`/`tagged`/`exclude` per-port modes into swconfig's port syntax
(`1`, `1t`, omitted) with the CPU port always tagged in. On a DSA board (OpenWrt 21.02+,
where this would be `config bridge-vlan`) it logs and does nothing rather than emitting
config nobody has verified.

Three things must line up or the port is skipped rather than guessed at:

- `dev.conf.vlan` must exist in your modelmap (`cpu_lan` + a `ports` name→number map).
  Without it openUF has no idea what the physical switch ports are, and guessing strands
  the device.
- the port needs a `swport` in `dev.conf.net.ports`, naming its `dev.conf.vlan.ports` key.
- the port must not be the uplink — reassigning the uplink's VLAN would cut the device off
  the network, so that is refused outright.

Because assigning a port to a VLAN means removing it from the stock VLAN's port list,
this is the one place openUF modifies UCI sections it did not create. It snapshots their
original `ports` strings into `state.json` (`swvlan_backup`) before the first change, and
`switchvlan.restore()` puts them back. Inspect the result with `uci show network` and
`swconfig dev switch0 show`.

> The generated UCI is unit-tested, but **openUF has no switch hardware to verify against** —
> that these sections actually program the switch ASIC, and that
> `/etc/init.d/network reload` behaves on real ath79, are unconfirmed.

The **Multicast and Broadcast Blocker** has no hostapd or OpenWrt equivalent — hostapd
can suppress group-addressed frames wholesale but has no notion of an allow-list — so
openUF enforces it with nftables, in its own `bridge openuf_bcfilt` table (separate
from the client-blocking `bridge openuf` table, which is rebuilt wholesale on every
block/unblock and would otherwise wipe these rules). Frames leaving a filtered SSID are
dropped unless the *sender's* MAC is allow-listed.

> **This deliberately breaks DHCP for wireless clients unless you add the DHCP server's
> MAC to the excepted-devices list.** That is Ubiquiti's own documented behavior for
> this control, so openUF reproduces it faithfully rather than adding DHCP/ARP
> exemptions of its own — a silent exemption would be harder to debug than the
> documented breakage. Inspect the live rules with `nft list table bridge openuf_bcfilt`.

**Minimum Data Rate** is set per WLAN in the controller but OpenWrt's rate options
(`basic_rate`, `supported_rates`, `legacy_rates`, `beacon_rate`) are `wifi-device`
options, so two WLANs sharing a radio cannot each get their own floor. openUF applies
the most permissive of them — the lowest floor, CCK still allowed if any WLAN allows
it — because the stricter choice would silently lock clients out of a co-hosted WLAN
that was meant to admit them. Give a WLAN its own radio if it needs its floor enforced
exactly. Note also that the floor is enforced by making it the sole *basic* rate (a
station must support every basic rate to associate); the "advertising rates" sub-toggle
additionally trims `supported_rates`.

Minimum RSSI is a *radio* setting in the controller UI (Devices → AP → Radios), not a per-WLAN one, and the wire value is an offset from an assumed noise floor rather than a dBm figure — openUF converts it using a live noise reading.

The **IoT Optimization** panel (Settings → WiFi → *WLAN* → IoT Optimization) is mostly controller-side sugar: two of its three toggles just set values the protocol already had — channel 6 on the 2.4 GHz radio, and DTIM 3 — so they need no dedicated support. "Force WiFi 4 Mode" additionally drops the WLAN's 5 GHz vap, pins WPA2, and turns off PMF, BSS Transition, proxy ARP, fast roaming and band steering; those all arrive as their ordinary keys. Note that it does *not* narrow the radio: the shared 2.4 GHz radio keeps whatever channel width it is configured for, so `htmode` is untouched.

To verify provisioned SSIDs:
```sh
uci show wireless | grep openuf_
```

To remove all provisioned SSIDs:
```sh
lua -e "dofile('/opt/openuf/ucihelper.lua').wlan_clear()"
# or simply reset-inform and re-adopt
```

---

## 7. LLDP topology

`lldpd` must be running for topology announcements to work.  openUF queries `lldpctl -f json` and includes the neighbor table in each inform payload so the controller can render the upstream switch on its topology map.

Check LLDP status:
```sh
lldpctl          # show neighbors
lldpctl -f json  # JSON output (what openUF reads)
```

If `lldpd` is absent or returns no neighbors, `lldp.lua` returns an empty table — non-fatal.

---

## 8. Troubleshooting

| Symptom | Likely cause |
|---|---|
| Device doesn't appear in UniFi Discover | `announce.lua` not running, or UDP port 10001 blocked |
| Controller shows device as "Disconnected" | `inform.lua` not running, or wrong `inform_url` |
| Adoption fails with SSH error | SSH not reachable from controller, or root password not set — run `passwd root` on the device, or reinstall with `--bootstrap-adopt` |
| Device stays stuck at "Adopting" forever | No AES-GCM backend — `lua-openssl` missing or built without AEAD support. The CLI `openssl-util` fallback is CBC-only and will not work (see § 1) |
| Controller rejects device ("firmware incompatible") | Adjust `fw.ver` in `ufmodel/u6iw.lua` |
| hostapd fails: "unknown configuration item 'bss_transition'" | A `wpad-basic-*` build is installed — replace it with `apk add wpad-wolfssl` |
| Band Steering has no effect | `usteer` not installed or not running — `/etc/init.d/usteer status` |
| Locate/LED does nothing | `dev.conf.led` is `nil` in your modelmap — set it to a path from `ls /sys/class/leds` |
| JSON decode error in controller logs | AES key mismatch — try `syswrapper.sh reset-inform` |
| SSID not appearing after adoption | Check `uci show wireless`, check `loglevel` in `/var/log/openuf.log` |
| `lldp_table` empty | `lldpd` not running — run `/etc/init.d/lldpd start` |
| Bootstrap account (`ubnt`) doesn't lock after adoption, or doesn't re-enable after a factory reset | `inform.lua` must be running for this — it's what detects the state change and runs `passwd -l`/`-u` (see § SSH prerequisite). Check `/var/log/openuf.log`. |

Log file: `/var/log/openuf.log`

For development testing without hardware, see `tools/test_controller.py`.
