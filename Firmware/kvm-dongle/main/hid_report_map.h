/*
 * Longwave KVM dongle — HID report descriptor.
 *
 * ============================== DO NOT EDIT ==============================
 * visionOS (like iOS and macOS) caches this descriptor at pairing time and
 * keeps using the cached copy for the life of the bond. Changing a single
 * byte here without changing the bond makes the headset interpret new reports
 * with the old layout — silently, with no error anywhere. If this descriptor
 * ever has to change, bump KVM_REPORT_MAP_REVISION below, and the user must
 * "Forget This Device" on the headset and pair again.
 * =========================================================================
 *
 * One report map, three top-level application collections:
 *
 *   Report ID 1 — Keyboard
 *       Input  (8 bytes): modifiers, reserved, keycode[6]   (boot-protocol
 *                         compatible layout)
 *       Output (1 byte) : 5 LED bits + 3 bits padding
 *   Report ID 2 — Mouse
 *       Input  (7 bytes): 5 buttons + 3 pad, int16 X, int16 Y,
 *                         int8 wheel, int8 AC Pan
 *   Report ID 3 — Consumer control
 *       Input  (2 bytes): one 16-bit usage from the Consumer page
 */
#pragma once

#include <stdint.h>

#define KVM_REPORT_MAP_REVISION 1

#define KVM_RPT_ID_KEYBOARD 0x01
#define KVM_RPT_ID_MOUSE    0x02
#define KVM_RPT_ID_CONSUMER 0x03

#define KVM_RPT_LEN_KEYBOARD_IN  8
#define KVM_RPT_LEN_KEYBOARD_OUT 1
#define KVM_RPT_LEN_MOUSE_IN     7
#define KVM_RPT_LEN_CONSUMER_IN  2

static const uint8_t kvm_hid_report_map[] = {
    /* ---------------- Report ID 1: Keyboard ---------------- */
    0x05, 0x01,       /* Usage Page (Generic Desktop)          */
    0x09, 0x06,       /* Usage (Keyboard)                      */
    0xA1, 0x01,       /* Collection (Application)              */
    0x85, KVM_RPT_ID_KEYBOARD, /*   Report ID (1)              */

    /*   modifier byte: 8 individual bits, LeftCtrl..RightGUI  */
    0x05, 0x07,       /*   Usage Page (Keyboard/Keypad)        */
    0x19, 0xE0,       /*   Usage Minimum (0xE0, LeftControl)   */
    0x29, 0xE7,       /*   Usage Maximum (0xE7, Right GUI)     */
    0x15, 0x00,       /*   Logical Minimum (0)                 */
    0x25, 0x01,       /*   Logical Maximum (1)                 */
    0x75, 0x01,       /*   Report Size (1)                     */
    0x95, 0x08,       /*   Report Count (8)                    */
    0x81, 0x02,       /*   Input (Data, Variable, Absolute)    */

    /*   reserved byte                                         */
    0x95, 0x01,       /*   Report Count (1)                    */
    0x75, 0x08,       /*   Report Size (8)                     */
    0x81, 0x03,       /*   Input (Constant, Variable, Absolute)*/

    /*   host -> device LED output report                      */
    0x95, 0x05,       /*   Report Count (5)                    */
    0x75, 0x01,       /*   Report Size (1)                     */
    0x05, 0x08,       /*   Usage Page (LEDs)                   */
    0x19, 0x01,       /*   Usage Minimum (Num Lock)            */
    0x29, 0x05,       /*   Usage Maximum (Kana)                */
    0x91, 0x02,       /*   Output (Data, Variable, Absolute)   */
    0x95, 0x01,       /*   Report Count (1)                    */
    0x75, 0x03,       /*   Report Size (3)                     */
    0x91, 0x03,       /*   Output (Const, Variable, Absolute)  */

    /*   six simultaneous keycodes                             */
    0x95, 0x06,       /*   Report Count (6)                    */
    0x75, 0x08,       /*   Report Size (8)                     */
    0x15, 0x00,       /*   Logical Minimum (0)                 */
    0x26, 0xFF, 0x00, /*   Logical Maximum (255)               */
    0x05, 0x07,       /*   Usage Page (Keyboard/Keypad)        */
    0x19, 0x00,       /*   Usage Minimum (0)                   */
    0x2A, 0xFF, 0x00, /*   Usage Maximum (255)                 */
    0x81, 0x00,       /*   Input (Data, Array, Absolute)       */
    0xC0,             /* End Collection                        */

    /* ---------------- Report ID 2: Mouse ------------------- */
    0x05, 0x01,       /* Usage Page (Generic Desktop)          */
    0x09, 0x02,       /* Usage (Mouse)                         */
    0xA1, 0x01,       /* Collection (Application)              */
    0x85, KVM_RPT_ID_MOUSE, /*   Report ID (2)                 */
    0x09, 0x01,       /*   Usage (Pointer)                     */
    0xA1, 0x00,       /*   Collection (Physical)               */

    /*     5 buttons + 3 bits padding                          */
    0x05, 0x09,       /*     Usage Page (Button)               */
    0x19, 0x01,       /*     Usage Minimum (Button 1)          */
    0x29, 0x05,       /*     Usage Maximum (Button 5)          */
    0x15, 0x00,       /*     Logical Minimum (0)               */
    0x25, 0x01,       /*     Logical Maximum (1)               */
    0x95, 0x05,       /*     Report Count (5)                  */
    0x75, 0x01,       /*     Report Size (1)                   */
    0x81, 0x02,       /*     Input (Data, Variable, Absolute)  */
    0x95, 0x01,       /*     Report Count (1)                  */
    0x75, 0x03,       /*     Report Size (3)                   */
    0x81, 0x03,       /*     Input (Const, Variable, Absolute) */

    /*     X / Y as signed 16-bit relative deltas              */
    0x05, 0x01,       /*     Usage Page (Generic Desktop)      */
    0x09, 0x30,       /*     Usage (X)                         */
    0x09, 0x31,       /*     Usage (Y)                         */
    0x16, 0x01, 0x80, /*     Logical Minimum (-32767)          */
    0x26, 0xFF, 0x7F, /*     Logical Maximum (32767)           */
    0x75, 0x10,       /*     Report Size (16)                  */
    0x95, 0x02,       /*     Report Count (2)                  */
    0x81, 0x06,       /*     Input (Data, Variable, Relative)  */

    /*     vertical wheel                                      */
    0x09, 0x38,       /*     Usage (Wheel)                     */
    0x15, 0x81,       /*     Logical Minimum (-127)            */
    0x25, 0x7F,       /*     Logical Maximum (127)             */
    0x75, 0x08,       /*     Report Size (8)                   */
    0x95, 0x01,       /*     Report Count (1)                  */
    0x81, 0x06,       /*     Input (Data, Variable, Relative)  */

    /*     horizontal pan                                      */
    0x05, 0x0C,       /*     Usage Page (Consumer)             */
    0x0A, 0x38, 0x02, /*     Usage (AC Pan)                    */
    0x15, 0x81,       /*     Logical Minimum (-127)            */
    0x25, 0x7F,       /*     Logical Maximum (127)             */
    0x75, 0x08,       /*     Report Size (8)                   */
    0x95, 0x01,       /*     Report Count (1)                  */
    0x81, 0x06,       /*     Input (Data, Variable, Relative)  */
    0xC0,             /*   End Collection (Physical)           */
    0xC0,             /* End Collection (Application)          */

    /* ------------- Report ID 3: Consumer control ----------- */
    0x05, 0x0C,       /* Usage Page (Consumer)                 */
    0x09, 0x01,       /* Usage (Consumer Control)              */
    0xA1, 0x01,       /* Collection (Application)              */
    0x85, KVM_RPT_ID_CONSUMER, /*   Report ID (3)              */
    0x15, 0x00,       /*   Logical Minimum (0)                 */
    0x26, 0xFF, 0x03, /*   Logical Maximum (0x03FF)            */
    0x19, 0x00,       /*   Usage Minimum (0)                   */
    0x2A, 0xFF, 0x03, /*   Usage Maximum (0x03FF)              */
    0x75, 0x10,       /*   Report Size (16)                    */
    0x95, 0x01,       /*   Report Count (1)                    */
    0x81, 0x00,       /*   Input (Data, Array, Absolute)       */
    0xC0,             /* End Collection                        */
};

#define KVM_HID_REPORT_MAP_LEN (sizeof(kvm_hid_report_map))
