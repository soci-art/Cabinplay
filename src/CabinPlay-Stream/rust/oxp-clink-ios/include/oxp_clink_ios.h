/* SPDX-FileCopyrightText: 2026 OpenXPlay.org
 * SPDX-License-Identifier: AGPL-3.0-only
 *
 * C ABI of the CarLink client (src/CabinPlay-Stream/rust/oxp-clink-ios/src/lib.rs).
 */
#ifndef OXP_CLINK_IOS_H
#define OXP_CLINK_IOS_H

#include <stddef.h>
#include <stdint.h>

typedef struct ClinkCallbacks {
    void *context;
    /* 0 idle, 1 connecting, 2 authenticating, 3 negotiating, 4 playing, 5 ended */
    void (*on_state)(void *context, uint16_t state);
    void (*on_error)(void *context, const uint8_t *bytes, size_t length);
    void (*on_touch)(void *context, uint32_t screen, double x, double y, uint8_t pressed);
    /* Calibration capture: raw surface-normalized press coordinates,
     * delivered instead of on_touch while capture mode is on. */
    void (*on_touch_capture)(void *context, double x, double y);
    void (*on_key)(void *context, uint32_t code, uint8_t down);
    void (*on_log)(void *context, const uint8_t *bytes, size_t length);
} ClinkCallbacks;

/* Set the phone identity presented in the auth request (id / model /
 * productName). Call before clink_start; NULL or empty keeps the previous
 * value. Defaults: "CabinPlay-iOS" / "CabinPlay" / "CabinPlay". */
void clink_set_identity(const char *device_id, const char *model,
                        const char *product_name);

int32_t clink_start(const char *head_unit_ipv4,
                    const char *local_ipv4,
                    const char *pin,
                    const char *state_dir,
                    uint32_t width,
                    uint32_t height,
                    ClinkCallbacks callbacks);

int32_t clink_push_config(uint32_t screen, uint32_t codec,
                          const uint8_t *config, size_t length, double fps);
int32_t clink_push_frame(uint32_t screen, const uint8_t *bytes, size_t length,
                         int64_t pts_us, int32_t key_frame);
/* Media audio (AAC-LC): register the format once per stream, then push raw
 * access units (no ADTS header) with pts on the video timeline. */
int32_t clink_push_audio_format(uint32_t stream, uint32_t sample_rate,
                                uint32_t channels, const uint8_t *config,
                                size_t length);
int32_t clink_push_audio_packet(uint32_t stream, const uint8_t *bytes,
                                size_t length, int64_t pts_us);
int32_t clink_stop(void);
int32_t clink_is_running(void);

/* Per-car touch calibration: picture rectangle in surface-normalized
 * coordinates; source 1 = built-in preset, 2 = user manual calibration. */
void clink_set_touch_calibration(double left, double right, double top,
                                 double bottom, uint32_t source);
void clink_clear_touch_calibration(void);
/* Last declared geometry for the calibration self-check: fills
 * [surface_w, surface_h, visible_w, visible_h]; 1 when surface known. */
uint32_t clink_touch_geometry(uint32_t *out);
/* While capture is on, touches report raw coordinates via
 * on_touch_capture and are never forwarded as normal touches. */
void clink_set_touch_capture(uint32_t enabled);
/* Touch conversion mode: 0 = passthrough (raw), 1 = centered model,
 * 2 = calibrated (default). Takes effect immediately. */
void clink_set_touch_mode(uint32_t mode);
/* Re-print the touch anchor line (declared geometry + active
 * conversion mode/rectangle) into the diagnostic log. */
void clink_log_touch_anchor(void);

#endif /* OXP_CLINK_IOS_H */
