# Upstream, the other forks, plugins and the licence

Part of the agent notes: [CLAUDE.md](../../CLAUDE.md) is the index and holds the hard constraints.

Read before an upstream sync, before touching `plugins.lua` or the rrb-unifi pin (the pin itself
is described in [installers.md](installers.md)), and before committing fixtures.

## Upstream: jonasevcik/openUF is inspiration, not a parent

This repository began as a fork of https://github.com/jonasevcik/openUF and was
**detached from the GitHub fork network on 2026-10-03**. It is a standalone repository:
there is no Sync-fork button, no ahead/behind count, no cross-repo compare view, and
upstream's commits no longer appear as shared history on GitHub. Do not write "this fork"
in the docs any more. Upstream stays reachable as a plain git remote:

```sh
git remote -v                                    # expect `upstream` -> jonasevcik/openUF
git remote add upstream https://github.com/jonasevcik/openUF.git   # if a fresh clone lacks it
git fetch upstream                               # ALWAYS first -- nothing else refreshes it
git log --oneline 08d0003..upstream/main         # what has not been reviewed yet
```

**The sync is a selective re-implementation, never a merge.** Keep ours where ours is
stronger; where theirs is better, re-implement it in this tree's style, with their tests,
and label their hardware evidence as theirs (upstream runs a Xiaomi AX3000T and an Archer
C5; this tree's lab is a JioRouter AX6000, DSA, `lan_cpueth = "br-lan"`). Upstream also takes
work from here (their 2026-09-25 commits were our 09-15 sysconf/l2guard/interval work,
credited to this repo), so diff before assuming a commit is new.

- **Last review point: `db5e92b` (re-checked 2026-11-13: upstream unchanged, so the next review still starts there) (upstream v0.13.0), sync 5 on 2026-11-02.** Earlier: the
  fork point `677f732`; sync 1 (2026-09-06) to `d7d7e21`; sync 2 (2026-09-13) to `12b4db0`;
  sync 3 (2026-09-28) to `08d0003` (v0.9.3); sync 4 (2026-10-18) to `2f263f3` (v0.11.0).
  The guest portal and its walled garden, left out of syncs 4 and 5, were adopted on 2026-11-17
  from upstream's head (PROTOCOL-VALIDATION.md § Adopted from upstream, 2026-11-17: the guest
  portal). Still not adopted: their `docs/WIRE-REFERENCE.md` split (`5f521bf`; our docs keep
  their own shape) and the GitHub issue templates.
  Each sync is a row in REVERSE-ENGINEERING.md's session log and an "Adopted from upstream,
  <date>" section in PROTOCOL-VALIDATION.md -- update both, and move this line.
- **A third fork is a remote too: `dmalinowski` → d-malinowski/openUF**, and his roaming
  project is where 802.11r with genuine UniFi APs lives now. The story, so it is not relived:
  his `pr/unifi-ft-interop` was adopted here on 2026-10-25 as `ftinterop.lua` with his
  translator vendored; jonasevcik answered the same PR (#2 upstream) with a plugin hook
  instead (`8287ecf`), he moved his module into his repository as an openUF plugin
  (release 1.4, tested on his HH5A + U7 Lite), closed the PR, and release 1.5 replaced the
  peer list with wildcard key holders -- which made this tree's two daemon changes
  (`wait 0`, `peers_file`, offered as PR #1 on his repository) unnecessary; he closed that PR
  on 2026-10-27 with the reasons. On 2026-11-02 this tree took upstream's hook as it is,
  removed `ftinterop.lua`, `openuf/rrb/` and the `openuf-rrb` service, and `setup.sh` offers
  his plugin (default yes). Their hardware is a HH5A and a U7 Lite; label it. The local clone
  `../unifi-openwrt-roaming` (`upstream` = his repository) is only for reading what the plugin
  and `rrb-unifi-setup` expect of openUF (`/opt/openuf/plugins.lua`, `M.API`); the fork
  `yesrab/unifi-openwrt-roaming` is not a source. One PR worth offering him: `rrb-unifi-setup`
  hardcodes `OUF=/opt/openuf`, and probing `/usr/lib/openuf` too would make the symlink
  unnecessary.
- **Mechanics that worked in syncs 3 and 4:** `git add -A` first, then per commit **in
  upstream's order** `git show --format= <c> -- openuf/ tests/ | git apply --3way` (the fetch puts their blobs in our
  object store; applying out of order makes later hunks miss their context). `inform.lua`
  has diverged enough that a hunk often lands as a "displaced block" (ours N lines, theirs
  a whole unrelated region): resolve those as ours and port the change by hand. Test files:
  resolve displaced blocks as ours, then port upstream's NEW tests by name (an entry is a
  one-tab `\t{` ... `\t},` block; a modified test is removed and re-added from their file).
  Copy wholesale any module byte-identical to the last sync point. Gate on the suite's
  final `Results:` line -- every per-file summary also says `0 failed`. Run `eval $(luarocks
  path --local)` before both the suite and `sh tools/dist.sh --verify`; use `sh -c` for
  word-split loops (zsh does not split an unquoted variable). A compile check on AP2 is
  `lua -e 'assert(loadfile("<f>"))'` per file -- `lua -e ... <f>` runs `<f>` as a script.
- **Fixtures** in both trees use RFC 7042 MACs (`00:00:5e:00:53:xx`) and RFC 5737 addresses
  (`192.0.2.x`). Pre-commit scan: `git diff --cached -U0 | grep "^+" | grep -nE
  "192\.168\.|([0-9a-f]{2}:){5}[0-9a-f]{2}"` -- `192.168.1.100` "testap" and `11:22:33`-style
  MACs are long-standing test placeholders, not lab values.
- **Nothing from the lab goes into these notes or the docs**: no device passwords, no API keys,
  no controller credentials. REVERSE-ENGINEERING.md's lab table carries the addresses and
  roles; secrets are asked for each session.

## Landmines

- **Plugins are upstream's `api = 1` contract, byte for byte, and `/opt/openuf` is part of it.**
  `plugins.lua` is jonasevcik's (8287ecf + 9159efd) with two additions: the plugin list may
  come from UCI (`openuf.main list plugin`, through `uciconf.lua`) and `M.list()` feeds the LuCI
  overview. A plugin written for upstream must run here unchanged, so do not rename `ctx`
  fields, change `M.API`'s line shape (`rrb-unifi-setup` reads it with `sed`), or move the
  hook away from "after every built-in option, before `wlan_add`". Upstream's `docs/PLUGINS.md`
  names `/opt/openuf/plugins.lua` as the detection path, so `/opt/openuf` is a symlink to
  `/usr/lib/openuf` on a package install: the package's postinst makes it when the path is
  free (the postrm removes ours), `setup.sh` makes it before running rrb-unifi-setup on a
  package install (a release before the postinst had it, and the tool's own PR to probe
  `/usr/lib/openuf` is still open), and `update.sh` refuses to run through it. A link, never
  a packaged file, so the two makers cannot conflict. The postinst's double-install warning
  and `install.sh`'s guard ignore a symlink. `inform._reconcile_plugins` forgets `cfgversion` when the fingerprint
  (names + file contents) moves, so enabling or removing a plugin costs one re-push. The
  `feature/pluginsAndHooks` branch (our superset: `before_push`/`after_push`/`tick`/`on_boot`/
  `on_forget`/`status`/declared packages, with a built-in `rrb` plugin) is superseded and was
  mined only for the UCI list and the LuCI field: with the translator external, nothing uses
  those hooks, and "proven by use, not by design" cuts the other way.
- **The repository is GPL-3.0-or-later since 2026-10-25** because of the then-vendored GPL
  translator; the translator is gone, the licence decision stays the user's (NOTICE records
  the history; the MIT notice for jonasevcik's work travels with the code either way).
