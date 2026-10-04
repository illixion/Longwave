Vendored from https://github.com/Nonary/libvirtualgamepad at commit
4b56fb9da177f320fb2d7ddb1b6262e5d55d2750 (2026-09-22), MIT (see LICENSE).

Files are byte-for-byte unchanged:
include/libvirtualgamepad/{protocol.h, ds4_usb.h, ds5_usb.h}
src/{xbox_series, dualsense, dualshock4, report_pump}.{h,cpp}

Longwave does NOT use protocol.h's k_device_interface_guid or
k_root_hardware_id (Vibeshine's identity); see ../../include/lwpad.h.
