# Packaging openUF for OpenWrt

Decision record for turning openUF into two OpenWrt packages, `openuf` (the daemon) and
`luci-app-openuf` (the web UI), laid out so that each can later be submitted unchanged to
`openwrt/packages` (`net/openuf`) and `openwrt/luci` (`applications/luci-app-openuf`).
The conventions below were read off those two repositories (checked out beside this one)
on 2026-09-29: `net/travelmate` and `utils/prometheus-node-exporter-lua` for a UCI+procd
service, `applications/luci-app-example` and `luci-app-lldpd` for the UI, and the feeds'
CONTRIBUTING and review rules.

## Layout in this repository

```
openUF/
├── openuf/                       the daemon, unchanged (Lua 5.1, cwd-relative loads)
├── package/                      an OpenWrt feed: one directory per package
│   ├── openuf/                   -> openwrt/packages: net/openuf
│   │   ├── Makefile
│   │   ├── files/openuf.config   -> /etc/config/openuf
│   │   ├── files/openuf.upgrade  -> /lib/upgrade/keep.d/openuf
│   │   │                         (the init script is openuf/etc/init.d/openuf inside
│   │   │                          the source archive: install.sh ships the same file)
│   │   └── test.sh               feed CI runtime check (openuf --version)
│   └── luci-app-openuf/          -> openwrt/luci: applications/luci-app-openuf
│       ├── Makefile              LUCI_TITLE, LUCI_DEPENDS:=+luci-base +openuf
│       ├── htdocs/luci-static/resources/view/openuf/{overview,settings,log}.js
│       ├── htdocs/luci-static/resources/view/status/include/05_openuf.js
│       │                         the essentials on Status → Overview
│       ├── root/usr/share/rpcd/ucode/luci.openuf        the backend (ucode)
│       ├── root/usr/share/rpcd/acl.d/luci-app-openuf.json
│       ├── root/usr/share/luci/menu.d/luci-app-openuf.json
│       └── po/templates/openuf.pot
└── .github/workflows/release.yml verify, build .ipk + .apk, attach to the release

openuf/hook/                      what the packages install as commands
├── openuf-cli.sh                 -> /usr/bin/openuf   (--version, status, probe, the
│                                    syswrapper verbs)
├── openuf-convert.sh             -> /usr/sbin/openuf-convert (--check, --convert, --revert)
└── probe.lua                     `openuf probe status|presets|discover|export`: the one
                                  source the UI reads, in the daemon's own terms
openuf/uciconf.lua                /etc/config/openuf -> the `dev`/`config` tables
```

## Decisions

| Topic | Decision | Why |
|---|---|---|
| Install prefix | `/usr/lib/openuf/` for the modules, presets and hook; `/usr/bin/syswrapper.sh` symlink (the controller's SSH adoption runs it by name); `/usr/bin/openuf` a tiny CLI (`--version`, `status`, `reset-inform`); `/etc/openuf/` for `state.json` and the ledger | Feed packages do not install under `/opt`. The cwd-relative `dofile` design stays: only the init script and the hook name the directory |
| Configuration | `/etc/config/openuf` (UCI). `conf.lua` becomes a loader that builds today's `config`/`dev` tables from UCI; presets stay Lua files under `modelmap/` and `ufmodel/`; a custom map is UCI sections (`device`, `port`, `vlan`, `radio`, `identity`) turned into the same `dev` table by one loader that applies `test_modelmap.lua`'s invariants as refusals | LuCI forms edit UCI; the presets are tried and true and keep their tests |
| Backend | ucode rpcd plugin `luci.openuf` under `/usr/share/rpcd/ucode/` (`rpcd-mod-ucode`, which `luci-base` already depends on) | Every current LuCI app with a backend is ucode or shell; Lua rpcd plugins are not what upstream takes |
| Daemon deps | Hard: `+lua +luabitop +lua-cjson +libuci-lua +lua-openssl +lldpd`. Optional (runtime-checked, listed on the status page with the install command): `nftables`, `kmod-nft-bridge`, `tc-tiny`, `kmod-sched-act-police`, `usteer`, `hostapd-utils`, a full `wpad-*` | OpenWrt has no "any full wpad" dependency, and the optional set outweighs the daemon on 8 MB flash |
| Package source | `PKG_SOURCE_URL` = the GitHub release archive `openuf-<ver>.tar.gz` (gzip, not xz: busybox tar on a device cannot unpack xz, and the same archive serves a manual install), which the release workflow produces from `tools/dist.sh --verify` (comment-stripped, proven bytecode-identical, tests passed) | Feed rules want an official release archive; the stripped tree halves the installed size, and the proof stays in CI logs |
| Version | `PKG_VERSION` from the tag `vX.Y.Z`; `PKG_RELEASE` reset to 1 on a version change; `BUILD` stamp kept | Feed convention |
| Minimum target | LuCI app: OpenWrt 24.10 and later (ucode rpcd, JS LuCI); daemon: unchanged reach | Both package formats the release builds (`opkg` on 24.10, `apk` on 25.12) |
| Init | `#!/bin/sh /etc/rc.common`, `USE_PROCD=1`, `start_service` with two instances (announce, inform), `procd_add_reload_trigger "openuf"` | Feed review rules |
| Upgrade safety | `conffiles`: `/etc/config/openuf`; `keep.d/openuf`: `/etc/config/openuf`, `/etc/openuf/` | What `install.sh` does with `sysupgrade.conf` today |

## The LuCI app

Menu: `admin/services/openuf` → *Overview*, *Settings*, *Log*; plus a few lines on
*Status → Overview* (`view/status/include/05_openuf.js`, numbered so it sorts before the stock `10_system` block and shows first).

Everything the pages show comes from `openuf probe …` (`openuf/hook/probe.lua`), which
runs the daemon's own loader and reports how the configuration resolved. The ucode backend
`luci.openuf` only adds what the daemon cannot know: the service state, the optional
packages, `openuf-convert --check`. So the UI can never describe a configuration the daemon
would read differently.

- **Overview**: state and adoption, the profile and identity in use (and the refusal
  reason when there is one), the pushed WiFi networks, the optional packages that are
  missing with the install command, and Restart / Scan for neighbours / Forget the
  controller behind confirmations. *Turn back into a router* appears only on a device
  `openuf-convert` converted.
- **Settings**: `form.Map('openuf')` on `openuf.main`, in tabs, every field with a
  fully descriptive label and a plain-language description. Two dropdowns, *Hardware
  profile* (Automatic / the shipped presets / Custom profile) and *UniFi model to
  present* (Automatic / the shipped identities / Custom identity), both locked while
  adopted because either moves the address the controller knows the device by. The
  custom sections are shown only while their dropdown says custom:
  - *Custom hardware profile*: `device 'custom'` + one `port` section per socket in a
    GridSection, `vlan`/`swport` on swconfig, `radio na`/`ng` policy. On first use it is
    seeded from `openuf probe discover` (`/etc/board.json` for the LAN/WAN sockets and
    the switch geometry, `/sys/class/leds` with the procd alias that already drives each
    LED, the netdevs with their MACs, the phys with their bands and UCI radio names).
    Two things discovery cannot read are said so in the text: which socket carries
    which label, and which LED is free.
  - *Custom UniFi identity*: `identity 'custom_identity'`, seeded from the shipped
    identity the profile names.
  - The mapping: nothing to show when both are presets; a read-only table of the
    preset's sockets, radios and LED when only the identity is custom (it is the preset's
    mapping that applies); the custom profile's own sections otherwise.
  - *Export the saved custom profile as a file*: `openuf probe export` writes the saved
    custom profile as a modelmap file, header marked unverified, into a modal with a
    download link. A custom identity cannot be named by a shipped file, so the export
    names the profile's own choice and says why.
  - *Convert to an access point and reboot*, shown only while `openuf-convert --check`
    reports a router: a modal with the address choice (DHCP or static with gateway and
    DNS), "keep the WAN socket as WAN", and the warning that the address will change.
- **Log**: `logread -e ^` (ubox's `-e daemon` matched nothing) filtered client-side.

ACL: read `ubus luci.openuf getStatus/listPresets/discover/exportPreset/getConvertState`,
`file exec` for `logread -e *`, `/etc/init.d/openuf start|stop|restart`, `openuf
reset-inform|11k-scan`, `uci openuf`; write `ubus luci.openuf convert/revert`, `uci openuf`.

## Release workflow (GitHub Actions)

*Actions → Release → Run workflow*: pick the branch, then whether this is a **patch, minor
or major** release. The run finds the newest version tag by number (`v0.0.1` and `0.0.1`
both count; none means `0.0.0`), raises that part, refuses if the tag exists, and only
once the tree has passed verification creates the tag on the chosen branch and the
release with generated notes, so a failed run leaves no tag and no release behind. The
tag is the version: `PKG_VERSION`, `PKG_HASH` and the download URL in the Makefiles are
substituted from it in the build and never committed by the run. A tag pushed by hand
(`git push origin v0.1.0`) or a release published in the web UI (a *draft* fires nothing
until "Publish release") is built the same way: the run creates the release if there is
none and attaches the files if there is. Everything the run creates with the built-in
token never re-triggers the workflow, and a release made in the web UI with a new tag
(which fires `push` and `release` together) is serialised by a concurrency group.

A fourth choice, **rebuild**, builds the newest version tag again and replaces its
files: for a run that failed after the tag and release were made, since a re-run of the
failed jobs uses the workflow file as it was, not the fix.

Lessons from the first attempts (2026-09-28/29): release `0.0.1` was published from the
web UI while the workflow listened only for pushed `v*.*.*` tags, so nothing ran;
`softprops/action-gh-release` updating that release failed with "Invalid
target_commitish" because it re-sends the release's recorded target, the `packaging`
branch, which had been deleted after its merge (the run now uses `gh` and never updates
a release, only creates one or uploads to it); and `v0.0.2`'s package jobs failed in
`openwrt/gh-action-sdk`'s init-script check, which runs `git diff` inside the mounted
feed directory, not a git repository in the container, so it fails on git before shfmt
sees anything (`NO_SHFMT_CHECK: true`; there is no `files/*.init` to check, and the init
script is syntax-checked in `verify`).

1. **verify**: Lua 5.1 + luarocks, `lua tests/run_tests.lua`, `sh tools/dist.sh --verify`,
   `bash -n` and `dash -n` on the shell files; upload `openuf-<ver>.tar.gz` as the release
   archive and record its sha256.
2. **build** (matrix): `openwrt/gh-action-sdk` with `FEED_DIR: package`, once against a
   24.10 SDK (produces `.ipk`) and once against a 25.12 SDK (produces `.apk`). Both packages
   are `PKGARCH:=all`, so one architecture per format is enough. The luci app's Makefile
   includes `luci.mk` from the SDK's luci feed; the same file is included as `../../luci.mk`
   when it lives inside `openwrt/luci`.
3. **publish**: attach the `.ipk`, `.apk` and the source archive to the release.

Formalities the feeds check on submission: `PKG_MAINTAINER`, `PKG_LICENSE:=MIT`,
`PKG_LICENSE_FILES:=LICENSE`, two-space metadata blocks and tabbed recipes, unindented
`conffiles`, procd init, an executable answering `--version` with `PKG_VERSION`, tabs in the
JavaScript (`js-beautify -t -a -j -w 110`), a `.pot` under `po/templates`.

## Order of work

1. `package/openuf` plus the UCI loader, with `install.sh`, `update.sh` and `deploy.sh` kept
   until the package has parity. Installable with `apk add ./openuf.apk`.
   **Done 2026-09-29** (branch `packaging`): `openuf/uciconf.lua` (+ `tests/test_uciconf.lua`),
   both daemons and the hook honour `/etc/config/openuf` when it has a `main` section, the
   init script finds either prefix, refuses a configuration that does not load and restarts
   on a change to `openuf`, `openuf-cli.sh` is `/usr/bin/openuf` on both install paths,
   `package/openuf/` is the feed directory, `tools/release-archive.sh` makes the source
   archive. Trialled on AP2 the same day by hand-installing the archive the way the
   Makefile does (`/usr/lib/openuf`, the new init script, `/etc/config/openuf` mirroring its
   conf.lua): both daemons ran under UCI with the same identity MAC, `openuf --version` and
   `status` answered, an unknown preset was refused at start by name with no daemon left
   running, `reload` after fixing it brought both back, and the `/opt` install was restored.
   Not yet run through an SDK: no docker on the dev machine, so the first tag is the first
   real build.
2. The release workflow, producing both formats. **Written 2026-09-29**, unverified until
   the first tag; the SDK image tags and `gh-action-sdk` inputs are the parts to check.
3. `luci-app-openuf` with the status page and the preset-only settings. **Done 2026-09-29:**
   `openuf probe status|presets` (hook/probe.lua, the daemon's own description of how the
   configuration resolved, authkey never included) is the single source the UI reads; the
   ucode backend `luci.openuf` adds the service state and the optional-package check;
   views `overview` (state, device, WLANs, packages, ledger, restart / scan / forget with a
   confirm), `settings` (form.Map on `openuf.main` with tabs; profile and identity locked
   while adopted; a tarball install is seeded from the probe so its first save changes only
   the source) and `log`. Tried live on AP2's LuCI (25.12.5): all three pages render with a
   clean console; a Save & Apply on the tarball-installed AP2 created `/etc/config/openuf`
   from the seed, the reload trigger restarted both daemons the second the file was written,
   the identity MAC and informs were unchanged, and the overview then reported the UCI
   source; the Scan button ran `openuf 11k-scan` through the ACL and the daemon consumed it.
   Three things found only by running it: LuCI's `uci.load` rejects a missing file (so
   install.sh now creates an empty `/etc/config/openuf`), lua-cjson encodes an empty table
   as `{}` (every list from the probe is guarded in JS), and buttons inside a polled block
   are re-created under the cursor (rendered once, outside it). The log view fetches the
   whole ring buffer with `-e ^` and filters client-side: ubox's `-e daemon` matched nothing.
4. Discovery, the custom forms, the mapping section, export, convert-to-AP.
   **Done 2026-09-29** (uncommitted, branch `packaging`): `openuf probe discover` and
   `export` in `hook/probe.lua` with three `/etc/board.json` fixtures (DSA, swconfig
   untagged and tagged CPU) in `tests/test_probe.lua`; the custom sections, the mapping
   rules and the export modal in `settings.js`; `openuf-convert` (`--check`, `--convert`,
   `--revert`) ported from `setup.sh`'s conversion phase; `getConvertState`, `convert`
   and `revert` in the backend; the revert button on the Overview; the status widget.
   Tried live on AP2: discovery reported the DSA layout, five sockets, both radios with
   their UCI names and the LEDs with what procd drives; the custom forms rendered seeded
   from it; a Save & Apply moved AP2 onto the custom profile with the identity MAC and
   the informs unchanged; the export modal produced a file that loads and passes the
   daemon's checks; `openuf-convert --check` said `ap`; AP2 was then put back on the
   shipped profile. Found only by running it: a custom identity leaves the cosmetic
   `fw.buildtime`/`factoryver` unset and `announce.lua` crash-looped on the nil (the loader
   now defaults them to empty), `m.lookupOption` exists only after the map has rendered,
   and hiding a section means hiding its `.cbi-section` ancestor, not the inner container.
   **Not run on hardware**: `--convert` and `--revert`, for want of a router to convert;
   their refusals and the backup/stamp round trip are what to watch on the first one.
