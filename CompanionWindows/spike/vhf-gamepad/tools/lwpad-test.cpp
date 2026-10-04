// lwpad-test: drives the Longwave virtual gamepad driver and checks what games
// would see. Every check prints "PASS <name> ..." or "FAIL <name> ...", which
// run-gamepad-spike.ps1 collects into its results log.
//
//   lwpad-test info               driver protocol info + counters
//   lwpad-test xinput             Xbox pad: XInput slot, input round trip, rumble round trip, removal
//   lwpad-test wgi                Xbox pad via Windows.Gaming.Input (Gamepad), incl. vibration
//   lwpad-test hold <seconds>     create an Xbox pad, hold A + left stick right (for the kill test)
//   lwpad-test probe              print connected XInput slots and their state
//   lwpad-test cycle <n>          create/destroy n times, checking XInput sees each, then leak checks

#include <windows.h>
#include <cfgmgr32.h>
#include <devguid.h>
#include <psapi.h>
#include <setupapi.h>
#include <tlhelp32.h>
#include <xinput.h>

#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Gaming.Input.h>

#include <atomic>
#include <chrono>
#include <cstdarg>
#include <cstring>
#include <cstdio>
#include <cstdlib>
#include <cwchar>
#include <functional>
#include <string>
#include <thread>

#include "lwpad_client.h"

#pragma comment(lib, "xinput.lib")
#pragma comment(lib, "setupapi.lib")
#pragma comment(lib, "winmm.lib")
#pragma comment(lib, "windowsapp.lib")
#pragma comment(lib, "advapi32.lib")
#pragma comment(lib, "psapi.lib")
#pragma comment(lib, "user32.lib")

namespace {

int g_failures = 0;

void pass(const char *name, const char *fmt = "", ...) {
  std::printf("PASS %s ", name);
  va_list args;
  va_start(args, fmt);
  std::vprintf(fmt, args);
  va_end(args);
  std::printf("\n");
  std::fflush(stdout);
}

void fail(const char *name, const char *fmt = "", ...) {
  ++g_failures;
  std::printf("FAIL %s ", name);
  va_list args;
  va_start(args, fmt);
  std::vprintf(fmt, args);
  va_end(args);
  std::printf("\n");
  std::fflush(stdout);
}

// A check that couldn't run meaningfully here (e.g. no foreground window).
void skip(const char *name, const char *fmt, ...) {
  std::printf("SKIP %s ", name);
  va_list args;
  va_start(args, fmt);
  std::vprintf(fmt, args);
  va_end(args);
  std::printf("\n");
  std::fflush(stdout);
}

void info(const char *fmt, ...) {
  std::printf("INFO ");
  va_list args;
  va_start(args, fmt);
  std::vprintf(fmt, args);
  va_end(args);
  std::printf("\n");
  std::fflush(stdout);
}

using clock_type = std::chrono::steady_clock;

double ms_since(clock_type::time_point t) {
  return std::chrono::duration<double, std::milli>(clock_type::now() - t).count();
}

// Polls `done` every millisecond until it returns true or `timeout_ms` passes.
bool wait_for(int timeout_ms, const std::function<bool()> &done) {
  const auto start = clock_type::now();
  while (ms_since(start) < timeout_ms) {
    if (done()) return true;
    Sleep(1);
  }
  return done();
}

DWORD xinput_connected_mask() {
  DWORD mask = 0;
  for (DWORD i = 0; i < XUSER_MAX_COUNT; ++i) {
    XINPUT_STATE s {};
    if (XInputGetState(i, &s) == ERROR_SUCCESS) mask |= 1u << i;
  }
  return mask;
}

bool open_driver(lwpad_client &client) {
  if (client.open()) return true;
  fail("open-driver", "error=%lu (is the driver installed and its device started?)", client.last_error);
  return false;
}

void print_stats(lwpad_client &client, const char *label) {
  lwpad::stats_response s {};
  if (client.stats(&s)) {
    info("stats[%s] created=%u destroyed=%u active=%u reports=%u outputs=%u features=%u owned_closes=%u", label,
         s.controllers_created, s.controllers_destroyed, s.controllers_active, s.reports_submitted, s.output_reports,
         s.feature_reads, s.closes_with_owned);
  }
}

// Creates Xbox pad `id` and returns the XInput slot that appeared, or -1.
int create_xbox_and_find_slot(lwpad_client &client, std::uint32_t id, double *elapsed_ms = nullptr) {
  const DWORD before = xinput_connected_mask();
  const auto start = clock_type::now();
  if (!client.create(id, lvg::profile::xbox_series)) {
    fail("create", "id=%u error=%lu", id, client.last_error);
    return -1;
  }
  // The first report makes the state readable; send neutral.
  client.input(id, 0);
  int slot = -1;
  wait_for(5000, [&] {
    const DWORD added = xinput_connected_mask() & ~before;
    for (int i = 0; i < XUSER_MAX_COUNT; ++i) {
      if (added & (1u << i)) {
        slot = i;
        return true;
      }
    }
    return false;
  });
  if (elapsed_ms) *elapsed_ms = ms_since(start);
  return slot;
}

// ---------------------------------------------------------------------------

int cmd_info() {
  lwpad_client client;
  if (!open_driver(client)) return 1;
  lvg::query_info_response r {};
  if (!client.query_info(&r)) {
    fail("query-info", "error=%lu", client.last_error);
    return 1;
  }
  pass("query-info", "protocol=%u profiles=0x%x features=0x%x max_controllers=%u", r.maximum_protocol_version,
       r.available_profiles, r.available_features, r.maximum_controllers);
  std::wprintf(L"INFO interface %ls\n", client.path.c_str());
  print_stats(client, "now");
  return g_failures ? 1 : 0;
}

struct input_case {
  const char *name;
  std::uint32_t buttons;
  std::int16_t lx, ly, rx, ry;
  std::uint8_t lt, rt;
  WORD expect_buttons;
};

int cmd_xinput() {
  timeBeginPeriod(1);
  lwpad_client client;
  if (!open_driver(client)) return 1;
  double create_ms = 0;
  const int slot = create_xbox_and_find_slot(client, 0, &create_ms);
  if (slot < 0) {
    fail("xinput-slot", "no new XInput slot within 5 s of creating the pad");
    return 1;
  }
  pass("xinput-slot", "slot=%d appeared %.0f ms after create", slot, create_ms);

  XINPUT_CAPABILITIES caps {};
  if (XInputGetCapabilities(slot, 0, &caps) == ERROR_SUCCESS) {
    info("caps type=%u subtype=%u flags=0x%x", caps.Type, caps.SubType, caps.Flags);
  }

  using namespace lvg;
  const input_case cases[] = {
    {"A", south, 0, 0, 0, 0, 0, 0, XINPUT_GAMEPAD_A},
    {"B", east, 0, 0, 0, 0, 0, 0, XINPUT_GAMEPAD_B},
    {"X", west, 0, 0, 0, 0, 0, 0, XINPUT_GAMEPAD_X},
    {"Y", north, 0, 0, 0, 0, 0, 0, XINPUT_GAMEPAD_Y},
    {"LB", left_shoulder, 0, 0, 0, 0, 0, 0, XINPUT_GAMEPAD_LEFT_SHOULDER},
    {"RB", right_shoulder, 0, 0, 0, 0, 0, 0, XINPUT_GAMEPAD_RIGHT_SHOULDER},
    {"Back", back, 0, 0, 0, 0, 0, 0, XINPUT_GAMEPAD_BACK},
    {"Start", start, 0, 0, 0, 0, 0, 0, XINPUT_GAMEPAD_START},
    {"LS", left_stick, 0, 0, 0, 0, 0, 0, XINPUT_GAMEPAD_LEFT_THUMB},
    {"RS", right_stick, 0, 0, 0, 0, 0, 0, XINPUT_GAMEPAD_RIGHT_THUMB},
    {"Up", dpad_up, 0, 0, 0, 0, 0, 0, XINPUT_GAMEPAD_DPAD_UP},
    {"Down", dpad_down, 0, 0, 0, 0, 0, 0, XINPUT_GAMEPAD_DPAD_DOWN},
    {"Left", dpad_left, 0, 0, 0, 0, 0, 0, XINPUT_GAMEPAD_DPAD_LEFT},
    {"Right", dpad_right, 0, 0, 0, 0, 0, 0, XINPUT_GAMEPAD_DPAD_RIGHT},
    {"UpRight", dpad_up | dpad_right, 0, 0, 0, 0, 0, 0, XINPUT_GAMEPAD_DPAD_UP | XINPUT_GAMEPAD_DPAD_RIGHT},
    {"A+B+LB", south | east | left_shoulder, 0, 0, 0, 0, 0, 0,
     XINPUT_GAMEPAD_A | XINPUT_GAMEPAD_B | XINPUT_GAMEPAD_LEFT_SHOULDER},
    {"LX+max", 0, 32767, 0, 0, 0, 0, 0, 0},
    {"LX-min", 0, -32768, 0, 0, 0, 0, 0, 0},
    {"LY+up", 0, 0, 32767, 0, 0, 0, 0, 0},
    {"LY-down", 0, 0, -32768, 0, 0, 0, 0, 0},
    {"RX+half", 0, 0, 0, 16384, 0, 0, 0, 0},
    {"RY-half", 0, 0, 0, 0, -16384, 0, 0, 0},
    {"Diag", 0, 12345, -23456, -1000, 30000, 0, 0, 0},
    {"LT-full", 0, 0, 0, 0, 0, 255, 0, 0},
    {"RT-full", 0, 0, 0, 0, 0, 0, 255, 0},
    {"Triggers-mid", 0, 0, 0, 0, 0, 64, 192, 0},
    {"Neutral", 0, 0, 0, 0, 0, 0, 0, 0},
  };

  const int stick_tolerance = 64;  // HID unsigned 16-bit -> XInput signed; rounding only
  const int trigger_tolerance = 2; // 8-bit -> 10-bit -> 8-bit
  double worst_ms = 0, total_ms = 0;
  int measured = 0;
  for (const input_case &c : cases) {
    const auto start = clock_type::now();
    if (!client.input(0, c.buttons, c.lx, c.ly, c.rx, c.ry, c.lt, c.rt)) {
      fail("xinput-input", "%s: submit error=%lu", c.name, client.last_error);
      continue;
    }
    XINPUT_STATE s {};
    auto matches = [&] {
      if (XInputGetState(slot, &s) != ERROR_SUCCESS) return false;
      const XINPUT_GAMEPAD &g = s.Gamepad;
      return g.wButtons == c.expect_buttons && std::abs(g.sThumbLX - c.lx) <= stick_tolerance &&
             std::abs(g.sThumbLY - c.ly) <= stick_tolerance && std::abs(g.sThumbRX - c.rx) <= stick_tolerance &&
             std::abs(g.sThumbRY - c.ry) <= stick_tolerance && std::abs(g.bLeftTrigger - c.lt) <= trigger_tolerance &&
             std::abs(g.bRightTrigger - c.rt) <= trigger_tolerance;
    };
    const bool ok = wait_for(1000, matches);
    const double ms = ms_since(start);
    const XINPUT_GAMEPAD &g = s.Gamepad;
    if (ok) {
      worst_ms = ms > worst_ms ? ms : worst_ms;
      total_ms += ms;
      ++measured;
      pass("xinput-input", "%-12s buttons=0x%04x LX=%d LY=%d RX=%d RY=%d LT=%u RT=%u (%.1f ms)", c.name, g.wButtons,
           g.sThumbLX, g.sThumbLY, g.sThumbRX, g.sThumbRY, g.bLeftTrigger, g.bRightTrigger, ms);
    } else {
      fail("xinput-input", "%-12s want buttons=0x%04x LX=%d LY=%d RX=%d RY=%d LT=%u RT=%u got 0x%04x %d %d %d %d %u %u",
           c.name, c.expect_buttons, c.lx, c.ly, c.rx, c.ry, c.lt, c.rt, g.wButtons, g.sThumbLX, g.sThumbLY,
           g.sThumbRX, g.sThumbRY, g.bLeftTrigger, g.bRightTrigger);
    }
  }
  if (measured) info("submit->XInputGetState latency: mean %.2f ms, worst %.2f ms (1 ms polling)", total_ms / measured, worst_ms);

  // Rumble: XInputSetState -> xinputhid -> HID output report -> our driver ->
  // feedback event the feeder polls.
  struct rumble_case {
    WORD left, right;
  };
  for (const rumble_case r : {rumble_case {0x8000, 0xFFFF}, rumble_case {0xFFFF, 0x0000}, rumble_case {0, 0}}) {
    lvg::feedback_event drain {};
    while (client.poll_feedback(0, &drain)) {
    }
    XINPUT_VIBRATION v {r.left, r.right};
    const auto start = clock_type::now();
    const DWORD rc = XInputSetState(slot, &v);
    lvg::feedback_event ev {};
    lvg::xbox_rumble_feedback fb {};
    const bool got = wait_for(1000, [&] {
      if (!client.poll_feedback(0, &ev)) return false;
      std::memcpy(&fb, ev.payload, sizeof(fb));
      return ev.type == lvg::feedback_type::xbox_rumble && std::abs(int(fb.low_frequency) - r.left) <= 700 &&
             std::abs(int(fb.high_frequency) - r.right) <= 700;
    });
    if (got) {
      pass("xinput-rumble", "set L=%u R=%u -> driver got low=%u high=%u lt=%u rt=%u (%.1f ms)", r.left, r.right,
           fb.low_frequency, fb.high_frequency, fb.left_trigger, fb.right_trigger, ms_since(start));
    } else {
      fail("xinput-rumble", "set L=%u R=%u (XInputSetState rc=%lu) -> no matching feedback; last type=%u low=%u high=%u",
           r.left, r.right, rc, static_cast<unsigned>(ev.type), fb.low_frequency, fb.high_frequency);
    }
  }

  if (!client.destroy(0)) fail("destroy", "error=%lu", client.last_error);
  const auto start = clock_type::now();
  if (wait_for(5000, [&] { return (xinput_connected_mask() & (1u << slot)) == 0; })) {
    pass("xinput-removed", "slot %d disconnected %.0f ms after destroy", slot, ms_since(start));
  } else {
    fail("xinput-removed", "slot %d still connected 5 s after destroy", slot);
  }
  print_stats(client, "end");
  return g_failures ? 1 : 0;
}

// Windows.Gaming.Input only hands readings (and accepts vibration) for the
// process that owns the FOREGROUND window - a game in the background gets
// zeros. A console tool has no window of its own, so this test makes one and
// asks for the foreground, and says whether it got it.
HWND make_foreground_window() {
  WNDCLASSW wc {};
  wc.lpfnWndProc = DefWindowProcW;
  wc.hInstance = GetModuleHandleW(nullptr);
  wc.lpszClassName = L"lwpad-wgi-test";
  wc.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);
  RegisterClassW(&wc);
  HWND hwnd = CreateWindowExW(WS_EX_TOPMOST, wc.lpszClassName, L"Longwave gamepad WGI test (closes itself)",
                              WS_OVERLAPPEDWINDOW | WS_VISIBLE, 100, 100, 480, 120, nullptr, nullptr, wc.hInstance,
                              nullptr);
  ShowWindow(hwnd, SW_SHOW);
  if (!SetForegroundWindow(hwnd)) {
    // Windows only lets a process take the foreground in some situations (it
    // was just started by the foreground process, etc.). Failing that, briefly
    // share input state with the current foreground thread, which is allowed.
    const HWND current = GetForegroundWindow();
    const DWORD their_thread = current ? GetWindowThreadProcessId(current, nullptr) : 0;
    const DWORD our_thread = GetCurrentThreadId();
    if (their_thread != 0 && their_thread != our_thread && AttachThreadInput(our_thread, their_thread, TRUE)) {
      BringWindowToTop(hwnd);
      SetForegroundWindow(hwnd);
      AttachThreadInput(our_thread, their_thread, FALSE);
    }
  }
  return hwnd;
}

void pump_messages() {
  MSG msg;
  while (PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) {
    TranslateMessage(&msg);
    DispatchMessageW(&msg);
  }
}

int cmd_wgi() {
  using namespace winrt::Windows::Gaming::Input;
  winrt::init_apartment(winrt::apartment_type::single_threaded);
  lwpad_client client;
  if (!open_driver(client)) return 1;

  const HWND hwnd = make_foreground_window();
  auto wait_pumping = [&](int ms, const std::function<bool()> &done) {
    return wait_for(ms, [&] {
      pump_messages();
      return done();
    });
  };
  wait_pumping(300, [] { return false; });
  const bool foreground = GetForegroundWindow() == hwnd;
  info("WGI test window is %s", foreground ? "the foreground window" : "NOT the foreground window (WGI will read zeros)");

  // WGI discovers controllers asynchronously through a system broker and
  // announces them with GamepadAdded - the documented way to find a pad.
  Gamepad added {nullptr};
  std::atomic<int> raw_added {0};
  const auto gamepad_token = Gamepad::GamepadAdded([&](auto &&, const Gamepad &g) { added = g; });
  const auto raw_token = RawGameController::RawGameControllerAdded([&](auto &&, auto &&) { ++raw_added; });
  wait_pumping(1500, [] { return false; });  // let WGI report what's already there
  const uint32_t before = Gamepad::Gamepads().Size();
  added = nullptr;
  info("WGI gamepads before: %u", before);

  const auto created_at = clock_type::now();
  if (!client.create(0, lvg::profile::xbox_series)) {
    fail("create", "error=%lu", client.last_error);
    return 1;
  }
  client.input(0, 0);
  wait_pumping(10000, [&] { return static_cast<bool>(added); });
  Gamepad pad = added;
  Gamepad::GamepadAdded(gamepad_token);
  RawGameController::RawGameControllerAdded(raw_token);
  if (!pad) {
    fail("wgi-gamepad", "no GamepadAdded within 10 s (RawGameControllerAdded fired %d times, Gamepads=%u)",
         raw_added.load(), Gamepad::Gamepads().Size());
    client.destroy(0);
    DestroyWindow(hwnd);
    return 1;
  }
  info("GamepadAdded %.0f ms after create", ms_since(created_at));
  auto raw = RawGameController::FromGameController(pad);
  pass("wgi-gamepad", "appeared; vid=%04x pid=%04x name='%ls' wireless=%d", raw ? raw.HardwareVendorId() : 0,
       raw ? raw.HardwareProductId() : 0, raw ? raw.DisplayName().c_str() : L"?", pad.IsWireless() ? 1 : 0);

  void (*report)(const char *, const char *, ...) = foreground ? fail : skip;
  client.input(0, lvg::south | lvg::right_shoulder, 32767, 0, 0, 0, 0, 255);
  GamepadReading r {};
  const bool ok = wait_pumping(1000, [&] {
    r = pad.GetCurrentReading();
    return (r.Buttons & GamepadButtons::A) == GamepadButtons::A &&
           (r.Buttons & GamepadButtons::RightShoulder) == GamepadButtons::RightShoulder && r.LeftThumbstickX > 0.99 &&
           r.RightTrigger > 0.99;
  });
  if (ok) {
    pass("wgi-input", "A+RB, LX=%.3f RT=%.3f", r.LeftThumbstickX, r.RightTrigger);
  } else {
    report("wgi-input", "buttons=0x%x LX=%.3f RT=%.3f%s", static_cast<unsigned>(r.Buttons), r.LeftThumbstickX,
           r.RightTrigger, foreground ? "" : " (inconclusive: no foreground window)");
  }

  lvg::feedback_event ev {};
  while (client.poll_feedback(0, &ev)) {
  }
  GamepadVibration vib {};
  vib.LeftMotor = 0.5;
  vib.RightMotor = 1.0;
  vib.LeftTrigger = 0.25;
  vib.RightTrigger = 0.75;
  pad.Vibration(vib);
  lvg::xbox_rumble_feedback fb {};
  const bool got = wait_pumping(1000, [&] {
    if (!client.poll_feedback(0, &ev)) return false;
    std::memcpy(&fb, ev.payload, sizeof(fb));
    return ev.type == lvg::feedback_type::xbox_rumble && fb.high_frequency > 60000 && fb.right_trigger > 40000;
  });
  if (got) {
    pass("wgi-vibration", "driver got low=%u high=%u lt=%u rt=%u (impulse triggers reach the driver)",
         fb.low_frequency, fb.high_frequency, fb.left_trigger, fb.right_trigger);
  } else {
    report("wgi-vibration", "last type=%u low=%u high=%u lt=%u rt=%u%s", static_cast<unsigned>(ev.type),
           fb.low_frequency, fb.high_frequency, fb.left_trigger, fb.right_trigger,
           foreground ? "" : " (inconclusive: no foreground window)");
  }
  pad.Vibration(GamepadVibration {});
  client.destroy(0);
  DestroyWindow(hwnd);
  return g_failures ? 1 : 0;
}

int cmd_hold(int seconds) {
  lwpad_client client;
  if (!open_driver(client)) return 1;
  const int slot = create_xbox_and_find_slot(client, 0);
  std::printf("READY slot=%d pid=%lu\n", slot, GetCurrentProcessId());
  std::fflush(stdout);
  const auto start = clock_type::now();
  while (ms_since(start) < seconds * 1000.0) {
    client.input(0, lvg::south, 32767, 0, 0, 0, 0, 200);
    Sleep(8);
  }
  return 0;
}

int cmd_probe() {
  for (DWORD i = 0; i < XUSER_MAX_COUNT; ++i) {
    XINPUT_STATE s {};
    const DWORD rc = XInputGetState(i, &s);
    if (rc == ERROR_SUCCESS) {
      const XINPUT_GAMEPAD &g = s.Gamepad;
      std::printf("SLOT %lu connected buttons=0x%04x LX=%d LY=%d RX=%d RY=%d LT=%u RT=%u packet=%lu\n", i, g.wButtons,
                  g.sThumbLX, g.sThumbLY, g.sThumbRX, g.sThumbRY, g.bLeftTrigger, g.bRightTrigger, s.dwPacketNumber);
    } else {
      std::printf("SLOT %lu not connected\n", i);
    }
  }
  lwpad_client client;
  if (client.open()) print_stats(client, "probe");
  return 0;
}

// --- leak checks -------------------------------------------------------------

struct host_usage {
  DWORD pid = 0;
  DWORD handles = 0;
  SIZE_T private_bytes = 0;
  DWORD threads = 0;
};

void enable_debug_privilege() {
  HANDLE token = nullptr;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, &token)) return;
  TOKEN_PRIVILEGES tp {1};
  if (LookupPrivilegeValueW(nullptr, SE_DEBUG_NAME, &tp.Privileges[0].Luid)) {
    tp.Privileges[0].Attributes = SE_PRIVILEGE_ENABLED;
    AdjustTokenPrivileges(token, FALSE, &tp, 0, nullptr, nullptr);
  }
  CloseHandle(token);
}

// Finds the WUDFHost.exe that has our driver DLL loaded.
host_usage find_driver_host() {
  host_usage usage;
  HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  PROCESSENTRY32W pe {sizeof(pe)};
  for (BOOL more = Process32FirstW(snap, &pe); more; more = Process32NextW(snap, &pe)) {
    if (_wcsicmp(pe.szExeFile, L"WUDFHost.exe") != 0) continue;
    HANDLE p = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, FALSE, pe.th32ProcessID);
    if (!p) continue;
    HMODULE modules[512];
    DWORD needed = 0;
    if (EnumProcessModulesEx(p, modules, sizeof(modules), &needed, LIST_MODULES_ALL)) {
      for (DWORD i = 0; i < needed / sizeof(HMODULE) && i < 512; ++i) {
        wchar_t name[MAX_PATH] {};
        GetModuleBaseNameW(p, modules[i], name, MAX_PATH);
        if (_wcsicmp(name, L"LongwaveVirtualGamepad.dll") == 0) {
          usage.pid = pe.th32ProcessID;
          GetProcessHandleCount(p, &usage.handles);
          PROCESS_MEMORY_COUNTERS_EX pmc {sizeof(pmc)};
          if (GetProcessMemoryInfo(p, reinterpret_cast<PROCESS_MEMORY_COUNTERS *>(&pmc), sizeof(pmc))) {
            usage.private_bytes = pmc.PrivateUsage;
          }
          usage.threads = pe.cntThreads;
        }
      }
    }
    CloseHandle(p);
    if (usage.pid) break;
  }
  CloseHandle(snap);
  return usage;
}

// Counts HID device nodes created by our driver: present, and in total
// (non-present "phantom" nodes are what a leak in PnP would look like).
void count_our_hid_nodes(int *present, int *total) {
  *present = *total = 0;
  for (int pass_no = 0; pass_no < 2; ++pass_no) {
    HDEVINFO set = SetupDiGetClassDevsW(&GUID_DEVCLASS_HIDCLASS, nullptr, nullptr, pass_no == 0 ? DIGCF_PRESENT : 0);
    SP_DEVINFO_DATA d {sizeof(d)};
    for (DWORD i = 0; SetupDiEnumDeviceInfo(set, i, &d); ++i) {
      wchar_t id[MAX_DEVICE_ID_LEN] {};
      SetupDiGetDeviceInstanceIdW(set, &d, id, MAX_DEVICE_ID_LEN, nullptr);
      _wcsupr_s(id);
      if (wcsstr(id, L"LONGWAVEPAD")) ++(pass_no == 0 ? *present : *total);
    }
    SetupDiDestroyDeviceInfoList(set);
  }
}

int cmd_cycle(int count) {
  timeBeginPeriod(1);
  enable_debug_privilege();
  lwpad_client client;
  if (!open_driver(client)) return 1;

  // Warm-up cycle so first-use allocations don't read as a leak.
  {
    const int slot = create_xbox_and_find_slot(client, 0);
    client.destroy(0);
    if (slot >= 0) wait_for(5000, [&] { return (xinput_connected_mask() & (1u << slot)) == 0; });
  }
  const host_usage before = find_driver_host();
  int hid_present_before = 0, hid_total_before = 0;
  count_our_hid_nodes(&hid_present_before, &hid_total_before);
  print_stats(client, "before");
  info("WUDFHost pid=%lu handles=%lu private=%zu KB threads=%lu; our HID nodes present=%d total=%d", before.pid,
       before.handles, before.private_bytes / 1024, before.threads, hid_present_before, hid_total_before);

  int create_failures = 0, xinput_failures = 0, remove_failures = 0;
  double worst_appear = 0, total_appear = 0, worst_remove = 0;
  const auto start = clock_type::now();
  for (int i = 0; i < count; ++i) {
    double appear = 0;
    const int slot = create_xbox_and_find_slot(client, 0, &appear);
    if (slot < 0) {
      ++xinput_failures;
      if (!client.destroy(0)) ++create_failures;
      continue;
    }
    total_appear += appear;
    worst_appear = appear > worst_appear ? appear : worst_appear;
    // One input round trip per cycle, so each pad is proven usable.
    client.input(0, lvg::south);
    XINPUT_STATE s {};
    if (!wait_for(1000, [&] { return XInputGetState(slot, &s) == ERROR_SUCCESS && (s.Gamepad.wButtons & XINPUT_GAMEPAD_A); })) {
      ++xinput_failures;
    }
    if (!client.destroy(0)) ++create_failures;
    const auto removed_at = clock_type::now();
    if (!wait_for(5000, [&] { return (xinput_connected_mask() & (1u << slot)) == 0; })) ++remove_failures;
    const double removal = ms_since(removed_at);
    worst_remove = removal > worst_remove ? removal : worst_remove;
    if ((i + 1) % 50 == 0) info("cycle %d/%d (%.0f s)", i + 1, count, ms_since(start) / 1000);
  }
  const host_usage after = find_driver_host();
  int hid_present_after = 0, hid_total_after = 0;
  count_our_hid_nodes(&hid_present_after, &hid_total_after);
  print_stats(client, "after");
  info("WUDFHost pid=%lu handles=%lu private=%zu KB threads=%lu; our HID nodes present=%d total=%d", after.pid,
       after.handles, after.private_bytes / 1024, after.threads, hid_present_after, hid_total_after);
  info("%d cycles in %.1f s; appear mean %.0f ms worst %.0f ms; removal worst %.0f ms", count,
       ms_since(start) / 1000, count ? total_appear / count : 0, worst_appear, worst_remove);

  if (create_failures == 0 && xinput_failures == 0 && remove_failures == 0) {
    pass("cycle", "%d create/use/destroy cycles, no failures", count);
  } else {
    fail("cycle", "ioctl failures=%d xinput failures=%d removal failures=%d", create_failures, xinput_failures,
         remove_failures);
  }
  // Leak criteria: same host process; handle count and private bytes not
  // growing with the cycle count; no growth in phantom HID nodes.
  if (after.pid != before.pid) {
    fail("cycle-host", "WUDFHost pid changed %lu -> %lu (host restarted = driver crashed?)", before.pid, after.pid);
  } else {
    pass("cycle-host", "same WUDFHost pid %lu throughout", after.pid);
  }
  const long handle_growth = static_cast<long>(after.handles) - static_cast<long>(before.handles);
  const long long mem_growth_kb = (static_cast<long long>(after.private_bytes) - static_cast<long long>(before.private_bytes)) / 1024;
  if (handle_growth <= 20 && mem_growth_kb <= 2048) {
    pass("cycle-leaks", "WUDFHost handle growth %ld, private bytes growth %lld KB over %d cycles", handle_growth,
         mem_growth_kb, count);
  } else {
    fail("cycle-leaks", "WUDFHost handle growth %ld, private bytes growth %lld KB over %d cycles", handle_growth,
         mem_growth_kb, count);
  }
  if (hid_total_after <= hid_total_before && hid_present_after == hid_present_before) {
    pass("cycle-pnp", "HID nodes present %d -> %d, total incl. phantom %d -> %d", hid_present_before,
         hid_present_after, hid_total_before, hid_total_after);
  } else {
    fail("cycle-pnp", "HID nodes present %d -> %d, total incl. phantom %d -> %d", hid_present_before,
         hid_present_after, hid_total_before, hid_total_after);
  }
  return g_failures ? 1 : 0;
}

}  // namespace

int main(int argc, char **argv) {
  const std::string cmd = argc > 1 ? argv[1] : "";
  if (cmd == "info") return cmd_info();
  if (cmd == "xinput") return cmd_xinput();
  if (cmd == "wgi") return cmd_wgi();
  if (cmd == "hold") return cmd_hold(argc > 2 ? std::atoi(argv[2]) : 30);
  if (cmd == "probe") return cmd_probe();
  if (cmd == "cycle") return cmd_cycle(argc > 2 ? std::atoi(argv[2]) : 200);
  std::fprintf(stderr, "usage: lwpad-test info|xinput|wgi|hold <s>|probe|cycle <n>\n");
  return 2;
}
