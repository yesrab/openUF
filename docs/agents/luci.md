# The LuCI app, the device page and the theme: landmines

Part of the agent notes: [CLAUDE.md](../../CLAUDE.md) is the index and holds the hard constraints.

Read before changing anything under `package/`. PACKAGING.md is the blueprint; the two install
prefixes and `/etc/config/openuf` are in [installers.md](installers.md).

- **The SDK build minifies CSS with csstidy, and csstidy breaks this CSS.** `luci.mk` runs
  `csstidy --template=highest` on every stylesheet under `htdocs`: selectors sharing declarations
  are merged across the file and `margin`/`padding` shorthands are rebuilt by splitting on spaces,
  so a `calc(-1 * …)` margin became `margin:calc(-1;` and the browser dropped every rule after it
  (v0.2.2 on AP2, 2026-10-26: unstyled login, unusable sidebar). Both LuCI packages set
  `LUCI_MINIFY_CSS:=0` before including `luci.mk`; keep it, and keep jsmin (its output was
  verified byte for byte against luci-base's `jsmin.c`). A package that renders fine from the
  tree and badly from a release is this until proven otherwise: compare the device's file with
  the tree's, and count what Chrome parses (`new CSSStyleSheet().replaceSync(text).cssRules`).
- **The device page is a uhttpd ucode handler that uhttpd loads ONCE, at start.**
  `luci-app-openuf`'s uci-defaults puts `/cgi-bin/luci=/usr/share/ucode/openuf/gate.uc` into
  `uhttpd.*.ucode_prefix` (replacing LuCI's own line, or adding it where stock 25.12 serves
  LuCI as the `/www/cgi-bin/luci` CGI script -- a ucode prefix wins over the CGI file). A
  changed `gate.uc` does nothing until uhttpd restarts; the package's postinst restarts it only
  when uhttpd is already running the gate (an upgrade), so a first install takes over at the
  reboot, as asked. The gate fails OPEN to LuCI on any error. `openuf.web.portal` is read per
  request and needs no restart.
- **uhttpd's ucode handler passes no `DOCUMENT_ROOT`, and LuCI breaks quietly without it**:
  `L.env.documentroot` is null, LuCI lists `null/luci-static/resources/preload`, rpcd refuses,
  and no preload script (ours: *Exit LuCI mode*) ever loads. `gate.uc` supplies uhttpd's
  `home` before dispatching. Anyone running LuCI's own `uhttpd.uc` handler has the same gap.
- **The page switch is `openuf.web.portal`, never `openuf.main.*`.** A `main` section is what
  makes UCI replace `conf.lua` (uciconf.lua); creating one on a tarball install to hold a web
  option would move the identity MAC. The portal therefore writes `main` only where it
  already exists and shows openUF's fields read-only otherwise.
- **A LuCI MultiValue/ListValue with no choices throws and blanks the whole page**
  (`Cannot convert undefined or null to object` in ui.js): build such an option only when
  there is something to choose (settings.js' radio picker on a board with no radio).
- **The overview's Updates section never asks GitHub by itself, and its update outlives the
  request that started it.** `openuf ota --check` runs on the button only; `--start` is
  detached and `--status` is polled (see installers.md, "Changing `openuf-ota.sh`"). The ACL
  splits them: `--check` and `--status` under read, `--start --tag *` under write
  (`tests/test_acl.lua`). `dom.content()` renders a `null` in its list as the text "null":
  build the list without it.
