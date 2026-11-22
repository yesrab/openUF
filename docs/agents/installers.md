# setup.sh, install.sh and update.sh

Part of the agent notes: [CLAUDE.md](../../CLAUDE.md) is the index and holds the hard constraints.

Read before changing `setup.sh`, `install.sh`, `update.sh`, `tools/deploy.sh`, the init script or
anything under `openuf/hook/` that installs or converts.

## Changing `setup.sh`

The guided installer: interview → packages → openUF → AP conversion → reboot.

**The phase order is load-bearing.** Packages install *before* the network teardown,
because the teardown can take the device's internet with it (this box stops being the
router). A failure in the first three phases leaves a working router; a failure in the
fourth leaves a working router with openUF installed but idle. Do not reorder.

Other things to preserve:

- **The re-exec.** `wget -qO- … | sh` hands the *script* to the shell on stdin, so a
  `read` would consume the script's own remaining bytes. It re-execs from a file with
  stdin on `/dev/tty`. It must be an `exec`, not `exec < /dev/tty` mid-script, which would
  take the rest of the script away from the shell still reading it. And test whether
  `/dev/tty` can be **opened** (`( exec < /dev/tty )` in a subshell) — `[ -r /dev/tty ]`
  answers yes in places where the open then fails.
- **Every question is asked before anything changes**, and each has a matching option so
  the same script runs unattended. Adding a prompt means adding an option.
- **The rrb-unifi roaming plugin is question 7 (default yes), and its pieces are split across
  the phases on purpose.** Its two packages (`ucode-mod-socket`, `kmod-veth`) join `OPTIONAL`
  and its release archive is fetched at the end of the packages phase, both while the box still
  has internet; `rrb-unifi-setup install --yes` runs at the end of phase 4, after openUF is
  installed and configured, and `setup.sh` confirms the tool's 120 s network watchdog at once
  (a veth cannot break the LAN) and puts the plugin into `/etc/openuf/plugins/` + `plugins.enabled`
  itself, because a package release from before the `/opt/openuf` symlink is invisible to the
  tool. `--unifi-roaming`/`--no-unifi-roaming`, `RRB_UNIFI_RELEASE_URL`, `RRB_UNIFI_DIR`,
  `RRB_UNIFI_FALLBACK_TAG` is gone: **the install is PINNED** (`RRB_UNIFI_TAG` defaults to
  `RRB_UNIFI_PINNED_TAG`, v1.5.1; `latest` is an explicit opt-in that installs unverified), the
  pinned plugin's sha256 is checked (`RRB_UNIFI_PLUGIN_SHA256`; `RRB_UNIFI_UNVERIFIED=1`
  overrides), and any tag's plugin must declare `api = 1`. A download failure skips the plugin
  with the manual steps printed; it never fails the install.
- **The rrb-unifi pin is a contract in three places that must agree, and a tool keeps it
  honest.** `tests/fixtures/rrb-unifi/` holds the pinned plugin and its `VERSION` (tag +
  sha256); `setup.sh` carries the same tag and sha; `tests/test_rrb_unifi_compat.lua` runs
  that plugin through THIS tree's `plugins.lua` and `apply_config` on every suite run (his
  assertions mirrored: mobility domain `5de5` for "corp", `ft_psk_generate_local 0`, the
  wildcard key holders, `nasid`, `ft_iface=vft0` only with the veth, a non-FT WLAN untouched,
  every `ctx.*` field his source names present) and fails when the three places disagree.
  **d-malinowski can change what his plugin expects of openUF, and this tree can change what
  it hands him; `sh tools/rrb-unifi-compat.sh` is the check in both directions**: it runs HIS
  `tests/run.lua --openuf` against this tree and OUR contract test against HIS latest plugin
  (`RRB_UNIFI_PLUGIN=<file>` points the test at any copy), then prints the contract-surface
  lines that changed between the pinned and the latest tag for a human read. `--bump` moves
  the pin (fixture, VERSION, setup.sh) once both pass. Run it whenever `plugins.lua`,
  `ucihelper`'s 802.11r block or the ctx a plugin sees changes, and when a new rrb-unifi
  release appears; `.github/workflows/rrb-unifi-compat.yml` runs it weekly and on dispatch
  and fails when the latest release is newer and either side breaks. His tests need a `bit`
  library: the tool writes a LuaBitOp-shaped shim for a 5.3+ dev Lua (CI and the device run
  5.1 with luabitop).
- **Value-taking options** must go through `need_val`, or a forgotten value silently
  configures the empty string.

### Testing it without hardware

The technique used so far, and worth reusing: extract the real block from `setup.sh` with
`sed -n` and run it against stub functions, so the test exercises the shipped code rather
than a copy that can drift.

```sh
{ cat harness-prologue.sh                      # stub uci/init.d/say/ok/warn/die, fake state
  sed -n "$(grep -n '^absorb_wan_swconfig() {' setup.sh | cut -d: -f1),NNNp" setup.sh
} > /tmp/t.sh && sh /tmp/t.sh
```

Stub `uci` over a flat `key=value` file — and use `grep -F` / `grep -vF`, because section
ids like `@switch_vlan[0]` are regex character classes and a plain `grep` silently matches
the wrong thing (this cost a debugging cycle and looked like a script bug).

Shapes worth covering: DSA and swconfig; untagged- and tagged-CPU swconfig; 21.02+
(`config device` bridge) and pre-21.02 (`network.lan.type=bridge`) layouts; every refusal
path; and the static-address forms `1.2.3.4/24`, `1.2.3.4,255.255.255.0`, bare `1.2.3.4`.

### The AP conversion

Reversible, and committed but not applied until the reboot. `wan`/`wan6` deleted,
`dhcp.lan.ignore=1`, `firewall`/`dnsmasq`/`odhcpd` stopped and disabled (packages kept),
`/tmp/resolv.conf` relinked to `resolv.conf.auto` (nothing listens on 127.0.0.1 once
dnsmasq is off, and a hostname inform URL would stop resolving), radios un-`disabled`,
`lldpd.config.cid_interface` set.

Moving the WAN socket is two different jobs — on DSA its netdev joins `br-lan`; on
swconfig `absorb_wan_swconfig` moves the physical port into the LAN VLAN inside the switch
(bridging the WAN *CPU* netdev works but hairpins every frame through the SoC). That
function refuses and falls back to the bridge unless it can prove the geometry. Keep it
that way.

An interface with proto `pppoe`/`wwan`/`dhcpv6` is **named and left alone**, not deleted —
it may be a management link.

## Changing `install.sh`

Copies `openuf/` to `/opt/openuf`, creates `/etc/openuf`, symlinks `syswrapper.sh`,
installs `/etc/init.d/openuf`, then dependencies.

**openUF's own files go in before any package install.** The optional feature packages are
collectively larger than openUF (nftables alone is ~490 KB with its kernel modules), and
installing them first has filled a small overlay and left the product itself uncopied —
the install "succeeded" with no `/opt/openuf` on disk. Product first means a space
shortage costs a feature, never openUF.

`try_optional` only installs when there is room to spare *afterwards*: filling an overlay
to 100% breaks `state.json` writes, the package database, and any later upgrade.

**An existing `conf.lua` is kept.** It holds the modelmap the device was adopted under,
and overwriting it on a reinstall (the natural upgrade path) reset the modelmap to the
generic one — on a DSA board that moves `lan_cpueth`, hence the identity MAC, hence
HTTP 400 forever. The shipped default lands as `conf.lua.dist`; `--replace-conf`
overwrites, and `setup.sh` passes it because it has just written `conf.lua` from its
interview. Options come after the action and an unknown one is an error, so a mistyped
flag cannot install silently without what it asked for.

**`update.sh` is the upgrade path, and it leans on two things `install.sh` provides.** It
installs `update.sh` as `/usr/bin/openuf-update` (a copy, not a symlink — it has to survive
its own `rm -rf /opt/openuf` during a rollback), and it leaves a build stamp in
`/opt/openuf/BUILD` (`dist.sh` writes one into a release tarball; a git checkout gets
`git describe`). The updater's health check reads `/tmp/openuf-status`, which `_tick`
rewrites after every completed cycle — `last_ok` on success, `last_fail` on a transport
failure, both kept, so a controller outage after a good update reads as "up but
unanswered" and is not rolled back. Keep that file flat `key=value`: busybox `sed` is what
parses it. `tools/deploy.sh` is the same updater driven from the dev machine over ssh, one
host at a time, with `dist.sh --verify` gating every push.

`--bootstrap-adopt` creates the locked-down non-root `ubnt`/`ubnt` account, scoped to
running `syswrapper.sh set-adopt` only, which self-locks once adopted and re-enables on
factory reset. The account's shell must be listed in `/etc/shells` or dropbear rejects the
login before the password (`User 'ubnt' has invalid shell, rejected`): `hook/openuf-bootstrap.sh`
registers it, also for an account that exists already, and `uninstall` removes it. The
validation container's OpenSSH never checked, so this was invisible until a real L2 adoption
(AP2, 2026-10-25).

**The 802.11r translator is NOT in the tree any more (2026-11-02).** It was vendored from
2026-10-25 to 2026-11-02 as `openuf/rrb/` with the `openuf-rrb` service; d-malinowski's own
project now ships an openUF plugin (`openuf-plugin/rrb-unifi.lua`, release 1.4+) installed by
his `rrb-unifi-setup`, and this tree's two daemon changes (`wait 0`, `peers_file`) were made
unnecessary by his release 1.5 (wildcard key holders, hostapd learns the peers) and declined
(PR #1 there, closed 2026-10-27). `install.sh install` therefore stops, disables and removes
a leftover `/etc/init.d/openuf-rrb`; the veth sections an old build wrote
(`openuf_ftveth`/`ftlink`/`ftpeer`, `ucihelper.LEGACY_FT_VETH_SECTIONS`) are removed by
`apply_config` right AFTER the `wifi reload` of the next push (never before: a BSS whose
`ft_iface` vanishes fails), and `inform._migrate_legacy_rrb` asks the controller for that push
at startup. `install.sh uninstall` still removes both.

## Changing `openuf-ota.sh` (`openuf ota`, the LuCI "Check for updates" button)

The updater to the latest RELEASE, for both install kinds: a package install gets the
release's `.apk`/`.ipk` files, a tarball install the release archive through `openuf-update`.
`--check` and `--status` print JSON for the overview page; `--start` is the detached run the
page uses and `--install` the foreground one.

- **`uclient-fetch` on 25.12 cannot download from `github.com`.** The TLS handshake stalls
  for 30 s and ends in "Connection timed out", on the test VM and on AP2 alike (2026-11-22,
  libustream-mbedtls), while `api.github.com`, `codeload.github.com` and
  `raw.githubusercontent.com` answer at once. Release files are therefore fetched from the
  API's own address for the asset (`.../releases/assets/<id>` with `Accept:
  application/octet-stream`, which redirects to the file); the plain download URL is only the
  second try. `update.sh` is unaffected (codeload). Anything else in the tree that fetches
  `github.com/<repo>/releases/download/...` on the device is suspect for the same reason.
- **Everything in the release JSON is hostile until the Lua parser has passed it.** Tag, file
  names and both URLs end up on command lines: the parser lets through a version-shaped tag,
  names of `[A-Za-z0-9._-]` and URLs that are exactly this repository's download and API
  asset addresses. Keep new fields behind the same kind of check.
- **No fallback to an unverified download, and no install without a checksum.** GitHub
  publishes a sha256 per asset (`digest`); a file without one, or that does not match, stops
  the update before anything is installed. `setup.sh`'s `--no-check-certificate` retry is
  for a first install at a keyboard; this runs unattended as root.
- **The detached run exists because the update restarts the page's own plumbing.**
  `luci-app-openuf`'s postinst HUPs rpcd and may restart uhttpd; `--start` copies the script
  to `/tmp` (the package replaces the file a shell is still reading) and runs it with its
  output in `/tmp/openuf-ota.log`, and the page polls `--status`, tolerating two minutes of
  unanswered polls. A `--check` uses its own scratch directory so it cannot remove a running
  update's files.
- **The way back is the installed version's own release**, downloaded before the install
  (`--plan-of`, `PLAN_ALL=1`: every installed package, also one whose version did not
  change). `apk add --allow-untrusted <older files>` downgrades (run on the VM);
  `opkg` needs `--force-downgrade` and has not been run. A daemon that runs but gets no
  answer is KEPT, as in `update.sh`: the old version would face the same controller.
- **apk does not restart a running service on upgrade** (`start` on an unchanged procd
  instance is a no-op), so the script restarts openUF itself and re-enables it when it was
  enabled before.
- Run on the VM 2026-11-22: 0.4.0 → 0.4.1 by command line and by the button, and a rollback
  forced with an unloadable configuration. Not run: opkg, the tarball path, a real AP.

## Landmines

- **Two install prefixes, one rule for the configuration.** The OpenWrt package installs
  to `/usr/lib/openuf`, `install.sh` to `/opt/openuf`; the init script, `syswrapper.sh`
  and `openuf-cli.sh` probe for whichever holds `inform.lua`. Whenever `/etc/config/openuf`
  has a `main` section, `uciconf.lua` replaces conf.lua's `dev` and `config` in both daemons
  and the hook -- conf.lua is then only the shipped default. `install.sh` never creates
  that section, so a tarball device keeps its conf.lua identity. `modelmap 'auto'` with
  no matching preset is a refusal (the init script's probe), never a generic fallback: the
  generic maps' `lan_cpueth` would move the identity MAC. A custom map goes through
  `uciconf.validate`, which is `test_modelmap.lua`'s invariants as refusals -- add an
  invariant in both places.
- **`libuci-lua` is required and fails silently.** It provides `require("uci")`, which
  every wireless read and write goes through, and it is not pulled in by `lua`. Without it
  the device adopts, reports its ports and statistics and looks completely healthy, while
  `radio_table` goes out **empty** — so the controller has no radio to provision a WLAN
  onto, accepts the push, and creates nothing. It is silent because every ucihelper call
  is `pcall`-wrapped (correctly — a UCI error must not take the inform loop down). Found
  on a real JIDU6101 after four pushed WLANs produced zero UCI sections. `inform.lua`'s
  `_warn_missing_uci` now shouts at startup and `tools/check.sh` tests for it; keep both.
- **A fresh OpenWrt ships every radio `disabled='1'`.** openUF writes that option only
  when the controller explicitly pushes a radio status, so a push that omits it leaves the
  radio off — provisioning "succeeds" and not one SSID is on the air. `setup.sh` clears it.
- **`wpad-basic-*` has no `bss_transition` at all** and errors the radio down, and every
  controller-pushed WLAN carries it. A full build is therefore **not negotiable**: the init
  script refuses to start without one (`grep wnm_sleep_mode /usr/sbin/hostapd` -- not
  `bss_transition`, which a basic build also carries as event names; upstream's correction), the
  package's postinst-pkg says so, and `hook/openuf-deps.sh` (`openuf deps --install`,
  `/usr/sbin/openuf-deps`, the LuCI overview's button) does the swap -- `del` the basic
  build, `add` the full one of the same crypto library, put the basic one back if that
  fails, `wifi up`, restart openUF -- and `--check` is the JSON the overview reads.
  `install.sh` and `setup.sh` run it too. No package dependency can express "any full
  build": every wpad variant PROVIDES the same names, and naming one CONFLICTS with the
  stock basic one.
- **8 MB flash is not enough** from a stock image: `lua-openssl` pulls in `libopenssl3`
  (~4.35 MB installed) and a stock 8 MB build leaves ~1.6 MB of overlay. Needs a custom
  image with the crypto in squashfs, or extroot.
- **Two kernel modules are not implied by their packages.** `kmod-nft-bridge` for the
  Multicast/Broadcast Blocker's `meta` rule (everything else in that table builds without
  it, so the control looks enabled and filters nothing) and `kmod-sched-act-police` for the
  upload half of WiFi Speed Limit. Both modules now warn by name when `nft`/`tc` reject the
  rule, and both installers add them. `os.execute` returns the raw exit status on Lua 5.1
  (0 = success, non-zero = failure, BOTH truthy), so any "did it work" check needs
  `exec_ok`, not a bare truth test.
- **`install.sh` registers `/etc/openuf/` and `conf.lua` in `/etc/sysupgrade.conf`**, or a
  firmware upgrade un-adopts the device. Append only when absent (`grep -qxF`), terminate a
  last line that lacks a newline first, and on uninstall drop only the `conf.lua` line --
  the state dir line stays because the directory does. Rewrite the file only on grep exit
  0 or 1; exit 2 with a full `/tmp` would otherwise truncate the user's own keep list.
