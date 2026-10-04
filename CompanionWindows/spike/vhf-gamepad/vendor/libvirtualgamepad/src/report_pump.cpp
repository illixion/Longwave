// Copyright (c) 2026 Chase Payne
// SPDX-License-Identifier: MIT

#include "report_pump.h"

#include <cstring>

namespace lvg::driver {

void report_pump::store(
  report_buffer *const slot,
  const void *const data,
  const std::uint32_t length,
  const std::uint8_t report_id) noexcept {
  const std::uint32_t copied = length > k_max_report_bytes
                                 ? static_cast<std::uint32_t>(k_max_report_bytes)
                                 : length;
  std::memcpy(slot->data, data, copied);
  slot->length = copied;
  slot->report_id = report_id;
}

void report_pump::reset() noexcept {
  // VHF can take a report before it has ever signalled readiness, so the first
  // one must not wait for a signal that only follows a submission.
  ready_ = true;
  priority_count_ = 0;
  transition_head_ = 0;
  transition_count_ = 0;
  have_latest_ = false;
  dropped_ = 0;
  have_signature_ = false;
  last_buttons_ = 0;
  last_left_trigger_ = false;
  last_right_trigger_ = false;
}

report_kind report_pump::classify(
  const std::uint32_t buttons,
  const std::uint8_t left_trigger,
  const std::uint8_t right_trigger) noexcept {
  const bool left_pressed = left_trigger > 0;
  const bool right_pressed = right_trigger > 0;

  const bool discrete_change = !have_signature_ || buttons != last_buttons_ ||
                               left_pressed != last_left_trigger_ ||
                               right_pressed != last_right_trigger_;

  have_signature_ = true;
  last_buttons_ = buttons;
  last_left_trigger_ = left_pressed;
  last_right_trigger_ = right_pressed;

  return discrete_change ? report_kind::transition : report_kind::continuous;
}

bool report_pump::enqueue(
  const void *const data,
  const std::uint32_t length,
  const std::uint8_t report_id,
  const report_kind kind) noexcept {
  if (data == nullptr || length == 0) {
    return true;
  }

  switch (kind) {
    case report_kind::priority: {
      if (priority_count_ >= k_priority_capacity) {
        // A host that has not consumed four handshake replies is not going to
        // consume a fifth; keeping the earliest keeps the exchange in order.
        return false;
      }
      store(&priority_[priority_count_], data, length, report_id);
      ++priority_count_;
      return true;
    }
    case report_kind::transition: {
      // A pending continuous snapshot was produced before this transition.
      // Sending it afterwards could restore a button or trigger state that
      // this transition just changed, so the transition supersedes it.
      have_latest_ = false;
      if (transition_count_ == k_transition_capacity) {
        // Drop the oldest rather than the newest. Losing an old press whose
        // release is still queued leaves a button reading released, which is
        // the safe direction; dropping the newest could leave one stuck down.
        transition_head_ = static_cast<std::uint8_t>((transition_head_ + 1) % k_transition_capacity);
        --transition_count_;
        ++dropped_;
      }
      const std::uint8_t tail =
        static_cast<std::uint8_t>((transition_head_ + transition_count_) % k_transition_capacity);
      store(&transitions_[tail], data, length, report_id);
      ++transition_count_;
      return dropped_ == 0;
    }
    case report_kind::continuous:
    default: {
      // Only the newest continuous state matters, so replace rather than queue.
      store(&latest_, data, length, report_id);
      have_latest_ = true;
      return true;
    }
  }
}

void report_pump::set_ready() noexcept {
  ready_ = true;
}

bool report_pump::take(report_buffer *const out) noexcept {
  if (out == nullptr || !ready_) {
    return false;
  }

  if (priority_count_ > 0) {
    *out = priority_[0];
    for (std::uint8_t i = 1; i < priority_count_; ++i) {
      priority_[i - 1] = priority_[i];
    }
    --priority_count_;
    ready_ = false;
    return true;
  }

  if (transition_count_ > 0) {
    *out = transitions_[transition_head_];
    transition_head_ = static_cast<std::uint8_t>((transition_head_ + 1) % k_transition_capacity);
    --transition_count_;
    ready_ = false;
    return true;
  }

  if (have_latest_) {
    *out = latest_;
    have_latest_ = false;
    ready_ = false;
    return true;
  }

  return false;
}

}  // namespace lvg::driver
