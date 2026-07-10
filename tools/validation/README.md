# Live controller validation environment

Disposable Docker environment for validating openUF's controller-pushed payload
assumptions against a real UniFi Network Application controller — see
[PROTOCOL-VALIDATION.md](../../PROTOCOL-VALIDATION.md) for the findings this
produces and [USAGE.md](../../USAGE.md#3-configuration) for the `debug_dump_file`
flag used to capture responses.

No target OpenWrt hardware or real Ubiquiti device needed — the controller is a
plain Docker container, and the "AP" is a disposable Alpine container reachable via
SSH, so the controller's real adopt flow (SSH in, run `syswrapper.sh set-adopt`)
completes exactly as it would against genuine hardware.

## 1. Start the environment

```sh
# from the repo root
docker compose -f tools/validation/docker-compose.yml up -d --build
```

First boot of `unifi-db` takes a few seconds to run `init-mongo.sh`; give it a
moment before the controller container comes up healthy.

## 2. Complete the controller's first-run setup

Open `https://localhost:8443` (self-signed cert — accept the browser warning) and
step through the setup wizard: create a local admin account, skip cloud
login/remote access if offered, name the site whatever you like.

## 3. Start openUF inside the AP container

```sh
docker exec -it openuf-validation-ap sh
cd /opt/openuf

# Enable the raw-response capture (see openuf/conf.lua) before starting:
sed -i 's/debug_dump_file = nil/debug_dump_file = "\/var\/log\/openuf-informs.log"/' conf.lua

# Point at the controller (L3 adoption -- different docker networks/subnets
# than a real LAN, so use set-inform rather than relying on L2 discovery):
syswrapper.sh set-inform http://controller:8080/inform

# Start the inform loop (foreground, so you can watch it live)
lua inform.lua
```

In the controller UI, the device should appear under **Devices** as **Pending**.
Click **Adopt** — the controller SSHes into `openuf-validation-ap` (root / `openuf`,
set in `ap/Dockerfile`) and runs `syswrapper.sh set-adopt`, completing the handshake
for real.

## 4. Work through the validation matrix

For each row in [PROTOCOL-VALIDATION.md](../../PROTOCOL-VALIDATION.md), trigger the
scenario from the controller UI, then tail the capture file in another shell:

```sh
docker exec openuf-validation-ap tail -f /var/log/openuf-informs.log
```

Copy the relevant raw JSON into the corresponding section of
`PROTOCOL-VALIDATION.md`, diff it against the current code's assumptions, and note
the verdict (confirmed / corrected). Any field-name corrections get their own commit
in the main codebase, per the project's usual per-finding commit cadence.

## 5. Tear down / reset

```sh
# Full reset (fresh controller + fresh AP state):
docker compose -f tools/validation/docker-compose.yml down -v

# Just re-adopt with a clean AP state, keep the controller/site config:
docker compose -f tools/validation/docker-compose.yml restart ap
docker exec openuf-validation-ap sh -c "syswrapper.sh reset-inform && rm -f /var/log/openuf-informs.log"
```
