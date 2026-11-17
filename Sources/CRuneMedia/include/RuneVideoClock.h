#ifndef RUNE_VIDEO_CLOCK_H
#define RUNE_VIDEO_CLOCK_H

#ifdef _WIN32
#ifdef __cplusplus
extern "C" {
#endif

struct RuneMedia;

/* Seconds until the refresh that a picture selected now can present on.
 * Returns zero until DWM exposes a valid composition grid. */
double rune_media_present_lead(void);
/* Seconds per refresh. Before a successful DWM reading, assume 60 Hz. */
double rune_media_refresh_period(void);
/* Schedule work for the refresh containing a media deadline relative to now. */
double rune_media_refresh_wake(double seconds_until_picture);
/* Delay until the next decoded sample will be due on a playing video's clock. */
double rune_media_next_video_delay(struct RuneMedia *media);

#ifdef __cplusplus
}
#endif
#endif
#endif
