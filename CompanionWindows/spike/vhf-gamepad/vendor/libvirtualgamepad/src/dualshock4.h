// Copyright (c) 2026 Chase Payne
// SPDX-License-Identifier: MIT
//
// DualShock 4 profile.
//
// Unlike the Xbox profiles this one is HID-native: Windows, SDL, and Steam all
// speak to a real DS4 as a HID device, so the work is reproducing its report
// layout and the feature reports its initialization paths read. A DS4 that
// answers input reports but not those features enumerates as an anonymous
// gamepad instead of a DualShock 4, which is why the calibration, firmware, and
// pairing features are part of the profile rather than an extra.

#pragma once

#include <cstddef>
#include <cstdint>

#include "libvirtualgamepad/protocol.h"
#include "libvirtualgamepad/ds4_usb.h"

namespace lvg::driver {

inline constexpr std::uint8_t k_ds4_input_report_id = 0x01;
inline constexpr std::uint8_t k_ds4_output_report_id = 0x05;
inline constexpr std::uint8_t k_ds4_feature_calibration_id = 0x02;
inline constexpr std::uint8_t k_ds4_feature_pairing_id = 0x12;
inline constexpr std::uint8_t k_ds4_feature_firmware_id = 0xA3;

inline constexpr std::uint16_t k_ds4_vendor_id = 0x054C;
inline constexpr std::uint16_t k_ds4_product_id = 0x09CC;  // DUALSHOCK 4 v2 (CUH-ZCT2).
inline constexpr std::uint16_t k_ds4_version = 0x0100;

// The touchpad's reporting surface, in the units a real DS4 uses.
inline constexpr std::uint16_t k_ds4_touch_width = 1920;
inline constexpr std::uint16_t k_ds4_touch_height = 942;
inline constexpr std::uint8_t k_ds4_touch_contacts = 2;

// Motion is reported in the device's own units: the accelerometer is 1G per
// 8192 counts and the gyroscope 1 degree/second per 16 counts.
inline constexpr std::int32_t k_ds4_accel_counts_per_g = 8192;
inline constexpr std::int32_t k_ds4_gyro_counts_per_dps = 16;
inline constexpr std::int32_t k_milli_g = 9807;  // Earth gravity in mm/s^2.

#pragma pack(push, 1)

// One touch contact: a 7-bit tracking id with an "inactive" high bit, then two
// 12-bit coordinates packed across three bytes.
struct ds4_touch_point {
  std::uint8_t tracking_id;
  std::uint8_t coordinates[3];
};

struct ds4_touch_packet {
  std::uint8_t timestamp;
  ds4_touch_point points[k_ds4_touch_contacts];
};

struct ds4_input_report {
  std::uint8_t report_id;
  std::uint8_t left_x;
  std::uint8_t left_y;
  std::uint8_t right_x;
  std::uint8_t right_y;
  // Low nibble is the hat (0..7 clockwise from up, 8 released); high nibble is
  // square, cross, circle, triangle.
  std::uint8_t buttons0;
  // L1, R1, L2, R2, Share, Options, L3, R3.
  std::uint8_t buttons1;
  // PS, touchpad click, then a 6-bit report counter.
  std::uint8_t buttons2;
  std::uint8_t left_trigger;
  std::uint8_t right_trigger;
  std::uint16_t timestamp;
  std::uint8_t battery;
  std::int16_t gyro_x;
  std::int16_t gyro_y;
  std::int16_t gyro_z;
  std::int16_t accel_x;
  std::int16_t accel_y;
  std::int16_t accel_z;
  std::uint8_t reserved0[5];
  // Bit 4 marks cable power; the low nibble is the battery level.
  std::uint8_t battery_status;
  std::uint8_t reserved1[2];
  std::uint8_t touch_packet_count;
  ds4_touch_packet touch[3];
  std::uint8_t reserved2[3];
};

struct ds4_output_report {
  std::uint8_t report_id;
  // Bit 0 rumble valid, bit 1 lightbar valid, bit 2 flash valid.
  std::uint8_t flags;
  std::uint8_t reserved0[2];
  std::uint8_t right_rumble;
  std::uint8_t left_rumble;
  std::uint8_t red;
  std::uint8_t green;
  std::uint8_t blue;
  std::uint8_t flash_on;
  std::uint8_t flash_off;
  std::uint8_t reserved1[21];
};

#pragma pack(pop)

static_assert(sizeof(ds4_touch_point) == 4);
static_assert(sizeof(ds4_touch_packet) == 9);
static_assert(sizeof(ds4_input_report) == 64);
static_assert(sizeof(ds4_output_report) == 32);

// As with the DualSense, these are the controller's byte offsets, not ours.
static_assert(offsetof(ds4_output_report, report_id) == 0);
static_assert(offsetof(ds4_output_report, flags) == 1);
static_assert(offsetof(ds4_output_report, right_rumble) == 4);
static_assert(offsetof(ds4_output_report, left_rumble) == 5);
static_assert(offsetof(ds4_output_report, red) == 6);
static_assert(offsetof(ds4_output_report, green) == 7);
static_assert(offsetof(ds4_output_report, blue) == 8);
static_assert(offsetof(ds4_output_report, flash_on) == 9);
static_assert(offsetof(ds4_output_report, flash_off) == 10);

// Per-controller state the profile accumulates between input submissions. A
// DS4 report carries buttons, motion, touch, and battery together, so each of
// those arrives on its own IOCTL and is folded into one report here.
struct ds4_state {
  lvg::ds4_usb::feature_state features;
  std::uint8_t report_counter;
  std::uint16_t timestamp;
  std::uint8_t touch_timestamp;
  std::uint8_t battery_level;
  bool cable_connected;
  bool battery_full;
  std::int16_t gyro[3];
  std::int16_t accel[3];
  // Tracking ids are 7-bit and increment per new contact, which is how a
  // consumer distinguishes a new touch from a moved one.
  std::uint8_t next_tracking_id;
  bool contact_active[k_ds4_touch_contacts];
  std::uint8_t contact_tracking_id[k_ds4_touch_contacts];
  std::uint16_t contact_x[k_ds4_touch_contacts];
  std::uint16_t contact_y[k_ds4_touch_contacts];

  void reset() noexcept;
};

[[nodiscard]] const std::uint8_t *ds4_descriptor(std::size_t *size) noexcept;

[[nodiscard]] ds4_input_report encode_ds4_input(
  const input_state_request &input,
  ds4_state *state) noexcept;

// Folds a touch, motion, or battery event into the accumulated state. Returns
// false when the event cannot be represented by this profile.
[[nodiscard]] bool apply_ds4_touch(const touch_state_request &touch, ds4_state *state) noexcept;
[[nodiscard]] bool apply_ds4_motion(const motion_state_request &motion, ds4_state *state) noexcept;
[[nodiscard]] bool apply_ds4_battery(const battery_state_request &battery, ds4_state *state) noexcept;

[[nodiscard]] bool decode_ds4_output(
  const ds4_output_report &output,
  playstation_output_feedback *feedback) noexcept;

// Applies only fields enabled by the report to a controller's retained output
// state. Use this before coalescing: an LED update must not stop the motors.
[[nodiscard]] bool apply_ds4_output(
  const ds4_output_report &output,
  playstation_output_feedback *state) noexcept;

// Fills a feature report. Returns the number of bytes written, or 0 when the
// report is not one this profile answers.
[[nodiscard]] std::size_t fill_ds4_feature(
  std::uint8_t report_id,
  std::uint8_t *buffer,
  std::size_t capacity,
  const lvg::ds4_usb::feature_state &state = {}) noexcept;

[[nodiscard]] feedback_event encode_playstation_feedback(
  std::uint32_t controller_id,
  const playstation_output_feedback &feedback) noexcept;

}  // namespace lvg::driver
