#if defined(__ANDROID__)
#include "RuneAndroidSemantics.h"
#include <android/native_activity.h>
#include <stdlib.h>

struct RuneAndroidSemantics {
    ANativeActivity *activity;
    void *context;
    RuneAndroidSemanticAction action;
    jmethodID attach, publish, reader;
};

static JNIEnv *semantics_env(ANativeActivity *a) {
    if (!a) return NULL;
    if (a->vm) {
        JNIEnv *env = NULL;
        if ((*a->vm)->GetEnv(a->vm, (void **)&env, JNI_VERSION_1_6) == JNI_OK && env)
            return env;
    }
    return a->env;
}

static jboolean on_action(JNIEnv *env, jobject receiver, jlong peer, jstring op, jint node, jbyteArray payload) {
    RuneAndroidSemantics *bridge = (RuneAndroidSemantics *)(intptr_t)peer;
    if (!bridge || !op || !bridge->activity || !(*env)->IsSameObject(env, receiver, bridge->activity->clazz)) return JNI_FALSE;
    const char *name = (*env)->GetStringUTFChars(env, op, NULL);
    if (!name) return JNI_FALSE;
    jsize size = payload ? (*env)->GetArrayLength(env, payload) : 0;
    jbyte *bytes = size > 0 ? (*env)->GetByteArrayElements(env, payload, NULL) : NULL;
    int32_t result = (!size || bytes) && bridge->action(bridge->context, name, node, (const uint8_t *)bytes, size);
    if (bytes) (*env)->ReleaseByteArrayElements(env, payload, bytes, JNI_ABORT);
    (*env)->ReleaseStringUTFChars(env, op, name);
    return result ? JNI_TRUE : JNI_FALSE;
}

RuneAndroidSemantics *rune_android_semantics_open(void *opaque, void *context, RuneAndroidSemanticAction action) {
    ANativeActivity *a = opaque;
    if (!a || !a->clazz || !action) return NULL;
    JNIEnv *env = semantics_env(a);
    if (!env) return NULL;
    jclass cls = (*env)->GetObjectClass(env, a->clazz);
    if (!cls) return NULL;
    // Register on the declaring class when the embedding app subclasses RuneActivity or RuneSurfaceView.
    jmethodID declared = (*env)->GetMethodID(env, cls, "runeHostClass", "()Ljava/lang/Class;");
    jclass host = declared ? (jclass)(*env)->CallObjectMethod(env, a->clazz, declared) : NULL;
    if (!host || (*env)->ExceptionCheck(env)) {
        (*env)->ExceptionClear(env);
        (*env)->DeleteLocalRef(env, cls);
        return NULL;
    }
    RuneAndroidSemantics *bridge = calloc(1, sizeof(*bridge));
    if (bridge) {
        bridge->activity = a;
        bridge->context = context;
        bridge->action = action;
        // A plain NativeActivity can still host a Rune GPU surface without the Java adapter.
        bridge->attach = (*env)->GetMethodID(env, cls, "setRunePeer", "(J)V");
        if (bridge->attach) bridge->publish = (*env)->GetMethodID(env, cls, "updateRuneSnapshot", "(Z[B)V");
        if (bridge->publish) bridge->reader = (*env)->GetMethodID(env, cls, "isRuneReaderActive", "()Z");
        JNINativeMethod methods[] = {{"nativeRuneAction", "(JLjava/lang/String;I[B)Z", (void *)on_action}};
        int registered = bridge->reader && (*env)->RegisterNatives(env, host, methods, 1) == JNI_OK;
        if (registered) {
            (*env)->CallVoidMethod(env, a->clazz, bridge->attach, (jlong)(intptr_t)bridge);
        }
        if (!registered || (*env)->ExceptionCheck(env)) {
            (*env)->ExceptionClear(env);
            free(bridge);
            bridge = NULL;
        }
    }
    (*env)->DeleteLocalRef(env, host);
    (*env)->DeleteLocalRef(env, cls);
    return bridge;
}

void rune_android_semantics_close(RuneAndroidSemantics *bridge) {
    if (!bridge) return;
    JNIEnv *env = semantics_env(bridge->activity);
    if (env && bridge->activity && bridge->activity->clazz && bridge->attach) {
        (*env)->CallVoidMethod(env, bridge->activity->clazz, bridge->attach, (jlong)0);
        if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
    }
    free(bridge);
}

int32_t rune_android_semantics_reader(RuneAndroidSemantics *bridge) {
    if (!bridge) return 0;
    JNIEnv *env = semantics_env(bridge->activity);
    if (!env || !bridge->activity || !bridge->activity->clazz || !bridge->reader) return 0;
    jboolean enabled = (*env)->CallBooleanMethod(env, bridge->activity->clazz, bridge->reader);
    if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); return 0; }
    return enabled;
}

void rune_android_semantics_publish(RuneAndroidSemantics *bridge, int32_t tree, const uint8_t *json, int32_t length) {
    if (!bridge || !json || length <= 0) return;
    JNIEnv *env = semantics_env(bridge->activity);
    if (!env || !bridge->activity || !bridge->activity->clazz || !bridge->publish) return;
    jbyteArray array = (*env)->NewByteArray(env, length);
    if (array) {
        (*env)->SetByteArrayRegion(env, array, 0, length, (const jbyte *)json);
        if (!(*env)->ExceptionCheck(env))
            (*env)->CallVoidMethod(env, bridge->activity->clazz, bridge->publish, (jboolean)(tree != 0), array);
        (*env)->DeleteLocalRef(env, array);
    }
    if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionDescribe(env); (*env)->ExceptionClear(env); }
}
#endif
