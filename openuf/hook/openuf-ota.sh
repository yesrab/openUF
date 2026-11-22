#!/bin/sh
# openuf-ota -- update an installed openUF to the latest published release,
# from the device itself. `openuf ota ...` on the command line, and the
# "Check for updates" button on the LuCI overview.
#
#   openuf ota --check
#       Asks GitHub for the latest release and prints JSON, changing nothing:
#         {"installed":"0.4.1","build":"v0.4.1 2026-11-18T17:05Z",
#          "kind":"apk","latest":"0.4.2","tag":"v0.4.2","newer":true,
#          "published":"2026-11-22T10:00:00Z",
#          "url":"https://github.com/yesrab/openUF/releases/tag/v0.4.2",
#          "packages":["openuf","luci-app-openuf"],"error":null}
#       kind is how this device was installed, which decides what an update
#       installs: "apk" / "opkg" (the openuf package; its packages from the
#       release) or "tarball" (install.sh under /opt/openuf; the release
#       archive through openuf-update). newer is null when the installed
#       version cannot be read as a release number.
#   openuf ota --install [--tag v0.4.2] [--force]
#       Updates now, in the foreground, printing what it does. Does nothing
#       when the release is not newer than what is installed, unless --force
#       (a reinstall, or going back to an older --tag).
#   openuf ota --start [--tag v0.4.2]
#       The same, detached from the caller, for the web UI: installing
#       luci-app-openuf restarts the very rpcd and uhttpd the button's
#       request came through. Prints {"started":true}; follow with --status.
#   openuf ota --status
#       JSON: {"state":"idle|running|done|failed","step":"...","message":"...",
#              "from":"0.4.1","to":"0.4.2","log":"..."} for the last update.
#
# What an update does, in this order:
#   1. reads the release, picks its files for this install and checks that
#      every one of them is there
#   2. downloads them to /tmp and compares each with the sha256 GitHub
#      publishes for it; a mismatch stops here
#   3. package install: also downloads the INSTALLED version's packages, as
#      the way back (skipped, and said, when that release is gone)
#   4. installs: `apk add --allow-untrusted` / `opkg install` for a package
#      install, `openuf-update --from <archive>` for a tarball install
#      (which keeps conf.lua, and has its own backup and rollback)
#   5. restarts openUF and waits for the new daemon to complete an inform
#      cycle (/tmp/openuf-status). A controller that does not answer is
#      reported, not rolled back: the old version would face the same
#      controller. A daemon that does not run is rolled back.
#
# Nothing here touches the network configuration or the radios, and
# /etc/config/openuf, conf.lua and /etc/openuf/state.json stay as they are:
# no re-adoption. Downloads are refused when the TLS certificate cannot be
# verified (no fallback to an unverified download, unlike setup.sh's first
# install: this one runs unattended and installs as root).
#
# Busybox ash. Check with `bash -n` and `dash -n`.
set -u

REPO=${OPENUF_REPO:-yesrab/openUF}
API=${OPENUF_OTA_API:-https://api.github.com/repos/$REPO/releases}
# Overridable by the tests only.
RUN=${OPENUF_OTA_RUN:-/tmp}
PKG_DIR=${OPENUF_OTA_PKG_DIR:-/usr/lib/openuf}
TAR_DIR=${OPENUF_OTA_TAR_DIR:-/opt/openuf}
RELEASE_JSON=${OPENUF_OTA_RELEASE_JSON:-}
HEALTH_FILE=${OPENUF_OTA_HEALTH_FILE:-/tmp/openuf-status}

STATUS=$RUN/openuf-ota.status
LOG=$RUN/openuf-ota.log
LOCK=$RUN/openuf-ota.lock
WORK=$RUN/openuf-ota.d
HEALTH_DEADLINE=75
PACKAGES="openuf luci-app-openuf luci-theme-halo"

say()  { printf '%s\n' "$*"; }
warn() { printf 'openuf-ota: %s\n' "$*" >&2; }

# ─── What is installed, and how ─────────────────────────────────────────────
if [ -f "$PKG_DIR/inform.lua" ]; then
	DIR=$PKG_DIR
	if command -v apk >/dev/null 2>&1; then KIND=apk
	elif command -v opkg >/dev/null 2>&1; then KIND=opkg
	else KIND=unknown; fi
elif [ -f "$TAR_DIR/inform.lua" ]; then
	DIR=$TAR_DIR
	KIND=tarball
else
	DIR=""
	KIND=none
fi

# exact name and its version: `apk info -e` is also true for a package that
# merely PROVIDES the name.
pkg_version() {
	case "$KIND" in
		apk)  apk list -I "$1" 2>/dev/null | sed -n "s/^$1-\\([0-9][^ ]*\\) .*/\\1/p" | head -1 ;;
		opkg) opkg list-installed "$1" 2>/dev/null | sed -n "s/^$1 - \\(.*\\)\$/\\1/p" | head -1 ;;
	esac
}

# A release number out of whatever names the installed version: "0.4.1",
# "0.4.1-r1", "v0.4.1", and a tarball's stamp "v0.4.1-3-gabc1234 2026-..."
# (which is 0.4.1 plus commits, so it still compares as 0.4.1). Empty when
# there is none, and then nothing is claimed about newer or older.
release_number() {
	printf '%s\n' "$1" | sed -n 's/^v\{0,1\}\([0-9][0-9]*\(\.[0-9][0-9]*\)\{1,3\}\).*/\1/p' | head -1
}

BUILD=$(cat "$DIR/BUILD" 2>/dev/null | head -1)
case "$KIND" in
	apk|opkg) INSTALLED=$(release_number "$(cat "$DIR/VERSION" 2>/dev/null | head -1)")
	          [ -n "$INSTALLED" ] || INSTALLED=$(release_number "$(pkg_version openuf)") ;;
	tarball)  INSTALLED=$(release_number "$BUILD") ;;
	*)        INSTALLED="" ;;
esac

# ver_gt A B: A is a later release number than B.
ver_gt() {
	[ -n "$1" ] && [ -n "$2" ] || return 1
	printf '%s %s\n' "$1" "$2" | awk '{
		n = split($1, a, "."); m = split($2, b, "."); k = (n > m) ? n : m
		for (i = 1; i <= k; i++) {
			x = (i <= n) ? a[i] + 0 : 0; y = (i <= m) ? b[i] + 0 : 0
			if (x > y) exit 0
			if (x < y) exit 1
		}
		exit 1 }'
}

# ─── JSON out ───────────────────────────────────────────────────────────────
# A string as a JSON string body: backslash, quote, control characters, and
# newlines as \n (the log is many lines).
json_esc() {
	awk 'BEGIN { ORS = "" }
		{ gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); gsub(/\t/, "\\t"); gsub(/\r/, "")
		  gsub(/[[:cntrl:]]/, "")
		  if (NR > 1) printf "\\n"
		  print }'
}
json_str() { if [ -n "$1" ]; then printf '"%s"' "$(printf '%s' "$1" | json_esc)"; else printf null; fi; }

# ─── Download ───────────────────────────────────────────────────────────────
# fetch <url> <dest> [header]. Whichever client the image has; certificate
# verification is each one's default and is never turned off. The timeout
# keeps a stalled handshake (see fetch_asset) from holding the update for
# the clients' own half minute per try.
fetch() {
	if command -v uclient-fetch >/dev/null 2>&1; then
		uclient-fetch -q -T 20 ${3:+"--header=$3"} -O "$2" "$1" 2>/dev/null && return 0
	fi
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL -m 120 ${3:+-H "$3"} -o "$2" "$1" 2>/dev/null && return 0
	fi
	if command -v wget >/dev/null 2>&1 && [ "$(readlink -f "$(command -v wget)" 2>/dev/null)" != /bin/uclient-fetch ]; then
		wget -q -T 20 ${3:+"--header=$3"} -O "$2" "$1" 2>/dev/null && return 0
	fi
	return 1
}

# fetch_asset <api url or -> <download url> <dest>: a release file, through
# the API's asset address first. On OpenWrt 25.12 uclient-fetch (mbedtls)
# cannot complete a TLS handshake with github.com at all -- 30 s, then
# "Connection timed out", on the test VM and on AP2 alike, 2026-11-22 --
# while api.github.com, which redirects to the same file, answers at once.
# The plain download URL is the second try, for a client that can.
fetch_asset() {
	if [ "$1" != "-" ] && fetch "$1" "$3" "Accept: application/octet-stream" && [ -s "$3" ]; then
		return 0
	fi
	fetch "$2" "$3" && [ -s "$3" ]
}

sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" 2>/dev/null | awk '{print $1}'
	elif command -v openssl >/dev/null 2>&1; then openssl dgst -sha256 "$1" 2>/dev/null | awk '{print $NF}'
	fi
}

# ─── The release ────────────────────────────────────────────────────────────
# release_load <tag or ""> : fetch the release (latest, or the named tag) and
# turn it into shell-safe lines in $WORK/release:
#   tag=v0.4.2 / published=... / url=...
#   asset <name> <download url> <sha256 or -> <API asset url or ->
# Everything in it came off the network and ends up on a command line, so the
# parser lets through only a version-shaped tag, file names of [A-Za-z0-9._-]
# and URLs under this repository's own releases (the download URL, and the
# API's address of the same file); anything else is dropped there. lua and lua-cjson are openUF's own dependencies.
REL_ERR=""
release_load() {
	mkdir -p "$WORK" || { REL_ERR="cannot create $WORK"; return 1; }
	rm -f "$WORK/release" "$WORK/release.json"
	if [ -n "$RELEASE_JSON" ]; then
		cp "$RELEASE_JSON" "$WORK/release.json" 2>/dev/null || { REL_ERR="cannot read $RELEASE_JSON"; return 1; }
	else
		_u="$API/latest"
		[ -n "$1" ] && _u="$API/tags/$1"
		if ! fetch "$_u" "$WORK/release.json"; then
			REL_ERR="could not reach GitHub for the release list. Check the device's internet access, DNS and clock (a wrong date fails the certificate check); GitHub also limits how often an address may ask"
			[ -n "$1" ] && REL_ERR="could not read release $1 from GitHub (no such release, or no internet access)"
			return 1
		fi
	fi
	command -v lua >/dev/null 2>&1 || { REL_ERR="lua not found"; return 1; }
	OTA_REPO=$REPO OTA_API=$API lua - "$WORK/release.json" > "$WORK/release" 2>"$WORK/release.err" <<'LUA'
local ok, cjson = pcall(require, "cjson")
if not ok then io.stderr:write("lua-cjson is not installed\n"); os.exit(1) end
local f = io.open(arg[1], "r")
local text = f and f:read("*a") or ""
if f then f:close() end
local okd, doc = pcall(cjson.decode, text)
if not okd or type(doc) ~= "table" then io.stderr:write("the release list is not JSON\n"); os.exit(1) end
local tag = doc.tag_name
if type(tag) ~= "string" or not tag:match("^v?%d+%.%d+[%d%.]*$") then
	io.stderr:write("no release found" .. (type(doc.message) == "string" and (": " .. doc.message:sub(1, 120):gsub("[^%w %.%-_,:/]", "")) or "") .. "\n")
	os.exit(1)
end
local repo = os.getenv("OTA_REPO") or ""
local prefix = "https://github.com/" .. repo .. "/releases/"
print("tag=" .. tag)
local pub = doc.published_at
if type(pub) == "string" and pub:match("^[%d%-T:Z]+$") then print("published=" .. pub) end
print("url=" .. prefix .. "tag/" .. tag)
for _, a in ipairs(type(doc.assets) == "table" and doc.assets or {}) do
	local name, url, digest = a.name, a.browser_download_url, a.digest
	if type(name) == "string" and name:match("^[%w][%w%._%-]*$") and type(url) == "string"
			and url == prefix .. "download/" .. tag .. "/" .. name then
		local sha = type(digest) == "string" and digest:match("^sha256:(%x+)$")
		if sha and #sha ~= 64 then sha = nil end
		local api, id = os.getenv("OTA_API") or "", a.url
		if type(id) ~= "string" or id:sub(1, #api + 8) ~= api .. "/assets/"
				or not id:sub(#api + 9):match("^%d+$") then
			id = "-"
		end
		print("asset " .. name .. " " .. url .. " " .. (sha and sha:lower() or "-") .. " " .. id)
	end
end
LUA
	if [ $? -ne 0 ] || ! grep -q '^tag=' "$WORK/release" 2>/dev/null; then
		REL_ERR=$(head -1 "$WORK/release.err" 2>/dev/null)
		[ -n "$REL_ERR" ] || REL_ERR="the release list could not be read"
		return 1
	fi
	REL_TAG=$(sed -n 's/^tag=//p' "$WORK/release" | head -1)
	REL_VER=$(release_number "$REL_TAG")
	REL_PUBLISHED=$(sed -n 's/^published=//p' "$WORK/release" | head -1)
	REL_URL=$(sed -n 's/^url=//p' "$WORK/release" | head -1)
	return 0
}

# asset_line <ERE on the name>: the first matching "name url sha apiurl" of $2
# (default: the loaded release).
asset_line() {
	awk -v re="$1" '$1 == "asset" && $2 ~ re { print $2, $3, $4, $5; exit }' "${2:-$WORK/release}" 2>/dev/null
}

# The asset name pattern of a package for this package manager.
pkg_asset_re() {
	case "$KIND" in
		apk)  printf '^%s-[0-9][0-9.]*-r[0-9]+\\.apk$' "$1" ;;
		opkg) printf '^%s_[0-9][0-9.]*-r[0-9]+_all\\.ipk$' "$1" ;;
	esac
}

# What an update would install: one "pkg name url sha apiurl" line per file in
# $WORK/plan. Fails with PLAN_ERR when the release has nothing for this
# install.
PLAN_ERR=""
plan_build() {
	: > "$WORK/plan"
	case "$KIND" in
		apk|opkg)
			for _p in $PACKAGES; do
				_have=$(pkg_version "$_p")
				[ -n "$_have" ] || continue          # not installed here: not ours to add
				_a=$(asset_line "$(pkg_asset_re "$_p")")
				if [ -z "$_a" ]; then
					[ "$_p" = openuf ] && { PLAN_ERR="release $REL_TAG has no openuf package for $KIND"; return 1; }
					continue
				fi
				# The same version already (the theme's seldom changes): nothing
				# to do. Not for the way back (PLAN_ALL), whose files ARE the
				# installed versions: every one of them is wanted there.
				if [ "${PLAN_ALL:-0}" != 1 ]; then
					case "${_a%% *}" in
						"$_p-$_have.apk"|"${_p}_${_have}_all.ipk") [ "$_p" = openuf ] || continue ;;
					esac
				fi
				printf '%s %s\n' "$_p" "$_a" >> "$WORK/plan"
			done
			grep -q '^openuf ' "$WORK/plan" || { PLAN_ERR="the openuf package is not in the package database"; return 1; }
			;;
		tarball)
			_a=$(asset_line '^openuf-[0-9][0-9.]*\.tar\.gz$')
			[ -n "$_a" ] || { PLAN_ERR="release $REL_TAG has no openuf-<version>.tar.gz"; return 1; }
			printf 'openuf %s\n' "$_a" > "$WORK/plan"
			;;
		none)    PLAN_ERR="openUF is not installed"; return 1 ;;
		*)       PLAN_ERR="no package manager found (neither apk nor opkg)"; return 1 ;;
	esac
	return 0
}

# ─── --check ────────────────────────────────────────────────────────────────
do_check() {
	_err=""; _newer=null; _pk=""
	# Its own scratch directory: a check must not pull the files out from
	# under an update that is running.
	WORK=$RUN/openuf-ota.check.$$
	if [ "$KIND" = none ]; then
		_err="openUF is not installed"
	elif ! release_load ""; then
		_err=$REL_ERR
	else
		if plan_build; then
			_pk=$(awk '{ printf "%s\"%s\"", (NR > 1 ? "," : ""), $1 }' "$WORK/plan")
		else
			_err=$PLAN_ERR
		fi
		if [ -n "$INSTALLED" ] && [ -n "$REL_VER" ]; then
			if ver_gt "$REL_VER" "$INSTALLED"; then _newer=true; else _newer=false; fi
		fi
	fi
	printf '{"installed":%s,"build":%s,"kind":"%s","latest":%s,"tag":%s,"newer":%s,"published":%s,"url":%s,"packages":[%s],"error":%s}\n' \
		"$(json_str "$INSTALLED")" "$(json_str "$BUILD")" "$KIND" \
		"$(json_str "${REL_VER:-}")" "$(json_str "${REL_TAG:-}")" "$_newer" \
		"$(json_str "${REL_PUBLISHED:-}")" "$(json_str "${REL_URL:-}")" "$_pk" "$(json_str "$_err")"
	rm -rf "$WORK"
	[ -z "$_err" ]
}

# ─── --status ───────────────────────────────────────────────────────────────
status_val() { sed -n "s/^$1=//p" "$STATUS" 2>/dev/null | head -1; }
status_set() {   # state step message
	{
		printf 'state=%s\nstep=%s\nmessage=%s\n' "$1" "$2" "$3"
		printf 'from=%s\nto=%s\npid=%s\nat=%s\n' "${FROM:-}" "${TO:-}" "$$" "$(date +%s)"
	} > "$STATUS.new" 2>/dev/null && mv "$STATUS.new" "$STATUS"
}

do_status() {
	_state=$(status_val state); _msg=$(status_val message); _step=$(status_val step)
	[ -n "$_state" ] || _state=idle
	if [ "$_state" = running ]; then
		_pid=$(status_val pid)
		# The updater died without saying so (power, a kill): do not leave
		# the page spinning on it.
		# (--start writes "start" under its own, short-lived pid a moment
		# before the detached run writes its own: allow that hand-over.)
		_age=$(( $(date +%s) - $(status_val at || echo 0) ))
		if [ "$_step" = start ] && [ "$_age" -lt 20 ] 2>/dev/null; then
			:
		elif [ -z "$_pid" ] || ! kill -0 "$_pid" 2>/dev/null; then
			_state=failed
			_msg="the updater stopped before it finished (during: ${_step:-start}). The log below says how far it got"
		fi
	fi
	printf '{"state":"%s","step":%s,"message":%s,"from":%s,"to":%s,"log":%s}\n' \
		"$_state" "$(json_str "$_step")" "$(json_str "$_msg")" \
		"$(json_str "$(status_val from)")" "$(json_str "$(status_val to)")" \
		"$(json_str "$(tail -n 60 "$LOG" 2>/dev/null)")"
}

# ─── The update ─────────────────────────────────────────────────────────────
health_val() { sed -n "s/^$1=//p" "$HEALTH_FILE" 2>/dev/null | head -1; }

fail() {   # step message
	say ""
	say "FAILED ($1): $2"
	status_set failed "$1" "$2"
	rm -rf "$WORK" "$LOCK"
	exit 1
}

# download_plan <plan file> <dir> <step>: every file of the plan into dir,
# each checked against the release's sha256.
download_plan() {
	mkdir -p "$2" || return 1
	while read -r _p _name _url _sha _api; do
		[ -n "$_name" ] || continue
		say "  ..    $_name"
		fetch_asset "${_api:--}" "$_url" "$2/$_name" || { DL_ERR="could not download $_name"; return 1; }
		if [ "$_sha" != "-" ]; then
			_got=$(sha256_of "$2/$_name")
			if [ -z "$_got" ]; then
				DL_ERR="no sha256sum on this device to check $_name with"; return 1
			fi
			if [ "$_got" != "$_sha" ]; then
				DL_ERR="$_name does not match the checksum GitHub publishes for it (got $_got)"; return 1
			fi
			say "  ok    $_name (sha256 matches)"
		else
			DL_ERR="release has no checksum for $_name"; return 1
		fi
	done < "$1"
	return 0
}

pkg_install() {   # dir, files...  ; $ROLLBACK=1 allows a downgrade
	_d=$1; shift
	_files=""
	for _f in "$@"; do _files="$_files $_d/$_f"; done
	case "$KIND" in
		apk)  # shellcheck disable=SC2086
		      apk add --allow-untrusted $_files ;;
		opkg) if [ "${ROLLBACK:-0}" = 1 ]; then
		          # shellcheck disable=SC2086
		          opkg install --force-downgrade $_files
		      else
		          # shellcheck disable=SC2086
		          opkg install $_files
		      fi ;;
	esac
}

# Restart openUF and wait for the new daemon's first completed inform cycle.
# Prints ok / unanswered / dead (no daemon process) / none (a daemon, but no
# cycle within the deadline).
restart_and_wait() {
	_at=$(date +%s)
	/etc/init.d/openuf restart >/dev/null 2>&1
	_w=0; _h=none
	while [ "$_w" -lt "$HEALTH_DEADLINE" ]; do
		sleep 5; _w=$((_w + 5))
		_ok=$(health_val last_ok); _fl=$(health_val last_fail)
		if [ -n "$_ok" ] && [ "$_ok" -ge "$_at" ] 2>/dev/null; then _h=ok; break; fi
		if [ -n "$_fl" ] && [ "$_fl" -ge "$_at" ] 2>/dev/null; then _h=unanswered; fi
		_n=$(ps w 2>/dev/null | grep -E 'lua inform\.lua' | grep -vc grep)
		if [ "$_n" = 0 ] && [ "$_w" -ge 20 ]; then _h=dead; break; fi
	done
	printf '%s' "$_h"
}

do_install() {   # tag or ""
	[ "$(id -u 2>/dev/null || echo 0)" = 0 ] || { warn "must run as root"; exit 1; }
	# One at a time. A lock whose owner is gone is a crashed run's.
	if ! mkdir "$LOCK" 2>/dev/null; then
		_o=$(cat "$LOCK/pid" 2>/dev/null)
		if [ -n "$_o" ] && kill -0 "$_o" 2>/dev/null; then
			warn "an update is already running (pid $_o)"; exit 1
		fi
		rm -rf "$LOCK"; mkdir "$LOCK" || { warn "cannot create $LOCK"; exit 1; }
	fi
	echo $$ > "$LOCK/pid"
	rm -rf "$WORK"
	FROM=$INSTALLED; TO=""

	status_set running check "reading the release"
	say "== release"
	[ "$KIND" != none ] || fail check "openUF is not installed"
	release_load "$1" || fail check "$REL_ERR"
	TO=$REL_VER
	say "  installed   ${INSTALLED:-unknown}${BUILD:+ ($BUILD)}"
	say "  release     $REL_TAG${REL_PUBLISHED:+, published $REL_PUBLISHED}"
	if [ "$FORCE" != 1 ] && [ -n "$INSTALLED" ] && ! ver_gt "$REL_VER" "$INSTALLED"; then
		say ""
		say "DONE: openUF $INSTALLED is already the latest release (--force installs $REL_TAG anyway)."
		status_set done done "openUF $INSTALLED is already the latest release"
		rm -rf "$WORK" "$LOCK"
		exit 0
	fi
	plan_build || fail check "$PLAN_ERR"
	say "  install     $KIND: $(awk '{ printf "%s%s", (NR > 1 ? ", " : ""), $2 }' "$WORK/plan")"

	status_set running download "downloading $REL_TAG"
	say ""
	say "== download"
	DL_ERR=""
	download_plan "$WORK/plan" "$WORK/new" || fail download "$DL_ERR. Nothing was changed"

	if [ "$KIND" = tarball ]; then
		status_set running install "installing $REL_TAG"
		say ""
		say "== install (openuf-update, which backs up and rolls back by itself)"
		command -v openuf-update >/dev/null 2>&1 || fail install "openuf-update is not installed; run install.sh from the release archive once"
		_arch=$(awk '{ print $2; exit }' "$WORK/plan")
		if openuf-update --from "$WORK/new/$_arch"; then
			say ""
			say "DONE: openUF ${INSTALLED:-?} -> $REL_VER"
			status_set done done "openUF is now $REL_VER"
			rm -rf "$WORK" "$LOCK"
			exit 0
		fi
		fail install "openuf-update did not complete; what it printed is above. It restores the previous version by itself when the new one does not start"
	fi

	# The way back for a package install: the installed version's own
	# packages, fetched while the download works. Without them a daemon that
	# does not start stays as it is, and that is said.
	HAVE_OLD=0
	if [ -n "$INSTALLED" ] && [ "$INSTALLED" != "$REL_VER" ] && [ -z "$RELEASE_JSON" ]; then
		say ""
		say "== the way back (release v$INSTALLED)"
		if fetch "$API/tags/v$INSTALLED" "$WORK/old.json" \
				&& RELEASE_JSON="$WORK/old.json" sh "$0" --plan-of "$WORK/old.json" "$WORK/oldplan" \
				&& download_plan "$WORK/oldplan" "$WORK/old"; then
			HAVE_OLD=1
		else
			say "  warn  release v$INSTALLED could not be fetched: a failed update cannot be undone automatically"
			rm -rf "$WORK/old"
		fi
	fi

	_was_enabled=0
	/etc/init.d/openuf enabled 2>/dev/null && _was_enabled=1

	status_set running install "installing $REL_TAG"
	say ""
	say "== install"
	# shellcheck disable=SC2046
	if ! pkg_install "$WORK/new" $(awk '{ print $2 }' "$WORK/plan"); then
		fail install "the package manager refused the new packages; what it printed is above. The installed version was not replaced"
	fi
	[ "$_was_enabled" = 1 ] && /etc/init.d/openuf enable >/dev/null 2>&1

	status_set running restart "restarting openUF and waiting for its first report to the controller"
	say ""
	say "== restart"
	_h=$(restart_and_wait)
	case "$_h" in
		ok)
			say "  ok    the new daemon completed an inform ($(health_val last_type))"
			say ""
			say "DONE: openUF ${INSTALLED:-?} -> $REL_VER. Configuration and adoption are unchanged."
			status_set done done "openUF is now $REL_VER"
			;;
		unanswered)
			say "  warn  the new daemon runs, but the controller has not answered yet: $(health_val last_fail_msg)"
			say ""
			say "DONE: openUF ${INSTALLED:-?} -> $REL_VER. Kept: the old version would face the same controller."
			status_set done done "openUF is now $REL_VER. The controller has not answered since the restart"
			;;
		*)
			if [ "$_h" = dead ]; then
				say "  warn  the new daemon is not running"
			else
				say "  warn  the new daemon did not complete a cycle within ${HEALTH_DEADLINE}s"
			fi
			logread 2>/dev/null | grep -E 'openuf|inform' | tail -8 | sed 's/^/    /'
			if [ "$HAVE_OLD" = 1 ]; then
				say ""
				say "== rolling back to $INSTALLED"
				# shellcheck disable=SC2046
				if ROLLBACK=1 pkg_install "$WORK/old" $(awk '{ print $2 }' "$WORK/oldplan"); then
					[ "$_was_enabled" = 1 ] && /etc/init.d/openuf enable >/dev/null 2>&1
					/etc/init.d/openuf restart >/dev/null 2>&1
					fail restart "openUF $REL_VER did not start; version $INSTALLED was put back and restarted"
				fi
				fail restart "openUF $REL_VER did not start, and putting $INSTALLED back failed too. Reinstall the packages by hand (see the log)"
			fi
			fail restart "openUF $REL_VER is installed but its daemon did not complete a cycle. Look at the system log (logread -e openuf)"
			;;
	esac
	rm -rf "$WORK" "$LOCK"
	exit 0
}

# ─── Entry ──────────────────────────────────────────────────────────────────
ACTION=""; TAG=""; FORCE=0
while [ $# -gt 0 ]; do
	case "$1" in
		--check|--status|--install|--start|--run) ACTION=$1 ;;
		--force) FORCE=1 ;;
		--tag) shift; [ $# -gt 0 ] || { warn "--tag needs a release tag"; exit 2; }; TAG=$1 ;;
		--plan-of)
			# Internal: the plan of another release's JSON ($2) into $3.
			[ $# -ge 3 ] || exit 2
			WORK=$(dirname "$3")/.planof.$$
			RELEASE_JSON=$2
			PLAN_ALL=1
			release_load "" && plan_build && cp "$WORK/plan" "$3"
			_rc=$?
			rm -rf "$WORK"
			exit $_rc ;;
		-h|--help) sed -n '2,50p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) warn "unknown option: $1 (see --help)"; exit 2 ;;
	esac
	shift
done
# A tag ends up in a URL and a file name.
case "$TAG" in
	"") ;;
	*[!A-Za-z0-9._-]*) warn "not a release tag: $TAG"; exit 2 ;;
esac

case "$ACTION" in
	--check)   do_check ;;
	--status)  do_status ;;
	--install) do_install "$TAG" ;;
	--run)
		# The detached run: everything it says goes to the log --status tails.
		trap '' HUP PIPE
		exec >"$LOG" 2>&1 </dev/null
		do_install "$TAG" ;;
	--start)
		[ "$(id -u 2>/dev/null || echo 0)" = 0 ] || { warn "must run as root"; exit 1; }
		_o=$(cat "$LOCK/pid" 2>/dev/null)
		if [ -n "$_o" ] && kill -0 "$_o" 2>/dev/null; then
			printf '{"started":false,"error":"an update is already running"}\n'
			exit 1
		fi
		# From a copy in /tmp: the package being installed replaces this very
		# file, and a shell reads its script as it goes.
		cp "$0" "$RUN/openuf-ota.run" 2>/dev/null || { printf '{"started":false,"error":"cannot write %s"}\n' "$RUN/openuf-ota.run"; exit 1; }
		: > "$LOG"
		FROM=$INSTALLED; TO=""
		status_set running start "starting"
		_force=""; [ "$FORCE" = 1 ] && _force=--force
		( sh "$RUN/openuf-ota.run" --run $_force ${TAG:+--tag "$TAG"} </dev/null >/dev/null 2>&1 & )
		printf '{"started":true}\n'
		;;
	*) sed -n '2,50p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
