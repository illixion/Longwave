// probe_harness — loads spatial_audio_probe.asi like the ASI loader would, then
// drives the hooked paths on the default render endpoint so the probe's log can
// be checked without the game:
//   1. IAudioClient: GetMixFormat + shared Initialize (the non-spatial path)
//   2. ISpatialAudioClient: capabilities, then (if a spatial format is enabled)
//      a 7.1.4 bed + up to 4 dynamic objects for ~2 s at -60 dBFS (inaudible
//      in practice), moving the dynamic objects in a circle.
// Usage: probe_harness.exe [path\to\spatial_audio_probe.asi]
//        probe_harness.exe --list   (no probe: spatial state of every active render endpoint)

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <spatialaudioclient.h>
#include <functiondiscoverykeys_devpkey.h>
#include <cmath>
#include <cstdio>
#include <vector>

#pragma comment(lib, "ole32.lib")

// Read-only: MaxDynamicObjectCount is 0 when no spatial format (Windows Sonic, Dolby Atmos, DTS:X) is
// enabled on the endpoint, and the format's object budget otherwise.
static int ListEndpoints() {
    CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    IMMDeviceEnumerator* en = nullptr;
    if (FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, __uuidof(IMMDeviceEnumerator),
                                (void**)&en)))
        return 1;
    IMMDevice* def = nullptr;
    LPWSTR defId = nullptr;
    if (SUCCEEDED(en->GetDefaultAudioEndpoint(eRender, eConsole, &def))) def->GetId(&defId);
    IMMDeviceCollection* col = nullptr;
    en->EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE, &col);
    UINT n = 0;
    if (col) col->GetCount(&n);
    for (UINT i = 0; i < n; i++) {
        IMMDevice* d = nullptr;
        if (FAILED(col->Item(i, &d))) continue;
        LPWSTR id = nullptr;
        d->GetId(&id);
        IPropertyStore* ps = nullptr;
        PROPVARIANT pv;
        PropVariantInit(&pv);
        if (SUCCEEDED(d->OpenPropertyStore(STGM_READ, &ps))) ps->GetValue(PKEY_Device_FriendlyName, &pv);
        UINT32 maxDyn = 0;
        HRESULT hr = E_FAIL;
        ISpatialAudioClient* sac = nullptr;
        if (SUCCEEDED(d->Activate(__uuidof(ISpatialAudioClient), CLSCTX_INPROC_SERVER, nullptr, (void**)&sac))) {
            hr = sac->GetMaxDynamicObjectCount(&maxDyn);
            sac->Release();
        }
        WAVEFORMATEX* mix = nullptr;
        IAudioClient* ac = nullptr;
        if (SUCCEEDED(d->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, (void**)&ac))) {
            ac->GetMixFormat(&mix);
            ac->Release();
        }
        printf("%s %-50ls maxDynamicObjects=%-4u (0x%08lX) mix=%uch %luHz  -> spatial %s\n",
               defId && id && !wcscmp(id, defId) ? "*" : " ", pv.vt == VT_LPWSTR ? pv.pwszVal : L"?", maxDyn, hr,
               mix ? mix->nChannels : 0, mix ? mix->nSamplesPerSec : 0, maxDyn ? "ON" : "off");
        if (mix) CoTaskMemFree(mix);
        PropVariantClear(&pv);
        if (ps) ps->Release();
        CoTaskMemFree(id);
        d->Release();
    }
    printf("(* = default render endpoint)\n");
    return 0;
}

int wmain(int argc, wchar_t** argv) {
    if (argc > 1 && !wcscmp(argv[1], L"--list")) return ListEndpoints();
    const wchar_t* dll = argc > 1 ? argv[1] : L"spatial_audio_probe.asi";
    HMODULE probe = LoadLibraryW(dll);
    printf("LoadLibrary(%ls) -> %p (err %lu)\n", dll, (void*)probe, probe ? 0 : GetLastError());

    CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    IMMDeviceEnumerator* en = nullptr;
    HRESULT hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, __uuidof(IMMDeviceEnumerator),
                                  (void**)&en);
    printf("CoCreateInstance(MMDeviceEnumerator) -> 0x%08lX\n", hr);
    if (FAILED(hr)) return 1;
    IMMDevice* dev = nullptr;
    hr = en->GetDefaultAudioEndpoint(eRender, eConsole, &dev);
    printf("GetDefaultAudioEndpoint -> 0x%08lX\n", hr);
    if (FAILED(hr)) return 1;

    // 1. Plain WASAPI
    IAudioClient* ac = nullptr;
    hr = dev->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, (void**)&ac);
    printf("Activate(IAudioClient) -> 0x%08lX\n", hr);
    if (SUCCEEDED(hr)) {
        WAVEFORMATEX* mix = nullptr;
        hr = ac->GetMixFormat(&mix);
        printf("GetMixFormat -> 0x%08lX (%u ch, %lu Hz)\n", hr, mix ? mix->nChannels : 0, mix ? mix->nSamplesPerSec : 0);
        if (mix) {
            hr = ac->Initialize(AUDCLNT_SHAREMODE_SHARED, 0, 1000000, 0, mix, nullptr);
            printf("Initialize(shared, mix format) -> 0x%08lX\n", hr);
            CoTaskMemFree(mix);
        }
        ac->Release();
    }

    // 2. Spatial
    ISpatialAudioClient* sac = nullptr;
    hr = dev->Activate(__uuidof(ISpatialAudioClient), CLSCTX_INPROC_SERVER, nullptr, (void**)&sac);
    printf("Activate(ISpatialAudioClient) -> 0x%08lX\n", hr);
    if (FAILED(hr)) return 1;
    UINT32 maxDyn = 0;
    hr = sac->GetMaxDynamicObjectCount(&maxDyn);
    printf("GetMaxDynamicObjectCount -> 0x%08lX, %u\n", hr, maxDyn);
    AudioObjectType native = AudioObjectType_None;
    sac->GetNativeStaticObjectTypeMask(&native);
    printf("NativeStaticObjectTypeMask -> 0x%X\n", native);
    hr = sac->IsSpatialAudioStreamAvailable(__uuidof(ISpatialAudioObjectRenderStream), nullptr);
    printf("IsSpatialAudioStreamAvailable -> 0x%08lX\n", hr);

    IAudioFormatEnumerator* fe = nullptr;
    WAVEFORMATEX* fmt = nullptr;
    if (SUCCEEDED(sac->GetSupportedAudioObjectFormatEnumerator(&fe)) && fe) fe->GetFormat(0, &fmt);
    if (!fmt) {
        printf("no object format (spatial sound is probably off) - done\n");
        return 0;
    }

    HANDLE ev = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    SpatialAudioObjectRenderStreamActivationParams p = {};
    p.ObjectFormat = fmt;
    p.StaticObjectTypeMask = (AudioObjectType)0x1FFE;  // 7.1.4
    p.MinDynamicObjectCount = 0;
    p.MaxDynamicObjectCount = maxDyn < 4 ? maxDyn : 4;
    p.Category = AudioCategory_GameEffects;
    p.EventHandle = ev;
    PROPVARIANT pv;
    PropVariantInit(&pv);
    pv.vt = VT_BLOB;
    pv.blob.cbSize = sizeof p;
    pv.blob.pBlobData = (BYTE*)&p;
    ISpatialAudioObjectRenderStream* rs = nullptr;
    hr = sac->ActivateSpatialAudioStream(&pv, __uuidof(ISpatialAudioObjectRenderStream), (void**)&rs);
    printf("ActivateSpatialAudioStream(7.1.4 + %u dyn) -> 0x%08lX\n", p.MaxDynamicObjectCount, hr);
    if (FAILED(hr)) return 0;

    std::vector<ISpatialAudioObject*> statics, dyns;
    for (int b = 1; b <= 12; b++) {
        ISpatialAudioObject* o = nullptr;
        if (SUCCEEDED(rs->ActivateSpatialAudioObject((AudioObjectType)(1u << b), &o))) statics.push_back(o);
    }
    for (UINT32 i = 0; i < p.MaxDynamicObjectCount; i++) {
        ISpatialAudioObject* o = nullptr;
        if (SUCCEEDED(rs->ActivateSpatialAudioObject(AudioObjectType_Dynamic, &o))) dyns.push_back(o);
    }
    printf("activated %zu static + %zu dynamic objects\n", statics.size(), dyns.size());

    rs->Start();
    double phase = 0;
    ULONGLONG start = GetTickCount64();
    UINT32 updates = 0;
    while (GetTickCount64() - start < 2300) {
        if (WaitForSingleObject(ev, 200) != WAIT_OBJECT_0) continue;
        UINT32 avail = 0, frames = 0;
        if (FAILED(rs->BeginUpdatingAudioObjects(&avail, &frames))) break;
        for (size_t i = 0; i < statics.size(); i++) {
            BYTE* buf;
            UINT32 len;
            if (SUCCEEDED(statics[i]->GetBuffer(&buf, &len))) {
                memset(buf, 0, len);
                if (i == 0) ((float*)buf)[0] = 0.001f;  // FL: a single -60 dBFS sample
            }
        }
        double t = (GetTickCount64() - start) / 1000.0;
        for (size_t i = 0; i < dyns.size(); i++) {
            BYTE* buf;
            UINT32 len;
            if (FAILED(dyns[i]->GetBuffer(&buf, &len))) continue;
            float* s = (float*)buf;
            for (UINT32 k = 0; k < len / 4; k++) s[k] = 0.001f * (float)sin(phase + k * 2 * 3.14159265 * 440 / 48000);
            double a = t * 2 + i * 1.5708;
            dyns[i]->SetPosition((float)(2 * cos(a)), 0.5f * (float)i, (float)(2 * sin(a)));
            dyns[i]->SetVolume(0.5f);
        }
        phase += frames * 2 * 3.14159265 * 440 / 48000;
        rs->EndUpdatingAudioObjects();
        updates++;
    }
    rs->Stop();
    printf("ran %u updates\n", updates);
    for (auto o : dyns) o->Release();
    for (auto o : statics) o->Release();
    rs->Release();
    sac->Release();
    dev->Release();
    en->Release();
    return 0;
}
