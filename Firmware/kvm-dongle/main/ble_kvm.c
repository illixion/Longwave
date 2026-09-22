/*
 * Longwave KVM dongle — BLE HID-over-GATT peripheral (NimBLE).
 *
 * Services published:
 *   0x1800 GAP            (NimBLE built-in: name "Longwave KVM", appearance)
 *   0x1801 GATT           (NimBLE built-in: service changed)
 *   0x180A Device Info    manufacturer / model / firmware rev / PnP ID
 *   0x180F Battery        static 100 %, because HOGP hosts expect it
 *   0x1812 HID            protocol mode, report map, HID info, control point,
 *                         and four report characteristics
 *
 * Every HID attribute is gated on an encrypted link (BLE_GATT_CHR_F_*_ENC).
 * That is deliberate: Apple hosts refuse to use a HID device whose reports are
 * readable without encryption, and requiring encryption is also what makes the
 * host start pairing as soon as it discovers the service.
 */

#include "ble_kvm.h"

#include "hid_report_map.h"
#include "kvm_config.h"
#include "proto.h"

#include <string.h>

#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "nvs_flash.h"

#include "host/ble_hs.h"
#include "host/ble_uuid.h"
#include "host/util/util.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"

/* Provided by the NimBLE config store; not declared in a public header. */
void ble_store_config_init(void);

static const char *TAG = "kvm_ble";

/* ------------------------------------------------------------------ UUIDs */

#define UUID_SVC_DIS            0x180A
#define UUID_CHR_MANUFACTURER   0x2A29
#define UUID_CHR_MODEL_NUMBER   0x2A24
#define UUID_CHR_FW_REVISION    0x2A26
#define UUID_CHR_PNP_ID         0x2A50

#define UUID_SVC_BAS            0x180F
#define UUID_CHR_BATTERY_LEVEL  0x2A19

#define UUID_SVC_HID            0x1812
#define UUID_CHR_HID_INFO       0x2A4A
#define UUID_CHR_REPORT_MAP     0x2A4B
#define UUID_CHR_HID_CTRL_POINT 0x2A4C
#define UUID_CHR_REPORT         0x2A4D
#define UUID_CHR_PROTOCOL_MODE  0x2A4E
#define UUID_DSC_REPORT_REF     0x2908

#define REPORT_TYPE_INPUT   0x01
#define REPORT_TYPE_OUTPUT  0x02

/* --------------------------------------------------------------- app state */

static kvm_ble_event_cb_t s_event_cb;

static uint16_t s_conn_handle = BLE_HS_CONN_HANDLE_NONE;
static bool s_encrypted;
static bool s_advertising;
static uint8_t s_own_addr_type;
static uint8_t s_led_state;

static uint16_t s_hnd_kbd_in;
static uint16_t s_hnd_mouse_in;
static uint16_t s_hnd_consumer_in;

static bool s_sub_kbd;
static bool s_sub_mouse;
static bool s_sub_consumer;

/* Last input report of each kind, so a read of the report characteristic
 * answers with something sane. */
static uint8_t s_last_kbd[KVM_RPT_LEN_KEYBOARD_IN];
static uint8_t s_last_mouse[KVM_RPT_LEN_MOUSE_IN];
static uint8_t s_last_consumer[KVM_RPT_LEN_CONSUMER_IN];

static uint8_t s_protocol_mode = 0x01; /* 0 = boot, 1 = report */
static uint8_t s_battery_level = 100;

/* HID Information: bcdHID 1.11, country 0, flags = RemoteWake |
 * NormallyConnectable. */
static const uint8_t s_hid_info[4] = { 0x11, 0x01, 0x00, 0x03 };

/* PnP ID: vendor ID source 0x02 (USB Implementer's Forum), Espressif's USB
 * vendor ID 0x303A, a product ID of our own, product version 1.0.0. */
static const uint8_t s_pnp_id[7] = {
    0x02,
    0x3A, 0x30,       /* vendor  0x303A, little endian */
    0x56, 0x4B,       /* product 0x4B56 ("KV")         */
    0x00, 0x01,       /* version 0x0100                */
};

static const char s_fw_revision[] =
    "0.1.0";

/* Report Reference descriptor values: {report id, report type}. */
static const uint8_t s_ref_kbd_in[2]   = { KVM_RPT_ID_KEYBOARD, REPORT_TYPE_INPUT };
static const uint8_t s_ref_kbd_out[2]  = { KVM_RPT_ID_KEYBOARD, REPORT_TYPE_OUTPUT };
static const uint8_t s_ref_mouse_in[2] = { KVM_RPT_ID_MOUSE, REPORT_TYPE_INPUT };
static const uint8_t s_ref_cons_in[2]  = { KVM_RPT_ID_CONSUMER, REPORT_TYPE_INPUT };

static void advertise_start(void);

static void emit(uint8_t ev, const uint8_t *data, uint8_t len)
{
    if (s_event_cb) {
        s_event_cb(ev, data, len);
    }
}

/* ------------------------------------------------------- GATT access hooks */

static int chr_read_static(struct ble_gatt_access_ctxt *ctxt,
                           const void *data, uint16_t len)
{
    int rc = os_mbuf_append(ctxt->om, data, len);
    return rc == 0 ? 0 : BLE_ATT_ERR_INSUFFICIENT_RES;
}

static int gatt_dis_access(uint16_t conn_handle, uint16_t attr_handle,
                           struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    (void)conn_handle;
    (void)attr_handle;
    (void)arg;

    uint16_t uuid = ble_uuid_u16(ctxt->chr->uuid);
    switch (uuid) {
    case UUID_CHR_MANUFACTURER:
        return chr_read_static(ctxt, KVM_MANUFACTURER, sizeof(KVM_MANUFACTURER) - 1);
    case UUID_CHR_MODEL_NUMBER:
        return chr_read_static(ctxt, KVM_MODEL_NUMBER, sizeof(KVM_MODEL_NUMBER) - 1);
    case UUID_CHR_FW_REVISION:
        return chr_read_static(ctxt, s_fw_revision, sizeof(s_fw_revision) - 1);
    case UUID_CHR_PNP_ID:
        return chr_read_static(ctxt, s_pnp_id, sizeof(s_pnp_id));
    default:
        return BLE_ATT_ERR_UNLIKELY;
    }
}

static int gatt_bas_access(uint16_t conn_handle, uint16_t attr_handle,
                           struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    (void)conn_handle;
    (void)attr_handle;
    (void)arg;
    return chr_read_static(ctxt, &s_battery_level, 1);
}

static int gatt_report_ref_access(uint16_t conn_handle, uint16_t attr_handle,
                                  struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    (void)conn_handle;
    (void)attr_handle;
    if (ctxt->op != BLE_GATT_ACCESS_OP_READ_DSC) {
        return BLE_ATT_ERR_UNLIKELY;
    }
    return chr_read_static(ctxt, arg, 2);
}

static int gatt_hid_access(uint16_t conn_handle, uint16_t attr_handle,
                           struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    (void)conn_handle;
    uint16_t uuid = ble_uuid_u16(ctxt->chr->uuid);

    switch (uuid) {
    case UUID_CHR_HID_INFO:
        return chr_read_static(ctxt, s_hid_info, sizeof(s_hid_info));

    case UUID_CHR_REPORT_MAP:
        return chr_read_static(ctxt, kvm_hid_report_map, KVM_HID_REPORT_MAP_LEN);

    case UUID_CHR_PROTOCOL_MODE:
        if (ctxt->op == BLE_GATT_ACCESS_OP_READ_CHR) {
            return chr_read_static(ctxt, &s_protocol_mode, 1);
        }
        if (ctxt->op == BLE_GATT_ACCESS_OP_WRITE_CHR) {
            uint8_t v = 0;
            uint16_t got = 0;
            if (ble_hs_mbuf_to_flat(ctxt->om, &v, 1, &got) != 0 || got != 1) {
                return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
            }
            s_protocol_mode = v;
            ESP_LOGI(TAG, "protocol mode -> %u", v);
            return 0;
        }
        return BLE_ATT_ERR_UNLIKELY;

    case UUID_CHR_HID_CTRL_POINT: {
        uint8_t v = 0;
        uint16_t got = 0;
        if (ble_hs_mbuf_to_flat(ctxt->om, &v, 1, &got) == 0 && got == 1) {
            ESP_LOGI(TAG, "HID control point: %s",
                     v == 0 ? "suspend" : "exit suspend");
        }
        return 0;
    }

    case UUID_CHR_REPORT: {
        /* `arg` identifies which report this characteristic carries. */
        uintptr_t which = (uintptr_t)arg;

        if (ctxt->op == BLE_GATT_ACCESS_OP_READ_CHR) {
            switch (which) {
            case KVM_RPT_ID_KEYBOARD:
                return chr_read_static(ctxt, s_last_kbd, sizeof(s_last_kbd));
            case KVM_RPT_ID_MOUSE:
                return chr_read_static(ctxt, s_last_mouse, sizeof(s_last_mouse));
            case KVM_RPT_ID_CONSUMER:
                return chr_read_static(ctxt, s_last_consumer, sizeof(s_last_consumer));
            case 0x80: /* keyboard LED output report */
                return chr_read_static(ctxt, &s_led_state, 1);
            default:
                return BLE_ATT_ERR_UNLIKELY;
            }
        }

        if (ctxt->op == BLE_GATT_ACCESS_OP_WRITE_CHR && which == 0x80) {
            uint8_t v = 0;
            uint16_t got = 0;
            if (ble_hs_mbuf_to_flat(ctxt->om, &v, 1, &got) != 0 || got < 1) {
                return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
            }
            s_led_state = v;
            ESP_LOGI(TAG, "keyboard LEDs -> 0x%02x", v);
            emit(KVM_EV_LED_STATE, &v, 1);
            return 0;
        }

        (void)attr_handle;
        return BLE_ATT_ERR_UNLIKELY;
    }

    default:
        return BLE_ATT_ERR_UNLIKELY;
    }
}

/* --------------------------------------------------------- GATT definition */

static const struct ble_gatt_dsc_def dsc_kbd_in[] = {
    {
        .uuid = BLE_UUID16_DECLARE(UUID_DSC_REPORT_REF),
        .att_flags = BLE_ATT_F_READ | BLE_ATT_F_READ_ENC,
        .access_cb = gatt_report_ref_access,
        .arg = (void *)s_ref_kbd_in,
    },
    { 0 },
};

static const struct ble_gatt_dsc_def dsc_kbd_out[] = {
    {
        .uuid = BLE_UUID16_DECLARE(UUID_DSC_REPORT_REF),
        .att_flags = BLE_ATT_F_READ | BLE_ATT_F_READ_ENC,
        .access_cb = gatt_report_ref_access,
        .arg = (void *)s_ref_kbd_out,
    },
    { 0 },
};

static const struct ble_gatt_dsc_def dsc_mouse_in[] = {
    {
        .uuid = BLE_UUID16_DECLARE(UUID_DSC_REPORT_REF),
        .att_flags = BLE_ATT_F_READ | BLE_ATT_F_READ_ENC,
        .access_cb = gatt_report_ref_access,
        .arg = (void *)s_ref_mouse_in,
    },
    { 0 },
};

static const struct ble_gatt_dsc_def dsc_cons_in[] = {
    {
        .uuid = BLE_UUID16_DECLARE(UUID_DSC_REPORT_REF),
        .att_flags = BLE_ATT_F_READ | BLE_ATT_F_READ_ENC,
        .access_cb = gatt_report_ref_access,
        .arg = (void *)s_ref_cons_in,
    },
    { 0 },
};

static const struct ble_gatt_svc_def s_gatt_svcs[] = {
    /* --- Device Information ------------------------------------------- */
    {
        .type = BLE_GATT_SVC_TYPE_PRIMARY,
        .uuid = BLE_UUID16_DECLARE(UUID_SVC_DIS),
        .characteristics = (struct ble_gatt_chr_def[]) {
            {
                .uuid = BLE_UUID16_DECLARE(UUID_CHR_MANUFACTURER),
                .access_cb = gatt_dis_access,
                .flags = BLE_GATT_CHR_F_READ,
            },
            {
                .uuid = BLE_UUID16_DECLARE(UUID_CHR_MODEL_NUMBER),
                .access_cb = gatt_dis_access,
                .flags = BLE_GATT_CHR_F_READ,
            },
            {
                .uuid = BLE_UUID16_DECLARE(UUID_CHR_FW_REVISION),
                .access_cb = gatt_dis_access,
                .flags = BLE_GATT_CHR_F_READ,
            },
            {
                .uuid = BLE_UUID16_DECLARE(UUID_CHR_PNP_ID),
                .access_cb = gatt_dis_access,
                .flags = BLE_GATT_CHR_F_READ,
            },
            { 0 },
        },
    },

    /* --- Battery ------------------------------------------------------- */
    {
        .type = BLE_GATT_SVC_TYPE_PRIMARY,
        .uuid = BLE_UUID16_DECLARE(UUID_SVC_BAS),
        .characteristics = (struct ble_gatt_chr_def[]) {
            {
                .uuid = BLE_UUID16_DECLARE(UUID_CHR_BATTERY_LEVEL),
                .access_cb = gatt_bas_access,
                .flags = BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_NOTIFY,
            },
            { 0 },
        },
    },

    /* --- HID ----------------------------------------------------------- */
    {
        .type = BLE_GATT_SVC_TYPE_PRIMARY,
        .uuid = BLE_UUID16_DECLARE(UUID_SVC_HID),
        .characteristics = (struct ble_gatt_chr_def[]) {
            {
                .uuid = BLE_UUID16_DECLARE(UUID_CHR_PROTOCOL_MODE),
                .access_cb = gatt_hid_access,
                .flags = BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_WRITE_NO_RSP,
            },
            {
                .uuid = BLE_UUID16_DECLARE(UUID_CHR_HID_INFO),
                .access_cb = gatt_hid_access,
                .flags = BLE_GATT_CHR_F_READ,
            },
            {
                .uuid = BLE_UUID16_DECLARE(UUID_CHR_REPORT_MAP),
                .access_cb = gatt_hid_access,
                .flags = BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_READ_ENC,
            },
            {
                .uuid = BLE_UUID16_DECLARE(UUID_CHR_HID_CTRL_POINT),
                .access_cb = gatt_hid_access,
                .flags = BLE_GATT_CHR_F_WRITE_NO_RSP,
            },
            /* Report ID 1 — keyboard input */
            {
                .uuid = BLE_UUID16_DECLARE(UUID_CHR_REPORT),
                .access_cb = gatt_hid_access,
                .arg = (void *)(uintptr_t)KVM_RPT_ID_KEYBOARD,
                .flags = BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_READ_ENC |
                         BLE_GATT_CHR_F_NOTIFY,
                .descriptors = (struct ble_gatt_dsc_def *)dsc_kbd_in,
                .val_handle = &s_hnd_kbd_in,
            },
            /* Report ID 1 — keyboard LED output */
            {
                .uuid = BLE_UUID16_DECLARE(UUID_CHR_REPORT),
                .access_cb = gatt_hid_access,
                .arg = (void *)(uintptr_t)0x80,
                .flags = BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_READ_ENC |
                         BLE_GATT_CHR_F_WRITE | BLE_GATT_CHR_F_WRITE_ENC |
                         BLE_GATT_CHR_F_WRITE_NO_RSP,
                .descriptors = (struct ble_gatt_dsc_def *)dsc_kbd_out,
            },
            /* Report ID 2 — mouse input */
            {
                .uuid = BLE_UUID16_DECLARE(UUID_CHR_REPORT),
                .access_cb = gatt_hid_access,
                .arg = (void *)(uintptr_t)KVM_RPT_ID_MOUSE,
                .flags = BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_READ_ENC |
                         BLE_GATT_CHR_F_NOTIFY,
                .descriptors = (struct ble_gatt_dsc_def *)dsc_mouse_in,
                .val_handle = &s_hnd_mouse_in,
            },
            /* Report ID 3 — consumer control input */
            {
                .uuid = BLE_UUID16_DECLARE(UUID_CHR_REPORT),
                .access_cb = gatt_hid_access,
                .arg = (void *)(uintptr_t)KVM_RPT_ID_CONSUMER,
                .flags = BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_READ_ENC |
                         BLE_GATT_CHR_F_NOTIFY,
                .descriptors = (struct ble_gatt_dsc_def *)dsc_cons_in,
                .val_handle = &s_hnd_consumer_in,
            },
            { 0 },
        },
    },

    { 0 },
};

/* ----------------------------------------------------------- advertising */

static int bond_count(void)
{
    int count = 0;
    if (ble_store_util_count(BLE_STORE_OBJ_TYPE_OUR_SEC, &count) != 0) {
        return 0;
    }
    return count;
}

static void advertise_start(void)
{
    if (s_conn_handle != BLE_HS_CONN_HANDLE_NONE) {
        return;
    }
    if (ble_gap_adv_active()) {
        /* Already up. Re-arming would fail with BLE_HS_EALREADY and, worse,
         * used to leave s_advertising false — so "forget bonds" reported the
         * dongle as idle while it was in fact still advertising. */
        s_advertising = true;
        return;
    }

    struct ble_hs_adv_fields fields;
    memset(&fields, 0, sizeof(fields));

    fields.flags = BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP;
    fields.appearance = KVM_APPEARANCE;
    fields.appearance_is_present = 1;
    fields.uuids16 = (ble_uuid16_t[]) { BLE_UUID16_INIT(UUID_SVC_HID) };
    fields.num_uuids16 = 1;
    fields.uuids16_is_complete = 1;
    fields.name = (uint8_t *)KVM_DEVICE_NAME;
    fields.name_len = sizeof(KVM_DEVICE_NAME) - 1;
    fields.name_is_complete = 1;

    int rc = ble_gap_adv_set_fields(&fields);
    if (rc != 0) {
        ESP_LOGE(TAG, "adv_set_fields rc=%d", rc);
        return;
    }

    /* Scan response carries the manufacturer name so a scanner sees it even
     * before connecting (DIS is only readable after connecting). */
    struct ble_hs_adv_fields rsp;
    memset(&rsp, 0, sizeof(rsp));
    static const uint8_t mfg[] = { 0xFF, 0xFF, 'L', 'o', 'n', 'g', 'w', 'a', 'v', 'e' };
    rsp.mfg_data = (uint8_t *)mfg;
    rsp.mfg_data_len = sizeof(mfg);
    rc = ble_gap_adv_rsp_set_fields(&rsp);
    if (rc != 0) {
        ESP_LOGW(TAG, "adv_rsp_set_fields rc=%d", rc);
    }

    struct ble_gap_adv_params adv;
    memset(&adv, 0, sizeof(adv));
    adv.conn_mode = BLE_GAP_CONN_MODE_UND;
    adv.disc_mode = BLE_GAP_DISC_MODE_GEN;
    adv.itvl_min = BLE_GAP_ADV_FAST_INTERVAL1_MIN; /* 30 ms  */
    adv.itvl_max = BLE_GAP_ADV_FAST_INTERVAL1_MAX; /* 60 ms  */

    extern int kvm_ble_gap_event(struct ble_gap_event *event, void *arg);
    rc = ble_gap_adv_start(s_own_addr_type, NULL, BLE_HS_FOREVER, &adv,
                           kvm_ble_gap_event, NULL);
    if (rc != 0 && rc != BLE_HS_EALREADY) {
        ESP_LOGE(TAG, "adv_start rc=%d", rc);
        s_advertising = false;
        return;
    }

    s_advertising = true;
    ESP_LOGI(TAG, "advertising as \"%s\" (%d bond%s stored)", KVM_DEVICE_NAME,
             bond_count(), bond_count() == 1 ? "" : "s");
    emit(KVM_EV_ADVERTISING, NULL, 0);
}

/* ------------------------------------------------------------ GAP events */

int kvm_ble_gap_event(struct ble_gap_event *event, void *arg)
{
    (void)arg;
    struct ble_gap_conn_desc desc;

    switch (event->type) {
    case BLE_GAP_EVENT_CONNECT:
        if (event->connect.status == 0) {
            s_conn_handle = event->connect.conn_handle;
            s_advertising = false;
            s_encrypted = false;
            s_sub_kbd = s_sub_mouse = s_sub_consumer = false;
            ESP_LOGI(TAG, "connected, handle=%d", s_conn_handle);
            emit(KVM_EV_CONNECTED, NULL, 0);

            /* Ask for HID-friendly connection parameters. These sit inside
             * Apple's accepted ranges (interval >= 15 ms, max >= min + 15 ms,
             * supervision timeout <= 6 s), so the headset accepts them rather
             * than silently ignoring the request. */
            struct ble_gap_upd_params up = {
                .itvl_min = 12,   /* 15 ms */
                .itvl_max = 24,   /* 30 ms */
                .latency = 0,
                .supervision_timeout = 400, /* 4 s */
            };
            ble_gap_update_params(s_conn_handle, &up);

            /* Nudge the host into pairing / re-encrypting straight away
             * instead of waiting for it to touch an encrypted attribute. */
            int rc = ble_gap_security_initiate(s_conn_handle);
            if (rc != 0 && rc != BLE_HS_EALREADY) {
                ESP_LOGW(TAG, "security_initiate rc=%d", rc);
            }
        } else {
            ESP_LOGW(TAG, "connect failed, status=%d", event->connect.status);
            s_conn_handle = BLE_HS_CONN_HANDLE_NONE;
            advertise_start();
        }
        return 0;

    case BLE_GAP_EVENT_DISCONNECT: {
        uint8_t reason = (uint8_t)(event->disconnect.reason & 0xFF);
        ESP_LOGI(TAG, "disconnected, reason=0x%x", event->disconnect.reason);
        s_conn_handle = BLE_HS_CONN_HANDLE_NONE;
        s_encrypted = false;
        s_sub_kbd = s_sub_mouse = s_sub_consumer = false;
        memset(s_last_kbd, 0, sizeof(s_last_kbd));
        memset(s_last_mouse, 0, sizeof(s_last_mouse));
        memset(s_last_consumer, 0, sizeof(s_last_consumer));
        emit(KVM_EV_DISCONNECTED, &reason, 1);
        advertise_start();
        return 0;
    }

    case BLE_GAP_EVENT_ENC_CHANGE:
        if (ble_gap_conn_find(event->enc_change.conn_handle, &desc) == 0) {
            s_encrypted = desc.sec_state.encrypted;
            uint8_t bonded = desc.sec_state.bonded ? 1 : 0;
            ESP_LOGI(TAG,
                     "encryption change: status=%d encrypted=%d authenticated=%d bonded=%d",
                     event->enc_change.status, desc.sec_state.encrypted,
                     desc.sec_state.authenticated, desc.sec_state.bonded);
            if (s_encrypted) {
                emit(KVM_EV_ENCRYPTED, &bonded, 1);
            }
        }
        return 0;

    case BLE_GAP_EVENT_SUBSCRIBE: {
        uint16_t h = event->subscribe.attr_handle;
        bool on = event->subscribe.cur_notify;
        if (h == s_hnd_kbd_in) {
            s_sub_kbd = on;
        } else if (h == s_hnd_mouse_in) {
            s_sub_mouse = on;
        } else if (h == s_hnd_consumer_in) {
            s_sub_consumer = on;
        } else {
            return 0;
        }
        uint8_t bits = (uint8_t)((s_sub_kbd ? 1 : 0) | (s_sub_mouse ? 2 : 0) |
                                 (s_sub_consumer ? 4 : 0));
        ESP_LOGI(TAG, "subscriptions: kbd=%d mouse=%d consumer=%d", s_sub_kbd,
                 s_sub_mouse, s_sub_consumer);
        emit(KVM_EV_SUBSCRIBED, &bits, 1);
        return 0;
    }

    case BLE_GAP_EVENT_MTU:
        ESP_LOGI(TAG, "MTU = %d", event->mtu.value);
        return 0;

    case BLE_GAP_EVENT_REPEAT_PAIRING:
        /* The peer wants to pair again while a bond already exists. Drop the
         * stale bond and let pairing proceed, otherwise a headset that was
         * reset can never come back. */
        if (ble_gap_conn_find(event->repeat_pairing.conn_handle, &desc) == 0) {
            ble_store_util_delete_peer(&desc.peer_id_addr);
        }
        ESP_LOGW(TAG, "repeat pairing: old bond deleted");
        return BLE_GAP_REPEAT_PAIRING_RETRY;

    case BLE_GAP_EVENT_PASSKEY_ACTION:
        /* Just Works only: we advertise NoInputNoOutput, so we should never
         * get here. Reject anything that needs a key rather than hang. */
        ESP_LOGW(TAG, "unexpected passkey action %d",
                 event->passkey.params.action);
        return BLE_ATT_ERR_UNLIKELY;

    case BLE_GAP_EVENT_CONN_UPDATE:
        ESP_LOGI(TAG, "conn params updated, status=%d",
                 event->conn_update.status);
        return 0;

    default:
        return 0;
    }
}

/* ---------------------------------------------------------- host lifecycle */

static void on_reset(int reason)
{
    ESP_LOGE(TAG, "NimBLE reset, reason=%d", reason);
    s_conn_handle = BLE_HS_CONN_HANDLE_NONE;
    s_encrypted = false;
    s_advertising = false;
}

static void on_sync(void)
{
    int rc = ble_hs_util_ensure_addr(0);
    if (rc != 0) {
        ESP_LOGE(TAG, "ensure_addr rc=%d", rc);
        return;
    }
    rc = ble_hs_id_infer_auto(0, &s_own_addr_type);
    if (rc != 0) {
        ESP_LOGE(TAG, "infer_auto rc=%d", rc);
        return;
    }
    uint8_t addr[6] = { 0 };
    ble_hs_id_copy_addr(s_own_addr_type, addr, NULL);
    ESP_LOGI(TAG, "BLE ready, address %02x:%02x:%02x:%02x:%02x:%02x",
             addr[5], addr[4], addr[3], addr[2], addr[1], addr[0]);
    advertise_start();
}

static void host_task(void *param)
{
    (void)param;
    nimble_port_run();
    nimble_port_freertos_deinit();
}

esp_err_t kvm_ble_init(kvm_ble_event_cb_t cb)
{
    s_event_cb = cb;

    esp_err_t err = nimble_port_init();
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "nimble_port_init failed: %s", esp_err_to_name(err));
        return err;
    }

    ble_hs_cfg.reset_cb = on_reset;
    ble_hs_cfg.sync_cb = on_sync;
    ble_hs_cfg.gatts_register_cb = NULL;
    ble_hs_cfg.store_status_cb = ble_store_util_status_rr;

    /* LE Secure Connections, Just Works, bonded, keys persisted to NVS.
     * MITM protection is off deliberately: the dongle has no display and no
     * keypad, so a passkey would have to be a compile-time constant, which
     * buys no real protection and makes pairing fussier on visionOS. */
    ble_hs_cfg.sm_io_cap = BLE_HS_IO_NO_INPUT_OUTPUT;
    ble_hs_cfg.sm_bonding = 1;
    ble_hs_cfg.sm_mitm = 0;
    ble_hs_cfg.sm_sc = 1;
    ble_hs_cfg.sm_our_key_dist = BLE_SM_PAIR_KEY_DIST_ENC | BLE_SM_PAIR_KEY_DIST_ID;
    ble_hs_cfg.sm_their_key_dist = BLE_SM_PAIR_KEY_DIST_ENC | BLE_SM_PAIR_KEY_DIST_ID;

    ble_svc_gap_init();
    ble_svc_gatt_init();

    int rc = ble_gatts_count_cfg(s_gatt_svcs);
    if (rc != 0) {
        ESP_LOGE(TAG, "gatts_count_cfg rc=%d", rc);
        return ESP_FAIL;
    }
    rc = ble_gatts_add_svcs(s_gatt_svcs);
    if (rc != 0) {
        ESP_LOGE(TAG, "gatts_add_svcs rc=%d", rc);
        return ESP_FAIL;
    }

    rc = ble_svc_gap_device_name_set(KVM_DEVICE_NAME);
    if (rc != 0) {
        ESP_LOGW(TAG, "device_name_set rc=%d", rc);
    }
    rc = ble_svc_gap_device_appearance_set(KVM_APPEARANCE);
    if (rc != 0) {
        ESP_LOGW(TAG, "appearance_set rc=%d", rc);
    }

    ble_store_config_init();

    nimble_port_freertos_init(host_task);
    return ESP_OK;
}

/* ------------------------------------------------------------- public API */

void kvm_ble_get_status(kvm_ble_status_t *out)
{
    memset(out, 0, sizeof(*out));

    bool connected = s_conn_handle != BLE_HS_CONN_HANDLE_NONE;
    int bonds = bond_count();

    out->flags = (uint8_t)((connected ? KVM_FLAG_CONNECTED : 0) |
                           (s_encrypted ? KVM_FLAG_ENCRYPTED : 0) |
                           (s_advertising ? KVM_FLAG_ADVERTISING : 0) |
                           (bonds > 0 ? KVM_FLAG_HAS_BOND : 0) |
                           (s_sub_kbd ? KVM_FLAG_SUB_KEYBOARD : 0) |
                           (s_sub_mouse ? KVM_FLAG_SUB_MOUSE : 0) |
                           (s_sub_consumer ? KVM_FLAG_SUB_CONSUMER : 0));

    if (connected && s_encrypted) {
        out->state = KVM_STATE_READY;
    } else if (connected) {
        out->state = KVM_STATE_CONNECTED;
    } else if (s_advertising) {
        out->state = KVM_STATE_ADVERTISING;
    } else {
        out->state = KVM_STATE_IDLE;
    }

    out->bond_count = (uint8_t)(bonds > 255 ? 255 : bonds);
    out->led_state = s_led_state;
    ble_hs_id_copy_addr(s_own_addr_type, out->mac, NULL);
}

static uint8_t notify(uint16_t handle, bool subscribed, const void *data,
                      uint16_t len)
{
    if (s_conn_handle == BLE_HS_CONN_HANDLE_NONE) {
        return KVM_ERR_NOT_CONNECTED;
    }
    if (!s_encrypted) {
        return KVM_ERR_NOT_CONNECTED;
    }
    if (!subscribed) {
        return KVM_ERR_NOT_SUBSCRIBED;
    }

    struct os_mbuf *om = ble_hs_mbuf_from_flat(data, len);
    if (!om) {
        return KVM_ERR_TX_FAILED;
    }
    int rc = ble_gatts_notify_custom(s_conn_handle, handle, om);
    if (rc != 0) {
        ESP_LOGW(TAG, "notify rc=%d", rc);
        return KVM_ERR_TX_FAILED;
    }
    return 0;
}

uint8_t kvm_ble_send_keyboard(const uint8_t report[8])
{
    memcpy(s_last_kbd, report, sizeof(s_last_kbd));
    return notify(s_hnd_kbd_in, s_sub_kbd, s_last_kbd, sizeof(s_last_kbd));
}

uint8_t kvm_ble_send_mouse(int16_t dx, int16_t dy, uint8_t buttons,
                           int8_t wheel, int8_t pan)
{
    s_last_mouse[0] = (uint8_t)(buttons & 0x1F);
    s_last_mouse[1] = (uint8_t)(dx & 0xFF);
    s_last_mouse[2] = (uint8_t)((dx >> 8) & 0xFF);
    s_last_mouse[3] = (uint8_t)(dy & 0xFF);
    s_last_mouse[4] = (uint8_t)((dy >> 8) & 0xFF);
    s_last_mouse[5] = (uint8_t)wheel;
    s_last_mouse[6] = (uint8_t)pan;
    return notify(s_hnd_mouse_in, s_sub_mouse, s_last_mouse, sizeof(s_last_mouse));
}

uint8_t kvm_ble_send_consumer(uint16_t usage)
{
    s_last_consumer[0] = (uint8_t)(usage & 0xFF);
    s_last_consumer[1] = (uint8_t)((usage >> 8) & 0xFF);
    return notify(s_hnd_consumer_in, s_sub_consumer, s_last_consumer,
                  sizeof(s_last_consumer));
}

uint8_t kvm_ble_release_all(void)
{
    static const uint8_t zero_kbd[8] = { 0 };
    uint8_t first = 0;
    uint8_t rc;

    rc = kvm_ble_send_keyboard(zero_kbd);
    if (rc && !first) {
        first = rc;
    }
    rc = kvm_ble_send_mouse(0, 0, 0, 0, 0);
    if (rc && !first) {
        first = rc;
    }
    rc = kvm_ble_send_consumer(0);
    if (rc && !first) {
        first = rc;
    }
    return first;
}

void kvm_ble_forget_bonds(void)
{
    if (s_conn_handle != BLE_HS_CONN_HANDLE_NONE) {
        ble_gap_terminate(s_conn_handle, BLE_ERR_REM_USER_CONN_TERM);
    }
    int rc = ble_store_clear();
    ESP_LOGW(TAG, "bonds cleared, rc=%d", rc);
    /* The disconnect callback restarts advertising; if we were not connected,
     * we are already advertising and this is a no-op. */
    advertise_start();
}
