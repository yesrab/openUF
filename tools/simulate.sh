#!/bin/sh
# simulate.sh — local end-to-end adoption simulation (no hardware needed)
#
# Starts the Python test controller on port 8081, runs a single inform
# round-trip in Lua, and verifies the response was decoded successfully.
#
# Usage:
#   sh tools/simulate.sh [--adopt]
#
# Requirements:
#   - python3 with pycryptodome (pip install pycryptodome)
#   - lua with lua-cjson (luarocks install --local lua-cjson)
#   - openssl in PATH
#
# Exit code: 0 = success, 1 = failure

set -e

PORT=8081
ADOPT_FLAG=""
if [ "$1" = "--adopt" ]; then
    ADOPT_FLAG="--adopt"
fi

TMPDIR_SIM=$(mktemp -d)
CONTROLLER_LOG="$TMPDIR_SIM/controller.log"
STATE_FILE="$TMPDIR_SIM/state.json"
RESULT_FILE="$TMPDIR_SIM/result.txt"

cleanup() {
    kill "$CONTROLLER_PID" 2>/dev/null || true
    rm -rf "$TMPDIR_SIM"
}
trap cleanup EXIT INT TERM

echo "=== openUF local simulation ==="
echo ""

# ── Start test controller ─────────────────────────────────────────────────────
echo "Starting test controller on port $PORT ..."
python3 tools/test_controller.py --port "$PORT" $ADOPT_FLAG > "$CONTROLLER_LOG" 2>&1 &
CONTROLLER_PID=$!
sleep 1

if ! kill -0 "$CONTROLLER_PID" 2>/dev/null; then
    echo "FAIL: test controller failed to start"
    cat "$CONTROLLER_LOG"
    exit 1
fi
echo "  controller PID $CONTROLLER_PID"
echo ""

# ── Run a single inform round-trip in Lua ─────────────────────────────────────
echo "Sending inform packet ..."
eval "$(luarocks path --local 2>/dev/null)" || true

lua - "$STATE_FILE" "$PORT" "$RESULT_FILE" << 'LUAEOF'
local state_file, port, result_file = arg[1], tonumber(arg[2]), arg[3]

OPENUF_TEST_MODE = true
dofile("openuf/lib/lib.lua")
local crypto = dofile("openuf/crypto.lua")
local state  = dofile("openuf/state.lua")
local inform = dofile("openuf/inform.lua")

-- Redirect state to temp file
inform._state._state_file = state_file
state._state_file = state_file

-- Use a test MAC
local st = {
    authkey    = state.DEFAULT_KEY,
    adopted    = false,
    cfgversion = "",
    inform_url = "http://127.0.0.1:" .. port .. "/inform",
    mac        = "aa:bb:cc:dd:ee:ff",
    ip         = "127.0.0.1",
    hostname   = "simulate-test",
}

local json_payload = inform.build_json(st, nil, {
    uap = {
        platform = "U6IW",
        model    = "U6IW",
        fw       = {pre="U6IW.", ver="6.6.55", buildtime="230801.1200", factoryver="6.5.28"},
        required_version = "6.0.0",
    }
})

local pkt = inform.build_packet(json_payload, st)

local body, err = inform.http_post(st.inform_url, pkt)
if not body then
    io.stderr:write("http_post failed: " .. tostring(err) .. "\n")
    os.exit(1)
end

local ok, resp_json, flags = pcall(inform.parse_packet, body, st)
if not ok then
    io.stderr:write("parse_packet failed: " .. tostring(resp_json) .. "\n")
    os.exit(1)
end

local ok2, resp = pcall(require("cjson").decode, resp_json)
if not ok2 then
    io.stderr:write("JSON decode failed: " .. tostring(resp) .. "\n")
    os.exit(1)
end

local f = io.open(result_file, "w")
f:write(require("cjson").encode({
    status   = "ok",
    response = resp,
}))
f:close()

io.stdout:write("  inform POST: OK\n")
io.stdout:write("  response type: " .. tostring(resp._type) .. "\n")
LUAEOF

echo ""

# ── Verify result ─────────────────────────────────────────────────────────────
if [ ! -f "$RESULT_FILE" ]; then
    echo "FAIL: no result file produced"
    echo ""
    echo "Controller log:"
    cat "$CONTROLLER_LOG"
    exit 1
fi

RESP_TYPE=$(python3 -c "
import json, sys
d = json.load(open('$RESULT_FILE'))
print(d['response'].get('_type','?'))
")

echo "Controller log:"
cat "$CONTROLLER_LOG"
echo ""

if [ "$RESP_TYPE" = "noop" ] || [ "$RESP_TYPE" = "setparam" ]; then
    echo "=== PASS: round-trip complete, response _type=$RESP_TYPE ==="
    exit 0
else
    echo "FAIL: unexpected response _type=$RESP_TYPE"
    exit 1
fi
