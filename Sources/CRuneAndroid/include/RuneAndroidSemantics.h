#ifndef RUNE_ANDROID_SEMANTICS_H
#define RUNE_ANDROID_SEMANTICS_H
#include <stdint.h>

typedef struct RuneAndroidSemantics RuneAndroidSemantics;
typedef int32_t (*RuneAndroidSemanticAction)(void *context, const char *operation,
    int32_t node, const uint8_t *json, int32_t length);

// All calls are made on the NativeActivity main looper.
RuneAndroidSemantics *rune_android_semantics_open(void *activity, void *context, RuneAndroidSemanticAction action);
void rune_android_semantics_close(RuneAndroidSemantics *bridge);
int32_t rune_android_semantics_reader(RuneAndroidSemantics *bridge);
void rune_android_semantics_publish(RuneAndroidSemantics *bridge, int32_t tree, const uint8_t *json, int32_t length);
#endif
