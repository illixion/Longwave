// Copyright (c) 2026 Chase Payne
// SPDX-License-Identifier: MIT
//
// Input report pacing.
//
// A HID read completes the moment a report is waiting. Hand VHF a new report on
// every state change and reads never block, so a program that loops on them
// spins on a core for nothing. VHF raises a readiness callback when it will take
// the next report; the driver submits only at that point and decides then which
// of the pending state is worth sending.
//
// Reports fall into three groups:
//
//   * continuous - sticks, triggers, motion, battery, touch movement. Only the
//     newest value means anything, so a newer one overwrites a waiting older
//     one.
//   * transition - button, D-pad, trigger-threshold and touch lifecycle
//     changes. Overwriting one would lose a press or a release, so they are
//     held in order.
//   * priority   - profile initialization replies. A host waiting on one is not
//     streaming yet, so it goes ahead of controller state.
//
// Pure logic, no WDF, so the policy can be tested directly.

#pragma once

#include <cstddef>
#include <cstdint>

namespace lvg::driver {

inline constexpr std::size_t k_max_report_bytes = 64;
// A host that has stalled this long is not coming back quickly; keeping more
// than this would trade memory for transitions nobody will see in time.
inline constexpr std::uint8_t k_transition_capacity = 16;
inline constexpr std::uint8_t k_priority_capacity = 4;

struct report_buffer {
  std::uint8_t data[k_max_report_bytes];
  std::uint32_t length;
  std::uint8_t report_id;
};

enum class report_kind : std::uint8_t {
  continuous,
  transition,
  priority,
};

class report_pump {
 public:
  void reset() noexcept;

  // Records a report for delivery. Returns false when a transition had to be
  // discarded because the queue was full, which the caller may want to log.
  bool enqueue(const void *data, std::uint32_t length, std::uint8_t report_id, report_kind kind) noexcept;

  // Marks VHF able to accept another report.
  void set_ready() noexcept;

  // Takes the next report to submit. Returns false when VHF is not ready or
  // nothing is waiting; on success the pump is no longer ready.
  [[nodiscard]] bool take(report_buffer *out) noexcept;

  [[nodiscard]] bool ready() const noexcept {
    return ready_;
  }

  [[nodiscard]] bool empty() const noexcept {
    return priority_count_ == 0 && transition_count_ == 0 && !have_latest_;
  }

  // Classifies an input state against the previous one. Buttons, the D-pad and
  // whether each trigger has crossed its digital threshold are discrete; the
  // analog values are not.
  [[nodiscard]] report_kind classify(
    std::uint32_t buttons,
    std::uint8_t left_trigger,
    std::uint8_t right_trigger) noexcept;

  [[nodiscard]] std::uint8_t transitions_waiting() const noexcept {
    return transition_count_;
  }

  [[nodiscard]] std::uint32_t dropped_transitions() const noexcept {
    return dropped_;
  }

 private:
  static void store(report_buffer *slot, const void *data, std::uint32_t length, std::uint8_t report_id) noexcept;

  bool ready_ {};
  report_buffer priority_[k_priority_capacity] {};
  std::uint8_t priority_count_ {};
  report_buffer transitions_[k_transition_capacity] {};
  std::uint8_t transition_head_ {};
  std::uint8_t transition_count_ {};
  report_buffer latest_ {};
  bool have_latest_ {};
  std::uint32_t dropped_ {};

  bool have_signature_ {};
  std::uint32_t last_buttons_ {};
  bool last_left_trigger_ {};
  bool last_right_trigger_ {};
};

}  // namespace lvg::driver
