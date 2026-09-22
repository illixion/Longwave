#include "led.h"

#include "kvm_config.h"

#include "driver/gpio.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include <stdatomic.h>

#define TICK_MS 20

static _Atomic int s_mode = KVM_LED_BOOT;
static _Atomic int s_activity_ticks;

#if KVM_LED_GPIO >= 0

static void led_write(bool on)
{
#if KVM_LED_ACTIVE_LOW
    gpio_set_level((gpio_num_t)KVM_LED_GPIO, on ? 0 : 1);
#else
    gpio_set_level((gpio_num_t)KVM_LED_GPIO, on ? 1 : 0);
#endif
}

/* Each pattern is a bitmap sampled at TICK_MS; bit i is the state of phase i.
 * 50 phases = one second. */
static bool pattern_on(kvm_led_mode_t mode, int phase)
{
    switch (mode) {
    case KVM_LED_BOOT:
        return (phase % 10) < 5;                 /* 100 ms / 100 ms */
    case KVM_LED_ADVERTISING:
        return phase < 8;                        /* 160 ms on, 840 ms off */
    case KVM_LED_CONNECTED:
        return (phase < 4) || (phase >= 8 && phase < 12); /* two blips */
    case KVM_LED_READY:
    default:
        return true;                             /* solid */
    }
}

static void led_task(void *arg)
{
    (void)arg;
    int phase = 0;
    for (;;) {
        kvm_led_mode_t mode = (kvm_led_mode_t)atomic_load(&s_mode);
        bool on = pattern_on(mode, phase);

        int act = atomic_load(&s_activity_ticks);
        if (act > 0) {
            atomic_store(&s_activity_ticks, act - 1);
            /* Invert during activity so it is visible in every pattern. */
            on = !on;
        }

        led_write(on);
        phase = (phase + 1) % 50;
        vTaskDelay(pdMS_TO_TICKS(TICK_MS));
    }
}

void kvm_led_init(void)
{
    gpio_config_t cfg = {
        .pin_bit_mask = 1ULL << KVM_LED_GPIO,
        .mode = GPIO_MODE_OUTPUT,
        .pull_up_en = GPIO_PULLUP_DISABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    gpio_config(&cfg);
    led_write(false);
    xTaskCreate(led_task, "kvm_led", 2048, NULL, 2, NULL);
}

void kvm_led_activity(void)
{
    atomic_store(&s_activity_ticks, 2); /* ~40 ms */
}

#else /* no LED on this board */

void kvm_led_init(void) {}
void kvm_led_activity(void) {}

#endif

void kvm_led_set_mode(kvm_led_mode_t mode)
{
    atomic_store(&s_mode, (int)mode);
}
