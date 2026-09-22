/*
 * Longwave KVM dongle — BLE HID-over-GATT peripheral.
 */
#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "esp_err.h"

typedef struct {
    uint8_t state;       /* KVM_STATE_*                                   */
    uint8_t flags;       /* KVM_FLAG_*                                    */
    uint8_t bond_count;  /* number of bonds stored in NVS                 */
    uint8_t led_state;   /* last keyboard LED bitmap the host wrote       */
    uint8_t mac[6];      /* the identity address we advertise             */
} kvm_ble_status_t;

/* Emitted from the NimBLE host task; must not block. */
typedef void (*kvm_ble_event_cb_t)(uint8_t event, const uint8_t *data,
                                   uint8_t len);

esp_err_t kvm_ble_init(kvm_ble_event_cb_t cb);

void kvm_ble_get_status(kvm_ble_status_t *out);

/* All senders return 0 on success, or a KVM_ERR_* code. */
uint8_t kvm_ble_send_keyboard(const uint8_t report[8]);
uint8_t kvm_ble_send_mouse(int16_t dx, int16_t dy, uint8_t buttons,
                           int8_t wheel, int8_t pan);
uint8_t kvm_ble_send_consumer(uint16_t usage);

/* Zero keyboard, mouse buttons and consumer usage, in that order. */
uint8_t kvm_ble_release_all(void);

/* Drop every bond, disconnect, and start advertising again. */
void kvm_ble_forget_bonds(void);
