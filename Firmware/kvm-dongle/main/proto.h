/*
 * Longwave KVM dongle — USB serial command protocol.
 *
 * Wire format (see PROTOCOL.md for the normative description):
 *
 *   +------+------+-----+--------------+------+
 *   | 0xA5 | TYPE | LEN | PAYLOAD[LEN] | CRC8 |
 *   +------+------+-----+--------------+------+
 *
 * CRC8 covers TYPE, LEN and PAYLOAD (not the start byte).
 * Poly 0x07, init 0x00, no reflection, no final XOR.
 */
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define KVM_SOF          0xA5u
#define KVM_MAX_PAYLOAD  64u
#define KVM_MAX_FRAME    (4u + KVM_MAX_PAYLOAD)

/* ---- host -> dongle ---------------------------------------------------- */
#define KVM_CMD_PING           0x01u /* len 0..4, payload echoed in the ack  */
#define KVM_CMD_GET_STATUS     0x02u /* len 0                                */
#define KVM_CMD_KEY_REPORT     0x03u /* len 8: raw boot-protocol kbd report  */
#define KVM_CMD_MOUSE_MOVE     0x04u /* len 7: dx16 dy16 btn wheel8 pan8     */
#define KVM_CMD_MOUSE_BUTTONS  0x05u /* len 1: button bitmap                 */
#define KVM_CMD_CONSUMER       0x06u /* len 3: usage16 pressed8              */
#define KVM_CMD_RELEASE_ALL    0x07u /* len 0                                */
#define KVM_CMD_FORGET_BONDS   0x08u /* len 0                                */

/* ---- dongle -> host ---------------------------------------------------- */
#define KVM_RSP_ACK      0x81u /* payload: [cmd] (+ echo for PING)           */
#define KVM_RSP_NACK     0x82u /* payload: [cmd, err]                        */
#define KVM_RSP_STATUS   0x83u /* payload: 16-byte status block              */
#define KVM_RSP_EVENT    0x85u /* payload: [event, data...] (unsolicited)    */

/* ---- NACK error codes -------------------------------------------------- */
#define KVM_ERR_CRC            0x01u
#define KVM_ERR_LENGTH         0x02u
#define KVM_ERR_UNKNOWN_CMD    0x03u
#define KVM_ERR_NOT_CONNECTED  0x04u
#define KVM_ERR_NOT_SUBSCRIBED 0x05u
#define KVM_ERR_TX_FAILED      0x06u
#define KVM_ERR_BAD_PAYLOAD    0x07u

/* ---- asynchronous event codes ------------------------------------------ */
#define KVM_EV_BOOT          0x01u /* payload: proto ver, fw major/minor/patch */
#define KVM_EV_ADVERTISING   0x02u /* payload: none                            */
#define KVM_EV_CONNECTED     0x03u /* payload: none                            */
#define KVM_EV_ENCRYPTED     0x04u /* payload: [bonded(0/1)]                    */
#define KVM_EV_DISCONNECTED  0x05u /* payload: [hci reason low byte]           */
#define KVM_EV_LED_STATE     0x06u /* payload: [keyboard LED bitmap]           */
#define KVM_EV_SUBSCRIBED    0x07u /* payload: [subscription bitmap]           */

/* ---- status flags (byte 5 of the status block) ------------------------- */
#define KVM_FLAG_CONNECTED    (1u << 0)
#define KVM_FLAG_ENCRYPTED    (1u << 1)
#define KVM_FLAG_ADVERTISING  (1u << 2)
#define KVM_FLAG_HAS_BOND     (1u << 3)
#define KVM_FLAG_SUB_KEYBOARD (1u << 4)
#define KVM_FLAG_SUB_MOUSE    (1u << 5)
#define KVM_FLAG_SUB_CONSUMER (1u << 6)

/* ---- link state (byte 4 of the status block) --------------------------- */
#define KVM_STATE_IDLE        0u
#define KVM_STATE_ADVERTISING 1u
#define KVM_STATE_CONNECTED   2u /* connected, link not yet encrypted */
#define KVM_STATE_READY       3u /* connected + encrypted, reports will flow */

uint8_t kvm_crc8(const uint8_t *data, size_t len);

/*
 * Build a complete frame into `out` (must hold at least KVM_MAX_FRAME bytes).
 * Returns the number of bytes written, or 0 if `len` is out of range.
 */
size_t kvm_frame_encode(uint8_t *out, uint8_t type, const uint8_t *payload,
                        uint8_t len);

/* ---- incremental parser ------------------------------------------------ */

typedef enum {
    KVM_PS_SOF = 0,
    KVM_PS_TYPE,
    KVM_PS_LEN,
    KVM_PS_PAYLOAD,
    KVM_PS_CRC,
} kvm_parse_state_t;

typedef struct {
    kvm_parse_state_t state;
    uint8_t type;
    uint8_t len;
    uint8_t idx;
    uint8_t payload[KVM_MAX_PAYLOAD];
} kvm_parser_t;

/*
 * Called once per candidate frame. `crc_ok` is false when the checksum did not
 * match, in which case the payload should not be acted on (the dongle answers
 * with a NACK carrying KVM_ERR_CRC).
 */
typedef void (*kvm_frame_cb_t)(uint8_t type, const uint8_t *payload,
                               uint8_t len, bool crc_ok, void *arg);

void kvm_parser_reset(kvm_parser_t *p);
void kvm_parser_feed(kvm_parser_t *p, const uint8_t *data, size_t len,
                     kvm_frame_cb_t cb, void *arg);
