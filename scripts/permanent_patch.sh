#!/usr/bin/env sh
# permanent_patch.sh — run INSIDE the iDRAC root shell
#
# Permanently patches /dev/mmcblk0p9 (the squashfs partition that iDRAC
# reads platcfgfld.txt from at boot). After this, the V100-SXM2-32GB is
# recognized after every iDRAC reboot — no re-exploit needed.
#
# PREREQUISITES:
#   - writecfg_patch.sh already applied (volatile fix active)
#   - iDRAC root shell via idrac_shell_setup.sh
#
# WHAT THIS DOES:
#   1. Mounts /dev/mmcblk0p9 (squashfs, read-only)
#   2. Copies platcfgfld.txt to /tmp (writable)
#   3. Patches the V100-SXM2-16GB entry to V100-SXM2-32GB PCI IDs
#   4. Rebuilds the squashfs
#   5. Writes it back to /dev/mmcblk0p9
#
# RISK: Writing to /dev/mmcblk0p9 is destructive. A bad write bricks
# the iDRAC (requires JTAG or board-level recovery). The original is
# preserved in /tmp/mmcblk0p9_orig.bin — but /tmp is volatile on iDRAC.
# Dump it to the host first if you want a real backup.
#
# iDRAC8 squashfs details:
#   Device:     /dev/mmcblk0p9
#   Mount point: /flash/pd0  (read-only squashfs)
#   Target file: /flash/pd0/ipmi/Trailbreaker/platcfgfld.txt
#   Compression: check with 'file /tmp/orig.sqfs' after copy

set -e

SQ_DEV="/dev/mmcblk0p9"
MNT="/tmp/sq_mnt"
WORK="/tmp/sq_work"
ORIG_BIN="/tmp/mmcblk0p9_orig.bin"
NEW_SQ="/tmp/new.sqfs"
PLATCFG_REL="ipmi/Trailbreaker/platcfgfld.txt"

echo "=== Step 1: Backup original partition ==="
dd if="${SQ_DEV}" of="${ORIG_BIN}" bs=4096
ORIG_SIZE=$(wc -c < "${ORIG_BIN}")
echo "Backup: ${ORIG_BIN} (${ORIG_SIZE} bytes)"
echo ""
echo "IMPORTANT: Copy this backup to the host NOW before continuing:"
echo "  (From host): sshpass -p <PASSWORD> scp -o PreferredAuthentications=password \\"
echo "    root@192.168.1.100:/tmp/mmcblk0p9_orig.bin ~/mmcblk0p9_orig.bin"
echo ""
echo "Press enter when backup is safe on the host, or Ctrl-C to abort..."
read -r _

echo "=== Step 2: Mount squashfs ==="
mkdir -p "${MNT}" "${WORK}"
mount -t squashfs "${SQ_DEV}" "${MNT}"
echo "Mounted ${SQ_DEV} at ${MNT}"

echo "=== Step 3: Copy filesystem to writable work area ==="
cp -a "${MNT}/." "${WORK}/"
umount "${MNT}"

echo "=== Step 4: Show current V100 entries in platcfgfld.txt ==="
grep -n "b3 1d\|ba 1d\|b5 1d\|1db5\|1db3\|1dba" "${WORK}/${PLATCFG_REL}" || true
echo ""

echo "=== Step 5: Patch — replace 16GB entry (ba 1d / 1a 12) with 32GB (b5 1d / 49 12) ==="
# The 16GB V100-SXM2-16GB has DID=0x1DB1/0x1DBA and SDID=0x1212/0x121A
# We replace the 0x1DBA/0x121A variant (slot 92) with the 32GB IDs
# Original line (16GB alt entry):
#   5 5 de 10 ba 1d de 10 1a 12 b8 b b8 b 1 ff 48
# New line (32GB):
#   5 5 de 10 b5 1d de 10 49 12 b8 b b8 b 1 ff 48

sed -i 's/5 5 de 10 ba 1d de 10 1a 12 b8 b b8 b 1 ff 48/5 5 de 10 b5 1d de 10 49 12 b8 b b8 b 1 ff 48/' \
    "${WORK}/${PLATCFG_REL}"

echo "Verify patch:"
grep -n "b5 1d\|49 12\|ba 1d\|1a 12" "${WORK}/${PLATCFG_REL}" || true
echo ""

echo "=== Step 6: Rebuild squashfs ==="
if command -v mksquashfs >/dev/null 2>&1; then
    mksquashfs "${WORK}" "${NEW_SQ}" -noappend -comp xz
else
    echo "ERROR: mksquashfs not found on iDRAC."
    echo "Fallback: unsquash on host, patch there, resquash, copy back."
    echo "See README.md section on host-side squashfs patching."
    exit 1
fi

NEW_SIZE=$(wc -c < "${NEW_SQ}")
echo "New squashfs: ${NEW_SQ} (${NEW_SIZE} bytes)"
echo ""

if [ "${NEW_SIZE}" -gt "${ORIG_SIZE}" ]; then
    echo "ERROR: New squashfs (${NEW_SIZE}) is larger than original (${ORIG_SIZE})!"
    echo "This would overflow the partition. Aborting."
    exit 1
fi

echo "=== Step 7: Write back to /dev/mmcblk0p9 ==="
echo "THIS IS THE DESTRUCTIVE STEP. Last chance to abort (Ctrl-C)..."
read -r _
dd if="${NEW_SQ}" of="${SQ_DEV}" bs=4096
sync
echo ""
echo "Done. Partition written."
echo ""
echo "=== Step 8: Verify by re-mounting and checking the file ==="
mount -t squashfs "${SQ_DEV}" "${MNT}"
grep "b5 1d" "${MNT}/${PLATCFG_REL}" && echo "PATCH CONFIRMED in squashfs" || echo "WARNING: patch not found"
umount "${MNT}"
echo ""
echo "The patch is now permanent."
echo "Test: reboot the iDRAC only (not the server) and verify nvidia-smi shows Not Active."
echo ""
echo "To reboot iDRAC only (from host):"
echo "  curl -k -s -u 'root:<PASSWORD>' \\"
echo "    -X POST https://192.168.1.100/redfish/v1/Managers/iDRAC.Embedded.1/Actions/Manager.Reset \\"
echo "    -H 'Content-Type: application/json' -d '{\"ResetType\":\"GracefulRestart\"}'"
