#include "RuneGLPassTimer.h"
#include "gl_api.h"
#include <stdlib.h>
#include <string.h>

enum {
    timer_sets = 3, query_count = RuneGLTimerMaxIntervals + 1,
    gl_extensions = 0x1F03, gl_num_extensions = 0x821D, gl_timestamp = 0x8E28,
    gl_time_elapsed = 0x88BF, gl_disjoint = 0x8FBB, gl_counter_bits = 0x8864,
    gl_current_query = 0x8865, gl_result = 0x8866, gl_available = 0x8867
};

typedef struct {
    GLuint queries[query_count];
    uint32_t labels[RuneGLTimerMaxIntervals];
    int count;
} Sample;

struct RuneGLTimer {
    const GLubyte *(RUNE_GL_CALL *GetString)(GLenum);
    const GLubyte *(RUNE_GL_CALL *GetStringi)(GLenum, GLuint);
    void (RUNE_GL_CALL *GetIntegerv)(GLenum, GLint *);
    void (RUNE_GL_CALL *GenQueries)(GLsizei, GLuint *);
    void (RUNE_GL_CALL *DeleteQueries)(GLsizei, const GLuint *);
    void (RUNE_GL_CALL *GetQueryiv)(GLenum, GLenum, GLint *);
    void (RUNE_GL_CALL *QueryCounter)(GLuint, GLenum);
    void (RUNE_GL_CALL *BeginQuery)(GLenum, GLuint);
    void (RUNE_GL_CALL *EndQuery)(GLenum);
    void (RUNE_GL_CALL *GetQueryObjectuiv)(GLuint, GLenum, GLuint *);
    void (RUNE_GL_CALL *GetQueryObjectui64v)(GLuint, GLenum, uint64_t *);
    Sample samples[timer_sets];
    int head, pending, active, es, elapsed, counter_bits;
};

static int has_disjoint_timer(const RuneGLTimer *timer) {
    GLint count = 0;
    timer->GetIntegerv(gl_num_extensions, &count);
    for (GLint i = 0; i < count; ++i) {
        const char *name = (const char *)timer->GetStringi(gl_extensions, (GLuint)i);
        if (name && !strcmp(name, "GL_EXT_disjoint_timer_query")) return 1;
    }
    return 0;
}

static Sample *recording(RuneGLTimer *timer) {
    return &timer->samples[(timer->head + timer->pending) % timer_sets];
}

RuneGLTimer *rune_gl_timer_open(RuneGLResolve resolve) {
    if (!resolve) return NULL;
    RuneGLTimer *timer = calloc(1, sizeof(*timer));
    if (!timer) return NULL;
#define LOOKUP(field, name) do { \
        void *address = resolve(name); \
        if (!address) goto unsupported; \
        memcpy(&timer->field, &address, sizeof(timer->field)); \
    } while (0)
#define QUERY(field) LOOKUP(field, timer->es ? "gl" #field "EXT" : "gl" #field)
    LOOKUP(GetString, "glGetString");
    LOOKUP(GetIntegerv, "glGetIntegerv");
    const char *version = (const char *)timer->GetString(GL_VERSION);
    if (!version) goto unsupported;
    timer->es = strncmp(version, "OpenGL ES", 9) == 0;
    GLint major = 0, minor = 0;
    timer->GetIntegerv(GL_MAJOR_VERSION, &major);
    timer->GetIntegerv(GL_MINOR_VERSION, &minor);
    if (major < 3) goto unsupported;
    if (timer->es) {
        LOOKUP(GetStringi, "glGetStringi");
        if (!has_disjoint_timer(timer)) goto unsupported;
    } else if (major == 3 && minor < 3) goto unsupported;
    QUERY(GetQueryiv);
    QUERY(GenQueries);
    QUERY(DeleteQueries);
    QUERY(GetQueryObjectuiv);
    QUERY(GetQueryObjectui64v);
    timer->GetQueryiv(gl_timestamp, gl_counter_bits, &timer->counter_bits);
    if (timer->counter_bits > 0) {
        QUERY(QueryCounter);
    } else {
        timer->GetQueryiv(gl_time_elapsed, gl_counter_bits, &timer->counter_bits);
        if (timer->counter_bits <= 0) goto unsupported;
        timer->elapsed = 1;
        QUERY(BeginQuery);
        QUERY(EndQuery);
    }
#undef LOOKUP
#undef QUERY
    if (timer->counter_bits > 64) goto unsupported;
    if (timer->es) {
        GLint stale = 0;
        timer->GetIntegerv(gl_disjoint, &stale);
    }
    for (int i = 0; i < timer_sets; ++i) {
        timer->GenQueries(query_count, timer->samples[i].queries);
        if (!timer->samples[i].queries[query_count - 1]) {
            rune_gl_timer_close(timer);
            return NULL;
        }
    }
    return timer;
unsupported:
    free(timer);
    return NULL;
}

int rune_gl_timer_begin(RuneGLTimer *timer) {
    if (!timer || timer->active || timer->pending == timer_sets) return 0;
    Sample *sample = recording(timer);
    sample->count = 0;
    if (timer->elapsed) {
        GLint active = 0;
        timer->GetQueryiv(gl_time_elapsed, gl_current_query, &active);
        if (active) return 0;
        timer->BeginQuery(gl_time_elapsed, sample->queries[0]);
    } else {
        timer->QueryCounter(sample->queries[0], gl_timestamp);
    }
    timer->active = 1;
    return 1;
}

int rune_gl_timer_mark(RuneGLTimer *timer, uint32_t label) {
    if (!timer || !timer->active) return 0;
    Sample *sample = recording(timer);
    if (sample->count == RuneGLTimerMaxIntervals) {
        rune_gl_timer_cancel(timer);
        return 0;
    }
    sample->labels[sample->count++] = label;
    if (timer->elapsed) {
        timer->EndQuery(gl_time_elapsed);
        timer->BeginQuery(gl_time_elapsed, sample->queries[sample->count]);
    } else {
        timer->QueryCounter(sample->queries[sample->count], gl_timestamp);
    }
    return 1;
}

void rune_gl_timer_cancel(RuneGLTimer *timer) {
    if (!timer || !timer->active) return;
    if (timer->elapsed) timer->EndQuery(gl_time_elapsed);
    timer->active = 0;
}

void rune_gl_timer_end(RuneGLTimer *timer) {
    if (!timer || !timer->active) return;
    Sample *sample = recording(timer);
    rune_gl_timer_cancel(timer);
    if (sample->count) ++timer->pending;
}

void rune_gl_timer_close(RuneGLTimer *timer) {
    if (!timer) return;
    rune_gl_timer_cancel(timer);
    for (int i = 0; i < timer_sets; ++i) timer->DeleteQueries(query_count, timer->samples[i].queries);
    free(timer);
}

void rune_gl_timer_abandon(RuneGLTimer *timer) { free(timer); }

int rune_gl_timer_read(RuneGLTimer *timer, int wait, RuneGLTimerInterval *out, int capacity) {
    if (!timer || !timer->pending) return 0;
    Sample *sample = &timer->samples[timer->head];
    if (!out || capacity < sample->count) return -1;
    GLuint last = sample->queries[timer->elapsed ? sample->count - 1 : sample->count];
    if (!wait) {
        GLuint ready = 0;
        timer->GetQueryObjectuiv(last, gl_available, &ready);
        if (!ready) return 0;
    }
    uint64_t last_value = 0;
    timer->GetQueryObjectui64v(last, gl_result, &last_value);
    if (timer->es) {
        GLint disjoint = 0;
        timer->GetIntegerv(gl_disjoint, &disjoint);
        if (disjoint) {
            rune_gl_timer_cancel(timer);
            timer->pending = 0;
            return -1;
        }
    }
    uint64_t previous = 0;
    if (!timer->elapsed) timer->GetQueryObjectui64v(sample->queries[0], gl_result, &previous);
    const uint64_t mask = UINT64_MAX >> (64 - timer->counter_bits);
    int valid = 1;
    for (int i = 0; i < sample->count; ++i) {
        uint64_t value = last_value;
        if (i + 1 < sample->count) {
            timer->GetQueryObjectui64v(sample->queries[timer->elapsed ? i : i + 1], gl_result, &value);
        }
        // The hardware clock may wrap between two adjacent timestamps.
        uint64_t nanos = timer->elapsed ? value : (value - previous) & mask;
        // Elapsed-query implementations may saturate on counter overflow.
        if (timer->elapsed && nanos >= mask) valid = 0;
        out[i].label = sample->labels[i];
        out[i].milliseconds = (double)nanos / 1000000.0;
        previous = value;
    }
    timer->head = (timer->head + 1) % timer_sets;
    --timer->pending;
    return valid ? sample->count : -1;
}
