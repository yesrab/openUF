# Protocol validation findings

openUF's assumptions about the UniFi inform protocol were originally inferred from
third-party reference material — [amd989/unifi-gateway](https://github.com/amd989/unifi-gateway)
and [paultyng/go-unifi](https://github.com/paultyng/go-unifi) — never checked against a
real UniFi Network Application. This document is the project's own ground truth,
established by running openUF against a real self-hosted controller, capturing decrypted
inform responses (`debug_dump_file`, see [USAGE.md](USAGE.md#3-configuration)), and
decompiling the controller's own Java bytecode and React bundles.

**Where this document and the third-party references disagree, this document wins.**
In particular, go-unifi models the controller's *admin REST API*, which is a different
surface from the inform wire protocol — several fields that exist there
(`dtim_mode`) have no counterpart on the wire. `bandsteering_mode` and the Roaming Assistant
do have one, but only for a device that claims `wifi_caps` bit `0x4` and `wifi_caps2` bit
`0x20` respectively -- see [Capability bitmasks](#capability-bitmasks).

This is a **reference for the confirmed current state**, not a lab journal. Superseded
hypotheses and the investigation trails that produced these facts have been removed;
git history has them if needed. Decompiled evidence is retained inline wherever a claim
would otherwise be hard to re-verify.

**Environments:**

- `lscr.io/linuxserver/unifi-network-application:10.4.57` (Docker, pinned), with openUF as
  the AP in a disposable Alpine container on the same Docker network (`tools/validation/`).
  Mocked `uci`/`ubus`, no radios.
- **Real hardware, 2026-07-28:** a TP-Link Archer C5 v1 (OpenWrt 25.12.5, ath79/mips_24kc,
  ath9k 2.4GHz + ath10k 5GHz) adopted by a **UniFi Cloud Gateway Ultra running Network
  10.4.57** — the same version as the Docker baseline, so the two are directly comparable.
  See [the first real-hardware run](#the-first-real-hardware-run) for what only appears
  once genuine `netifd`/`hostapd`/radios are in the loop.

**Status:** adoption, provisioning, and every UI-surfaced feature listed in the
[feature matrix](#feature-matrix) are confirmed working end-to-end against a real
controller, except where a row says otherwise. Adoption, the WiFi config push, live
clients and the radios themselves are additionally confirmed on real hardware.

---

## Validation environment

Everything in this section is about `tools/validation/`, not about openUF's product code.
Real OpenWrt target hardware has genuine `uci`/`iw`/`ubus`/`hostapd` and hits none of it.

### Required setup, in order

1. **`lua-openssl` must be present in the AP container.** Without an AES-GCM backend the
   controller will never provision the device — see
   [the GCM provisioning gate](#the-gcm-provisioning-gate). `tools/validation/ap/Dockerfile`
   builds the `zhaozg/lua-openssl` rock (`luarocks-5.1 install openssl`); no prebuilt Alpine
   apk exists. `install.sh` already installs `lua-openssl` on real OpenWrt hardware.
2. **Set the Inform Host Override before adopting anything.** Devices → Device Updates and
   Settings → Device SSH Settings. It must be the controller container's **literal IP** —
   the controller rejects a bare hostname with `ERROR inform - dev[<mac>] invalid inform_ip
   <hostname>`. This setting lives in the controller's own DB and is wiped by every
   `docker compose down -v`.
3. **Set a Device SSH Authentication password** (≥12 characters, enforced by the controller's
   own validator). Needed for L2/SSH adoption.

Skipping (2) presents as adoption silently stalling: `state.json` never flips
`adopted: true`, and `server.log` logs `inform decryption failed with defaultAuthKey=false`
— the controller *did* issue a per-device key, but the device never received a usable
config push. That is a setup omission, not a new bug.

### Always reset fully; never patch live state

Validation runs start from `docker compose down -v && docker compose up -d --build`.
Hand-editing a running container's `state.json`, or a device doc in Mongo, produces
results that do not reproduce — see [the minidev cache](#the-minidev-cache-never-sees-external-writes).

### The mocks, and their one sharp edge

The Alpine container has no `uci`, `ubus`, `iw`, `bridge`, or `hostapd`. Four
validation-only shims stand in, all outside `openuf/`:

| Shim | Stands in for | Notes |
|---|---|---|
| `ap/uci-mock.lua` | `require("uci")` | Installed at `/usr/local/share/lua/5.1/uci.lua`. Seeded with `radio0`/`radio1` `wifi-device` sections matching `generic-dualband-ap.lua`'s `hwassign`. |
| `ap/ubus-mock.sh` | `ubus call network.wireless status` | Static `radio0`→`wlan0`, `radio1`→`wlan1` map. |
| `ap/iw-mock.sh` | `iw dev … survey/station/scan dump` | Three fake stations with independently growing counters, plus fake neighbour BSSes. |
| `ap/bridge-mock.sh` | `bridge fdb show` | Two fake wired hosts; `entrypoint.sh` seeds `/proc/net/arp` via `ip neigh replace` (kernel state can't be baked into an image layer). |

**`uci-mock.lua` is in-memory only, per process.** Its `db` table is seeded fresh at
process start and only ever one-way dumped to a debug JSON file on `commit()` — never read
back. Consequences:

- Restarting `inform.lua` to pick up code changes **wipes any WiFi network config that was
  only ever pushed to the previous process's memory.** Recreate the WLAN in the controller
  UI afterwards to force a fresh `system_cfg` push.
- A throwaway `lua5.1 script.lua` invocation gets its own pristine mock state and proves
  nothing about the running daemon. **The only reliable way to check live wire data is to
  read what the controller actually received** (Mongo, or the REST API), never a fresh
  local script.

### Other environment facts

- **`cap_add: [NET_ADMIN]`** is required on the `ap` service — `netconfig.lua`'s `ip addr
  add`/`ip route replace` and `firewall.lua`'s `nft` both fail with `Operation not
  permitted` without it. Docker drops the capability by default even for root.
- **A `docker stop`/`start` of an AP container yields a fresh MAC from Docker**, so a
  restarted container is a brand-new device to the controller. Convenient for producing
  fresh adoption targets; means a stopped device's controller entry can never be resumed.
- **`ap2` compose service** (`replacement` profile) provides a second same-model device for
  the replace/clone flows; recipes in `tools/validation/README.md` §6.
- A `reboot` handled inside the container genuinely exits the container (no init to survive
  it). `docker start` the stopped — not removed — container to recover logs.
- Background `127.0.0.1:9080/api/ucore/manifest` and `get-ulp-manifest` connection-refused
  errors appear in `server.log` regardless of device activity. Pre-existing and harmless.

---

## The first real-hardware run

2026-07-28, Archer C5 v1 + UniFi Cloud Gateway Ultra (Network 10.4.57). Everything below
is what the Docker environment structurally *cannot* show: it mocks `uci`/`ubus` and has no
radios, so a config that `apply_config` writes "successfully" is never handed to `netifd`,
`hostapd`, or a regulatory domain. Three of the four findings are of the same shape — UCI
that reads perfectly and not one SSID on the air.

### The discovery path decides the adoption method, not the subnet

A controller that has heard a device's L2 broadcasts adopts it **by SSH**, even when it sits
on the controller's own subnet and its informs are landing perfectly. On the Adopt click the
gateway opened three SSH connections to the AP within 20 seconds:

```
dropbear[3746]: Child connection from 192.0.2.1:33114
dropbear[3746]: Login attempt for nonexistent user from 192.0.2.1:33114
```

and, failing them, parked the device at **Connection Interrupted** while the inform loop kept
running normally. The device record remembers this: removing it, stopping the broadcaster
(`config.l2_announce = false`), and letting the device re-appear from L3 informs alone made
the very next Adopt click complete over the inform channel with no SSH attempted at all.

So a device that cannot accept the controller's SSH login (no password auth, no bootstrap
account) **must** have `l2_announce` off, regardless of topology. "L3 adoption" names how the
controller discovered the device, not where it is.

### `macfilter="disable"` takes both radios off the air

OpenWrt's own schema (`/usr/share/schema/wireless.wifi-iface.json`) declares the option as
`enum: ["allow","deny"]`. 25.12's ucode validator does not ignore an out-of-enum value — it
aborts the radio setup:

```
wifi-scripts: macfilter: disable has to be one of [ "allow", "deny" ]
netifd: radio0 (4179): Died   (validate.uc:47 → die())
```

openUF wrote `macfilter="disable"` whenever the MAC filter was off, i.e. by default, so
**every** config push killed both radios. "Off" is the absence of the option: `ap.uc`'s
`iface_macfilter()` emits `accept_mac_file`/`deny_mac_file` for the two enum values and
returns for anything else. Fixed by deleting the option instead.

### `beacon_rate` is fatal on a driver that cannot program it

hostapd does not treat an unsupported beacon rate as a hint:

```
nl80211: Driver does not support setting Beacon frame rate (legacy)
Failed to set beacon parameters
Interface initialization failed
```

The 2.4GHz ath9k radio never came up, while the ath10k 5GHz radio — which the controller sent
no `beacon_rate` for — was fine. The capability is `NL80211_EXT_FEATURE_BEACON_RATE_LEGACY`,
reported **per phy** in `iw phy`'s "Supported extended features" list; neither phy on this
board has it. openUF now gates the option on that flag and still applies the rate floor
itself (`basic_rate`/`supported_rates`), which needs no driver support.

### The regulatory domain arrives as a numeric code, and nothing was applying it

`get_radio_table` has always *read* UCI `country` to derive the payload's `country_code`, but
nothing ever wrote it — so the radios kept whatever regdomain OpenWrt booted with while
reporting `840`/US back (the fallback when the option is unset). On the wire it is an
**ISO 3166-1 numeric** code, sent both unindexed and per radio:

```
radio.countrycode=203
radio.1.countrycode=203      # radio.1.phyname=radio0
radio.2.countrycode=203      # radio.2.phyname=radio1
```

UCI wants alpha-2, so 203 → `CZ`. Applying it moved the device from `country US: DFS-FCC` to
`country CZ: DFS-ETSI` and the 2.4GHz radio to channel 13 — legal in CZ, not in the US.

Worth knowing for anyone reading channel numbers off a live AP afterwards: with
`channel=auto` (which is what the controller sends unless a channel is pinned) hostapd ACS
picks freely within the new domain, and its choice can be a poor one in practice — it landed
on 5GHz channel 165, which CZ caps at **13 dBm**, and on 2.4GHz channel 13, which plenty of
client devices refuse outright. The controller's site-level Channel Plan exclusions are not
on the wire; pinning the channel per radio in the device's Radios settings is the remedy, and
that push (Auto → 6 / 36) was confirmed reaching UCI and the live radios within one inform
cycle.

### What the real controller sends that the Docker one did not

`radio.<n>.ieee_mode` came through as **`11naht40`** (5GHz) and **`11nght20`** (2.4GHz) — HT,
not HE, even though the device presents as an 802.11ax U6-InWall. openUF's downward clamp of
the PHY generation was therefore never triggered on this site; it remains insurance for a
site configured with wider/newer channel widths, not a confirmed-exercised path.

WPA2/WPA3 transition with PMF Optional arrives as `aaa.<n>.wpa=2` +
`wpa.key.1.mgmt=WPA-PSK` + `pmf.status=enabled` + `pmf.mode=1` — no SAE key-mgmt on the wire
at all, confirming the earlier Docker-era note that this controller signals WPA3-mixed purely
through PMF for a madwifi-driver model.

---

## The ports an AP reported were the CPU's, not the board's — FIXED

2026-08-02, two APs on the real UCG Ultra: a TL-WDR3500 (`Bedroom AP`) and an Archer C5 v1
(`Living room AP`). The Ports view showed **one port per AP**, and the number on it was
wrong. The investigation started from the user's own reading of the UI — only the uplink is
listed, and what is listed looks like it came from the gateway.

What the controller held for each AP (`/proxy/network/api/s/default/stat/device`):

```
port_table: [{port_idx:1, is_uplink:true, speed:1000, full_duplex:true, name:"PoE Out + Data"}]
ethernet_table: []      lldp_table: []
uplink: {..., uplink_remote_port:4, uplink_source:"lldp_downlink"}
```

Three separate things were wrong, all of them on the openUF side:

- **The speed was the CPU port's.** Both modelmaps declared a single port naming the CPU
  netdev, whose link is the internal SoC↔switch one — always `1000/full`. The Bedroom AP's
  actual uplink socket had negotiated 100baseT: `swconfig dev switch0 port 4 get link` said
  `speed:100baseT`, and the gateway's own row for the same cable said **FE** while the AP's
  row said **GbE**. A metric that contradicts the device on the other end of the wire.
- **The other sockets did not exist.** Both boards had live links on sockets the controller
  never heard of (the Archer C5 had three sockets up, of which one was reported).
- **Wired clients were attributed to the gateway.** Two hosts plugged into the APs' own LAN
  sockets showed up as `last_uplink_name: "Cloud Gateway Ultra"`, `sw_port` 2 and 4,
  `sw_depth: 1` — the gateway learned them through its downlink and, since the AP they sit
  behind reported no downstream port at all, the gateway's account was the only one.

The old code's premise was that MAC↔socket mapping "is knowable only from the switch's own
ARL table, which openUF does not read". The fix is that it now does. One
`swconfig dev switch0 show` returns per-port `link`/`pvid`, the ARL table, and (driver
permitting) per-port MIB counters — see the [`port_table[]` entry](#port_table-entry)
reference for what each field is sourced from now.

**Which socket is the uplink is measured, not declared.** The default route's gateway IP →
its MAC in `/proc/net/arp` → that MAC's port in the ARL. On these two boards the same
gateway MAC was learned on physical port 4 and physical port 2 respectively, matching the
cabling — a modelmap constant would have been wrong on one of them, and would go wrong on
either the next time a cable moves. It is also the guard on per-port VLAN: that socket is
refused an assignment, and a board that cannot determine it refuses every port.

**A side effect worth recording:** per-port VLAN assignment was unreachable on both real
boards before this. The only reported port was the uplink, and uplink ports deliberately
carry no `swport` — so the Port Manager had exactly one port and it was the one port that
must never be reassigned.

Two things looked broken and are not openUF's doing: `lldp_table` is empty because `lldpd`
on the APs receives nothing (the UCG Ultra does not transmit LLDP to them, though it happily
parses theirs), and `ethernet_table` is not sent at all — no evidence yet on what the
controller does with it, so it stays unsent rather than guessed at.

### The Ports view's other columns

Empty is the right answer for most of them, and the real gateway is the control group:

| Column | Source | On this site |
|---|---|---|
| **Anomaly** | Controller-side, from its own stats history ("24h AI Anomaly Score") | `0` on every AP port; `20` on the UCG's port facing the 100baseT-linked AP — the same conclusion it records on the device as `detailed_states.negotiated_low_uplink_port_speed: true`, which only appeared once openUF stopped claiming 1000 |
| **STP** | `stp_state`/`stp_pathcost`, a USW port property | `-` for every port, the gateway's own included |
| **Profile** | Port profile (`portconf_id` in `port_overrides`), controller-side config | `-` for every port, the gateway's own included |
| **Operation** | `op_mode` (`switch`/`mirror`/`aggregate`) | The controller writes `op_mode: "switch"` and `forward: "all"` onto openUF's ports **although openUF sends neither** — server-side defaults. `switch` is the truthful value for these sockets anyway |
| **Tx/Rx Sum, Tx/Rx Rate** | `rx_bytes`/`tx_bytes` | Populated from the per-port MIB — see below |
| **Tx/Rx Multicast, Broadcast, Dropped, Packets** | `rx_multicast`, `tx_broadcast`, `rx_dropped`, … | Sent by the gateway, not by openUF: swconfig's per-port MIB exposes `RxGoodByte`/`TxByte` and nothing else, and the CPU netdev's totals belong to every socket at once |

**Per-port counters are a driver setting, not a capability.** The ar8xxx driver only maintains
the MIB while `ar8xxx_mib_poll_interval` is non-zero, and boards differ: the AR9344 shipped at
`500` and reported counters, the AR8327 shipped at `0` and answered "Operation not supported"
for every port, so one AP's Ports view was populated and the other's read 0 B everywhere. One
`swconfig dev switch0 set ar8xxx_mib_poll_interval 500` produced counters on the next read, so
openUF now does that once at startup when the attribute exists and reads 0
(`switchvlan.enable_mib_polling`, opt out with `dev.conf.vlan.mib_poll_ms = false`).

---

## A tagged SSID's trunk deafened every wired client on the AP — FIXED

2026-08-02, same two APs. The user reported a printer at a static `192.0.2.11`, cabled
into the Bedroom AP, that nothing could reach and that never appeared in the controller UI.
It was an openUF bug, and the printer was only the visible half of it — a second host on
another socket had been dead the same way, unnoticed.

The printer was alive and talking: the AP's switch had learned its MAC in the ARL on
physical port 2, and that was the MAC the laptop's ARP cache held for `.11`. Frames got
*from* it and never *to* it.

**UCI and the switch disagreed**, which is the tell:

| | UCI `switch_vlan` for VLAN 1 | live `swconfig dev switch0 show` |
|---|---|---|
| WDR3500 — **AR8229**, `vlans: 16` | `1 2 3 4 0t` (sockets untagged) | `0t 1t 2t 3t 4t` — **all tagged** |
| Archer C5 — **AR8327**, `vlans: 4096` | `0 1 2 3 4 5` | `0 1t 2 3 4 5` — as written |

Both APs carried an identical `openuf_swvlan10` trunk of `0t 1t 2t 3t 4t`, written by
`switchvlan.trunk_ports()` for the tagged IoT SSID. Only the AR8229 let it bleed into
VLAN 1.

**On the `ar8216`/`ar8226`/`ar8229`/`ar8236` driver family, tagging is not a property of
(port, VLAN) — it is one global per-port bitmask.** `ar8xxx_sw_set_ports()` does

```c
if (p->flags & (1 << SWITCH_PORT_FLAG_TAGGED))
        priv->vlan_tagged |= (1 << p->id);
```

and `__ar8216_setup_port()` reads that single bitmask to choose `AR8216_OUT_ADD_VLAN` vs
`AR8216_OUT_STRIP_VLAN`, for every VLAN at once. So marking socket 2 tagged for VLAN 10
made it egress-tagged in VLAN 1 too, and the untagged printer dropped every frame. The
AR8327 escapes this because `ar8327.c` overrides the get/set-ports ops with a real
per-(port, VLAN) tag table — which is exactly why the bug shipped: **it is invisible on
the board the feature was developed against.**

The fix trunks only the CPU port and the uplink socket, which is the entire path a tagged
SSID's frames take. The old code's stated reason for tagging everything — that the uplink
socket is not knowable from config — had gone stale: `sysinfo.uplink_phys_port()` measures
it from the switch's own ARL, and `switchvlan.apply()` already had the answer in hand.
When it cannot be resolved openUF now holds any existing trunk rather than guessing;
letting a transient nil fall through to the reconcile pass would delete a working trunk
and reload, then rewrite it on the next inform, bouncing the IoT WLAN in a loop.

Verified live on both boards. WDR3500: VLAN 1 back to `0t 1 2 3 4t`, printer and the
second host answering ICMP from the AP and from a laptop two hops away. Archer C5: VLAN 1
untouched, VLAN 10 down from `0t 2t 3t 4t 5t` to `0t 2t`. On both, a one-shot
`udhcpc -i br-openuf10` still took a lease from the VLAN 20 gateway, so the feature the
trunk exists for is intact.

**A hardware limit that follows, and cannot be fixed in software.** On a global-bitmask
chip a port cannot be untagged in VLAN 1 *and* tagged in VLAN 10. Running a tagged
wireless VLAN therefore leaves the **uplink** socket egress-tagged for VLAN 1 as well —
visible above as the `4t` in `0t 1 2 3 4t`. The UCG Ultra accepts tagged VLAN 1 on that
port (it is the live, working state), and the effect is confined to the one socket facing
the gateway rather than every socket facing a client.

**Generalising:** this is the third finding in the same shape as the first real-hardware
run — config that reads perfectly and hardware that does something else. A `swconfig`
port string is a *request*; `swconfig dev <sw> show` is the only account of what the ASIC
actually holds, and the two must be compared on each chip family, not one.

---

## Controller behaviors that are not openUF bugs

Each of these cost real investigation time at least once.

### A 404 with an empty body does not mean the inform was rejected

A well-formed, correctly-encrypted first-contact inform gets **HTTP 404 with
`Content-Length: 0`**, with zero corresponding entry in the controller's `inform` logger —
yet the device is created server-side and shows as "1 device is ready to adopt." Verified at
the wire level through a raw byte-logging TCP relay: the `100 Continue` handshake completes
normally and the response genuinely has an empty body.

Malformed packets behave differently and are easy to tell apart: they get **400** with a
specific logged reason (`Bad packet magic`, `Data version 0 is not supported`,
`Content too short`).

Ruled out as causes, so they aren't re-tried: compression (a real zlib-compressed,
correctly-flagged payload gets the same 404) and GCM-vs-CBC (both get the same 404).

`http_post` treats any non-200 as a hard failure and never inspects the body. In every case
observed the body was genuinely empty, so nothing is lost — but the client cannot
distinguish "processed, nothing to say" from "rejected," and backs off identically either way.

**When you see this on a fresh device: click Adopt.** That is the correct next move, not
more debugging.

### Historical stats live in the `unifi_stat` database, on a 5-minute cadence

CPU/memory graphs, per-client Traffic Activity, the Radios tab's "Avg." columns, and the
Ports view's Bps chart are **not** rendered from live inform data. They are read from
`unifi_stat`'s `stat_5minutes` / `stat_hourly` / `stat_archive` collections, written by a
periodic archiver (`com.ubnt.service.system.QDcGUYAmLvJwylXw`, internally labelled
`stat-processor`).

So: a flat/empty graph checked two minutes after adoption is expected. Allow ~15 minutes, or
a few 5-minute buckets, before treating it as a defect. Query
`unifi_stat.stat_5minutes` directly to check whether the data is landing — `db.stat` in the
**`unifi`** database is a different, empty collection and querying it is misleading.

### The minidev cache never sees external writes

`com.ubnt.service.devmgr.SNMiFVJXxaonBOtqbJ`'s device lookup is cache-then-DB-fallback: an
in-memory "minidev" summary (`_id`, `site_id`, `authkeys`, `x_aes_gcm`, `hash_id`) keyed
`("global", "minidev", mac)`, populated once on the first DB hit and never invalidated by an
external write. Editing a device doc in Mongo while the controller runs therefore has no
observable effect. Restarting the controller to force a reload introduces its own artifact:
the device flips to **Offline** in the UI even while `last_seen` keeps advancing and informs
keep landing, and does not self-heal within a normal observation window.

This is why the "always reset fully" rule exists. It also explains why "Remove"
(factory-reset) leaves informs decrypting successfully afterwards — they are being served
from a stale cache entry while the underlying doc is already gone.

### Config sync can get stuck after informs stabilise

Observed while trying to force pure-WPA3 emission: switching the test WLAN's Security
Protocol to WPA3 made the controller **stop pushing the WLAN's `aaa.<n>`/`wireless.<n>`
blocks entirely** — not just the SAE fields — and reverting the setting did not restore
pushes, even across an `inform.lua` restart. No related error in `server.log`.

**Reusable warning:** a live no-op does *not* always mean "the controller is deliberately
withholding this field because of a capability gate" (which is exactly what it meant for
`advertise_ap_name`). Sometimes it means the environment's config sync is stuck. Decompile
the emitter to tell the two apart before concluding anything.

### Controller-side UI quirks

- **Environment tab (AirView) stops updating ~10 s after mount**, with no user interaction:
  the row disappears, "No WiFi broadcasts found" renders, and the sidebar filters grey out.
  Clicking any other Time Range tab instantly restores everything. Verified the data is
  present server-side the whole time (10/10 direct `stat/rogueap` polls over 23 s returned
  all entries). Consistent with the table capturing `rowsPerPage` from the pre-fetch, empty
  selector result at mount (`useState({pageNumber:0,from:0,rowsPerPage:r.length})`) and never
  recomputing it. A genuine defect in the controller's own frontend, outside openUF's control.
- **Radios tab's "Type" filter shows nothing until one option is explicitly checked**, unlike
  Band/MIMO/Status on the same page, where an empty selection means "show all." "Type" here
  means the **AP's own uplink** connection type, so a wired-uplinked AP correctly appears
  under "Wired" — the radios themselves being wireless is irrelevant.
- **"Remove" on a client sends no wire command at all** — pure controller-side bookkeeping.
  A still-present client reappears on the very next inform.
- **The upgrade confirmation dialog truncates versions to 3 components**, so a genuine
  full-string mismatch can render as "Update U6 IW from 6.8.2 to 6.8.2?".

---

## Decompiling the controller

The controller is a Java app, and Java bytecode retains field-name string constants in the
class-file constant pool even under ProGuard-style class/method obfuscation — a far friendlier
analysis target than the AP's encrypted ARM firmware (see [dead ends](#dead-ends--do-not-re-attempt)).

**Procedure:**

1. Extract `/usr/lib/unifi/lib/internal/internal-dependencies.jar` from the container — the
   real ~29 MB application jar. (`ace.jar` is only a license-protected bootstrap `Launcher`.)
2. **Unzip it on a case-sensitive filesystem.** `com.ubnt.service.aa` and
   `com.ubnt.service.aA` — and ~55 other package pairs differing only by case — are distinct
   real packages. macOS silently folds them into one directory, corrupting the extraction and
   producing a decompile of the *wrong* class's method body with no warning. Do the
   `unzip` + decompile inside a Linux container (`docker cp` the jar into the controller
   image itself, which already has a JVM).
3. **Use CFR (`cfr.jar` 0.152) for large methods.** `jadx` silently drops method bodies it
   can't reconstruct — no marker, just absent output. The ~5,182-unit method that gates
   provisioning was invisible to jadx and decompiled cleanly under CFR. jadx is still fine
   for browsing and for properly-scoped class listings.
4. For frontend behavior, fetch the live controller's own React chunks
   (`react-app-wrapper.*.js`, `radiosPage.*.js`, `swai.*.js`, `airview.*.js`) and grep them.
   **Where they are (10.6.106):** the UniFi OS shell at `/` is public but only loads its own
   bundles; the Network app lives behind `/proxy/network/manage/` (401 without a session). A
   UniFi OS **API key** sent as `X-API-KEY` opens it: `/proxy/network/manage/` returns the
   shell whose loader is `angular/<build>/js/index.js`; that file's chunk manifest names ~49
   entry chunks served from `/proxy/network/manage/react/js/<name>.<hash>.js`; the main bundle
   `swai.<hash>.js` (~5.5 MB) carries the capability constant tables and a map of ~1,600 lazy
   chunks (`<id>.<hash>.js`, same directory; ~21 MB in all) which hold the device settings
   forms. The same key works on the legacy API (`stat/device`, `rest/device`, `rest/setting`,
   `cmd/devmgr`) and on `/proxy/network/v2/api/...`, so a REST write can be reproduced without
   the UI and the response compared with the UI's behaviour (2026-10-03, mesh).
5. **Without a controller at hand at all (2026-10-03):** Ubiquiti's firmware catalog
   (`https://fw-update.ubnt.com/api/firmware-latest?filter=eq~~product~~unifi-controller&filter=eq~~channel~~release`)
   lists the current Network release per platform with a direct download; the `debian` entry
   is a .deb (147 MB for 10.6.106, build `atag-10.6.106-36011`, i.e. the UCG Ultra's own
   build). `ar x` it, `tar xf data.tar.xz`, and the application is
   `usr/lib/unifi/lib/internal/internal-dependencies.jar`. Unzip on a case-sensitive volume
   (step 2), find the classes by constant-pool string with `grep -rlaF` (the binary flag
   matters, and a `grep` that is really ugrep skips class files silently), then run `jadx`
   (Homebrew, pulls openjdk) on just those `.class` files. This is how the wireless-uplink
   contract was read in an afternoon after three guessed payload shapes had failed: the UAP
   inform processor is `com.ubnt.service.devmgr.iceUMDuewFNFLMOqti`, the VAP/uplink processor
   `com.ubnt.service.devmgr.C.RxFvcetMTlkSFFxK` (names are per build).
   Where a decode function's logic matters, the webpack module registry
   (`window["webpackChunk…"].push([[Symbol()], {}, req => …])`) gives a direct reference to
   the **live** function, which can be called with a sweep of inputs — ground truth, not a guess.

**Logging:** the controller's loggers use flat, hand-picked names (`inform`, `adopt`,
`inform.uap`, `core.lock`, `web.api`), not package paths — see
`com.ubnt.service.system.HCKpgcBFPLu`. Setting `com.ubnt` to DEBUG does nothing for them. A
custom `logback.xml` with explicit `<logger name="inform" level="DEBUG"/>` entries, wired in
via `-Dlogback.configurationFile=`, is needed. Note that most handlers only log on their
*short-circuit* branch, so silence is consistent with everything passing normally.

### Class index

| Class | Role |
|---|---|
| `com.ubnt.service.devmgr.l.MiVjHefaf` | Inform handler / adoption state machine; the provisioning gate; upgrade-offer gate |
| `com.ubnt.service.devmgr.PGOcbDWlbnYQdFW` | `uap`/`uacc` state processor — `radio_table`, `port_table`, `scan_radio_table` ingestion |
| `com.ubnt.service.devmgr.tFhABnrHYJqvjaoEa` | Sibling state processor; power/PoE field copy; `radio_caps` passthrough |
| `com.ubnt.service.devmgr.c.KHUkYjHujLgFBD` | vapInformProcessor — filters `vap_table`, copies `sta_table` attrs |
| `com.ubnt.service.devmgr.DyonYyyYJkiyv` | Per-port `mac_table` processing |
| `com.ubnt.service.devmgr.TtZhv` | Client record writer (wired + disconnect-time wireless archive) |
| `com.ubnt.service.devmgr.HCKpgcBFPLu` → `com.ubnt.g.s.jRsSex` | **Live** (still-connected) client generation display |
| `com.ubnt.service.devmgr.SNMiFVJXxaonBOtqbJ` | Device lookup / minidev cache; replace + clone config services |
| `com.ubnt.service.system.QDcGUYAmLvJwylXw` | Stat archiver (`stat-processor`) — writes `stat_5minutes` `o:"ap"` buckets |
| `com.ubnt.service.system.x.htDMji` | Archiver method that reads `radio_table[].athstats` |
| `com.ubnt.service.aO.hhFgUVZPT` / `aO.bLwwMKkr` | Scan ingestion; the `"PeerScan"` DTO |
| `com.ubnt.service.config.eWivisHeQsnaqDtx` | WLAN/radio config generator (emits `system_cfg`) |
| `com.ubnt.service.config.ubntconf.OXMua` | SAE field emitter |
| `com.ubnt.ace.api.e.VVyiC` | REST per-port VLAN validator |
| `com.ubnt.data.cVbZoFIZsWYaVCquTr` (+ ~90 nested) | The controller's entire internal Device model — one nested class per wire sub-object |
| `com.ubnt.data.cVbZoFIZsWYaVCquTr$QCtdvLKOBb` | vap-stats DTO (**not** the unrelated top-level `com.ubnt.data.QCtdvLKOBb`, a FirewallRule — obfuscated short names collide across packages, always extract by full path) |
| `com.ubnt.data.uuvchZbWVhirD` | Device DTO — `hasFirmwareCapability`, `hasWifiCapability2`, `isSwitch` |
| `com.ubnt.data.dhdeXcHqLRBKMUZk` | Model registry (per-model port count and feature set) |
| `com.ubnt.g.f.e.rYtJfMBbtgWvku` | Radio band enum: `ng`, `na`, `ad`, `6e` |

---

## The inform protocol

### Envelope

Header layout, flags (`0x01` encrypted, `0x02` compressed), zlib-before-encrypt ordering,
AES-128-CBC + PKCS#7, and the default `http://unifi:8080/inform` URL all match openUF's
implementation and fxkr/unifi-protocol-reverse-engineering's published documentation.
`PKT_VERSION` is 1; the GCM AAD is the 40-byte header.

`mgmt_cfg` is a newline-delimited `key=value` **string**, not JSON.

### The GCM provisioning gate

**On 10.4.57 the controller will not provision a device until it has received a genuine
AES-GCM-encrypted inform.** `x_aes_gcm` is set *only* in the decrypt path — `InformServlet`
reads the packet's on-the-wire encryption flag (`header.isGcm()`) and the handler does
`dev.set("x_aes_gcm", true)`. **There is no JSON/payload field that sets it.** The controller
always requests GCM (`use_aes_gcm=true` is written unconditionally into every `mgmt_cfg`), and
once `x_aes_gcm` is set it rejects a GCM→CBC downgrade outright (`"tried to downgrade inform
encryption from AES-GCM to AES-CBC, rejecting"`).

The gate itself, in `MiVjHefaf`:

```java
if (!(dev.isUnsupported() || dev.aesGcmInformEncryptionOnly() || <globalFlag>)) {
    // "dev[..] : mgmt config update before provision"
    resp = new setparam; resp.put("mgmt_cfg", ...);
    dev.set("cfgversion", <fresh random 16-hex>);   // rolls every cycle
    return resp;                                     // returns BEFORE provisioning
}
```

`aesGcmInformEncryptionOnly()` just returns the device doc's `x_aes_gcm` boolean. While it is
false, **every** inform hits this branch, gets a brand-new random `cfgversion`, and returns
early — never reaching `cfgversion`-convergence provisioning, and never reaching the
`wait_for_initial_inform` clear.

**The diagnostic signature** of a device stuck here: adoption reports as completed, informs
decrypt fine, `last_seen` advances — but `cfgversion` is different on *every single* cycle,
`x_aes_gcm` stays false, `provisioned_at` is absent, and the UI shows "Adopting" forever.

Once GCM is sent, all of it resolves in one cycle: `x_aes_gcm` → true, `cfgversion` stabilises,
`provisioned_at` set, `wait_for_initial_inform` cleared, device Connected.

`crypto.lua`'s GCM code works against the `zhaozg/lua-openssl` binding with no changes. The
`openssl(1)` CLI fallback **cannot** do GCM (`enc` refuses AEAD ciphers), so a container
without a real binding silently downgrades to CBC and hangs on this gate.

### Adoption: L2 vs L3

**L3 (inform-only, no SSH).** The controller logs `discovered via L3 inform, skip SSH adoption`
and delivers the new `authkey` directly in the `mgmt_cfg` of the `setparam` sent right after
the Adopt click:

```json
{"_type":"setparam","mgmt_cfg":"capability=notif,notif-assoc-stat\nselfrun_guest_mode=pass\ncfgversion=e07e7991b8c62b47\nled_enabled=true\nstun_url=stun://172.19.0.4:3478/\nmgmt_url=https://172.19.0.4:8443/manage/site/default\nauthkey=ccc32a3bbe40157773294de8ed683627\ninform_url=http://172.19.0.4:8080/inform\nuse_aes_gcm=true\nreport_crash=true\n","server_time_in_utc":"1783841863822"}
```

openUF accepts a hex32 `authkey` from `mgmt_cfg` **only while `st.adopted == false`** — while
unadopted the device is still using the well-known default key, so this exchange carries no
less confidentiality than the rest of L3 provisioning already assumes.

**L2 (broadcast discovery + real SSH).** With `announce.lua` broadcasting, the controller runs
genuine SSH on the Adopt click and executes `syswrapper.sh set-adopt <url> <key>`. The existing
`syswrapper.lua`/`state.lua` shape (`adopted`, `authkey`, `inform_url`, `cfgversion`, `use_gcm`)
is what real SSH adoption expects — confirmed by a real round-trip.

Two things real hardware does that the validation container had to be taught:

- The controller's SSH client (`sshj`) offers only legacy `ssh-rsa` (SHA-1), matching aging
  UBNT firmware; OpenSSH ≥8.8 excludes it by default. `HostKeyAlgorithms +ssh-rsa` /
  `PubkeyAcceptedAlgorithms +ssh-rsa` are needed in `sshd_config`.
- The controller authenticates as the Ubiquiti factory-default account **`ubnt`/`ubnt`**, not
  the admin-configured Device SSH credentials — correct behavior, because `announce.lua`'s
  `IsDefault` byte (`0x17` in the TLV blob, `make_blob_17_1a`) correctly declares the device
  unadopted.

`mgmt_url` is the **web UI deep link** (`https://host:8443/manage/site/default`), *not* an
alias for `inform_url`. Treating them as the same key makes the device overwrite its working
inform endpoint on the first routine post-adopt `setparam` and disappear permanently.

### Response `_type`s

The complete set, per `InformServlet`: `noop`, `setparam`, `cmd`, `upgrade`, `reboot`,
`setdefault`. There is no export/backup/dump command.

| `_type` | Shape | Notes |
|---|---|---|
| `noop` | `{"_type":"noop","interval":…,"live_update":false,"include_blocks":[],"server_time_in_utc":"…"}` | Steady state. `interval` is the cadence the controller wants -- `10` normally, but **not constant**: on 2026-09-15 the UCG Ultra answered with 16–19 for two stretches of a minute or two while the RF stats page was open in the UI, then went back to 10. Honoured since that day (clamped to 5–300 s, back to the device's 10 s when absent) -- openUF used to discard it, so its informs would have kept arriving every 10 s against the controller's wish. `live_update` has only ever been observed `false` (row 17 in REVERSE-ENGINEERING.md's backlog); `include_blocks` see block-sta below. |
| `setparam` | `{"_type":"setparam","mgmt_cfg":"…","system_cfg":"…","server_time_in_utc":"…"}` | Both configs are flat `key=value` blobs. See [system_cfg](#system_cfg-the-real-config-channel). |
| `cmd` | `{"_type":"cmd","cmd":"…","mac":"…","device_id":"…",…}` | See command table below. |
| `upgrade` | `{"_type":"upgrade","version":"6.8.2.15592","md5sum":"…","url":"http://fw-download.ubnt.com/…"}` | Fire-and-forget, sent exactly once; no retry, no confirmation expected. |
| `reboot` | `{"_type":"reboot","reboot_type":"soft",…}` | The top-level form is the real one; `{"_type":"cmd","cmd":"restart"}` is not the path this action takes. `reboot_type` is unused by openUF. |
| `setdefault` | — | Handler exists but has never been observed dispatched live; see [open questions](#open-questions). |

**After executing a `cmd`, the device must send another inform immediately** (documented by
fxkr and confirmed live: the controller's next `noop` lands in the same second).

Confirmed `cmd` strings:

| `cmd` | Trigger | Payload |
|---|---|---|
| `set-locate` | Locate button | `{"cmd":"set-locate","device_id":…}` |
| `block-sta` | Block client | `{"cmd":"block-sta","mac":"…"}` |
| `unblock-sta` | Unblock client | `{"cmd":"unblock-sta","mac":"…"}` |
| `spectrum-scan` | — | Handler implemented; no UI affordance found in 10.4.57 to fire it. |

Block/unblock are **one-shot commands**, not persistent per-inform state. The candidate
persistent field `include_blocks` (present on every response) was ruled out — it stays `[]`
even while a client is genuinely blocked. The device is expected to remember the block itself,
which is why `state.json` carries `blocked_stas` and `firewall.reconcile()` runs at startup.

---

## `system_cfg`: the real config channel

**A real controller never sends `resp.vap_table` / `radio_table` / `network_table` as JSON.**
All device configuration — WiFi, radios, IP settings, per-port VLAN, minimum RSSI — arrives
inside the flat, OpenWrt/hostapd-style `system_cfg` key=value blob on a `setparam`.
`inform.lua`'s `M._parse_wifi_system_cfg()` translates it into the `{radio_table, vap_table}`
shape `ucihelper.apply_config()` expects.

Conventions used throughout: booleans are `"enabled"`/`"disabled"` (sometimes `"true"`/`"1"`);
an **absent block means disabled** — there is generally no explicit `status=false`.

### `aaa.<n>.*` — per-SSID security

| Key | Meaning |
|---|---|
| `ssid` | SSID |
| `id` | The wlanconf Mongo ObjectId. **Must be echoed back** — see [`vap_table`](#vap_table-entry). |
| `wpa` | WPA protocol version (`2`/`3`). Stays `2` even for a WPA2/WPA3 transition WLAN. |
| `wpa.psk` | Passphrase |
| `wpa.key.<k>.mgmt` | AKM set (`WPA-PSK`, `SAE`, …). **This**, not `wpa`, is what distinguishes SAE. |
| `pmf.status` / `pmf.mode` | 802.11w. `mode` is `0`\|`1`\|`2` (disabled/optional/required), mapping 1:1 onto hostapd's `ieee80211w`. On this madwifi model, **WPA2/WPA3 transition intent is carried entirely by these fields** — dropping them silently collapses mixed mode to plain WPA2. |
| `pmf.cipher` | `AES-128-CMAC`. Not translated — hostapd's default BIP group-mgmt cipher already is this. |
| `ft.status` | Fast Roaming (802.11r) for the WLAN. No `mobility_domain`/`r0kh`/`r1kh` on the wire — the controller computes and syncs those internally across the site; `ucihelper.derive_mobility_domain()` fills the gap locally. |
| `wpa3.ft.status` | FT for the **SAE akm alone**, a separate toggle from `ft.status`, from the wlanconf's `isWpa3SaeFastRoamingEnabled()`. Emitted unconditionally on any SAE push (the first key `OXMua` writes) and absent otherwise. OpenWrt has one `ieee80211r` switch feeding hostapd's `key_mgmt`, and on `sae-mixed` it yields FT-PSK **and** FT-SAE together, so openUF enables FT if *either* toggle asks and logs the disagreement. |
| `bss_transition` | 802.11v. Present on every band's block, flips independently of Fast Roaming. |
| `br.devname` | `br0` untagged, **`br0.<vlan>`** when the WLAN is assigned to a VLAN network — CONFIRMED live 2026-08-01, the first capture of a tagged WLAN on real hardware. This suffix is the *only* per-WLAN VLAN signal; there is no `network_table`/`networkconf_id` join anywhere in the wire format. |
| `sae.anti_clogging` / `sae.sync` | Plain integers, emitted only when > 0 **and** the WLAN is genuinely WPA3 (see below). |
| `driver` | `madwifi` — confirms the controller is talking to this model as madwifi-era firmware, which explains several value encodings below. |

A VLAN assignment also produces companion `vlan.*`, `bridge.*` and `netconf.*` blocks.
**The `bridge.*` block is a specification, not decoration** — an earlier revision of this
document said openUF "does not need to reproduce these", which cost a live debugging
session. Captured 2026-08-01 when a WLAN was put on VLAN 20:

```
bridge.1.devname=br0            bridge.2.devname=br0.20
bridge.1.port.1.devname=eth0    bridge.2.port.1.devname=ath2      ← the vap
bridge.1.port.2.devname=ath0    bridge.2.port.2.devname=eth0.20   ← the tagged uplink
bridge.1.port.3.devname=ath1    bridge.2.stp.status=disabled
```

That second bridge is exactly the L2 a tagged SSID needs, and openUF must build the
equivalent (`br-openuf<vlan>` holding `<cpueth>.<vlan>`, with the VAP joined to it).
Skipping it yields a VAP and an uplink sub-device that are both up and completely
unconnected: the client associates and gets no DHCP, no gateway, nothing, while UCI,
netifd and hostapd all look correct.

`netconf.*` blocks are per-device-interface and stay anchored: the AP's own IP settings
remained at `netconf.1` (`devname=br0`) with the VLAN's entries taking later indices, so
inform.lua's `^netconf%.1%.` anchor is safe against a VLAN being added.

**Provisioning is not driven by `cfgversion` alone.** A device reporting a stale or bogus
version sometimes gets an immediate full push and sometimes only `noop`s, indefinitely,
even across restarts and fresh random values. An empty string is ignored outright. The
reliable trigger is a real config change in the controller — and note that a UI form
failing validation (e.g. switching a 2.4-GHz-only WLAN to Manual, where Band Steering
demands two bands) saves nothing and pushes nothing, with no error surfaced beyond the
form itself.

**SAE gating.** `com.ubnt.service.config.ubntconf.OXMua`'s emitter is capability-gate-free:

```
n = wlan.getInt("sae_anti_clogging", -1); if (n > 0) emit "aaa.<idx>.sae.anti_clogging" = n
s = wlan.getInt("sae_sync", -1);          if (s > 0) emit "aaa.<idx>.sae.sync" = s
```

but is only *called* when `wlan.isWpa3() || wlan.isOn6GHzBand()`. `isWpa3()` reads the DB flag
`wpa3_support`, which the **"WPA2/WPA3" dropdown does set** — read live from this site's
wlanconf: `wpa3_support: true`, `wpa3_transition: true`, `pmf_mode: optional`. (An earlier
revision of this document claimed the mixed choice left `wpa3_support` false and that a mixed
WLAN therefore never emits these keys. Wrong: the WLAN-side gate passes; what suppresses the
whole SAE block is the *per-device radio* capability check described in the WPA3 section.)
openUF used to map these to hostapd's `sae_anti_clogging_threshold` / `sae_sync`. **It no
longer does, and no longer parses them**: both are real hostapd keys but neither is a
wifi-iface UCI option — upstream checked the wifi-iface schema, `/usr/share/ucode/wifi/`
and `hostapd.sh`'s `config_add_*` lists on an Archer C5 and an AX3000T (both 25.12.5) and
found neither name anywhere, so the writes were stored in UCI and dropped in silence. See
feature 27 in the matrix.

### `wireless.<n>.*` — per-SSID radio binding and behavior

| Key | Meaning |
|---|---|
| `ssid`, `parent` | SSID, and the owning radio (`radio0`/`radio1`) |
| `dtim_period` | Plain integer, **always present** regardless of the WLAN's Auto/Custom DTIM toggle. There is no `dtim_mode`/`dtim_ng`/`dtim_na` key on the wire — go-unifi's band-split shape describes the REST API, not this protocol. |
| `no2ghz_oui` | **Band Steering's real wire representation.** Not a per-device `mgmt_cfg` field. Toggling Band Steering changes only this key, and only on the 2.4 GHz entry (the 5 GHz entry stays `disabled` — nothing to toggle there). A madwifi/QCA convention: omitting the AP's OUI from 2.4 GHz beacons nudges dual-band clients toward 5 GHz. Mainline mac80211/hostapd has no equivalent, so openUF derives a single device-wide `steering_active` boolean (true if *any* vap has it) and drives `usteer`, which is itself a device-wide daemon. |
| `mcast.enhance` | Multicast Enhancement / Multicast-to-Unicast. `0`\|`1`. |
| `minrate_data`, `beacon_rate`, `mgmt_rate`, `minrate_cck_rates.status`, `minrate_below_disable`, `pureg` | **Minimum Data Rate Control.** `minrate_data` is the floor in kb/s; `beacon_rate`/`mgmt_rate` simply mirror it. `minrate_cck_rates.status` and `pureg` are derived consequences on 2.4 GHz (a 12 Mbps floor is OFDM, so CCK goes `false` and `pureg` goes `1`). `minrate_below_disable` is the separate "advertising rates" sub-toggle. Emitted per band and **absent entirely** when that band's control is off — not band-gated, which an early reading of a 2.4-GHz-only capture suggested. |
| `bcfilt.status`, `bcfilt.<k>.mac`, `bcfilt.<k>.status` | **Multicast and Broadcast Blocker** (REST `bc_filter_enabled`/`bc_filter_list`). `status` appears whenever the control is on, including with an empty allow-list; the indexed entries only once it is non-empty. `<k>` is 1-based and does **not** follow the REST list's order — adding a second MAC renumbered the first — so the index means nothing beyond grouping. Emitted on both band entries. |
| `l2_isolation` | **Client Isolation.** `enabled`\|`disabled`, always present, emitted on both band entries. → OpenWrt `isolate` (hostapd `ap_isolate`). |
| `devname` | The Ubiquiti-side netdev for this vap (`ath0`…`ath3`). **The join key for the top-level [`macacl.*`](#macacl--mac-address-filter) section**, whose own indices do not line up with `<n>`. Not a name that exists on OpenWrt — enforcement resolves the real netdev via `ubus`. |
| `mac_acl.status`, `mac_acl.policy` | ⚠️ **Decoys — not the MAC Address Filter.** Sit at `enabled`/`deny` with the control off and do not move when it is toggled; the real feature is the top-level [`macacl.*`](#macacl--mac-address-filter) section. |
| `hide_ssid` | **Hide WiFi Name.** `true`\|`false` — note the vocabulary, not the `enabled`/`disabled` most keys here use. Always present, emitted on both band entries, and duplicated verbatim as `aaa.<n>.hide_ssid`. → OpenWrt `hidden` (hostapd `ignore_broadcast_ssid`). |
| `mcastrate` | Multicast rate. Observed only ever as `auto` — no WLAN-level control in 10.4.57's UI moves it, and OpenWrt's `mcast_rate` is adhoc/mesh-only anyway, so openUF does not map it. |
| `advertise_ap_name` | "Show Access Point Name in Beacon". **Only emitted when the device declares `wifi_caps2` bit `0x40`** — see [capability bitmasks](#capability-bitmasks). |
| `iot`, `qbssload` | **"Force WiFi 4 Mode"** (IoT Optimization; REST field `enhanced_iot`). Absent entirely when off; appear together as `iot=enabled` + `qbssload=disabled` on the WLAN's 2.4 GHz entry when on. The parent radio is *not* touched — `radio.<n>.ieee_mode` keeps the site's configured width — so this is a per-BSS flag only. `qbssload` is its one distinct on-air effect (suppress the QBSS Load IE); the rest of the mode arrives as ordinary keys: the 5 GHz vap is dropped outright, security pinned to WPA2, and `bss_transition`/`proxy_arp`/`no2ghz_oui`/PMF/`advertise_ap_name` all forced off. |

### `radio.<n>.*` — per-radio config

`phyname` (`radio0`), `channel` (integer or the literal `auto`), `txpower` (integer or `auto`),
`txpower_mode` (`auto`/`custom`/`disabled`), `status`, `ieee_mode`. When no radio is
provisionable the blob contains the literal comment `# no wlan provisioned as no radio found`
and the **unindexed** `radio.status=disabled` — see
[`radio_table` must not be empty](#radio_table-entry).

Do not confuse that unindexed key with the **indexed** `radio.<n>.status`, which is the real
per-radio enable/disable control — see
[`radio.<n>.status` — per-radio disable](#radionstatus--per-radio-disable).

`ieee_mode` is **the wire's only channel-width signal**: a compound `11` + band (`ng`/`na`) +
PHY and width token — `11nght20`, `11nght40`, `11naht40`, `11acvht80`, `11axhe80`. Changing
Devices → [AP] → Settings → Radios → "2.4 GHz Channel Width" from 20 to 40 changes exactly this
key (alongside `cwm.mode` 0→1, a redundant channel-width-management flag carrying no extra
information). openUF maps it to UCI `wifi-device.htmode`; on OpenWrt/mac80211 that option is the
PHY ceiling, so `HT20`/`HT40` also *is* "802.11n only". There is no separate 11n/11ac/11ax mode
key — an earlier version of openUF expected one, never populated it, and so silently never
applied channel width at all.

### `stamgr.<n>.*` — per-radio Station Manager (Minimum RSSI)

Indexed the same as `radio.<n>`, **not** tied to any SSID. This is a device/radio-level
setting (Devices → [AP] → Radios), not a WLAN one — distinct from the WLAN Advanced panel's
"Roaming Assistant", which is a different feature with its own REST fields
(`roamingAssistantNaEnabled`/`Rssi`) that never appear on the wire.

```
stamgr.1.status=true
stamgr.1.radio=ng
stamgr.1.minrssi.status=true
stamgr.1.minrssi.rssi=15
stamgr.1.loadbalance.status=false
```

**The threshold is not plain dBm.** UI `-80 dBm` → wire `15`; UI `-85 dBm` → wire `10` —
`wire = dbm + 95` exactly, a fixed madwifi-era encoding (matching `aaa.1.driver=madwifi`).
openUF stores the raw wire value in UCI and converts back with the same constant. **It is
NOT "dB above the live noise floor"** — an earlier version added `sysinfo.radio_stats()`'s
noise reading instead, which the controller cannot possibly have encoded against (it never
learns a radio's noise floor) and which only looked right on a radio whose floor happens to
be -95: an ath9k 2.4 GHz radio reads -107 and turned a requested -80 into -92, mt76 radios
read -90/-92 and turned it into -75. Corrected 2026-09-06, adopting upstream's fix.

`loadbalance.status` is a sibling sub-feature sharing the block; unimplemented.

**Enforcement semantics** (from web research — this is client-facing AP behavior, not a wire
format): Minimum RSSI is a **roaming aid, not a block**. The AP sends a single deauth frame to
a below-threshold client; there is no persistent drop rule and the client may reassociate
immediately, even to the same AP. This is materially different from `block-sta`, so it has its
own helper, `ucihelper.kick_station()`, rather than reusing `firewall.deauth()`.

### `macacl.*` — MAC Address Filter

A **top-level section keyed by devname**, not by the `wireless.<n>` index. Confirmed live
2026-07-18 by enabling the control on one WLAN with a single allow-listed MAC:

```
macacl.status=enabled                       # global gate
macacl.1.devname=ath0                       # join key -> wireless.<n>.devname
macacl.1.status=enabled
macacl.1.acl.status=enabled
macacl.1.acl.policy=allow                   # allow | deny  (UI "Filter Type")
macacl.1.acl.1.mac=02:11:22:33:44:55
macacl.1.acl.1.status=enabled
macacl.1.acl.1.type=user
macacl.2.devname=ath2                       # the same WLAN's 5 GHz vap
```

Only the vaps belonging to the filtered WLAN get a block, and they are numbered from 1
independently of `wireless.<n>` — in this capture `macacl.1`/`macacl.2` correspond to
`wireless.1`/`wireless.3`. **A join on `devname` is mandatory**; an index-based reading
misfiles the filter onto the wrong WLAN.

Like `bcfilt.<k>`, the `acl.<k>` index carries no meaning beyond grouping, so openUF sorts
the list. Maps onto OpenWrt's `macfilter` (`disable`\|`allow`\|`deny`) + `maclist`, whose
policy vocabulary lines up 1:1 with the controller's.

⚠️ **Two decoys excluded by the same diff.** `wireless.<n>.mac_acl.status` /
`wireless.<n>.mac_acl.policy` sit at `enabled`/`deny` with the control **off** and did not
move when it was toggled — the same shape as `radio.<n>.bcmc_l2_filter.status` was for the
broadcast blocker. `aaa.<n>.radius.macacl.status` is the unrelated RADIUS MAC Authentication
control. Do not re-investigate these.

### `qos.*` — WiFi Speed Limit

Another **top-level section keyed by devname**. Confirmed live 2026-07-18 by creating a
speed-limit profile (33 Mbps down / 17 Mbps up) and assigning it to one WLAN. Note the
per-WLAN toggle does nothing until at least one profile exists in the site settings — with no
profile there is nothing to select and nothing reaches the wire.

```
qos.status=enabled
qos.mode=1
qos.if.1.devname=eth0 / .devspeed=1000 / .type=uplink   # interface inventory
qos.if.2.devname=ath0 / .devspeed=570
qos.vap.1.devname=ath0                                  # join key
qos.vap.1.dwnlink.maxspeed=33000                        # kbps  (UI Mbps x 1000)
qos.vap.1.dwnlink.minspeed=33000
qos.vap.1.uplink.1.devname=eth0
qos.vap.1.uplink.1.maxspeed=17000                       # kbps
qos.ebt.1.cmd=PREROUTING --in-interface ath0 -j mark --mark-or 0x1000 ...
```

| Detail | |
|---|---|
| Units | **kbps**. The UI's Mbps value × 1000. |
| Discriminator | **Presence of `maxspeed`.** Not `qos.status` (global), and *not the block itself*: an unlimited vap still gets a `qos.vap.<m>` block carrying only `minspeed`, set to that radio's raw `devspeed` (570 on 2.4 GHz, 2400 on 5 GHz here). Treating the block as "limited" would cap every WLAN at its own PHY rate. |
| Scope | A **per-VAP aggregate** cap, not per-client — there is no per-station structure on the wire. All clients on the SSID share the ceiling, which is what makes one qdisc per VAP sufficient. |
| `qos.ebt.<n>.cmd` | Literal ebtables fragments the stock firmware would replay to fwmark each VAP. openUF implements the intent with `tc` instead (`shaper.lua`), since ebtables is not a given on OpenWrt while `tc` ships in the base iproute2. |

### `netconf.*` / `dhcpc.*` / `route.*` / `resolv.*` — IP settings

```
netconf.1.devname=br0
netconf.1.ip=172.19.0.50
netconf.1.netmask=255.255.255.0
netconf.1.autoip.status=disabled
route.1.gateway=172.19.0.1
resolv.nameserver.1.ip=192.168.1.1
resolv.host.1.name=<device name>      # also the source for wps_device_name
dhcpc.status=enabled
dhcpc.1.status / dhcpc.1.devname      # the actual DHCP-vs-static signal
```

**A fresh device's very first post-adopt `setparam` always carries `dhcpc.1.status=enabled`** —
a brand-new device is in DHCP by definition. Acting on that unconditionally (flush + `udhcpc`)
strands the interface if no DHCP server can grant a fresh lease. `netconfig.apply_dhcp` is
therefore only called when `st.ip_mode == "static"` already, i.e. when genuinely reverting our
own prior static push; first contact and steady-state reaffirmations are a no-op, matching how
real hardware's continuously-running DHCP client needs no manual re-invocation.

### `switch.*` — per-port VLAN

Appears only once the device declares switch capability. Fully mapped live 2026-07-19 by
diffing `system_cfg` across five states. An earlier version of this section claimed the
controller "manages VLAN membership server-side and only needs the device to *accept* the
push" — **that was wrong**, and it is why README claimed the feature worked while no code
existed. The device is sent a complete, actionable VLAN table.

**Baseline (B0) — Port VLAN off**, the state every device sits in until the control is
enabled:

```
switch.status=disabled
switch.vlan.status=disabled
switch.dot1x.status=disabled
switch.jumboframes=disabled
switch.port.1.name=PoE Out + Data   / .opmode=switch
switch.port.2.name=Data             / .opmode=switch     # ... through port 5
```

The `switch.port.N` entries are always present — one per the **model registry's** port count
(5 for U6IW), not per whatever `port_table` openUF reports. They carry only `name`/`opmode`
and never move; they are inventory, not control.

**The discriminator is `switch.status` / `switch.vlan.status` flipping to `enabled`.** Both
sit at `disabled` in B0, so — unlike `wireless.<n>.mac_acl.*` or `radio.<n>.bcmc_l2_filter.status`
— these are genuine gates, not decoys. They are driven by a **device-level** checkbox
(Devices → [AP] → Settings → IP Settings → **Port VLAN**), not by anything per-port, and until
it is ticked the whole per-port VLAN UI is greyed out.

**C1 — Port VLAN enabled, no port override.** The site's VLANs appear as a table:

```
switch.status=enabled
switch.vlan.status=enabled
switch.vlan.1.id=1      / .mode=untagged / .status=enabled
switch.vlan.2.id=20     / .mode=tagged   / .status=enabled
```

`switch.vlan.<m>` is a slot number; `.id` is the real VLAN id. `.mode` here is the VLAN's
device-wide default.

**C2 — port 2's Native VLAN set to the VLAN-20 network.** Three keys are added:

```
switch.port.2.pvid=20              # the port's untagged/native VLAN
switch.vlan.1.port.2.mode=tagged   # VLAN 1 is tagged on port 2
switch.vlan.2.port.2.mode=untagged # VLAN 20 is untagged on port 2
```

So membership is expressed **twice, redundantly**: once per-port (`pvid`) and once as a
per-VLAN-per-port matrix (`switch.vlan.<m>.port.<n>.mode`). The matrix is the authoritative
one — it is what carries tagging, and `pvid` is derivable from it (the VLAN whose mode is
`untagged`).

**`switch.port.<n>` joins directly to `port_table[].port_idx`** — no devname indirection,
unlike `macacl.*`/`qos.vap.*`. Confirmed by the Port Manager UI listing exactly the two ports
openUF reports at the time (not the registry's five) and the override landing on wire index
2, openUF's port_idx 2. This join is why `port_idx` is pinned to a physical socket in the
modelmaps and must not be renumbered: the controller stores a port's settings against it.

**C3 — Tagged VLAN Management → Block All.** One key changes:

```
switch.vlan.1.port.2.mode=exclude   # was "tagged"
```

giving the full mode vocabulary: **`untagged` | `tagged` | `exclude`**, which maps 1:1 onto
swconfig's untagged/tagged/absent port membership.

**C4 — port reverted to default.** The three per-port keys from C2 simply **disappear**, and
the blob returns byte-identical to C1. Teardown is therefore expressible: absence means
default (untagged on the management VLAN, all others tagged), the same "absent block means
disabled" convention used everywhere else in this format.

### `cron.*`, `ntpclient.*`, `system.timezone` — controller-managed system settings

Confirmed live 2026-09-15 on AP2 (JIDU6101, UCG Ultra 10.6.101), the first full push after
the unhandled ledger went in — every one of these had been in every capture and read by
nothing:

```
system.timezone=IST-5:30            locale.timezone=IST-5:30       # the same POSIX TZ string twice
ntpclient.status=enabled
ntpclient.1.status=enabled          ntpclient.1.server=0.ubnt.pool.ntp.org   # ... .4 = 3.ubnt.pool.ntp.org
cron.status=enabled
cron.1.status=enabled
cron.1.user=<the site's Device SSH Authentication username>
cron.1.job.1.status=enabled
cron.1.job.1.schedule=0 4 * * *
cron.1.job.1.cmd=syswrapper.sh 11k-scan
```

The cron job is the controller scheduling a **nightly 04:00 (device local time) neighbour
scan on every AP**, through the AP's own cron and its `syswrapper.sh` — the "automated RRM
scans" Ubiquiti's Channel AI describes. openUF's `sysconf.lua` writes the jobs into a marked
block of `/etc/crontabs/root` (only commands this build provides; the pushed user is ignored
and jobs run as root), and `syswrapper.sh 11k-scan` asks the running daemon to sweep every
radio on its next heartbeat. The timezone goes to UCI `system.@system[0].timezone` and the
servers to `system.ntp.server`, each stamping the value it replaced; `ntpclient.status=disabled`
restores the list. Device-side effect verified on AP2 the same day (see the feature matrix).

### `ebtables.*` — L2 hardening rules

Same push, ten literal ebtables fragments the stock firmware replays:

```
ebtables.status=enabled             ebtables.add_vlan.status=disabled
ebtables.1.cmd=-t nat -A PREROUTING  --in-interface  ath0 -d BGA -j DROP    # and ath1, ath2
ebtables.2.cmd=-t nat -A POSTROUTING --out-interface ath0 -d BGA -j DROP    # and ath1, ath2
ebtables.7.cmd=-t broute -A BROUTING -i ath1 -p 802_1Q -j DROP              # the VLAN-tagged SSID's VAP
ebtables.8.cmd=-t broute -A BROUTING --vlan-id 10 -p 802_1Q -j DROP         # bridge-wide
```

`BGA` is ebtables' alias for the Bridge Group Address `01:80:c2:00:00:00` (STP BPDUs); with
STP off the Linux bridge *forwards* frames to it, so without these a wireless client can inject
BPDUs into the wired LAN, and the `802_1Q` pair says no client may inject VLAN-tagged frames.
`l2guard.lua` re-expresses them as nft `bridge openuf_l2guard` on the **AP VAP netdevs only**:
the bridge-wide `--vlan-id` rule is safe on the stock firmware only because its tagged uplink
is an 8021q sub-device (`eth0.10`) that takes tagged frames before the bridge; on a DSA board
openUF's tagged uplink is `br-lan.10`, on the bridge, and the same rule would drop the IoT
WLAN's own uplink traffic. `qos.ebt.*` (WiFi Speed Limit) is the same replay mechanism.

### `radio.<n>.status` — per-radio disable

Also settled 2026-07-19, in the same session. Setting a radio's **Transmit Power → Disabled**
(Devices → [AP] → Settings → Radios) moves four keys:

```
radio.1.status=disabled            # was enabled
radio.1.txpower_mode=disabled      # was auto
radio.1.virtual.1.status=disabled  # was enabled
wireless.1.status=disabled         # and every other vap on that radio
wireless.2.status=disabled
```

This corrects an earlier reading of this document, which recorded `radio.status=disabled`
only as part of the radio-less `# no wlan provisioned as no radio found` case and concluded
the key carried no per-radio signal. **The indexed `radio.<n>.status` is a real control.**

openUF maps `radio.<n>.status` onto UCI `wifi-device.disabled` and `wireless.<n>.status` onto
each `wifi-iface.disabled`, and reports both back out (`radio_table[].disabled` /
`vap_table[].disabled` already read them off UCI), so the controller sees its own push
reflected. Two details worth keeping:

- The read is **tri-state**. An absent `status` key writes nothing, so a blob that never
  carries it cannot re-enable a radio or SSID the operator disabled by hand in
  `/etc/config/wireless`; only an explicit `enabled`/`disabled` writes. An explicit
  `enabled` must clear the flag, or a radio could never be switched back on.
- Only the **indexed** key is read. The unindexed `radio.status=disabled` in the radio-less
  blob would otherwise take every radio on the device down — the tokenizer's
  `radio.<n>.<key>` shape cannot match a two-component key, so this is structural, but it is
  pinned by a test.

A disabled WLAN is still provisioned, just with `disabled=1`, so its configuration survives
a re-enable.

---

## Wireless uplink (mesh): the push, the contract, and the live result — 2026-10-03

Captured on AP2 against the UCG Ultra (Network 10.6.106) by claiming `wifi_caps` bits through
`debug_caps`, setting the device's mesh-connect flag and priority-1 parent through the
controller's own REST and command endpoints, and diffing the resulting `setparam`s against the
wired baseline; then **implemented (`backhaul.lua`) and verified end to end the same day**:
AP2's cable pulled, AP2 joined AP1's hidden downlink as a 4-address station at −10 dBm with
HE160 4×4 rates both ways, kept its address, informed over the hop, carried a VLAN-10 IoT
client to its own network, and the controller showed the uplink as wireless with AP1 as the
parent and AP1 listing AP2 as a wireless downlink. Full evidence: REVERSE-ENGINEERING.md,
Investigation 1.

**The reporting contract, from the controller's inform processor** (`internal-dependencies.jar`
of the matching Linux package, jadx on `com.ubnt.service.devmgr.iceUMDuewFNFLMOqti` and
`...devmgr.C.RxFvcetMTlkSFFxK`; the three shapes guessed before reading it were all wrong):

- The top-level **`uplink` is a string**: the *name* of the uplink interface. Default `"eth0"`;
  `"down"` marks an isolated device. When it names an entry of `if_table`, the wired path runs
  (counters from that entry, identity from the gateway's LLDP downlink). When it names a
  `vap_table` entry of `usage` `uplink`, the wireless path runs. Sending an object here is
  read as the default and yields a stale "wired via port N".
- A **wireless uplink is a `vap_table` entry** with `usage: "uplink"`, `name` equal to the
  `uplink` string, `up: true`, a non-zero `channel`, `essid` equal to the site's mesh ESSID
  (that is what sets `is_mesh_v3`), `bssid` = the station's own address, `state` RUN, and a
  **`sta_table` holding exactly one station: the parent's downlink BSS**, with `rx_packets > 0`
  and the attributes the controller copies onto the uplink (`signal`, `rssi`, `tx_rate`,
  `rx_rate`, `tx_packets`, `rx_packets`, `tx_bytes`, `rx_bytes`). That station is resolved to
  a device **by its `serialno`** when that is a MAC; the fallbacks are a `(vwire|vport)-<12
  hex>` ESSID (mesh v2, where the name encoded the parent) and an OUI-based derivation that
  only knows Ubiquiti prefixes, so openUF must supply `serialno` — the controller's priority-1
  parent (`mesh.serial1`), else the sibling element of the BSS joined.
- A **downlink is a `vap_table` entry** with `usage: "downlink"` (same validity rules), whose
  `sta_table` lists the children's 4-address stations; each resolves to a child by `serialno`,
  then by the controller's own BSSID tracker, else it logs "Can't resolve wireless mac".
- `uplink_table`, `vwire_table`, `vwire_vap_table`, `downlink_table` and the v2
  `wireless-links` view are **computed by the controller** from the above; device-sent
  copies are ignored. `meshv3_peer_mac` and `uplink_bssid` are stored verbatim.
- A `vap_table` entry whose ESSID starts with `vport-`/`vwire-` but has `usage: user` is
  dropped with "handling is done differently, update AP firmware".

**Device side (openUF, 2026-10-03 evening):** `_parse_wifi_system_cfg` hands the push's two
entries to `backhaul.lua`; `_parse_mesh_system_cfg` reads the `mesh`/`connectivity` blocks.
The downlink becomes `openuf_bh_dl_<radio>` (hidden `wds 1` WPA2-PSK AP in `lan`, beaconing
the sibling element), the uplink `openuf_bh_ul_<radio>` (4-address station, enabled only
while the wired uplink socket has no link). `get_vap_table` reports both as typed entries
named with the controller's devnames (`vwire3`, `ath4`), the uplink with its station
interface's own `station dump` as its one-entry `sta_table` plus `serialno`, the downlink
with the per-station WDS netdevs' dumps as its children; Minimum RSSI and Roaming Assistant
never act on either. `uplink` is the uplink VAP's name while associated. `wifi_caps`
`0x1|0x800` are claimed by default on DSA boards.

**How the controller is told.** The device settings form issues
`PUT /api/s/<site>/rest/device/<_id>` with `mesh_sta_vap_enabled` (and `mesh_uplink_1`/`_2`),
then `POST /api/s/<site>/cmd/devmgr {"cmd":"set-priority-uplink","mac":<child>,"prefer1":<parent>}`
(`prefer2` optional; `unset-priority-uplink` clears). The flag is persisted only for a device
claiming `wifi_caps` `0x1`, and the controller turns it **on by itself** once a device claims
that bit. The parent dropdown is the device's `uplink_table`, which the controller derives from
the uplink VAP's resolved station.

**What arrives** (child = AP2, parent `78:bb:c1:fe:3f:c9` = AP1, 5 GHz radio is `radio.2`):

```
# mesh                                       (needs 0x1 + 0x800)
mesh.status=enabled
mesh.version=3
mesh.essid=vwire-5f3369181f7fbab5             ← site setting connectivity.x_mesh_essid
mesh.psk=<32 chars>                           ← site setting connectivity.x_mesh_psk
mesh.serial1=78:bb:c1:fe:3f:c9                ← priority-1 parent (mesh_uplink_1)
# connectivity                               (needs 0x1)
connectivity.status=enabled
connectivity.uplink_wds=ath4
connectivity.uplink_eth=eth0
connectivity.uplink_bridge=br0
# the downlink: a hidden WPA2 AP for children (needs 0x1 + 0x800; flag on or off)
radio.2.virtual.1.devname=vwire3   radio.2.virtual.1.mode=master   radio.2.virtual.1.status=enabled
wireless.4.devname=vwire3  mode=master  usage=downlink  wds=enabled  vwire=enabled  vport=disabled
wireless.4.ssid=vwire-5f3369181f7fbab5  hide_ssid=true  parent=radio1  security=none  authmode=1
aaa.4.devname=vwire3  ssid=vwire-…  wpa=2  wpa.key.1.mgmt=WPA-PSK  wpa.psk=<same 32 chars>
aaa.4.wpa.1.pairwise=CCMP  hide_ssid=true  status=enabled  br.devname=br0  pmf.status=disabled
# the uplink: a 4-address station toward the parent (needs 0x1 and the device's mesh flag)
radio.2.virtual.2.devname=ath4     radio.2.virtual.2.mode=managed  radio.2.virtual.2.status=enabled
wireless.5.devname=ath4  mode=managed  usage=uplink  wds=enabled  vport=enabled  vwire=disabled
wireless.5.ssid=vport-ac10076fc670  hide_ssid=true  parent=radio1  security=none
aaa.5.devname=ath4  ssid=vport-ac10076fc670  status=disabled   (no key here: the station uses mesh.psk)
# plumbing: both devnames join the bridges, tagged for every VLAN the AP carries
bridge.1.port.4.devname=ath4   bridge.1.port.5.devname=vwire3
vlan.2.devname=ath4 vlan.2.id=10   vlan.3.devname=vwire3 vlan.3.id=10
bridge.2.port.3.devname=ath4.10   bridge.2.port.4.devname=vwire3.10
netconf.<n>: ath4/vwire3 up=disabled promisc=enabled; ath4.10/vwire3.10 up=enabled
```

Everything else in the push was unchanged, including `radio.2.channel=auto` — the controller
does not pin the child to the parent's channel in the config, so the station itself has to
follow the parent (the parent's own channel is in its push). The `vport-<mac>` naming matches
fxkr's 2015 capture of a real UAP's uplink VAP.

### The parent names its children — 2026-10-03

The controller resolves each station of a downlink VAP to a device by the station's
`serialno`, else by a BSS it has scanned with that MAC, else by Ubiquiti's OUI arithmetic
(first byte rewritten, fourth byte − 1). A 4-address station never beacons and a
TP-Link/Jio board has no Ubiquiti OUI, so without `serialno` the parent logged "Can't
resolve wireless mac" and its `downlink_table` stayed empty while the child's uplink
resolved fine. The parent can name the child itself: hostapd parks each WDS peer on its
own netdev (`phy1-ap1.sta<N>`), the bridge learns the child's identity MAC behind that
netdev, and the sibling element in the parent's scans says which MACs are site APs.
`backhaul.child_serialno()` intersects the two and the station's `serialno` is set when
exactly one sibling is behind the netdev (two would mean a grandchild on a multi-hop path,
and a wrong attribution is worse than none). This is the same first-class field the uplink
side already fills, which is why it was chosen over OUI games or renaming the station.
Implemented on both APs' trees 2026-10-03; it runs on whichever AP is the parent.

## RF scans: Airtime Scan, Quick Scan and Radio AI's sweep — 2026-10-03

Three different commands, one device-side job. Everything below is read from controller
10.6.106's bytecode (`com.ubnt.service.system.l.*`, `devmgr.b.g.ctfbDsCjrxgkv`,
`devmgr.iceUMDuewFNFLMOqti`, `devmgr.kDxteQiUX`, `devmgr.e.c.VsCpQiCuGEvNvUNmH`,
`stat.hyFnQ`) and its frontend bundles (`swai`, `airview`, `react-app-wrapper`), then
confirmed live against AP2 the same day.

**The gates.** Airtime Scan (Devices → [AP] → Radios → Airtime): button shown with
`wifi_caps` `0x10` (RF_SCAN) on a wired AP; the view's "scan while serving" flag is
`wifi_caps2` `0x2` (MONITOR_RF_SCAN). Quick Scan: `wifi_caps2` `0x80`; the REST handler
also requires `!isWirelessUplink()`, an active device, and no scan already running. Radio
AI's prescan asks every AP with `supportQuickScan()` that is not on a wireless uplink.
`stat/spectrum-scan`, the endpoint the view reads, skips any device without
`supportSpectrumScan()` — so without `0x10` the data is invisible even when sent.

**The commands.**

| cmd | arguments as the device receives them | who sends it |
|---|---|---|
| `spectrum-scan` | `{mac}` | the Airtime Scan button |
| `quick-scan` | `{mac, "scan-band": 0\|1\|2, "scan-bw": 20\|40\|80\|160}` — band index (ng/na/6e) and width in MHz, both **integers** (the REST side takes `"na"`/`80` and re-encodes) | the Quick Scan dialog; Radio AI's prescan |
| `scan_band` | `{band: "ng"\|"na"}` | the controller's scheduled neighbour sweep (`XbYOtjBEpjeHWlUU`); it sets the record's `scanning` and takes the next inform's `scan_radio_table` |

**What the device reports.** The sweep itself is `iw dev <if> scan ap-force` followed by
`iw dev <if> survey dump`, 1.5–2.7 s per radio; all three commands run it inside their own
dispatch, so the inform that follows the command already carries the result.

- `radio_table[].spectrum_table` — rows `{channel, width, center_freq, utilization,
  interference}`, one per 20 MHz channel per width the band offers (ng 20/40, na
  20/40/80/160). `utilization` is busy airtime in %, `interference` the busy time that was
  neither this radio's rx nor tx in %, both 0–100. The table must be on the **radio_table
  entry**: the UAP processor walks `payload.radio_table` (as it does for `athstats`) and
  copies `spectrum_table` from each radio into the stored `radio_table_stats` when the
  device is not mid-quick-scan and the list is non-empty. A table only in
  `radio_table_stats` is never read — two live sweeps left `stat/spectrum-scan` empty
  until the table moved. openUF sends it in both places.
- `radio_table[].spectrum_table_time` — seconds **since** the sweep. The processor stores
  `now − value` as the sweep's epoch; the view prints it as "N minutes ago".
- `quickscan_scanning` / `spectrum_scanning` — booleans. The controller set the record's
  `quick_scan_state.in_progress` when it dispatched the quick-scan; the device's `false`
  on the next inform is the "just finished" edge that pushes the fresh tables to the open
  view (`kDxteQiUX`). A quick-scan the device never answers times out after ten minutes.
- `EVT_AP_QuickScanEvent` — a **notification inform**: the regular payload plus
  `inform_as_notif: true`, `notif_reason: "event"` and `notif_payload: {event_string:
  "EVT_AP_QuickScanEvent", radio, radio_name, channel, width, center_freq, utilization,
  interference}`. The inform entry (`devmgr.l.AqxpICcpcuIxnda`) takes that branch before
  any statistics processing and answers a bare `noop`; the handler upserts the row and
  stamps the record's `spectrum_scan_timestamp` (ms) — which is the Quick Scan card's
  "last scan" and what Radio AI's prescan waits for before it reads the tables. The
  device's own top-level `spectrum_scan_timestamp` is ignored. openUF posts one such
  inform after the heartbeat that carried a sweep's table; one row is enough.
- The row shape, the averaging and the width tabs come from the frontend: `renderChannel`
  filters rows with `width === tab` whose `channel` is in the block's `subChannels` (which
  for 2.4 GHz 40 MHz blocks span every overlapping 20 MHz channel) and **averages** them
  (module 178221), so each row carries its own channel's figures.

**Live, 2026-10-03, AP2 (JIDU6101, 25 channels on 5 GHz):** `quick-scan` with
`scan-band: "na", scan-bw: 80` through `cmd/devmgr` → `cmd: quick-scan` in the daemon
log, `quick_scan_state.in_progress: true` with `last_band: na, last_width: 80`, then
`false` on the next inform; the notification inform set `spectrum_scan_timestamp` (ms)
and, once the table rode the radio_table entry, `stat/spectrum-scan` held **100 rows for
radio1 — 25 channels at each of 20/40/80/160 MHz** — with `spectrum_table_time` as the
sweep's epoch (the age the device sent, converted). `spectrum-scan` arrived and swept both
radios the same way. Three runs in all; the first two (table only in `radio_table_stats`)
left the stat empty, which is how that mistake was found.
The DTO (`stat/device`) strips `spectrum_table` from `radio_table_stats` unless a quick
scan is in progress, by design; `stat/spectrum-scan/<mac>` is the read path.

**Still approximate.** `interference` as "busy minus own rx/tx" counts other BSSs' traffic
as interference, which a real AP's hardware spectral scan would not. The survey counters
are cumulative since boot for the operating channel and a few ms for the others, so the
operating channel's figure is a long-run average while the rest are the sweep's dwell.

## Discovery requests and WiFiman — 2026-10-03

**WiFiman is console-side.** The site setting is `mgmt.wifiman_enabled`; the controller
never pushes any wifiman key to an AP (AP2's ledger has none after weeks), and the app
reads the console: `GET /v2/api/site/<site>/wifiman/<clientIp>` (client info: channel,
link rates, experience history, `uplink_devices` chain, `nearest_neighbors`, ISP
capability) and `.../wifiman/<clientIp>/devices`; `POST .../feedback` stores the app's
speed tests. The controller finds the client **by its IP** in the active clients, follows
`ap_mac` to the AP and `uplink.uplink_mac` up the chain, and asks the AP for an inform
within ten seconds (`wifiManInformService`). Queried with the API key for a laptop on
openUF's AP1, every field came back populated except `noise: 0` and `channel_width: null`
(openUF reports neither per station). The REST classes (`com.ubnt.service.wifiman.*`,
`com.ubnt.net.l.aN.RxFvcetMTlkSFFxK`) are the whole feature; the same `GET` under
`/api/` instead of `/v2/api/` answers `api.err.InvalidObject`, which cost an hour.

**The AP-side gap was discovery.** WiFiman's Discovery tab, the UniFi mobile app and the
Device Discovery Tool list Ubiquiti devices by broadcasting the four-byte probes
`01 00 00 00` (v1) and `02 08 00 00` (v2) to UDP 10001 and listing who answers. openUF's
announcer only ever **broadcast** (version 2, command 6) from an ephemeral port and never
listened on 10001, so those tools saw a bare host next to the UCG Ultra's full entry —
"no extra info". Captured 2026-10-03 with a probe script: the UCG answers v1 with version
1 / command 0 and v2 with version 2 / command 9, the same TLVs (hardware address, IP,
hostname, platform, firmware, uptime, …) in both, unicast from port 10001 to the asker's
own port; AP1 and AP2 answered nothing. `announce.lua` now binds 10001 and answers each
probe the same way (`reply_for`, `_serve_requests`); the first probe after the deploy got
four replies from AP2. The periodic broadcast is unchanged, and `l2_announce = false`
still turns both off together.

## Outbound payload field reference

Everything openUF sends. Names were audited against the controller's own Device model
(`com.ubnt.data.cVbZoFIZsWYaVCquTr` and its ~90 nested per-sub-object classes).

### Top level

| Field | Value / notes |
|---|---|
| `_type` | `"state"` |
| `default`, `state` | `not adopted`; `2` connected / `0` unadopted |
| `mac`, `serial`, `model`, `platform`, `hostname`, `ip` | `serial` is the MAC with colons stripped |
| `inform_url`, `cfgversion`, `uptime`, `time` | |
| **`version`** | **Bare firmware version only — never model-prefixed.** See below. |
| `required_version`, `bootrom_version`, `country_code` | `bootrom_version` has no counterpart anywhere in the device schema (closest is `boot_time`, a timestamp); likely ignored, left as-is for want of evidence to rename it to. |
| `mem_total`, **`mem_used`** | Bytes. `mem_used = total − free`; the schema has `mem_used`, not `mem_free`. |
| **`system-stats`** | Hyphenated key, `{cpu, mem, uptime}` — all three **strings**, cpu/mem as percentages. Not `sys_stats`, and not loadavgs. `cpu` is `0` on the very first inform (delta-sampling `/proc/stat` has no prior sample). |
| **`fw_caps`** | `0x110` — see [capability bitmasks](#capability-bitmasks) |
| **`wifi_caps2`** | `0x40` — see [capability bitmasks](#capability-bitmasks) |
| `spectrum_scanning`, `spectrum_scan_timestamp` | **Device-level**, not per-radio (the per-radio fields are `spectrum_table`/`spectrum_table_time`) |
| `if_table[]` | `name`, `mac`, `rx_bytes`, `tx_bytes`, `rx_packets`, `tx_packets`, `rx_errors`, `tx_errors` |
| `radio_table[]`, `radio_table_stats[]`, `vap_table[]`, `scan_radio_table[]`, `port_table[]`, `lldp_table[]` | See below |

**Why `version` must be bare.** The upgrade-offer gate in `MiVjHefaf`:

```java
private boolean chgwykfBxZCAuEHPPQ(String string, String string2) {
    return this.TgovGTpPRqBiOa(string) && !StringUtils.equals(string, string2);
}
// object3 = ProductInfo.version         -- e.g. "6.8.2.15592" (bare)
// string  = inform.getString("version")
```

A **strict, unnormalized `StringUtils.equals`** — no prefix stripping, no numeric parsing.
Sending `"U6IW.6.8.2.15592"` never matches `"6.8.2.15592"`, so the "Update Available" banner is
permanent regardless of the actual firmware version. The catalog's version is confirmed bare
by the controller's own startup log: `firmware[U6IW] new version (6.8.2.15592) is available`.

`fw.pre` (`"U6IW."`) remains correct and untouched in `announce.lua`'s L2 discovery
"firmware version verbose" TLV — a different protocol surface. Do not reuse it here.

### Capability bitmasks

| Field | Bit | Controller method | Effect if absent |
|---|---|---|---|
| `fw_caps` | `0x10` (16) | `Device.hasQCASwitch()` = `hasFirmwareCapability(16)` | The Ports view's projection of `port_table` into the device DTO doesn't happen. Wired-client *ingestion* is gated only on `isSwitch()` (a model-registry property), so clients still appear in the list — but the Ports view stays empty. |
| `fw_caps` | `0x100` (256) | `Device.hasOWRTSwitch()` = `hasFirmwareCapability(256)` | Per-port VLAN assignment is rejected outright — see below. |
| `wifi_caps2` | `0x40` (64) | `Device.supportAdvertisingDeviceNameInBeacon()` = `hasWifiCapability2(64)` | The controller never emits `wireless.<n>.advertise_ap_name` at all, and doesn't even re-push config on the toggle. |
| `wifi_caps2` | `0x20` (32) | `Device.supportsAssistedRoaming()` | A WLAN's Roaming Assistant (`wireless.<n>.btm_disassoc.*`) is never emitted. Claimed since 2026-09-28 (`roamassist.lua`). |
| `wifi_caps2` | `0x80` (128) | `Device.supportQuickScan()` | The Quick Scan button is hidden and the REST `quick-scan` cmd is refused (`devmgr.b.g.ctfbDsCjrxgkv`); Radio AI's prescan skips the AP ("no quick-scan-capable eligible AP"). Claimed since 2026-10-03 — see [RF scans](#rf-scans-airtime-scan-quick-scan-and-radio-ais-sweep--2026-10-03). |
| `wifi_caps2` | `0x2` (2) | `MONITOR_RF_SCAN` (frontend table 718429) | The Airtime view's "scan while serving" check. Claimed since 2026-10-03 alongside `0x80`; the device's share is the same forced sweep. |
| `wifi_caps` | `0x10` (16) | `RF_SCAN` (frontend table 537871) → `supportSpectrumScan()` | The Airtime Scan button is hidden and `stat/spectrum-scan` skips the device (`if (hyfnq6.supportSpectrumScan())`). Claimed since 2026-10-03. No config key changed on the push that followed the claim (ledger diffed on AP2). |
| `wifi_caps` | `0x4` / `0x8` | `supportBandsteering()` / `supportVapBasedBandsteering()` | The device-level `bandsteering.status`/`mode` block (the AP's own Band Steering setting) and its per-WLAN pairs are never emitted; without `0x8` one single-band WLAN switches the device's steering off. Claimed since 2026-09-28. |
| `wifi_caps` | `0x20` (32) | `supportATFConfig()` | `atf.status`/`atf.mode` (Airtime Fairness) is never emitted. Claimed where mac80211's per-phy `airtime_flags` exists (`airtime.lua`). |
| `wifi_caps` | `0x100000` | `supportWpaPpsk()` | A WLAN with Private Pre-Shared Keys, or UID IoT, is **skipped** ("PPSK is not supported … will be skipped"). Claimed where the ucode generator writes `vlanid=` and hostapd has VLAN support (`sysinfo.ppsk_supported`). |
| `radio_caps2` | `0x1` | radio DTO `CVir()` | Every WPA3 WLAN is downgraded to WPA2 -- see the WPA3 section below. Claimed where hostapd has SAE. |
| `radio_caps2` | `0x2` | radio DTO, FT-with-WPA3 (`ytajcagDggPuTaL()`) | On an SAE WLAN `wpa3_fast_roaming` is forced off, so `aaa.<n>.wpa3.ft.status` is always `disabled`; on a WPA3-only WLAN `fast_roaming_enabled` too, and no 802.11r goes out at all. Claimed alongside `0x1`. |
| `radio_caps2` | `0x8` | radio DTO, OWE (`NoFWvUa()`) | An Enhanced Open WLAN is **not provisioned** ("WPA3-OWE cannot provision"); with OWE transition on it goes out as plain open. Claimed where `hostapd -vowe` passes and the ucode generator knows `owe_transition`. |
| `wifi_caps` | `0x1` (VWIRE) | backend validator of `rest/device` (field `mesh_sta_vap_enabled`); AP config generator | **Confirmed live 2026-10-03 (AP2, 10.6.106, REST writes bisected over five masks).** Without it the mesh-connect flag is silently dropped (`rc: ok`, empty `data`, reads back `false`) — the UI's tick "reverts". With it the flag persists and the push gains the **uplink station VAP** (`usage=uplink`, `wds`/`vport` enabled, `vport-<mac>`) and `connectivity.uplink_*`. Not claimed: openUF has no WDS station. |
| `wifi_caps` | `0x800` (MESHV3) | AP config generator | **Confirmed live 2026-10-03.** Together with `0x1` adds the `mesh.*` block (`status=enabled`, `version=3`, `essid`, `psk`, `serial1` while a parent is set) and the **downlink VAP** `vwire3` (`usage=downlink`, `vwire=enabled`, hidden WPA2-PSK), flag on or off. Alone it does nothing. Not claimed. |
| `wifi_caps` | `0x80` (MESH) | — | **No observable effect** (2026-10-03): pushes with and without it were identical. |

`wifi_caps2` is a **second, entirely separate** bitmask from `wifi_caps`. Since 2026-09-28
openUF claims `wifi_caps` `0xC` (+`0x20`, +`0x100000` where the device-side probe passes),
`wifi_caps2` `0x60` and `radio_caps2` `0x3` (+`0x8`); `debug_caps` in `conf.lua` still
replaces any mask whole for an experiment. The rows below come from upstream's full sweep of
the controller's gates.

#### Full sweep of the capability gates (controller 10.6.101, upstream, 2026-09-27)

Every `has*Capability` predicate on `com.ubnt.data.dChnXOlwHH` (the `Device` class) and
every `radio_caps`/`radio_caps2` bit test on the radio DTO `com.ubnt.i.g.e.DXufmCC` was
traced by upstream to its callers, mainly the AP config generator
`com.ubnt.service.config.oHgVgY` and the per-radio WLAN security filter
`com.ubnt.service.config.ubntconf.plVcFpIybmrpXclX`. Calls on
`com.ubnt.i.g.OZQcnZuvnRweLFaaG` in oHgVgY check the **model registry**, not anything the
device sends, and are excluded. **The unclaimed rows come from decompiled code only; none
has been checked on the wire.**

Gated, and deliberately not claimed:

| Field | Bit | Predicate | Effect while unclaimed |
|---|---|---|---|
| `fw_caps` | `0x1000` | `supportMultiBlockWlanSchedule()` | A WLAN Schedule with several blocks per day goes out as one `wireless.<n>.schedule_<day>` key per block, all under the same name, so the last one wins. With the bit set they become `schedule_<day>.<i>` |
| `fw_caps` | `0x400000` | `supportWlanScheduleInvert()` | The controller inverts a schedule itself instead of sending `schedule_invert` |

The two schedule bits are not claimed because openUF implements no WLAN Schedule: the
`schedule_*` keys are emitted whenever a WLAN has a schedule, regardless of any bit, and
openUF parses none of them. Claim both when the feature is built.

- **No OpenWrt equivalent, or out of scope:**
  - `radio_caps2` `0x4`: WPA3-Enterprise-192.
  - `radio_caps2` `0x400` and `wifi_caps2` `0x1`/`0x4000`/`0x8000`: MLO and Mesh-MLO.
  - `radio_caps` `0x20000`: `radio.<n>.hard_noisefloor.*` / sensitivity level, a QCA RX-sensitivity setting.
  - `wifi_caps` `0x4000`/`0x8000`: multi-vport and Element. (`0x1`/`0x80`/`0x800` — vwire, mesh, meshv3 — moved to the gated table above on 2026-10-03; see § Wireless uplink.)
  - `wifi_caps` `0x2000` "open hostapd", `0x40` `bga_filter`, `0x4000000` low-performance mode (`0x10` spectrum scan is claimed since 2026-10-03).
  - `wifi_caps2` `0x4` Green AP, `0x10` ACS-DFS, `0x200` neighbour-in-scan, `0x20000` (an AP-group check, purpose unclear) (`0x80` quick scan and `0x2` monitor RF scan are claimed since 2026-10-03).
  - `fw_caps` `0x800000` Hotspot 2.0 (such a WLAN is skipped without it) and `0x20000000` RADIUS `filter_id`.
  - `fw2_caps` `0x80000` RadSec, `0x20` `port_table.mac_table_ipv6`, `0x80` device command retry.
- **Multicast Suppressor** (`wifi_caps2` `0x400000` → `wireless.<n>.multicast.suppressor`):
  could be enforced in nft like the Multicast/Broadcast Blocker, but it is the same feature
  class that breaks casting. Low priority.
- **No callers in the controller**, so a bit does nothing: `supportMinRateCtrl` (`wifi_caps`
  `0x200`), `supportMultiAclList` (`0x400`), `supportRadiusMacAuth` (`0x1000`),
  `supportHideChWidth` (`0x10000`), `supportZeroHandoff` (`0x2`), `supportLockAp`
  (`0x1000000`), `supportsRoamTopologyStats` (`wifi_caps2` `0x2000`).

The mesh bits (`wifi_caps` `0x1`/`0x800`) stay the subject of REVERSE-ENGINEERING.md's
mesh investigation and are only ever claimed through `debug_caps`.

#### The frontend's own names for the bits (Network app 10.6.106, `swai.*.js`, read 2026-10-03)

The React bundle carries both tables as constants, which fixes the names the decompile could
only infer. `wifi_caps`:

```
VWIRE 0x1 · ZERO_HANDOFF 0x2 · BANDSTEER 0x4 · BANDSTEER_PER_VAP 0x8 · RF_SCAN 0x10 ·
AIRTIME_CONFIG 0x20 · BGA_FILTER 0x40 · MESH 0x80 · MIN_RSSI_STRICT_MODE 0x100 ·
MULTIPLE_ACL_LIST 0x400 · MESHV3 0x800 · UNIFI_WIFI_CAP_RADIUS_MAC_AUTH 0x1000 ·
HIDE_CH_WIDTH 0x10000 · STA_ONLY 0x2000000 · LOW_PERFORMANCE_MODE 0x4000000 · RF_SCAN_6G 0x8000000
```

`wifi_caps2`:

```
MLO 0x1 · MONITOR_RF_SCAN 0x2 · GREEN_AP 0x4 · DFS_BACKGROUND_SCAN 0x8 · ROAMING_ASSISTANT 0x20 ·
QUICK_SCAN 0x80 · MESH_MLO_PARENT 0x4000 · MESH_MLO_CHILD 0x8000 · WIRELESS_UPLINK_ONLY 0x40000
```

The UI also treats a device as "wireless uplink only" when its model is a mesh/extender model
or `wifi_caps2` has `WIRELESS_UPLINK_ONLY`.

**The per-port VLAN validator** (`com.ubnt.ace.api.e.VVyiC`, reachable only once
`hasQCASwitch()` is true):

```java
private void chgwykfBxZCAuEHPPQ(UCthhvfQNZ port, boolean hasOWRTSwitch, boolean hasSwitchVlanCap8) {
    nwTNVfYOnNbEWSoCkPq.guoZiIiLhURleoJ(port).ifPresent(forwardMode -> {
        if (!((forwardMode != ALL && forwardMode != CUSTOMIZE) || hasOWRTSwitch)) {
            throw new QnvUxbsXyAJZ(VLAN_TAGGING_UNSUPPORTED, ...);
        }
        if (hasSwitchVlanCap8 && forwardMode NOT IN {CUSTOMIZE, NATIVE, DISABLED}) {
            throw new QnvUxbsXyAJZ(VLAN_TAGGING_UNSUPPORTED, ...);
        }
    });
}
```

For a port with no explicit `forward` override — the default `ALL` mode, true for every port
openUF sends — the first branch collapses to `!hasOWRTSwitch()`. Without bit `0x100`, **every
default-mode port is unconditionally rejected** with `api.err.VlanTaggingUnsupportedByDevice`,
before `vlan_caps` or anything port-specific is consulted. (Sweeping `switch_caps.vlan_caps`
through 0/3/4/5/6/7/15/31/255 only changed *which* of two near-identical errors fired.)
"OpenWrt switch" as opposed to a QCA hardware switch ASIC is, fittingly, exactly what this is.

### `radio_table[]` entry

| Field | Notes |
|---|---|
| `name` | UCI device name (`radio0`) |
| **`radio`** | **The band** (`ng`/`na`), from `band_for_channel()` — channels 1-14 → `ng`, else `na`. Parsed by `com.ubnt.g.f.e.rYtJfMBbtgWvku`'s `String.toLowerCase()` factory, which has **no null guard**: omitting this field throws an NPE inside the controller's adopt processing on *every* inform, corrupting its UI-facing device cache (Devices list shows "No UniFi Devices Have Been Adopted" while Mongo says adopted). 60 GHz/6 GHz aren't disambiguable from channel number alone and are unsupported. |
| `channel` | Live negotiated channel from `iw dev`, more authoritative than UCI's value (frequently the literal `"auto"`, which the controller will not resolve to a number) |
| **`ht`**, **`tx_power`** | Not `htmode`/`txpower` |
| `disabled`, `builtin_antenna`, `builtin_ant_gain`, `max_txpower` | |
| `nss`, `is_11ac`, `is_11ax`, `is_11be`, `has_dfs`, `has_fccdfs`, `has_ht160`, `has_eht240`, `has_eht320` | Read directly off each entry by `PGOcbDWlbnYQdFW`'s `copyAttrsIfPresent`, **independent of `radio_caps`**. Derived by `sysinfo.radio_caps()` from `iw phy phyN info`. |
| **`radio_caps`** | A separate **integer bitmask**, not `nss`. See below. |
| `min_rssi`, `min_rssi_enabled` | `min_rssi` is **dBm** on the wire (converted from the raw `stamgr` units with the fixed `raw - 95` offset, see the `stamgr` section) |
| **`athstats`** | Nested `{cu_total, cu_self_rx, cu_self_tx, cu_interf}`. See below. |

**An empty `radio_table` blocks a large amount of downstream behavior.** The controller checks
`if (list3.isEmpty()) { … "Missing radio_table in inform…" }` and this is exactly the
"no radio found" condition that suppresses WLAN provisioning. Real OpenWrt hardware has genuine
`wifi-device` sections populated by the driver at boot, independent of any configured SSID.

**`radio_caps` MIMO bits.** The controller's Java side only ever passes this int through
verbatim (`uCthhvfQNZ2.put("radio_caps", uCthhvfQNZ3.getInt("radio_caps", 0))`); the decode into
`"1x1"`…`"4x4"` happens **client-side only**, in the Radios tab's `mimo: e7(radio.radio_caps)`.
Reverse-engineered by calling the live `e7` decoder through the webpack module registry with a
single-bit sweep:

| `nss` | bit |
|---|---|
| 1 | `0x8` |
| 2 | `0x10` |
| 3 | `0x20` |
| 4 | `0x4000000` |

Checked highest-first when multiple bits are set. It is **not** simply `radio_caps == nss`
(live-tested and refuted). Left at the default `0`, the MIMO column is blank *and* the
1x1–4x4 filter checkboxes exclude the radio outright rather than merely filtering it wrong.

**`athstats` is required for the "Avg. Interference"/"Avg. Airtime" columns.** The archiver
method `com.ubnt.service.system.x.htDMji` iterates `radio_table` — not `radio_table_stats`, not
`vap_table` — and:

```java
if (!uCthhvfQNZ.containsField("athstats")) continue;
```

then reads `cu_total`/`cu_self_rx`/`cu_self_tx`/`satisfaction`/`cu_interf` off that nested
sub-object. Sending the same four fields on `radio_table_stats` and `vap_table` (both real, both
used by other paths) leaves every archived bucket without them. Named after the legacy Atheros
`ath9k`/`ath10k` stats struct UniFi firmware historically exposed under this name.

### `radio_table_stats[]` entry

Parallel to `radio_table` — the real controller's own split of static config vs. live stats.

`name`, `channel`, `cu_total`, **`cu_self_rx`**, **`cu_self_tx`** (two separate fields, not one
combined `cu_self`), `cu_interf`, plus `spectrum_table` / `spectrum_table_time` when a
`spectrum-scan` cmd has populated `M._spectrum_cache`.

All `cu_*` are percentages derived from `iw dev <ifname> survey dump`;
`cu_interf = max(0, cu_total − cu_self_rx − cu_self_tx)` — airtime busy for reasons other than
this radio's own tx/rx.

> **`iw` survey field names.** The real binary prints `channel active time:`,
> `channel busy time:`, `channel receive time:`, `channel transmit time:` — *not*
> `channel time:`/`channel time busy:`/etc. Patterns must be anchored to line start so
> `channel busy time:` doesn't also match inside `extension channel busy time:`, which `iw`
> emits on wider channels.

> **The operating channel's entry is not first — pick it by `[in use]`.** `survey dump`
> emits one entry per channel the phy supports, in the phy's own frequency order, so the
> operating channel sits wherever it falls: measured live on 2026-08-02, entry **11 of 13**
> for a 2.4GHz radio on ch11 and **3 of 24** for a 5GHz radio on ch44. Every other entry is
> a scan dwell carrying only a few milliseconds of accumulated time (3–146 ms observed).
> Deriving `cu_*` from `stats[1]` therefore divided a busy figure by a ~3 ms active time and
> reported a genuinely 24%-busy 2.4GHz channel to the controller as **100%**, and a 1.9%-busy
> 5GHz channel as **75%** — which is what made both APs look like they were drowning in
> interference. The same wrong entry also fed the noise floor Minimum RSSI was, at the time,
> (wrongly) converted with. Fixed by flagging `in_use` in `sysinfo.radio_stats()` and selecting it in
> `inform.lua`'s `_in_use_survey()`; the test fixture now mirrors the real ordering, and
> reverting the selection fails 4 tests.

`spectrum_table[]` entries carry `channel`, `center_freq`, `width`, `utilization`,
`interference` (field names recovered from two independent Lombok DTO constant pools).
`channel`/`center_freq`/`utilization` come mechanically from survey dump; `width` and
`interference` are best-effort — see [best-effort fields](#best-effort-and-unverified-fields).

### `vap_table[]` entry

| Field | Notes |
|---|---|
| `name` | UCI section name |
| **`essid`** | Not `ssid` |
| **`id`** and **`wlanconf_id`** | Both carry the wlanconf ObjectId from `aaa.<n>.id`. **Mandatory.** See below. |
| **`radio`** | The **band** (`ng`/`na`), same enum as `radio_table`. Sending `radio0` here logs `WARN stat - unexpected radio[radio0] while processing stats` on every inform and silently drops that vap's stats aggregation. |
| **`radio_name`** | The UCI device name (`radio0`) — a separate, real field on the same DTO. This is what `get_ifname_for_radio()` needs. |
| `encryption`, `disabled`, `bssid`, `channel`, `tx_power`, `usage` | `usage` is `"user"` |
| `num_sta` | Coexists with the nested `sta_table` on the real DTO |
| `rx_bytes`, `tx_bytes`, `rx_packets`, `tx_packets`, `tx_retries`, `tx_dropped` | The UI's "Air Stats" panel. `iw` exposes these only per-station, so they're summed across connected stations while building `sta_table`. `rx_dropped`/`rx_errors`/`tx_errors`/`satisfaction` have no source in `iw` output at all — left unset rather than invented (802.11 ARQ retry/failure counters are inherently TX-side only). |
| `avg_client_signal` | Mean `signal` of associated clients, dBm. Omitted entirely when the VAP has no clients. |
| `cu_total`, `cu_self_rx`, `cu_self_tx`, `cu_interf` | Mirrored from the radio |
| `sta_table[]` | Nested — see below |

**`id` is mandatory or the entire VAP is discarded.** `com.ubnt.service.devmgr.c.KHUkYjHujLgFBD`
(vapInformProcessor) filters the raw `vap_table` *before* any per-station processing runs. For a
`usage=user` VAP it requires a non-`"unknown"` `id`, then re-looks it up via
`configCache.get(siteId, id)` to attach `wlanconf_id`/`ap_mac`/`site_id`/`is_guest`/`is_wep`.
A missing `id` is checked with `!"unknown".equals(id)` and drops the VAP **silently** —
no log line, no error, taking the nested `sta_table` and every wireless client with it.
The `"Inconsistent vap"`/`"Invalid id"` warn paths only fire on an actual lookup *failure*.

**"Air Stats" needs growing counters, not just non-zero ones.** The widget renders a
rate/delta between informs. Static counters produce a zero delta even when the absolute value
is correct — which is why `iw-mock.sh`'s fake counters must increase monotonically.

### `sta_table[]` entry (nested inside each `vap_table` entry)

Nested, **not** a flat top-level `user_table`.

| Field | Notes |
|---|---|
| `active`, `mac`, `ap_mac`, `channel`, `radio` | `active` is always `true` — an entry only exists while `iw station dump` lists the station |
| `signal`, `rssi` | Both the same value; `iw` exposes no separately-measured RSSI |
| `rx_bytes`, `tx_bytes`, `rx_packets`, `tx_packets` | **Raw cumulative counters.** The vapInformProcessor computes its own `tx_bytes-d`/`rx_bytes-d`/`bytes-d`/`bytes-r` deltas server-side keyed by `time_delta` — never send a pre-computed rate here. |
| `tx_rate`, `rx_rate` | **Kbps** (`iw` reports Mbit/s, so ×1000) |
| `uptime`, `idletime` | `iw`'s "connected time" / "inactive time", both in seconds |
| **`tx_mcs`**, `rx_mcs` | Not `tx_mcs_index` (that name is only the ucore-message JSON name for a different internal event). Absent for legacy pre-11n rates. |
| `nss` | Read directly by the controller, no derivation |
| `radio_proto` | Read only by the **disconnect-time** archive path (`TtZhv`) |
| **`is_11n`, `is_11ac`, `is_11ax`, `is_11be`** | What the **live** display actually uses — see below |
| `wifi_tx_attempts`, `wifi_tx_retries_percentage` | `attempts = tx_packets + tx_retries` |
| `satisfaction`, `satisfaction_now` | Best-effort estimate — see below |
| `capacity`, `throughput`, `linkscore`, `multicast` | Best-effort / placeholders — see below |
| `name` | Omitted — controller/admin-assigned, no local source |

The attribute list `KHUkYjHujLgFBD` copies verbatim off each incoming entry is exactly:
`"channel", "radio", "name", "signal", "rssi", "tx_rate", "rx_rate", "tx_packets",
"rx_packets", "tx_bytes", "rx_bytes"`.

**Why the `is_11*` booleans matter more than `radio_proto`.** The live, still-connected client
display is computed by `com.ubnt.service.devmgr.HCKpgcBFPLu` → `com.ubnt.g.s.jRsSex`, which
**ignores the `radio_proto` string entirely**:

```java
private static jRsSex lhPagEPcc(UCthhvfQNZ uCthhvfQNZ) {  // 2.4GHz (ng) path
    if (uCthhvfQNZ.is("is_11be", false)) return BE;
    if (uCthhvfQNZ.is("is_11ax", false)) return AX;
    if (uCthhvfQNZ.is("is_11n",  false)) return NG;
    if (uCthhvfQNZ.is("is_11b",  false)) return B;
    return G;   // fallthrough when none are set
}
```

Sending only `radio_proto` leaves every live client showing `"g"` (2.4 GHz) or `"a"` (5 GHz),
while `nss` — read directly, no derivation — works immediately. Both must be sent.

**Generation/NSS derivation** from `iw`'s own bitrate line tokens (format strings confirmed via
`strings /usr/sbin/iw`):

| Token | Generation | NSS |
|---|---|---|
| bare `MCS N` | `n` | `floor(N/8)+1` (HT MCS layout: 0-7 = 1 stream, 8-15 = 2, …) |
| `VHT-MCS` / `VHT-NSS` | `ac` | read directly |
| `HE-MCS` / `HE-NSS` | `ax` | read directly |
| `EHT-MCS` / `EHT-NSS` | `be` | read directly |
| none (legacy) | falls back to the band: `a` on `na`, `g` on `ng` | 1 |

Never `b` — real dual-band 11n+ hardware doesn't negotiate down to 802.11b-only rates.

**`satisfaction` is a device-computed field.** The controller's `wifi_experience_score` is a
straight passthrough — `com.ubnt.service.l.e.AcrQJeJCScLn`:
`wifi_experience_score = doc.getOptionalInt("satisfaction")`. The wireless-client model
(`com.ubnt.service.l.e.AQODNNoMmBlFpWXX`) reads `satisfaction`, `satisfaction_now`,
`satisfaction_real`, `satisfaction_reason`, `wifi_tx_attempts`, `wifi_tx_retries_percentage`,
`tx_mcs`, `ccq`, `noise`, `nss` as **plain data**; the controller computes nothing itself beyond
a running `satisfaction_avg` accumulator. Real AP firmware computes it on-device with a
proprietary formula. Sending nothing renders as "No Experience", correctly.

### `port_table[]` entry

Processed only when `Device.isSwitch()` is true for the reported model —
`hasFeature(UiHQyVmgX) || hasFeature(yojQKHv)`. The model registry
(`com.ubnt.data.dhdeXcHqLRBKMUZk`) registers `U6IW` as device type `uap` with **5 ethernet
ports** and the switch feature, matching reality (a U6-InWall has a built-in 4-port downstream
switch). A plain AP like `U6MP` is not a switch. So for the model openUF impersonates, this is
not optional: an empty `port_table` means zero wired clients can ever appear.

One entry per `cfg.net.ports`. Each entry carries `port_idx` (1-based), `name`, `media`,
`up`, `enable`, `speed`, `full_duplex`, `is_uplink`, `speed_caps`, `port_poe`, `poe_caps`
and `rx_bytes`/`tx_bytes`/`rx_packets`/`tx_packets`/`rx_errors`/`tx_errors`. Where those
facts come from depends on what the board can be asked:

**Per-socket (swconfig board, modelmap field `{idx, swport}`).** One entry per physical
socket. `up`/`speed`/`full_duplex`/`pvid` and the ARL table come from a single
`swconfig dev <sw> show` (`sysinfo.switch_status`), and `is_uplink` is set on the socket the
default gateway's MAC was learned on (`sysinfo.uplink_phys_port`) — detected, never declared,
because on an AP the cable is in whichever LAN socket the installer used. Counters are the
switch's own per-port MIB (`RxGoodByte`/`TxByte`; there are no per-port packet or error
counts, and an AR8327 with `ar8xxx_mib_poll_interval: 0` has no MIB at all), falling back on
the uplink entry only to the CPU netdev's `sysinfo.interfaces()` counters — everything the
CPU sent or received crossed that socket. Other sockets report `0` rather than a fabricated
share of the same total.

The two shapes mix within one board, per port: an entry with no `swport` falls through to
the netdev source below even when the switch answered. That is not a fallback but the right
answer for a socket wired to its own MAC and PHY rather than to the switch — the
TL-WDR3500's WAN socket is a second `ag71xx` surfacing as `eth1`, so sysfs there describes
that socket and not the CPU's link.

**Netdev (no switch, no swconfig, or no identifiable uplink — modelmap field
`{idx, ifname, uplink}`, defaulting to `{wan_cpueth=uplink, lan_cpueth=lan}`).** `up` from
sysfs `carrier`/`operstate`, `speed`/`full_duplex` from sysfs, counters from
`sysinfo.interfaces()`, `is_uplink` from the modelmap. On a swconfig board every one of
those describes the *CPU port* — the internal SoC↔switch link, always 1000/full — which is
why this is the fallback and not the default. Confirmed live: a TL-WDR3500 reported GbE on
an uplink whose socket had negotiated 100baseT, and the gateway's own Ports view said FE for
the same cable.

**Non-uplink ports additionally carry `mac_table[]`** — `{mac, ip, hostname, age, uptime,
vlan}`, where `vlan` is present only for a socket openUF has assigned to a VLAN and is what
places the client on the right *network* (the controller keeps a host only where
`network.getVlan() == host.getInt("vlan", 1)`; absent means 1 — see the 2026-09-13 section),
joined with `/proc/net/arp` for IPs and `/tmp/dhcp.leases` when present for hostnames
(optional — an AP is usually not the DHCP server; `hostname` stays absent rather than
invented). The host list itself is per-socket from the ARL table
(`sysinfo.switch_mac_table`, multicast/broadcast MACs filtered on the address bit), or
`sysinfo.mac_table(ifname)` off `bridge fdb show dev <ifname>` on the netdev path (dynamic
`master br-lan` entries only; `self`/`permanent` and multicast/broadcast filtered).
`bridge fdb` can only ever say "behind the CPU port", so on a switch board it cannot place a
host on a socket — that is what the ARL adds. Sockets whose `pvid` is not the management
VLAN carry no `mac_table` either: the Archer C5's WAN socket is live and has learned a host,
but it sits on VLAN 2 with its CPU port down, so that host is not on the LAN it would be
listed in.

Ports flagged `is_uplink: true` are skipped by the controller for client creation, since that
port faces the controller's own network.

**An uplink port must carry no `mac_table` at all — not even the gateway.** Reporting just
the one MAC on the other end of the cable is tempting: openUF knows it (finding it is how the
uplink socket is identified), a real UniFi gateway visibly does it on its own uplink port, and
it would fill the Ports view's Connection column, which is otherwise blank or stuck on a
retained "last seen device". It would also invert the topology map. The controller matches
every MAC on a port against its adopted devices, and a port carrying exactly one known device
files that device into this one's `downlink_table` (`wRSpUfdrmMXnppHBKZ`):

```java
bl9 = !is_uplink && device.isUplinkMac(neighbour);
if (!bl9) downlink_table.add(neighbour, port);
```

The `isUplinkMac` guard that would prevent it is ANDed with `!is_uplink`, so it disables
itself on exactly the port where it is needed — the gateway would hang beneath every AP that
reported it. A real gateway escapes this because its upstream is the ISP's router, which is
not an adopted device and never reaches that branch; openUF cannot tell the two cases apart
from the device. Upstream verified it on their live site: with both APs silent on their
uplinks, each AP's `downlink_table` is empty and the gateway's holds both APs, which is the
correct shape.

A blank Connection column on an uplink port is therefore intended. `last_connection` is only
recomputed when a port reports exactly one MAC (`wefewPevorbc`: `if (list.size() > 1) return
existing`), and is never touched at all when the port sends no `mac_table` field — which is
why a stale value there persists until cleared with the Ports view's **Clear Last Seen
Device**.

Two exclusion filters prevent double-reporting: the device's **own** MACs, and any MAC
currently associated as a wireless station — a wireless client bridged into `br-lan` genuinely
appears in the bridge FDB too.

**Wired hosts will never show per-client traffic**, by design. `TtZhv` reads only
`mac`/`ip`/`hostname`/`age`/`uptime` off each `mac_table` entry; there is no per-client byte
counter anywhere in the wired-client wire protocol. A wired client's traffic is attributed via
its switch port's own counters.

### `scan_radio_table[]` entry

Backs Insights → AirView → **Environment** (`GET /api/s/default/stat/rogueap`). Built from
`iw dev <ifname> scan dump` — the kernel's already-cached BSS list, cheap and non-disruptive,
unlike the `spectrum-scan` cmd's real scan trigger.

Nested shape (confirmed against `PGOcbDWlbnYQdFW`, which reads a top-level `scan_radio_table`
array and hands each entry's nested `scan_table` to the ingestion service — not a flat list):

```
scan_radio_table[] = { radio, name, scan_table[] }
```

Per `scan_table[]` entry — the consumer DTO `com.ubnt.service.aO.bLwwMKkr` (literally named
`"PeerScan"` in its own builder's `toString`) confirms the full field list:

| Field | Notes |
|---|---|
| `mac`, `bssid`, `essid`, `channel`, `freq`, `signal`, `rssi`, `security` | |
| `radio`, `radio_name` | |
| **`band`** | A field **distinct from `radio`** but taking the identical enum values. The Environment tab's list selector applies an *unconditional* filter upstream of every visible sidebar filter: `A.filter(A=>!!T.R?.[A?.band]?.[A?.bw>0?A.bw:m.L?.[A?.band]])`. `T.R[undefined]` is `undefined`, so an entry without `band` fails silently for every row — indistinguishable from "no data", regardless of filter state. |
| **`bw`** | Channel width MHz. The "Ch. Width" cell reads it directly and renders nothing when falsy: `renderCell:({bw:A})=>A?…:null`. Parsed from `iw`'s `BSS operating channel width: N MHz` (only present for HE/VHT-capable neighbours), defaulting to `20` — legacy-safe and valid on both bands. |
| **`age`** | **Elapsed seconds, not an absolute timestamp.** The ingestion code reads `getInt("age")` and computes `last_seen = report_time − age` itself; it also **silently drops any entry with `age >= 30`** as a staleness guard. Sending an absolute timestamp under either key yields an empty result with no error. Parsed from `iw`'s `last seen: N ms ago`. |

`is_rogue` is much narrower than the tab name suggests: set true only when a neighbouring BSSID
broadcasts the **same essid as one of the site's own configured networks** (an evil-twin check
raising `EVT_AP_DetectRogueAP`). Ordinary neighbours correctly have `is_rogue: false` and still
appear in the Environment list.

### `lldp_table[]` entry

Field names from the real DTO (`OXMua`): `chassis_descr`, `chassis_id`, `local_port_name`,
`local_port_idx`, `is_wired`, `port_id`, `port_descr`.

- `chassis_descr` comes from `chassis.descr`, **not** `chassis.name` — System Description and
  System Name are different LLDP TLVs.
- `local_port_idx` is read from `/sys/class/net/<port>/ifindex` — this is *our own* local
  interface, not something lldpctl reports about the neighbour, so it is a local sysfs lookup
  rather than a protocol field. Omitted when unavailable.
- `is_wired` is unconditionally `true` — LLDP is inherently a wired-link protocol.

### Best-effort and unverified fields

These are explicitly approximations, flagged as such in the code. Listed here so nobody mistakes
them for measured values.

| Field | Status |
|---|---|
| `sta_table[].capacity` | Negotiated `tx_bitrate` (Mbps, floored) as a proxy for "available bandwidth to this client" |
| `sta_table[].throughput` | Delta-sampled byte rate (bytes/sec); `0` on first sample for a given MAC |
| `sta_table[].linkscore`, `.multicast` | `0` placeholders — **no local source and no public reference found for either.** Neither `paultyng/go-unifi`'s `User` model nor `unpoller/unifi`'s `clients.go` has them at all. Still needs live-capture verification. |
| `sta_table[].satisfaction` | `estimate_satisfaction()`, reworked from upstream 2026-09-28: the worst of three terms, following the uplink/downlink/coverage split of commercial controllers (Aruba/Aerohive client health = ideal ÷ actual airtime; Mist coverage and throughput SLEs; Meraki/Cisco SNR thresholds). **Downlink** = the airtime this client's frames would take (110 µs each plus the payload at its ceiling rate) ÷ the `tx duration` they actually took, one window per ≥ 20 frames, capped at 100. The ceiling is the stream count, width and top MCS the client associated with (`hostapd_cli all_sta`: `ht_mcs_bitmask`, `rx_vht_mcs_map`, `ht_caps_info`/`vht_caps_info` width bits, `[HE]` flag), capped by the AP's own streams and live channel width, one MCS below the top. Until a first airtime window, or on a driver without `tx duration`, the tx rate ÷ that ceiling stands in. **Uplink** = 50 + half the rx rate ÷ the same ceiling, only in an inform in which the client sent ≥ 20 frames (`rx bitrate` is the last frame's rate). **Coverage** = SNR against the radio's in-use survey noise (floored at −95 dBm: ath9k/ath10k report −107/−106), 5 dB → 0, 20 dB → 90, 25 dB → 100. Each term is smoothed (EWMA α 0.2). The constants are upstream's judgements, not UniFi calibration. Upstream's evidence (AX3000T, mt76, 2026-09-27): a −71 dBm dishwasher holding MCS 7 with 89 % failed attempts, 7.8 % ping loss and 503 µs of airtime per 97-byte frame scored 24 where signal-vs-retries gave 93; retry/failed counters were dropped because mt76's `tx failed` counts failed attempts (can exceed packets), ath9k's `tx retries` counts every attempt and ath10k never reports `tx failed`. ⚠️ Unconfirmed: whether ath10k firmware counts retries in `tx duration`, HE ceilings (MCS 0–11 assumed), and any of it on the JioRouter boards. Before 2026-09-28 the score was the worse of a signal score (−85 → 0, −50 → 100) and `100 − retries%`. `wifi_tx_attempts`/`wifi_tx_retries_percentage` stay the lifetime iw values. |
| `spectrum_table[].width` | The radio's configured `htmode` (e.g. `HT40` → 40) as a uniform approximation — no live-scan source gives per-channel width |
| `spectrum_table[].interference` | Noise-floor dBm passed through; `iw survey dump` has no interference metric of its own. Falls back to the pre-sweep reading for any frequency whose post-scan noise comes back `0` (see [the first real-hardware run](#the-first-real-hardware-run)) |
| `radio_table[].builtin_antenna` = `true`, `.builtin_ant_gain` = `3` (dBi) | **Constants — no software source exists for either.** Not inert: the controller adds the gain to TX power to display EIRP, so a board with different antennas reports a wrong EIRP. Change them in `ucihelper.RADIO_DEFAULTS` if your hardware differs. |
| `radio_caps().has_fccdfs` | Mirrors `has_dfs`; `iw` exposes no separate FCC-DFS indication |
| `radio_caps().has_eht240` / `.has_eht320` | Hardcoded `false` — openUF has no 802.11be target hardware to derive them from |
| `port_table[].media` = `"GE"`, `.enable` = `true`, `.speed_caps` = `0`, `.port_poe` = `false`, `.poe_caps` = `0` | Constants. The PoE ones are honest for every target board (none source PoE); `media`/`speed_caps` are unmodelled. `speed`/`full_duplex`/`up` **are** measured — per physical socket via swconfig where the board has a switch, else from sysfs |
| `port_table[].rx_packets`/`tx_packets`/`rx_errors`/`tx_errors` on a per-socket entry | `0`. swconfig's per-port MIB exposes byte counters only (`RxGoodByte`/`TxByte`), and the CPU netdev's packet/error totals belong to every socket at once. A downstream socket's `rx_bytes`/`tx_bytes` are likewise `0` on a driver with no MIB (AR8327 with polling off) rather than a share of the CPU total |
| `serial` | Derived from the device MAC with the colons stripped — a real AP's serial is a separate factory value openUF has no equivalent of |
| `spectrum_scanning` = `false` | Always false: scans are run synchronously inside the cmd handler, so the device is never "currently scanning" when a payload is built |
| `lldp_table[].is_wired` = `true` | LLDP is inherently a wired-link protocol |
| `model` / `platform` / `version` / `required_version` / `bootrom_version` | The emulated UniFi identity from `ufmodel/*.lua` — deliberately not the host hardware. This is the point of the project, not an accidental approximation |
| `fw_caps` = `0x110`, `wifi_caps` = `0x1C`(+`0x20`/`0x100000`/`0x801` by probe), `wifi_caps2` = `0xE2` | Claimed capability bits, each derived from the controller's own bytecode and confirmed live — see [Capability bitmasks](#capability-bitmasks). openUF claims only bits whose features it actually implements |
| `ucihelper` `wps_device_name` / `ap_setup_locked` | Standards-based rather than Ubiquiti-derived — see the beacon row in the [feature matrix](#feature-matrix) |
| ~~`usteer.lua`'s `USTEER_DEFAULTS`~~ | ✅ **Resolved upstream 2026-09-10.** Verified against the installed package (usteer 2025.10.04) on an Archer C5. `band_steering_threshold` is a real option — it is in the init script's own list of keys fed to `ubus call usteer set_config`. The named `local` section is read too: the loader does `config_foreach uci_usteer usteer`, which visits every section of type `usteer`, named or anonymous. `network` is read from `uci get usteer.@usteer[-1].network`, the last section of that type — openUF's — so both writes are load-bearing and correctly named. |

Everything not listed above is measured from the running system. Several fields
*used* to belong in this table and no longer do — `max_txpower`, `tx_power`,
`nss`, per-client `signal`, `hostname`, and `port_table[].speed`/`full_duplex`
were all constants or misparsed values until the first real-hardware run
surfaced them; they are now read from `iw`, sysfs and `/proc`.

### WPA3 was silently downgraded to WPA2 — the radio must claim the SAE bit — FIXED

Before `radio_caps2` was sent (see below), a WLAN set to **WPA2/WPA3** in the UI
reached openUF as plain WPA2, and nothing anywhere said so. The captured
`system_cfg` contained no `sae`, no `wpa3`, just:

```
aaa.1.wpa=2
aaa.1.wpa.key.1.mgmt=WPA-PSK
aaa.1.pmf.status=enabled     aaa.1.pmf.mode=1
```

openUF applies that faithfully, so hostapd runs
`wpa_key_mgmt=WPA-PSK FT-PSK WPA-PSK-SHA256` and every client — WPA3-capable
ones included — associates with AKM `00-0f-ac-2`/`-4`/`-6`. Never `00-0f-ac-8`
(SAE).

This is **not** the controller's WLAN being misconfigured. Its REST API confirms
the wlanconf really does carry `wpa3_support: true`, `wpa3_transition: true`.
The downgrade is per device, in `com.ubnt.service.config.ubntconf.QSAkfnbfInKJ`:

```java
if (wlanconf.isWpa3()) {                      // wlanconf field wpa3_support
    if (!radio.CVir()) {                      // radio lacks the SAE capability
        if (wlanconf.isWpa3LegacyEnabled())   // wlanconf field wpa3_transition
            return downgrade(wlanconf, radio);          // ← silent WPA2
        log.warn("SAE cannot provision {} to {}", name, mac);
        return null;                                     // WLAN dropped entirely
    }
```

So a **transition-mode** WLAN degrades quietly, while a **WPA3-only** WLAN would
be dropped from the device altogether with that one server-side log line.

`CVir()` tests **bit `0x1` of `radio_caps2`** — see the next section for the
field-level trace. openUF used to send `radio_caps` (the MIMO column:
`0x8`/`0x10`/`0x20`/`0x4000000` for 1x1…4x4) and **no `radio_caps2` at all**, so
the bit was clear and every WPA3 WLAN was downgraded on every openUF device.
That is fixed: `radio_caps2 = 0x1` now ships on each SAE-capable radio -- `0x3` since
2026-09-28, bit `0x2` being what keeps 802.11r on a WPA3-only WLAN, plus `0x8` where hostapd
has OWE (see [Capability bitmasks](#capability-bitmasks)).

The emission side is gated separately, on the WLAN alone
(`com.ubnt.service.config.j.rYtJfMBbtgWvku`: `isWpa3() || band == 6E`), and
produces `wpa3.support=enabled` + `wpa3.transition=enabled|disabled` — the keys
openUF's `_parse_wifi_system_cfg` would need to read, since **SAE never arrives
as a `wpa.key.<n>.mgmt` value**. `SECURITY_MAP`'s `wpa3` → `sae` and
`wpa2/wpa3` → `sae-mixed` entries were unreachable for exactly as long as the
capability bit was missing; both are now exercised on real hardware. (An earlier note in this document read the
PMF keys as the controller's way of signalling WPA3-mixed for a madwifi-driver
model. That was wrong — PMF is just PMF, and the real signal is these two keys.)

### The capability is `radio_caps2` bit `0x1` — RESOLVED

`CVir()` is a bit test, and tracing which field backs it settles the whole
question. The chain, all from the 10.4.57 bytecode:

```
config gen (QSAkfnbfInKJ)   calls radio.CVir()
CVir()                      = (1 & ZPjpXpgFhJSgqk().orElse(0)) == 1
ZPjpXpgFhJSgqk()            -> impl field iBjnA          (com.ubnt.g.f.e.jRsSex)
iBjnA                       <- builder field SuUD
SuUD                        <- setter rMxwXnPhhdotvjERKoA(int)
that setter is called with  getInt("radio_caps2")        ← the wire field
```

`radio_caps` lands somewhere else entirely — builder `kJeOrfqt` → impl
`DbisCuTqoItCGd` → accessor `FJaWnIAautY()`, which is the MIMO column and
nothing more. **The two capability integers are not interchangeable, and the one
that gates WPA3 is the one openUF never sent.** It arrived as `0` on every
inform (the parser's `getInt` default), `0` fails the bit test, and so every
WPA3 WLAN was silently downgraded on every openUF device.

**Confirmed live end-to-end, 2026-08-01, real hardware.** Sending
`radio_caps2 = 0x1` (gated on `sysinfo.sae_supported()`) flipped the very next
config push:

```
aaa.1.wpa.key.1.mgmt=SAE          (was WPA-PSK)
aaa.1.wpa3.support=enabled
aaa.1.wpa3.transition=enabled
aaa.1.wpa3.ft.status=disabled
aaa.1.sae.anti_clogging=5   aaa.1.sae.sync=5
```

and both APs came up controller-driven, no manual step:

```
UCI:     encryption='sae-mixed'  ieee80211w='1'  ieee80211r='1'
         sae_sync='5'  sae_anti_clogging_threshold='5'
hostapd: wpa_key_mgmt = SAE FT-SAE WPA-PSK WPA-PSK-SHA256 FT-PSK
```

Note the push also carries `wpa3.ft.status=disabled` alongside `ft.status=enabled`
— the exact disagreement case described in the [`aaa.<n>` table](#aaan--per-ssid-security-and-behavior).

#### What was wrong before, and why

Three earlier claims in this document are now retracted:

1. *"`wpa3_supported` is the gate."* It is not read at all — see below.
2. *"`radio_caps`/`radio_caps2` bit `0x1` were both set live with no effect."*
   The conclusion was wrong. Whatever that experiment actually set, sending
   `radio_caps2 = 0x1` from the radio-table builder works reproducibly on both
   APs. Suspected cause: the config was never regenerated, so no push followed
   — a device-state change alone does not trigger one. Clearing the stored
   `cfgversion` and restarting forces a full push, which is how this was tested.
3. *"The capability comes from the controller's model registry, so no payload
   field can unlock WPA3."* The model registry exists —
   `getModel().radiosByBand().getOrDefault(band, EMPTY_DEVICE_MODEL_RADIO)`,
   with the U6-InWall's entry mapping `BAND_NA→2400`, `BAND_NG→570` — but it
   returns `com.ubnt.g.f.VVyiC`, a **different type** from the device radio DTO
   `com.ubnt.g.f.e.VVyiC` that `CVir()` is invoked on. It is not on this path.
   Checking the receiver type is what broke the deadlock.

`wpa3_supported` genuinely is inert, and that part stands: the only class
carrying the literal (`com.ubnt.net.k.aI.jRsSex`, a record of `wpa3Supported` /
`band6GHzSupported` / `oweSupported`) is **constructed, never parsed** — built
from an injected `com.ubnt.service.wifi` service, ignoring the device parameter
— and reading the persisted device back confirms it: `radio_caps` round-trips
verbatim while `wpa3_supported` and `owe_supported` come back `undefined`.
openUF still sends it, because it is truthful and another version may read it,
but it unlocks nothing.

### What a transition-mode push looks like

Reconstructed from the emitters rather than captured, since no openUF device can
provoke one. Two classes produce it — `com.ubnt.service.config.eWivisHeQsnaqDtx`
for the WLAN block (prefix recipe `aaa.`, so keys are `aaa.<idx>.…`) and
`com.ubnt.service.config.ubntconf.OXMua` for the SAE sub-block — both behind the
same gate, `com.ubnt.service.config.j.rYtJfMBbtgWvku`:
**`isWpa3() || radioBand == 6E`** (that second clause is why 6 GHz always gets
WPA3). The key-mgmt method in full:

```java
String mgmt = "WPA-PSK";
if (gate(wlan)) {
    mgmt = "SAE";                       // replaces — never appended
    OXMua.emit(sb, wlan, "aaa." + i);   // the sae.* / wpa3.ft.status block
}
emit("aaa." + i, "wpa.key.1.mgmt", mgmt, "wpa.psk", wlan.getWpaPreSharedKey());
```

For a WPA2/WPA3 WLAN with PMF Optional and 802.11r on, that yields:

```
aaa.1.wpa=2                       # stays 2 — WPA3 never makes this 3
aaa.1.wpa.1.pairwise=CCMP         # the legacy flag is inverted under WPA3, so never "TKIP CCMP"
aaa.1.wpa.key.1.mgmt=SAE          # replaces WPA-PSK; both never appear together
aaa.1.wpa.psk=<psk>
aaa.1.wpa3.support=enabled
aaa.1.wpa3.transition=enabled     # "disabled" here means WPA3-only
aaa.1.wpa3.ft.status=enabled
aaa.1.pmf.status=enabled  aaa.1.pmf.mode=1  aaa.1.pmf.cipher=<cipher>
aaa.1.ft.status=enabled
```

plus, only when the site actually sets them: `sae.anti_clogging` / `sae.sync`
(each when > 0), `sae.groups.<n>.group` with `sae.has_groups=enabled` (from
`sae_groups`), `sae.psk.<n>.psk`/`.mac`/`.id`/`.vlan` (SAE private PSKs), and
`wpa3.enhanced_192=enabled` for EAP with Enhanced 192-bit.

**The structural trap:** `SAE` *replaces* `WPA-PSK` — the wire never carries
both, so the AKM set alone cannot distinguish transition mode from WPA3-only.
Only `wpa3.transition` does. Reading the AKM by itself provisions a mixed WLAN
as pure WPA3 and locks out every WPA2 client.

### The device side works — verified end-to-end

With the capability bit in place the controller sends transition mode of its own
accord, and openUF provisions it correctly on real hardware:

```
UCI:     encryption='sae-mixed'
hostapd: wpa_key_mgmt = SAE FT-SAE WPA-PSK WPA-PSK-SHA256 FT-PSK
         sae_require_mfp=1  sae_pwe=2  sae_groups=19 20 21
```

Live clients then split exactly as transition mode intends — a Pixel 9
negotiated `00-0f-ac-9` (FT-SAE) while older devices stayed on `00-0f-ac-2`
(WPA2-PSK) on the same SSID.

`wpad-mbedtls`, OpenWrt 25.12's ath79 default, does support SAE
(`sae_password`, `sae_groups`, `psk-sae` in `ap.uc`), so claiming it is honest
on that hardware.

### Fixtures must be verbatim command output

Three of the bugs found on real hardware were invisible to a green test suite
because the fixtures under `tests/fixtures/` were *tidier than reality*:

- `iw_station_dump.txt` had no `avg ack signal:` lines, so nothing caught an
  unanchored `signal:` pattern matching them and reporting every client at the
  ack value instead of its RSSI.
- `iw_phy_info_*.txt` carried an `HT TX Max spatial streams:` line that real
  ath9k/ath10k never emit, hiding that an HT-only radio has no source for `nss`
  at all and always fell back to 1x1.
- `iw_dev_info.txt` omitted the `ssid` and `multicast TXQ` blocks real output
  carries.

A fixture is a *recording*, not an illustration: paste real output from a real
device, including the lines that look irrelevant. The ones that look irrelevant
are exactly where unanchored patterns go wrong.

---

## Adopted from upstream (jonasevcik/openUF), 2026-09-06

This fork left upstream at `677f732`. Upstream's twenty commits of 1–2 September 2026 were
reviewed and the parts that were better than ours re-implemented here (not merged); the
hardware evidence below is **theirs**, gathered on a Xiaomi Mi Router AX3000T (mediatek/filogic
MT7981, OpenWrt 25.12.5) against the same model of gateway, and each item is marked with what
this fork has and has not re-verified on its own JioRouter boards.

| Finding | Evidence | Status here |
|---|---|---|
| A UCI section name may contain only `[A-Za-z0-9_]`; libuci discards anything else with `set()` and `commit()` both returning true | An SSID `openuf-verify` pushed, parsed, and never provisioned | Sanitizer fixed; our hash suffix keeps punctuation-only variants distinct. Mock cursors now refuse an invalid name |
| Minimum RSSI is `dBm = raw - 95`, not raw plus the live noise floor | UI -80 ↔ 15 and -85 ↔ 10 on every radio; the noise-floor version drifted -92…-75 across ath9k/ath10k/mt76 | Adopted; AP2's mt76 radios were exactly the -90/-92 case |
| `ft_psk_generate_local=1` disables FT-SAE | A station that negotiated FT-SAE reassociated with `auth_alg=sae` plus a 4-way, even between BSSes on one radio | Removed; OpenWrt's `auth_type`-keyed default derives the key holders |
| `kmod-nft-bridge` is required by the Blocker's `meta` rule and not implied by `nftables`; `kmod-sched-act-police` by the upload half of Speed Limit | Table and set built, only the drop rule rejected; `tc filter … police` failed with "Failed to load TC action module" | Both installers add them; both modules warn by name on rejection. **AP2 lacked both**, so its Blocker and upload cap were silently inert |
| The `ht` in `11naht40` is not a PHY request | 5 GHz radio came up HT40 on hardware that does HE160; a real U6-InWall runs the same token as HE40 | Adopted, in `rf_config` rather than the parser so it composes with the floor, ceiling, clamp and Force WiFi 4 |
| 2.4 GHz has no 80 MHz channel whatever the PHY | An HE 2.4 GHz radio reported `max_width` 80 and a pushed HE80 was fatal to hostapd | Adopted in `parse_phy_caps` |
| A tagged SSID needs no switch trunk on DSA; the 8021q device on the bridge port claims the VID before the bridge | `wan.10` on the `wan` bridge port carried VLAN 10 with `vlan_filtering` off | Consistent with AP2's `br-lan.10` on the bridge, which also works; both shapes supported via `sysinfo.lan_bridge` |
| Per-port VLAN on DSA as a bridge move (socket out of `br-lan`, into `br-openuf<id>`), never `bridge-vlan` | Verified on an mt7530: the driver accepts a user port in a second bridge; counters on the socket and the tagged uplink climb by the same amount | Adopted with their tests. **Not yet exercised on an mt7531** (the JioRouter switch, same driver family) |
| "Port VLAN off" can arrive as a `system_cfg` with no `switch.*` keys at all | Observed live after unticking the box | Adopted: absence counts as off while a reversibility ledger exists |
| Locate must restore the LED's previous trigger, persist it, and be torn down at startup | A radio LED stayed on the identify blink across three Locate cycles | Adopted with their tests |
| 802.11k beacon reports as an Environment-tab source | One request to one client returned 15 BSSes across both bands; 9 of 13 clients advertised no 802.11k | Adopted as `rrmscan.lua`, on by default (`rrm_enrichment`). Complements this fork's `neighbour_scan_interval` |
| `bridge fdb show br <bridge>` names the socket each MAC was learned on | Fixtures are real captures | Adopted, and it fixed a latent bug of ours: the whole-FDB read could pick the gateway's MAC as learned on the VLAN bridge's own port |
| Xiaomi Mi Router AX3000T profile | Adoption, LLDP, ports, wired clients, both radios, Locate, tagged VLAN all verified there | Adopted with `uplink_detect = "fdb"` and its board names added; **not run on this fork's hardware** |

Kept as ours where ours was stronger: atomic `state.json` writes and generic field
passthrough, the `_tick` error boundaries and debug switches, wire-value validation, the
per-pass ubus and `iw phy` caches, `--replace-conf`, the `iw` 6.17 parser fixes.

## Adopted from upstream (jonasevcik/openUF), 2026-09-13

Second review, covering upstream's 61 commits of 3–12 September 2026 (`d7d7e21..12b4db0`),
again re-implemented here rather than merged. As before, the hardware evidence is **theirs**
— an AX3000T and an Archer C5 against a UCG Ultra on Network 10.6.101 — and nothing below
has been re-verified on this fork's JioRouter boards. Roughly a third of their commits
turned out to be fixes this fork had already made on 2026-09-06 (the `_tick` boundary,
atomic state writes, wire validation, the announce fixes, the per-VAP BSSID, the iw 6.17
scan parser, the RRM benching, the ubus and `iw phy` caches, the HTTP 400 streak warning);
those were checked for equivalence and left alone.

| Finding | Evidence | Status here |
|---|---|---|
| A DSA socket moved into a VLAN bridge must have MAC learning **off**, or the ASIC's single address table hardware-drops every VLAN-tagged reply to it while outbound stays perfect | Captured at three points at once with a Trådfri hub on port 2: learning on, 4 DISCOVERs out and 0 replies anywhere; learning off, OFFER + ACK in 2 ms. An entry learned before the move cannot be deleted (ENOENT / EOPNOTSUPP) and ages out in ~140 s | Adopted: `switchvlan.dsa_apply` writes `openuf_brport<vid>_<socket>` with `learning '0'`; `ucihelper.ensure_vlan_network` does the same for the tagged uplink sub-device (`openuf_brport<vid>`), which the switch also files against the VLAN bridge; `prune_vlan_networks` and `dsa_restore` sweep both |
| Learning off empties `bridge fdb` for that socket, and on DSA the FDB is the ONLY wired-host source — so the port reported no clients and the controller credited them to the gateway | The wired IoT device listed under the gateway at GbE instead of under the AP's port 2 at FE. `vlan_filtering` + `bridge-vlan` would fix it at the switch (mt7530 sets `IVL_MAC`) but is blocked on netifd (openwrt#16314, #9089: every member incl. runtime VAPs needs an explicit `bridge-vlan`, and the 8021q sub-device would have to go) | Adopted: `switchvlan.reconcile_mac_taps` installs `table bridge openuf_learn` (sets `portmacs` and `portips`, 5-minute timeouts matching FDB ageing, one rule per set over every tapped socket); `sysinfo.mac_table(ifname, bridge, allow_tap)` reads it only for a socket whose bridge is not the uplink's and only when the FDB is silent. Rebuilt at startup from the UCI sections, left alone when it already matches |
| The controller files a wired client under a network by `mac_table[].vlan`, defaulting to 1 — not by the port's native VLAN and not by the IP it already holds | `com.ubnt.service.devmgr.isqI`: `if (network.getVlan() != host.getInt("vlan", 1)) continue;`; the dedup key is `mac .. vlan`; the client record copies `vlan` and drops a 1. With `vlan` and the tap's `ip` the live record read network IoT, vlan 10, Office AP port 2, FE | Adopted: `_filter_hosts` stamps each row with the VLAN of the bridge the socket sits in (`br-openuf<vid>`), nil on the management VLAN; the tap's second set harvests addresses from ARP and IPv4 (0.0.0.0 excluded), freshest wins, because the AP holds no address on that VLAN and `/proc/net/arp` can never answer |
| `port_table` asked the UPLINK's bridge about every socket, so a moved socket answered nothing even with learning on | Seen while tracing the above | Adopted: each socket asks `sysinfo.bridge_of` for its own bridge, memoized per pass; `forget_uplink_cache` after a switch push, since the 300 s TTL cannot see openUF moving a socket itself |
| An uplink port must carry no `mac_table` at all, gateway included: a port with exactly one known device files it into `downlink_table`, and the `isUplinkMac` guard is ANDed with `!is_uplink` | Both APs silent → each AP's `downlink_table` empty, the gateway's holding both. `last_connection` is never recomputed when the field is absent, so a stale Connection column is expected | Already our behaviour; the rationale recorded (feature 39) |
| A DSA map whose `lan_cpueth` names a socket announces one MAC and sources every frame from another (`br-lan` inherits the conduit's), and the gateway raises an IP conflict | Capture on `wan`: the reported address sending exclusively from the eth0 MAC | Adopted as `ucihelper.ensure_bridge_identity`, run once from `M.run`; pins `br-lan`'s `macaddr` to `lan_cpueth`'s only when they differ. **A no-op on this fork's maps**, whose `lan_cpueth` is `br-lan` itself |
| The blocker (nft) and speed limit (tc) are kernel state and were only ever built inside `apply_config`; after a reboot the controller replies `noop` and both stayed off while the UI showed them on | Verified in the validation lab once its UCI mock persisted; the `openuf_bcfilt*`/`openuf_ratelimit_*` stamps had never been read back | Adopted: `ucihelper.reapply_runtime_rules` rebuilds both from the stamps at startup, through the same `reconcile_runtime` `apply_config` uses |
| A controller-pushed static IP is `ip addr` state, died with the reboot, and the four `static_*` fields in `state.json` had no reader; and a raise between the apply and the tail-end save lost the record | The AP moved to its pushed address, usteer raised, `state.json` never learned about it | Adopted: `_reapply_static_ip` at startup, before `_populate_net_info`; the IP branch saves state the moment the interface changes |
| `rrmscan.collector_stop` had no caller: the detached `ubus subscribe` child outlived a disabled `rrm_enrichment` and a service stop, appending to a RAM disk forever; the procd reload trigger degraded to a restart on every LuCI wireless edit | Static analysis plus the 31.7 MB debug dump found the same week | Adopted: stopped from `_rrm_tick`'s disabled branch and from a real `stop_service()`; `service_triggers` dropped; the `pgrep` liveness check runs once a minute and is re-armed after a config push |
| `debug_dump_file` had no ceiling and lives on tmpfs | 31.7 MB after five weeks, 55% of a 59 MB `/tmp` | Adopted: 4 MiB cap, `debug_dump_max_bytes`, restart-with-marker rather than rotate |
| `conf.lua`'s `inform_url` and `state_file` were read by nothing | — | `state_file` was already honoured here; `inform_url` now seeds `state.DEFAULT_INFORM_URL` |
| `_state_mtime` forked `stat -c %Y` every heartbeat and fell back to the contents, which are the stronger token anyway | No stat applet on a WDR3500 | Adopted; `coreutils-stat` dropped from both installers |
| Six per-heartbeat costs: ARP and leases read once per socket, the ARL walked whole per socket, `bridge fdb show dev` forked per socket on DSA, the phy dump re-parsed per radio, `readlink`/`ip route` forked every 10 s, `lldpctl` forked every 10 s, `/proc/uptime` read per radio, `/etc/config/wireless` loaded three times | Measured with the new `tools/heartbeat-probe.lua` on the Archer C5 | Adopted: a `sysinfo` lookup pass mirroring ucihelper's, a 300 s uplink cache that never caches nil, the parsed phy caps cached with the text, a 60 s LLDP cache that never caches an empty answer, one `radio_rows` memo per pass with copies handed to each caller |
| `inflate` supplied zero bits past EOF and spun forever on a truncated stream | Found by writing the module's first tests | Adopted with `tests/test_inflate.lua` (Lua 5.1-safe `string.char`, not `\xNN`) |
| `sysupgrade` knows nothing about `/etc/openuf` or `conf.lua`; a firmware upgrade un-adopts the AP | `sysupgrade -b` listed 29 entries, neither among them | Adopted in `install.sh` with the four follow-up fixes (no trailing newline, uninstall keeps the state dir line, grep exit 2 leaves the file alone) |
| `cfg.vlan.device` had five readers and no producer | Every swconfig call addressed `switch0` regardless | Adopted: declared in all five swconfig maps, pinned by a modelmap test; `wan_name`/`wan_vlanid` and `uap.field` dropped as dead |
| `sae_anti_clogging_threshold`/`sae_sync` are not wifi-iface options; "Show AP Name in Beacon" never reaches a beacon | Schema, ucode and `hostapd.sh` checked on both boards | Adopted: writes and parser fields removed; features 26/27 re-graded |
| Test fixtures carried the author's real home-network MACs and addresses | — | Mapped one-for-one onto RFC 7042 / RFC 5737 documentation values here too, since this fork ships the same captures |

Kept as ours: `sysinfo.lan_bridge` (upstream resolves the uplink bridge with `bridge_of`,
which cannot handle a map whose `lan_cpueth` is the bridge itself), the `not uplink_unknown`
gate on wired clients, `keep_wlan_sections`, the `--replace-conf` installer flag, the
`/tmp/openuf-status` health file and `update.sh`, the `coreutils-stat` removal (upstream
still installs a package nothing reads). Not taken: upstream's README screenshots of their
own deployment.

## Adopted from upstream (jonasevcik/openUF), 2026-09-28

Third review, covering upstream's 26 commits of 25–27 September 2026 (`12b4db0..08d0003`,
tag `v0.9.3`), again re-implemented here rather than merged. The first seven of those
commits were upstream taking this fork's 2026-09-15 work (`sysconf.lua`, `l2guard.lua`, the
`noop` interval, the bootstrap re-lock guard) -- credited as such in their file headers --
and were checked for equivalence and left alone. The rest is new, and **every piece of
hardware evidence below is theirs** (an AX3000T and an Archer C5 against a UCG Ultra on
Network 10.6.101, plus their Docker lab on 10.4.57). Deployed to AP2 (build `d4c3460`) the
same day: rows 44, 45 and 49 of the feature matrix record what its first push showed, and
REVERSE-ENGINEERING.md backlog row 20 what is still owed.

| Finding | Evidence | Status here |
|---|---|---|
| Sibling openUF APs were listed as third-party APs impersonating the site's SSID: the controller decides `is_rogue` from the reporting AP's `is_unifi`/`serialno` alone and never consults its own devices' BSSIDs | Decompiled `com.ubnt.service.aS.rhAW`; all six sibling BSSes at upstream's home flagged | Adopted: every VAP beacons `vendor_elements` `dd0d 026f55 6f5546 01 <identity MAC>` (a private OUI, so a real UniFi AP cannot misparse it), `scan_table` joins it back over nl80211 through `ucode` (OpenWrt's `iw` prints no unknown vendor IE -- checked live on both of their boards), and a tagged BSS carries `is_unifi=true`, `serialno=<MAC>` |
| `iw` prints every non-ASCII SSID byte as `\xNN`, so "Café" reached the Environment tab as `Caf\xc3\xa9` and the evil-twin check could not match it | Seen live 2026-09-27 | Adopted: decoded in `scan_table`; a NUL-filled hidden SSID yields no `essid` |
| `band_steering_threshold` only biases usteer's load balancing and is inert with `load_balancing_threshold` 0; the real switch is `band_steering_interval`, whose non-zero default means a running daemon always steered | usteer source (`band_steering.c`, `policy.c`); confirmed in the running daemon with `ubus call usteer get_config` | Adopted: `usteer.lua` writes `band_steering_interval 0` for off and deletes it for on, with an `openuf_active` stamp; old thresholds are removed |
| The AP's own Band Steering setting arrives as `bandsteering.status`/`mode` (+ per-WLAN `vap.N.devname` pairs) only for a device claiming `wifi_caps` `0x4`; `0x8` keeps it on with a single-band WLAN present | Captured live on a real UCG Ultra; `equal` (Balance) has no usteer equivalent | Adopted: `_parse_bandsteering_system_cfg` / `_steering_flags`; Prefer 5G turns steering on, Balance logs once |
| Roaming Assistant (`wireless.<n>.btm_disassoc.status`/`.threshold`, 5 GHz vaps only) is emitted only with `wifi_caps2` `0x20`; usteer's own roam trigger is device-wide and its only scoping knob switches every usteer function off per SSID | Decompiled `ubntconf` (the −75/−88 constants); a −80 dBm client refused the BTM request (`status_code=4`), was disassociated 16 s later and reassociated on the −61 dBm AP within 1 s | Adopted as `roamassist.lua`: per-WLAN decision, BTM request then disassociation with a 30 s ban, only toward an AP that hears the client ≥ `roam_assist_diff_db` louder; `usteer.set_enabled` gains a third argument so the daemon runs for it with steering off |
| FT on a WPA3-only WLAN needs `radio_caps2` `0x2`; without it `wpa3.ft.status` is always `disabled` and no 802.11r goes out | Radio DTO `ytajcagDggPuTaL()` in the per-radio security filter; lab wire diff | Adopted: `0x3` wherever `sae_supported()` |
| Enhanced Open needs `radio_caps2` `0x8`; transition mode arrives as two VAPs per radio (open + hidden OWE, linked by `owe_devname`) that would collapse into one UCI section | Lab capture on 10.4.57 with `0xB` | Adopted: `owe_supported()` probes `hostapd -vowe` and the ucode generator, the parser keeps the open half with `owe_transition`, `get_ifnames_for_vap` covers the second BSS for stations, blocker and shaper. ⚠️ No OWE BSS on any real AP yet |
| Airtime Fairness (`atf.mode`) needs `wifi_caps` `0x20`; mac80211's per-phy `airtime_flags` (debugfs, 3 = TX+RX, 0 = off) is the only switch, and it resets on reboot | On confirmed on four radios against the real controller; the controller had `atf_enabled: false` stored from before the bit was claimed | Adopted as `airtime.lua`, `st.atf_enabled`, `_reapply_airtime` at startup, default restored on forget. ⚠️ Off is lab-only |
| Private Pre-Shared Keys need `wifi_caps` `0x100000`; the wire is `aaa.<n>.wpa.psk_file.<k>.psk`/`.vlanid` + `dynamic_vlan=1`, and OpenWrt's `wifi-station`/`wifi-vlan` sections already express them | Lab capture on 10.4.57 through to UCI | Adopted: `ppsk_supported()`, `ucihelper.ppsk_add`/`vap_vlan_ids`, `wlan_clear` drops the sections with their VAP, `bss_ifname` maps a VLAN netdev's stations back to their hostapd BSS, `switchvlan` trunks the keys' VLANs. ⚠️ No VLAN-key client on any real AP yet |
| The satisfaction estimate (signal vs. retry ratio) missed a failing link because retry counters mean different things per driver | See the `sta_table[].satisfaction` row above | Adopted: airtime / uplink rate / SNR terms, `hostapd_sta_caps`, `tx_duration` and per-direction width in `sta_table`, live width in `radio_caps` |
| A `setdefault` or out-of-process `reset-inform` left the l2guard table, the nightly cron job and a long controller interval behind | Reasoned from the code | Adopted: `_forget_controller` on both paths (`was_adopted` in `_reload_if_changed`) |
| A push that adds an SSID runs `wifi reload` asynchronously, so l2guard's VAP snapshot could miss the new netdev until the next push | Reasoned from the code | Adopted: `_l2guard_resync` once a minute, rebuilding only on a non-empty changed list |
| `_popen` drops stderr, so a refused `iw scan` was indistinguishable from a successful one; a plain scan on a beaconing AP sweeps the same channels as `ap-force` on ath9k/ath10k/mt76 | Compared channel by channel on their live APs, 2026-09-25 | Adopted: `_force_scan` (`ap-force` kept as a free guard, exit status judged, refusal logged) for both the spectrum-scan cmd and the 11k-scan |
| Full sweep of the controller's capability gates | Decompiled 10.6.101 | Adopted into [Capability bitmasks](#capability-bitmasks); WLAN Schedule recorded as the one unbuilt feature whose bits change the wire |

Kept as ours: `debug_caps`/`debug_payload_extra` (the masks above are still replaced whole by
an override), `state.lua`'s typed-passthrough design (`atf_enabled` added to the typed list),
`_maybe_scan_neighbours` and the rest of this tree's names, the unhandled ledger (which now
recognises `bandsteering.*` and `atf.*`), `update.sh`/`/tmp/openuf-status`, and this
fork's CLAUDE.md (upstream added its own; its Lua 5.1 and verification rules are folded in).
Not taken: their README screenshots, and their rename of the scan-request consumer.

## Feature matrix

Every controller-UI control exercised against a live openUF device. "Confirmed" means driven
through the real UI with the resulting wire payload captured or the effect verified.

| # | Control / feature | Wire mechanism | Status |
|---|---|---|---|
| 1 | Adopt (L2/SSH, L3/mgmt_cfg) | SSH `syswrapper.sh set-adopt`, or `authkey` in `mgmt_cfg` | ✅ Confirmed both paths |
| 2 | Baseline post-adopt inform | `setparam` + `mgmt_cfg` | ✅ Confirmed |
| 3 | SSID push (no VLAN) | `system_cfg` `aaa.*`/`wireless.*`/`radio.*` | ✅ Confirmed |
| 4 | VLAN-tagged network + SSID assignment | `aaa.<n>.br.devname = br0.<vlan>` | ✅ Confirmed. The switch trunk carries the CPU port and the uplink socket only — tagging the LAN sockets deafens untagged wired clients on `ar8216`-family switches, where the tag flag is one global per-port bitmask |
| 5 | Fast Roaming (802.11r) | `aaa.<n>.ft.status` only | ✅ Confirmed by byte-for-byte `system_cfg` diff, both directions |
| 6 | TX power / channel per radio | `radio.<n>.channel`/`.txpower`/`.txpower_mode` | ✅ Confirmed |
| 7 | Locate | `cmd:"set-locate"` | ✅ Confirmed, including the **LED hardware effect on a real board** (Archer C5, `dev.conf.led = "green:system"`): `locate_start` writes `trigger=timer` + 250/250 ms, `locate_stop` restores `trigger=none`, and the Manage → LED toggle drives `brightness` 1/0 |
| 8 | RF/spectrum scan trigger | `cmd:"spectrum-scan"` | ✅ Handler exercised **against real radios** — 27 channels on 5 GHz, 13 on 2.4 GHz, with genuine per-channel utilization and noise. Still **no manual trigger control exists anywhere in 10.4.57's UI** (AirView is passive), so it has never been fired *by the controller*; the handler was invoked directly on the device. |
| 9 | Firmware upgrade | `_type:"upgrade"` | ✅ Confirmed. openUF stores `upgrade_requested_version`/`_url` and logs — it never downloads, verifies, flashes, or reboots. Verified live: no side effects, device stayed Connected. The pushed `md5sum`/filename match Ubiquiti's real CDN artifact byte-for-byte. |
| 10 | Forget device / factory reset | `_type:"setdefault"` | ⚠️ UI action and server-side deletion work, but **no `setdefault` was ever dispatched on the wire**; handler unverified. See [open questions](#open-questions). Since 2026-09-28 the handler (and the `reset-inform` path) also tears down the l2guard table, the controller's cron block and a controller-set inform interval -- unit-tested only. |
| 11 | `fw.ver` acceptance | — | ✅ Accepted verbatim, no validation beyond storage |
| 12 | Restart | `_type:"reboot"` (top-level, **not** `cmd:"restart"`) | ✅ Confirmed; real container reboot observed |
| 13 | Manage LED on/off | `mgmt_cfg` `led_enabled` | ✅ Confirmed both values live. `led.set_enabled()` uses `trigger=none` + `brightness=1/0`, distinct from the locate blink's timer trigger. |
| 14 | IP Settings (DHCP/Static) | `system_cfg` `netconf.*`/`dhcpc.*`/`route.*` | ✅ Confirmed end-to-end: real kernel interface change, real route, informing from the new address, controller Overview reflecting it back |
| 15 | Power / PoE | `power_source`, `power_source_voltage`, `psu_table`, `power-monitor`, `total_max_power`, `led_state`, `outlet_table` — copied straight off the inform when present | 🔍 Not implemented. The "Power: -" element lives in the **Parent Device** subsection (properties of the upstream LLDP-linked switch), and this environment has no PoE switch. Field names confirmed; values/format not researched, and openUF has no local signal for a real PoE class. |
| 16 | Set Replacement Device / Load Configuration | **None** — controller-side Mongo document clone (`commonDeviceCloneConfigService`), then an ordinary adopt + `setparam` | ✅ Both confirmed live; zero product code needed. Replacement auto-adopts the target ~50 s after the source goes away. |
| 17 | Wired clients | `port_table[]` + per-port `mac_table[]` | ✅ Confirmed live: both fake hosts under Connection → Wired, on the correct port; Ports view renders them. Hosts are placed on the physical socket the switch learned them on (ARL table) as of 2026-08-02 — before that, real wired clients behind an AP were reported by nobody and the controller credited them to the gateway's port. Extended 2026-09-13 (from upstream's 2026-09-12 work): each socket is asked about its OWN bridge, a socket whose MAC learning is off is served by the `bridge openuf_learn` nft tap, and rows carry `vlan` (+ a tap-harvested `ip`) — which is what puts the client on the right **network**, not just the right port. See [Adopted from upstream, 2026-09-13](#adopted-from-upstream-jonasevcikopenuf-2026-09-13) |
| 18 | Per-port VLAN assignment | `fw_caps` bit `0x100`; controller pushes `switch.*` | ⚠️ Wire format fully mapped live 2026-07-19 (gate, per-VLAN table, per-port `pvid` + tagged/untagged/exclude matrix, teardown). The **controller side** is confirmed — it accepts the assignment and pushes an actionable table. Device-side apply on swconfig is unverifiable here (the validation AP has no switch); on DSA it is a bridge move adopted from upstream, verified there on an mt7530 — see [Adopted from upstream](#adopted-from-upstream-jonasevcikopenuf-2026-09-06). Note it was unreachable on both real boards until 2026-08-02: the only port they reported was the uplink, which is exactly the port that must never be reassigned |
| 19 | Client block / unblock | `cmd:"block-sta"` / `"unblock-sta"` | ✅ Confirmed live including real nftables enforcement and survival across a simulated reboot. `hostapd_cli` deauth is unit-tested only (no real hostapd here). |
| 20 | Environment / rogue-AP scan | `scan_radio_table[]` | ✅ openUF's payload and the controller's ingestion both confirmed correct (10/10 direct API polls). The tab's own display bug is [controller-side](#controller-side-ui-quirks). Since 2026-09-28 a sibling openUF AP is tagged `is_unifi`/`serialno` from its vendor element and non-ASCII SSIDs are decoded (both upstream's evidence, see [Adopted from upstream, 2026-09-28](#adopted-from-upstream-jonasevcikopenuf-2026-09-28)). |
| 21 | Radios tab + client MIMO/generation | `radio_table` capability fields; per-station `nss`/`is_11*` | ✅ Confirmed live on four stations spanning HT/VHT/HE/legacy |
| 22 | Radios tab Avg. Signal / Interference / Airtime / MIMO | `vap_table.avg_client_signal`; `radio_table.athstats`; `radio_table.radio_caps` | ✅ All four confirmed live on a fresh reset (`-64`/`-50 dBm`, `3%`, `7%`, `2x2`), with bidirectional filter behavior verified |
| 23 | Minimum RSSI | `system_cfg` `stamgr.<n>.*`; outbound `min_rssi`/`min_rssi_enabled` | ✅ Wire format and field names confirmed; conversion is the fixed `raw - 95` (corrected 2026-09-06 — the live-noise-floor version was wrong on every radio but one). Enforcement (`kick_station`) is unit-tested only — no real radios here. |
| 24 | Security tab WPA2/WPA3 protocol options | **None** | ℹ️ Not capability-driven from anything openUF sends. No security-capability field exists in the payload; `ucihelper`'s `SECURITY_MAP` (`wpa2`→`psk2`, `wpa3`→`sae`, `wpa2/wpa3`→`sae-mixed`, `wpa-enterprise`→`wpa2+ccmp`) is a one-way map of a choice the controller has already made. The dropdown's options come from the controller's own internal per-model database, keyed on the reported `model`/`platform`. Not fixable here. |
| 25 | Band Steering / BSS Transition / DTIM | `wireless.<n>.no2ghz_oui` / `aaa.<n>.bss_transition` / `wireless.<n>.dtim_period` | ✅ All three confirmed live by individual before/after `system_cfg` diffs. The off switch was inert until 2026-09-28 (`band_steering_threshold` is not usteer's switch; `band_steering_interval` is -- upstream's evidence, in the running daemon). |
| 26 | Show AP Name in Beacon | `wifi_caps2` bit `0x40` → `wireless.<n>.advertise_ap_name` | ⚠️ Wire protocol and capability gating confirmed live, both directions. **The OpenWrt side does not work and is not implemented.** openUF writes `wps_device_name` + `ap_setup_locked` (both valid wifi-iface options — present in the schema and in `/usr/share/ucode/wifi/`), but OpenWrt emits the WPS/WSC block that carries `device_name` only under `if (config.wps_possible && length(config.config_methods))` (`ap.uc:227`), and `config_methods` is populated solely from `wps_pushbutton`/`wps_label`. openUF sets neither, so WPS never activates and no WSC Device Name IE reaches a beacon. Upstream verified 2026-09-10 on an Archer C5 (ath79) and an AX3000T (filogic), both 25.12.5, same gate on both; no live BSS conf carries any WPS key. Turning WPS on to broadcast a name trades a real security surface for a cosmetic feature — deliberately not done. |
| 27 | SAE Anti-clogging / Sync Time | `aaa.<n>.sae.anti_clogging` / `.sae.sync` | ❌ **Not applicable on OpenWrt.** Key names, integer shape and `isWpa3()` gating are confirmed via an unambiguous decompiled method body, and the emitting (true WPA3) case could not be live-diffed — forcing pure WPA3 tripped the [config-sync issue](#config-sync-can-get-stuck-after-informs-stabilise). It does not matter: `sae_anti_clogging_threshold` and `sae_sync` are real hostapd config keys but are **not** wifi-iface UCI options. Upstream verified 2026-09-10 on an Archer C5 (ath79) and an AX3000T (filogic), both 25.12.5, against all three places an option can be declared — the wifi-iface schema, `/usr/share/ucode/wifi/` and `hostapd.sh`'s `config_add_*` lists. Neither name appears in any of them, on either board, so openUF's writes were stored in UCI and dropped in silence. Both writes removed (2026-09-13 here); the wire keys are no longer parsed either, since nothing could consume them. |
| 28 | PMF (802.11w) / Multicast Enhancement | `aaa.<n>.pmf.status`/`.pmf.mode`; `wireless.<n>.mcast.enhance` | ✅ Confirmed live by `system_cfg` diff. PMF is what actually carries WPA2/WPA3 transition intent on this model. |
| 29 | Channel width | `radio.<n>.ieee_mode` → `wifi-device.htmode` | ✅ Confirmed live both directions: `11nght20`↔`11nght40` follows the per-AP 2.4 GHz Channel Width control, and the pushed value reaches UCI (`radio0` `HT20`, `radio1` `HT40`). Previously parsed by nothing, so width never applied. |
| 30 | IoT Optimization: Lock 2.4 GHz to Channel 6 | `radio.<n>.channel` (no dedicated key) | ✅ Confirmed live end-to-end: the toggle changes the 2.4 GHz radio's `channel` from `auto` to `6`, and UCI `radio0.channel` follows (verified 11 → 6, so it is not a coincidence of the default). |
| 31 | IoT Optimization: DTIM Interval Lock | `wireless.<n>.dtim_period` (no dedicated key) | ✅ Confirmed live end-to-end: pins the 2.4 GHz vap's `dtim_period` to `3` (REST `iot_dtim_lock` → `dtim_ng: 3`), which reaches UCI. |
| 32 | IoT Optimization: Force WiFi 4 Mode | `wireless.<n>.iot` + `wireless.<n>.qbssload` | ✅ **Fully confirmed on real hardware** (JIDU6101 / MT7986, OpenWrt 25.12.5, UCG Ultra 10.6.101). Wire signature by before/after diff: `wireless.1.iot=enabled`, `wireless.1.qbssload=disabled`, `wireless.1.parent=radio0` — 2.4 GHz only, the 5 GHz VAP is dropped from the push entirely. Both keys reach UCI (`openuf_iot=1`, `bss_load_update_period=0`), and the previously-unverified hostapd side was read back out of the generated `/var/run/hostapd-phy0.conf`: `bss_load_update_period=0`, `bss_transition=0`, `ieee80211w=0`, `wpa=2`, `wpa_key_mgmt=WPA-PSK`. **`radio.<n>.ieee_mode` is NOT changed by this mode** (stayed `11nght40`), which is what makes a board `htmode_floor` collide with it — see the suppression in `ucihelper.rf_config`. |
| 33 | Proxy ARP / Client Isolation | `aaa.<n>.proxy_arp` / `wireless.<n>.l2_isolation` | ✅ Confirmed live 2026-07-18 by REST-toggling `wlanconf.proxy_arp` + `l2_isolation` and diffing `system_cfg`: exactly these two keys flipped `disabled`→`enabled`, on **both** the 2.4 GHz and 5 GHz entries of the WLAN, nothing else moved. Both are always present on their block, so "off" is explicit. `proxy_arp` had been visible in the Force WiFi 4 Mode diff all along but was never parsed. |
| 34 | Minimum Data Rate Control | `wireless.<n>.minrate_data` (+ `beacon_rate`, `mgmt_rate`, `minrate_cck_rates.status`, `minrate_below_disable`, `pureg`) | ✅ Confirmed live 2026-07-18 by REST-setting `minrate_setting_preference=manual` + `minrate_ng_data_rate_kbps=12000` and diffing: `minrate_data`/`beacon_rate`/`mgmt_rate` 1000→12000, `minrate_cck_rates.status` true→false, `pureg` 0→1. Separately confirmed **not band-gated** — enabling `minrate_na` (24 Mbps) made the same keys appear on the 5 GHz entries. **The OpenWrt side is radio-level**, not per-BSS (verified in OpenWrt's `hostapd.sh`: these are `hostapd_common_add_device_config` options), so openUF aggregates a radio's VAPs to the most permissive floor. Note `beacon_rate` is passed to hostapd **verbatim in 100-kbps units** while `basic_rate`/`supported_rates` are divided by 100 by `hostapd_add_rate` — openUF converts only the former. Not verified on real hardware. |
| 35 | Multicast and Broadcast Blocker | `wireless.<n>.bcfilt.status` + `bcfilt.<k>.mac`/`.status` | ✅ Wire format confirmed live 2026-07-18 across four diffs (on with one MAC, with two MACs, on with an empty list, off). Two keys already on the wire were **excluded** as candidates by the same diffs: `radio.<n>.bcmc_l2_filter.status` (sits at `enabled` with the control off) and `wireless.<n>.multicast.inspect` — neither moved. ⚠️ Enforcement is openUF's own nftables ruleset (`bridge openuf_bcfilt`), since no hostapd/OpenWrt option expresses a multicast allow-list; the generated ruleset is verified against real nftables 1.0.9 and confirmed not to collide with `firewall.lua`'s table, but the on-air effect is unverified (no real radios). |
| 36 | Hide WiFi Name | `wireless.<n>.hide_ssid` (+ duplicate `aaa.<n>.hide_ssid`) | ✅ Confirmed live 2026-07-18 by toggling the control in the UI and diffing `system_cfg`: exactly those two keys flipped `false`→`true`, on both band entries of the WLAN, nothing else moved. Always present, so "off" is explicit and is written back out as `hidden=0`. Note the `true`/`false` vocabulary rather than `enabled`/`disabled`. Previously **documented in USAGE.md as already applied, but no code read or wrote it** — the same doc-vs-code drift as `use_only_unifi_wlan`. |
| 37 | MAC Address Filter | top-level `macacl.<m>.*`, joined on `wireless.<n>.devname` | ✅ Confirmed live 2026-07-18 by enabling the control with one allow-listed MAC and diffing `system_cfg`: the whole `macacl` section appeared at once, keyed by devname (`ath0`/`ath2`) and numbered independently of `wireless.<n>`, so **the devname join is mandatory**. Two keys already on the wire were **excluded** by the same diff: `wireless.<n>.mac_acl.status`/`.policy` (sit at `enabled`/`deny` with the control off) and `aaa.<n>.radius.macacl.status` (the separate RADIUS MAC Authentication control). → OpenWrt `macfilter` + `maclist`, whose allow/deny vocabulary matches the controller's 1:1. Enforced by hostapd itself, so no openUF-side ruleset is involved. |
| 38 | WiFi Speed Limit | top-level `qos.vap.<m>.*`, joined on `wireless.<n>.devname` | ✅ Wire format confirmed live 2026-07-18 by creating a speed-limit profile (33/17 Mbps) and assigning it to a WLAN. Values are **kbps**, and the discriminator is the presence of `maxspeed` — an unlimited vap still gets a block, carrying only `minspeed` set to its raw `devspeed`. The cap is a **per-VAP aggregate**, not per-client. Requires a profile to exist before the per-WLAN toggle does anything. ⚠️ Enforcement is openUF's own `tc` ruleset (`shaper.lua`), since no hostapd/OpenWrt option expresses a throughput cap: HTB on egress for downlink, ingress policing for uplink. Every generated command is verified against real tc (iproute2 6.9.0), but the on-air throughput is unverified (no real radios). |
| 40 | Controller-scheduled `11k-scan` (cron) | `system_cfg` `cron.*` → `/etc/crontabs/root`; `syswrapper.sh 11k-scan` → the daemon's neighbour scan | ✅ Wire confirmed live 2026-09-15 (AP2). Device side: the block is written, crond runs it, the verb leaves a request the next heartbeat consumes, `iw scan` runs on every radio and the following inform carries the fresh `scan_radio_table`. Verified on AP2 by running the verb by hand — the 04:00 firing itself has not been waited for. |
| 41 | NTP servers and timezone | `system_cfg` `ntpclient.<n>.server`, `system.timezone` → UCI `system.ntp.server`, `system.@system[0].timezone` | ✅ Wire confirmed live 2026-09-15. On AP2 the timezone already matched (setup.sh had asked the same question) and the server list moved to `*.ubnt.pool.ntp.org` with the OpenWrt pool stamped as `openuf_ntp_orig`. Whether the jailed `sysntpd` then syncs is the open question from the same day: it had not in 30 minutes on the OpenWrt pool either, and the clock was stepped by hand. |
| 42 | `ebtables.*` hardening | `system_cfg` `ebtables.<n>.cmd` → nft `bridge openuf_l2guard` on the AP VAPs | ⚠️ Wire confirmed live 2026-09-15; the three generated rules are accepted by nft on AP2 (kmod-nft-bridge present). On-air effect (a client's BPDU or tagged frame actually dropped) not verified. Since 2026-09-28 the VAP list is re-read once a minute and the table is removed on a factory reset (unit-tested). |
| 39 | Ports view Connection column on an **uplink** port | `port_table[]` with **no** `mac_table` field on `is_uplink` ports | ✅ Blank (or a retained stale value) is the CORRECT state, verified upstream 2026-09-12. Reporting the one MAC on the other end of the cable is tempting — openUF knows it, since finding it is how the uplink socket is identified, and a real UniFi gateway visibly does it on its own uplink port — but it would invert the topology map: the controller files a known device seen alone on a port into this device's `downlink_table`, and the `isUplinkMac` guard against that is ANDed with `!is_uplink`, so it disables itself on exactly the port where it is needed. The gateway would hang beneath every AP that reported it. A real gateway escapes it only because the ISP's router is not an adopted device. Live proof of the correct shape: both of upstream's APs' `downlink_table` empty, the gateway's holding both APs. The stale text persists because `last_connection` is never recomputed when a port sends no `mac_table` field (and only ever recomputed when a port reports exactly **one** MAC) — clear it with the Ports view's **Clear Last Seen Device**. |
| 43 | Roaming Assistant | `wifi_caps2` bit `0x20` → `wireless.<n>.btm_disassoc.status`/`.threshold` (5 GHz entry only) | ⚠️ Adopted 2026-09-28. Upstream: wire, gate and teardown confirmed in their lab and against a real UCG Ultra; a −80 dBm client moved to a −61 dBm AP on real radios. Nothing between AP1 and AP2 yet |
| 44 | Device-level Band Steering (Prefer 5G / Balance) | `wifi_caps` bits `0x4`/`0x8` → `bandsteering.status`/`.mode` + `bandsteering.<n>.vap.<k>.devname` | ⚠️ Adopted 2026-09-28. Upstream: the real controller sends the block, Prefer 5G brings usteer's default interval back, Off sends `status=disabled`; a client steered by the device setting alone not observed. **AP2, 2026-09-28:** the real UCG Ultra sent `bandsteering.status=disabled` on the first push after the deploy (device setting Off); usteer was restarted with the old threshold removed and `openuf_active=1` |
| 45 | Airtime Fairness | `wifi_caps` bit `0x20` → `atf.status`/`atf.mode` → `/sys/kernel/debug/ieee80211/phyN/airtime_flags` | ⚠️ Adopted 2026-09-28. Upstream: On written and read back on four radios against the real controller; Off lab-only. The controller may hold `atf_enabled: false` from before the bit was claimed. **AP2 (mt7986/mt76), 2026-09-28: Off confirmed on hardware here** -- the first push after the deploy carried `atf.status=enabled`, `atf.mode=disabled` (the controller had held the setting from before the bit was claimed, exactly as upstream found) and both phys' `airtime_flags` read back empty; the scheduler stays off until the device panel says On |
| 46 | Enhanced Open (OWE) incl. transition | `radio_caps2` bit `0x8` → `wpa.key.1.mgmt=OWE` (+ `owe_devname` pair) → `encryption=owe`, `owe_transition=1` | ⚠️ Adopted 2026-09-28; upstream's lab wire capture only. No OWE BSS on any real AP |
| 47 | Private Pre-Shared Keys | `wifi_caps` bit `0x100000` → `aaa.<n>.wpa.psk_file.<k>.psk`/`.vlanid`, `dynamic_vlan=1` → `wifi-station` + `wifi-vlan` sections | ⚠️ Adopted 2026-09-28; upstream's lab wire capture through to UCI. No VLAN-key client on any real AP |
| 48 | FT on a WPA3-only WLAN | `radio_caps2` bit `0x2` | ⚠️ Adopted 2026-09-28; upstream's lab wire diff. An FT-SAE roam on a WPA3-only WLAN not verified on hardware |
| 49 | Sibling-AP recognition | `vendor_elements` on every VAP → `scan_table[].is_unifi`/`.serialno` | ⚠️ Adopted 2026-09-28; upstream saw the flags clear on their two APs. AP1/AP2 not on this build yet. **AP2, 2026-09-28:** after the forced re-push `vendor_elements=dd0d026f556f5546 01 <MAC>` is in both hostapd configs and on all three VAPs in UCI; AP1 not yet on this build, so no `is_unifi` tag has been seen on the wire. **✅ AP2 → AP1, 2026-10-03:** with both on the sibling-element build, AP2's `scan_radio_table` carries AP1's three BSSes with `is_unifi: true` and `serialno: <AP1 MAC>` (5 GHz ch 100 at −10 dBm, in 23 of 40 informs), and the controller's `stat/rogueap` (26 third-party rows) lists none of them — recognised, not flagged. (A device's own `stat/device` record never shows its scan table; look in `stat/rogueap`) |
| 50 | WLAN Schedule | `wireless.<n>.schedule_<day>` (+ `fw_caps` `0x1000`/`0x400000` change the shape) | ❌ Not implemented; keys go to the unhandled ledger |
| 51 | Wireless uplink / mesh | `wifi_caps` `0x1`+`0x800` → `wireless.<n>.usage=uplink\|downlink`, `wds=enabled`, `mesh.*` → `openuf_bh_dl_*` (hidden `wds 1` AP) / `openuf_bh_ul_*` (4addr `sta`, wired-first policy); reported back as `usage`-typed VAPs, `uplink` = the uplink VAP's name, the parent as its one station with `serialno` | ✅ **Verified end to end 2026-10-03** (AP2 cable pulled → joined AP1's downlink at −10 dBm, informed over the hop, VLAN-10 client reached its network; controller: AP2 `uplink.type=wireless`, `uplink_mac`=AP1, `is_mesh_v3`, `uplink_table`=[AP1], AP1 `wireless_downlink_macs`=[AP2]). Wire-return path verified 14:07 UTC (station disabled on the first heartbeat, controller back to the LLDP uplink). Multi-hop not yet exercised. Bits claimed by default on DSA boards |
| 52 | Quick Scan (Radios → Quick Scan; Radio AI prescan) | `wifi_caps2` `0x80` → `cmd: quick-scan {scan-band: 0\|1\|2, scan-bw: 20\|40\|80\|160}`; device: `quickscan_scanning` + `radio_table[].spectrum_table`/`spectrum_table_time` + an `EVT_AP_QuickScanEvent` notification inform | ✅ **Verified live 2026-10-03** on AP2 against 10.6.106: the REST cmd arrived (`cmd: quick-scan` in the log), the controller's `quick_scan_state` went `in_progress` and back, the event stamped `spectrum_scan_timestamp` and `stat/spectrum-scan` carries the rows — see [RF scans](#rf-scans-airtime-scan-quick-scan-and-radio-ais-sweep--2026-10-03) |
| 53 | Airtime Scan (Radios → Airtime) | `wifi_caps` `0x10` (RF_SCAN; the view also checks `wifi_caps2` `0x2` MONITOR_RF_SCAN) → `cmd: spectrum-scan`; device: `spectrum_scanning` + the same per-radio tables | ✅ Same handler and same live run (`cmd: spectrum-scan` arrived, every radio swept). The result view reads `stat/spectrum-scan`, never the device DTO (which strips the tables unless a scan is running) |
| 54 | Radio AI neighbour sweep | `cmd: scan_band {band: ng\|na}` (the controller's own scheduler, `XbYOtjBEpjeHWlUU`; it sets `scanning` and reads the next inform's `scan_radio_table`) | ✅ Handled 2026-10-03: a forced sweep on the named band; the verb itself was captured on AP1 2026-10-02 |
| 55 | Discovery requests (WiFiman Discovery, UniFi app, Device Discovery Tool) | UDP 10001 probes `01 00 00 00` / `02 08 00 00`, answered unicast with the announce TLVs under version 1 / command 0 and version 2 / command 9 | ✅ **Verified live 2026-10-03**: AP2 answered both probes (4 replies) after answering none; a UCG Ultra answers them identically — see [Discovery requests and WiFiman](#discovery-requests-and-wifiman--2026-10-03) |
| 56 | WiFiman (Settings → System → WiFiman) | Console-side only: `mgmt.wifiman_enabled` is never pushed to an AP; the app reads `/v2/api/site/<site>/wifiman/<its own IP>` on the console | ✅ **Verified live 2026-10-03**: the console answered fully for a laptop connected through openUF's AP1 (channel, link rates, experience history, `uplink_devices` chain, `nearest_neighbors` from openUF's scans). Nothing to implement in the inform; the device-side gap was row 55 |

---

## Open questions

- **`setdefault` is never dispatched.** Clicking Remove deletes the device server-side and
  flips the UI to "ready to adopt", but no `setdefault` reaches the wire and `state.json` keeps
  `adopted: true` with the old authkey. Whether a real `setdefault` is sent under different
  circumstances (e.g. only over SSH for L2-discovered devices, mirroring how initial adopt
  differs by discovery method) is unconfirmed. openUF's handler is untested but there is no
  evidence it is wrong.
- **`linkscore` and `multicast`** have no known source or reference; currently `0`. Needs a
  live capture from real hardware.
- **`bootrom_version`** has no counterpart in the device schema. Probably ignored.
- **The `spectrum-scan` cmd handler** has never received a real controller-issued command.
- ~~**openUF's `usteer` config option names**~~ — ✅ resolved upstream 2026-09-10, verified
  against the installed package; the option names and the named `local` section are both
  correct.
- ~~**hostapd's acceptance of `wps_device_name`/`ap_setup_locked`**~~ — ✅ resolved upstream
  2026-09-10: the option names are valid, but OpenWrt never emits the WPS block that would
  carry them (see feature 26). The feature is now documented as not implemented.
- **SAE anti-clogging / sync time** cannot be applied on OpenWrt at all:
  `sae_anti_clogging_threshold` and `sae_sync` are real hostapd keys but are declared in no
  wifi-iface schema, no ucode generator and no `hostapd.sh` `config_add_*` list, on either
  of upstream's boards. openUF no longer writes them (see feature 27).
- **PoE self-reporting** could be reopened if the validation environment ever gains a real
  switch container, or if a non-Parent-Device UI surface for those fields is found.

---

## Dead ends — do not re-attempt

- **Extracting the AP→controller protocol from U6-InWall firmware.** The official image
  (`v6.8.2+15592`, pulled from `fw-update.ubnt.com`, md5
  `0fec04452cadd2d025777d36ab2974ea`) is a **kernel-only OTA delta**. Its GPT has 5 partitions
  of which only `HLOS` has data; there is no system/rootfs/application partition at all.
  `HLOS.img` is at flat 8.0 bits/byte entropy across ~95% of the file (computed per-1MB block,
  not eyeballed from a binwalk graph), with no compression magic and zero `strings` hits for a
  kernel banner, driver names, or any of `scan`/`spectrum`/`rssi`/`noise`/`channel`/`bssid`.
  Only the last ~1.3 MB is plaintext, and that is device-tree blobs. The inform-client binary
  simply is not in this artifact. Untried alternatives if this ever matters: a pre-2023 build
  that might predate encrypted/kernel-only packaging; pulling the binary off a live owned
  device over SSH; or a LAN packet capture between real hardware and a real controller.
- **Chasing `wait_for_initial_inform` as a thing in itself.** It is downstream of
  [the GCM gate](#the-gcm-provisioning-gate). Editing it in Mongo does nothing (the process
  never re-reads), and restarting the controller to force a reload introduces a separate
  "Offline" artifact.
- **Looking for a manual RF-scan trigger in 10.4.57's UI.** There isn't one — AirView is fed
  entirely by passive, continuously-collected stats. Settings search for "spectrum" returns
  nothing, and no `_type:"cmd"` arrives on its own while the page is open.
- **`strings` on concatenated Java class files on macOS.** `0xCAFEBABE` is both the Java class
  magic and the Mach-O fat-binary magic, so macOS `strings` chokes. Extract printable-ASCII
  runs in Python instead.
- **Deleting a stale wireless client record and waiting for it to reappear.** The pattern works
  for wired clients but wireless ones never came back (45+ s). Recreate the WLAN instead.
