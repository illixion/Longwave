/*
 * Longwave KVM dongle — status LED.
 *
 *   BOOT / IDLE   fast blink  (100 ms on, 100 ms off)  — radio not up yet
 *   ADVERTISING   slow blink  (150 ms on, 850 ms off)  — waiting to be paired
 *   CONNECTED     double blip every second             — linked, not encrypted
 *   READY         solid on                             — encrypted, reports OK
 *   relaying      READY with a 40 ms drop-out per report burst
 */
#pragma once

#include <stdbool.h>

typedef enum {
    KVM_LED_BOOT = 0,
    KVM_LED_ADVERTISING,
    KVM_LED_CONNECTED,
    KVM_LED_READY,
} kvm_led_mode_t;

void kvm_led_init(void);
void kvm_led_set_mode(kvm_led_mode_t mode);

/* Called on every HID report relayed to the host; produces a visible flicker
 * on top of the READY pattern. */
void kvm_led_activity(void);
