#ifndef C_RUNE_TEST_SOCKETS_H
#define C_RUNE_TEST_SOCKETS_H

#include <stdint.h>
#include <stddef.h>

/* A loopback-only TCP listener on an ephemeral port. Invalid handles are -1. */
intptr_t rune_test_socket_listen(uint16_t *port, int *error);
intptr_t rune_test_socket_accept(intptr_t listener);
int rune_test_socket_read(intptr_t client, void *bytes, size_t count);
int rune_test_socket_write(intptr_t client, const void *bytes, size_t count);
void rune_test_socket_close(intptr_t handle);

#endif
