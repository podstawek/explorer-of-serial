#!/usr/bin/env bash
# netcheck.sh — prove this process can reach ONLY what jail_allow says.
#
#   ./scripts/netcheck.sh [expected.json] [COARSE=1]
#
# Reads the SAME jail_allow from the project config. Verifies per endpoint:
#   services:  must connect (HTTP code within probe_timeout)
#   targets:   must connect (port open)
#   internet:  must NOT establish any connection (any TCP connection = FAIL;
#              HTTP code means connection worked = FAIL; DNS resolution = FAIL)
# Exit 0 = environment matches expectations. 3 = mismatch (preflight must abort).
# COARSE — skip services/targets expectations (they were bypassed with
# EXPLORER_ALLOW_COARSE_LAN); still requires NO internet.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR"
EXPECTED_FILE="${1:-scripts/tests/netcheck.expected.json}"
export COARSE="${COARSE:-0}"

[[ "$COARSE" == "1" ]] || [[ -f "$EXPECTED_FILE" ]] || { echo "netcheck: expected file missing: $EXPECTED_FILE" >&2; exit 2; }
command -v python3 >/dev/null || { echo "netcheck: needs python3" >&2; exit 2; }

CONFIG_FILE="${EXPLORER_CONFIG:-$SCRIPT_DIR/config/explorer.$(id -un).json}"
PYTHON_BIN="${PYTHON_BIN:-python3}"

mapfile -t CHECKS < <("$PYTHON_BIN" "$SCRIPT_DIR/scripts/netcheck-plan.py" "$CONFIG_FILE" "$EXPECTED_FILE")
[[ ${#CHECKS[@]} -gt 0 ]] || { echo "netcheck: no checks produced" >&2; exit 2; }

fail=0
echo "== netcheck $(date -Is) on $(hostname) =="
for line in "${CHECKS[@]}"; do
  IFS='|' read -r kind host port want_http <<< "$line"
  code=000
  for _ in 1 2 3; do
    if [[ "$kind" == "svc" ]]; then
      code="$(curl --noproxy '*' --connect-timeout 4 -m 8 -o /dev/null -sw '%{http_code}' "http://$host:$port/v1/models" 2>/dev/null)" || code=000
    else
      code="$(python3 - "$host" "$port" <<'PY'
import socket, sys
try:
    socket.create_connection((sys.argv[1], int(sys.argv[2])), 4).close()
    print("1")
except OSError:
    print("000")
PY
)" || code=000
    fi
    [[ "$code" != "000" ]] && break
    sleep 1
  done

  if [[ "$kind" == "internet" ]]; then
    if [[ "$code" != "000" ]]; then
      echo "FAIL internet $host:$port — REACHABLE ($code), network is NOT offline"; fail=1
    else
      echo "ok internet $host:$port unreachable as required"
    fi
    continue
  fi

  if [[ "$code" == "000" ]]; then
    if [[ "$COARSE" == "1" ]]; then echo "WARN $kind $host:$port unreachable (allowed: COARSE mode, but is it up?)"
    else echo "FAIL $kind $host:$port unreachable (expect $want_http) — jail is too strict or endpoint down"; fail=1; fi
  elif [[ "$kind" == "svc" && -n "$want_http" && "$code" != "$want_http" ]]; then
    echo "FAIL $kind $host:$port answered $code, expected $want_http"; fail=1
  else
    echo "ok $kind $host:$port (code $code)"
  fi
done

# DNS must be dead for the offline guarantee (unless a local resolver is intended)
if [[ "$COARSE" != "1" ]]; then
  if out="$(getent hosts example.org 2>&1)" && [[ -n "$out" ]]; then
    echo "FAIL dns example.org resolved ($out) — DNS must not work inside the jail"; fail=1
  else
    echo "ok dns unresolvable"
  fi
fi

echo "== netcheck: FAILURES=$fail =="
exit $(( fail ? 3 : 0 ))
