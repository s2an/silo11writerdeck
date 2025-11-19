#!/usr/bin/env bash
# silo11writerdeck: Bluetooth Auto-Pair, Trust & Connect launcher (oneshot)
# - Starts the Python agent in background
# - Briefly opens a scan/pairing window
# - Leaves the agent running; unit stays "active" via RemainAfterExit=true

set -euo pipefail

# --- Config -------------------------------------------------------------------
LOGFILE="${LOGFILE:-/tmp/bt-autopair-trust-connect.log}"
AGENT="${AGENT:-/usr/local/bin/bt_autopair_trust_connect_agent.py}"
# Allow a mock bluetoothctl for testing (export MOCK_BTCTL=/path/to/mock)
BLUETOOTHCTL_CMD="${MOCK_BTCTL:-bluetoothctl}"

# Agent flags (tweak via environment if needed)
#   AGENT_FLAGS="--wait-retries 12 --wait-delay 1.0"
AGENT_FLAGS=${AGENT_FLAGS:-}

# Pairing/scan window (seconds)
PAIR_WINDOW="${PAIR_WINDOW:-10}"

# Whether to disable discoverability/pairability/scan here after the window.
# (The agent will also turn them off after a successful connect unless
#  started with --no-post-connect-knobs.)
CLOSE_KNOBS="${CLOSE_KNOBS:-1}"  # 1=yes, 0=no

# --- Helpers ------------------------------------------------------------------
bt() {
  # shellcheck disable=SC2068
  ${BLUETOOTHCTL_CMD} $@
}

say()  { printf "[%(%Y-%m-%d %H:%M:%S)T] %s\n" -1 "$*"; }
fail() { say "ERROR: $*"; exit 1; }

# --- Start log ----------------------------------------------------------------
: > "$LOGFILE" || true
chmod 666 "$LOGFILE" 2>/dev/null || true

{
say "=== silo11writerdeck: bt-autopair-trust-connect start ==="
say "LOGFILE=$LOGFILE"
say "AGENT=$AGENT"
say "BLUETOOTHCTL=$(command -v ${BLUETOOTHCTL_CMD} || echo 'not found')"
say "AGENT_FLAGS=${AGENT_FLAGS:-<none>}"
say "PAIR_WINDOW=${PAIR_WINDOW}s  CLOSE_KNOBS=${CLOSE_KNOBS}"

# --- Preconditions ------------------------------------------------------------
command -v python3 >/dev/null || fail "python3 not found in PATH"
command -v ${BLUETOOTHCTL_CMD} >/dev/null || fail "bluetoothctl not found"

# --- Clean up any prior agent -------------------------------------------------
if pgrep -f "$AGENT" >/dev/null 2>&1; then
  say "Existing agent found; terminating…"
  pkill -f "$AGENT" || true
  sleep 1
fi

# --- Launch agent (background) ------------------------------------------------
# Notes:
# - Agent will: wait for adapter, register NoInputNoOutput, auto-confirm,
#   trust+connect, and (by default) turn knobs off after successful connect.
# - You can pass --no-post-connect-knobs via AGENT_FLAGS to change that.
say "Starting Python agent…"
nohup python3 "$AGENT" $AGENT_FLAGS >>"$LOGFILE" 2>&1 &
AGENT_PID=$!
say "Agent PID=$AGENT_PID"

# Small grace period for DBus registration
sleep 2

# --- Register default agent at bluetoothctl side ------------------------------
say "Registering default agent with bluetoothctl…"
registered=0
for i in 1 2 3 4 5; do
  if bt <<'EOF' | grep -q "Agent registered"
agent NoInputNoOutput
default-agent
EOF
  then
    say "✔ Agent registered with bluetoothctl"
    registered=1
    break
  else
    say "…not yet, retrying ($i/5)"
    sleep 1
  fi
done
[[ $registered -eq 1 ]] || say "Proceeding even though bluetoothctl didn’t confirm registration"

# --- Open pairing window ------------------------------------------------------
say "Enabling discovery for ${PAIR_WINDOW}s…"
bt <<'EOF' || true
power on
discoverable on
pairable on
scan on
EOF

sleep "$PAIR_WINDOW"

if [[ "$CLOSE_KNOBS" == "1" ]]; then
  say "Closing discovery window…"
  bt <<'EOF' || true
scan off
discoverable off
pairable off
EOF
else
  say "Leaving discovery window open (CLOSE_KNOBS=0)"
fi

# --- Show quick paired snapshot ----------------------------------------------
say "--- Paired devices snapshot ---"
bt paired-devices || true

say "Launcher done; agent continues in background."
say "=== silo11writerdeck: bt-autopair-trust-connect end ==="

} >>"$LOGFILE" 2>&1

# oneshot service returns here; agent keeps running under systemd supervision
exit 0
