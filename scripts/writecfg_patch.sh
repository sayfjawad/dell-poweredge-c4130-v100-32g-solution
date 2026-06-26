#!/usr/bin/env sh
# writecfg_patch.sh — run INSIDE the iDRAC root shell (after idrac_shell_setup.sh)
#
# Patches the iDRAC GPGPU power table (group 20033) to add the
# V100-SXM2-32GB entry. This tells iDRAC to stop asserting PWR_BRAKE_N.
#
# VOLATILE: survives server on/off cycles but NOT iDRAC reboot.
# For permanent fix: run permanent_patch.sh immediately after this.
#
# Run with the SERVER POWERED OFF (iDRAC running, host OS off).
# Then power the server ON. Do NOT reboot iDRAC.
#
# PCI IDs being patched in:
#   VID  = 0x10DE  (NVIDIA)
#   DID  = 0x1DB5  (V100-SXM2-32GB)
#   SVID = 0x10DE
#   SDID = 0x1249
#
# Power values:
#   PeakPwr      = 0x0BB8 = 3000 (units: 100mW → 300W)
#   ThrottledPwr = 0x0BB8 = 3000

echo "=== Current GPGPU power table entries (group 20033) ==="
readcfg -g20033
echo ""

echo "=== Writing V100-SXM2-32GB entry into slot 92 (index 90) ==="
writecfg -r'@@20033:90:1' -v'05 05 DE 10 B5 1D DE 10 49 12 B8 0B B8 0B 01 FF 48'
echo ""

echo "=== Verify — should now show DID=b5 in GPGPU_92_1 ==="
readcfg -g20033 | grep -A1 -B1 "b5 1d"
echo ""

echo "Done. Now power on the server OS from the host:"
echo "  curl -k -s -u 'root:<PASSWORD>' \\"
echo "    -X POST https://192.168.1.100/redfish/v1/Systems/System.Embedded.1/Actions/ComputerSystem.Reset \\"
echo "    -H 'Content-Type: application/json' -d '{\"ResetType\":\"On\"}' -w '\\nHTTP %{http_code}'"
echo ""
echo "After boot, run scripts/verify_host.sh on the host to confirm fix."
echo ""
echo "IMPORTANT: Run permanent_patch.sh NOW before any iDRAC reboot!"
