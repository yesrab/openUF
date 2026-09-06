# openUF — Usage Guide

## 1. Dependencies

Install the following apk packages on the OpenWrt device before running openUF.
OpenWrt 25.12 replaced `opkg` with `apk`; on 24.10 and earlier substitute
`opkg update` / `opkg install`.

```sh
apk update
apk add lua lua-cjson luasocket lua-openssl luabitop libuci-lua iw lldpd nftables hostapd-utils usteer ip-bridge tc-tiny wpad-wolfssl
```

| Package | Purpose |
|---|---|
| `lua` | Lua 5.1 runtime |
| `lua-cjson` | Fast JSON encode/decode |
| `luasocket` | TCP client for HTTP POST to controller |
| `lua-openssl` | AES-128-CBC **and AES-128-GCM** (replaces `luacrypto`, which was dropped from the 25.12 feeds). Effectively mandatory — see the GCM note below |
| `luabitop` | bit operations for Lua 5.1 |
| `libuci-lua` | `require("uci")` — **every** wireless read and write goes through it (`ucihelper.lua`, `switchvlan.lua`, `usteer.lua`). Not pulled in by `lua`. Its absence is openUF's most invisible failure: the device adopts, reports its ports and statistics and looks perfectly healthy, but `radio_table` goes out **empty**, so the controller has no radio to provision a WLAN onto and not one pushed SSID is ever created. Confirmed on real hardware — four pushed WLANs, zero UCI sections, nothing logged. `openuf` now shouts about it at startup and `tools/check.sh` tests for it |
| `iw` | Radio and station statistics |
| `lldpd` | LLDP topology announcement and neighbor discovery |
| `openssl-util` | `openssl` CLI — last-resort AES-**CBC** fallback if `lua-openssl` is unavailable. This path cannot do GCM, so it is not sufficient to complete adoption on its own |
| `nftables` | Client block/unblock (`openuf/firewall.lua`) **and** the Multicast/Broadcast Blocker (`openuf/bcfilter.lua`). ~490 KB with its kernel modules — the first thing that won't fit on a small-flash board, which leaves both features unavailable (openUF logs that rather than pretending) |
| `kmod-nft-bridge` | The Multicast/Broadcast Blocker only. `nftables` does not pull it in, and without `nft_meta_bridge` the bridge family has no `meta` expression — so the blocker's drop rule is rejected while its table, chain and allow-list set all build normally, and the control reports success while filtering nothing. openUF now logs the rejection and names this package. Client block/unblock matches on `ether saddr` alone and does not need it |
| `kmod-sched-act-police` | The **upload** half of WiFi Speed Limit. `tc-tiny` brings `sch_htb` (download) but the ingress `police` action is a separate module a stock filogic image lacks, so only the download cap applied. openUF logs the rejection and names this package |
| `kmod-leds-gpio` | Only on a board whose device tree declares GPIO LEDs the image has no driver for (an AX3000T registers nothing but its radio LEDs, which are wired to nothing). `install.sh` adds it when it sees that situation |
| `hostapd-utils` | `hostapd_cli` — immediate deauth of a just-blocked wireless client, client kick (Roaming Assistance) and Minimum RSSI enforcement |
| `tc-tiny` | `tc` — WiFi Speed Limit (`openuf/shaper.lua`). Busybox has no `tc`; without it the limit is recorded in UCI and never enforced |
| `coreutils-stat` | `stat` — only if your build has no `stat` applet (some do not). `inform.lua` uses `stat -c %Y` to notice an out-of-process `state.json` write, i.e. an SSH `set-adopt` or a manual `reset-inform`; without it those are ignored until restart. Enabling busybox's own `stat` applet is smaller |
| `usteer` | Band Steering (Behavior Controls) — ubus-based client-steering daemon, driven by `openuf/usteer.lua` |
| `wpad-wolfssl` (or `wpad-openssl`, `wpad-mbedtls`, `wpad`) | Full hostapd build with 802.11k/v support — required for BSS Transition and Band Steering. Any of the full builds will do; `wpad-basic-*` lacks `bss_transition` entirely and errors with "unknown configuration item 'bss_transition'" |

`install.sh install` installs all of the above automatically when missing, so a
manual `apk add` is only needed if you're not using the installer. It treats any
full `wpad` build as sufficient and leaves an existing one alone — notably
`wpad-mbedtls`, which is what OpenWrt 25.12 ships on ath79 — rather than swapping
it for `wpad-wolfssl` and bouncing every SSID on the device for no gain.

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
`install.sh` installs it for you when — and only when — the URL it finds (the
adopted `state.json`, else `conf.lua`'s default) actually is `https://`.

---

## 2. Installation

### The guided installer (`setup.sh`)

```sh
wget -qO- https://raw.githubusercontent.com/yesrab/openUF/main/setup.sh | sh
```

This is the path to use unless you have a reason not to. It does everything in this
guide's sections 1–3 plus the access-point conversion, in an order chosen so a failure
never leaves the device unreachable — see the README's Quick start for the phase list
and the reasoning.

Piping into `sh` and still being able to answer questions works because the script
re-execs itself from a file with stdin reattached to `/dev/tty`: on a pipe, stdin *is*
the script, so a `read` would otherwise eat the script's own remaining bytes. With no
controlling terminal at all (cron, a provisioning system) it says so and takes the
default answer for everything.

| Option | Question it answers | Default |
|---|---|---|
| `--ap-mode` / `--no-ap-mode` | convert to a pure AP? | yes |
| `--absorb-wan` / `--no-absorb-wan` | WAN socket into the LAN bridge? | yes |
| `--lan-address ADDR` | `dhcp`, `192.168.1.20/24`, or `192.168.1.20,255.255.255.0` | `dhcp` |
| `--lan-gateway IP`, `--lan-dns "IP [IP]"` | for a static address | — |
| `--modelmap NAME` | hardware profile, or `auto` to generate one | detected board, else a generic by radio count |
| `--controller HOST` | IP, hostname, or a full inform URL | none (L2 discovery) |
| `--bootstrap` / `--no-bootstrap` | create the `ubnt`/`ubnt` adoption account? | yes |
| `--exclusive-wlan` / `--shared-wlan` | `use_only_unifi_wlan` | exclusive |
| `--country CC` / `--no-country` | regulatory-domain override, 2-letter ISO code | none |
| `--l2-announce` / `--no-l2-announce` | L2 discovery broadcasts | derived (see below) |
| `--reboot` / `--no-reboot` | reboot at the end? | yes |
| `-y`, `--yes` | take every default, ask nothing | — |
| `--keep-work` | leave the downloaded tree in `/tmp` | — |

`OPENUF_REPO=owner/repo`, `OPENUF_REF=branch-or-tag` and `OPENUF_SRC=/path/to/checkout`
point it at a different source.

**The derived L2 setting.** `l2_announce` ships `true` and that is what makes the AP
appear in the controller by itself — but a controller that discovered a device over L2
insists on adopting it over SSH, and fails with "Connection Interrupted" if it cannot log
in, no matter how healthy the inform loop is. So when there is neither a bootstrap account
nor a root password, `setup.sh` turns broadcasts **off**: the controller then treats the
device as L3-discovered and delivers the adoption key over the inform channel, needing no
login. Override either way with `--l2-announce` / `--no-l2-announce`.

**What the AP conversion changes.** All reversible, and all of it committed but not applied
until the reboot:

| | Change |
|---|---|
| `network` | `wan` and `wan6` interfaces deleted; the WAN socket moved to the LAN side (see below); `lan` set to DHCP or the given static address; `ip6assign` dropped |
| `dhcp` | `dhcp.lan.ignore=1`, `dhcp.wan` deleted |
| services | `firewall`, `dnsmasq`, `odhcpd` stopped and `disable`d — packages kept, so re-enabling is one command each |
| resolver | `/tmp/resolv.conf` relinked to `resolv.conf.auto`, since nothing listens on 127.0.0.1 once `dnsmasq` is off and a hostname inform URL would stop resolving |
| `wireless` | `disabled='1'` removed from each radio — a fresh OpenWrt ships them off, and openUF only writes that option when the controller explicitly pushes a radio status |
| `lldpd` | `cid_interface` set to the profile's `lan_name` (section 7 explains why) |

An interface with proto `pppoe`/`wwan`/`dhcpv6`/etc. is **named and left alone** rather
than deleted — it may be a management link, and deleting a section the script did not put
there is worse than leaving it.

#### Moving the WAN socket to the LAN side

"The WAN port" is a different kind of object on the two switch generations, so this is
two different jobs:

- **DSA** — `network.wan.device` is the *socket's own* netdev (`wan`), so adding it to the
  LAN bridge genuinely puts that socket on the LAN, and traffic between it and a LAN socket
  stays inside the switch ASIC. This is the canonical dumb-AP recipe and what `setup.sh`
  does.
- **swconfig** — `network.wan.device` is a *CPU* netdev (`eth0` on an Archer C5, or
  `eth0.2` on a tagged-CPU board) reaching a socket the ASIC has segmented into its own
  VLAN. Bridging that netdev into `br-lan` works, but every frame between the WAN socket
  and a LAN socket then hairpins through the SoC — switch → CPU port → bridge → other CPU
  port → switch. On a 720 MHz QCA9558 that is the difference between wire speed and roughly
  100 Mbit/s, and it burns CPU openUF needs.

  So on swconfig `setup.sh` does the real fix instead: it rewrites the `config switch_vlan`
  sections, appending the WAN VLAN's non-CPU ports to the LAN VLAN and deleting the WAN
  VLAN. The socket becomes an ordinary LAN socket, switched in hardware, and the WAN CPU
  netdev is simply left unused. On an Archer C5 that is physical port 1 joining
  `ports '2 3 4 5 0'` and the VLAN 2 section going away.

  Because a wrong move here reassigns the wrong socket — and the first symptom is a device
  that does not come back from the reboot — it proceeds **only** when all of these hold,
  and otherwise falls back to bridging the netdev and says so:

  - the chosen profile declares `dev.conf.vlan` (the CPU port numbers) and
    `dev.conf.net.lan_vlanid`. UCI's port lists are bare numbers; which of them are CPU
    ports is board truth that lives only in the profile
  - exactly one `switch_vlan` section carries the LAN VLAN id
  - exactly one *other* `switch_vlan` section exists, on the same switch device
  - that section has at least one non-CPU port to move (a `t`/`u` suffix is stripped
    before the comparison, so a tagged CPU port is never mistaken for a socket)

  A side effect worth knowing: openUF suppresses wired clients on any socket whose pvid is
  not the management VLAN, so before this change the Archer C5's WAN socket reported no
  hosts even with a cable in it. Afterwards it is on VLAN 1 and reports them normally.

openUF's own nftables tables live in `bridge openuf` and `bridge openuf_bcfilt`,
deliberately outside `fw4`'s `inet fw4`, so client Block/Unblock and the Multicast and
Broadcast Blocker keep working with the firewall service off.

### By hand

Download the source tree directly on the device over SSH — no git client or scp required.
`install.sh` comment-strips the Lua on the way in (`tools/strip.lua`), so the device gets
the same lean tree a release would ship:

```sh
# On the OpenWrt device
wget -O openuf-src.tar.gz https://codeload.github.com/yesrab/openUF/tar.gz/main
tar xzf openuf-src.tar.gz && cd openUF-main
sh install.sh install
```

Releases are tagged `vX.Y.Z`; each tag push builds and publishes a pre-stripped
`openuf.tar.gz` plus its `.sha256` via GitHub Actions under
`https://github.com/yesrab/openUF/releases`, and those install the same way. If you're
working from a git checkout instead (e.g. for development), the old transfer-then-install
flow still works:

```sh
# From your development machine
scp -r openuf/ install.sh setup.sh tools/ root@<device-ip>:/tmp/openuf/
ssh root@<device-ip> "cd /tmp/openuf && sh install.sh install"
# or, for the guided install from that same checkout:
ssh -t root@<device-ip> "cd /tmp/openuf && sh setup.sh"
```

`install.sh` does **not** touch the network configuration: a device installed this way is
still a router unless you convert it yourself. It works on both package managers — `apk`
on OpenWrt 25.12+ and `opkg` on 24.10 and earlier.

What `install.sh install` does:
- Copies `openuf/` to `/opt/openuf/` — **keeping an existing `conf.lua`** (the shipped
  default lands next to it as `conf.lua.dist`). That is what makes a re-run the upgrade
  path: `conf.lua` holds the modelmap the device was adopted under, and on a DSA board
  resetting it to the generic profile moves `lan_cpueth` and with it the identity MAC,
  after which the controller rejects every inform with HTTP 400. `--replace-conf`
  overwrites it deliberately; `setup.sh` passes that, since it has just rewritten
  `conf.lua` from its interview. Modelmaps are always replaced, so a board profile you
  edited on the device should be copied out first.
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
-- For TP-Link Archer C5 v1 (dual-band, board-specific):
dev = dofile("modelmap/archer-c5-v1.lua")

-- For TP-Link TL-WDR3500 v1 (dual-band, board-specific):
dev = dofile("modelmap/tl-wdr3500-v1.lua")

-- For TP-Link WR1043ND v2 (single-band):
dev = dofile("modelmap/tl-wr1043ndv2.lua")

-- For JioRouter AX6000 JIDU6101 (MT7986A / filogic — a DSA board):
dev = dofile("modelmap/jiorouter-ax6000-jidu6101.lua")

-- For JioRouter AX6000 JIDU6J01 / 6201 / 6401 / 6601 / 6701 (one map, all five):
dev = dofile("modelmap/jiorouter-ax6000-jidu6j01.lua")

-- For Xiaomi Mi Router AX3000T (MT7981 / filogic — DSA; adopted from upstream):
dev = dofile("modelmap/xiaomi-ax3000t.lua")

-- For any other dual-band OpenWrt AP:
dev = dofile("modelmap/generic-dualband-ap.lua")

-- For any other single-band OpenWrt AP:
dev = dofile("modelmap/generic-singleband-ap.lua")
```

`setup.sh` picks this line for you: each board-specific profile declares the OpenWrt
board names it is for in `dev.openwrt_boards` (the DTS compatible string, e.g.
`{"jiorouter,ax6000-jidu6101"}`), and the installer matches that against
`/tmp/sysinfo/board_name`. openUF itself never reads the field, so a profile without one
is still perfectly valid — but adding it is what makes a new profile get preselected on
every device like yours.

Prefer a board-specific map where one exists. A generic profile cannot know your
board's LED name (so Locate and the LED toggle do nothing) or which of its ports
is the uplink — and it gets the uplink wrong on an Archer C5 deployed as an AP,
which uses `eth1` and never touches `eth0`.

#### Radio policy (`dev.conf.radio`)

```lua
dev.conf.radio = {
	na = { acs_exclude_dfs = true, htmode_floor = "HE80" },
	ng = { htmode_floor = "HE20" },
}
```

| Field | What it does |
|---|---|
| `acs_exclude_dfs` | Writes UCI `acs_exclude_dfs=1` whenever the effective channel is `auto`, so hostapd's ACS chooses among **non-DFS** channels only |
| `channels` | Optional explicit ACS candidate list (UCI `channels` → hostapd `chanlist`). Narrower than `acs_exclude_dfs`, for a board that also needs specific channels excluded |
| `htmode_floor` | Raise a pushed `htmode` to at least this, kind and width independently. The hardware clamp still runs **after** it, so a floor can never invent capability. **Suppressed for a radio while any WLAN on it has "Force WiFi 4 Mode" on** — that mode is an explicit instruction, the floor is a correction for a controller default, and explicit intent wins |
| `htmode_max` | Lower a pushed `htmode` to at most this — for a width the driver *advertises* and the radio cannot actually run |

Both ACS options are torn down again the moment a concrete channel is pushed — they are
ACS-only inputs, and leaving them behind would silently resurrect the restriction the next
time **Auto** is selected.

**Why `acs_exclude_dfs` exists.** Controller channel **Auto** arrives as the literal
`channel=auto` and is handed to hostapd's ACS. On an MT7986 (JIDU6101) ACS reliably picks
a DFS channel the driver cannot start CAC on, and the radio is left **down** while the
controller happily reports the WLAN as provisioned:

```
phy1-ap0: ACS-COMPLETED freq=5260 channel=52
phy1-ap0: DFS-CAC-START freq=5260 chan=52 cac_time=60s
hostapd: DFS start_dfs_cac() failed, -1
phy1-ap0: interface state DFS->DISABLED / AP-DISABLED
```

With the flag set, the same radio came up first try — `ACS-COMPLETED channel=153` →
`AP-ENABLED`, live on channel 149 at 80 MHz. Note that a *maximum* channel is not a fix:
under `IN`, `iw phy` marks 52–64 and 100–144 "(radar detection)", so capping at 128 would
leave every failing channel in range while excluding 149–165, which are the ones that work.

**The PHY generation comes from the hardware, not from the wire.** What a real controller
sends is `radio.<n>.ieee_mode=11nght20` / `11naht40` — its vocabulary is Atheros-era (the
same push names the VAPs `ath0`/`ath1`/`ath2`), and that `ht` is *not* a request for 802.11n.
It is all this key has ever said: the **band** and the **width**. A real U6-InWall receiving
`11naht40` runs it as HE40. So openUF takes the width from the wire and the PHY from `iw phy`
(`ucihelper.best_phy`), then clamps as above — a 2.4 GHz-capable ax radio given `11nght20`
gets `HE20`, an n-only one gets `HT20`. Reading the token literally had pinned every 802.11ax
radio to 802.11n permanently, which is invisible in the controller (it shows the width, which
was right) and visible only in `iw dev`. An explicit `vht`/`he`/`eht` token, if one ever
arrives, is honoured as written, and a WLAN with **Force WiFi 4 Mode** keeps the radio on
HT, because that mode asked for an 802.11n beacon. (Found by upstream on an AX3000T; the
JioRouter maps had been compensating with an `htmode_floor`.)

**Why `htmode_floor` still exists.** The PHY is automatic now, but the WIDTH is what the
wire says, and a UCG Ultra pushes `11naht40` — 40 MHz — to this emulated U6IW at a 4x4
WiFi-6 radio, which threw away most of it (a client associated at MCS 15 / 144 Mbit/s).
That is a controller-side default for the model it thinks it is talking to rather than an
intent, so a board may declare a floor to raise the width back. This is the **one
exception** to openUF's otherwise absolute "clamp downward only" rule, which is why it is
opt-in per board and logged when it fires:

```
openuf: radio1: controller asked for htmode HE40, board floor is HE80 -- raised to HE80
```

`HE20` as the 2.4 GHz floor is now documentation rather than a correction: a pushed
`11nght40` keeps its 40 MHz and comes up HE40 with or without it. (2.4 GHz may still transmit
at 20 MHz on air — hostapd applies 802.11 40 MHz coexistence when it sees neighbouring BSSes.
That is standard behaviour, not a misconfiguration.)

**Why `htmode_max` exists.** A JIDU6101's `iw phy` reports `Supported Channel Width: 160
MHz`, so `clamp_htmode` passes `HE160` straight through — and the radio comes up **down**.
A 160 MHz block is 8 contiguous 20 MHz channels, and under `IN` every one that fits
overlaps DFS:

```
DFS-CAC-START freq=5180 chan=36 sec_chan=1, width=2, seg0=50, seg1=0, cac_time=60s
hostapd: DFS start_dfs_cac() failed, -1
hostapd: Interface initialization failed          -> AP-DISABLED
```

Channel 36 centres the block on `seg0=50` (channels 36–64, of which 52–64 are DFS);
channel 100 centres on 114 (100–128, all DFS). The only clear range, 149–173, is seven
channels — 140 MHz — and 177 is disabled, so no 160 MHz block fits there at all. With CAC
broken in this driver, 160 MHz is unreachable on any channel, and `acs_exclude_dfs` cannot
help because a **fixed** channel skips ACS entirely. No capability check can catch this —
only the board can say "advertised but unusable".

There is one way to get 160 MHz on such a board: change the **regdomain**, since that is
what applies the DFS flags in the first place. Under `PA` the same radio has no DFS
channels at all and 160 MHz comes up first try — see `country_override` in §3. If you use
it, raise `htmode_max` to `HE160` (or drop it) so the ceiling stops blocking what now
works.

#### swconfig boards vs DSA boards

Which of these your board is decides the whole shape of `dev.conf.net.ports`, and
getting it wrong is not cosmetic: a socket wrongly treated as downstream makes the AP
report the entire LAN, gateway included, as hosts plugged into it.

On the **swconfig** boards (ath79 and other pre-DSA targets) the kernel sees only the CPU
port. sysfs therefore answers questions about the internal SoC↔switch link — always
1000/full — rather than about the socket a cable is in, and the bridge FDB attributes every
wired host to that one netdev. The switch knows all of it, so a profile there sets
`dev.conf.vlan` and lists sockets by `swport`.

On a **DSA** board (mediatek/filogic and later) every socket is its own netdev with its own
carrier, negotiated speed and slice of the bridge FDB. The switch detour is unnecessary and
`dev.conf.vlan` must be **absent** — setting it sends openUF down the swconfig path,
shelling out to a `swconfig` that is not installed. Ports are listed by `ifname`, and the
uplink socket is found in the bridge FDB by setting:

```lua
dev.conf.net.uplink_detect = "fdb"
```

That looks up the default gateway's MAC and reports whichever socket learned it as
`is_uplink`. When it cannot answer — no default route yet, no `bridge` binary, gateway not
learned — openUF reports the ports but **no wired clients at all**, rather than attributing
the LAN to a guessed socket. Two more DSA differences:

- `lan_cpueth` names the LAN **bridge** (`br-lan`), not a socket. It decides the device's
  identity MAC, which must not depend on which of four equally-valid sockets the installer
  used; it is where the management address lives; and a tagged SSID's sub-device has to
  hang off the bridge (`br-lan.20`) — one on a bridge *port* never sees a frame.
- Per-port VLAN assignment is unavailable. `switchvlan.lua` detects DSA and refuses rather
  than guessing at a swconfig port map.

The modelmap sets:
- `dev.openwrt_boards`      — the OpenWrt board names this profile is for, e.g.
  `{"tplink,archer-c5-v1"}`. Read only by `setup.sh`, to preselect the profile; openUF
  ignores it. Omit it on a generic profile
- `dev.conf.net.lan_cpueth` — LAN CPU ethernet port (e.g. `eth1`), or the LAN **bridge**
  (`br-lan`) on a DSA board; also the trunk the VLAN-tagged sub-interfaces
  (`<lan_cpueth>.<vlanid>`) for controller-pushed VLAN SSIDs hang off
- `dev.conf.net.uplink_detect` — `"fdb"` on a DSA board, to find the uplink socket in the
  bridge FDB instead of a swconfig ARL table. Omit it on a swconfig board, where the
  ARL lookup already covers it; the two are mutually exclusive
- `dev.conf.radio`         — per-band answers to things the controller states in terms it
  cannot know are wrong for this board. Keyed by openUF's band keys (`ng` = 2.4 GHz,
  `na` = 5/6 GHz), all three fields optional, and with no entry the behaviour is exactly
  as before. See **Radio policy** below
- `dev.conf.vlan.mib_poll_ms` — how often the switch driver refreshes its per-port byte
  counters, which is where the Ports view's Tx/Rx figures come from. openUF turns polling on
  at startup (500 ms) when the driver ships it off, which an AR8327 does; set `false` to
  leave the switch alone, at the cost of 0 B on every socket
- `dev.conf.net.ports`      — the ports openUF reports to the controller, one entry per
  **physical socket** on a board with a switch: `{idx = 1, swport = "lan1"}`, where `idx`
  is the UniFi `port_idx` and `swport` names a key in `dev.conf.vlan.ports`. Pin each
  `idx` to a socket and leave it alone — the controller keys per-port settings on it.
  Do **not** flag one as `uplink`: openUF detects which socket the uplink cable is in
  from the switch's ARL table, so the flag follows a replug and the other sockets report
  their own link speed and their own wired clients. A board with no switch map instead
  uses the netdev shape (`{idx = 1, ifname = "eth0", uplink = true}`), which on a switch
  board can report only the CPU port's internal link. The two mix: a socket wired to its
  own MAC/PHY instead of the switch (the TL-WDR3500's WAN socket, `eth1`) is listed with an
  `ifname` and no `swport`, and sysfs then describes that socket correctly. Count the RJ45
  sockets on the case — the list should have one entry each
- `dev.conf.net.wan_iface`  — WAN interface (e.g. `eth0`)
- `dev.conf.switch`         — Switch device name (e.g. `switch0`)
- `dev.conf.led`            — status LED, driven by the controller's Locate action and its
  **Manage → LED** toggle. Accepts a full sysfs path (`/sys/class/leds/tp-link:green:wlan`)
  or a bare LED name (`tp-link:green:wlan`). `nil` by default, since a generic profile can't
  know the board's LED — LED control is a silent no-op until you set it. Find yours with
  `ls /sys/class/leds`
- `dev.openuf.uap.ufmodel`  — Which ufmodel file to load (e.g. `"u6iw"`)
- `dev.openuf.uap.hwassign` — UCI radio names to report to the controller
  (e.g. `{"radio0", "radio1"}`). Every other `wifi-device` on the board is left out of
  `radio_table`, so a radio the emulated model doesn't have (a third phy, a mesh- or
  monitor-only one) is neither shown nor configurable in the UI. Omit it — or leave it
  empty — to report every radio UCI knows about, which is what a modelmap without the
  field means. openUF never touches an unreported radio: a config push naming one is
  refused rather than applied

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
    keep_wlan_sections  = {},    -- AP sections that option must leave alone (see below)
    inform_url  = "http://unifi:8080/inform",   -- default URL (overwritten at adoption)
    state_file  = "/etc/openuf/state.json",     -- honoured by inform, announce and syswrapper
    l2_announce = true,          -- see below
    debug_dump_file = nil,       -- see below
    debug_dump_requests = false, -- with debug_dump_file: record requests and HTTP errors too
    debug_caps = nil,            -- RESEARCH ONLY: override the claimed capability bits
    debug_payload_extra = nil,   -- RESEARCH ONLY: extra top-level payload fields
    neighbour_scan_interval = 0, -- seconds between background neighbour scans, 0 = never
    rrm_enrichment = true,       -- ask 802.11k clients to report neighbours (see below)
    rrm_request_interval = 600,  -- seconds between those requests, one client at a time
    country_override = nil,      -- see below
    bootstrap_adopt_user = nil,  -- see below
}
```

`keep_wlan_sections` — `wifi-iface` section names that `use_only_unifi_wlan` must never
switch off, e.g. `{"guest_legacy"}`. Sections whose `mode` is not `ap` (a mesh point, a
station interface) are exempt without being listed: a link is not a competing SSID, and it
may be this AP's own uplink. A listed section openUF had already switched off on an
earlier pass is switched back on. Non-AP sections are also left out of the reported
`vap_table` — they have no SSID and are not a BSS the controller can provision.

`country_override` — an ISO 3166-1 alpha-2 code programmed into the driver **instead of**
the one the controller pushes. `nil` (default) means the controller's own value is used.

It exists because the regdomain, not the hardware, decides which channels carry a DFS flag
— and DFS does not work on every driver. Measured on a JIDU6101 (MT7986/mt7915, which
cannot start CAC at all):

| Regdomain | 5 GHz channels 52–144 | 160 MHz |
|---|---|---|
| `IN`, `DE`, `US` | all `(radar detection)` | **impossible** — every block that fits overlaps DFS |
| `PA` | **no DFS flag at all** | works: `channel 44, width 160 MHz, center1 5250`, `he_oper_chwidth=2` |

The controller is still told its **own** country, not the override: openUF stamps the
controller's value per radio as `openuf_country` and `get_radio_table` reports that in
preference to the live `country`, so the site setting does not appear to have changed.
Clearing the option puts the controller's regdomain back into UCI and removes the stamp —
it never leaves a foreign regdomain programmed with nothing in the config explaining why.

> This programs a regulatory domain the device may not physically be in. Which channels may
> be used, and at what power, is a legal limit rather than a preference. That call belongs
> to whoever runs the AP, which is why the option is off unless deliberately set.

`l2_announce` — on by default; sends the UDP discovery broadcasts that make the
device appear in UniFi Discover with no `set-inform` at all. Set it to `false`
to be adopted over L3 only, and restart the service (the init script reads this
and simply doesn't start the broadcaster). The reason to turn it off isn't
noise: a controller that discovered a device via L2 adopts it *by SSHing in*,
so on a device that can't accept that login, adoption fails while the inform
loop looks perfectly healthy — see § 4.

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

`debug_dump_requests` — with `debug_dump_file` set, also append what openUF *sends*
(one line tagged `TX` per inform, every 10 s) and any transport failure (`ERR HTTP 400`,
`ERR connect failed: …`). Response lines keep their untagged shape, so the recipes in
REVERSE-ENGINEERING.md still work; `grep ' TX '` / `grep -v ' TX '` separates the two.

`debug_caps` and `debug_payload_extra` — **research switches; leave them `nil`.** The
rule everywhere else is that openUF never claims a capability bit it cannot honour,
because a claimed bit makes the controller push config and show UI for a feature that
then silently does nothing. These are the deliberate exception, for protocol
experiments (REVERSE-ENGINEERING.md's mesh plan): `debug_caps = {fw_caps = …,
wifi_caps = …, wifi_caps2 = …}` replaces the masks the payload claims (a mask left out
keeps its shipped value; `wifi_caps` is not sent at all unless overridden), and
`debug_payload_extra = {uplink = {…}}` merges extra top-level fields into every
payload verbatim. The daemon shouts at startup while either is set.

`neighbour_scan_interval` — seconds between `iw dev <if> scan` on each radio; `0`
(default) never scans. The Environment view is fed from the kernel's cached BSS list,
which forgets a network about 30 s after it was last seen, and the controller drops
anything with `age >= 30` on top — and nothing else in openUF scans, so after the
boot-time ACS sweep the list drains to empty. A scan takes the radio off-channel for a
moment (clients see a brief stall), which is why it is off unless you turn it on; `300`
is a sane value. The first scan happens one interval after start, never at boot.

`rrm_enrichment` / `rrm_request_interval` — client-assisted neighbour discovery, adopted
from upstream. Every `rrm_request_interval` seconds (default 600) openUF asks **one**
802.11k-capable client for an active beacon measurement: the *client* leaves the channel,
sweeps, and reports what it saw, while the AP keeps serving. This is the mechanism
Ubiquiti's Channel AI describes as *"neighbor reports and automated RRM scans"*, and the
no-cost complement to `neighbour_scan_interval` above. One answer returned 15 BSSes across
both bands upstream, and a client on 5 GHz routinely reports 2.4 GHz too. Only clients
advertising active or passive beacon measurement are asked (beacon-table-only clients
acknowledge and never answer); a minority of clients qualify, so this supplements the
passive cache rather than replacing it. Two refinements over upstream's version, both from
the first live run on AP2: the operating class follows the band the client is on (81 for a
2.4 GHz client, 115 for 5 GHz — a 2.4-only client answers a 5 GHz class with "incapable"),
and a client that advertises the capability but never produces a report is benched after
two unanswered requests for six hours, with one log line saying so, instead of being asked
forever. Rows sourced this way show a blank WiFi Name and
Security, because a beacon report carries neither — openUF will not invent a security mode
it did not measure. See § 6 for how to watch it work. `false` never sends a request; an
*absent* key means on, so a `conf.lua` kept across an upgrade (see § 2) picks the feature up
without an edit. The other new options default to off when absent.

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

> **The controller picks the adoption path from how it discovered the device,
> not from where it is.** A device it heard via L2 broadcast gets the SSH
> treatment above even when it sits on the controller's own subnet and informs
> perfectly — confirmed against a real UniFi OS gateway, which SSHed in three
> times on the Adopt click, failed (`Login attempt for nonexistent user`), and
> parked the device at **Connection Interrupted** while the inform loop kept
> running normally. If SSH can't succeed on your device, set
> `config.l2_announce = false` in `conf.lua` and restart: with no broadcasts the
> controller treats it as L3-discovered and delivers the key over the inform
> channel instead. Forget any device record created while broadcasts were on
> first — the controller remembers how it found it.

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
| `mac` | The identity MAC the previous run informed under (read off `lan_cpueth` at startup). Compared against the live one on the next start: a difference on an adopted device is the HTTP-400-forever condition, and is shouted about |
| `locating`, `led_enabled` | The controller's Locate and Manage → LED state, so a restart does not forget them |
| `swvlan_backup` | Original `ports` strings of the stock `switch_vlan` sections, snapshotted before per-port VLAN assignment first modifies them; used to restore them (see § 6) |
| `ip_mode`, `static_ip`, `static_netmask`, `static_gateway`, `static_dns` | The last "IP Settings" push. `ip_mode` is `"static"` or `"dhcp"`; the `static_*` fields are set only in static mode and cleared on a revert to DHCP. `static_dns` is an array in the controller's primary/secondary order, written to `/etc/resolv.conf`. On DHCP, DNS is left to the lease and openUF does not touch `resolv.conf` |

Every field `state.save` writes is read back by `state.load` (the eight in the JSON
above are type-checked and fall back to a default; anything else round-trips as-is). The
file is written through a sibling temp file and renamed into place, so a power cut
mid-write leaves the old file rather than a truncated one — and a truncated file would
be read as "defaults", which un-adopts the device. A non-empty file that does not parse
is reported on stderr for the same reason.

To reset to factory defaults:
```sh
syswrapper.sh reset-inform
```

---

## 6. WiFi provisioning

When the controller pushes a config, `ucihelper.lua` applies it via OpenWrt UCI.  Only sections prefixed with `openuf_` are created or deleted.

> **The `openuf_` prefix is a UCI *section name*, not an SSID filter.**  Every WLAN the
> controller pushes is provisioned, whatever it is called: the section is named
> `openuf_<radio>_<sanitized ssid>` while the broadcast SSID is exactly what the controller
> sent.  The prefix exists so openUF can tell its own sections from yours and never rewrite
> or delete a hand-made one — it does not mean openUF only picks up controller WLANs whose
> name starts with `openuf_`, and there is no way to ask it to.  What *is* configurable is
> whether your hand-made SSIDs keep broadcasting, which is `use_only_unifi_wlan` below.

`use_only_unifi_wlan` (default `true`) additionally sets `disabled=1` on every *other* AP-mode `wifi-iface`, so the radios carry only what the controller provisioned.  openUF stamps each SSID it turns off with `openuf_autodisabled=1`; setting the option back to `false` re-enables exactly those and leaves everything else as-is, so an SSID you had disabled yourself is never switched back on.  Set it to `false` from the start to keep hand-configured SSIDs broadcasting alongside the controller's, or list the ones to keep in `keep_wlan_sections` (§ 3).  Sections whose `mode` is not `ap` — a mesh point or a station interface, i.e. a wireless backhaul — are never touched either way, and are not reported as VAPs.

Settings carried through from the controller:

| Controller setting | Applied as |
|---|---|
| SSID, passphrase, security | `wifi-iface` ssid/key/encryption |
| Hide WiFi Name | `hidden` (hostapd `ignore_broadcast_ssid`) |
| MAC Address Filter | `macfilter` (`disable`/`allow`/`deny`) + `maclist` |
| WiFi Speed Limit | `tc` shaping per VAP, not a hostapd option (plus `openuf_ratelimit_down`/`openuf_ratelimit_up` on the section for visibility) |
| WPA2 / WPA3 / WPA2-WPA3 mixed | `encryption=psk2`/`sae`/`sae-mixed`, from the pushed AKM set **plus** `wpa3.transition` — SAE replaces WPA-PSK on the wire, so the AKM alone cannot tell mixed from WPA3-only. Depends on openUF advertising `radio_caps2` bit `0x1` |
| WPA-Enterprise (802.1X) | **not supported** — the WLAN is skipped and logged. The wire protocol carries no RADIUS server/port/secret to write, so there is nothing openUF could provision |
| PMF (802.11w) | `ieee80211w` (0 disabled / 1 optional / 2 required) |
| Fast Roaming (802.11r) | `ieee80211r`. The controller carries **two** toggles — `ft.status` for the WLAN and `wpa3.ft.status` for the SAE akm alone (SAE pushes only). OpenWrt has one switch feeding hostapd's `key_mgmt`, and on `sae-mixed` it yields FT-PSK *and* FT-SAE together, so FT is enabled if **either** asks for it and a disagreement is logged |
| BSS Transition (802.11v) | `bss_transition` — **needs a full `wpad` build** |
| Band Steering | `usteer` config, not a hostapd option |
| Auto/Custom DTIM Period | `dtim_period` |
| Multicast Enhancement | `multicast_to_unicast` |
| Minimum Data Rate | per-**radio** `basic_rate` / `supported_rates` / `legacy_rates` / `beacon_rate` |
| Multicast and Broadcast Blocker | nftables rules, not a hostapd option (plus `openuf_bcfilt`/`openuf_bcfilt_macs` on the section for visibility) |
| Proxy ARP | `proxy_arp` — **needs a full `wpad` build** |
| Client Isolation | `isolate` (hostapd `ap_isolate`) |
| Network / VLAN assignment | a per-VLAN bridge (`br-openuf<id>`) holding the tagged uplink sub-device (`eth1.<id>`), which the VAP joins — plus a `switch_vlan` trunk on swconfig boards. See below |
| Channel, TX power | `wifi-device` channel/txpower; the controller's **Auto** channel is written as the literal `channel=auto`, engaging hostapd ACS (the AP surveys the band at radio bring-up and picks the least-busy channel). **Auto** TX power *deletes* the `txpower` option (UCI has no auto value; absent = driver default/max), so reverting from a fixed dBm actually takes effect |
| Radio enable/disable (TX Power → Disabled) | `wifi-device` `disabled`; the radio's WLANs get `wifi-iface` `disabled` too, keeping their config for a later re-enable |
| Channel width | `wifi-device` htmode, from the radio's `ieee_mode` token, **clamped to what the radio can actually do** — see below |
| IoT Optimization: Lock 2.4 GHz to Channel 6 | nothing new — arrives as `channel=6` on the 2.4 GHz radio |
| IoT Optimization: DTIM Interval Lock | nothing new — arrives as `dtim_period=3` on the 2.4 GHz SSID |
| IoT Optimization: Force WiFi 4 Mode | `bss_load_update_period=0` (suppresses the QBSS Load IE) + an `openuf_iot` marker |
| Minimum RSSI | per-**radio**; enforced by openUF deauthenticating clients below the threshold, not by hostapd |
| Per-port VLAN (Ports → *port* → Native VLAN) | swconfig `switch_vlan` sections named `openuf_swvlan<id>` — see below |

**Channel width is clamped to the hardware.** openUF presents itself as a
U6-InWall (802.11ax) whatever the host radios really are, so a controller will
happily push `ieee_mode=11nahe80` at an 802.11n/ac radio. Written to UCI
verbatim that produces a config file that looks perfectly correct and a hostapd
that refuses to start — no SSID on the air, and nothing in the config to explain
why. openUF therefore probes `iw phy` for each band's real PHY and maximum
width and clamps the request **downward only** (`HE80` → `VHT80` on an ac
radio, `HE40` → `HT40` on an n-only 2.4 GHz radio); a request the hardware can
already satisfy is never touched, and every clamp is logged:

```
openuf: radio0: controller asked for htmode HE80, hardware supports VHT80 -- clamped
```

If `iw` is unavailable or its output can't be parsed, the controller's value is
written through unchanged rather than clamped to a guess. The same probe supplies
each radio's real `max_txpower` (the ceiling the controller's TX Power slider
uses) instead of a static default.

> **SSID punctuation is sanitized into the UCI section name.** A UCI section name may
> contain only `[A-Za-z0-9_]`, so an SSID of `Guest-WiFi` becomes a section named
> `openuf_radio0_Guest_WiFi_<hash>` — the SSID *itself* is stored and broadcast unchanged,
> and the short hash of the original name keeps `Guest-WiFi`, `Guest WiFi` and `Guest_WiFi`
> as three distinct sections. This matters because libuci enforces the rule **silently**:
> `set()` returns true, `commit()` returns true, and a section whose name contains anything
> else is discarded before it reaches `/etc/config`. openUF's sanitizer used to keep `-`,
> so an SSID with a hyphen cost the entire WLAN with nothing logged anywhere (found by
> upstream, live, with an SSID of `openuf-verify`).

**Fast Roaming (802.11r) and the `ft_psk_generate_local` trap.** openUF sets
`ieee80211r`, a `mobility_domain` derived from the SSID (so every AP computes the same one
with no coordination) and `ft_over_ds=0` — and deliberately does **not** set
`ft_psk_generate_local`. It used to force it to `1`, which silently disabled fast roaming
for every WPA3 client: local key generation only exists for **FT-PSK**, while FT-SAE derives
its keys from the per-session SAE PMK and needs the `r0kh`/`r1kh` key holders OpenWrt only
configures when that option is `0`. Left unset, `hostapd.sh` keys it on the auth type and
derives deterministic wildcard key holders from `md5(mobility_domain/psk)`, so independent
APs sharing an SSID and passphrase agree without coordination. Upstream observed the failure
live: a station that had negotiated FT-SAE still reassociated with `auth_alg=sae` plus a full
4-way handshake, even between two BSSes on the same radio. To tell a real fast transition
apart, force one with `hostapd_cli bss_tm_req` and read the target AP's log: `auth_alg=ft`
**and no `EAPOL-4WAY-HS-COMPLETED`** is fast; `auth_alg=sae` followed by a 4-way is the
fallback.

**VLAN-tagged SSIDs** (assigning a WiFi network to a non-native network) need three
things on the AP, and openUF builds all three:

1. a tagged sub-device on the uplink — `eth1.<vlan>`;
2. a **bridge** holding it, `br-openuf<vlan>`, which the VAP joins. This is the part
   that is easy to miss: point the VAP's network at the bare sub-device instead and
   netifd brings the interface up, `ip link` shows both netdevs, hostapd starts, and a
   client associates and gets *nothing* — because the VAP and the uplink are two
   separate masterless interfaces. Everything looks healthy except `ip link`'s missing
   `master`;
3. on swconfig boards, a `switch_vlan` **trunk** so the switch passes the VID at all.
   Without it an ASIC that filters unknown VIDs drops every frame (confirmed: 100%
   packet loss on an AR8327 until the entry existed). openUF tags exactly two ports —
   the CPU port and the uplink socket, the latter found at runtime by
   `sysinfo.uplink_phys_port()`. That is the whole path a tagged SSID's frames take
   (`VAP → br-openuf<id> → eth0.<id> → CPU → uplink → gateway`); no LAN socket is on it.
   If the uplink cannot be resolved openUF leaves any existing trunk alone rather than
   guessing.

> **Why not simply tag every socket.** openUF used to, and it broke every untagged
> wired client behind an AP running a tagged SSID. On the `ar8216`/`ar8226`/`ar8229`/
> `ar8236` driver family the tag flag is **not** per (port, VLAN): `ar8xxx_sw_set_ports()`
> folds it into one global per-port bitmask (`priv->vlan_tagged`) from which
> `__ar8216_setup_port()` picks add-tag vs strip-tag *for every VLAN at once*. Tagging a
> socket into VLAN 10 therefore made it egress-tagged in VLAN 1 too, and the printer
> plugged into it went deaf while still transmitting — UCI read `1 2 3 4 0t` while the
> switch reported `0t 1t 2t 3t 4t`. The AR8327 has a real per-(port, VLAN) tag table and
> showed none of it, which is how the bug survived. A consequence worth knowing on the
> global-bitmask chips: a port cannot be untagged in VLAN 1 *and* tagged in VLAN 10, so
> running a tagged wireless VLAN necessarily leaves the **uplink** socket egress-tagged
> for VLAN 1 as well. UniFi gateways accept that, and it is confined to the one port
> facing the gateway.

> **Keep VLAN ids below the switch's VLAN table size.** netifd has no `vid` option
> (`strings /sbin/netifd` lists only `vlan` and `ports`), so a `switch_vlan` section's
> `vlan` value is *both* the table slot and the VLAN id. Small switches have small
> tables — the TL-WDR3500's AR8229 reports `vlans: 16` in `swconfig dev switch0 help` —
> and a section naming a slot the hardware lacks is skipped by netifd **silently**.
> openUF reads that size and logs the mismatch instead of writing config that will be
> ignored. Whether it actually breaks traffic depends on the ASIC: the AR8327 filters
> unknown VIDs and needs the entry, the AR8229 forwards them and the SSID works without
> one. Choosing a VLAN id under 16 keeps both boards properly configured.

Changing a network's VLAN id, or deleting the WLAN, tears the old bridge and interface
down again — only `openuf_`-prefixed sections are ever removed.

**Per-port VLAN assignment** must be switched on twice: once on the device
(Devices → *AP* → Settings → IP Settings → **Port VLAN**, which is what flips the wire's
`switch.status`/`switch.vlan.status` gates), then per port under **Ports**. Until the
device-level box is ticked the per-port VLAN controls stay greyed out and nothing reaches
the wire.

On **swconfig** boards (ath79-era) openUF writes one `config switch_vlan` section per
VLAN, named `openuf_swvlan<id>`, translating the controller's `untagged`/`tagged`/`exclude`
per-port modes into swconfig's port syntax (`1`, `1t`, omitted) with the CPU port always
tagged in.

**On a DSA board it works differently, and deliberately not via `config bridge-vlan`**
(adopted from upstream, who verified it on an AX3000T's mt7530; the JioRouter boards'
mt7531 is the same driver family). The socket assigned to VLAN 10 is moved out of `br-lan`
and into `br-openuf10` — the bridge that already holds the tagged uplink sub-device
(`br-lan.10` on the JioRouter maps, `wan.10` on the AX3000T's), and the IoT VAP if a tagged
SSID sits on the same VLAN:

```
device on lan3 --untagged--> lan3 -> br-openuf10 -> <uplink>.10 --tagged--> uplink -> gateway
```

That a wired port and a wireless client on VLAN 10 land in the *same* bridge is the point,
not a coincidence: they are one broadcast domain and the controller models them as one
network. `br-lan` keeps the uplink socket, the unassigned sockets and the AP's management
address, untouched, and nothing anywhere runs with `vlan_filtering`, so a wrong answer
cannot strand the AP. The `bridge-vlan` route was rejected because turning `vlan_filtering`
on `br-lan` means every VLAN, the management one included, must be declared exactly right
or the device is stranded — and because an 8021q device on a bridge *port* claims tagged
frames before the bridge ever sees them, so a `bridge-vlan` declaring the same VID would
receive nothing while looking correct in UCI.

Scope on DSA: **Native VLAN only.** A bridge gives a port exactly one untagged home, which
is what a Native VLAN is. A port given nothing but *tagged* VLANs is refused with a log line
rather than half-applied (the controller's default "Tagged VLAN Management: Allow All" marks
every non-native VLAN tagged — a default, not a request, and not warned about). The socket
the uplink cable is in is never moved, and when the bridge FDB cannot say which socket that
is, every port is refused. Reversibility is `st.dsa_brlan_ports`: `br-lan`'s port list as
the board shipped it, snapshotted once before the first move; unticking **Port VLAN** puts it
back verbatim. Note the off signal can be an *absence*: a device that had Port VLAN on and
then has it unticked receives a `system_cfg` with no `switch.*` keys at all rather than the
gates set to `disabled`. openUF treats that as off only while it holds a ledger, so there is
something to undo. Moving a socket between bridges is invisible to the attached host, which
keeps its old lease on the wrong subnet — bounce the port or power-cycle the device.

Three things must line up or the port is skipped rather than guessed at:

- `dev.conf.vlan` must exist in your modelmap (`cpu_lan` + a `ports` name→number map).
  Without it openUF has no idea what the physical switch ports are, and guessing strands
  the device.
- the port needs a `swport` in `dev.conf.net.ports`, naming its `dev.conf.vlan.ports` key.
- the port must not be the uplink — reassigning the uplink's VLAN would cut the device off
  the network, so that is refused outright. On a modelmap that declares sockets rather
  than netdevs, the uplink is whichever socket the default gateway is reached through
  (found in the switch's ARL table); if that cannot be determined, **every** port is
  refused rather than risking the wrong one.

Because assigning a port to a VLAN means removing it from the stock VLAN's port list
(swconfig allows one *untagged* VLAN per port), this is the one place openUF modifies UCI
sections it did not create: a port moved untagged onto an openUF VLAN loses its untagged
membership in every other `switch_vlan` section, and an explicit *exclude* drops the
port's membership from that VLAN. Two safety refusals apply — an exclude that would leave
the port untagged **nowhere** is ignored, and the management VLAN is never stripped of
its last downstream port. openUF snapshots the original `ports` strings into `state.json`
(`swvlan_backup`) before the first change, and `switchvlan.restore()` puts them back. Unticking the device-level **Port VLAN** box runs
that restore automatically (the wire keeps the `switch.*` block with both gates at
`disabled`, which openUF treats as the explicit off signal); a push that carries no
`switch.*` block at all leaves the switch untouched. Inspect the result with
`uci show network` and `swconfig dev switch0 show`.

> The generated UCI is unit-tested, but **openUF has no switch hardware to verify against** —
> that these sections actually program the switch ASIC, and that
> `/etc/init.d/network reload` behaves on real ath79, are unconfirmed.

The **Environment** tab (Insights → AirView) is fed from `iw dev <ifname> scan dump`, the
kernel's passive BSS cache. That cache is filled from beacons the radio overhears **on the
channel it is already serving**, and the kernel forgets an entry about 30 s after it was
last seen — so on its own the tab lists co-channel neighbours and, after the boot-time ACS
sweep, nothing else. Measured on AP2 (a JIDU6101): 0 neighbours on 5 GHz, 4 co-channel on
2.4 GHz. Two options close that gap, and they compose: `neighbour_scan_interval` makes the
AP itself sweep (a brief client stall per scan, off by default), and `rrm_enrichment` asks
802.11k-capable *clients* to sweep and report (costs the AP nothing, on by default; see § 3).
To see the latter work: `pgrep -f 'ubus subscribe hostapd'` is the collector that receives
the reports (hostapd delivers them as ubus *notifications*, so `ubus listen` shows nothing —
only `ubus subscribe` works), `logread | grep BEACON-REQ-TX-STATUS` shows requests going
out, and `/tmp/openuf-rrm.jsonl` is the spool, drained on every inform. Rows sourced this
way show a blank WiFi Name and Security.

The **Multicast and Broadcast Blocker** has no hostapd or OpenWrt equivalent — hostapd
can suppress group-addressed frames wholesale but has no notion of an allow-list — so
openUF enforces it with nftables, in its own `bridge openuf_bcfilt` table (separate
from the client-blocking `bridge openuf` table, which is rebuilt wholesale on every
block/unblock and would otherwise wipe these rules). Frames leaving a filtered SSID are
dropped unless the *sender's* MAC is allow-listed.

This needs **`kmod-nft-bridge`**, and it is the only feature that does. The drop rule is
openUF's one bridge-family `meta` match, and `nft_meta_bridge` is a separate module that
`nftables` does not depend on — absent from a stock filogic *and* ath79 image alike (AP2 did
not have it). The failure is quiet in the worst way: the table, the chain and the per-VAP
allow-list set are all created and populated, and only the drop rule is rejected, so the
control reads as enabled in the controller and `nft list table bridge openuf_bcfilt` shows a
table that filters nothing. openUF now logs `nft rejected the drop rule for <ifname> --
install kmod-nft-bridge` when this happens, and `install.sh`/`setup.sh` install the module.
Upstream verified the ruleset on real hardware: with the sender not allow-listed, 14 of 14
broadcast frames heading out the IoT VAP were dropped; allow-listed, 0 of 15.

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
additionally trims `supported_rates`. Rate options openUF writes are stamped with an
`openuf_rates` marker on the radio section: turning the control off (the wire simply
omits every `minrate_*` key) tears down exactly the marked options, while rate options
you hand-tuned on an unmarked radio are never touched.

Minimum RSSI is a *radio* setting in the controller UI (Devices → AP → Radios), not a per-WLAN one, and the wire value is not dBm but a fixed offset from it (`wire = dBm + 95`; UI -80 ↔ wire 15, UI -85 ↔ wire 10) — openUF converts it back with that same constant. An earlier version added the *live* noise floor instead, which only looked right on a radio whose floor happens to be -95 and drifted 12 dB between drivers (upstream's finding). The controller signals *disable* by omitting the whole `stamgr.<n>` block from the next config push; openUF treats that as an explicit off and clears `minrssi_enabled` in UCI (the stored threshold stays parked for a later re-enable).

The reported **country code** comes from the wifi-device's UCI `country` option (the
regulatory domain OpenWrt programs), mapped best-effort from ISO alpha-2 to the numeric
code the controller expects; an absent or unrecognized regdomain falls back to 840 (US),
the value that used to be hardcoded for every deployment.

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

### Point lldpd's chassis ID at the same interface as `lan_cpueth`

```sh
uci set lldpd.config.cid_interface='lan'
uci commit lldpd && /etc/init.d/lldpd restart
```

**Without this the controller cannot place the AP on its topology map**, and shows
some unrelated device (here the ISP's uplink) as the AP's Parent Device.

The reason is that two different MACs are involved. openUF identifies the device
by the MAC of `dev.conf.net.lan_cpueth`, and that is the MAC the controller
adopts it under. `lldpd`, left to itself, picks its chassis ID from whichever
interface it likes — in practice the lowest-numbered one, i.e. `eth0`. The
upstream gateway therefore learns the AP as a neighbour under a chassis ID that
does not match any adopted device, and silently declines to join the two.

Whether that bites is pure luck of the board's port naming:

| Board | `eth0` | `lan_cpueth` | Default chassis ID | Topology |
|---|---|---|---|---|
| TL-WDR3500 v1 | LAN trunk | `eth0` | matches identity | resolves by accident |
| Archer C5 v1 | unused WAN socket | `eth1` | **`eth0`, wrong** | Parent Device wrong |

Setting `cid_interface` to the LAN network makes the chassis ID the same MAC
openUF reports, and the controller resolves the uplink immediately — confirmed
live: an Archer C5 went from no `uplink_mac` at all to
`Cloud Gateway Ultra, port 4` on the next LLDP advertisement.

Verify the two agree:
```sh
lldpcli show chassis | grep ChassisID          # lldpd's identity
grep -o '"mac":"[^"]*"' /etc/openuf/state.json # openUF's identity
```

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
| **Adopted and healthy, but no pushed SSID is ever created** | **`libuci-lua` is missing** — the most likely cause by far, and it looks like nothing is wrong. Check with `lua -e 'print(pcall(require,"uci"))'`; fix with `apk add libuci-lua` and restart. Every wireless read/write is `pcall`-wrapped, so without it the device adopts, reports ports and statistics, and sends an **empty `radio_table`** — the controller has no radio to put a WLAN on, accepts the push, and creates nothing. openUF warns about this at startup (`logread \| grep openuf`) and `tools/check.sh` tests for it |
| SSID not appearing after adoption | Confirm the controller actually pushed it: set `debug_dump_file` in `conf.lua`, restart, and look for `wireless.*`/`aaa.*` keys in the `setparam` `system_cfg`. If the controller only ever sends `noop`, it believes the device is already configured — clear `cfgversion` in `state.json` and restart to force a full re-push. Then check `uci show wireless \| grep openuf` |
| Controller channel width is ignored; radio runs 802.11n | UniFi's `ieee_mode` token keeps the vestigial `ht` PHY marker and moves only the width, so 80 MHz arrives as `11naht80`. openUF used to take that literally as `HT80` — which does not exist — and `clamp_htmode` knocked it back to `HT40`, silently discarding the setting. Fixed: a width above 40 MHz promotes the token to `VHT`, the narrowest PHY that can express it. If the radio still runs below its capability, set a `dev.conf.radio.<band>.htmode_floor` |
| Radios provisioned but a **5 GHz** SSID never comes up | hostapd's ACS picked a **DFS** channel and the driver's CAC failed — `logread \| grep DFS` shows `start_dfs_cac() failed` then `AP-DISABLED`. Common on mt7915/mt7986 (filogic). Fix it in the modelmap with `dev.conf.radio.na.acs_exclude_dfs = true`, which restricts ACS to non-DFS channels (see **Radio policy**); pinning a non-DFS channel in the controller also works |
| `lldp_table` empty | `lldpd` not running — run `/etc/init.d/lldpd start` |
| Bootstrap account (`ubnt`) doesn't lock after adoption, or doesn't re-enable after a factory reset | `inform.lua` must be running for this — it's what detects the state change and runs `passwd -l`/`-u` (see § SSH prerequisite). Check `logread -e openuf`. |
| Adopted, but every inform is answered `HTTP 400` and the controller shows the device Offline | The identity MAC changed underneath the adoption: `dev.conf.net.lan_cpueth` now names a different interface than the device was adopted under (a modelmap switch, or a reinstall that reset `conf.lua`). openUF says so at startup (it compares against the MAC the previous run persisted) and again on the first 400 of a streak. Forget the device in the controller and re-adopt, or point `lan_cpueth` back |
| Insights → Environment shows nothing, or only right after boot | Nothing rescans: the kernel's BSS cache forgets neighbours after ~30 s and the controller drops entries with `age >= 30`. Set `neighbour_scan_interval` in `conf.lua` (§ 3), accepting the brief client stall each scan costs |
| `logread` says `cannot read a MAC from dev.conf.net.lan_cpueth` | The modelmap names an interface this board does not have (a generic profile on a DSA board, say). The daemon keeps informing under the identity `state.json` persisted; fix `conf.lua` |

Logs go to the system log via procd: `logread -e openuf` (follow with `logread -f`).

For development testing without hardware, see `tools/test_controller.py`.
