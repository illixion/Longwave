// spatial_audio_probe — a pass-through diagnostic that logs how a process uses
// Windows Spatial Sound (ISpatialAudioClient) and plain WASAPI (IAudioClient).
//
// Loaded as an .asi by Ultimate ASI Loader (or LoadLibrary'd by the harness).
// Nothing is wrapped: each interesting COM method is detoured in place with
// MinHook, the original is always called with the caller's exact arguments, and
// its result is returned untouched. The probe only observes.
//
// Hook chain:
//   combase!CoCreateInstance(Ex)  -- sees CLSID_MMDeviceEnumerator
//     -> IMMDevice::Activate      -- every interface any caller activates
//          -> IAudioClient::{Initialize,IsFormatSupported,GetMixFormat},
//             IAudioClient3::InitializeSharedAudioStream
//          -> ISpatialAudioClient::{GetMaxDynamicObjectCount, IsAudioObjectFormatSupported,
//             IsSpatialAudioStreamAvailable, ActivateSpatialAudioStream}
//               -> render stream {Start, Stop, Reset, Begin/EndUpdatingAudioObjects,
//                  ActivateSpatialAudioObject}
//                    -> object {GetBuffer, SetEndOfStream, SetPosition, SetVolume}
//   mmdevapi!ActivateAudioInterfaceAsync (logged only; it lands in IMMDevice::Activate)
//
// The audio thread never logs per update: stream statistics are aggregated and
// written once per second per stream.

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <initguid.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <spatialaudioclient.h>
#include <spatialaudiometadata.h>
#include <endpointvolume.h>
#include <audiopolicy.h>
#include <devicetopology.h>
#include <functiondiscoverykeys_devpkey.h>
#include <mmreg.h>
#include <ks.h>
#include <ksmedia.h>
#include <intrin.h>

#include <algorithm>
#include <cmath>
#include <cstdarg>
#include <cstdio>
#include <map>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

#include "MinHook.h"

#pragma intrinsic(_ReturnAddress)

// ---------------------------------------------------------------------------
// Logging

static HANDLE g_log = INVALID_HANDLE_VALUE;
static SRWLOCK g_logLock = SRWLOCK_INIT;
static thread_local int t_inProbe = 0;

struct ProbeScope {
    ProbeScope() { ++t_inProbe; }
    ~ProbeScope() { --t_inProbe; }
};

static void LogLine(const std::string& text) {
    if (g_log == INVALID_HANDLE_VALUE) return;
    SYSTEMTIME st;
    GetLocalTime(&st);
    char head[64];
    int n = _snprintf_s(head, sizeof head, _TRUNCATE, "%02u:%02u:%02u.%03u [%5lu] ", st.wHour, st.wMinute,
                        st.wSecond, st.wMilliseconds, GetCurrentThreadId());
    std::string line(head, n > 0 ? n : 0);
    line += text;
    line += "\r\n";
    DWORD written;
    AcquireSRWLockExclusive(&g_logLock);
    WriteFile(g_log, line.data(), (DWORD)line.size(), &written, nullptr);
    ReleaseSRWLockExclusive(&g_logLock);
}

static void AppendF(std::string& s, const char* fmt, ...) {
    char buf[2048];
    va_list ap;
    va_start(ap, fmt);
    int n = _vsnprintf_s(buf, sizeof buf, _TRUNCATE, fmt, ap);
    va_end(ap);
    s.append(buf, n >= 0 ? n : strlen(buf));
}

static void Logf(const char* fmt, ...) {
    char buf[4096];
    va_list ap;
    va_start(ap, fmt);
    _vsnprintf_s(buf, sizeof buf, _TRUNCATE, fmt, ap);
    va_end(ap);
    LogLine(buf);
}

static std::string Narrow(const wchar_t* w) {
    if (!w) return "(null)";
    int n = WideCharToMultiByte(CP_UTF8, 0, w, -1, nullptr, 0, nullptr, nullptr);
    std::string s(n > 0 ? n - 1 : 0, '\0');
    if (n > 1) WideCharToMultiByte(CP_UTF8, 0, w, -1, &s[0], n, nullptr, nullptr);
    return s;
}

// "Cyberpunk2077.exe+0x1234" for an address, to tell game, audioware and system callers apart.
static std::string ModuleOf(const void* addr) {
    HMODULE mod = nullptr;
    if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                            (LPCWSTR)addr, &mod) ||
        !mod) {
        char b[32];
        _snprintf_s(b, sizeof b, _TRUNCATE, "%p", addr);
        return b;
    }
    wchar_t path[MAX_PATH];
    DWORD n = GetModuleFileNameW(mod, path, MAX_PATH);
    const wchar_t* base = path;
    for (DWORD i = 0; i < n; i++)
        if (path[i] == L'\\' || path[i] == L'/') base = path + i + 1;
    std::string s = Narrow(base);
    AppendF(s, "+0x%llx", (unsigned long long)((const char*)addr - (const char*)mod));
    return s;
}

static std::string GuidStr(REFGUID g) {
    char b[64];
    _snprintf_s(b, sizeof b, _TRUNCATE, "{%08lX-%04X-%04X-%02X%02X-%02X%02X%02X%02X%02X%02X}", g.Data1, g.Data2,
                g.Data3, g.Data4[0], g.Data4[1], g.Data4[2], g.Data4[3], g.Data4[4], g.Data4[5], g.Data4[6],
                g.Data4[7]);
    return b;
}

// IDirectSound(8) can be activated on an IMMDevice; dsound.h is not worth including for two GUIDs.
DEFINE_GUID(kIID_IDirectSound, 0x279AFA83, 0x4981, 0x11CE, 0xA5, 0x21, 0x00, 0x20, 0xAF, 0x0B, 0xE5, 0x60);
DEFINE_GUID(kIID_IDirectSound8, 0xC50A7E93, 0xF395, 0x4834, 0x9E, 0xF6, 0x7F, 0xA9, 0x9D, 0xE5, 0x09, 0x66);
DEFINE_GUID(kIID_IBaseFilter, 0x56A86895, 0x0AD4, 0x11CE, 0xB0, 0x3A, 0x00, 0x20, 0xAF, 0x0B, 0xA7, 0x70);

static std::string IidName(REFIID iid) {
    struct {
        const GUID* g;
        const char* name;
    } static const kNames[] = {
        {&__uuidof(IAudioClient), "IAudioClient"},
        {&__uuidof(IAudioClient2), "IAudioClient2"},
        {&__uuidof(IAudioClient3), "IAudioClient3"},
        {&__uuidof(ISpatialAudioClient), "ISpatialAudioClient"},
        {&__uuidof(ISpatialAudioClient2), "ISpatialAudioClient2"},
        {&__uuidof(ISpatialAudioMetadataClient), "ISpatialAudioMetadataClient"},
        {&__uuidof(ISpatialAudioObjectRenderStream), "ISpatialAudioObjectRenderStream"},
        {&__uuidof(ISpatialAudioObjectRenderStreamForMetadata), "ISpatialAudioObjectRenderStreamForMetadata"},
        {&__uuidof(IAudioEndpointVolume), "IAudioEndpointVolume"},
        {&__uuidof(IAudioMeterInformation), "IAudioMeterInformation"},
        {&__uuidof(IAudioSessionManager), "IAudioSessionManager"},
        {&__uuidof(IAudioSessionManager2), "IAudioSessionManager2"},
        {&__uuidof(IDeviceTopology), "IDeviceTopology"},
        {&kIID_IDirectSound, "IDirectSound"},
        {&kIID_IDirectSound8, "IDirectSound8"},
        {&kIID_IBaseFilter, "IBaseFilter"},
    };
    for (auto& e : kNames)
        if (IsEqualIID(iid, *e.g)) return e.name;
    return GuidStr(iid);
}

static std::string Hr(HRESULT hr) {
    struct {
        HRESULT hr;
        const char* name;
    } static const kNames[] = {
        {S_OK, "S_OK"},
        {S_FALSE, "S_FALSE"},
        {E_NOINTERFACE, "E_NOINTERFACE"},
        {E_INVALIDARG, "E_INVALIDARG"},
        {E_POINTER, "E_POINTER"},
        {E_OUTOFMEMORY, "E_OUTOFMEMORY"},
        {E_NOTIMPL, "E_NOTIMPL"},
        {E_ACCESSDENIED, "E_ACCESSDENIED"},
        {AUDCLNT_E_UNSUPPORTED_FORMAT, "AUDCLNT_E_UNSUPPORTED_FORMAT"},
        {AUDCLNT_E_DEVICE_INVALIDATED, "AUDCLNT_E_DEVICE_INVALIDATED"},
        {AUDCLNT_E_ALREADY_INITIALIZED, "AUDCLNT_E_ALREADY_INITIALIZED"},
        {AUDCLNT_E_DEVICE_IN_USE, "AUDCLNT_E_DEVICE_IN_USE"},
        {AUDCLNT_E_ENDPOINT_CREATE_FAILED, "AUDCLNT_E_ENDPOINT_CREATE_FAILED"},
        {AUDCLNT_E_BUFFER_SIZE_NOT_ALIGNED, "AUDCLNT_E_BUFFER_SIZE_NOT_ALIGNED"},
        {SPTLAUDCLNT_E_DESTROYED, "SPTLAUDCLNT_E_DESTROYED"},
        {SPTLAUDCLNT_E_OUT_OF_ORDER, "SPTLAUDCLNT_E_OUT_OF_ORDER"},
        {SPTLAUDCLNT_E_RESOURCES_INVALIDATED, "SPTLAUDCLNT_E_RESOURCES_INVALIDATED"},
        {SPTLAUDCLNT_E_NO_MORE_OBJECTS, "SPTLAUDCLNT_E_NO_MORE_OBJECTS"},
        {SPTLAUDCLNT_E_PROPERTY_NOT_SUPPORTED, "SPTLAUDCLNT_E_PROPERTY_NOT_SUPPORTED"},
        {SPTLAUDCLNT_E_ERRORS_IN_OBJECT_CALLS, "SPTLAUDCLNT_E_ERRORS_IN_OBJECT_CALLS"},
        {SPTLAUDCLNT_E_METADATA_FORMAT_NOT_SUPPORTED, "SPTLAUDCLNT_E_METADATA_FORMAT_NOT_SUPPORTED"},
        {SPTLAUDCLNT_E_STREAM_NOT_AVAILABLE, "SPTLAUDCLNT_E_STREAM_NOT_AVAILABLE"},
        {SPTLAUDCLNT_E_INVALID_LICENSE, "SPTLAUDCLNT_E_INVALID_LICENSE"},
        {SPTLAUDCLNT_E_STREAM_NOT_STOPPED, "SPTLAUDCLNT_E_STREAM_NOT_STOPPED"},
        {SPTLAUDCLNT_E_STATIC_OBJECT_NOT_AVAILABLE, "SPTLAUDCLNT_E_STATIC_OBJECT_NOT_AVAILABLE"},
        {SPTLAUDCLNT_E_OBJECT_ALREADY_ACTIVE, "SPTLAUDCLNT_E_OBJECT_ALREADY_ACTIVE"},
        {SPTLAUDCLNT_E_INTERNAL, "SPTLAUDCLNT_E_INTERNAL"},
    };
    for (auto& e : kNames)
        if (e.hr == hr) return e.name;
    char b[24];
    _snprintf_s(b, sizeof b, _TRUNCATE, "0x%08lX", (unsigned long)hr);
    return b;
}

// AudioObjectType bit i -> name (bit 0 = Dynamic).
static const char* const kObjTypeNames[] = {"Dyn", "FL",  "FR",  "FC",  "LFE", "SL",  "SR", "BL", "BR", "TFL",
                                            "TFR", "TBL", "TBR", "BFL", "BFR", "BBL", "BBR", "BC", "StL", "StR"};
static const int kObjTypeCount = sizeof kObjTypeNames / sizeof kObjTypeNames[0];

static std::string ObjMaskStr(UINT32 mask) {
    std::string s;
    AppendF(s, "0x%X [", mask);
    bool first = true;
    for (int i = 0; i < 32; i++) {
        if (!(mask & (1u << i))) continue;
        if (!first) s += ",";
        first = false;
        if (i < kObjTypeCount)
            s += kObjTypeNames[i];
        else
            AppendF(s, "bit%d", i);
    }
    s += "]";
    if (mask == 0x1FFE) s += " (=7.1.4)";
    else if (mask == 0x1FE) s += " (=7.1)";
    else if (mask == 0x7E || mask == 0x19E) s += " (=5.1)";
    else if (mask == 0x7FE) s += " (=7.1.2)";
    else if ((mask & ~1u) == 0x3FFFE) s += " (=8.1.4.4)";
    return s;
}

static int ObjTypeBit(UINT32 type) {
    for (int i = 0; i < 32; i++)
        if (type == (1u << i)) return i;
    return -1;
}

static std::string SpeakerMaskStr(DWORD mask) {
    static const char* const kNames[] = {"FL", "FR", "FC", "LFE", "BL", "BR", "FLC", "FRC", "BC",
                                         "SL", "SR", "TC", "TFL", "TFC", "TFR", "TBL", "TBC", "TBR"};
    std::string s;
    AppendF(s, "0x%lX [", mask);
    bool first = true;
    for (int i = 0; i < 32; i++) {
        if (!(mask & (1u << i))) continue;
        if (!first) s += ",";
        first = false;
        if (i < 18)
            s += kNames[i];
        else
            AppendF(s, "bit%d", i);
    }
    s += "]";
    return s;
}

static bool FormatIsFloat(const WAVEFORMATEX* w) {
    if (!w) return true;
    if (w->wFormatTag == WAVE_FORMAT_IEEE_FLOAT) return true;
    if (w->wFormatTag == WAVE_FORMAT_EXTENSIBLE && w->cbSize >= 22)
        return IsEqualGUID(((const WAVEFORMATEXTENSIBLE*)w)->SubFormat, KSDATAFORMAT_SUBTYPE_IEEE_FLOAT) != 0;
    return false;
}

static std::string WfxStr(const WAVEFORMATEX* w) {
    if (!w) return "(null)";
    std::string s;
    const char* tag = w->wFormatTag == WAVE_FORMAT_PCM          ? "PCM"
                      : w->wFormatTag == WAVE_FORMAT_IEEE_FLOAT ? "FLOAT"
                      : w->wFormatTag == WAVE_FORMAT_EXTENSIBLE ? "EXTENSIBLE"
                                                                : "tag";
    AppendF(s, "%s(0x%X) %uch %luHz %ubit align=%u", tag, w->wFormatTag, w->nChannels, w->nSamplesPerSec,
            w->wBitsPerSample, w->nBlockAlign);
    if (w->wFormatTag == WAVE_FORMAT_EXTENSIBLE && w->cbSize >= 22) {
        auto x = (const WAVEFORMATEXTENSIBLE*)w;
        const char* sub = IsEqualGUID(x->SubFormat, KSDATAFORMAT_SUBTYPE_IEEE_FLOAT) ? "float"
                          : IsEqualGUID(x->SubFormat, KSDATAFORMAT_SUBTYPE_PCM)      ? "pcm"
                                                                                     : nullptr;
        AppendF(s, " sub=%s valid=%u mask=%s", sub ? sub : GuidStr(x->SubFormat).c_str(), x->Samples.wValidBitsPerSample,
                SpeakerMaskStr(x->dwChannelMask).c_str());
    }
    return s;
}

static std::string Db(float peak) {
    if (peak <= 1e-6f) return "-inf";
    char b[16];
    _snprintf_s(b, sizeof b, _TRUNCATE, "%.1f", 20.0f * log10f(peak));
    return b;
}

static std::string DeviceStr(IMMDevice* d) {
    std::string s;
    LPWSTR id = nullptr;
    if (SUCCEEDED(d->GetId(&id)) && id) {
        s = Narrow(id);
        CoTaskMemFree(id);
    }
    IPropertyStore* ps = nullptr;
    if (SUCCEEDED(d->OpenPropertyStore(STGM_READ, &ps)) && ps) {
        PROPVARIANT pv;
        PropVariantInit(&pv);
        if (SUCCEEDED(ps->GetValue(PKEY_Device_FriendlyName, &pv)) && pv.vt == VT_LPWSTR)
            s = "\"" + Narrow(pv.pwszVal) + "\" " + s;
        PropVariantClear(&pv);
        ps->Release();
    }
    return s;
}

// ---------------------------------------------------------------------------
// Hook plumbing. A method can be backed by more than one implementation
// (multiple-inheritance thunks, separate classes for static and dynamic
// objects), so every hook has three detour instances, one per distinct target.

constexpr int kImpls = 3;

template <typename Fn>
struct MultiHook {
    const char* name;
    void* target[kImpls];
    Fn orig[kImpls];
};

static SRWLOCK g_hookLock = SRWLOCK_INIT;

template <typename Fn>
static void HookTarget(void* target, MultiHook<Fn>& mh, void* const (&detours)[kImpls]) {
    if (!target) return;
    AcquireSRWLockExclusive(&g_hookLock);
    for (int i = 0; i < kImpls; i++)
        if (mh.target[i] == target) {
            ReleaseSRWLockExclusive(&g_hookLock);
            return;
        }
    int slot = -1;
    for (int i = 0; i < kImpls; i++)
        if (!mh.target[i]) {
            slot = i;
            break;
        }
    MH_STATUS st = MH_UNKNOWN;
    if (slot >= 0) {
        mh.target[slot] = target;
        st = MH_CreateHook(target, detours[slot], (void**)&mh.orig[slot]);
        // Queued, not enabled: enabling freezes every thread in the process (~15 ms each here), so a
        // batch of hooks is applied under a single freeze by ApplyHooks().
        if (st == MH_OK) st = MH_QueueEnableHook(target);
    }
    ReleaseSRWLockExclusive(&g_hookLock);
    if (slot < 0)
        Logf("hook %s: more than %d implementations, %s left unhooked", mh.name, kImpls, ModuleOf(target).c_str());
    else
        Logf("hook %s[%d] at %s: %s", mh.name, slot, ModuleOf(target).c_str(),
             st == MH_OK ? "queued" : MH_StatusToString(st));
}

static void ApplyHooks(const char* batch) {
    AcquireSRWLockExclusive(&g_hookLock);
    MH_STATUS st = MH_ApplyQueued();
    ReleaseSRWLockExclusive(&g_hookLock);
    if (st != MH_OK) Logf("apply hooks (%s): %s", batch, MH_StatusToString(st));
}

template <typename Fn>
static void HookSlot(void* obj, int slot, MultiHook<Fn>& mh, void* const (&detours)[kImpls]) {
    if (!obj) return;
    HookTarget((*(void***)obj)[slot], mh, detours);
}

#define DETOURS(fn) static void* const fn##_detours[kImpls] = {(void*)&fn<0>, (void*)&fn<1>, (void*)&fn<2>}

// ---------------------------------------------------------------------------
// Spatial stream + object statistics

struct StreamState;

struct ObjInfo {
    uint32_t id;
    StreamState* st;
    UINT32 type;
    float x = 0, y = 0, z = 0, vol = 1;
    bool hasPos = false, ended = false;
    float peakSec = 0;
    uint64_t lastUpdate = 0;
    uint32_t secSeen = 0;
    ULONGLONG lastSeenTick = 0;
};

struct PendingBuf {
    ObjInfo* o;
    const BYTE* buf;
    UINT32 len;
};

struct StreamState {
    uint32_t id = 0;
    void* stream = nullptr;
    bool metadata = false;
    bool isFloat = true;
    int bits = 32;
    // per-second accumulators
    ULONGLONG secStart = 0;
    uint32_t secSerial = 1;
    uint32_t updates = 0, beginFails = 0, frMin = UINT32_MAX, frMax = 0, availMin = UINT32_MAX, availMax = 0;
    uint64_t frSum = 0;
    uint32_t dynActivated = 0, staticActivated = 0, activateFails = 0, ended = 0, positions = 0;
    HRESULT lastActivateFail = S_OK;
    std::map<uint32_t, uint32_t> dynHist, audibleHist;
    float staticPeak[32] = {};
    UINT32 staticSeenMask = 0;
    float dynPeak = 0;
    // per update
    std::vector<PendingBuf> pending;
    // totals
    uint64_t totalUpdates = 0;
    uint32_t totalDynActivated = 0, maxDynConcurrent = 0, maxAudibleConcurrent = 0;
};

static std::mutex g_stateMx;
static std::unordered_map<void*, StreamState*> g_streams;
static std::unordered_map<void*, ObjInfo*> g_objs;
static uint32_t g_nextStreamId = 1, g_nextObjId = 1;

static StreamState* GetStreamLocked(void* stream) {
    auto it = g_streams.find(stream);
    if (it != g_streams.end()) return it->second;
    auto st = new StreamState();
    st->id = g_nextStreamId++;
    st->stream = stream;
    st->secStart = GetTickCount64();
    g_streams[stream] = st;
    return st;
}

static float PeakOf(const PendingBuf& p, const StreamState* st) {
    float peak = 0;
    if (!p.buf || !p.len) return 0;
    if (st->isFloat && st->bits == 32) {
        auto s = (const float*)p.buf;
        UINT32 n = p.len / 4;
        for (UINT32 i = 0; i < n; i++) peak = std::max(peak, fabsf(s[i]));
    } else if (st->bits == 16) {
        auto s = (const int16_t*)p.buf;
        UINT32 n = p.len / 2;
        int m = 0;
        for (UINT32 i = 0; i < n; i++) m = std::max(m, abs((int)s[i]));
        peak = m / 32768.0f;
    }
    return std::isfinite(peak) ? peak : 1e9f;
}

static const float kAudible = 1e-4f;  // -80 dBFS

static void ProcessPendingLocked(StreamState* st) {
    uint32_t dyn = 0, audible = 0;
    for (auto& p : st->pending) {
        float peak = PeakOf(p, st);
        ObjInfo* o = p.o;
        o->lastUpdate = st->totalUpdates;
        o->secSeen = st->secSerial;
        if (o->type == AudioObjectType_Dynamic) {
            dyn++;
            if (peak > kAudible) audible++;
            o->peakSec = std::max(o->peakSec, peak);
            st->dynPeak = std::max(st->dynPeak, peak);
        } else {
            int b = ObjTypeBit(o->type);
            if (b >= 0) st->staticPeak[b] = std::max(st->staticPeak[b], peak);
            st->staticSeenMask |= o->type;
        }
    }
    st->pending.clear();
    st->dynHist[dyn]++;
    st->audibleHist[audible]++;
    st->maxDynConcurrent = std::max(st->maxDynConcurrent, dyn);
    st->maxAudibleConcurrent = std::max(st->maxAudibleConcurrent, audible);
}

static std::string HistStr(const std::map<uint32_t, uint32_t>& h) {
    std::string s = "{";
    bool first = true;
    for (auto& kv : h) {
        if (!first) s += " ";
        first = false;
        AppendF(s, "%u:%u", kv.first, kv.second);
    }
    return s + "}";
}

static std::string FlushLocked(StreamState* st, ULONGLONG now) {
    std::string s;
    double secs = (now - st->secStart) / 1000.0;
    AppendF(s, "[stream %u] %.2fs updates=%u", st->id, secs, st->updates);
    if (st->beginFails) AppendF(s, " beginFails=%u", st->beginFails);
    if (st->updates)
        AppendF(s, " frames/update=%u..%u(avg %.0f) availDyn=%u..%u", st->frMin, st->frMax,
                (double)st->frSum / st->updates, st->availMin, st->availMax);
    AppendF(s, " | activated: static=%u dyn=%u", st->staticActivated, st->dynActivated);
    if (st->activateFails) AppendF(s, " fail=%u(%s)", st->activateFails, Hr(st->lastActivateFail).c_str());
    AppendF(s, " ended=%u positions=%u", st->ended, st->positions);

    uint32_t dynSeen = 0, dynAlive = 0;
    std::vector<ObjInfo*> live;
    for (auto& kv : g_objs) {
        ObjInfo* o = kv.second;
        if (o->st != st || o->type != AudioObjectType_Dynamic) continue;
        if (o->secSeen == st->secSerial) dynSeen++;
        if (o->lastUpdate + 1 == st->totalUpdates) {
            dynAlive++;
            live.push_back(o);
        }
    }
    AppendF(s, "\r\n    dyn: distinctThisSec=%u inLastUpdate=%u perUpdate=%s audiblePerUpdate=%s peak=%s dB",
            dynSeen, dynAlive, HistStr(st->dynHist).c_str(), HistStr(st->audibleHist).c_str(), Db(st->dynPeak).c_str());
    s += "\r\n    static peaks dB:";
    if (!st->staticSeenMask) s += " (no static buffers)";
    for (int b = 1; b < 32; b++)
        if (st->staticSeenMask & (1u << b))
            AppendF(s, " %s=%s", b < kObjTypeCount ? kObjTypeNames[b] : "?", Db(st->staticPeak[b]).c_str());
    std::sort(live.begin(), live.end(), [](ObjInfo* a, ObjInfo* b) { return a->peakSec > b->peakSec; });
    for (size_t i = 0; i < live.size() && i < 8; i++) {
        ObjInfo* o = live[i];
        if (o->hasPos)
            AppendF(s, "\r\n    obj#%u pos=(%+.2f,%+.2f,%+.2f) dist=%.2f vol=%.2f peak=%s dB", o->id, o->x, o->y, o->z,
                    sqrtf(o->x * o->x + o->y * o->y + o->z * o->z), o->vol, Db(o->peakSec).c_str());
        else
            AppendF(s, "\r\n    obj#%u pos=(unset) vol=%.2f peak=%s dB", o->id, o->vol, Db(o->peakSec).c_str());
    }
    AppendF(s, "\r\n    totals: updates=%llu dynActivated=%u maxDynPerUpdate=%u maxAudibleDynPerUpdate=%u",
            (unsigned long long)st->totalUpdates, st->totalDynActivated, st->maxDynConcurrent, st->maxAudibleConcurrent);

    // reset per-second state
    for (auto it = g_objs.begin(); it != g_objs.end();) {
        ObjInfo* o = it->second;
        if (o->st == st) o->peakSec = 0;
        if (o->st == st && o->ended && now - o->lastSeenTick > 10000) {
            delete o;
            it = g_objs.erase(it);
        } else
            ++it;
    }
    st->secStart = now;
    st->secSerial++;
    st->updates = st->beginFails = 0;
    st->frMin = st->availMin = UINT32_MAX;
    st->frMax = st->availMax = 0;
    st->frSum = 0;
    st->dynActivated = st->staticActivated = st->activateFails = st->ended = st->positions = 0;
    st->dynHist.clear();
    st->audibleHist.clear();
    memset(st->staticPeak, 0, sizeof st->staticPeak);
    st->staticSeenMask = 0;
    st->dynPeak = 0;
    return s;
}

// ---------------------------------------------------------------------------
// Spatial audio object hooks

using GetBuffer_t = HRESULT(STDMETHODCALLTYPE*)(ISpatialAudioObjectBase*, BYTE**, UINT32*);
using SetEndOfStream_t = HRESULT(STDMETHODCALLTYPE*)(ISpatialAudioObjectBase*, UINT32);
using SetPosition_t = HRESULT(STDMETHODCALLTYPE*)(ISpatialAudioObject*, float, float, float);
using SetVolume_t = HRESULT(STDMETHODCALLTYPE*)(ISpatialAudioObject*, float);

static MultiHook<GetBuffer_t> g_GetBuffer{"ISpatialAudioObject::GetBuffer"};
static MultiHook<SetEndOfStream_t> g_SetEndOfStream{"ISpatialAudioObject::SetEndOfStream"};
static MultiHook<SetPosition_t> g_SetPosition{"ISpatialAudioObject::SetPosition"};
static MultiHook<SetVolume_t> g_SetVolume{"ISpatialAudioObject::SetVolume"};

template <int I>
HRESULT STDMETHODCALLTYPE D_GetBuffer(ISpatialAudioObjectBase* self, BYTE** buf, UINT32* len) {
    HRESULT hr = g_GetBuffer.orig[I](self, buf, len);
    if (t_inProbe || FAILED(hr) || !buf || !len) return hr;
    std::lock_guard<std::mutex> lk(g_stateMx);
    auto it = g_objs.find(self);
    if (it != g_objs.end()) {
        it->second->lastSeenTick = GetTickCount64();
        it->second->st->pending.push_back({it->second, *buf, *len});
    }
    return hr;
}
DETOURS(D_GetBuffer);

template <int I>
HRESULT STDMETHODCALLTYPE D_SetEndOfStream(ISpatialAudioObjectBase* self, UINT32 frames) {
    HRESULT hr = g_SetEndOfStream.orig[I](self, frames);
    if (t_inProbe) return hr;
    std::lock_guard<std::mutex> lk(g_stateMx);
    auto it = g_objs.find(self);
    if (it != g_objs.end() && !it->second->ended) {
        it->second->ended = true;
        it->second->st->ended++;
    }
    return hr;
}
DETOURS(D_SetEndOfStream);

template <int I>
HRESULT STDMETHODCALLTYPE D_SetPosition(ISpatialAudioObject* self, float x, float y, float z) {
    HRESULT hr = g_SetPosition.orig[I](self, x, y, z);
    if (t_inProbe) return hr;
    std::lock_guard<std::mutex> lk(g_stateMx);
    auto it = g_objs.find(self);
    if (it != g_objs.end()) {
        ObjInfo* o = it->second;
        o->x = x, o->y = y, o->z = z, o->hasPos = true;
        o->st->positions++;
    }
    return hr;
}
DETOURS(D_SetPosition);

template <int I>
HRESULT STDMETHODCALLTYPE D_SetVolume(ISpatialAudioObject* self, float v) {
    HRESULT hr = g_SetVolume.orig[I](self, v);
    if (t_inProbe) return hr;
    std::lock_guard<std::mutex> lk(g_stateMx);
    auto it = g_objs.find(self);
    if (it != g_objs.end()) it->second->vol = v;
    return hr;
}
DETOURS(D_SetVolume);

static void HookObject(void* obj, bool metadataCommands) {
    // Slots 3/4 (GetBuffer, SetEndOfStream) are in ISpatialAudioObjectBase, shared by both object kinds.
    // Slots 7/8 are SetPosition/SetVolume only on ISpatialAudioObject; on the metadata-commands object they
    // are WriteNextMetadataCommand etc. with a different signature, so never hook them there.
    HookSlot(obj, 3, g_GetBuffer, D_GetBuffer_detours);
    HookSlot(obj, 4, g_SetEndOfStream, D_SetEndOfStream_detours);
    if (!metadataCommands) {
        HookSlot(obj, 7, g_SetPosition, D_SetPosition_detours);
        HookSlot(obj, 8, g_SetVolume, D_SetVolume_detours);
    }
    ApplyHooks("object");
}

// ---------------------------------------------------------------------------
// Render stream hooks

using StreamVoid_t = HRESULT(STDMETHODCALLTYPE*)(ISpatialAudioObjectRenderStreamBase*);
using BeginUpdating_t = HRESULT(STDMETHODCALLTYPE*)(ISpatialAudioObjectRenderStreamBase*, UINT32*, UINT32*);
using ActivateObject_t = HRESULT(STDMETHODCALLTYPE*)(void*, AudioObjectType, void**);

static MultiHook<StreamVoid_t> g_Start{"RenderStream::Start"};
static MultiHook<StreamVoid_t> g_Stop{"RenderStream::Stop"};
static MultiHook<StreamVoid_t> g_Reset{"RenderStream::Reset"};
static MultiHook<BeginUpdating_t> g_Begin{"RenderStream::BeginUpdatingAudioObjects"};
static MultiHook<StreamVoid_t> g_End{"RenderStream::EndUpdatingAudioObjects"};
static MultiHook<ActivateObject_t> g_ActivateObject{"RenderStream::ActivateSpatialAudioObject"};
static MultiHook<ActivateObject_t> g_ActivateObjectMeta{"RenderStreamForMetadata::ActivateSpatialAudioObjectForMetadataCommands"};

static void LogStreamCall(const char* what, void* self, HRESULT hr, void* caller) {
    uint32_t id;
    {
        std::lock_guard<std::mutex> lk(g_stateMx);
        id = GetStreamLocked(self)->id;
    }
    Logf("[stream %u] %s -> %s caller=%s", id, what, Hr(hr).c_str(), ModuleOf(caller).c_str());
}

template <int I>
HRESULT STDMETHODCALLTYPE D_Start(ISpatialAudioObjectRenderStreamBase* self) {
    void* caller = _ReturnAddress();
    HRESULT hr = g_Start.orig[I](self);
    if (!t_inProbe) LogStreamCall("Start", self, hr, caller);
    return hr;
}
DETOURS(D_Start);

template <int I>
HRESULT STDMETHODCALLTYPE D_Stop(ISpatialAudioObjectRenderStreamBase* self) {
    void* caller = _ReturnAddress();
    HRESULT hr = g_Stop.orig[I](self);
    if (t_inProbe) return hr;
    std::string out;
    {
        std::lock_guard<std::mutex> lk(g_stateMx);
        StreamState* st = GetStreamLocked(self);
        if (st->updates) out = FlushLocked(st, GetTickCount64());
    }
    if (!out.empty()) LogLine(out);
    LogStreamCall("Stop", self, hr, caller);
    return hr;
}
DETOURS(D_Stop);

template <int I>
HRESULT STDMETHODCALLTYPE D_Reset(ISpatialAudioObjectRenderStreamBase* self) {
    void* caller = _ReturnAddress();
    HRESULT hr = g_Reset.orig[I](self);
    if (!t_inProbe) LogStreamCall("Reset", self, hr, caller);
    return hr;
}
DETOURS(D_Reset);

template <int I>
HRESULT STDMETHODCALLTYPE D_Begin(ISpatialAudioObjectRenderStreamBase* self, UINT32* avail, UINT32* frames) {
    HRESULT hr = g_Begin.orig[I](self, avail, frames);
    if (t_inProbe) return hr;
    std::lock_guard<std::mutex> lk(g_stateMx);
    StreamState* st = GetStreamLocked(self);
    st->pending.clear();
    if (FAILED(hr)) {
        st->beginFails++;
        return hr;
    }
    st->updates++;
    if (frames) {
        st->frMin = std::min(st->frMin, *frames);
        st->frMax = std::max(st->frMax, *frames);
        st->frSum += *frames;
    }
    if (avail) {
        st->availMin = std::min(st->availMin, *avail);
        st->availMax = std::max(st->availMax, *avail);
    }
    return hr;
}
DETOURS(D_Begin);

template <int I>
HRESULT STDMETHODCALLTYPE D_End(ISpatialAudioObjectRenderStreamBase* self) {
    if (t_inProbe) return g_End.orig[I](self);
    std::string out;
    {
        // Buffers are filled between GetBuffer and here, so this is where they are measured.
        std::lock_guard<std::mutex> lk(g_stateMx);
        StreamState* st = GetStreamLocked(self);
        ProcessPendingLocked(st);
        st->totalUpdates++;
        ULONGLONG now = GetTickCount64();
        if (now - st->secStart >= 1000) out = FlushLocked(st, now);
    }
    HRESULT hr = g_End.orig[I](self);
    if (!out.empty()) LogLine(out);
    return hr;
}
DETOURS(D_End);

static void OnObjectActivated(void* self, AudioObjectType type, void** obj, HRESULT hr, bool meta, void* caller) {
    bool logIt = false;
    uint32_t sid = 0, oid = 0, nDyn = 0;
    {
        std::lock_guard<std::mutex> lk(g_stateMx);
        StreamState* st = GetStreamLocked(self);
        sid = st->id;
        if (SUCCEEDED(hr) && obj && *obj) {
            auto it = g_objs.find(*obj);
            ObjInfo* o = it != g_objs.end() ? it->second : (g_objs[*obj] = new ObjInfo());
            *o = ObjInfo();
            o->id = oid = g_nextObjId++;
            o->st = st;
            o->type = type;
            o->lastSeenTick = GetTickCount64();
            if (type == AudioObjectType_Dynamic) {
                st->dynActivated++;
                nDyn = ++st->totalDynActivated;
                logIt = nDyn <= 16;  // the first few individually, the rest in the per-second line
            } else {
                st->staticActivated++;
                logIt = true;
            }
        } else {
            st->activateFails++;
            st->lastActivateFail = hr;
            logIt = st->activateFails <= 1;
        }
    }
    if (logIt) {
        int b = ObjTypeBit(type);
        Logf("[stream %u] Activate%s(%s) -> %s obj#%u%s caller=%s", sid, meta ? "ObjectForMetadataCommands" : "SpatialAudioObject",
             b >= 0 && b < kObjTypeCount ? kObjTypeNames[b] : "?", Hr(hr).c_str(), oid,
             nDyn == 16 ? " (further dynamic activations only counted)" : "", ModuleOf(caller).c_str());
    }
    if (SUCCEEDED(hr) && obj && *obj) HookObject(*obj, meta);
}

template <int I>
HRESULT STDMETHODCALLTYPE D_ActivateObject(void* self, AudioObjectType type, void** obj) {
    void* caller = _ReturnAddress();
    HRESULT hr = g_ActivateObject.orig[I](self, type, obj);
    if (!t_inProbe) OnObjectActivated(self, type, obj, hr, false, caller);
    return hr;
}
DETOURS(D_ActivateObject);

template <int I>
HRESULT STDMETHODCALLTYPE D_ActivateObjectMeta(void* self, AudioObjectType type, void** obj) {
    void* caller = _ReturnAddress();
    HRESULT hr = g_ActivateObjectMeta.orig[I](self, type, obj);
    if (!t_inProbe) OnObjectActivated(self, type, obj, hr, true, caller);
    return hr;
}
DETOURS(D_ActivateObjectMeta);

// ---------------------------------------------------------------------------
// ISpatialAudioClient hooks

using GetMaxDyn_t = HRESULT(STDMETHODCALLTYPE*)(ISpatialAudioClient*, UINT32*);
using IsFmtSupported_t = HRESULT(STDMETHODCALLTYPE*)(ISpatialAudioClient*, const WAVEFORMATEX*);
using IsStreamAvail_t = HRESULT(STDMETHODCALLTYPE*)(ISpatialAudioClient*, REFIID, const PROPVARIANT*);
using ActivateStream_t = HRESULT(STDMETHODCALLTYPE*)(ISpatialAudioClient*, const PROPVARIANT*, REFIID, void**);

static MultiHook<GetMaxDyn_t> g_GetMaxDyn{"ISpatialAudioClient::GetMaxDynamicObjectCount"};
static MultiHook<IsFmtSupported_t> g_IsObjFmtSupported{"ISpatialAudioClient::IsAudioObjectFormatSupported"};
static MultiHook<IsStreamAvail_t> g_IsStreamAvail{"ISpatialAudioClient::IsSpatialAudioStreamAvailable"};
static MultiHook<ActivateStream_t> g_ActivateStream{"ISpatialAudioClient::ActivateSpatialAudioStream"};

static LONG g_isacQueryLogs = 0;

template <int I>
HRESULT STDMETHODCALLTYPE D_GetMaxDyn(ISpatialAudioClient* self, UINT32* n) {
    void* caller = _ReturnAddress();
    HRESULT hr = g_GetMaxDyn.orig[I](self, n);
    if (!t_inProbe && InterlockedIncrement(&g_isacQueryLogs) <= 200)
        Logf("ISpatialAudioClient::GetMaxDynamicObjectCount -> %s n=%u caller=%s", Hr(hr).c_str(),
             SUCCEEDED(hr) && n ? *n : 0, ModuleOf(caller).c_str());
    return hr;
}
DETOURS(D_GetMaxDyn);

template <int I>
HRESULT STDMETHODCALLTYPE D_IsObjFmtSupported(ISpatialAudioClient* self, const WAVEFORMATEX* f) {
    void* caller = _ReturnAddress();
    HRESULT hr = g_IsObjFmtSupported.orig[I](self, f);
    if (!t_inProbe && InterlockedIncrement(&g_isacQueryLogs) <= 200)
        Logf("ISpatialAudioClient::IsAudioObjectFormatSupported(%s) -> %s caller=%s", WfxStr(f).c_str(),
             Hr(hr).c_str(), ModuleOf(caller).c_str());
    return hr;
}
DETOURS(D_IsObjFmtSupported);

template <int I>
HRESULT STDMETHODCALLTYPE D_IsStreamAvail(ISpatialAudioClient* self, REFIID iid, const PROPVARIANT* aux) {
    void* caller = _ReturnAddress();
    HRESULT hr = g_IsStreamAvail.orig[I](self, iid, aux);
    if (!t_inProbe && InterlockedIncrement(&g_isacQueryLogs) <= 200)
        Logf("ISpatialAudioClient::IsSpatialAudioStreamAvailable(%s, aux vt=%d) -> %s caller=%s", IidName(iid).c_str(),
             aux ? aux->vt : -1, Hr(hr).c_str(), ModuleOf(caller).c_str());
    return hr;
}
DETOURS(D_IsStreamAvail);

static const char* CategoryStr(AUDIO_STREAM_CATEGORY c) {
    switch (c) {
        case AudioCategory_Other: return "Other";
        case AudioCategory_ForegroundOnlyMedia: return "ForegroundOnlyMedia";
        case AudioCategory_Communications: return "Communications";
        case AudioCategory_Alerts: return "Alerts";
        case AudioCategory_SoundEffects: return "SoundEffects";
        case AudioCategory_GameEffects: return "GameEffects";
        case AudioCategory_GameMedia: return "GameMedia";
        case AudioCategory_GameChat: return "GameChat";
        case AudioCategory_Speech: return "Speech";
        case AudioCategory_Movie: return "Movie";
        case AudioCategory_Media: return "Media";
        default: return "?";
    }
}

struct ParsedParams {
    std::string text;
    bool isFloat = true;
    int bits = 32;
};

static ParsedParams DescribeActivationParams(const PROPVARIANT* p, REFIID riid) {
    ParsedParams r;
    if (!p) {
        r.text = "    params: (null PROPVARIANT)";
        return r;
    }
    AppendF(r.text, "    params: vt=%d", p->vt);
    if (p->vt != VT_BLOB || !p->blob.pBlobData) return r;
    ULONG size = p->blob.cbSize;
    AppendF(r.text, " blob=%lu bytes", size);
    if (size < sizeof(SpatialAudioObjectRenderStreamActivationParams)) return r;
    // The leading fields (format, static mask, min/max dynamic, category, event) are the same in
    // the plain, "2" and ForMetadata variants.
    auto a = (const SpatialAudioObjectRenderStreamActivationParams*)p->blob.pBlobData;
    AppendF(r.text, "\r\n      ObjectFormat=%s\r\n      StaticObjectTypeMask=%s\r\n      MinDynamicObjectCount=%u MaxDynamicObjectCount=%u Category=%s(%d) EventHandle=%s",
            WfxStr(a->ObjectFormat).c_str(), ObjMaskStr(a->StaticObjectTypeMask).c_str(), a->MinDynamicObjectCount,
            a->MaxDynamicObjectCount, CategoryStr(a->Category), (int)a->Category, a->EventHandle ? "set" : "null");
    if (a->ObjectFormat) {
        r.isFloat = FormatIsFloat(a->ObjectFormat);
        r.bits = a->ObjectFormat->wBitsPerSample;
    }
    if (IsEqualIID(riid, __uuidof(ISpatialAudioObjectRenderStreamForMetadata)) &&
        size >= sizeof(SpatialAudioObjectRenderStreamForMetadataActivationParams)) {
        auto m = (const SpatialAudioObjectRenderStreamForMetadataActivationParams*)p->blob.pBlobData;
        AppendF(r.text, "\r\n      MetadataFormatId=%s MaxMetadataItemCount=%u MetadataActivationParams=%s",
                GuidStr(m->MetadataFormatId).c_str(), m->MaxMetadataItemCount,
                m->MetadataActivationParams ? "set" : "null");
        if (m->MetadataActivationParams) AppendF(r.text, "(vt=%d)", m->MetadataActivationParams->vt);
    } else if (size > sizeof(SpatialAudioObjectRenderStreamActivationParams)) {
        // SpatialAudioObjectRenderStreamActivationParams2 appends SPATIAL_AUDIO_STREAM_OPTIONS.
        UINT32 opts = *(const UINT32*)(p->blob.pBlobData + sizeof(SpatialAudioObjectRenderStreamActivationParams));
        AppendF(r.text, "\r\n      (ActivationParams2) Options=0x%X%s", opts, (opts & 1) ? " OFFLOAD" : "");
    }
    return r;
}

static void RegisterStream(void* stream, REFIID riid, const ParsedParams& pp) {
    bool meta = IsEqualIID(riid, __uuidof(ISpatialAudioObjectRenderStreamForMetadata)) != 0;
    uint32_t id;
    {
        std::lock_guard<std::mutex> lk(g_stateMx);
        StreamState* st = GetStreamLocked(stream);
        st->metadata = meta;
        st->isFloat = pp.isFloat;
        st->bits = pp.bits;
        id = st->id;
    }
    Logf("[stream %u] registered as %s (samples %s%d)", id, IidName(riid).c_str(), pp.isFloat ? "float" : "int", pp.bits);
    if (!meta && !IsEqualIID(riid, __uuidof(ISpatialAudioObjectRenderStream))) {
        Logf("[stream %u] unknown stream interface, not hooking its methods", id);
        return;
    }
    HookSlot(stream, 5, g_Start, D_Start_detours);
    HookSlot(stream, 6, g_Stop, D_Stop_detours);
    HookSlot(stream, 7, g_Reset, D_Reset_detours);
    HookSlot(stream, 8, g_Begin, D_Begin_detours);
    HookSlot(stream, 9, g_End, D_End_detours);
    if (meta)
        HookSlot(stream, 10, g_ActivateObjectMeta, D_ActivateObjectMeta_detours);
    else
        HookSlot(stream, 10, g_ActivateObject, D_ActivateObject_detours);
    ApplyHooks("stream");
}

template <int I>
HRESULT STDMETHODCALLTYPE D_ActivateStream(ISpatialAudioClient* self, const PROPVARIANT* p, REFIID riid, void** out) {
    if (t_inProbe) return g_ActivateStream.orig[I](self, p, riid, out);
    void* caller = _ReturnAddress();
    ParsedParams pp;
    {
        ProbeScope g;
        pp = DescribeActivationParams(p, riid);  // before the call: the format pointer is the caller's
    }
    HRESULT hr = g_ActivateStream.orig[I](self, p, riid, out);
    ProbeScope g;
    Logf("ISpatialAudioClient::ActivateSpatialAudioStream(%s) -> %s caller=%s\r\n%s", IidName(riid).c_str(),
         Hr(hr).c_str(), ModuleOf(caller).c_str(), pp.text.c_str());
    if (SUCCEEDED(hr) && out && *out) RegisterStream(*out, riid, pp);
    return hr;
}
DETOURS(D_ActivateStream);

static void DumpSpatialClient(ISpatialAudioClient* c) {
    ProbeScope g;
    std::string s = "ISpatialAudioClient capabilities:";
    AudioObjectType native = AudioObjectType_None;
    HRESULT h = c->GetNativeStaticObjectTypeMask(&native);
    AppendF(s, "\r\n    NativeStaticObjectTypeMask -> %s %s", Hr(h).c_str(), ObjMaskStr(native).c_str());
    UINT32 maxDyn = 0;
    h = c->GetMaxDynamicObjectCount(&maxDyn);
    AppendF(s, "\r\n    MaxDynamicObjectCount -> %s %u", Hr(h).c_str(), maxDyn);
    h = c->IsSpatialAudioStreamAvailable(__uuidof(ISpatialAudioObjectRenderStream), nullptr);
    AppendF(s, "\r\n    IsSpatialAudioStreamAvailable(RenderStream) -> %s", Hr(h).c_str());
    h = c->IsSpatialAudioStreamAvailable(__uuidof(ISpatialAudioObjectRenderStreamForMetadata), nullptr);
    AppendF(s, "\r\n    IsSpatialAudioStreamAvailable(RenderStreamForMetadata) -> %s", Hr(h).c_str());
    IAudioFormatEnumerator* fe = nullptr;
    h = c->GetSupportedAudioObjectFormatEnumerator(&fe);
    if (SUCCEEDED(h) && fe) {
        UINT32 n = 0;
        fe->GetCount(&n);
        for (UINT32 i = 0; i < n; i++) {
            WAVEFORMATEX* f = nullptr;
            if (FAILED(fe->GetFormat(i, &f)) || !f) continue;
            UINT32 mf = 0;
            HRESULT hm = c->GetMaxFrameCount(f, &mf);
            AppendF(s, "\r\n    format[%u] %s maxFrameCount=%u (%s)", i, WfxStr(f).c_str(), mf, Hr(hm).c_str());
        }
        fe->Release();
    } else
        AppendF(s, "\r\n    GetSupportedAudioObjectFormatEnumerator -> %s", Hr(h).c_str());
    for (int b = 1; b < kObjTypeCount; b++) {
        if (!(native & (1u << b))) continue;
        float x = 0, y = 0, z = 0;
        h = c->GetStaticObjectPosition((AudioObjectType)(1u << b), &x, &y, &z);
        AppendF(s, "\r\n    static %s position (%+.2f,%+.2f,%+.2f) %s", kObjTypeNames[b], x, y, z,
                SUCCEEDED(h) ? "" : Hr(h).c_str());
    }
    LogLine(s);
}

static void HookSpatialClient(IUnknown* unk) {
    ISpatialAudioClient* c = nullptr;
    if (FAILED(unk->QueryInterface(__uuidof(ISpatialAudioClient), (void**)&c)) || !c) return;
    HookSlot(c, 5, g_GetMaxDyn, D_GetMaxDyn_detours);
    HookSlot(c, 8, g_IsObjFmtSupported, D_IsObjFmtSupported_detours);
    HookSlot(c, 9, g_IsStreamAvail, D_IsStreamAvail_detours);
    HookSlot(c, 10, g_ActivateStream, D_ActivateStream_detours);
    ApplyHooks("spatial client");
    DumpSpatialClient(c);
    c->Release();
}

// ---------------------------------------------------------------------------
// IAudioClient hooks (the non-spatial path, and whatever else renders: audioware, video, ...)

using Init_t = HRESULT(STDMETHODCALLTYPE*)(IAudioClient*, AUDCLNT_SHAREMODE, DWORD, REFERENCE_TIME, REFERENCE_TIME,
                                           const WAVEFORMATEX*, LPCGUID);
using IsFormatSupported_t = HRESULT(STDMETHODCALLTYPE*)(IAudioClient*, AUDCLNT_SHAREMODE, const WAVEFORMATEX*,
                                                        WAVEFORMATEX**);
using GetMixFormat_t = HRESULT(STDMETHODCALLTYPE*)(IAudioClient*, WAVEFORMATEX**);
using InitShared_t = HRESULT(STDMETHODCALLTYPE*)(IAudioClient3*, DWORD, UINT32, const WAVEFORMATEX*, LPCGUID);

static MultiHook<Init_t> g_Init{"IAudioClient::Initialize"};
static MultiHook<IsFormatSupported_t> g_IsFormatSupported{"IAudioClient::IsFormatSupported"};
static MultiHook<GetMixFormat_t> g_GetMixFormat{"IAudioClient::GetMixFormat"};
static MultiHook<InitShared_t> g_InitShared{"IAudioClient3::InitializeSharedAudioStream"};
static LONG g_fmtQueryLogs = 0;

template <int I>
HRESULT STDMETHODCALLTYPE D_Init(IAudioClient* self, AUDCLNT_SHAREMODE mode, DWORD flags, REFERENCE_TIME dur,
                                 REFERENCE_TIME period, const WAVEFORMATEX* f, LPCGUID session) {
    if (t_inProbe) return g_Init.orig[I](self, mode, flags, dur, period, f, session);
    void* caller = _ReturnAddress();
    std::string fs = WfxStr(f);
    HRESULT hr = g_Init.orig[I](self, mode, flags, dur, period, f, session);
    Logf("IAudioClient::Initialize(%s, flags=0x%lX, buffer=%.1fms, period=%.1fms) fmt=%s -> %s client=%p caller=%s",
         mode == AUDCLNT_SHAREMODE_EXCLUSIVE ? "EXCLUSIVE" : "SHARED", flags, dur / 10000.0, period / 10000.0, fs.c_str(),
         Hr(hr).c_str(), (void*)self, ModuleOf(caller).c_str());
    return hr;
}
DETOURS(D_Init);

template <int I>
HRESULT STDMETHODCALLTYPE D_IsFormatSupported(IAudioClient* self, AUDCLNT_SHAREMODE mode, const WAVEFORMATEX* f,
                                              WAVEFORMATEX** closest) {
    if (t_inProbe) return g_IsFormatSupported.orig[I](self, mode, f, closest);
    void* caller = _ReturnAddress();
    std::string fs = WfxStr(f);
    HRESULT hr = g_IsFormatSupported.orig[I](self, mode, f, closest);
    if (InterlockedIncrement(&g_fmtQueryLogs) <= 100)
        Logf("IAudioClient::IsFormatSupported(%s, %s) -> %s closest=%s caller=%s",
             mode == AUDCLNT_SHAREMODE_EXCLUSIVE ? "EXCLUSIVE" : "SHARED", fs.c_str(), Hr(hr).c_str(),
             closest && *closest ? WfxStr(*closest).c_str() : "-", ModuleOf(caller).c_str());
    return hr;
}
DETOURS(D_IsFormatSupported);

template <int I>
HRESULT STDMETHODCALLTYPE D_GetMixFormat(IAudioClient* self, WAVEFORMATEX** f) {
    if (t_inProbe) return g_GetMixFormat.orig[I](self, f);
    void* caller = _ReturnAddress();
    HRESULT hr = g_GetMixFormat.orig[I](self, f);
    if (InterlockedIncrement(&g_fmtQueryLogs) <= 100)
        Logf("IAudioClient::GetMixFormat -> %s %s caller=%s", Hr(hr).c_str(),
             SUCCEEDED(hr) && f ? WfxStr(*f).c_str() : "", ModuleOf(caller).c_str());
    return hr;
}
DETOURS(D_GetMixFormat);

template <int I>
HRESULT STDMETHODCALLTYPE D_InitShared(IAudioClient3* self, DWORD flags, UINT32 periodFrames, const WAVEFORMATEX* f,
                                       LPCGUID session) {
    if (t_inProbe) return g_InitShared.orig[I](self, flags, periodFrames, f, session);
    void* caller = _ReturnAddress();
    std::string fs = WfxStr(f);
    HRESULT hr = g_InitShared.orig[I](self, flags, periodFrames, f, session);
    Logf("IAudioClient3::InitializeSharedAudioStream(flags=0x%lX, period=%u frames) fmt=%s -> %s caller=%s", flags,
         periodFrames, fs.c_str(), Hr(hr).c_str(), ModuleOf(caller).c_str());
    return hr;
}
DETOURS(D_InitShared);

static void HookAudioClient(IUnknown* unk) {
    IAudioClient* c = nullptr;
    if (SUCCEEDED(unk->QueryInterface(__uuidof(IAudioClient), (void**)&c)) && c) {
        HookSlot(c, 3, g_Init, D_Init_detours);
        HookSlot(c, 7, g_IsFormatSupported, D_IsFormatSupported_detours);
        HookSlot(c, 8, g_GetMixFormat, D_GetMixFormat_detours);
        c->Release();
    }
    IAudioClient3* c3 = nullptr;
    if (SUCCEEDED(unk->QueryInterface(__uuidof(IAudioClient3), (void**)&c3)) && c3) {
        HookSlot(c3, 20, g_InitShared, D_InitShared_detours);
        c3->Release();
    }
    ApplyHooks("audio client");
}

// ---------------------------------------------------------------------------
// IMMDevice::Activate, ActivateAudioInterfaceAsync, CoCreateInstance

using Activate_t = HRESULT(STDMETHODCALLTYPE*)(IMMDevice*, REFIID, DWORD, PROPVARIANT*, void**);
static MultiHook<Activate_t> g_Activate{"IMMDevice::Activate"};

template <int I>
HRESULT STDMETHODCALLTYPE D_Activate(IMMDevice* self, REFIID iid, DWORD ctx, PROPVARIANT* params, void** out) {
    if (t_inProbe) return g_Activate.orig[I](self, iid, ctx, params, out);
    void* caller = _ReturnAddress();
    HRESULT hr = g_Activate.orig[I](self, iid, ctx, params, out);
    ProbeScope g;
    Logf("IMMDevice::Activate(%s, ctx=0x%lX, params vt=%d) -> %s device=%s caller=%s", IidName(iid).c_str(), ctx,
         params ? params->vt : -1, Hr(hr).c_str(), DeviceStr(self).c_str(), ModuleOf(caller).c_str());
    if (SUCCEEDED(hr) && out && *out) {
        IUnknown* u = (IUnknown*)*out;
        if (IsEqualIID(iid, __uuidof(IAudioClient)) || IsEqualIID(iid, __uuidof(IAudioClient2)) ||
            IsEqualIID(iid, __uuidof(IAudioClient3)))
            HookAudioClient(u);
        else if (IsEqualIID(iid, __uuidof(ISpatialAudioClient)) || IsEqualIID(iid, __uuidof(ISpatialAudioClient2)))
            HookSpatialClient(u);
    }
    return hr;
}
DETOURS(D_Activate);

using ActivateAsync_t = HRESULT(WINAPI*)(LPCWSTR, REFIID, PROPVARIANT*, IActivateAudioInterfaceCompletionHandler*,
                                         IActivateAudioInterfaceAsyncOperation**);
static ActivateAsync_t o_ActivateAsync = nullptr;

static HRESULT WINAPI D_ActivateAsync(LPCWSTR path, REFIID iid, PROPVARIANT* params,
                                      IActivateAudioInterfaceCompletionHandler* handler,
                                      IActivateAudioInterfaceAsyncOperation** op) {
    void* caller = _ReturnAddress();
    HRESULT hr = o_ActivateAsync(path, iid, params, handler, op);
    if (!t_inProbe)
        Logf("ActivateAudioInterfaceAsync(%s, %s, params vt=%d) -> %s caller=%s", Narrow(path).c_str(),
             IidName(iid).c_str(), params ? params->vt : -1, Hr(hr).c_str(), ModuleOf(caller).c_str());
    return hr;
}

static volatile LONG g_deviceHooked = 0;

static void InstallDeviceHooks(IUnknown* unk) {
    if (g_deviceHooked) return;
    ProbeScope g;
    IMMDeviceEnumerator* en = nullptr;
    if (FAILED(unk->QueryInterface(__uuidof(IMMDeviceEnumerator), (void**)&en)) || !en) return;
    IMMDevice* dev = nullptr;
    HRESULT hr = en->GetDefaultAudioEndpoint(eRender, eConsole, &dev);
    if (FAILED(hr) || !dev) {
        IMMDeviceCollection* col = nullptr;
        if (SUCCEEDED(en->EnumAudioEndpoints(eAll, DEVICE_STATEMASK_ALL, &col)) && col) {
            UINT n = 0;
            col->GetCount(&n);
            if (n) col->Item(0, &dev);
            col->Release();
        }
    }
    if (dev) {
        if (InterlockedExchange(&g_deviceHooked, 1) == 0) {
            Logf("default render endpoint: %s (GetDefaultAudioEndpoint -> %s)", DeviceStr(dev).c_str(), Hr(hr).c_str());
            HookSlot(dev, 3, g_Activate, D_Activate_detours);
            HMODULE mm = GetModuleHandleW(L"mmdevapi.dll");
            void* target = mm ? (void*)GetProcAddress(mm, "ActivateAudioInterfaceAsync") : nullptr;
            MH_STATUS st = target ? MH_CreateHook(target, (void*)&D_ActivateAsync, (void**)&o_ActivateAsync) : MH_ERROR_FUNCTION_NOT_FOUND;
            if (st == MH_OK) st = MH_QueueEnableHook(target);
            Logf("hook ActivateAudioInterfaceAsync: %s", st == MH_OK ? "queued" : MH_StatusToString(st));
            ApplyHooks("device");
        }
        dev->Release();
    } else {
        Logf("MMDeviceEnumerator created but no endpoint to read IMMDevice's vtable from yet; will retry");
    }
    en->Release();
}

using CoCreateInstance_t = HRESULT(WINAPI*)(REFCLSID, LPUNKNOWN, DWORD, REFIID, LPVOID*);
using CoCreateInstanceEx_t = HRESULT(WINAPI*)(REFCLSID, IUnknown*, DWORD, COSERVERINFO*, DWORD, MULTI_QI*);
static CoCreateInstance_t o_CoCreateInstance = nullptr;
static CoCreateInstanceEx_t o_CoCreateInstanceEx = nullptr;

static HRESULT WINAPI D_CoCreateInstance(REFCLSID clsid, LPUNKNOWN outer, DWORD ctx, REFIID iid, LPVOID* out) {
    HRESULT hr = o_CoCreateInstance(clsid, outer, ctx, iid, out);
    if (!t_inProbe && !g_deviceHooked && SUCCEEDED(hr) && out && *out &&
        IsEqualCLSID(clsid, __uuidof(MMDeviceEnumerator)))
        InstallDeviceHooks((IUnknown*)*out);
    return hr;
}

static HRESULT WINAPI D_CoCreateInstanceEx(REFCLSID clsid, IUnknown* outer, DWORD ctx, COSERVERINFO* srv, DWORD n,
                                           MULTI_QI* res) {
    HRESULT hr = o_CoCreateInstanceEx(clsid, outer, ctx, srv, n, res);
    if (!t_inProbe && !g_deviceHooked && SUCCEEDED(hr) && res && IsEqualCLSID(clsid, __uuidof(MMDeviceEnumerator)))
        for (DWORD i = 0; i < n; i++)
            if (SUCCEEDED(res[i].hr) && res[i].pItf) {
                InstallDeviceHooks(res[i].pItf);
                break;
            }
    return hr;
}

// ---------------------------------------------------------------------------
// Entry

static void OpenLog(HMODULE self) {
    wchar_t path[MAX_PATH];
    DWORD n = GetModuleFileNameW(self, path, MAX_PATH);
    while (n && path[n - 1] != L'\\') n--;
    path[n] = 0;
    wcscat_s(path, L"spatial_audio_probe.log");
    g_log = CreateFileW(path, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
                        OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
}

static bool ShouldRun() {
    wchar_t exe[MAX_PATH];
    DWORD n = GetModuleFileNameW(nullptr, exe, MAX_PATH);
    const wchar_t* base = exe;
    for (DWORD i = 0; i < n; i++)
        if (exe[i] == L'\\') base = exe + i + 1;
    // The ASI loader also sits in front of the crash reporter; keep out of it.
    return _wcsnicmp(base, L"REDEngineErrorReporter", 22) != 0;
}

static void Init(HMODULE self) {
    OpenLog(self);
    wchar_t exe[MAX_PATH];
    GetModuleFileNameW(nullptr, exe, MAX_PATH);
    LogLine("================================================================");
    Logf("spatial_audio_probe loaded into %s (pid %lu), built " __DATE__ " " __TIME__, Narrow(exe).c_str(),
         GetCurrentProcessId());
    MH_STATUS st = MH_Initialize();
    if (st != MH_OK) {
        Logf("MH_Initialize failed: %s; probe inactive", MH_StatusToString(st));
        return;
    }
    // combase is a KnownDLL already mapped in practically every process; loading it here is safe.
    HMODULE cb = GetModuleHandleW(L"combase.dll");
    if (!cb) cb = LoadLibraryW(L"combase.dll");
    void* t1 = cb ? (void*)GetProcAddress(cb, "CoCreateInstance") : nullptr;
    void* t2 = cb ? (void*)GetProcAddress(cb, "CoCreateInstanceEx") : nullptr;
    st = t1 ? MH_CreateHook(t1, (void*)&D_CoCreateInstance, (void**)&o_CoCreateInstance) : MH_ERROR_FUNCTION_NOT_FOUND;
    if (st == MH_OK) st = MH_EnableHook(t1);
    Logf("hook combase!CoCreateInstance: %s", MH_StatusToString(st));
    st = t2 ? MH_CreateHook(t2, (void*)&D_CoCreateInstanceEx, (void**)&o_CoCreateInstanceEx) : MH_ERROR_FUNCTION_NOT_FOUND;
    if (st == MH_OK) st = MH_EnableHook(t2);
    Logf("hook combase!CoCreateInstanceEx: %s", MH_StatusToString(st));
}

BOOL APIENTRY DllMain(HMODULE mod, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(mod);
        if (ShouldRun()) Init(mod);
    }
    return TRUE;
}
