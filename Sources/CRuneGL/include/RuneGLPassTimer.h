#ifndef RUNE_GL_PASS_TIMER_H
#define RUNE_GL_PASS_TIMER_H

#include "CRuneGL.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct RuneGLTimer RuneGLTimer;
typedef struct { uint32_t label; double milliseconds; } RuneGLTimerInterval;
enum { RuneGLTimerMaxIntervals = 32 };

/* Current-context GPU timing, using timestamp queries or elapsed queries when
 * the driver only supports those. Returns NULL when neither counter works.
 * On GLES use one recorder per context: reading GPU_DISJOINT_EXT resets it. */
RuneGLTimer *rune_gl_timer_open(RuneGLResolve resolve);
void rune_gl_timer_close(RuneGLTimer *timer);
void rune_gl_timer_abandon(RuneGLTimer *timer);

/* Begin a sample when a query set is free. After a successful begin, mark
 * each interval's end with an application label, then end the sample.
 * Up to three finished samples queue without blocking. Cancel a failed frame. */
int rune_gl_timer_begin(RuneGLTimer *timer);
int rune_gl_timer_mark(RuneGLTimer *timer, uint32_t label);
void rune_gl_timer_end(RuneGLTimer *timer);
void rune_gl_timer_cancel(RuneGLTimer *timer);

/* Consume the oldest available sample. Return its interval count, zero if
 * nothing is ready, or -1 on disjoint/invalid data or insufficient capacity.
 * Pass wait=0 to poll. A short output buffer leaves the sample queued. */
int rune_gl_timer_read(RuneGLTimer *timer, int wait, RuneGLTimerInterval *intervals, int capacity);

#ifdef __cplusplus
}
#endif
#endif
