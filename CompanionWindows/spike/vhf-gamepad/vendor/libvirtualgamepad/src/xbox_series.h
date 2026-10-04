// Copyright (c) 2026 Chase Payne
// SPDX-License-Identifier: MIT
//
// Xbox Series-shaped HID gamepad.
//
// This is the profile that reaches XInput. Windows ships xinputhid.sys as a
// *filter* driver, not a bus driver: C:\Windows\INF\xinputhid.inf attaches it
// to any HID device whose hardware ID appears in its match list
// (HID\VID_045E&PID_xxxx&IG_00). VHF_CONFIG carries a HardwareIDs field, so a
// VHF child can carry a matching ID and pick up the filter, which is what makes
// it an XInput device. No bus driver is involved.
//
// The identity alone is not the point and would not be honest on its own: the
// report layout, trigger resolution, hat encoding, and rumble payload below are
// the shapes a real Xbox Series pad presents over HID, derived from Microsoft's
// published INF match list and public HID descriptor documentation. Xbox 360 is
// still out of reach for a different reason - a real 360 pad is an XUSB device
// on a USB bus, which needs a bus child that VHF cannot create.

#pragma once

#include <cstddef>
#include <cstdint>

#include "libvirtualgamepad/protocol.h"

namespace lvg::driver {

inline constexpr std::uint8_t k_xbox_series_input_report_id = 1;
inline constexpr std::uint8_t k_xbox_series_output_report_id = 3;

// The identity a real Xbox Series controller presents, plus the generic GIP
// software product ID that xinputhid.inf also matches. Both are offered so the
// filter still attaches if Microsoft retires the specific entry.
inline constexpr std::uint16_t k_xbox_vendor_id = 0x045E;
inline constexpr std::uint16_t k_xbox_series_product_id = 0x0B12;
inline constexpr std::uint16_t k_xbox_gip_software_product_id = 0x02FF;
inline constexpr std::uint16_t k_xbox_series_version = 0x0509;

// Triggers are 10-bit on this device, not 8-bit.
inline constexpr std::uint16_t k_xbox_trigger_max = 1023;

// Rumble magnitudes are a percentage, and the enable mask selects actuators.
inline constexpr std::uint8_t k_xbox_rumble_max = 100;
inline constexpr std::uint8_t k_xbox_enable_right_trigger = 0x01;
inline constexpr std::uint8_t k_xbox_enable_left_trigger = 0x02;
inline constexpr std::uint8_t k_xbox_enable_right_motor = 0x04;
inline constexpr std::uint8_t k_xbox_enable_left_motor = 0x08;

// Button bit positions inside the 15-bit button field, in HID button order.
// Buttons 3, 6, 9, and 10 are unpopulated on this device; the gaps are real and
// applications that match on button numbers depend on them.
enum xbox_series_button : std::uint16_t {
  xbox_a = 1u << 0,
  xbox_b = 1u << 1,
  xbox_x = 1u << 3,
  xbox_y = 1u << 4,
  xbox_left_shoulder = 1u << 6,
  xbox_right_shoulder = 1u << 7,
  xbox_view = 1u << 10,
  xbox_menu = 1u << 11,
  xbox_guide = 1u << 12,
  xbox_left_stick = 1u << 13,
  xbox_right_stick = 1u << 14,
};

#pragma pack(push, 1)

struct xbox_series_input_report {
  std::uint8_t report_id;
  std::uint16_t left_x;
  std::uint16_t left_y;
  std::uint16_t right_x;
  std::uint16_t right_y;
  // 10 significant bits each, the rest declared as padding in the descriptor.
  std::uint16_t left_trigger;
  std::uint16_t right_trigger;
  // 4-bit hat in the low nibble; 0 is the null (centred) value, 1..8 clockwise
  // from up. This differs from the generic profile, which is 0-based.
  std::uint8_t hat;
  // 15 button bits, then one padding bit.
  std::uint16_t buttons;
  // The Share button is a Consumer "Record" usage on real hardware, not a
  // gamepad button, so it occupies its own byte.
  std::uint8_t share;
};

struct xbox_series_output_report {
  std::uint8_t report_id;
  std::uint8_t enable_mask;
  std::uint8_t left_trigger_motor;
  std::uint8_t right_trigger_motor;
  std::uint8_t left_motor;
  std::uint8_t right_motor;
  std::uint8_t duration;
  std::uint8_t start_delay;
  std::uint8_t loop_count;
};

#pragma pack(pop)

static_assert(sizeof(xbox_series_input_report) == 17);
static_assert(sizeof(xbox_series_output_report) == 9);

// The Xbox Series report descriptor.
[[nodiscard]] const std::uint8_t *xbox_series_descriptor(std::size_t *size) noexcept;

// A REG_MULTI_SZ hardware ID list for VHF_CONFIG.HardwareIDs. `bytes` receives
// the length including both terminators.
[[nodiscard]] const wchar_t *xbox_series_hardware_ids(std::size_t *bytes) noexcept;

[[nodiscard]] xbox_series_input_report encode_xbox_series_input(
  const input_state_request &input) noexcept;

// Decodes a rumble write. Returns false when the report is not a rumble write
// this profile understands.
[[nodiscard]] bool decode_xbox_series_output(
  const xbox_series_output_report &output,
  xbox_rumble_feedback *rumble) noexcept;

[[nodiscard]] feedback_event encode_xbox_series_feedback(
  std::uint32_t controller_id,
  const xbox_rumble_feedback &rumble) noexcept;

}  // namespace lvg::driver
