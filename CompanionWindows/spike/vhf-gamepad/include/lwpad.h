// Longwave virtual gamepad: the identity of our driver.
//
// The wire format (request structs, IOCTL codes, profile and button enums) is
// libvirtualgamepad's, vendored unchanged under vendor/libvirtualgamepad. It is
// small, fixed-size, versioned and METHOD_BUFFERED, which is what we would have
// written anyway. What must NOT be shared is the identity: libvirtualgamepad's
// protocol.h also declares Vibeshine's interface GUID and root hardware ID, and
// if both drivers were installed on one PC a client would open whichever it
// found first. So Longwave uses its own GUID and hardware ID, defined here, and
// never refers to lvg::k_device_interface_guid or lvg::k_root_hardware_id.

#pragma once

#include "libvirtualgamepad/protocol.h"

namespace lwpad {

// The control interface our driver registers on its root device. Clients find
// the driver by enumerating this interface (SetupDiGetClassDevs /
// CM_Get_Device_Interface_List), then send lvg::ioctl_* requests to it.
// {9B6BD835-F12F-4B31-9DC7-8AFD6029CED2}
inline constexpr GUID k_interface_guid {
  0x9b6bd835, 0xf12f, 0x4b31, {0x9d, 0xc7, 0x8a, 0xfd, 0x60, 0x29, 0xce, 0xd2}};

// The hardware ID of the one root-enumerated device node the driver loads on.
// Must match the INF's [Models] line.
inline constexpr wchar_t k_root_hardware_id[] = L"Root\\LongwaveVirtualGamepad";

// Base container ID for the HID children (a random GUID with its last byte
// zeroed). The last byte is replaced with the controller index so each pad is
// its own physical device to Windows.
inline constexpr GUID k_container_base {
  0x3cc554e8, 0xbf52, 0x4c12, {0xbf, 0x72, 0x87, 0xc3, 0x27, 0x01, 0x02, 0x00}};

// Driver-only counters, read back by the test tool to prove the driver side of
// a round trip (e.g. that XInputSetState really produced an output report).
inline constexpr DWORD ioctl_query_stats =
  CTL_CODE(FILE_DEVICE_UNKNOWN, 0x8F0, METHOD_BUFFERED, FILE_READ_DATA | FILE_WRITE_DATA);

#pragma pack(push, 1)
struct stats_response {
  lvg::request_header header;
  std::uint32_t controllers_created;   // successful VhfStart since load
  std::uint32_t controllers_destroyed; // VhfDelete since load (any reason)
  std::uint32_t controllers_active;
  std::uint32_t reports_submitted;     // VhfReadReportSubmit successes
  std::uint32_t output_reports;        // HID output reports received (rumble etc.)
  std::uint32_t feature_reads;         // HID GetFeature answered
  std::uint32_t closes_with_owned;     // file closes that had to tear down pads
  std::uint32_t reserved;
};
#pragma pack(pop)
static_assert(sizeof(stats_response) == 40);

}  // namespace lwpad
