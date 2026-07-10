# Live controller validation environment

Disposable Docker environment for validating openUF's controller-pushed payload
assumptions against a real UniFi Network Application controller — see
[PROTOCOL-VALIDATION.md](../../PROTOCOL-VALIDATION.md) for the findings this
produces and [USAGE.md](../../USAGE.md#3-configuration) for the `debug_dump_file`
flag used to capture responses.

No target OpenWrt hardware or real Ubiquiti device needed — the controller is a
plain Docker container, and the "AP" is a disposable Alpine container reachable via
SSH. For L2 (broadcast) adoption, the controller's real adopt flow (SSH in, run
`syswrapper.sh set-adopt`) completes exactly as it would against genuine hardware.
L3 adoption currently does not complete — see PROTOCOL-VALIDATION.md.

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

- Check **Inform Host Override**, set the value to `controller` (this stack's
  Docker Compose service name — what the AP container resolves to reach the
  controller).
- Check **Device SSH Authentication**, username `root`, password matching the AP
  container's real sshd password (`openuf` by default per `ap/Dockerfile` — the
  controller's own password-strength validator requires ≥10 chars + uppercase +
  symbol, so if you change it here, `docker exec openuf-validation-ap sh -c "echo
  'root:<newpassword>' | chpasswd"` to match on the AP side too).
- Apply Changes.

**Note:** as of 2026-07-10, configuring this did *not* resolve the L3-adoption
deadlock documented in PROTOCOL-VALIDATION.md — the same `invalid inform_ip
controller` line still appears even with the override correctly set from a clean
first contact. Still worth doing, since it's a genuine, independently-documented
Docker requirement (see linuxserver.io docs) and rules out one variable — just
don't expect it alone to unblock adoption.

## 4. Start openUF inside the AP container

`debug_dump_file` and the `eth0` interface override are already baked into the
image (`ap/Dockerfile`) — no manual `sed` step needed.

```sh
docker exec -it openuf-validation-ap sh
cd /opt/openuf

# Point at the controller (L3 adoption -- different docker networks/subnets
# than a real LAN, so use set-inform rather than relying on L2 discovery):
syswrapper.sh set-inform http://controller:8080/inform

# Start the inform loop (foreground, so you can watch it live)
lua inform.lua
```

In the controller UI, the device should appear under **Devices** as **Pending**.
Click **Adopt** — for an L3-discovered device the controller currently does *not*
SSH in (`discovered via L3 inform, skip SSH adoption` in `server.log`), and
adoption does not complete — see PROTOCOL-VALIDATION.md for the current state of
that investigation. The SSH credentials above are still relevant for testing L2
(broadcast) adoption, which does use them.

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
