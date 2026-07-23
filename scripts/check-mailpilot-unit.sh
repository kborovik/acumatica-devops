#!/usr/bin/env bash
# Offline probe for mailpilot unit policy + migrate-before-restart (SPEC V7,V8,V10).
# Static check — no guest required. Lab manual steps: see docs/mailpilot.md
# "systemd unit restart policy".
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
unit="$root/ansible/roles/mailpilot_crm/templates/mailpilot.service.j2"
tasks="$root/ansible/roles/mailpilot_crm/tasks/main.yml"
fail=0

ok()  { printf 'OK  %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; fail=1; }

[[ -f "$unit" ]]  || { bad "missing $unit"; exit 1; }
[[ -f "$tasks" ]] || { bad "missing $tasks"; exit 1; }

# --- unit template: start-rate limit (V7) ---
unit_block="$(awk '/\[Unit\]/,/\[Service\]/' "$unit")"
if grep -qE '^StartLimitIntervalSec=[0-9]+' <<<"$unit_block"; then
  ok "StartLimitIntervalSec in [Unit]"
else
  bad "StartLimitIntervalSec missing from [Unit] (schema-gate would crash-loop)"
fi
if grep -qE '^StartLimitBurst=[0-9]+' <<<"$unit_block"; then
  ok "StartLimitBurst in [Unit]"
else
  bad "StartLimitBurst missing from [Unit]"
fi
if grep -qE '^Restart=on-failure' "$unit"; then
  ok "Restart=on-failure present"
else
  bad "Restart=on-failure missing"
fi
# Burst must be finite and small enough to leave failed state quickly
burst="$(grep -E '^StartLimitBurst=' "$unit" | head -1 | cut -d= -f2)"
if [[ -n "${burst:-}" && "$burst" -ge 1 && "$burst" -le 10 ]]; then
  ok "StartLimitBurst=$burst (1..10)"
else
  bad "StartLimitBurst out of expected range: ${burst:-empty}"
fi

# --- deploy tasks: migrate before unit (V8) ---
python3 - "$tasks" <<'PY' || fail=1
import sys
from pathlib import Path
text = Path(sys.argv[1]).read_text()
need = [
    "mailpilot db init",
    "mailpilot db migrate",
    "mailpilot db check",
    "mailpilot.service.j2",
]
pos = []
for n in need:
    i = text.find(n)
    if i < 0:
        print(f"FAIL missing task text: {n}")
        sys.exit(1)
    pos.append(i)
if not (pos[0] < pos[1] < pos[2] < pos[3]):
    print("FAIL order: need db init → migrate → check before unit template")
    sys.exit(1)
print("OK  task order: db init → migrate → check before unit template")
if "already_initialized" not in text:
    print("FAIL init must tolerate already_initialized on upgrade")
    sys.exit(1)
print("OK  init tolerates already_initialized")
PY

# --- docs mention policy (V9) ---
docs="$root/docs/mailpilot.md"
if grep -q 'StartLimitBurst' "$docs" && grep -q 'systemd unit restart policy' "$docs"; then
  ok "docs/mailpilot.md documents unit restart policy"
else
  bad "docs/mailpilot.md missing unit restart policy section"
fi

if [[ "$fail" -ne 0 ]]; then
  echo "mailpilot unit check FAILED"
  exit 1
fi
echo "mailpilot unit check PASSED (static; lab: start unit on pending-schema DB → expect failed not green loop)"
