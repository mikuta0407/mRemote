#ifndef MREMOTE_SSH_FORWARD_H
#define MREMOTE_SSH_FORWARD_H

/*
 * Local port forwarding (`ssh -L`) for the run thread of one session: a
 * listener on 127.0.0.1 per forward, and per accepted connection a
 * direct-tcpip channel, pumped both ways without blocking. Everything here
 * runs on the run thread, in its poll loop; nothing is thread-safe.
 */

#include <poll.h>
#include <stddef.h>
#include <stdint.h>

#include <libssh2.h>

#include "mremote/ssh_bridge.h"

typedef struct mr_forwarder mr_forwarder;

/* Copies the specs. Opens the listeners; for each, report(context, index,
 * errno) says whether it listens (0) or why not. While congested(context)
 * says so, the session's send queue is full and no data is sent. Returns
 * NULL only when out of memory. */
mr_forwarder *mr_forwarder_create(
    LIBSSH2_SESSION *ssh, const mr_ssh_forward *forwards, size_t count,
    void (*report)(void *context, size_t index, int32_t error),
    int (*congested)(void *context), void *context);

/* The descriptors to poll, appended at fds; returns how many (at most
 * mr_forwarder_max_fds). */
size_t mr_forwarder_fill_pollfds(mr_forwarder *forwarder, struct pollfd *fds);
size_t mr_forwarder_max_fds(const mr_forwarder *forwarder);

/* Accepts, opens channels and moves data as far as it can without blocking.
 * Returns 1 when anything moved (call again before polling), 0 when idle,
 * or a negative libssh2 error that ends the whole session. */
int mr_forwarder_step(mr_forwarder *forwarder);

/* How long the poll may wait before mr_forwarder_step must run again, even
 * with nothing ready (a closing tunnel's deadline), in ms; -1 for no limit. */
int mr_forwarder_timeout_ms(const mr_forwarder *forwarder);

/* Channels still open are left to libssh2_session_free. */
void mr_forwarder_destroy(mr_forwarder *forwarder);

#endif
