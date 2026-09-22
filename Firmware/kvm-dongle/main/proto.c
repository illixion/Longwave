#include "proto.h"

#include <string.h>

uint8_t kvm_crc8(const uint8_t *data, size_t len)
{
    uint8_t crc = 0x00;
    for (size_t i = 0; i < len; i++) {
        crc ^= data[i];
        for (int b = 0; b < 8; b++) {
            crc = (crc & 0x80) ? (uint8_t)((crc << 1) ^ 0x07) : (uint8_t)(crc << 1);
        }
    }
    return crc;
}

size_t kvm_frame_encode(uint8_t *out, uint8_t type, const uint8_t *payload,
                        uint8_t len)
{
    if (len > KVM_MAX_PAYLOAD) {
        return 0;
    }
    out[0] = KVM_SOF;
    out[1] = type;
    out[2] = len;
    if (len && payload) {
        memcpy(&out[3], payload, len);
    }
    out[3 + len] = kvm_crc8(&out[1], (size_t)len + 2u);
    return (size_t)len + 4u;
}

void kvm_parser_reset(kvm_parser_t *p)
{
    p->state = KVM_PS_SOF;
    p->type = 0;
    p->len = 0;
    p->idx = 0;
}

void kvm_parser_feed(kvm_parser_t *p, const uint8_t *data, size_t len,
                     kvm_frame_cb_t cb, void *arg)
{
    for (size_t i = 0; i < len; i++) {
        uint8_t c = data[i];

        switch (p->state) {
        case KVM_PS_SOF:
            /* Everything that is not a start byte is ignored. This is what
             * lets ESP_LOG console output share the same UART: log lines are
             * ASCII and never contain 0xA5. */
            if (c == KVM_SOF) {
                p->state = KVM_PS_TYPE;
            }
            break;

        case KVM_PS_TYPE:
            p->type = c;
            p->state = KVM_PS_LEN;
            break;

        case KVM_PS_LEN:
            if (c > KVM_MAX_PAYLOAD) {
                /* Bogus length: this was not a frame. Resynchronise. */
                kvm_parser_reset(p);
                if (c == KVM_SOF) {
                    p->state = KVM_PS_TYPE;
                }
                break;
            }
            p->len = c;
            p->idx = 0;
            p->state = p->len ? KVM_PS_PAYLOAD : KVM_PS_CRC;
            break;

        case KVM_PS_PAYLOAD:
            p->payload[p->idx++] = c;
            if (p->idx >= p->len) {
                p->state = KVM_PS_CRC;
            }
            break;

        case KVM_PS_CRC: {
            uint8_t hdr[2] = { p->type, p->len };
            uint8_t crc = kvm_crc8(hdr, 2);
            /* Continue the CRC over the payload. */
            for (uint8_t k = 0; k < p->len; k++) {
                crc ^= p->payload[k];
                for (int b = 0; b < 8; b++) {
                    crc = (crc & 0x80) ? (uint8_t)((crc << 1) ^ 0x07)
                                       : (uint8_t)(crc << 1);
                }
            }
            if (cb) {
                cb(p->type, p->payload, p->len, crc == c, arg);
            }
            kvm_parser_reset(p);
            break;
        }

        default:
            kvm_parser_reset(p);
            break;
        }
    }
}
