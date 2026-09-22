/*
 * Longwave KVM dongle — entry point and USB serial command loop.
 *
 * The Mac talks to this firmware over the CH340 USB-UART bridge on UART0 at
 * 921600 baud. The ESP_LOG console shares that UART: log output is plain ASCII
 * and can never look like a frame (frames start with 0xA5), and the framer
 * ignores anything that is not a start byte. So one cable carries both the
 * boot log and the protocol.
 */

#include "ble_kvm.h"
#include "kvm_config.h"
#include "led.h"
#include "proto.h"

#include <string.h>

#include "driver/uart.h"
#include "driver/uart_vfs.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "nvs_flash.h"

static const char *TAG = "kvm";

static SemaphoreHandle_t s_tx_lock;
static kvm_parser_t s_parser;

/* ------------------------------------------------------------ frame output */

static void send_frame(uint8_t type, const uint8_t *payload, uint8_t len)
{
    uint8_t buf[KVM_MAX_FRAME];
    size_t n = kvm_frame_encode(buf, type, payload, len);
    if (n == 0) {
        return;
    }
    /* One write per frame: the UART driver serialises a single call, so a
     * concurrent ESP_LOG line can land before or after a frame but never
     * inside one. The mutex keeps two frames from interleaving with each
     * other (the BLE host task emits events asynchronously). */
    xSemaphoreTake(s_tx_lock, portMAX_DELAY);
    uart_write_bytes(KVM_UART_NUM, buf, n);
    xSemaphoreGive(s_tx_lock);
}

static void send_ack(uint8_t cmd)
{
    send_frame(KVM_RSP_ACK, &cmd, 1);
}

static void send_ack_echo(uint8_t cmd, const uint8_t *echo, uint8_t echo_len)
{
    uint8_t p[1 + KVM_MAX_PAYLOAD];
    p[0] = cmd;
    if (echo_len > KVM_MAX_PAYLOAD - 1) {
        echo_len = KVM_MAX_PAYLOAD - 1;
    }
    if (echo_len) {
        memcpy(&p[1], echo, echo_len);
    }
    send_frame(KVM_RSP_ACK, p, (uint8_t)(1 + echo_len));
}

static void send_nack(uint8_t cmd, uint8_t err)
{
    uint8_t p[2] = { cmd, err };
    send_frame(KVM_RSP_NACK, p, 2);
}

static void send_status(void)
{
    kvm_ble_status_t st;
    kvm_ble_get_status(&st);

    uint32_t uptime_s = (uint32_t)(esp_timer_get_time() / 1000000ULL);

    uint8_t p[16];
    p[0] = KVM_PROTO_VERSION;
    p[1] = KVM_FW_MAJOR;
    p[2] = KVM_FW_MINOR;
    p[3] = KVM_FW_PATCH;
    p[4] = st.state;
    p[5] = st.flags;
    p[6] = st.bond_count;
    p[7] = st.led_state;
    memcpy(&p[8], st.mac, 6);
    p[14] = (uint8_t)(uptime_s & 0xFF);
    p[15] = (uint8_t)((uptime_s >> 8) & 0xFF);

    send_frame(KVM_RSP_STATUS, p, sizeof(p));
}

/* Called from the NimBLE host task. */
static void on_ble_event(uint8_t ev, const uint8_t *data, uint8_t len)
{
    uint8_t p[1 + 8];
    p[0] = ev;
    if (len > 8) {
        len = 8;
    }
    if (len && data) {
        memcpy(&p[1], data, len);
    }
    send_frame(KVM_RSP_EVENT, p, (uint8_t)(1 + len));

    switch (ev) {
    case KVM_EV_ADVERTISING:
        kvm_led_set_mode(KVM_LED_ADVERTISING);
        break;
    case KVM_EV_CONNECTED:
        kvm_led_set_mode(KVM_LED_CONNECTED);
        break;
    case KVM_EV_ENCRYPTED:
        kvm_led_set_mode(KVM_LED_READY);
        break;
    case KVM_EV_DISCONNECTED:
        kvm_led_set_mode(KVM_LED_ADVERTISING);
        break;
    default:
        break;
    }
}

/* ------------------------------------------------------- command dispatch */

static int16_t rd_i16(const uint8_t *p)
{
    return (int16_t)((uint16_t)p[0] | ((uint16_t)p[1] << 8));
}

static void on_frame(uint8_t type, const uint8_t *payload, uint8_t len,
                     bool crc_ok, void *arg)
{
    (void)arg;

    if (!crc_ok) {
        send_nack(type, KVM_ERR_CRC);
        return;
    }

    switch (type) {
    case KVM_CMD_PING:
        send_ack_echo(KVM_CMD_PING, payload, len);
        return;

    case KVM_CMD_GET_STATUS:
        if (len != 0) {
            send_nack(type, KVM_ERR_LENGTH);
            return;
        }
        send_status();
        return;

    case KVM_CMD_KEY_REPORT: {
        if (len != 8) {
            send_nack(type, KVM_ERR_LENGTH);
            return;
        }
        uint8_t rc = kvm_ble_send_keyboard(payload);
        if (rc) {
            send_nack(type, rc);
        } else {
            kvm_led_activity();
            send_ack(type);
        }
        return;
    }

    case KVM_CMD_MOUSE_MOVE: {
        if (len != 7) {
            send_nack(type, KVM_ERR_LENGTH);
            return;
        }
        uint8_t rc = kvm_ble_send_mouse(rd_i16(&payload[0]), rd_i16(&payload[2]),
                                        payload[4], (int8_t)payload[5],
                                        (int8_t)payload[6]);
        if (rc) {
            send_nack(type, rc);
        } else {
            kvm_led_activity();
            send_ack(type);
        }
        return;
    }

    case KVM_CMD_MOUSE_BUTTONS: {
        if (len != 1) {
            send_nack(type, KVM_ERR_LENGTH);
            return;
        }
        uint8_t rc = kvm_ble_send_mouse(0, 0, payload[0], 0, 0);
        if (rc) {
            send_nack(type, rc);
        } else {
            kvm_led_activity();
            send_ack(type);
        }
        return;
    }

    case KVM_CMD_CONSUMER: {
        if (len != 3) {
            send_nack(type, KVM_ERR_LENGTH);
            return;
        }
        uint16_t usage = (uint16_t)payload[0] | ((uint16_t)payload[1] << 8);
        if (usage > 0x03FF) {
            send_nack(type, KVM_ERR_BAD_PAYLOAD);
            return;
        }
        uint8_t rc = kvm_ble_send_consumer(payload[2] ? usage : 0);
        if (rc) {
            send_nack(type, rc);
        } else {
            kvm_led_activity();
            send_ack(type);
        }
        return;
    }

    case KVM_CMD_RELEASE_ALL: {
        if (len != 0) {
            send_nack(type, KVM_ERR_LENGTH);
            return;
        }
        uint8_t rc = kvm_ble_release_all();
        if (rc) {
            send_nack(type, rc);
        } else {
            kvm_led_activity();
            send_ack(type);
        }
        return;
    }

    case KVM_CMD_FORGET_BONDS:
        if (len != 0) {
            send_nack(type, KVM_ERR_LENGTH);
            return;
        }
        /* Ack first: clearing bonds tears the link down, and the host should
         * see the answer to the command it sent before the state change. */
        send_ack(type);
        kvm_ble_forget_bonds();
        return;

    default:
        send_nack(type, KVM_ERR_UNKNOWN_CMD);
        return;
    }
}

/* ------------------------------------------------------------------- main */

static void uart_init(void)
{
    const uart_config_t cfg = {
        .baud_rate = KVM_UART_BAUD,
        .data_bits = UART_DATA_8_BITS,
        .parity = UART_PARITY_DISABLE,
        .stop_bits = UART_STOP_BITS_1,
        .flow_ctrl = UART_HW_FLOWCTRL_DISABLE,
        .source_clk = UART_SCLK_DEFAULT,
    };
    ESP_ERROR_CHECK(uart_driver_install(KVM_UART_NUM, KVM_UART_RX_BUF,
                                        KVM_UART_TX_BUF, 0, NULL, 0));
    ESP_ERROR_CHECK(uart_param_config(KVM_UART_NUM, &cfg));
    /* Route stdout/ESP_LOG through the same driver so console writes and our
     * frame writes go through one lock instead of fighting over the FIFO. */
    uart_vfs_dev_use_driver(KVM_UART_NUM);
}

void app_main(void)
{
    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES ||
        err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        err = nvs_flash_init();
    }
    ESP_ERROR_CHECK(err);

    s_tx_lock = xSemaphoreCreateMutex();
    configASSERT(s_tx_lock);

    kvm_led_init();
    kvm_led_set_mode(KVM_LED_BOOT);
    uart_init();

    ESP_LOGI(TAG, "Longwave KVM dongle %d.%d.%d, protocol v%d, %u baud",
             KVM_FW_MAJOR, KVM_FW_MINOR, KVM_FW_PATCH, KVM_PROTO_VERSION,
             (unsigned)KVM_UART_BAUD);

    ESP_ERROR_CHECK(kvm_ble_init(on_ble_event));

    kvm_parser_reset(&s_parser);

    uint8_t boot[4] = { KVM_PROTO_VERSION, KVM_FW_MAJOR, KVM_FW_MINOR,
                        KVM_FW_PATCH };
    on_ble_event(KVM_EV_BOOT, boot, sizeof(boot));

    uint8_t rx[256];
    for (;;) {
        /* Block on the first byte, then drain whatever else is already in the
         * ring buffer without waiting. Asking for a full buffer with a timeout
         * instead would sit out the whole timeout before returning the few
         * bytes of a command frame — measured at a 52 ms median round trip
         * with a 50 ms timeout, which is unusable for an input relay. */
        int n = uart_read_bytes(KVM_UART_NUM, rx, 1, portMAX_DELAY);
        if (n <= 0) {
            continue;
        }
        int more = uart_read_bytes(KVM_UART_NUM, &rx[1], sizeof(rx) - 1, 0);
        if (more > 0) {
            n += more;
        }
        kvm_parser_feed(&s_parser, rx, (size_t)n, on_frame, NULL);
    }
}
