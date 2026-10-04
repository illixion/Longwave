// Copyright (c) 2026 Chase Payne
// SPDX-License-Identifier: MIT
//
// DualSense profile. HID-native like the DualShock 4, with the same
// requirement that the feature reports its host-side initialization reads are
// answered, plus the adaptive trigger programs and the player/microphone LEDs
// that only exist on this device.
//
// The output report layout is the risky part of this profile: a consumer that
// recognizes the identity writes the console's real report shape through
// HIDAPI rather than anything derived from our descriptor, so the offsets below
// have to match hardware. They follow the layout the mainline Linux
// hid-playstation driver documents.

#pragma once

#include <cstddef>
#include <cstdint>

#include "libvirtualgamepad/protocol.h"
#include "libvirtualgamepad/ds5_usb.h"

namespace lvg::driver {

inline constexpr std::uint8_t k_ds5_input_report_id = 0x01;
inline constexpr std::uint8_t k_ds5_output_report_id = 0x02;
inline constexpr std::uint8_t k_ds5_output_report_id_bt = 0x31;
inline constexpr std::uint8_t k_ds5_feature_calibration_id = 0x05;
inline constexpr std::uint8_t k_ds5_feature_pairing_id = 0x09;
inline constexpr std::uint8_t k_ds5_feature_firmware_id = 0x20;

inline constexpr std::uint16_t k_ds5_vendor_id = 0x054C;
inline constexpr std::uint16_t k_ds5_product_id = 0x0CE6;  // DualSense (CFI-ZCT1).
inline constexpr std::uint16_t k_ds5_version = 0x0100;

inline constexpr std::uint16_t k_ds5_touch_width = 1920;
inline constexpr std::uint16_t k_ds5_touch_height = 1080;
inline constexpr std::uint8_t k_ds5_touch_contacts = 2;

// Output validity bits, named as the console's report defines them.
inline constexpr std::uint8_t k_ds5_flag0_compatible_vibration = 0x01;
inline constexpr std::uint8_t k_ds5_flag0_haptics_select = 0x02;
inline constexpr std::uint8_t k_ds5_flag0_right_trigger_effect = 0x04;
inline constexpr std::uint8_t k_ds5_flag0_left_trigger_effect = 0x08;
inline constexpr std::uint8_t k_ds5_flag1_mic_mute_led = 0x01;
inline constexpr std::uint8_t k_ds5_flag1_power_save = 0x02;
inline constexpr std::uint8_t k_ds5_flag1_lightbar = 0x04;
inline constexpr std::uint8_t k_ds5_flag1_release_leds = 0x08;
inline constexpr std::uint8_t k_ds5_flag1_player_indicator = 0x10;
inline constexpr std::uint8_t k_ds5_flag2_compatible_vibration = 0x04;

#pragma pack(push, 1)

struct ds5_touch_point {
  std::uint8_t contact;
  std::uint8_t coordinates[3];
};

struct ds5_input_report {
  std::uint8_t report_id;
  std::uint8_t left_x;
  std::uint8_t left_y;
  std::uint8_t right_x;
  std::uint8_t right_y;
  std::uint8_t left_trigger;
  std::uint8_t right_trigger;
  std::uint8_t sequence;
  // [0] hat + face buttons, [1] shoulders/triggers/create/options/sticks,
  // [2] PS, touchpad, mute.
  std::uint8_t buttons[4];
  std::uint8_t reserved0[4];
  std::int16_t gyro[3];
  std::int16_t accel[3];
  std::uint32_t sensor_timestamp;
  std::uint8_t reserved1;
  ds5_touch_point touch[k_ds5_touch_contacts];
  std::uint8_t reserved2[12];
  // Low nibble battery level, high nibble charging state.
  std::uint8_t status;
  std::uint8_t reserved3[10];
};

struct ds5_trigger_effect {
  std::uint8_t mode;
  std::uint8_t parameters[10];
};

struct ds5_output_report {
  std::uint8_t report_id;
  std::uint8_t valid_flag0;
  std::uint8_t valid_flag1;
  std::uint8_t motor_right;
  std::uint8_t motor_left;
  std::uint8_t reserved0[4];
  std::uint8_t mute_button_led;
  std::uint8_t power_save_control;
  ds5_trigger_effect right_trigger;
  ds5_trigger_effect left_trigger;
  std::uint8_t reserved1[6];
  std::uint8_t valid_flag2;
  std::uint8_t reserved2[2];
  std::uint8_t lightbar_setup;
  std::uint8_t led_brightness;
  std::uint8_t player_leds;
  std::uint8_t lightbar_red;
  std::uint8_t lightbar_green;
  std::uint8_t lightbar_blue;
};

#pragma pack(pop)

static_assert(sizeof(ds5_touch_point) == 4);
static_assert(sizeof(ds5_input_report) == 64);
static_assert(sizeof(ds5_trigger_effect) == 11);
static_assert(sizeof(ds5_output_report) == 48);

// Output-report field positions, checked against the byte offsets a DualSense
// actually uses rather than against this struct's own layout. Sizes alone do
// not catch a transposed pair of fields, and nothing about a wrong offset is
// visible at runtime: the light bar simply lights the wrong colour or a rumble
// motor never spins.
static_assert(offsetof(ds5_output_report, report_id) == 0);
static_assert(offsetof(ds5_output_report, valid_flag0) == 1);
static_assert(offsetof(ds5_output_report, valid_flag1) == 2);
static_assert(offsetof(ds5_output_report, motor_right) == 3);
static_assert(offsetof(ds5_output_report, motor_left) == 4);
static_assert(offsetof(ds5_output_report, mute_button_led) == 9);
static_assert(offsetof(ds5_output_report, power_save_control) == 10);
// Right precedes left, matching the order of the two enable bits in flag0.
static_assert(offsetof(ds5_output_report, right_trigger) == 11);
static_assert(offsetof(ds5_output_report, left_trigger) == 22);
static_assert(offsetof(ds5_output_report, valid_flag2) == 39);
static_assert(offsetof(ds5_output_report, lightbar_setup) == 42);
static_assert(offsetof(ds5_output_report, led_brightness) == 43);
static_assert(offsetof(ds5_output_report, player_leds) == 44);
static_assert(offsetof(ds5_output_report, lightbar_red) == 45);
static_assert(offsetof(ds5_output_report, lightbar_green) == 46);
static_assert(offsetof(ds5_output_report, lightbar_blue) == 47);

struct ds5_state {
  lvg::ds5_usb::feature_state features;
  std::uint8_t sequence;
  std::uint32_t sensor_timestamp;
  std::uint8_t battery_level;
  bool cable_connected;
  bool battery_full;
  std::int16_t gyro[3];
  std::int16_t accel[3];
  std::uint8_t next_tracking_id;
  bool contact_active[k_ds5_touch_contacts];
  std::uint8_t contact_tracking_id[k_ds5_touch_contacts];
  std::uint16_t contact_x[k_ds5_touch_contacts];
  std::uint16_t contact_y[k_ds5_touch_contacts];

  void reset() noexcept;
};

[[nodiscard]] const std::uint8_t *ds5_descriptor(std::size_t *size) noexcept;

[[nodiscard]] ds5_input_report encode_ds5_input(
  const input_state_request &input,
  ds5_state *state) noexcept;

[[nodiscard]] bool apply_ds5_touch(const touch_state_request &touch, ds5_state *state) noexcept;
[[nodiscard]] bool apply_ds5_motion(const motion_state_request &motion, ds5_state *state) noexcept;
[[nodiscard]] bool apply_ds5_battery(const battery_state_request &battery, ds5_state *state) noexcept;

[[nodiscard]] bool decode_ds5_output(
  const ds5_output_report &output,
  playstation_output_feedback *feedback) noexcept;

// Retains fields absent from this report, including the other trigger's
// program. A trigger is disabled by an explicit enabled report with mode off.
[[nodiscard]] bool apply_ds5_output(
  const ds5_output_report &output,
  playstation_output_feedback *state) noexcept;

[[nodiscard]] std::size_t fill_ds5_feature(
  std::uint8_t report_id,
  std::uint8_t *buffer,
  std::size_t capacity,
  const lvg::ds5_usb::feature_state &state = {}) noexcept;

}  // namespace lvg::driver
