/*
 * Longwave KVM dongle — build-wide configuration.
 */
#pragma once

/* Firmware version, reported by KVM_CMD_GET_STATUS. */
#define KVM_FW_MAJOR 0
#define KVM_FW_MINOR 1
#define KVM_FW_PATCH 0

/* Version of the USB serial command protocol (see PROTOCOL.md). */
#define KVM_PROTO_VERSION 1

/* BLE identity. The device name also lives in sdkconfig
 * (CONFIG_BT_NIMBLE_SVC_GAP_DEVICE_NAME); this copy is what goes into the
 * advertising payload. Keep the two in sync. */
#define KVM_DEVICE_NAME    "Longwave KVM"
#define KVM_MANUFACTURER   "Longwave"
#define KVM_MODEL_NUMBER   "KVM Dongle"
#define KVM_APPEARANCE     0x03C1 /* HID / Keyboard */

/* UART carrying the host command protocol. This is UART0, the same pins the
 * CH340 bridge is wired to, and the same UART the ESP_LOG console uses. */
#define KVM_UART_NUM       0
#define KVM_UART_BAUD      460800
#define KVM_UART_RX_BUF    4096
#define KVM_UART_TX_BUF    4096

/* Status LED. GPIO2 is the on-board LED on the ESP32 DevKitC / NodeMCU-32S
 * family. Set to -1 if the board has no usable LED. */
#define KVM_LED_GPIO       2
#define KVM_LED_ACTIVE_LOW 0
