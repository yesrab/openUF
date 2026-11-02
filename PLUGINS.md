# Writing an openUF plugin

A plugin lets a recipe that openUF does not ship, typically one that needs extra software on
the AP, add or change the UCI options of the WLANs openUF provisions. It lives in its own
project; openUF only offers the hook. **Third-party plugins are unsupported by openUF**, and
**a plugin is Lua running as root**, with the same trust as `conf.lua`. openUF does not
sandbox it. Enable only code you have read.

The hook and its contract are jonasevcik/openUF's (`api = 1`, 2026-10-25), taken as they are
so that a plugin written for upstream runs here unchanged. The first one on real hardware is
d-malinowski's [rrb-unifi](https://github.com/d-malinowski/unifi-openwrt-roaming) plugin,
802.11r fast roaming with genuine UniFi access points, which `setup.sh` offers to install
(USAGE.md § 6). Status here: unit-tested through `apply_config`; the rrb-unifi plugin ran on
its author's BT Home Hub 5A against a U7 Lite. ⚠️ No plugin has run on this tree's own APs yet.

## The contract

A plugin is the file `/etc/openuf/plugins/<name>.lua` (name: letters, digits, `_`, `-`). It
returns a table:

```lua
return {
    name = "myplugin",
    api  = 1,                       -- another number: refused, with a log line
    vap_options = function(extra, vap, ctx)
        if not vap.fast_roaming_enabled then return end   -- leave other WLANs alone
        extra.mobility_domain = "abcd"                    -- override a built-in option
        extra.hostapd_bss_options = {"ft_iface=vft0"}     -- a UCI list
        extra.reassociation_deadline = ctx.DELETE         -- remove an option
    end,
}
```

`vap_options` runs once per WLAN and radio on each controller push, **after every built-in
option is in `extra` and before it is written**. It runs for every WLAN, so check what you need
(`vap.ssid`, `vap.fast_roaming_enabled`, ...) and return early for the rest.

| Argument | Meaning |
|---|---|
| `extra` | The WLAN's UCI options as openUF built them: option name -> string, number, boolean, or list of strings/numbers, or `ctx.DELETE` to remove one. Edit it in place. |
| `vap` | A copy of the parsed controller WLAN without its passphrase (`ssid`, `radio`, `iapp_key`, `fast_roaming_enabled`, ...). Only the neutral fields documented in `inform.lua` are stable. |
| `ctx.DELETE` | Sentinel: `extra.opt = ctx.DELETE` removes the option. |
| `ctx.bssid(radio, ssid)` | The WLAN's live BSSID, or nil. |
| `ctx.cursor()` | A UCI cursor, for reading other configs. |
| `ctx.read_file(path)` | File contents, or nil. |
| `ctx.util` | `{bit, is_mac, valid_ifname, read_file}`: `bit` is the `band`/`bor`/`bxor`/`lshift`/`rshift` table. Use these instead of reaching into openUF's modules. |
| `ctx.log(msg)` | A line in the system log, prefixed with the plugin name. |

## Guard rails

- A plugin that is missing, does not load, has another `api`, raises, or returns a bad edit is
  logged (`logread | grep "openuf: plugin"`) and skipped for that WLAN; the push goes on.
- An edit is all or nothing: one bad option discards that plugin's changes for the WLAN.
- Option names must be `[A-Za-z0-9_]+` (libuci silently drops others). `device`, `mode`, `ssid`,
  `encryption`, `network`, `key` and every `openuf_*` stamp are reserved to openUF.
- Plugins run in the order they are listed; a later one sees an earlier one's edits.
- Capability bits (`wifi_caps` and friends) and the inform payload are not editable through
  this hook: a plugin must never claim what the device cannot honour.
- A plugin is loaded once per process: after editing it, `/etc/init.d/openuf restart`.
- **A UCI option must exist in the consumer.** Unknown options are stored and silently dropped.
  Check `/usr/share/schema/wireless.*.json` and `/usr/share/ucode/wifi/` on the device, and read
  the result back (`/var/run/hostapd-phy*.conf`), not just the UCI.

## Enabling, disabling, uninstalling

Nothing in the plugin directory loads unless named. Three sources, merged (duplicates run once):

1. `config.plugins = {"myplugin"}` in `conf.lua` (a file the user owns; a tarball install).
2. `list plugin 'myplugin'` in `openuf.main` of `/etc/config/openuf` (a UCI-managed device:
   the LuCI settings page has the list).
3. `/etc/openuf/plugins.enabled`: one name per line, `#` starts a comment. **An installer
   should use this one**: append or delete a line, never edit `conf.lua` or the user's UCI.
   `/etc/openuf/` survives a sysupgrade.

**Applying.** openUF rebuilds every `openuf_` WLAN section on each push, so a plugin needs no
teardown of its own options. A restart alone does not push, because the controller answers noop
while the config version matches. openUF therefore remembers a fingerprint of the requested names
and of each plugin file's content in `state.json`; at startup, if it has changed since the last
push, openUF forgets its config version and the controller pushes again. Force Provision in the
controller makes it immediate, and is the fallback. The cost: a changed plugin set makes one
extra push, and the push reloads hostapd's settings (not a restart).

**Uninstall order** (matters when the options refer to something the plugin installed, like a veth):

1. Remove the name from `plugins.enabled` (and `conf.lua` / UCI), restart openUF.
2. Wait for the re-push, or Force Provision.
3. Confirm the option is gone: `uci show wireless | grep <option>`.
4. Only then remove what the plugin installed outside UCI. That part is the plugin's own job
   (rrb-unifi-setup's `uninstall` does exactly this).

## Versions and detection

- The hook is present when `/opt/openuf/plugins.lua` exists; its `M.API` is the number. On a
  package install `/opt/openuf` is a symlink to `/usr/lib/openuf`, kept for exactly this check.
- `api` changes only for a breaking change to the contract above. New `ctx` fields and new optional
  callbacks are additive and keep the same `api`, so feature-detect (`if ctx.thing then`).
- A bump is announced under "upgrade notes" in the release notes and here. A plugin declaring an
  `api` openUF does not speak is refused with a log line, never a crash.
- `openuf probe status` lists every requested plugin with its load state (the LuCI overview shows
  the same), and `tools/check.sh` prints the enabled names.

## Testing a plugin

`openuf/plugins.lua` has two seams, `M._read_file` and `M._log`, and `M.vap_options(extra, vap, cfg,
env)` can be called with a fake `env` (`DELETE`, `bssid`, `cursor`). `tests/test_plugins.lua` shows
both that and a full run through `ucihelper.apply_config` with a recording mock cursor. Keep in mind:
a mock accepts what libuci would drop, so check names against `[A-Za-z0-9_]+` yourself, and verify
on a device before claiming a plugin works.
