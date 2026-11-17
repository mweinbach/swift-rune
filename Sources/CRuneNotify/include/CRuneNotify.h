#ifndef RUNE_NOTIFY_H
#define RUNE_NOTIFY_H

#include <stdint.h>
#include "RuneNotifyLinuxFocus.h"

#ifdef _WIN32
#include "RuneNotifyWindows.h"
#endif

#ifdef __cplusplus
extern "C" {
#endif

#if defined(__linux__) && !defined(__ANDROID__)
typedef struct RuneNotifyLinux RuneNotifyLinux;
typedef struct RuneNotifyLinuxMessage RuneNotifyLinuxMessage;
enum RuneNotifyLinuxEventKind {
    RUNE_NOTIFY_CLOSED, RUNE_NOTIFY_ACTION, RUNE_NOTIFY_REPLIED,
    RUNE_NOTIFY_SERVER_GONE, RUNE_NOTIFY_ACTIVATION_TOKEN
};
typedef void (*RuneNotifyLinuxEvent)(RuneNotifyLinux *client, int kind, const char *owner, uint32_t number, const char *value);
RuneNotifyLinux *rune_notify_linux_connect(RuneNotifyLinuxEvent event);
void rune_notify_linux_disconnect(RuneNotifyLinux *client);
int rune_notify_linux_connected(RuneNotifyLinux *client);
int rune_notify_linux_available(RuneNotifyLinux *client);
RuneNotifyLinuxMessage *rune_notify_linux_message(const char *name, const char *desktop_entry,
    const char *icon, const char *title, const char *body, uint8_t urgency,
    int silent, const char *sound, const char *category);
void rune_notify_linux_action(RuneNotifyLinuxMessage *message, const char *key,
                              const char *label, const char *reply_placeholder);
uint32_t rune_notify_linux_post(RuneNotifyLinux *client, RuneNotifyLinuxMessage *message,
    const char *prior_owner, uint32_t prior_number, char **posted_owner);
int rune_notify_linux_remove(RuneNotifyLinux *client, const char *owner, uint32_t number);
void rune_notify_linux_message_free(RuneNotifyLinuxMessage *message);
void rune_notify_linux_free_string(char *value);
#endif

#ifdef __cplusplus
}
#endif
#endif
