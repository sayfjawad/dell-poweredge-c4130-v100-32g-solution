#!/usr/bin/env bash
# verify_host.sh — run from the HOST OS to confirm the fix worked
#
# Checks all four V100 GPUs for HW Power Brake state and reports
# current SM clock vs max clock.

set -euo pipefail

echo "=== iDRAC firmware version ==="
curl -k -s -u 'root:<PASSWORD>' \
  https://192.168.1.100/redfish/v1/Managers/iDRAC.Embedded.1 \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print('  Firmware:', d.get('FirmwareVersion','?'))"
echo ""

echo "=== GPU Power Brake state ==="
nvidia-smi -q | grep -E "(Product Name|HW Slowdown|HW Power Brake|SM Clock|Memory Clock)" | \
    sed 's/^[ \t]*/  /'
echo ""

echo "=== Current vs Max SM clocks ==="
nvidia-smi --query-gpu=index,name,clocks.sm,clocks.max.sm,clocks_event_reasons.hw_power_brake_slowdown \
    --format=csv,noheader | column -t -s','
echo ""

echo "=== PSU fans (expect lower RPM if fix is active) ==="
sudo ipmitool sdr type Fan 2>/dev/null | grep "Fan8" | sed 's/^/  /' || echo "  (ipmitool not available)"
