# openUF — Usage Guide

## 1. Dependencies

Install the following opkg packages on the OpenWrt device before running openUF:

```sh
opkg update
opkg install lua lua-cjson lua-lzlib luacrypto luasocket iw lldpd
```

| Package | Purpose |
|---|---|
| `lua` | Lua 5.1 runtime |
| `lua-cjson` | Fast JSON encode/decode |
| `lua-lzlib` | zlib compression for inform payloads |
| `luacrypto` | AES-128-CBC/GCM via OpenSSL |
| `luasocket` | TCP client for HTTP POST to controller |
| `iw` | Radio and station statistics |
| `lldpd` | LLDP topology announcement and neighbor discovery |

`luabitop` (bit operations for Lua 5.1) is available in standard OpenWrt builds and is typically already installed.

---

## 2. Installation

Transfer the project to the device and run the installer:

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
- `dev.conf.led`            — sysfs LED path (e.g. `/sys/class/leds/tp-link:green:wlan`) driven by
  the controller's Locate action; `nil` by default — set it per board to enable Locate
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

### Feature flags and paths (`openuf/conf.lua`)

```lua
enable = {
    led = true,   -- status LED (slow blink = unconfigured, solid = connected);
                  -- also gates the controller-triggered Locate blink (openuf/led.lua)
    uap = true,   -- AP emulation
    usg = false,  -- USG mode (not implemented)
    usw = false,  -- USW mode (not implemented)
}

config = {
    use_only_unifi_wlan = true,  -- disable non-openuf_ SSIDs during provisioning
    inform_url  = "http://unifi:8080/inform",   -- default URL (overwritten at adoption)
    state_file  = "/etc/openuf/state.json",
    log_file    = "/var/log/openuf.log",
}
```

---

## 4. Adoption flow

### SSH prerequisite

The controller SSHes into the device as `root` to run `syswrapper.sh set-adopt` during adoption.  **SSH must be accessible and the root password must be set** before clicking Adopt:

```sh
# On the OpenWrt device — set a root password if not already done
passwd root
```

Confirm SSH works from the controller's network before attempting adoption.  A fresh OpenWrt install often has a blank root password and SSH enabled; set the password first.

> **Security note:** openUF intentionally ignores the `authkey` field inside the `mgmt_cfg` payload sent by the controller over HTTP.  Key rotation only happens via this SSH `set-adopt` path, matching how real UniFi hardware works.

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
4. Click **Adopt** — the controller SSHes in and completes the handshake

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
  "upgrade_requested_url":     ""
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

To reset to factory defaults:
```sh
syswrapper.sh reset-inform
```

---

## 6. WiFi provisioning

When the controller pushes a config (SSID, channel, security), `ucihelper.lua` applies it via OpenWrt UCI.  Only sections prefixed with `openuf_` are touched — existing hand-configured SSIDs are preserved.

To verify provisioned SSIDs:
```sh
uci show wireless | grep openuf_
```

To remove all provisioned SSIDs:
```sh
lua -e "dofile('/opt/openuf/ucihelper.lua'); require('M').wlan_clear()"
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
| Adoption fails with SSH error | SSH not reachable from controller, or root password not set — run `passwd root` on the device |
| Controller rejects device ("firmware incompatible") | Adjust `fw.ver` in `ufmodel/u6iw.lua` |
| JSON decode error in controller logs | AES key mismatch — try `syswrapper.sh reset-inform` |
| SSID not appearing after adoption | Check `uci show wireless`, check `loglevel` in `/var/log/openuf.log` |
| `lldp_table` empty | `lldpd` not running — run `/etc/init.d/lldpd start` |

Log file: `/var/log/openuf.log`

For development testing without hardware, see `tools/test_controller.py`.
