/*
 * Minimal crashpad handler stub for NixOS.
 *
 * The original chrome_crashpad_handler shipped with WPS/xiezuo crashes on NixOS
 * because it cannot parse ELF headers modified by autoPatchelfHook (the
 * DT_RUNPATH entries confuse crashpad's ELF reader).  This stub replaces it
 * with a tiny program that performs the required IPC handshake so the main
 * Electron process can proceed, then sits idle until the parent exits.
 *
 * Protocol (observed via strace on the original handler):
 *   1. Chromium passes --initial-client-fd=N (a SEQPACKET unix socket).
 *   2. Handler recvmsg()s a 40-byte registration with SCM_CREDENTIALS.
 *   3. Handler sendmsg()s back 8 zero bytes — this unblocks the client.
 *   4. Handler drains any further registration messages.
 *   5. Handler stays alive (pause) until killed by the parent.
 */
#define _GNU_SOURCE
#include <sys/socket.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <signal.h>

#define PREFIX "--initial-client-fd="
#define PREFIX_LEN 20  /* strlen("--initial-client-fd=") */

int main(int argc, char *argv[]) {
    int client_fd = -1;

    /* Parse --initial-client-fd=N from the command line */
    for (int i = 1; i < argc; i++) {
        if (strncmp(argv[i], PREFIX, PREFIX_LEN) == 0) {
            client_fd = atoi(argv[i] + PREFIX_LEN);
            break;
        }
    }

    if (client_fd < 0) {
        /* No client fd — nothing to handshake, just stay alive */
        pause();
        return 0;
    }

    signal(SIGPIPE, SIG_IGN);

    /* Step 1: read the initial registration message */
    char buf[512];
    struct iovec iov = { .iov_base = buf, .iov_len = sizeof(buf) };
    char cmsg_buf[256];
    struct msghdr msg;
    memset(&msg, 0, sizeof(msg));
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    msg.msg_control = cmsg_buf;
    msg.msg_controllen = sizeof(cmsg_buf);

    ssize_t n = recvmsg(client_fd, &msg, 0);
    if (n <= 0) {
        pause();
        return 0;
    }

    /* Step 2: send back 8 zero bytes — the handshake response */
    char response[8];
    memset(response, 0, sizeof(response));
    struct iovec resp_iov = { .iov_base = response, .iov_len = sizeof(response) };
    struct msghdr resp_msg;
    memset(&resp_msg, 0, sizeof(resp_msg));
    resp_msg.msg_iov = &resp_iov;
    resp_msg.msg_iovlen = 1;
    sendmsg(client_fd, &resp_msg, MSG_NOSIGNAL);

    /* Step 3: drain any remaining registration messages */
    for (;;) {
        iov.iov_base = buf;
        iov.iov_len = sizeof(buf);
        memset(&msg, 0, sizeof(msg));
        msg.msg_iov = &iov;
        msg.msg_iovlen = 1;
        msg.msg_control = cmsg_buf;
        msg.msg_controllen = sizeof(cmsg_buf);
        n = recvmsg(client_fd, &msg, 0);
        if (n <= 0) break;
    }

    close(client_fd);

    /* Stay alive until the parent kills us */
    pause();
    return 0;
}
