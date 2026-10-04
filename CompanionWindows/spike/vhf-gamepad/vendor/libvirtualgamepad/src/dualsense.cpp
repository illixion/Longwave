// Copyright (c) 2026 Chase Payne
// SPDX-License-Identifier: MIT

#include "dualsense.h"

#include <cstring>

#include "dualshock4.h"  // Shared motion scaling and the feedback encoder.

namespace lvg::driver {
namespace {

[[nodiscard]] std::uint8_t encode_hat(const std::uint32_t buttons) noexcept {
  const bool up = (buttons & button_mask::dpad_up) != 0;
  const bool down = (buttons & button_mask::dpad_down) != 0;
  const bool left = (buttons & button_mask::dpad_left) != 0;
  const bool right = (buttons & button_mask::dpad_right) != 0;

  if ((up && down) || (left && right)) {
    return 8;
  }
  if (up) {
    return right ? 1 : (left ? 7 : 0);
  }
  if (down) {
    return right ? 3 : (left ? 5 : 4);
  }
  return right ? 2 : (left ? 6 : 8);
}

[[nodiscard]] std::uint8_t to_stick(const std::int16_t value) noexcept {
  return static_cast<std::uint8_t>((static_cast<std::int32_t>(value) + 32768) >> 8);
}

// Vibeshine's vertical axes are positive-up; the device's are positive-down.
// Negating around 32768 keeps a centred stick on exactly 128, which games treat
// as the rest position; negating around 32767 lands on 127 and reads as a
// permanent slight tilt. The clamp catches INT16_MIN, whose negation overflows
// the 8-bit range.
[[nodiscard]] std::uint8_t to_stick_inverted(const std::int16_t value) noexcept {
  const std::int32_t scaled = (32768 - static_cast<std::int32_t>(value)) >> 8;
  return static_cast<std::uint8_t>(scaled > 255 ? 255 : (scaled < 0 ? 0 : scaled));
}

[[nodiscard]] std::int16_t clamp_i16(const std::int32_t value) noexcept {
  if (value > 32767) {
    return 32767;
  }
  if (value < -32768) {
    return -32768;
  }
  return static_cast<std::int16_t>(value);
}

void pack_touch_point(ds5_touch_point *const point,
                      const bool active,
                      const std::uint8_t tracking_id,
                      const std::uint16_t x,
                      const std::uint16_t y) noexcept {
  point->contact = static_cast<std::uint8_t>((active ? 0x00u : 0x80u) | (tracking_id & 0x7Fu));
  point->coordinates[0] = static_cast<std::uint8_t>(x & 0xFFu);
  point->coordinates[1] = static_cast<std::uint8_t>(((x >> 8) & 0x0Fu) | ((y & 0x0Fu) << 4));
  point->coordinates[2] = static_cast<std::uint8_t>((y >> 4) & 0xFFu);
}

[[nodiscard]] std::uint16_t to_touch_x(const std::uint16_t value) noexcept {
  return static_cast<std::uint16_t>((static_cast<std::uint32_t>(value) * (k_ds5_touch_width - 1)) / 65535u);
}

[[nodiscard]] std::uint16_t to_touch_y(const std::uint16_t value) noexcept {
  return static_cast<std::uint16_t>((static_cast<std::uint32_t>(value) * (k_ds5_touch_height - 1)) / 65535u);
}

}  // namespace

void ds5_state::reset() noexcept {
  features = {};
  sequence = 0;
  sensor_timestamp = 0;
  battery_level = 5;
  cable_connected = false;
  battery_full = false;
  for (int axis = 0; axis < 3; ++axis) {
    gyro[axis] = 0;
    accel[axis] = 0;
  }
  accel[1] = static_cast<std::int16_t>(k_ds4_accel_counts_per_g);
  next_tracking_id = 1;
  for (std::uint8_t i = 0; i < k_ds5_touch_contacts; ++i) {
    contact_active[i] = false;
    contact_tracking_id[i] = 0;
    contact_x[i] = 0;
    contact_y[i] = 0;
  }
}

const std::uint8_t *ds5_descriptor(std::size_t *const size) noexcept {
  if (size != nullptr) {
    *size = lvg::ds5_usb::report_descriptor_size;
  }
  return lvg::ds5_usb::report_descriptor;
}

ds5_input_report encode_ds5_input(
  const input_state_request &input,
  ds5_state *const state) noexcept {
  ds5_input_report report {};
  report.report_id = k_ds5_input_report_id;

  report.left_x = to_stick(input.left_x);
  report.left_y = to_stick_inverted(input.left_y);
  report.right_x = to_stick(input.right_x);
  report.right_y = to_stick_inverted(input.right_y);
  report.left_trigger = input.left_trigger;
  report.right_trigger = input.right_trigger;

  std::uint8_t buttons0 = encode_hat(input.buttons);
  if (input.buttons & button_mask::west) {
    buttons0 |= 0x10;  // Square
  }
  if (input.buttons & button_mask::south) {
    buttons0 |= 0x20;  // Cross
  }
  if (input.buttons & button_mask::east) {
    buttons0 |= 0x40;  // Circle
  }
  if (input.buttons & button_mask::north) {
    buttons0 |= 0x80;  // Triangle
  }
  report.buttons[0] = buttons0;

  std::uint8_t buttons1 = 0;
  if (input.buttons & button_mask::left_shoulder) {
    buttons1 |= 0x01;
  }
  if (input.buttons & button_mask::right_shoulder) {
    buttons1 |= 0x02;
  }
  if (input.left_trigger > 0) {
    buttons1 |= 0x04;
  }
  if (input.right_trigger > 0) {
    buttons1 |= 0x08;
  }
  if (input.buttons & button_mask::back) {
    buttons1 |= 0x10;  // Create
  }
  if (input.buttons & button_mask::start) {
    buttons1 |= 0x20;  // Options
  }
  if (input.buttons & button_mask::left_stick) {
    buttons1 |= 0x40;
  }
  if (input.buttons & button_mask::right_stick) {
    buttons1 |= 0x80;
  }
  report.buttons[1] = buttons1;

  std::uint8_t buttons2 = 0;
  if (input.buttons & button_mask::home) {
    buttons2 |= 0x01;  // PS
  }
  if (input.buttons & button_mask::touchpad) {
    buttons2 |= 0x02;
  }
  if (input.buttons & button_mask::misc) {
    buttons2 |= 0x04;  // Microphone mute
  }
  report.buttons[2] = buttons2;

  if (state != nullptr) {
    state->sequence = static_cast<std::uint8_t>(state->sequence + 1);
    report.sequence = state->sequence;

    // The console's sensor clock runs at roughly 3 microsecond ticks; a
    // consumer only needs it to advance monotonically between samples.
    state->sensor_timestamp += 1333;
    report.sensor_timestamp = state->sensor_timestamp;

    for (int axis = 0; axis < 3; ++axis) {
      report.gyro[axis] = state->gyro[axis];
      report.accel[axis] = state->accel[axis];
    }

    std::uint8_t status = static_cast<std::uint8_t>(state->battery_level & 0x0F);
    if (state->battery_full) {
      status = static_cast<std::uint8_t>(0x20 | 0x0A);  // Complete.
    } else if (state->cable_connected) {
      status |= 0x10;  // Charging.
    }
    report.status = status;

    for (std::uint8_t i = 0; i < k_ds5_touch_contacts; ++i) {
      pack_touch_point(
        &report.touch[i],
        state->contact_active[i],
        state->contact_tracking_id[i],
        to_touch_x(state->contact_x[i]),
        to_touch_y(state->contact_y[i]));
    }
  } else {
    report.accel[1] = static_cast<std::int16_t>(k_ds4_accel_counts_per_g);
    for (auto &point : report.touch) {
      pack_touch_point(&point, false, 0, 0, 0);
    }
  }

  return report;
}

bool apply_ds5_touch(const touch_state_request &touch, ds5_state *const state) noexcept {
  if (state == nullptr) {
    return false;
  }

  const auto event = static_cast<touch_event>(touch.event_type);
  if (event == touch_event::cancel_all) {
    for (std::uint8_t i = 0; i < k_ds5_touch_contacts; ++i) {
      state->contact_active[i] = false;
    }
    return true;
  }

  if (touch.contact_index >= k_ds5_touch_contacts) {
    return false;
  }

  const std::uint8_t index = touch.contact_index;
  switch (event) {
    case touch_event::down:
      if (!state->contact_active[index]) {
        state->contact_tracking_id[index] = state->next_tracking_id;
        state->next_tracking_id = static_cast<std::uint8_t>((state->next_tracking_id + 1) & 0x7F);
        if (state->next_tracking_id == 0) {
          state->next_tracking_id = 1;
        }
      }
      state->contact_active[index] = true;
      state->contact_x[index] = touch.x;
      state->contact_y[index] = touch.y;
      return true;
    case touch_event::move:
    case touch_event::hover:
      if (!state->contact_active[index]) {
        return false;
      }
      state->contact_x[index] = touch.x;
      state->contact_y[index] = touch.y;
      return true;
    case touch_event::up:
    case touch_event::cancel:
      state->contact_active[index] = false;
      return true;
    default:
      return false;
  }
}

bool apply_ds5_motion(const motion_state_request &motion, ds5_state *const state) noexcept {
  if (state == nullptr) {
    return false;
  }

  switch (static_cast<motion_kind>(motion.motion_type)) {
    case motion_kind::accelerometer: {
      const auto convert = [](const std::int32_t milli) {
        return clamp_i16((milli * k_ds4_accel_counts_per_g) / k_milli_g);
      };
      state->accel[0] = convert(motion.x_milli);
      state->accel[1] = convert(motion.y_milli);
      state->accel[2] = convert(motion.z_milli);
      return true;
    }
    case motion_kind::gyroscope: {
      const auto convert = [](const std::int32_t milli) {
        return clamp_i16((milli * k_ds4_gyro_counts_per_dps) / 1000);
      };
      state->gyro[0] = convert(motion.x_milli);
      state->gyro[1] = convert(motion.y_milli);
      state->gyro[2] = convert(motion.z_milli);
      return true;
    }
    default:
      return false;
  }
}

bool apply_ds5_battery(const battery_state_request &battery, ds5_state *const state) noexcept {
  if (state == nullptr) {
    return false;
  }

  const auto reported = static_cast<lvg::battery_state>(battery.flags);
  state->cable_connected =
    reported == lvg::battery_state::charging || reported == lvg::battery_state::full ||
    reported == lvg::battery_state::not_charging;
  state->battery_full = reported == lvg::battery_state::full;

  if (battery.percent <= 100) {
    // The DualSense reports battery in 0..10 steps.
    state->battery_level =
      static_cast<std::uint8_t>((static_cast<std::uint32_t>(battery.percent) * 10u + 50u) / 100u);
  }
  return true;
}

bool decode_ds5_output(
  const ds5_output_report &output,
  playstation_output_feedback *const feedback) noexcept {
  playstation_output_feedback decoded {};
  if (feedback == nullptr || !apply_ds5_output(output, &decoded)) {
    return false;
  }
  *feedback = decoded;
  return true;
}

bool apply_ds5_output(
  const ds5_output_report &output,
  playstation_output_feedback *const feedback) noexcept {
  if (feedback == nullptr || output.report_id != k_ds5_output_report_id) {
    return false;
  }

  // Newer host drivers use vibration-v2 in flag2 instead of flag0's legacy
  // enable bit. Both formats carry their motor amplitudes in the same bytes.
  if ((output.valid_flag0 & k_ds5_flag0_compatible_vibration) ||
      (output.valid_flag2 & k_ds5_flag2_compatible_vibration)) {
    feedback->low_frequency = static_cast<std::uint16_t>(output.motor_left << 8);
    feedback->high_frequency = static_cast<std::uint16_t>(output.motor_right << 8);
  }

  if (output.valid_flag1 & k_ds5_flag1_lightbar) {
    feedback->red = output.lightbar_red;
    feedback->green = output.lightbar_green;
    feedback->blue = output.lightbar_blue;
    feedback->valid |= ps_output_lightbar_valid;
  }

  if (output.valid_flag1 & k_ds5_flag1_player_indicator) {
    feedback->player_leds = output.player_leds;
    feedback->valid |= ps_output_player_leds_valid;
  }

  if (output.valid_flag1 & k_ds5_flag1_mic_mute_led) {
    feedback->microphone_led = output.mute_button_led;
    feedback->valid |= ps_output_microphone_led_valid;
  }

  // Each trigger is programmed independently. An omitted trigger keeps its
  // current program; an explicit off program releases it.
  if (output.valid_flag0 & k_ds5_flag0_left_trigger_effect) {
    feedback->left_trigger.mode = output.left_trigger.mode;
    std::memcpy(feedback->left_trigger.parameters, output.left_trigger.parameters,
                sizeof(feedback->left_trigger.parameters));
    feedback->valid |= ps_output_triggers_valid;
  }
  if (output.valid_flag0 & k_ds5_flag0_right_trigger_effect) {
    feedback->right_trigger.mode = output.right_trigger.mode;
    std::memcpy(feedback->right_trigger.parameters, output.right_trigger.parameters,
                sizeof(feedback->right_trigger.parameters));
    feedback->valid |= ps_output_triggers_valid;
  }

  return true;
}

std::size_t fill_ds5_feature(
  const std::uint8_t report_id,
  std::uint8_t *const buffer,
  const std::size_t capacity,
  const lvg::ds5_usb::feature_state &state) noexcept {
  return lvg::ds5_usb::get_feature(report_id, buffer, capacity, state);
}

}  // namespace lvg::driver
