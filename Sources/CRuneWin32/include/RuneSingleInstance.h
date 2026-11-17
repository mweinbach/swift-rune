#ifndef RUNE_SINGLE_INSTANCE_H
#define RUNE_SINGLE_INSTANCE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Utf8 argument bytes are borrowed for the duration of receive, on the instance thread.
typedef int32_t (*RuneInstanceQuitting)(void);
typedef void (*RuneInstanceReceive)(const uint8_t *body, uint32_t length);
int32_t rune_win_instance_claim(const uint16_t *id, size_t id_length, const uint8_t *message, uint32_t length,
                                uint32_t handed_pid, RuneInstanceQuitting quitting, RuneInstanceReceive receive);
void rune_win_instance_release(void);
int32_t rune_win_instance_process_alive(uint32_t pid);
void rune_win_instance_raise_front(void);

#ifdef __cplusplus
}
#endif
#endif
