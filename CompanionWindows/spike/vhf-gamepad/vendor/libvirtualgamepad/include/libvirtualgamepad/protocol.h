// Copyright (c) 2026 Chase Payne
// SPDX-License-Identifier: MIT
//
// The control-device ABI shared by Vibeshine and the UMDF VHF source driver.
// Keep every request fixed-size and METHOD_BUFFERED. Do not add pointers,
// handles, strings, or compiler-sized fields to this wire contract.

#pragma once

#include <cstddef>
#include <cstdint>

#include <windows.h>
#include <winioctl.h>

namespace lvg {

// Version 2 widened the feedback payload: a DualSense adaptive-trigger update
// is 23 bytes and could not be expressed in version 1's 16-byte payload, and
// splitting it across events would lose data to the driver's single pending
// feedback slot. A version mismatch is rejected rather than reinterpreted.
inline constexpr std::uint16_t k_protocol_version = 2;
inline constexpr std::uint32_t k_max_controllers = 16;

// This is the source device's private control interface, never the HID child
// interface. Both the Vibeshine client and driver compile this same value.
inline constexpr GUID k_device_interface_guid {
  0x27debbf5,
  0x1d1e,
  0x4e9c,
  {0x90, 0x6d, 0xd1, 0x04, 0xb1, 0x41, 0x8b, 0x2b}
};

inline constexpr wchar_t k_root_hardware_id[] = L"ROOT\\VIBESHINEVIRTUALGAMEPAD";

enum class profile : std::uint16_t {
  // Reserved for protocol compatibility. The public driver refuses this value
  // until the project has an accepted VID/PID allocation.
  generic_hid = 1,
  xbox_360 = 2,
  xbox_one = 3,
  xbox_series = 4,
  dualshock_4 = 5,
  dualsense = 6,
  switch_pro = 7,
  // Reserved for protocol compatibility. Its report encoder remains available
  // for development, but the public driver refuses it pending an accepted
  // VID/PID allocation.
  generic_pid = 8,
};

enum button_mask : std::uint32_t {
  // These values are deliberately identical to Vibeshine's existing Windows
  // platform contract. Keeping the normalized ABI stable makes the adapter a
  // field copy rather than a brittle semantic remapping.
  dpad_up = 0x000001u,
  dpad_down = 0x000002u,
  dpad_left = 0x000004u,
  dpad_right = 0x000008u,
  start = 0x000010u,
  back = 0x000020u,
  left_stick = 0x000040u,
  right_stick = 0x000080u,
  left_shoulder = 0x000100u,
  right_shoulder = 0x000200u,
  home = 0x000400u,
  south = 0x001000u,
  east = 0x002000u,
  west = 0x004000u,
  north = 0x008000u,
  paddle_1 = 0x010000u,
  paddle_2 = 0x020000u,
  paddle_3 = 0x040000u,
  paddle_4 = 0x080000u,
  touchpad = 0x100000u,
  misc = 0x200000u,
};

enum class feedback_type : std::uint16_t {
  none = 0,
  generic_rumble_rgb = 1,
  raw_output_report = 2,
  // Rumble without a light. The payload is still generic_rumble_rgb_feedback,
  // but its colour channels carry no meaning: a DirectInput PID effect says
  // nothing about an LED, and reporting one would make a client turn a real
  // controller's light off every time a game started a force.
  generic_rumble = 3,
  // All four Xbox actuators in one event. The driver keeps a single pending
  // feedback slot per controller, so body and trigger rumble have to travel
  // together or one of them would be dropped by coalescing.
  xbox_rumble = 4,
  // A PlayStation output report: rumble, lightbar, and (DualSense only) the
  // adaptive trigger programs, player LEDs, and microphone LED. One report
  // carries all of it, so one event does too.
  playstation_output = 5,
};

// DualSense adaptive trigger modes, as the console's output report encodes them.
enum class trigger_effect_mode : std::uint8_t {
  off = 0x00,
  feedback = 0x01,
  weapon = 0x02,
  vibration = 0x06,
};

using profile_mask_t = std::uint32_t;

[[nodiscard]] constexpr profile_mask_t profile_bit(const profile value) noexcept {
  const auto index = static_cast<std::uint16_t>(value);
  return index == 0 || index > 32 ? 0u : (1u << (index - 1));
}

enum feature_mask : std::uint32_t {
  feature_input_state = 1u << 0,
  feature_feedback = 1u << 1,
  feature_touch = 1u << 2,
  feature_motion = 1u << 3,
  feature_battery = 1u << 4,
  feature_hid_feature_reports = 1u << 5,
};

enum class raw_hid_operation : std::uint8_t {
  write_report = 1,
  set_feature = 2,
  get_feature = 3,
};

#pragma pack(push, 1)

struct request_header {
  std::uint32_t size;
  std::uint16_t version;
  std::uint16_t reserved;
};

struct create_controller_request {
  request_header header;
  std::uint32_t controller_id;
  profile requested_profile;
  std::uint16_t reserved;
};

struct query_info_request {
  request_header header;
};

struct query_info_response {
  request_header header;
  std::uint16_t minimum_protocol_version;
  std::uint16_t maximum_protocol_version;
  profile_mask_t available_profiles;
  std::uint32_t available_features;
  std::uint32_t maximum_controllers;
  std::uint32_t reserved;
};

struct controller_id_request {
  request_header header;
  std::uint32_t controller_id;
};

// Axes are Vibeshine's normalized state: sticks are signed with **positive
// meaning up and right**, and triggers are 0..255. Each profile converts to its
// own device's convention, because they disagree - HID sticks are positive-down
// and a DualShock 4's are unsigned. A client must not pre-convert; doing so on
// top of the profile's conversion inverts the vertical axes.
struct input_state_request {
  request_header header;
  std::uint32_t controller_id;
  std::uint32_t buttons;
  std::int16_t left_x;
  std::int16_t left_y;
  std::int16_t right_x;
  std::int16_t right_y;
  std::uint8_t left_trigger;
  std::uint8_t right_trigger;
  std::uint16_t reserved;
};

// Touch lifecycle, matching Vibeshine's normalized touch events.
enum class touch_event : std::uint8_t {
  hover = 0,
  down = 1,
  up = 2,
  move = 3,
  cancel = 4,
  cancel_all = 5,
};

enum class motion_kind : std::uint8_t {
  accelerometer = 1,
  gyroscope = 2,
};

enum class battery_state : std::uint8_t {
  unknown = 0,
  not_present = 1,
  discharging = 2,
  charging = 3,
  full = 4,
  not_charging = 5,
};

// Coordinates and pressure are normalized to 0..65535 by the client adapter.
// contact_index is a profile-independent logical contact, not a platform
// pointer identifier.
struct touch_state_request {
  request_header header;
  std::uint32_t controller_id;
  std::uint8_t contact_index;
  std::uint8_t event_type;
  std::uint16_t x;
  std::uint16_t y;
  std::uint16_t pressure;
  std::uint16_t reserved;
};

// Motion uses signed milli-units: m/s^2 * 1000 for accelerometers and degrees
// per second * 1000 for gyroscopes. The profile implementation owns any
// device-specific scaling and calibration.
struct motion_state_request {
  request_header header;
  std::uint32_t controller_id;
  std::uint8_t motion_type;
  std::uint8_t reserved0[3];
  std::int32_t x_milli;
  std::int32_t y_milli;
  std::int32_t z_milli;
};

struct battery_state_request {
  request_header header;
  std::uint32_t controller_id;
  std::uint8_t percent;
  std::uint8_t flags;
  std::uint16_t reserved;
};

struct generic_rumble_rgb_feedback {
  std::uint16_t low_frequency;
  std::uint16_t high_frequency;
  std::uint8_t red;
  std::uint8_t green;
  std::uint8_t blue;
  std::uint8_t reserved;
};

struct xbox_rumble_feedback {
  std::uint16_t low_frequency;
  std::uint16_t high_frequency;
  std::uint16_t left_trigger;
  std::uint16_t right_trigger;
};

// Mirrors Vibeshine's adaptive-trigger feedback message so the adapter is a
// field copy. `parameters` is the raw effect program for that trigger.
struct trigger_effect_feedback {
  std::uint8_t mode;
  std::uint8_t parameters[10];
};

struct playstation_output_feedback {
  std::uint16_t low_frequency;
  std::uint16_t high_frequency;
  std::uint8_t red;
  std::uint8_t green;
  std::uint8_t blue;
  // Bit 0 lightbar valid, bit 1 triggers valid, bit 2 player LEDs valid,
  // bit 3 microphone LED valid. A DualShock 4 only ever sets the first.
  std::uint8_t valid;
  std::uint8_t player_leds;
  std::uint8_t microphone_led;
  trigger_effect_feedback left_trigger;
  trigger_effect_feedback right_trigger;
};

inline constexpr std::uint8_t ps_output_lightbar_valid = 0x01;
inline constexpr std::uint8_t ps_output_triggers_valid = 0x02;
inline constexpr std::uint8_t ps_output_player_leds_valid = 0x04;
inline constexpr std::uint8_t ps_output_microphone_led_valid = 0x08;

struct raw_hid_report_feedback {
  raw_hid_operation operation;
  std::uint8_t report_id;
  std::uint8_t data_size;
  std::uint8_t reserved;
  std::uint8_t data[12];
};

struct feedback_event {
  request_header header;
  std::uint32_t controller_id;
  feedback_type type;
  std::uint16_t payload_size;
  std::uint8_t payload[32];
};

#pragma pack(pop)

static_assert(sizeof(request_header) == 8);
static_assert(sizeof(create_controller_request) == 16);
static_assert(sizeof(query_info_request) == 8);
static_assert(sizeof(query_info_response) == 28);
static_assert(sizeof(controller_id_request) == 12);
static_assert(sizeof(input_state_request) == 28);
static_assert(sizeof(touch_state_request) == 22);
static_assert(sizeof(motion_state_request) == 28);
static_assert(sizeof(battery_state_request) == 16);
static_assert(sizeof(generic_rumble_rgb_feedback) == 8);
static_assert(sizeof(xbox_rumble_feedback) == 8);
static_assert(sizeof(raw_hid_report_feedback) == 16);
static_assert(sizeof(trigger_effect_feedback) == 11);
static_assert(sizeof(playstation_output_feedback) == 32);
// Exactly fills the payload; anything larger needs another version bump.
static_assert(sizeof(playstation_output_feedback) <= sizeof(feedback_event::payload));
static_assert(sizeof(feedback_event) == 48);

inline constexpr DWORD ioctl_query_info =
  CTL_CODE(FILE_DEVICE_UNKNOWN, 0x800, METHOD_BUFFERED, FILE_READ_DATA | FILE_WRITE_DATA);
inline constexpr DWORD ioctl_create_controller =
  CTL_CODE(FILE_DEVICE_UNKNOWN, 0x801, METHOD_BUFFERED, FILE_READ_DATA | FILE_WRITE_DATA);
inline constexpr DWORD ioctl_destroy_controller =
  CTL_CODE(FILE_DEVICE_UNKNOWN, 0x802, METHOD_BUFFERED, FILE_READ_DATA | FILE_WRITE_DATA);
inline constexpr DWORD ioctl_submit_input_state =
  CTL_CODE(FILE_DEVICE_UNKNOWN, 0x803, METHOD_BUFFERED, FILE_READ_DATA | FILE_WRITE_DATA);
inline constexpr DWORD ioctl_poll_feedback =
  CTL_CODE(FILE_DEVICE_UNKNOWN, 0x804, METHOD_BUFFERED, FILE_READ_DATA | FILE_WRITE_DATA);
inline constexpr DWORD ioctl_submit_touch_state =
  CTL_CODE(FILE_DEVICE_UNKNOWN, 0x805, METHOD_BUFFERED, FILE_READ_DATA | FILE_WRITE_DATA);
inline constexpr DWORD ioctl_submit_motion_state =
  CTL_CODE(FILE_DEVICE_UNKNOWN, 0x806, METHOD_BUFFERED, FILE_READ_DATA | FILE_WRITE_DATA);
inline constexpr DWORD ioctl_submit_battery_state =
  CTL_CODE(FILE_DEVICE_UNKNOWN, 0x807, METHOD_BUFFERED, FILE_READ_DATA | FILE_WRITE_DATA);

template<class request_t>
[[nodiscard]] inline bool valid_request(const request_t *request, const std::size_t bytes) {
  return request != nullptr && bytes == sizeof(request_t) &&
         request->header.size == sizeof(request_t) &&
         request->header.version == k_protocol_version &&
         request->header.reserved == 0;
}

}  // namespace lvg
