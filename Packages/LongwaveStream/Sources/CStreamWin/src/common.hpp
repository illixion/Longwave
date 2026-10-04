// Shared helpers for the CStreamWin shim. Internal; not part of the C ABI.
#pragma once

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <d3d11_4.h>
#include <dxgi1_6.h>

#include <winrt/base.h>

#include <cstdarg>
#include <cstdio>
#include <memory>
#include <string>

#include "lw_stream.h"

namespace lw {

// Records a printf-style message as this thread's last error and returns `status`.
lw_status fail(lw_status status, const char *format, ...);

// Same, appending the HRESULT and its system message.
lw_status fail_hr(HRESULT hr, const char *what);

// Wraps an ABI entry point: converts C++/WinRT and std exceptions into a status
// so nothing unwinds across the C boundary.
template <typename F>
lw_status guarded(const char *what, F &&body) noexcept {
    try {
        return body();
    } catch (const winrt::hresult_error &e) {
        return fail_hr(e.code(), what);
    } catch (const std::exception &e) {
        return fail(LW_E_OS, "%s: %s", what, e.what());
    } catch (...) {
        return fail(LW_E_OS, "%s: unknown exception", what);
    }
}

std::string narrow(const wchar_t *wide);
std::wstring widen(const char *utf8);
void copy_string(char *dest, size_t capacity, const std::string &source);

int64_t qpc_now();
int64_t qpc_frequency();
// WinRT TimeSpan / WASAPI positions are QPC in 100 ns units; convert to raw ticks.
int64_t qpc_from_hundred_ns(int64_t hundred_ns);

// The DXGI adapter and output that drive `monitor`; false if none does.
bool find_monitor_output(HMONITOR monitor, winrt::com_ptr<IDXGIAdapter1> &adapter,
                         winrt::com_ptr<IDXGIOutput> &output);

// Raises the calling thread to an MMCSS class ("Capture", "Pro Audio");
// returns the handle for AvRevertMmThreadCharacteristics, or NULL.
HANDLE join_mmcss(const wchar_t *task);
void leave_mmcss(HANDLE handle);

// Sleeps about `microseconds` on a high-resolution waitable timer (Windows 10
// 1803+; plain Sleep's granularity is 1 ms at best), without spinning.
void precise_sleep(int64_t microseconds);

} // namespace lw

// The concrete type behind lw_device.
struct lw_device {
    winrt::com_ptr<IDXGIAdapter1> adapter;
    winrt::com_ptr<ID3D11Device> device;
    winrt::com_ptr<ID3D11DeviceContext> context;
    lw_device_info info{};
};
