# Protocol validation findings

openUF's assumptions about controller-pushed inform payloads (`vap_table`,
`network_table`, `radio_table`, the `cmd`/`setparam`/`upgrade`/`setdefault` response
shapes) were originally inferred from third-party reference material —
[amd989/unifi-gateway](https://github.com/amd989/unifi-gateway) and
[paultyng/go-unifi](https://github.com/paultyng/go-unifi) — never checked against a
real UniFi Network Application. This document is the project's own ground truth,
captured by running openUF against a real self-hosted controller and dumping raw
decrypted inform responses via the `debug_dump_file` opt-in flag (see
[USAGE.md](USAGE.md#3-configuration)).

Where this document and the third-party references disagree, this document wins.

**Environment used:** `linuxserver/unifi-network-application` (Docker), version
`_TBD_`, with openUF running as the AP inside a disposable Alpine Linux container on
the same Docker network (see `tools/validation/`).

**Status:** in progress — Stage 1 of the controller→AP validation plan. Each row
below gets filled in as its scenario is captured and diffed against the current code.

---

## 1. Initial adopt handshake

- **Status:** ⬜ not yet captured
- **Compare against:** `mgmt_cfg` key=value string format, `set-adopt` invocation
  shape (`openuf/hook/syswrapper.lua`)
- **Findings:**
- **Code changes:**

## 2. Baseline post-adopt inform response

- **Status:** ⬜ not yet captured
- **Compare against:** top-level `_type` field name/values (`noop`/`config`/`cmd`)
  (`openuf/inform.lua:388-490`)
- **Findings:**
- **Code changes:**

## 3. Default SSID push (no VLAN)

- **Status:** ⬜ not yet captured
- **Compare against:** `vap_table` field names (`openuf/ucihelper.lua` `apply_config()`)
- **Findings:**
- **Code changes:**

## 4. VLAN-tagged network + SSID assignment

- **Status:** ⬜ not yet captured
- **Compare against:** `network_table`/`networkconf_id` join shape
  (`openuf/ucihelper.lua`)
- **Findings:**
- **Code changes:**

## 5. Fast Roaming / WPA3 fast roaming toggle

- **Status:** ⬜ not yet captured
- **Compare against:** presence/absence and real field name of
  `mobility_domain`/`r0kh`/`r1kh`/`fast_roaming_enabled`
  (`openuf/ucihelper.lua` `derive_mobility_domain` stopgap)
- **Findings:**
- **Code changes:**

## 6. TX power (Low/Medium/High/Custom) per radio

- **Status:** ⬜ not yet captured
- **Compare against:** `radio_table` field name/value shape
  (`openuf/ucihelper.lua` `rf_config()`)
- **Findings:**
- **Code changes:**

## 7. Locate trigger

- **Status:** ⬜ not yet captured
- **Compare against:** exact `cmd` string(s) (`openuf/inform.lua:455-460`)
- **Findings:**
- **Code changes:**

## 8. RF/spectrum scan trigger (trigger only)

- **Status:** ⬜ not yet captured
- **Compare against:** exact `cmd` string for the scan trigger
  (`openuf/inform.lua:461-478`)
- **Note:** result-reporting (AP→controller direction) is out of scope for this
  stage — see Stage 2.
- **Findings:**
- **Code changes:**

## 9. Firmware upgrade offer

- **Status:** ⬜ not yet captured
- **Compare against:** `_type:"upgrade"` shape, `version`/`url` field names
  (`openuf/inform.lua:438-448`)
- **Findings:**
- **Code changes:**

## 10. Forget device / factory reset

- **Status:** ⬜ not yet captured
- **Compare against:** `_type:"setdefault"` shape (`openuf/inform.lua:423-430`)
- **Findings:**
- **Code changes:**

## 11. fw.ver acceptance (passive)

- **Status:** ⬜ not yet captured
- **Compare against:** does the current `openuf/ufmodel/u6iw.lua` `fw.ver` get
  accepted by the real controller, or rejected?
- **Findings:**
- **Code changes:**

---

## Stage 2 (future, not started)

Static extraction of a real AP firmware image (`binwalk` + `strings`/Ghidra) to
determine the AP→controller spectrum-scan-result reporting shape — the one item
Stage 1's controller-only setup can't resolve, since it requires observing what a
genuine AP sends up, not what the controller pushes down.
