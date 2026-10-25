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
│   ├── luci-app-openuf/          -> openwrt/luci: applications/luci-app-openuf
│       ├── Makefile              LUCI_DEPENDS:=+luci-base +openuf +uhttpd-mod-ucode; the
│       │                         postinst/prerm that load and remove the gate
│       ├── htdocs/openuf/{index.html,portal.css,portal.js}
│       │                         the device page (no LuCI files, no web fonts)
│       ├── htdocs/luci-static/resources/preload/openuf_exit.js
│       │                         "Exit LuCI mode" in LuCI's indicator bar
│       ├── root/usr/share/ucode/openuf/gate.uc   the gate in front of LuCI
│       ├── root/etc/uci-defaults/80_openuf-portal
│       │                         registers the gate with uhttpd, creates openuf.web
│       ├── root/usr/share/rpcd/acl.d/luci-app-openuf-portal.json
│       │                         `unauthenticated`: luci.openuf getPublic only
│       ├── htdocs/luci-static/resources/view/openuf/{overview,settings,log}.js
│       ├── htdocs/luci-static/resources/view/status/include/05_openuf.js
│       │                         the essentials on Status → Overview
│       ├── root/usr/share/rpcd/ucode/luci.openuf        the backend (ucode)
│       ├── root/usr/share/rpcd/acl.d/luci-app-openuf.json
│       ├── root/usr/share/luci/menu.d/luci-app-openuf.json
│       └── po/templates/openuf.pot
│   └── luci-theme-halo/          -> openwrt/luci: themes/luci-theme-halo
│       ├── htdocs/luci-static/halo/{cascade.css,logo.svg}, halo-dark/halo-light symlinks
│       ├── htdocs/luci-static/resources/menu-halo.js     sidebar, breadcrumb, tabs
│       ├── ucode/template/themes/halo/{header,footer,sysauth}.ut (+ variant symlinks)
│       └── root/etc/uci-defaults/30_luci-theme-halo        registers the three variants
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

- **The 802.11r translator is part of the `openuf` package, not a package of its own**
  (2026-10-25). d-malinowski's rrb-unifi (GPL-3.0-or-later) is vendored as `openuf/rrb/`
  and installed to `/usr/lib/openuf/rrb/` with its LICENSE and README; its procd script is
  `openuf/etc/init.d/openuf-rrb`; `DEPENDS` carries `+ucode-mod-socket +kmod-veth`;
  `PKG_LICENSE` is `GPL-3.0-or-later` (the whole repository since 2026-10-25; NOTICE lists the copyright holders). The veth pair is written
  by the daemon's user, openUF, into `/etc/config/network` on the first FT push, so neither a
  uci-defaults nor a postinst touches the network. Fixes come from
  https://github.com/d-malinowski/unifi-openwrt-roaming (see `openuf/rrb/README.md`), re-applied
  with the `// openUF:` changes.
- **Plugins ship in `openuf/plugins/`** (2026-10-25), installed to `/usr/lib/openuf/plugins/`;
  third-party ones live in `/etc/openuf/plugins/` (the sysupgrade keep list already has
  `/etc/openuf/`) and are named in `openuf.main` as `list plugin`. `openuf deps` learns their
  packages and services from `openuf probe plugin-deps`, so the package's `DEPENDS` carries
  only what the built-in ones need (`ucode-mod-socket`, `kmod-veth` for `rrb`).

| Topic | Decision | Why |
|---|---|---|
| Install prefix | `/usr/lib/openuf/` for the modules, presets and hook; `/usr/bin/syswrapper.sh` symlink (the controller's SSH adoption runs it by name); `/usr/bin/openuf` a tiny CLI (`--version`, `status`, `reset-inform`); `/etc/openuf/` for `state.json` and the ledger | Feed packages do not install under `/opt`. The cwd-relative `dofile` design stays: only the init script and the hook name the directory |
| Configuration | `/etc/config/openuf` (UCI). `conf.lua` becomes a loader that builds today's `config`/`dev` tables from UCI; presets stay Lua files under `modelmap/` and `ufmodel/`; a custom map is UCI sections (`device`, `port`, `vlan`, `radio`, `identity`) turned into the same `dev` table by one loader that applies `test_modelmap.lua`'s invariants as refusals | LuCI forms edit UCI; the presets are tried and true and keep their tests |
| Backend | ucode rpcd plugin `luci.openuf` under `/usr/share/rpcd/ucode/` (`rpcd-mod-ucode`, which `luci-base` already depends on) | Every current LuCI app with a backend is ucode or shell; Lua rpcd plugins are not what upstream takes |
| Daemon deps | Hard: `+lua +luabitop +lua-cjson +luasocket +lua-openssl +libuci-lua +iw +lldpd +ip-bridge +hostapd-utils +usteer +nftables +kmod-nft-bridge +tc-tiny +kmod-sched-act-police` (2026-09-29: the feature packages were optional at first; the user found the package install leaving features off and made them hard). Not expressible: a **full wpad build**, so `openuf deps --install` (hook/openuf-deps.sh, `/usr/sbin/openuf-deps`) swaps a `wpad-basic-*` for the full build of the same crypto library, the init script refuses to start without one, the package's postinst-pkg says so, and the LuCI overview has the button | Every wpad variant PROVIDES the same names, so no virtual package tells full from basic; naming one variant would CONFLICT with the stock `wpad-basic-*` and make the package uninstallable; a postinst cannot swap under the package manager's own lock |
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
  reason when there is one), the pushed WiFi networks, *Software openUF needs* (the
  hostapd build, full or basic, and the missing packages, from `openuf deps --check`,
  with the button that runs `openuf deps --install` through `fs.exec_direct` -- cgi-io,
  no ubus timeout -- and reloads), and Restart / Scan for neighbours / Forget the
  controller behind confirmations. A basic build is also a red banner at the top. *Turn back into a router* appears only on a device
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

Also on the settings page: *Device page* (`openuf.web.portal`), and the radio picker becomes
a note when the board reports no radio (an empty MultiValue blanks the page).

ACL (`luci-app-openuf-portal.json` adds the `unauthenticated` group: `ubus luci.openuf
getPublic`, nothing else): read `cgi-io exec`, `ubus luci.openuf getStatus/listPresets/discover/exportPreset/
getConvertState`, `file exec` for `logread -e *`, `/etc/init.d/openuf start|stop|restart`,
`openuf reset-inform|11k-scan|deps --check`, `uci openuf`; write `ubus luci.openuf
convert/revert`, `file exec openuf deps --install [*]`, `uci openuf`.

## The device page and the gate (luci-app-openuf, 2026-10-18)

The user's brief: like an adopted Omada or UniFi device, the box should belong to its
controller -- its address opens a page that says where it is managed from, with the local
settings behind a login -- and LuCI should be reachable only through a hidden gesture, with
a way back.

| Piece | What it does |
|---|---|
| `gate.uc` | A uhttpd ucode handler registered for `/cgi-bin/luci`. Per request: `/__openuf/unlock` sets the `openuf_luci=<epoch>` cookie and goes to LuCI; `/__openuf/lock` destroys the LuCI session, clears the cookie, goes to `/openuf/?locked`; with `openuf.web.portal` off (or `/www/openuf/index.html` missing) everything goes to LuCI's dispatcher; otherwise a request passes only with the cookie AND (a valid LuCI session OR the cookie younger than 600 s, to log in), and goes to `/openuf/` (`?expired` when a session ended). Any error falls through to LuCI. It also supplies `DOCUMENT_ROOT`, which uhttpd's ucode handler omits and LuCI's preload discovery needs. Presentation only: LuCI keeps its login, `/ubus` and cgi-io are not behind it |
| `/www/openuf/` | *Overview*: `luci.openuf getPublic` with the unauthenticated rpcd session -- hostname, model, presented identity, MAC, openUF version, adopted, controller host/port, last contact/failure, uptime, running (cached 5 s; the facts the discovery packets already broadcast, plus where to manage it). *Local Settings*: `session.login` as root, then `luci.openuf getStatus/listPresets`, `uci get/set/add/commit` on `openuf` (`main` only where it exists, `web` created when absent), `file exec` for `openuf reset-inform` and the init script, `system reboot`. Konami code / seven taps on the device picture → "Open LuCI?" → `/cgi-bin/luci/__openuf/unlock` |
| `preload/openuf_exit.js` | Shows *Exit LuCI mode* (an indicator beside *Refreshing*) only while the `openuf_luci` cookie is set |
| lifecycle | uci-defaults switches `uhttpd.*.ucode_prefix` to the gate but restarts nothing, so a first install takes over at the next reboot; the postinst restarts uhttpd only when it already runs the gate (an upgrade); the prerm (not on upgrade: apk runs none, opkg sets `PKG_UPGRADE`) restores LuCI's line and restarts uhttpd at once |
| `luci-theme-halo` | Optional, never a dependency; installed by `openuf deps --install` only with LuCI present and ≥ 4096 KB free on the overlay (`--no-theme` skips; `--check` reports `theme`); the LuCI overview's software table shows the decision |

Verified on an OpenWrt 25.12.6 armsr/armv8 VM under QEMU (stock image + `uhttpd-mod-ucode`,
openUF from the tarball, the app's files laid out as luci.mk installs them) on 2026-10-18:
the redirect from `/` and every `/cgi-bin/luci` path; `getPublic` answering the
unauthenticated session while `getStatus` is refused (-32002); wrong and right password;
settings save creating only `openuf.web` on a box with no `main`; the switch followed live
both ways; the Konami code with real key presses; LuCI's login; *Exit LuCI mode* beside
*Refreshing*; lock and expiry returning to the page; the four lifecycle cases (first install
waits for the reboot, the reboot takes over, an upgrade reloads the gate, removal restores
LuCI immediately); and the same unlock → login (`sysauth_https`) → a session outliving the
10-minute grace → lock → old cookie refused sequence over HTTPS. Light, dark and a 390 px
phone layout were screenshotted. The VM's user-mode networking resets the odd parallel
static request, which also happens with stock uhttpd and no gate. **Not yet run:** on a real
AP (both lab APs are production), through the SDK, on 24.10/opkg.

## The dashboard (luci-app-openuf, admin/dashboard, 2026-10-19)

LuCI's landing page on an openUF device (menu order 5, before Status), a read-only view
(`view/openuf/dashboard.js`, its own stylesheet `openuf/dashboard.css` loaded by the view with
LuCI's `resource_version` token in the URL, so an upgrade never shows the previous sheet from
the browser's cache; written through the theme's tokens with fallbacks, so it holds up under
Bootstrap too). Its health tiles are a container query: seven on one row down to a 1280 px
window (the detail line goes first), then two balanced rows. The idea --
one screen that answers "is this access point healthy, and if not, where?" -- is
luci-theme-vantage's dashboard; the implementation is this repo's own and reads only what
LuCI's own network model and rpcd give, polled every five seconds:

- a verdict ("Everything looks healthy" / "N things need attention") over the checks:
  Uplink (the interface carrying the default route, wan-named first; rates from the byte
  counters), Controller (openUF's `getStatus`: stopped / not adopted / adopted, last contact
  age), CPU (1-minute load over the core count from `/proc/cpuinfo`), Memory, Wi-Fi (radios
  up, SSIDs, clients), Signal (clients below -75 dBm), Storage. Each check links to the page
  that fixes it where there is one.
- the network path: gateway (address, DNS) → this device (model, address, uptime) → each
  radio (band, channel · width, rate) with its networks as chips (lock = encrypted, the
  count of clients, or "joined" for a station link).
- throughput: a sparkline per interface (uplink, each radio) over the last five minutes,
  download in the accent colour and upload in its own; peaks beside it. For the uplink,
  received bytes are download; for a radio, transmitted bytes are (the clients' download).
- radios (channel, width, TX power, noise, country, networks), clients (name from LuCI's
  host hints, MAC · IP, network · band, signal bars and dBm, ↓ TX / ↑ RX rate, the Wi-Fi
  generation from the rate flags, connected time; only an access point's own stations
  count -- a station-mode network's peer is the AP it joined), system (firmware, kernel,
  uptime, load, memory and storage bars) and the UniFi controller card (adoption, inform
  URL, last contact and failure, presented identity, hardware profile, version, the
  configuration error if any; a link to Services → openUF).

The ACL `luci-app-openuf` gained the read-only grants the page needs (`system board/info`,
`luci-rpc getNetworkDevices/getWirelessDevices/getHostHints`, `network.interface dump`,
`network.device status`, `network.wireless status`, `iwinfo info/assoclist`, read of
`/proc/cpuinfo`); root needed none of them. Verified in the QEMU VM with two
`mac80211_hwsim` radios (an AP "Halo Lab" and a station on the second radio that joins it,
so a real association shows), light and dark, 1440 px, 960 px and 390 px.

## The Halo theme (luci-theme-halo, 2026-10-18; reworked 2026-10-19)

A full LuCI theme modelled on UniFi Network, meant to stand alone, and the same tokens as the
device page so the two read as one product. The 2026-10-19 rework replaced a plain sidebar
(which read as Bootstrap recoloured) with UniFi's two-level navigation and a set of
stock-page tidy-ups, after a look at luci-theme-vantage (anothaDev, GPL-3.0) for what makes a
LuCI theme feel like a product rather than a reskin. Ideas were taken from it; its code was
not (Halo is Apache-2.0): the shell, script and stylesheet are Halo's own.

- **Shell** (`header.ut`, `menu-halo.js`): one sidebar with the hostname and model at its
  head, a row per section (LuCI's menu level 1) with an icon and the name, the section's
  pages nested under it (level 2; the open sections are remembered per browser), the
  menu's deeper levels as a segmented control above the page, a top bar with the
  breadcrumb and LuCI's indicators as pills (the unsaved-changes count as a badge, the
  refresh dot pulsing). The sidebar has three shapes, chosen before first paint from
  `data-nav` on `<html>` and kept current on resize: `side` (the full sidebar), `rail`
  (icons only, the name on hover, the pages in a flyout -- on screens ≤ 1100 px, or
  collapsed by the person with the button at the foot, `localStorage` `halo.nav`; the host
  chip then shows in the top bar) and `bar` (phones ≤ 720 px: a bottom bar of sections and
  a sheet of pages). An appearance toggle at the foot cycles automatic / light / dark
  (`localStorage` `halo.theme`, applied before first paint); the Halo Dark / Halo Light
  variants pin a scheme and hide it. The first version of the rework (same day) had an
  icon rail with a separate page-list column; the user found the icons and their names
  too far apart, hence the single sidebar.
- **Content**: the page column is capped (1280 px; 1760 px for the dashboard) and centred on
  a wider screen; cards with a full-bleed header row, tables edge to edge inside them, a
  200 px label column with fields up to 400 px, one control height, sentence-case table
  headers, tabular figures, form tabs underlined, a floating Save & Apply bar docked
  bottom right (above the bottom bar on phones).
- **Stock pages** (CSS where the markup allows, `menu-halo.js` where it does not): the
  overview's memory table becomes one meter (in use / cache / free) and storage one thin bar
  per mount, both rebuilt from LuCI's own table on every poll (the table stays, hidden);
  `ui.itemlist` dumps ("Label: value<br>") become label / value grids; interface rows show a
  property grid beside the device box; zone colours LuCI sets inline are tinted with the
  colour as an edge; firewall targets and policies are coloured; a heading that only repeats
  the breadcrumb is hidden from view and kept for screen readers; the overview's Hide / Show
  labels are outlined pills; radio boxes get a band chip.
- **Not adopted from Vantage, on purpose**: folding help text to one line, folding row
  actions into a ⋯ menu, the command palette. The first two rewrite what LuCI draws and
  were that theme's main source of regressions; none of the three is UniFi's idiom.

Every class `luci-theme-bootstrap` styles is covered, with its mechanics for the dropdown,
dynamic list, tooltip, modal overlay and the narrow-screen table collapse carried over
(Apache-2.0, credited in the file). Checked in the QEMU VM on 2026-10-19: login, Status
overview (light and dark), Interfaces and its edit modal, System (form tabs), Firewall zones,
openUF's own pages, the 960 px flyout, the 390 px bottom bar and sheet, the appearance
toggle. Not yet on a real AP (both lab APs are production).

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

Formalities the feeds check on submission: `PKG_MAINTAINER`, `PKG_LICENSE:=GPL-3.0-or-later`,
`PKG_LICENSE_FILES:=LICENSE NOTICE`, two-space metadata blocks and tabbed recipes, unindented
`conffiles`, procd init, an executable answering `--version` with `PKG_VERSION`, tabs in the
JavaScript (`js-beautify -t -a -j -w 110`), a `.pot` under `po/templates`.

## One install path per device (2026-10-19)

A Deco M4R set up with `setup.sh` (then a file install under `/opt/openuf`) and later given
the `openuf` and `luci-app-openuf` packages appeared in the controller as two devices. The
init script runs `/usr/lib/openuf` whenever it exists, so the package's copy took over with
the package's `/etc/config/openuf` (`modelmap auto`), not the `conf.lua` the interview had
written -- a different profile is a different `lan_cpueth`, which is a different identity
MAC. `setup.sh` is therefore the one entry point and never mixes the two:

- its interview asks **headless?** (default no): the web install fetches the `.apk`/`.ipk`
  files of the latest GitHub release (`OPENUF_RELEASE_URL`, or `OPENUF_PKG_DIR` for files
  already on the device), installs `openuf` + `luci-app-openuf` (+ `luci-theme-halo` when
  wanted and present in the release) in one transaction with `apk add --allow-untrusted` /
  `opkg install`, writes the answers to `/etc/config/openuf` (a generated profile as the
  `custom` device + `port` sections), creates the adoption account through the new
  `openuf bootstrap-account` (`hook/openuf-bootstrap.sh`) and removes a leftover
  `/opt/openuf`; headless is the file install as before;
- `install.sh install` refuses when `/usr/lib/openuf/inform.lua` exists;
- the package's `postinst-pkg` warns when `/opt/openuf/inform.lua` exists and says how to
  carry the configuration over.

Testing this in the VM found a second bug: on apk, `apk info -e hostapd` is true for
`wpad-basic-mbedtls` (it PROVIDES hostapd), so `setup.sh`'s packages phase believed a full
wpad was installed and skipped the swap -- on every 25.12 device, which then had an openUF
that never starts. The phase now decides by the binary (`wnm_sleep_mode` in
`/usr/sbin/hostapd`, as the init script does), and every `pkg_installed` on apk (setup.sh,
install.sh, openuf-deps.sh) matches the exact package line of `apk list -I`.

A third, found when the new hook ran in the VM: `install.sh` hashed the bootstrap account's
password with `openssl passwd -6`, and a stock image has no `openssl` binary (lua-openssl
brings the library only, the CLI is `openssl-util`) -- the hash came out empty and the
account had no password at all. `hook/openuf-bootstrap.sh` now creates the account locked
(`!`), then hashes with what the image has (the openssl CLI; busybox `passwd -a sha512`
fed on stdin under `setsid`, so it does not ask the terminal; `uhttpd -m`), and says so
when none of them worked -- locked beats open. `install.sh` calls the same hook.

The release workflow attaches `luci-theme-halo` since this branch; v0.1.8 and earlier ship
only `openuf` and `luci-app-openuf`, so a web install from those says so and skips the theme.

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
