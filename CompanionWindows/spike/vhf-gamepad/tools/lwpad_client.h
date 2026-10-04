// Minimal feeder-side client for the Longwave virtual gamepad driver.
// This is roughly what the host's lw_gamepad_* C shim (NATIVE_V3_PROTOCOL.md
// §7.2) would wrap: find the driver's interface, open it, send fixed-size
// IOCTLs. Closing the handle (or dying) deletes every pad this handle created.

#pragma once

#include <windows.h>
#include <cfgmgr32.h>

#include <cstdint>
#include <string>
#include <vector>

#include "lwpad.h"

#pragma comment(lib, "cfgmgr32.lib")

class lwpad_client {
 public:
  lwpad_client() = default;
  ~lwpad_client() { close(); }
  lwpad_client(const lwpad_client &) = delete;
  lwpad_client &operator=(const lwpad_client &) = delete;

  // Returns false (and sets last_error) when the driver isn't installed/started.
  bool open() {
    close();
    ULONG chars = 0;
    if (CM_Get_Device_Interface_List_SizeW(&chars, const_cast<GUID *>(&lwpad::k_interface_guid), nullptr,
                                           CM_GET_DEVICE_INTERFACE_LIST_PRESENT) != CR_SUCCESS || chars <= 1) {
      last_error = ERROR_FILE_NOT_FOUND;
      return false;
    }
    std::vector<wchar_t> list(chars);
    if (CM_Get_Device_Interface_ListW(const_cast<GUID *>(&lwpad::k_interface_guid), nullptr, list.data(), chars,
                                      CM_GET_DEVICE_INTERFACE_LIST_PRESENT) != CR_SUCCESS || list[0] == L'\0') {
      last_error = ERROR_FILE_NOT_FOUND;
      return false;
    }
    path = list.data();
    handle_ = CreateFileW(path.c_str(), GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                          OPEN_EXISTING, 0, nullptr);
    if (handle_ == INVALID_HANDLE_VALUE) {
      last_error = GetLastError();
      handle_ = nullptr;
      return false;
    }
    return true;
  }

  void close() {
    if (handle_ != nullptr) CloseHandle(handle_);
    handle_ = nullptr;
  }

  bool query_info(lvg::query_info_response *out) {
    lvg::query_info_request in {header<lvg::query_info_request>()};
    return ioctl(lvg::ioctl_query_info, &in, sizeof(in), out, sizeof(*out));
  }

  bool stats(lwpad::stats_response *out) { return ioctl(lwpad::ioctl_query_stats, nullptr, 0, out, sizeof(*out)); }

  bool create(std::uint32_t id, lvg::profile profile) {
    lvg::create_controller_request in {header<lvg::create_controller_request>(), id, profile, 0};
    return ioctl(lvg::ioctl_create_controller, &in, sizeof(in), nullptr, 0);
  }

  bool destroy(std::uint32_t id) {
    lvg::controller_id_request in {header<lvg::controller_id_request>(), id};
    return ioctl(lvg::ioctl_destroy_controller, &in, sizeof(in), nullptr, 0);
  }

  // Sticks: signed, positive = up/right. Triggers 0..255. Buttons: lvg::button_mask.
  bool input(std::uint32_t id, std::uint32_t buttons, std::int16_t lx = 0, std::int16_t ly = 0,
             std::int16_t rx = 0, std::int16_t ry = 0, std::uint8_t lt = 0, std::uint8_t rt = 0) {
    lvg::input_state_request in {header<lvg::input_state_request>(), id, buttons, lx, ly, rx, ry, lt, rt, 0};
    return ioctl(lvg::ioctl_submit_input_state, &in, sizeof(in), nullptr, 0);
  }

  // Gyro in milli-degrees/s, accelerometer in milli-m/s^2.
  bool motion(std::uint32_t id, lvg::motion_kind kind, std::int32_t x, std::int32_t y, std::int32_t z) {
    lvg::motion_state_request in {header<lvg::motion_state_request>(), id, static_cast<std::uint8_t>(kind), {0, 0, 0},
                                  x, y, z};
    return ioctl(lvg::ioctl_submit_motion_state, &in, sizeof(in), nullptr, 0);
  }

  // True when an event was waiting. The driver keeps only the newest one.
  bool poll_feedback(std::uint32_t id, lvg::feedback_event *out) {
    lvg::controller_id_request in {header<lvg::controller_id_request>(), id};
    return ioctl(lvg::ioctl_poll_feedback, &in, sizeof(in), out, sizeof(*out));
  }

  DWORD last_error = 0;
  std::wstring path;

 private:
  template <class T>
  static lvg::request_header header() {
    return {sizeof(T), lvg::k_protocol_version, 0};
  }

  bool ioctl(DWORD code, void *in, DWORD in_size, void *out, DWORD out_size) {
    DWORD returned = 0;
    if (handle_ == nullptr) {
      last_error = ERROR_INVALID_HANDLE;
      return false;
    }
    if (!DeviceIoControl(handle_, code, in, in_size, out, out_size, &returned, nullptr)) {
      last_error = GetLastError();
      return false;
    }
    last_error = 0;
    return true;
  }

  HANDLE handle_ = nullptr;
};
