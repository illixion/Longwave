// Longwave virtual gamepad driver (spike).
//
// What this is, in Windows terms:
//
//   * A UMDF2 driver: a DLL that Windows loads into WUDFHost.exe, a normal
//     user-mode process. A crash here kills that process, not the PC - no blue
//     screen is possible from this code.
//   * A VHF "source" driver: it sits on one root-enumerated device node
//     (Root\LongwaveVirtualGamepad, created by lwpad-devnode.exe). The inbox
//     Virtual HID Framework (vhf.sys + VhfUm.dll, part of Windows since 10
//     1709) is the function driver of that node. Each VhfCreate/VhfStart below
//     asks VHF to create a *child* HID device with our report descriptor; every
//     HID consumer on the PC (XInput via xinputhid, DirectInput, Raw Input,
//     Windows.Gaming.Input, SDL, Steam) then sees an ordinary USB-less gamepad.
//   * The feeder (Longwave's host, or lwpad-test.exe here) opens our device
//     interface and drives pads with fixed-size IOCTLs. When the feeder's
//     handle closes - including when the process is killed - every pad it
//     created is deleted, so a crash can't leave a ghost controller.
//
// Design and code are adapted from libvirtualgamepad (MIT, Copyright (c) 2026
// Chase Payne, https://github.com/Nonary/libvirtualgamepad). The report
// encoders for each controller family are vendored from it unchanged; this
// file is a reduced rewrite of its driver.cpp keeping its lifetime rules:
// open the VHF target from PrepareHardware (not DeviceAdd), never hold
// state_lock across a VHF call, and pace input reports on VHF's readiness
// callback. Profiles here: Xbox Series (XInput-visible) and DualSense.

#define WIN32_NO_STATUS
#include <windows.h>
#undef WIN32_NO_STATUS
#include <wdf.h>
#include <vhf.h>

#include <cstddef>
#include <cstdint>
#include <cstring>

#include "lwpad.h"
#include "dualsense.h"
#include "dualshock4.h"
#include "report_pump.h"
#include "xbox_series.h"

namespace {

using lvg::driver::report_kind;

// ---------------------------------------------------------------------------
// Profiles

struct profile_info {
  lvg::profile id;
  const std::uint8_t *descriptor;
  std::size_t descriptor_size;
  std::uint16_t vendor_id;
  std::uint16_t product_id;
  std::uint16_t version;
  // REG_MULTI_SZ hardware IDs for the HID child, or null to let VHF derive
  // them from VID/PID. The Xbox list is what makes Windows attach its inbox
  // xinputhid.sys filter, i.e. what makes the pad an XInput controller.
  const wchar_t *hardware_ids;
  std::size_t hardware_ids_bytes;
};

[[nodiscard]] bool find_profile(const lvg::profile id, profile_info *const out) noexcept {
  *out = {};
  out->id = id;
  switch (id) {
    case lvg::profile::xbox_series:
      out->descriptor = lvg::driver::xbox_series_descriptor(&out->descriptor_size);
      out->vendor_id = lvg::driver::k_xbox_vendor_id;
      out->product_id = lvg::driver::k_xbox_series_product_id;
      out->version = lvg::driver::k_xbox_series_version;
      out->hardware_ids = lvg::driver::xbox_series_hardware_ids(&out->hardware_ids_bytes);
      return true;
    case lvg::profile::dualsense:
      out->descriptor = lvg::driver::ds5_descriptor(&out->descriptor_size);
      out->vendor_id = lvg::driver::k_ds5_vendor_id;
      out->product_id = lvg::driver::k_ds5_product_id;
      out->version = lvg::driver::k_ds5_version;
      return true;
    default:
      return false;
  }
}

constexpr lvg::profile_mask_t k_available_profiles =
  lvg::profile_bit(lvg::profile::xbox_series) | lvg::profile_bit(lvg::profile::dualsense);

// ---------------------------------------------------------------------------
// State

enum class slot_state : std::uint8_t { empty, starting, active, stopping };

struct device_context;

struct controller_slot {
  device_context *parent;
  std::uint32_t controller_id;
  VHFHANDLE vhf;
  WDFFILEOBJECT owner;  // the feeder handle that created it
  lvg::profile profile;
  slot_state state;
  // One coalesced feedback event: the newest actuator state wins.
  bool feedback_pending;
  lvg::feedback_event feedback;
  lvg::playstation_output_feedback ps_feedback;
  // The last input, so a motion update can rebuild the whole report.
  bool have_input;
  lvg::input_state_request last_input;
  lvg::driver::ds5_state ds5;
  lvg::driver::report_pump pump;
  // VHF keeps pointers to these, so they live as long as the child.
  GUID container_id;
  wchar_t instance_id[24];
};

struct device_context {
  // lifetime_gate is held across VHF calls; state_lock only around field
  // access. VhfStart/VhfDelete can call back into us on another thread, and
  // those callbacks take state_lock - so state_lock is never held across them.
  WDFWAITLOCK lifetime_gate;
  WDFWAITLOCK state_lock;
  WDFIOTARGET vhf_target;
  HANDLE vhf_file;  // what VHF_CONFIG needs: a handle to our own stack
  bool target_open;
  bool stopping;
  controller_slot slots[lvg::k_max_controllers];
  volatile LONG created, destroyed, submitted, outputs, features, owned_closes;
};

struct target_context {
  device_context *device;
};

WDF_DECLARE_CONTEXT_TYPE_WITH_NAME(device_context, get_device_context);
WDF_DECLARE_CONTEXT_TYPE_WITH_NAME(target_context, get_target_context);

class state_guard {
 public:
  explicit state_guard(device_context *c) noexcept : c_(c) { WdfWaitLockAcquire(c_->state_lock, nullptr); }
  ~state_guard() { WdfWaitLockRelease(c_->state_lock); }
  state_guard(const state_guard &) = delete;
  state_guard &operator=(const state_guard &) = delete;
 private:
  device_context *c_;
};

class lifetime_guard {
 public:
  explicit lifetime_guard(device_context *c) noexcept : c_(c) { WdfWaitLockAcquire(c_->lifetime_gate, nullptr); }
  ~lifetime_guard() { WdfWaitLockRelease(c_->lifetime_gate); }
  lifetime_guard(const lifetime_guard &) = delete;
  lifetime_guard &operator=(const lifetime_guard &) = delete;
 private:
  device_context *c_;
};

void reset_slot(controller_slot *const slot) noexcept {
  device_context *const parent = slot->parent;
  const std::uint32_t id = slot->controller_id;
  std::memset(slot, 0, sizeof(*slot));
  slot->parent = parent;
  slot->controller_id = id;
  slot->state = slot_state::empty;
}

// Opening our own stack "by file" is how a UMDF source driver gets the handle
// VHF wants. It only works once PnP has started the device, which is why it
// happens from PrepareHardware (and is retried on first create) rather than
// from DeviceAdd. Caller holds the lifetime gate.
[[nodiscard]] NTSTATUS ensure_target_open(device_context *const c) noexcept {
  WDFIOTARGET target = nullptr;
  {
    state_guard lock(c);
    if (c->vhf_file != nullptr) return STATUS_SUCCESS;
    if (c->stopping || c->vhf_target == nullptr) return STATUS_DEVICE_NOT_READY;
    target = c->vhf_target;
  }
  WDF_IO_TARGET_OPEN_PARAMS params;
  WDF_IO_TARGET_OPEN_PARAMS_INIT_OPEN_BY_FILE(&params, nullptr);
  NTSTATUS status = WdfIoTargetOpen(target, &params);
  if (!NT_SUCCESS(status)) return status;
  const HANDLE file = WdfIoTargetWdmGetTargetFileHandle(target);
  if (file == nullptr) {
    WdfIoTargetClose(target);
    return STATUS_DEVICE_NOT_READY;
  }
  state_guard lock(c);
  c->vhf_file = file;
  c->target_open = true;
  return STATUS_SUCCESS;
}

// ---------------------------------------------------------------------------
// Input reports

// Hands a report to VHF if it can take one now; otherwise it waits in the pump
// for EvtVhfReadyForNextReadReport. Must be called WITHOUT state_lock. Does not
// take the lifetime gate, because it also runs inside VHF callbacks, where
// VhfDelete is waiting for us and the handle is guaranteed alive.
NTSTATUS pump_report(controller_slot &slot, const void *data, ULONG length, UCHAR report_id,
                     report_kind kind) noexcept {
  device_context *const c = slot.parent;
  lvg::driver::report_buffer next {};
  bool have_next = false;
  VHFHANDLE vhf = nullptr;
  {
    state_guard lock(c);
    if (c->stopping || slot.state != slot_state::active || slot.vhf == nullptr) {
      return STATUS_DEVICE_NOT_READY;
    }
    if (data != nullptr) (void)slot.pump.enqueue(data, length, report_id, kind);
    have_next = slot.pump.take(&next);
    vhf = slot.vhf;
  }
  if (!have_next) return STATUS_SUCCESS;

  HID_XFER_PACKET packet {next.data, next.length, next.report_id};
  const NTSTATUS status = VhfReadReportSubmit(vhf, &packet);
  if (NT_SUCCESS(status)) {
    InterlockedIncrement(&c->submitted);
  } else {
    state_guard lock(c);
    slot.pump.set_ready();
  }
  return status;
}

void evt_vhf_ready_for_next_report(PVOID client_context) {
  auto *const slot = static_cast<controller_slot *>(client_context);
  if (slot == nullptr || slot->parent == nullptr) return;
  {
    state_guard lock(slot->parent);
    slot->pump.set_ready();
  }
  (void)pump_report(*slot, nullptr, 0, 0, report_kind::continuous);
}

// Builds the profile's input report from the last input state. Caller holds
// state_lock. Returns the report length, 0 if there is nothing to send.
ULONG build_input_report(controller_slot &slot, std::uint8_t *const buffer, UCHAR *const report_id) noexcept {
  if (slot.profile == lvg::profile::xbox_series) {
    const auto report = lvg::driver::encode_xbox_series_input(slot.last_input);
    std::memcpy(buffer, &report, sizeof(report));
    *report_id = lvg::driver::k_xbox_series_input_report_id;
    return sizeof(report);
  }
  if (slot.profile == lvg::profile::dualsense) {
    const auto report = lvg::driver::encode_ds5_input(slot.last_input, &slot.ds5);
    std::memcpy(buffer, &report, sizeof(report));
    *report_id = lvg::driver::k_ds5_input_report_id;
    return sizeof(report);
  }
  return 0;
}

// ---------------------------------------------------------------------------
// HID requests from the PC's side (output/feature/get-input reports)

void complete(VHFOPERATIONHANDLE op, NTSTATUS status) noexcept {
  if (op != nullptr) VhfAsyncOperationComplete(op, status);
}

// An output report: XInputSetState, SDL rumble, a DualSense lightbar/trigger
// write. Decoded into one feedback event the feeder polls for.
void evt_vhf_write_report(PVOID client_context, VHFOPERATIONHANDLE op, PVOID, PHID_XFER_PACKET packet) {
  auto *const slot = static_cast<controller_slot *>(client_context);
  if (slot == nullptr || slot->parent == nullptr || packet == nullptr || packet->reportBuffer == nullptr ||
      packet->reportBufferLen == 0) {
    complete(op, STATUS_INVALID_PARAMETER);
    return;
  }
  device_context *const c = slot->parent;
  InterlockedIncrement(&c->outputs);
  NTSTATUS status = STATUS_INVALID_DEVICE_REQUEST;
  {
    state_guard lock(c);
    if (c->stopping || slot->state != slot_state::active) {
      status = STATUS_DEVICE_NOT_READY;
    } else if (slot->profile == lvg::profile::xbox_series) {
      lvg::driver::xbox_series_output_report out {};
      lvg::xbox_rumble_feedback rumble {};
      if (packet->reportId == lvg::driver::k_xbox_series_output_report_id &&
          packet->reportBufferLen >= sizeof(out)) {
        std::memcpy(&out, packet->reportBuffer, sizeof(out));
        if (lvg::driver::decode_xbox_series_output(out, &rumble)) {
          slot->feedback = lvg::driver::encode_xbox_series_feedback(slot->controller_id, rumble);
          slot->feedback_pending = true;
          status = STATUS_SUCCESS;
        }
      }
    } else if (slot->profile == lvg::profile::dualsense) {
      // USB form is report 0x02. Sony's PC library (libScePad) writes the
      // Bluetooth form 0x31 instead: same payload after id, sequence and tag.
      const std::uint8_t *const data = packet->reportBuffer;
      const ULONG length = packet->reportBufferLen;
      lvg::driver::ds5_output_report out {};
      bool decoded = false;
      lvg::playstation_output_feedback merged = slot->ps_feedback;
      if (data[0] == lvg::driver::k_ds5_output_report_id && length >= sizeof(out)) {
        std::memcpy(&out, data, sizeof(out));
        decoded = lvg::driver::apply_ds5_output(out, &merged);
      } else if (data[0] == lvg::driver::k_ds5_output_report_id_bt && length >= 3 + sizeof(out) - 1) {
        out.report_id = lvg::driver::k_ds5_output_report_id;
        std::memcpy(reinterpret_cast<std::uint8_t *>(&out) + 1, data + 3, sizeof(out) - 1);
        decoded = lvg::driver::apply_ds5_output(out, &merged);
      }
      if (decoded) {
        slot->ps_feedback = merged;
        slot->feedback = lvg::driver::encode_playstation_feedback(slot->controller_id, merged);
        slot->feedback_pending = true;
        status = STATUS_SUCCESS;
      } else {
        status = STATUS_INVALID_PARAMETER;
      }
    }
  }
  complete(op, status);
}

// DualSense hosts (SDL, Steam, Sony's library) read calibration, pairing and
// firmware feature reports before they will treat the pad as a DualSense.
void evt_vhf_get_feature(PVOID client_context, VHFOPERATIONHANDLE op, PVOID, PHID_XFER_PACKET packet) {
  auto *const slot = static_cast<controller_slot *>(client_context);
  NTSTATUS status = STATUS_INVALID_DEVICE_REQUEST;
  if (slot != nullptr && slot->parent != nullptr && packet != nullptr && packet->reportBuffer != nullptr) {
    InterlockedIncrement(&slot->parent->features);
    state_guard lock(slot->parent);
    if (slot->state == slot_state::active && slot->profile == lvg::profile::dualsense) {
      const std::size_t written = lvg::driver::fill_ds5_feature(
        packet->reportId, packet->reportBuffer, packet->reportBufferLen, slot->ds5.features);
      status = written != 0 ? STATUS_SUCCESS : STATUS_INVALID_DEVICE_REQUEST;
    }
  }
  complete(op, status);
}

void evt_vhf_set_feature(PVOID client_context, VHFOPERATIONHANDLE op, PVOID, PHID_XFER_PACKET packet) {
  auto *const slot = static_cast<controller_slot *>(client_context);
  NTSTATUS status = STATUS_INVALID_DEVICE_REQUEST;
  if (slot != nullptr && slot->parent != nullptr && packet != nullptr) {
    state_guard lock(slot->parent);
    if (slot->state == slot_state::active && slot->profile == lvg::profile::dualsense &&
        lvg::ds5_usb::set_feature(packet->reportId, packet->reportBuffer, packet->reportBufferLen,
                                  slot->ds5.features)) {
      status = STATUS_SUCCESS;
    }
  }
  complete(op, status);
}

// HidD_GetInputReport: answer with the current state instead of waiting.
void evt_vhf_get_input_report(PVOID client_context, VHFOPERATIONHANDLE op, PVOID, PHID_XFER_PACKET packet) {
  auto *const slot = static_cast<controller_slot *>(client_context);
  NTSTATUS status = STATUS_INVALID_DEVICE_REQUEST;
  if (slot != nullptr && slot->parent != nullptr && packet != nullptr && packet->reportBuffer != nullptr) {
    state_guard lock(slot->parent);
    std::uint8_t buffer[lvg::driver::k_max_report_bytes] {};
    UCHAR id = 0;
    const ULONG length = slot->state == slot_state::active ? build_input_report(*slot, buffer, &id) : 0;
    if (length == 0 || (packet->reportId != 0 && packet->reportId != id)) {
      status = STATUS_INVALID_DEVICE_REQUEST;
    } else if (packet->reportBufferLen < length) {
      status = STATUS_BUFFER_TOO_SMALL;
    } else {
      std::memcpy(packet->reportBuffer, buffer, length);
      status = STATUS_SUCCESS;
    }
  }
  complete(op, status);
}

// VhfDelete(..., TRUE) returns only after this has run; slots are static
// storage in the device context, so nothing needs freeing.
void evt_vhf_cleanup(PVOID) {}

// ---------------------------------------------------------------------------
// Controller lifetime

[[nodiscard]] NTSTATUS create_controller(device_context *const c, const WDFFILEOBJECT owner,
                                         const lvg::create_controller_request &request) noexcept {
  if (request.controller_id >= lvg::k_max_controllers || request.reserved != 0) return STATUS_INVALID_PARAMETER;
  profile_info profile {};
  if (!find_profile(request.requested_profile, &profile)) return STATUS_NOT_SUPPORTED;

  controller_slot &slot = c->slots[request.controller_id];
  lifetime_guard life(c);
  {
    state_guard lock(c);
    if (c->stopping) return STATUS_DEVICE_NOT_READY;
    if (slot.state != slot_state::empty) return STATUS_DEVICE_BUSY;
    reset_slot(&slot);
    slot.owner = owner;
    slot.profile = profile.id;
    slot.state = slot_state::starting;
    slot.ds5.reset();
    slot.ds5.features.address[0] = static_cast<std::uint8_t>(request.controller_id);
    slot.pump.reset();
  }

  auto abandon = [&](NTSTATUS status) {
    state_guard lock(c);
    if (slot.owner == owner) reset_slot(&slot);
    return status;
  };

  NTSTATUS status = ensure_target_open(c);
  if (!NT_SUCCESS(status)) return abandon(status);
  HANDLE file = nullptr;
  {
    state_guard lock(c);
    file = c->vhf_file;
  }
  if (file == nullptr) return abandon(STATUS_DEVICE_NOT_READY);

  // Everything the callbacks read is initialised before VhfStart, because VHF
  // may call them before VhfStart returns.
  VHF_CONFIG config;
  VHF_CONFIG_INIT(&config, file, static_cast<USHORT>(profile.descriptor_size),
                  const_cast<PUCHAR>(profile.descriptor));
  config.VhfClientContext = &slot;
  config.EvtVhfAsyncOperationWriteReport = evt_vhf_write_report;
  config.EvtVhfAsyncOperationGetInputReport = evt_vhf_get_input_report;
  config.EvtVhfReadyForNextReadReport = evt_vhf_ready_for_next_report;
  config.EvtVhfCleanup = evt_vhf_cleanup;
  if (profile.id == lvg::profile::dualsense) {
    config.EvtVhfAsyncOperationGetFeature = evt_vhf_get_feature;
    config.EvtVhfAsyncOperationSetFeature = evt_vhf_set_feature;
  }
  config.VendorID = profile.vendor_id;
  config.ProductID = profile.product_id;
  config.VersionNumber = profile.version;
  if (profile.hardware_ids != nullptr) {
    config.HardwareIDs = const_cast<PWSTR>(profile.hardware_ids);
    config.HardwareIDsLength = static_cast<USHORT>(profile.hardware_ids_bytes);
  }
  // Each pad gets its own container and instance ID; otherwise Windows groups
  // several pads as one physical device, and two pads of one model can
  // collide on their device path.
  slot.container_id = lwpad::k_container_base;
  slot.container_id.Data4[7] = static_cast<UCHAR>(request.controller_id);
  config.ContainerID = slot.container_id;
  const wchar_t prefix[] = L"LongwavePad";
  std::memcpy(slot.instance_id, prefix, sizeof(prefix));
  std::size_t n = RTL_NUMBER_OF(prefix) - 1;
  if (request.controller_id >= 10) slot.instance_id[n++] = static_cast<wchar_t>(L'0' + request.controller_id / 10);
  slot.instance_id[n++] = static_cast<wchar_t>(L'0' + request.controller_id % 10);
  slot.instance_id[n] = L'\0';
  config.InstanceID = slot.instance_id;
  config.InstanceIDLength = static_cast<USHORT>((n + 1) * sizeof(wchar_t));

  VHFHANDLE vhf = nullptr;
  status = VhfCreate(&config, &vhf);
  if (!NT_SUCCESS(status)) return abandon(status);
  // VhfStart reads slot.vhf only through its callbacks' state checks, so mark
  // the slot active after it returns; callbacks before then see "starting"
  // and decline.
  status = VhfStart(vhf);
  if (!NT_SUCCESS(status)) {
    VhfDelete(vhf, TRUE);
    return abandon(status);
  }
  bool adopted = false;
  {
    state_guard lock(c);
    if (!c->stopping && slot.owner == owner && slot.state == slot_state::starting) {
      slot.vhf = vhf;
      slot.state = slot_state::active;
      adopted = true;
    }
  }
  if (!adopted) {
    VhfDelete(vhf, TRUE);
    return abandon(STATUS_CANCELLED);
  }
  InterlockedIncrement(&c->created);
  return STATUS_SUCCESS;
}

// Deletes one pad if `owner` created it. Takes the lifetime gate itself.
bool destroy_owned(device_context *const c, const WDFFILEOBJECT owner, const std::uint32_t id) noexcept {
  if (id >= lvg::k_max_controllers) return false;
  controller_slot &slot = c->slots[id];
  lifetime_guard life(c);
  VHFHANDLE vhf = nullptr;
  {
    state_guard lock(c);
    if (slot.owner != owner || slot.state != slot_state::active) return false;
    slot.state = slot_state::stopping;
    slot.feedback_pending = false;
    vhf = slot.vhf;
    slot.vhf = nullptr;
  }
  if (vhf != nullptr) {
    VhfDelete(vhf, TRUE);  // waits for in-flight callbacks; they see "stopping"
    InterlockedIncrement(&c->destroyed);
  }
  state_guard lock(c);
  if (slot.owner == owner && slot.state == slot_state::stopping) reset_slot(&slot);
  return true;
}

// Deletes every pad, e.g. when the device stops or is removed.
void stop_all(device_context *const c, const bool forget_target) noexcept {
  VHFHANDLE handles[lvg::k_max_controllers] {};
  lifetime_guard life(c);
  {
    state_guard lock(c);
    c->stopping = true;
    c->vhf_file = nullptr;
    if (forget_target) {
      c->vhf_target = nullptr;
      c->target_open = false;
    }
    for (std::uint32_t i = 0; i < lvg::k_max_controllers; ++i) {
      controller_slot &slot = c->slots[i];
      if (slot.state == slot_state::active) {
        handles[i] = slot.vhf;
        slot.vhf = nullptr;
        slot.state = slot_state::stopping;
      }
    }
  }
  for (const VHFHANDLE h : handles) {
    if (h != nullptr) {
      VhfDelete(h, TRUE);
      InterlockedIncrement(&c->destroyed);
    }
  }
  state_guard lock(c);
  for (auto &slot : c->slots) {
    if (slot.state == slot_state::stopping) reset_slot(&slot);
  }
}

// ---------------------------------------------------------------------------
// Feeder IOCTLs

[[nodiscard]] controller_slot *owned_active(device_context *const c, const WDFFILEOBJECT owner,
                                            const std::uint32_t id) noexcept {
  if (id >= lvg::k_max_controllers) return nullptr;
  controller_slot &slot = c->slots[id];
  return (!c->stopping && slot.owner == owner && slot.state == slot_state::active) ? &slot : nullptr;
}

NTSTATUS submit_input(device_context *const c, const WDFFILEOBJECT owner,
                      const lvg::input_state_request &request) noexcept {
  if (request.reserved != 0) return STATUS_INVALID_PARAMETER;
  lifetime_guard life(c);
  std::uint8_t buffer[lvg::driver::k_max_report_bytes] {};
  UCHAR id = 0;
  ULONG length = 0;
  report_kind kind = report_kind::continuous;
  controller_slot *slot = nullptr;
  {
    state_guard lock(c);
    slot = owned_active(c, owner, request.controller_id);
    if (slot == nullptr) return STATUS_DEVICE_NOT_READY;
    slot->last_input = request;
    slot->have_input = true;
    // Button/trigger-threshold changes queue in order; analog-only changes
    // overwrite each other. That way a press is never lost to coalescing.
    kind = slot->pump.classify(request.buttons, request.left_trigger, request.right_trigger);
    length = build_input_report(*slot, buffer, &id);
  }
  return pump_report(*slot, buffer, length, id, kind);
}

NTSTATUS submit_motion(device_context *const c, const WDFFILEOBJECT owner,
                       const lvg::motion_state_request &request) noexcept {
  lifetime_guard life(c);
  std::uint8_t buffer[lvg::driver::k_max_report_bytes] {};
  UCHAR id = 0;
  ULONG length = 0;
  controller_slot *slot = nullptr;
  {
    state_guard lock(c);
    slot = owned_active(c, owner, request.controller_id);
    if (slot == nullptr) return STATUS_DEVICE_NOT_READY;
    if (slot->profile != lvg::profile::dualsense) return STATUS_NOT_SUPPORTED;
    if (!lvg::driver::apply_ds5_motion(request, &slot->ds5)) return STATUS_INVALID_PARAMETER;
    if (!slot->have_input) return STATUS_SUCCESS;  // goes out with the next input
    length = build_input_report(*slot, buffer, &id);
  }
  return pump_report(*slot, buffer, length, id, report_kind::continuous);
}

template <class T>
[[nodiscard]] NTSTATUS retrieve(WDFREQUEST request, T **const out) noexcept {
  PVOID raw = nullptr;
  size_t bytes = 0;
  const NTSTATUS status = WdfRequestRetrieveInputBuffer(request, sizeof(lvg::request_header), &raw, &bytes);
  if (!NT_SUCCESS(status)) return status;
  if (!lvg::valid_request(static_cast<T *>(raw), bytes)) return STATUS_INVALID_BUFFER_SIZE;
  *out = static_cast<T *>(raw);
  return STATUS_SUCCESS;
}

template <class T>
[[nodiscard]] NTSTATUS output_buffer(WDFREQUEST request, T **const out) noexcept {
  return WdfRequestRetrieveOutputBuffer(request, sizeof(T), reinterpret_cast<PVOID *>(out), nullptr);
}

void evt_io_device_control(WDFQUEUE queue, WDFREQUEST request, size_t, size_t, ULONG code) {
  device_context *const c = get_device_context(WdfIoQueueGetDevice(queue));
  const WDFFILEOBJECT owner = WdfRequestGetFileObject(request);
  if (owner == nullptr) {
    WdfRequestComplete(request, STATUS_INVALID_HANDLE);
    return;
  }
  NTSTATUS status = STATUS_INVALID_DEVICE_REQUEST;
  ULONG_PTR information = 0;

  switch (code) {
    case lvg::ioctl_query_info: {
      lvg::query_info_request *in = nullptr;
      lvg::query_info_response *out = nullptr;
      status = retrieve(request, &in);
      if (NT_SUCCESS(status)) status = output_buffer(request, &out);
      if (NT_SUCCESS(status)) {
        *out = {};
        out->header = {sizeof(*out), lvg::k_protocol_version, 0};
        out->minimum_protocol_version = out->maximum_protocol_version = lvg::k_protocol_version;
        out->available_profiles = k_available_profiles;
        out->available_features = lvg::feature_input_state | lvg::feature_feedback | lvg::feature_motion |
                                  lvg::feature_hid_feature_reports;
        out->maximum_controllers = lvg::k_max_controllers;
        information = sizeof(*out);
      }
      break;
    }
    case lvg::ioctl_create_controller: {
      lvg::create_controller_request *in = nullptr;
      status = retrieve(request, &in);
      if (NT_SUCCESS(status)) status = create_controller(c, owner, *in);
      break;
    }
    case lvg::ioctl_destroy_controller: {
      lvg::controller_id_request *in = nullptr;
      status = retrieve(request, &in);
      if (NT_SUCCESS(status)) status = destroy_owned(c, owner, in->controller_id) ? STATUS_SUCCESS : STATUS_NOT_FOUND;
      break;
    }
    case lvg::ioctl_submit_input_state: {
      lvg::input_state_request *in = nullptr;
      status = retrieve(request, &in);
      if (NT_SUCCESS(status)) status = submit_input(c, owner, *in);
      break;
    }
    case lvg::ioctl_submit_motion_state: {
      lvg::motion_state_request *in = nullptr;
      status = retrieve(request, &in);
      if (NT_SUCCESS(status)) status = submit_motion(c, owner, *in);
      break;
    }
    case lvg::ioctl_poll_feedback: {
      lvg::controller_id_request *in = nullptr;
      lvg::feedback_event *out = nullptr;
      status = retrieve(request, &in);
      if (NT_SUCCESS(status)) status = output_buffer(request, &out);
      if (NT_SUCCESS(status)) {
        state_guard lock(c);
        controller_slot *const slot = owned_active(c, owner, in->controller_id);
        if (slot == nullptr) {
          status = STATUS_DEVICE_NOT_READY;
        } else if (!slot->feedback_pending) {
          status = STATUS_NO_MORE_ENTRIES;
        } else {
          *out = slot->feedback;
          slot->feedback_pending = false;
          information = sizeof(*out);
        }
      }
      break;
    }
    case lwpad::ioctl_query_stats: {
      lwpad::stats_response *out = nullptr;
      status = output_buffer(request, &out);
      if (NT_SUCCESS(status)) {
        *out = {};
        out->header = {sizeof(*out), lvg::k_protocol_version, 0};
        out->controllers_created = static_cast<std::uint32_t>(c->created);
        out->controllers_destroyed = static_cast<std::uint32_t>(c->destroyed);
        out->reports_submitted = static_cast<std::uint32_t>(c->submitted);
        out->output_reports = static_cast<std::uint32_t>(c->outputs);
        out->feature_reads = static_cast<std::uint32_t>(c->features);
        out->closes_with_owned = static_cast<std::uint32_t>(c->owned_closes);
        state_guard lock(c);
        for (const auto &slot : c->slots) {
          if (slot.state == slot_state::active) ++out->controllers_active;
        }
        information = sizeof(*out);
      }
      break;
    }
    default:
      break;
  }
  WdfRequestCompleteWithInformation(request, status, information);
}

// ---------------------------------------------------------------------------
// File objects (feeder handles) and PnP

void evt_file_create(WDFDEVICE, WDFREQUEST request, WDFFILEOBJECT) {
  WdfRequestComplete(request, STATUS_SUCCESS);
}

// The feeder's handle closed - normally, or because the process died. Windows
// closes a dead process's handles for it, so this is the crash cleanup path.
void evt_file_close(WDFFILEOBJECT file) {
  device_context *const c = get_device_context(WdfFileObjectGetDevice(file));
  bool any = false;
  for (std::uint32_t id = 0; id < lvg::k_max_controllers; ++id) {
    any = destroy_owned(c, file, id) || any;
  }
  if (any) InterlockedIncrement(&c->owned_closes);
}

// WDF keeps the target's file handle valid through this callback when the
// target is deleted while open; VhfDelete must run before it goes away.
void evt_target_cleanup(WDFOBJECT object) {
  device_context *const c = get_target_context(static_cast<WDFIOTARGET>(object))->device;
  if (c != nullptr) stop_all(c, true);
}

NTSTATUS evt_prepare_hardware(WDFDEVICE device, WDFCMRESLIST, WDFCMRESLIST) {
  device_context *const c = get_device_context(device);
  lifetime_guard life(c);
  {
    state_guard lock(c);
    c->stopping = false;
  }
  // A failure here is retried on the first create rather than failing start.
  (void)ensure_target_open(c);
  return STATUS_SUCCESS;
}

NTSTATUS evt_release_hardware(WDFDEVICE device, WDFCMRESLIST) {
  device_context *const c = get_device_context(device);
  stop_all(c, false);
  lifetime_guard life(c);
  WDFIOTARGET target = nullptr;
  {
    state_guard lock(c);
    target = c->target_open ? c->vhf_target : nullptr;
    c->target_open = false;
  }
  if (target != nullptr) WdfIoTargetClose(target);
  return STATUS_SUCCESS;
}

NTSTATUS evt_device_add(WDFDRIVER, PWDFDEVICE_INIT init) {
  // The INF installs VHF as the function driver and us above it as a filter;
  // VHF stays the power policy owner.
  WdfFdoInitSetFilter(init);

  WDF_FILEOBJECT_CONFIG file_config;
  WDF_FILEOBJECT_CONFIG_INIT(&file_config, evt_file_create, evt_file_close, WDF_NO_EVENT_CALLBACK);
  WdfDeviceInitSetFileObjectConfig(init, &file_config, WDF_NO_OBJECT_ATTRIBUTES);

  WDF_PNPPOWER_EVENT_CALLBACKS pnp;
  WDF_PNPPOWER_EVENT_CALLBACKS_INIT(&pnp);
  pnp.EvtDevicePrepareHardware = evt_prepare_hardware;
  pnp.EvtDeviceReleaseHardware = evt_release_hardware;
  WdfDeviceInitSetPnpPowerEventCallbacks(init, &pnp);

  WDF_OBJECT_ATTRIBUTES attributes;
  WDF_OBJECT_ATTRIBUTES_INIT_CONTEXT_TYPE(&attributes, device_context);
  WDFDEVICE device = nullptr;
  NTSTATUS status = WdfDeviceCreate(&init, &attributes, &device);
  if (!NT_SUCCESS(status)) return status;

  device_context *const c = get_device_context(device);
  std::memset(c, 0, sizeof(*c));
  for (std::uint32_t i = 0; i < lvg::k_max_controllers; ++i) {
    c->slots[i].parent = c;
    c->slots[i].controller_id = i;
  }

  // Parent chain device -> lifetime_gate -> state_lock -> target, so both
  // locks outlive the target's cleanup callback, which takes them.
  WDF_OBJECT_ATTRIBUTES lock_attributes;
  WDF_OBJECT_ATTRIBUTES_INIT(&lock_attributes);
  lock_attributes.ParentObject = device;
  status = WdfWaitLockCreate(&lock_attributes, &c->lifetime_gate);
  if (!NT_SUCCESS(status)) return status;
  lock_attributes.ParentObject = c->lifetime_gate;
  status = WdfWaitLockCreate(&lock_attributes, &c->state_lock);
  if (!NT_SUCCESS(status)) return status;

  WDF_OBJECT_ATTRIBUTES target_attributes;
  WDF_OBJECT_ATTRIBUTES_INIT_CONTEXT_TYPE(&target_attributes, target_context);
  target_attributes.ParentObject = c->state_lock;
  target_attributes.EvtCleanupCallback = evt_target_cleanup;
  status = WdfIoTargetCreate(device, &target_attributes, &c->vhf_target);
  if (!NT_SUCCESS(status)) return status;
  get_target_context(c->vhf_target)->device = c;

  status = WdfDeviceCreateDeviceInterface(device, &lwpad::k_interface_guid, nullptr);
  if (!NT_SUCCESS(status)) return status;

  // Sequential: one feeder IOCTL at a time, which keeps reasoning simple.
  // Power-managed so stop/resume can't race controller I/O.
  WDF_IO_QUEUE_CONFIG queue_config;
  WDF_IO_QUEUE_CONFIG_INIT_DEFAULT_QUEUE(&queue_config, WdfIoQueueDispatchSequential);
  queue_config.PowerManaged = WdfTrue;
  queue_config.EvtIoDeviceControl = evt_io_device_control;
  return WdfIoQueueCreate(device, &queue_config, WDF_NO_OBJECT_ATTRIBUTES, nullptr);
}

}  // namespace

extern "C" NTSTATUS DriverEntry(PDRIVER_OBJECT driver_object, PUNICODE_STRING registry_path) {
  WDF_DRIVER_CONFIG config;
  WDF_DRIVER_CONFIG_INIT(&config, evt_device_add);
  config.DriverPoolTag = 'dpwL';
  return WdfDriverCreate(driver_object, registry_path, WDF_NO_OBJECT_ATTRIBUTES, &config, WDF_NO_HANDLE);
}
