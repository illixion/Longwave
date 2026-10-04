// Process set-up, errors, clock, displays and the shared D3D11 device.
#include "common.hpp"

#include <avrt.h>
#include <timeapi.h>

#include <vector>

namespace lw {

static thread_local std::string g_last_error;

lw_status fail(lw_status status, const char *format, ...) {
    char buffer[1024];
    va_list args;
    va_start(args, format);
    vsnprintf(buffer, sizeof buffer, format, args);
    va_end(args);
    g_last_error = buffer;
    return status;
}

lw_status fail_hr(HRESULT hr, const char *what) {
    wchar_t *message = nullptr;
    FormatMessageW(FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
                       FORMAT_MESSAGE_IGNORE_INSERTS,
                   nullptr, static_cast<DWORD>(hr), 0, reinterpret_cast<LPWSTR>(&message), 0,
                   nullptr);
    std::string text = message ? narrow(message) : std::string();
    if (message) LocalFree(message);
    while (!text.empty() && (text.back() == '\n' || text.back() == '\r' || text.back() == ' '))
        text.pop_back();
    lw_status status = LW_E_OS;
    if (hr == DXGI_ERROR_ACCESS_LOST || hr == DXGI_ERROR_DEVICE_REMOVED ||
        hr == DXGI_ERROR_DEVICE_RESET)
        status = LW_E_ACCESS_LOST;
    return fail(status, "%s failed (0x%08lX%s%s)", what, static_cast<unsigned long>(hr),
                text.empty() ? "" : ": ", text.c_str());
}

std::string narrow(const wchar_t *wide) {
    if (!wide || !*wide) return {};
    int length = WideCharToMultiByte(CP_UTF8, 0, wide, -1, nullptr, 0, nullptr, nullptr);
    std::string out(static_cast<size_t>(length > 0 ? length - 1 : 0), '\0');
    if (length > 1) WideCharToMultiByte(CP_UTF8, 0, wide, -1, out.data(), length, nullptr, nullptr);
    return out;
}

std::wstring widen(const char *utf8) {
    if (!utf8 || !*utf8) return {};
    int length = MultiByteToWideChar(CP_UTF8, 0, utf8, -1, nullptr, 0);
    std::wstring out(static_cast<size_t>(length > 0 ? length - 1 : 0), L'\0');
    if (length > 1) MultiByteToWideChar(CP_UTF8, 0, utf8, -1, out.data(), length);
    return out;
}

void copy_string(char *dest, size_t capacity, const std::string &source) {
    if (!dest || capacity == 0) return;
    size_t n = source.size() < capacity - 1 ? source.size() : capacity - 1;
    memcpy(dest, source.data(), n);
    dest[n] = '\0';
}

int64_t qpc_now() {
    LARGE_INTEGER value;
    QueryPerformanceCounter(&value);
    return value.QuadPart;
}

int64_t qpc_frequency() {
    static const int64_t frequency = [] {
        LARGE_INTEGER value;
        QueryPerformanceFrequency(&value);
        return value.QuadPart;
    }();
    return frequency;
}

int64_t qpc_from_hundred_ns(int64_t hundred_ns) {
    // Split to avoid overflow: hundred_ns * frequency can exceed 2^63.
    const int64_t f = qpc_frequency();
    const int64_t whole = hundred_ns / 10'000'000;
    const int64_t rest = hundred_ns % 10'000'000;
    return whole * f + rest * f / 10'000'000;
}

HANDLE join_mmcss(const wchar_t *task) {
    DWORD index = 0;
    return AvSetMmThreadCharacteristicsW(task, &index);
}

void leave_mmcss(HANDLE handle) {
    if (handle) AvRevertMmThreadCharacteristics(handle);
}

void precise_sleep(int64_t microseconds) {
    if (microseconds <= 0) return;
    struct Timer {
        HANDLE handle = CreateWaitableTimerExW(nullptr, nullptr, CREATE_WAITABLE_TIMER_HIGH_RESOLUTION,
                                               TIMER_ALL_ACCESS);
        ~Timer() {
            if (handle) CloseHandle(handle);
        }
    };
    static thread_local Timer timer;
    if (!timer.handle) {
        Sleep(static_cast<DWORD>((microseconds + 999) / 1000));
        return;
    }
    LARGE_INTEGER due;
    due.QuadPart = -microseconds * 10; // relative, 100 ns units
    SetWaitableTimer(timer.handle, &due, 0, nullptr, nullptr, FALSE);
    WaitForSingleObject(timer.handle, INFINITE);
}

} // namespace lw

using namespace lw;

extern "C" const char *lw_last_error(void) { return g_last_error.c_str(); }

extern "C" int64_t lw_qpc_now(void) { return qpc_now(); }
extern "C" int64_t lw_qpc_frequency(void) { return qpc_frequency(); }

extern "C" lw_status lw_runtime_init(void) {
    return guarded("lw_runtime_init", [] {
        // Physical-pixel coordinates everywhere; DXGI duplication also refuses
        // some outputs to DPI-unaware processes.
        if (!SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)) {
            DWORD error = GetLastError();
            // ERROR_ACCESS_DENIED means a manifest already set it: fine.
            if (error != ERROR_ACCESS_DENIED) return fail_hr(HRESULT_FROM_WIN32(error), "SetProcessDpiAwarenessContext");
        }
        try {
            winrt::init_apartment(winrt::apartment_type::multi_threaded);
        } catch (const winrt::hresult_error &e) {
            // RPC_E_CHANGED_MODE: the host already chose an apartment; capture
            // still works from free-threaded frame pools.
            if (e.code() != RPC_E_CHANGED_MODE) throw;
        }
        timeBeginPeriod(1);
        qpc_frequency();
        return LW_OK;
    });
}

// ---- Displays -----------------------------------------------------------------

namespace {

struct MonitorCollector {
    std::vector<lw_monitor_info> monitors;
};

BOOL CALLBACK collect_monitor(HMONITOR monitor, HDC, LPRECT, LPARAM param) {
    auto *collector = reinterpret_cast<MonitorCollector *>(param);
    MONITORINFOEXW info{};
    info.cbSize = sizeof info;
    if (!GetMonitorInfoW(monitor, &info)) return TRUE;
    lw_monitor_info out{};
    out.handle = monitor;
    out.x = info.rcMonitor.left;
    out.y = info.rcMonitor.top;
    out.width = info.rcMonitor.right - info.rcMonitor.left;
    out.height = info.rcMonitor.bottom - info.rcMonitor.top;
    out.is_primary = (info.dwFlags & MONITORINFOF_PRIMARY) ? 1 : 0;
    copy_string(out.device_name, sizeof out.device_name, narrow(info.szDevice));
    DEVMODEW mode{};
    mode.dmSize = sizeof mode;
    if (EnumDisplaySettingsW(info.szDevice, ENUM_CURRENT_SETTINGS, &mode))
        out.refresh_hz = mode.dmDisplayFrequency;
    collector->monitors.push_back(out);
    return TRUE;
}

// Finds the DXGI adapter and output that drive `monitor`.
bool find_output(HMONITOR monitor, winrt::com_ptr<IDXGIAdapter1> &adapter_out,
                 winrt::com_ptr<IDXGIOutput> &output_out) {
    winrt::com_ptr<IDXGIFactory1> factory;
    if (FAILED(CreateDXGIFactory1(IID_PPV_ARGS(factory.put())))) return false;
    for (UINT a = 0;; ++a) {
        winrt::com_ptr<IDXGIAdapter1> adapter;
        if (factory->EnumAdapters1(a, adapter.put()) == DXGI_ERROR_NOT_FOUND) break;
        for (UINT o = 0;; ++o) {
            winrt::com_ptr<IDXGIOutput> output;
            if (adapter->EnumOutputs(o, output.put()) == DXGI_ERROR_NOT_FOUND) break;
            DXGI_OUTPUT_DESC desc{};
            if (SUCCEEDED(output->GetDesc(&desc)) && desc.Monitor == monitor) {
                adapter_out = adapter;
                output_out = output;
                return true;
            }
        }
    }
    return false;
}

} // namespace

namespace lw {
bool find_monitor_output(HMONITOR monitor, winrt::com_ptr<IDXGIAdapter1> &adapter,
                         winrt::com_ptr<IDXGIOutput> &output) {
    return find_output(monitor, adapter, output);
}
} // namespace lw

extern "C" int32_t lw_monitor_list(lw_monitor_info *out, int32_t capacity) {
    MonitorCollector collector;
    EnumDisplayMonitors(nullptr, nullptr, collect_monitor, reinterpret_cast<LPARAM>(&collector));
    for (auto &monitor : collector.monitors) {
        winrt::com_ptr<IDXGIAdapter1> adapter;
        winrt::com_ptr<IDXGIOutput> output;
        if (find_output(static_cast<HMONITOR>(monitor.handle), adapter, output)) {
            DXGI_ADAPTER_DESC1 desc{};
            adapter->GetDesc1(&desc);
            copy_string(monitor.adapter_name, sizeof monitor.adapter_name, narrow(desc.Description));
        }
    }
    int32_t count = static_cast<int32_t>(collector.monitors.size());
    for (int32_t i = 0; i < count && i < capacity && out; ++i) out[i] = collector.monitors[i];
    return count;
}

// ---- Device -------------------------------------------------------------------

extern "C" lw_status lw_device_create(void *monitor, lw_device **out) {
    if (!out) return fail(LW_E_INVALID_ARG, "lw_device_create: out is NULL");
    *out = nullptr;
    return guarded("lw_device_create", [&]() -> lw_status {
        winrt::com_ptr<IDXGIAdapter1> adapter;
        if (monitor) {
            winrt::com_ptr<IDXGIOutput> output;
            if (!find_output(static_cast<HMONITOR>(monitor), adapter, output))
                return fail(LW_E_INVALID_ARG, "lw_device_create: no DXGI output drives that monitor");
        } else {
            winrt::com_ptr<IDXGIFactory1> factory;
            winrt::check_hresult(CreateDXGIFactory1(IID_PPV_ARGS(factory.put())));
            for (UINT a = 0;; ++a) {
                winrt::com_ptr<IDXGIAdapter1> candidate;
                if (factory->EnumAdapters1(a, candidate.put()) == DXGI_ERROR_NOT_FOUND) break;
                DXGI_ADAPTER_DESC1 desc{};
                candidate->GetDesc1(&desc);
                if (desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) continue;
                adapter = candidate;
                break;
            }
            if (!adapter) return fail(LW_E_UNSUPPORTED, "lw_device_create: no hardware adapter");
        }

        const D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0};
        auto device = std::make_unique<lw_device>();
        HRESULT hr = D3D11CreateDevice(adapter.get(), D3D_DRIVER_TYPE_UNKNOWN, nullptr,
                                       D3D11_CREATE_DEVICE_BGRA_SUPPORT | D3D11_CREATE_DEVICE_VIDEO_SUPPORT,
                                       levels, ARRAYSIZE(levels), D3D11_SDK_VERSION,
                                       device->device.put(), nullptr, device->context.put());
        if (FAILED(hr)) return fail_hr(hr, "D3D11CreateDevice");

        // Capture callbacks (copy) and the encoder thread (NVENC) share the
        // immediate context.
        auto multithread = device->device.as<ID3D11Multithread>();
        multithread->SetMultithreadProtected(TRUE);

        DXGI_ADAPTER_DESC1 desc{};
        adapter->GetDesc1(&desc);
        copy_string(device->info.adapter_name, sizeof device->info.adapter_name, narrow(desc.Description));
        device->info.vendor_id = desc.VendorId;
        device->info.dedicated_video_memory = desc.DedicatedVideoMemory;
        device->adapter = adapter;
        *out = device.release();
        return LW_OK;
    });
}

extern "C" void lw_device_get_info(const lw_device *device, lw_device_info *out) {
    if (device && out) *out = device->info;
}

extern "C" void lw_device_release(lw_device *device) { delete device; }
