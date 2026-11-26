/* SPDX-FileCopyrightText: 2026 OpenXPlay.org
 * SPDX-License-Identifier: AGPL-3.0-only
 *
 * C ABI of the CarLink client (src/OpenXPlay-Stream/rust/oxp-clink-ios/src/lib.rs).
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
    void (*on_key)(void *context, uint32_t code, uint8_t down);
    void (*on_log)(void *context, const uint8_t *bytes, size_t length);
} ClinkCallbacks;

/* Set the phone identity presented in the auth request (id / model /
 * productName). Call before clink_start; NULL or empty keeps the previous
 * value. Defaults: "OpenXPlay-iOS" / "OpenXPlay" / "CabinPlay". */
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
int32_t clink_stop(void);
int32_t clink_is_running(void);

#endif /* OXP_CLINK_IOS_H */
