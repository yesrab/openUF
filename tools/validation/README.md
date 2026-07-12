# Live controller validation environment

Disposable Docker environment for validating openUF's controller-pushed payload
assumptions against a real UniFi Network Application controller — see
[PROTOCOL-VALIDATION.md](../../PROTOCOL-VALIDATION.md) for the findings this
produces and [USAGE.md](../../USAGE.md#3-configuration) for the `debug_dump_file`
flag used to capture responses.

No target OpenWrt hardware or real Ubiquiti device needed — the controller is a
plain Docker container, and the "AP" is a disposable Alpine container reachable via
SSH. **L2 (broadcast) adoption works end-to-end** in this environment: the
controller's real adopt flow (SSH in, run `syswrapper.sh set-adopt`) completes
exactly as it would against genuine hardware, once the setup below is followed
exactly (three separate real bugs had to be fixed to get here — see
PROTOCOL-VALIDATION.md's "L2 discovery + real SSH adoption now works end-to-end"
section for what they were and why). L3-only adoption (`set-inform` with no L2
broadcast) still does not complete — see PROTOCOL-VALIDATION.md.

## 1. Start the environment

```sh
# from the repo root
docker compose -f tools/validation/docker-compose.yml up -d --build
```

First boot of `unifi-db` takes a few seconds to run `init-mongo.sh`; give it a
moment before the controller container comes up healthy.

## 2. Complete the controller's first-run setup

Open `https://localhost:8443` (self-signed cert — accept the browser warning) and
step through the setup wizard: **Advanced Setup → Skip** (do not create a real
Ubiquiti cloud account) → set local admin credentials → Finish.

## 3. Set the Inform Host Override (required — do this before adopting anything)

Docker deployments of the UniFi Network Application don't know their own
externally-reachable address by default, and devices/informs get rejected
(`invalid inform_ip controller` in `server.log`) until this is set explicitly. This
setting lives in the controller's own database, so it's wiped by
`docker compose down -v` and must be redone after every full reset.

In the controller UI: **Devices → Device Updates and Settings → Device SSH
Settings** (or search "inform" in the settings search box) →

- Check **Inform Host Override**. **Use the controller container's real IP
  address, not the `controller` hostname** — get it with `docker inspect
  openuf-validation-controller --format '{{range .NetworkSettings.Networks}}
  {{.IPAddress}}{{end}}'`. A bare hostname here produces `invalid inform_ip
  <hostname>` in `server.log` once informs start flowing (this is what the value
  in that log line actually is — the AP's own configured `inform_url` host,
  echoed back — not, as an earlier version of this doc guessed, the override
  setting itself).
- Check **Device SSH Authentication**, username `root`, password matching the AP
  container's real sshd password (`openuf` by default per `ap/Dockerfile` — the
  controller's own password-strength validator requires ≥10 chars + uppercase +
  symbol, so if you change it here, `docker exec openuf-validation-ap sh -c "echo
  'root:<newpassword>' | chpasswd"` to match on the AP side too). **These
  credentials are only used for already-adopted devices** — see step 4.
- Apply Changes.

## 4. Start openUF inside the AP container (L2 / broadcast adoption)

`debug_dump_file` and the `eth0` interface override are already baked into the
image (`ap/Dockerfile`), along with the real Ubiquiti factory-default `ubnt`/`ubnt`
SSH account (see below for why) and the `ssh-rsa` host key algorithm re-enable
`sshd` needs to negotiate with the controller's SSH client — no manual setup step
needed for any of that.

```sh
docker exec -it openuf-validation-ap sh
cd /opt/openuf

# Broadcast discovery (real UDP broadcast on port 10001 -- works genuinely in
# this Docker bridge network as of the announce.lua socket-creation-order fix):
lua announce.lua &

# Start the inform loop (foreground, so you can watch it live)
lua inform.lua
```

The device appears in the controller UI as a new **Access Point** entry (distinct
from any L3-only "Gateway" entry) with **Click to Adopt**. Click it — for an
L2-discovered device the controller genuinely SSHes in this time. It tries the real
Ubiquiti factory-default account, `ubnt`/`ubnt` (not the **Device SSH
Authentication** credentials from step 3 — those only apply once a device is
already adopted and reports itself as non-default), which is why the image bakes in
a `ubnt` user (UID 0) with that exact password. If adoption still fails, check
`docker exec openuf-validation-controller tail -f /config/logs/server.log` for the
`SSH adopt failed ip[...],msg[...]` line — `msg[unreachable]` with a
`HostKeyAlgorithms` complaint means the ssh-rsa fix isn't active; `msg[loginfail]`
means a credentials mismatch.

Once SSH adopt succeeds, `syswrapper.sh set-adopt` runs for real on the AP
container and writes `/etc/openuf/state.json` with a controller-issued `authkey`.
**No restart needed** — `inform.lua` reloads `state.json` on its own if the
file's mtime changes between loop iterations (`M._reload_if_changed`, checked
at the top of every ~10s cycle), so an already-running process picks up a
fresh SSH-driven adoption within one cycle. (This note used to say the
opposite — that was accurate before that reload logic was added, but got left
stale afterward. Re-verified 2026-07-12: reset an already-running, already-
adopted process's state via `reset-inform`, then re-ran `set-adopt` directly
without touching the process, and it resumed informing successfully on its
own — the only delay was the exponential backoff from the intervening failed
attempts, not a missed reload.)

## 5. Work through the validation matrix

For each row in [PROTOCOL-VALIDATION.md](../../PROTOCOL-VALIDATION.md), trigger the
scenario from the controller UI, then tail the capture file in another shell:

```sh
docker exec openuf-validation-ap tail -f /var/log/openuf-informs.log
```

Copy the relevant raw JSON into the corresponding section of
`PROTOCOL-VALIDATION.md`, diff it against the current code's assumptions, and note
the verdict (confirmed / corrected). Any field-name corrections get their own commit
in the main codebase, per the project's usual per-finding commit cadence.

**Note:** the device currently never settles out of "Adopting" in the UI, even
though `server.log` shows a completed adopt and a continuous stream of successful,
decrypted informs (confirmed via `tcpdump` and `debug_dump_file`) — see the "Open
item" at the end of PROTOCOL-VALIDATION.md's L2 section. This doesn't block
capturing responses via `debug_dump_file` for the matrix above, since the
controller keeps actively pushing `setparam` every cycle regardless.

## 6. Tear down / reset

```sh
# Full reset (fresh controller + fresh AP state -- remember to redo step 3,
# Inform Host Override, after this since it lives in the wiped database):
docker compose -f tools/validation/docker-compose.yml down -v

# Just re-adopt with a clean AP state, keep the controller/site config
# (Inform Host Override survives this since it doesn't touch unifi-db):
docker compose -f tools/validation/docker-compose.yml restart ap
docker exec openuf-validation-ap sh -c "syswrapper.sh reset-inform && rm -f /var/log/openuf-informs.log"
```
