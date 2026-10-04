// Copyright (c) 2026 Chase Payne
// SPDX-License-Identifier: MIT

#include "xbox_series.h"

#include <cstring>

namespace lvg::driver {
namespace {

// The report shape a real Xbox Series pad presents over HID: unsigned 16-bit
// sticks, 10-bit triggers on the Simulation Controls page, a 1-based hat with a
// null state, fifteen buttons with the vendor's real gaps, and Share as a
// Consumer Record usage. xinputhid.sys reads the device through these usages,
// so the shape is what makes the filter usable rather than merely attached.
constexpr std::uint8_t k_xbox_series_descriptor[] = {
  0x05, 0x01,              // Usage Page (Generic Desktop)
  0x09, 0x05,              // Usage (Game Pad)
  0xA1, 0x01,              // Collection (Application)
  0x85, 0x01,              //   Report ID (1)
  0x09, 0x01,              //   Usage (Pointer)
  0xA1, 0x00,              //   Collection (Physical)
  0x09, 0x30,              //     Usage (X)
  0x09, 0x31,              //     Usage (Y)
  0x15, 0x00,              //     Logical Minimum (0)
  0x27, 0xFF, 0xFF, 0x00, 0x00,  // Logical Maximum (65535)
  0x95, 0x02,              //     Report Count (2)
  0x75, 0x10,              //     Report Size (16)
  0x81, 0x02,              //     Input (Data, Variable, Absolute)
  0xC0,                    //   End Collection
  0x09, 0x01,              //   Usage (Pointer)
  0xA1, 0x00,              //   Collection (Physical)
  0x09, 0x32,              //     Usage (Z)
  0x09, 0x35,              //     Usage (Rz)
  0x15, 0x00,              //     Logical Minimum (0)
  0x27, 0xFF, 0xFF, 0x00, 0x00,  // Logical Maximum (65535)
  0x95, 0x02,              //     Report Count (2)
  0x75, 0x10,              //     Report Size (16)
  0x81, 0x02,              //     Input (Data, Variable, Absolute)
  0xC0,                    //   End Collection
  0x05, 0x02,              //   Usage Page (Simulation Controls)
  0x09, 0xC5,              //   Usage (Brake)
  0x15, 0x00,              //   Logical Minimum (0)
  0x26, 0xFF, 0x03,        //   Logical Maximum (1023)
  0x95, 0x01,              //   Report Count (1)
  0x75, 0x0A,              //   Report Size (10)
  0x81, 0x02,              //   Input (Data, Variable, Absolute)
  0x15, 0x00,              //   Logical Minimum (0)
  0x25, 0x00,              //   Logical Maximum (0)
  0x75, 0x06,              //   Report Size (6)
  0x95, 0x01,              //   Report Count (1)
  0x81, 0x03,              //   Input (Constant, Variable, Absolute)
  0x05, 0x02,              //   Usage Page (Simulation Controls)
  0x09, 0xC4,              //   Usage (Accelerator)
  0x15, 0x00,              //   Logical Minimum (0)
  0x26, 0xFF, 0x03,        //   Logical Maximum (1023)
  0x95, 0x01,              //   Report Count (1)
  0x75, 0x0A,              //   Report Size (10)
  0x81, 0x02,              //   Input (Data, Variable, Absolute)
  0x15, 0x00,              //   Logical Minimum (0)
  0x25, 0x00,              //   Logical Maximum (0)
  0x75, 0x06,              //   Report Size (6)
  0x95, 0x01,              //   Report Count (1)
  0x81, 0x03,              //   Input (Constant, Variable, Absolute)
  0x05, 0x01,              //   Usage Page (Generic Desktop)
  0x09, 0x39,              //   Usage (Hat switch)
  0x15, 0x01,              //   Logical Minimum (1)
  0x25, 0x08,              //   Logical Maximum (8)
  0x35, 0x00,              //   Physical Minimum (0)
  0x46, 0x3B, 0x01,        //   Physical Maximum (315)
  0x66, 0x14, 0x00,        //   Unit (English Rotation: Degrees)
  0x75, 0x04,              //   Report Size (4)
  0x95, 0x01,              //   Report Count (1)
  0x81, 0x42,              //   Input (Data, Variable, Absolute, Null state)
  0x75, 0x04,              //   Report Size (4)
  0x95, 0x01,              //   Report Count (1)
  0x15, 0x00,              //   Logical Minimum (0)
  0x25, 0x00,              //   Logical Maximum (0)
  0x35, 0x00,              //   Physical Minimum (0)
  0x45, 0x00,              //   Physical Maximum (0)
  0x65, 0x00,              //   Unit (None)
  0x81, 0x03,              //   Input (Constant, Variable, Absolute)
  0x05, 0x09,              //   Usage Page (Button)
  0x19, 0x01,              //   Usage Minimum (1)
  0x29, 0x0F,              //   Usage Maximum (15)
  0x15, 0x00,              //   Logical Minimum (0)
  0x25, 0x01,              //   Logical Maximum (1)
  0x75, 0x01,              //   Report Size (1)
  0x95, 0x0F,              //   Report Count (15)
  0x81, 0x02,              //   Input (Data, Variable, Absolute)
  0x15, 0x00,              //   Logical Minimum (0)
  0x25, 0x00,              //   Logical Maximum (0)
  0x75, 0x01,              //   Report Size (1)
  0x95, 0x01,              //   Report Count (1)
  0x81, 0x03,              //   Input (Constant, Variable, Absolute)
  0x05, 0x0C,              //   Usage Page (Consumer)
  0x0A, 0xB2, 0x00,        //   Usage (Record)
  0x15, 0x00,              //   Logical Minimum (0)
  0x25, 0x01,              //   Logical Maximum (1)
  0x95, 0x01,              //   Report Count (1)
  0x75, 0x01,              //   Report Size (1)
  0x81, 0x02,              //   Input (Data, Variable, Absolute)
  0x15, 0x00,              //   Logical Minimum (0)
  0x25, 0x00,              //   Logical Maximum (0)
  0x75, 0x07,              //   Report Size (7)
  0x95, 0x01,              //   Report Count (1)
  0x81, 0x03,              //   Input (Constant, Variable, Absolute)

  // Rumble. Real hardware describes this with Physical Interface Device
  // usages, and four one-byte magnitudes: both trigger motors and both body
  // motors, gated by an actuator-enable mask.
  0x05, 0x0F,              //   Usage Page (Physical Interface Device)
  0x09, 0x21,              //   Usage (Set Effect Report)
  0x85, 0x03,              //   Report ID (3)
  0xA1, 0x02,              //   Collection (Logical)
  0x09, 0x97,              //     Usage (DC Enable Actuators)
  0x15, 0x00,              //     Logical Minimum (0)
  0x25, 0x01,              //     Logical Maximum (1)
  0x75, 0x04,              //     Report Size (4)
  0x95, 0x01,              //     Report Count (1)
  0x91, 0x02,              //     Output (Data, Variable, Absolute)
  0x15, 0x00,              //     Logical Minimum (0)
  0x25, 0x00,              //     Logical Maximum (0)
  0x75, 0x04,              //     Report Size (4)
  0x95, 0x01,              //     Report Count (1)
  0x91, 0x03,              //     Output (Constant, Variable, Absolute)
  0x09, 0x70,              //     Usage (Magnitude)
  0x15, 0x00,              //     Logical Minimum (0)
  0x25, 0x64,              //     Logical Maximum (100)
  0x75, 0x08,              //     Report Size (8)
  0x95, 0x04,              //     Report Count (4)
  0x91, 0x02,              //     Output (Data, Variable, Absolute)
  0x09, 0x50,              //     Usage (Duration)
  0x66, 0x01, 0x10,        //     Unit (SI Linear: Seconds)
  0x55, 0x0E,              //     Unit Exponent (-2)
  0x15, 0x00,              //     Logical Minimum (0)
  0x26, 0xFF, 0x00,        //     Logical Maximum (255)
  0x75, 0x08,              //     Report Size (8)
  0x95, 0x01,              //     Report Count (1)
  0x91, 0x02,              //     Output (Data, Variable, Absolute)
  0x09, 0xA7,              //     Usage (Start Delay)
  0x15, 0x00,              //     Logical Minimum (0)
  0x26, 0xFF, 0x00,        //     Logical Maximum (255)
  0x75, 0x08,              //     Report Size (8)
  0x95, 0x01,              //     Report Count (1)
  0x91, 0x02,              //     Output (Data, Variable, Absolute)
  0x65, 0x00,              //     Unit (None)
  0x55, 0x00,              //     Unit Exponent (0)
  0x09, 0x7C,              //     Usage (Loop Count)
  0x15, 0x00,              //     Logical Minimum (0)
  0x26, 0xFF, 0x00,        //     Logical Maximum (255)
  0x75, 0x08,              //     Report Size (8)
  0x95, 0x01,              //     Report Count (1)
  0x91, 0x02,              //     Output (Data, Variable, Absolute)
  0xC0,                    //   End Collection
  0xC0,                    // End Collection
};

// REG_MULTI_SZ: each ID is null terminated and the list ends with an extra
// null. The specific Series entry comes first so PnP prefers it, with the
// generic GIP software ID behind it as a survivable fallback.
constexpr wchar_t k_xbox_series_hardware_ids[] =
  L"HID\\VID_045E&PID_0B12&IG_00\0"
  L"HID\\VID_045E&PID_02FF&IG_00\0"
  L"\0";

// Clockwise from up, matching the descriptor's 1..8 range. 0 is the null value
// the descriptor declares, so a centred D-pad reports 0 rather than a
// direction.
[[nodiscard]] std::uint8_t encode_hat(const std::uint32_t buttons) noexcept {
  const bool up = (buttons & button_mask::dpad_up) != 0;
  const bool down = (buttons & button_mask::dpad_down) != 0;
  const bool left = (buttons & button_mask::dpad_left) != 0;
  const bool right = (buttons & button_mask::dpad_right) != 0;

  if ((up && down) || (left && right)) {
    return 0;
  }
  if (up) {
    return right ? 2 : (left ? 8 : 1);
  }
  if (down) {
    return right ? 4 : (left ? 6 : 5);
  }
  return right ? 3 : (left ? 7 : 0);
}

[[nodiscard]] std::uint16_t map_buttons(const std::uint32_t buttons) noexcept {
  std::uint16_t mapped = 0;
  if (buttons & button_mask::south) {
    mapped |= xbox_a;
  }
  if (buttons & button_mask::east) {
    mapped |= xbox_b;
  }
  if (buttons & button_mask::west) {
    mapped |= xbox_x;
  }
  if (buttons & button_mask::north) {
    mapped |= xbox_y;
  }
  if (buttons & button_mask::left_shoulder) {
    mapped |= xbox_left_shoulder;
  }
  if (buttons & button_mask::right_shoulder) {
    mapped |= xbox_right_shoulder;
  }
  if (buttons & button_mask::back) {
    mapped |= xbox_view;
  }
  if (buttons & button_mask::start) {
    mapped |= xbox_menu;
  }
  if (buttons & button_mask::home) {
    mapped |= xbox_guide;
  }
  if (buttons & button_mask::left_stick) {
    mapped |= xbox_left_stick;
  }
  if (buttons & button_mask::right_stick) {
    mapped |= xbox_right_stick;
  }
  return mapped;
}

// Vibeshine's sticks are signed and positive-up; this device's are unsigned
// and, for the vertical axes, positive-down.
[[nodiscard]] std::uint16_t to_unsigned_axis(const std::int16_t value) noexcept {
  return static_cast<std::uint16_t>(static_cast<std::int32_t>(value) + 32768);
}

[[nodiscard]] std::uint16_t to_unsigned_vertical_axis(const std::int16_t value) noexcept {
  return static_cast<std::uint16_t>(32767 - static_cast<std::int32_t>(value));
}

[[nodiscard]] std::uint16_t to_trigger(const std::uint8_t value) noexcept {
  return static_cast<std::uint16_t>((static_cast<std::uint32_t>(value) * k_xbox_trigger_max) / 255u);
}

// Rumble magnitudes are a 0..100 percentage on the wire.
[[nodiscard]] std::uint16_t from_rumble_percent(const std::uint8_t value) noexcept {
  const std::uint32_t clamped = value > k_xbox_rumble_max ? k_xbox_rumble_max : value;
  return static_cast<std::uint16_t>((clamped * 65535u) / k_xbox_rumble_max);
}

}  // namespace

const std::uint8_t *xbox_series_descriptor(std::size_t *const size) noexcept {
  if (size != nullptr) {
    *size = sizeof(k_xbox_series_descriptor);
  }
  return k_xbox_series_descriptor;
}

const wchar_t *xbox_series_hardware_ids(std::size_t *const bytes) noexcept {
  if (bytes != nullptr) {
    *bytes = sizeof(k_xbox_series_hardware_ids);
  }
  return k_xbox_series_hardware_ids;
}

xbox_series_input_report encode_xbox_series_input(const input_state_request &input) noexcept {
  xbox_series_input_report report {};
  report.report_id = k_xbox_series_input_report_id;
  report.left_x = to_unsigned_axis(input.left_x);
  report.left_y = to_unsigned_vertical_axis(input.left_y);
  report.right_x = to_unsigned_axis(input.right_x);
  report.right_y = to_unsigned_vertical_axis(input.right_y);
  report.left_trigger = to_trigger(input.left_trigger);
  report.right_trigger = to_trigger(input.right_trigger);
  report.hat = encode_hat(input.buttons);
  report.buttons = map_buttons(input.buttons);
  // Either the client's dedicated Share button or the misc button maps here;
  // both mean "the extra capture button" to a Moonlight client.
  report.share = (input.buttons & (button_mask::misc | button_mask::touchpad)) != 0 ? 1u : 0u;
  return report;
}

bool decode_xbox_series_output(
  const xbox_series_output_report &output,
  xbox_rumble_feedback *const rumble) noexcept {
  if (rumble == nullptr || output.report_id != k_xbox_series_output_report_id) {
    return false;
  }

  // An actuator with its enable bit clear keeps its previous state on real
  // hardware, but reporting a stale magnitude as current would be worse than
  // reporting silence, so a disabled actuator reads as zero.
  const bool left_motor = (output.enable_mask & k_xbox_enable_left_motor) != 0;
  const bool right_motor = (output.enable_mask & k_xbox_enable_right_motor) != 0;
  const bool left_trigger = (output.enable_mask & k_xbox_enable_left_trigger) != 0;
  const bool right_trigger = (output.enable_mask & k_xbox_enable_right_trigger) != 0;

  rumble->low_frequency = left_motor ? from_rumble_percent(output.left_motor) : 0;
  rumble->high_frequency = right_motor ? from_rumble_percent(output.right_motor) : 0;
  rumble->left_trigger = left_trigger ? from_rumble_percent(output.left_trigger_motor) : 0;
  rumble->right_trigger = right_trigger ? from_rumble_percent(output.right_trigger_motor) : 0;
  return true;
}

feedback_event encode_xbox_series_feedback(
  const std::uint32_t controller_id,
  const xbox_rumble_feedback &rumble) noexcept {
  feedback_event event {};
  event.header.size = sizeof(event);
  event.header.version = k_protocol_version;
  event.controller_id = controller_id;
  event.type = feedback_type::xbox_rumble;
  event.payload_size = sizeof(rumble);
  std::memcpy(event.payload, &rumble, sizeof(rumble));
  return event;
}

}  // namespace lvg::driver
