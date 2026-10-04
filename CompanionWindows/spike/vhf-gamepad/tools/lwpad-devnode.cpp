// lwpad-devnode: creates, removes and reports the driver's root device node.
//
// Why this exists: a driver for real hardware is loaded when Windows finds the
// hardware. A virtual driver has no hardware, so something must create a
// "root-enumerated" device node - a device that exists because software says
// so - carrying our hardware ID (Root\LongwaveVirtualGamepad). Windows then
// matches it to our INF and loads the driver. devcon.exe and nefconc.exe do the
// same thing; this is the minimal version using only inbox SetupAPI calls, so
// nothing third-party is needed.
//
//   lwpad-devnode create <path-to-inf>   create the node (once) and install the driver on it
//   lwpad-devnode remove                 remove every node with our hardware ID (present or not)
//   lwpad-devnode status                 print instance ID, status and problem code
//
// Exit codes: 0 ok, 1 failure, 2 not found (status/remove), 3010 reboot needed.
// The install is NONINTERACTIVE: if Windows would have to ask the user anything
// (e.g. "Windows can't verify the publisher of this driver"), it fails with an
// error instead of prompting. That is how the spike proves installs are silent.

#include <windows.h>
#include <cfgmgr32.h>
#include <devguid.h>
#include <newdev.h>
#include <setupapi.h>

#include <cstdio>
#include <cwchar>
#include <string>
#include <vector>

#include "lwpad.h"

#pragma comment(lib, "setupapi.lib")
#pragma comment(lib, "newdev.lib")
#pragma comment(lib, "cfgmgr32.lib")

namespace {

// REG_MULTI_SZ: the ID, its terminator, and the list terminator.
std::vector<wchar_t> hardware_id_multi_sz() {
  std::vector<wchar_t> v(lwpad::k_root_hardware_id, lwpad::k_root_hardware_id + wcslen(lwpad::k_root_hardware_id));
  v.push_back(L'\0');
  v.push_back(L'\0');
  return v;
}

bool has_our_hardware_id(HDEVINFO set, SP_DEVINFO_DATA *info) {
  wchar_t buffer[1024] {};
  if (!SetupDiGetDeviceRegistryPropertyW(set, info, SPDRP_HARDWAREID, nullptr, reinterpret_cast<PBYTE>(buffer),
                                         sizeof(buffer) - 2 * sizeof(wchar_t), nullptr)) {
    return false;
  }
  for (const wchar_t *p = buffer; *p; p += wcslen(p) + 1) {
    if (_wcsicmp(p, lwpad::k_root_hardware_id) == 0) return true;
  }
  return false;
}

// Calls fn(set, info, instance_id) for every node (present or not) carrying our ID.
template <class Fn>
int for_each_node(Fn fn) {
  HDEVINFO set = SetupDiGetClassDevsW(&GUID_DEVCLASS_SYSTEM, nullptr, nullptr, 0);
  if (set == INVALID_HANDLE_VALUE) return -1;
  int count = 0;
  SP_DEVINFO_DATA info {sizeof(info)};
  for (DWORD i = 0; SetupDiEnumDeviceInfo(set, i, &info); ++i) {
    if (!has_our_hardware_id(set, &info)) continue;
    wchar_t id[MAX_DEVICE_ID_LEN] {};
    SetupDiGetDeviceInstanceIdW(set, &info, id, MAX_DEVICE_ID_LEN, nullptr);
    fn(set, &info, id);
    ++count;
  }
  SetupDiDestroyDeviceInfoList(set);
  return count;
}

int status() {
  const int n = for_each_node([](HDEVINFO, SP_DEVINFO_DATA *info, const wchar_t *id) {
    ULONG st = 0, problem = 0;
    const CONFIGRET cr = CM_Get_DevNode_Status(&st, &problem, info->DevInst, 0);
    if (cr == CR_NO_SUCH_DEVINST) {
      wprintf(L"node %ls: not present\n", id);
    } else {
      wprintf(L"node %ls: started=%d problem=%lu (0 = working)\n", id, (st & DN_STARTED) ? 1 : 0,
              (st & DN_HAS_PROBLEM) ? problem : 0);
    }
  });
  if (n == 0) wprintf(L"no node with hardware ID %ls\n", lwpad::k_root_hardware_id);
  return n > 0 ? 0 : 2;
}

int create(const wchar_t *inf_arg) {
  wchar_t inf[MAX_PATH] {};
  if (GetFullPathNameW(inf_arg, MAX_PATH, inf, nullptr) == 0 || GetFileAttributesW(inf) == INVALID_FILE_ATTRIBUTES) {
    fwprintf(stderr, L"INF not found: %ls\n", inf_arg);
    return 1;
  }

  // Create the node only if there isn't one already - one node serves all pads.
  int existing = for_each_node([](HDEVINFO, SP_DEVINFO_DATA *, const wchar_t *id) {
    wprintf(L"node exists: %ls\n", id);
  });
  if (existing == 0) {
    HDEVINFO set = SetupDiCreateDeviceInfoList(&GUID_DEVCLASS_SYSTEM, nullptr);
    if (set == INVALID_HANDLE_VALUE) {
      fwprintf(stderr, L"SetupDiCreateDeviceInfoList failed: %lu\n", GetLastError());
      return 1;
    }
    SP_DEVINFO_DATA info {sizeof(info)};
    const std::vector<wchar_t> ids = hardware_id_multi_sz();
    const bool ok =
      SetupDiCreateDeviceInfoW(set, L"LongwaveVirtualGamepad", &GUID_DEVCLASS_SYSTEM, nullptr, nullptr,
                               DICD_GENERATE_ID, &info) &&
      SetupDiSetDeviceRegistryPropertyW(set, &info, SPDRP_HARDWAREID, reinterpret_cast<const BYTE *>(ids.data()),
                                        static_cast<DWORD>(ids.size() * sizeof(wchar_t))) &&
      SetupDiCallClassInstaller(DIF_REGISTERDEVICE, set, &info);
    const DWORD error = GetLastError();
    SetupDiDestroyDeviceInfoList(set);
    if (!ok) {
      fwprintf(stderr, L"creating the root node failed: %lu\n", error);
      return 1;
    }
    wprintf(L"node created\n");
  }

  // Match the node to our INF and install. NONINTERACTIVE: fail, don't prompt.
  BOOL reboot = FALSE;
  if (!UpdateDriverForPlugAndPlayDevicesW(nullptr, lwpad::k_root_hardware_id, inf,
                                          INSTALLFLAG_FORCE | INSTALLFLAG_NONINTERACTIVE, &reboot)) {
    const DWORD error = GetLastError();
    fwprintf(stderr, L"UpdateDriverForPlugAndPlayDevices failed: %lu (0x%08lX)\n", error, error);
    return 1;
  }
  wprintf(L"driver installed on node%ls\n", reboot ? L" (Windows requests a reboot)" : L"");
  return reboot ? 3010 : 0;
}

int remove() {
  bool reboot = false;
  int failures = 0;
  const int n = for_each_node([&](HDEVINFO set, SP_DEVINFO_DATA *info, const wchar_t *id) {
    SP_REMOVEDEVICE_PARAMS params {};
    params.ClassInstallHeader.cbSize = sizeof(SP_CLASSINSTALL_HEADER);
    params.ClassInstallHeader.InstallFunction = DIF_REMOVE;
    params.Scope = DI_REMOVEDEVICE_GLOBAL;
    if (SetupDiSetClassInstallParamsW(set, info, &params.ClassInstallHeader, sizeof(params)) &&
        SetupDiCallClassInstaller(DIF_REMOVE, set, info)) {
      SP_DEVINSTALL_PARAMS_W install {sizeof(install)};
      if (SetupDiGetDeviceInstallParamsW(set, info, &install) && (install.Flags & (DI_NEEDREBOOT | DI_NEEDRESTART))) {
        reboot = true;
      }
      wprintf(L"removed %ls\n", id);
    } else {
      fwprintf(stderr, L"removing %ls failed: %lu\n", id, GetLastError());
      ++failures;
    }
  });
  if (n == 0) {
    wprintf(L"no node to remove\n");
    return 2;
  }
  if (failures) return 1;
  return reboot ? 3010 : 0;
}

}  // namespace

int wmain(int argc, wchar_t **argv) {
  if (argc >= 3 && wcscmp(argv[1], L"create") == 0) return create(argv[2]);
  if (argc >= 2 && wcscmp(argv[1], L"remove") == 0) return remove();
  if (argc >= 2 && wcscmp(argv[1], L"status") == 0) return status();
  fwprintf(stderr, L"usage: lwpad-devnode create <inf> | remove | status\n");
  return 1;
}
