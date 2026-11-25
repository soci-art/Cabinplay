/* SPDX-FileCopyrightText: 2026 OpenXPlay.org
 * SPDX-License-Identifier: AGPL-3.0-only
 *
 * C ABI of the oxp-ios receiver core (rust/oxp-ios/src/lib.rs).
 * The struct layout must stay in sync with `OxpCallbacks` in that file.
 */
#ifndef OXP_IOS_H
#define OXP_IOS_H

#include <stddef.h>
#include <stdint.h>

typedef struct OxpCallbacks {
    void *context;
    void (*on_video_codec)(void *context, uint16_t kind, uint32_t codec);
    void (*on_video_config)(void *context, uint16_t kind, const uint8_t *bytes, size_t length);
    void (*on_video_frame)(void *context, uint16_t kind, const uint8_t *bytes, size_t length, uint64_t sender_nanos);
    void (*on_audio_format)(void *context, const uint8_t *bytes, size_t length);
    void (*on_audio_rtp)(void *context, const uint8_t *bytes, size_t length, uint32_t sample);
    void (*on_state)(void *context, const uint8_t *bytes, size_t length);
    void (*on_log)(void *context, const uint8_t *bytes, size_t length);
} OxpCallbacks;

int32_t oxp_start(const char *identity_dir,
                  const char *device_id,
                  const char *bt_mac,
                  uint32_t width,
                  uint32_t height,
                  uint32_t fps,
                  uint16_t port,
                  OxpCallbacks callbacks);

int32_t oxp_stop(void);
int32_t oxp_is_running(void);
void oxp_log(const char *line);

#endif /* OXP_IOS_H */
