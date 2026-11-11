// WASAPI loopback: what an output device is playing, in its own mix format.
//
// Loopback taps a render endpoint after the Windows mixer, so it carries every
// application's audio at the endpoint's channel layout (stereo, 5.1, 7.1 ...).
// Two Windows behaviours to know:
//  - When nothing is playing, loopback delivers no packets at all (not
//    silence). The consumer must treat gaps in `qpc` as silence.
//  - The format is the endpoint's shared-mode mix format, normally 32-bit
//    float at 48 kHz; it changes if the user changes the speaker setup, which
//    invalidates the stream (start again).
#include "common.hpp"

#include <audioclient.h>
#include <mmdeviceapi.h>
// Define (not just declare) the property keys and format GUIDs used below.
#include <initguid.h>
#include <functiondiscoverykeys_devpkey.h>
#include <ksmedia.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <thread>
#include <vector>

namespace {

// COM for a shim-owned thread (the multithreaded apartment).
struct ComScope {
    HRESULT hr;
    ComScope() : hr(CoInitializeEx(nullptr, COINIT_MULTITHREADED)) {}
    ~ComScope() {
        if (SUCCEEDED(hr)) CoUninitialize();
    }
};

winrt::com_ptr<IMMDeviceEnumerator> make_enumerator() {
    winrt::com_ptr<IMMDeviceEnumerator> enumerator;
    winrt::check_hresult(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                                          IID_PPV_ARGS(enumerator.put())));
    return enumerator;
}

winrt::com_ptr<IMMDevice> find_endpoint(const char *id) {
    auto enumerator = make_enumerator();
    winrt::com_ptr<IMMDevice> device;
    if (id && *id) {
        winrt::check_hresult(enumerator->GetDevice(lw::widen(id).c_str(), device.put()));
    } else {
        winrt::check_hresult(enumerator->GetDefaultAudioEndpoint(eRender, eConsole, device.put()));
    }
    return device;
}

struct CoFormat {
    WAVEFORMATEX *format = nullptr;
    ~CoFormat() { CoTaskMemFree(format); }
};

lw_audio_format describe(const WAVEFORMATEX *format) {
    lw_audio_format out{};
    out.sample_rate = format->nSamplesPerSec;
    out.channels = format->nChannels;
    out.bits_per_sample = format->wBitsPerSample;
    out.block_align = format->nBlockAlign;
    out.is_float = format->wFormatTag == WAVE_FORMAT_IEEE_FLOAT;
    if (format->wFormatTag == WAVE_FORMAT_EXTENSIBLE && format->cbSize >= 22) {
        auto *ext = reinterpret_cast<const WAVEFORMATEXTENSIBLE *>(format);
        out.channel_mask = ext->dwChannelMask;
        out.is_float = IsEqualGUID(ext->SubFormat, KSDATAFORMAT_SUBTYPE_IEEE_FLOAT);
    }
    return out;
}

} // namespace

extern "C" int32_t lw_audio_endpoint_list(lw_audio_endpoint_info *out, int32_t capacity) {
    std::vector<lw_audio_endpoint_info> endpoints;
    lw_status status = lw::guarded("lw_audio_endpoint_list", [&]() -> lw_status {
        ComScope com;
        auto enumerator = make_enumerator();
        std::wstring default_id;
        {
            winrt::com_ptr<IMMDevice> def;
            if (SUCCEEDED(enumerator->GetDefaultAudioEndpoint(eRender, eConsole, def.put()))) {
                LPWSTR id = nullptr;
                if (SUCCEEDED(def->GetId(&id))) {
                    default_id = id;
                    CoTaskMemFree(id);
                }
            }
        }
        winrt::com_ptr<IMMDeviceCollection> collection;
        winrt::check_hresult(enumerator->EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE, collection.put()));
        UINT count = 0;
        collection->GetCount(&count);
        for (UINT i = 0; i < count; ++i) {
            winrt::com_ptr<IMMDevice> device;
            if (FAILED(collection->Item(i, device.put()))) continue;
            lw_audio_endpoint_info info{};
            LPWSTR id = nullptr;
            if (SUCCEEDED(device->GetId(&id))) {
                lw::copy_string(info.id, sizeof info.id, lw::narrow(id));
                info.is_default = default_id == id;
                CoTaskMemFree(id);
            }
            winrt::com_ptr<IPropertyStore> properties;
            if (SUCCEEDED(device->OpenPropertyStore(STGM_READ, properties.put()))) {
                PROPVARIANT name;
                PropVariantInit(&name);
                if (SUCCEEDED(properties->GetValue(PKEY_Device_FriendlyName, &name)) && name.vt == VT_LPWSTR)
                    lw::copy_string(info.name, sizeof info.name, lw::narrow(name.pwszVal));
                PropVariantClear(&name);
            }
            winrt::com_ptr<IAudioClient> client;
            if (SUCCEEDED(device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, client.put_void()))) {
                CoFormat mix;
                if (SUCCEEDED(client->GetMixFormat(&mix.format))) {
                    auto format = describe(mix.format);
                    info.channels = format.channels;
                    info.sample_rate = format.sample_rate;
                    info.channel_mask = format.channel_mask;
                }
            }
            endpoints.push_back(info);
        }
        return LW_OK;
    });
    if (status != LW_OK) return status;
    const int32_t total = static_cast<int32_t>(endpoints.size());
    for (int32_t i = 0; i < total && i < capacity && out; ++i) out[i] = endpoints[i];
    return total;
}

struct lw_audio_loopback {
    std::thread thread;
    std::atomic<bool> quit{false};
};

extern "C" lw_status lw_audio_loopback_start(const char *endpoint_id, lw_audio_callback callback, void *context,
                                             lw_audio_loopback **out, lw_audio_format *out_format) {
    if (!callback || !out) return lw::fail(LW_E_INVALID_ARG, "lw_audio_loopback_start: NULL argument");
    *out = nullptr;
    std::string id = endpoint_id ? endpoint_id : "";
    auto loopback = std::make_unique<lw_audio_loopback>();

    // Initialize on the capture thread itself (COM objects stay on the thread
    // that made them), and report the outcome back before returning.
    std::atomic<int> ready{0}; // 0 pending, 1 ok, -1 failed
    lw_status start_status = LW_OK;
    std::string start_error;
    lw_audio_format format{};
    HANDLE started = CreateEventW(nullptr, TRUE, FALSE, nullptr);

    auto *raw = loopback.get();
    loopback->thread = std::thread([=, &ready, &start_status, &start_error, &format]() {
        ComScope com;
        winrt::com_ptr<IAudioClient> client;
        winrt::com_ptr<IAudioCaptureClient> capture;
        lw_audio_format local_format{};
        lw_status status = lw::guarded("WASAPI loopback", [&]() -> lw_status {
            auto device = find_endpoint(id.c_str());
            winrt::check_hresult(device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, client.put_void()));
            CoFormat mix;
            winrt::check_hresult(client->GetMixFormat(&mix.format));
            local_format = describe(mix.format);
            // 100 ms of engine buffer; we drain every few milliseconds.
            winrt::check_hresult(client->Initialize(AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_LOOPBACK,
                                                    1'000'000, 0, mix.format, nullptr));
            winrt::check_hresult(client->GetService(IID_PPV_ARGS(capture.put())));
            winrt::check_hresult(client->Start());
            return LW_OK;
        });
        if (status != LW_OK) {
            start_status = status;
            start_error = lw_last_error();
            ready.store(-1);
            SetEvent(started);
            return;
        }
        format = local_format;
        ready.store(1);
        SetEvent(started);

        HANDLE mmcss = lw::join_mmcss(L"Pro Audio");
        while (!raw->quit.load(std::memory_order_relaxed)) {
            UINT32 packet = 0;
            if (FAILED(capture->GetNextPacketSize(&packet))) break; // device invalidated
            while (packet > 0) {
                BYTE *data = nullptr;
                UINT32 frames = 0;
                DWORD flags = 0;
                UINT64 qpc_100ns = 0;
                if (FAILED(capture->GetBuffer(&data, &frames, &flags, nullptr, &qpc_100ns))) break;
                uint32_t out_flags = 0;
                if (flags & AUDCLNT_BUFFERFLAGS_SILENT) out_flags |= LW_AUDIO_SILENT;
                if (flags & AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY) out_flags |= LW_AUDIO_DISCONTINUITY;
                callback(context, (flags & AUDCLNT_BUFFERFLAGS_SILENT) ? nullptr : data, frames,
                         frames * local_format.block_align,
                         lw::qpc_from_hundred_ns(static_cast<int64_t>(qpc_100ns)), out_flags);
                capture->ReleaseBuffer(frames);
                if (FAILED(capture->GetNextPacketSize(&packet))) break;
            }
            Sleep(2);
        }
        lw::leave_mmcss(mmcss);
        client->Stop();
    });

    WaitForSingleObject(started, INFINITE);
    CloseHandle(started);
    if (ready.load() != 1) {
        loopback->thread.join();
        return lw::fail(start_status, "%s", start_error.c_str());
    }
    if (out_format) *out_format = format;
    *out = loopback.release();
    return LW_OK;
}

extern "C" void lw_audio_loopback_stop(lw_audio_loopback *loopback) {
    if (!loopback) return;
    loopback->quit.store(true);
    if (loopback->thread.joinable()) loopback->thread.join();
    delete loopback;
}

// ---- Render: a stream we generate (the headset's microphone) -----------------

struct lw_audio_render {
    std::thread thread;
    std::atomic<bool> quit{false};
};

extern "C" lw_status lw_audio_render_start(const char *endpoint_id, uint32_t sample_rate,
                                           lw_audio_render_callback callback, void *context,
                                           lw_audio_render **out) {
    if (!callback || !out) return lw::fail(LW_E_INVALID_ARG, "lw_audio_render_start: NULL argument");
    if (sample_rate < 8000 || sample_rate > 192000)
        return lw::fail(LW_E_INVALID_ARG, "lw_audio_render_start: sample rate %u", sample_rate);
    *out = nullptr;
    std::string id = endpoint_id ? endpoint_id : "";
    auto render = std::make_unique<lw_audio_render>();

    std::atomic<int> ready{0}; // 0 pending, 1 ok, -1 failed
    lw_status start_status = LW_OK;
    std::string start_error;
    HANDLE started = CreateEventW(nullptr, TRUE, FALSE, nullptr);

    auto *raw = render.get();
    render->thread = std::thread([=, &ready, &start_status, &start_error]() {
        ComScope com;
        winrt::com_ptr<IAudioClient> client;
        winrt::com_ptr<IAudioRenderClient> renderer;
        UINT32 buffer_frames = 0;
        lw_status status = lw::guarded("WASAPI render", [&]() -> lw_status {
            auto device = find_endpoint(id.c_str());
            winrt::check_hresult(device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, client.put_void()));
            // Our own format, mono float32 at the source's rate: AUTOCONVERTPCM
            // has the engine convert channels, rate and sample type to the
            // endpoint's mix format, so nothing here resamples.
            WAVEFORMATEXTENSIBLE format{};
            format.Format.wFormatTag = WAVE_FORMAT_EXTENSIBLE;
            format.Format.nChannels = 1;
            format.Format.nSamplesPerSec = sample_rate;
            format.Format.wBitsPerSample = 32;
            format.Format.nBlockAlign = 4;
            format.Format.nAvgBytesPerSec = sample_rate * 4;
            format.Format.cbSize = sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX);
            format.Samples.wValidBitsPerSample = 32;
            format.dwChannelMask = SPEAKER_FRONT_CENTER;
            format.SubFormat = KSDATAFORMAT_SUBTYPE_IEEE_FLOAT;
            // 100 ms of engine buffer; we keep only ~20 ms of it filled.
            winrt::check_hresult(client->Initialize(
                AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY,
                1'000'000, 0, &format.Format, nullptr));
            winrt::check_hresult(client->GetService(IID_PPV_ARGS(renderer.put())));
            winrt::check_hresult(client->GetBufferSize(&buffer_frames));
            return LW_OK;
        });
        if (status != LW_OK) {
            start_status = status;
            start_error = lw_last_error();
            ready.store(-1);
            SetEvent(started);
            return;
        }
        const UINT32 target = std::min<UINT32>(buffer_frames, sample_rate / 50); // 20 ms
        auto fill = [&]() -> bool {
            UINT32 padding = 0;
            if (FAILED(client->GetCurrentPadding(&padding))) return false; // device invalidated
            if (padding >= target) return true;
            const UINT32 frames = target - padding;
            BYTE *data = nullptr;
            if (FAILED(renderer->GetBuffer(frames, &data))) return false;
            callback(context, reinterpret_cast<float *>(data), frames);
            renderer->ReleaseBuffer(frames, 0);
            return true;
        };
        fill(); // prime with what the source has (silence while it primes)
        if (FAILED(client->Start())) {
            start_status = LW_E_OS;
            start_error = "WASAPI render: IAudioClient::Start failed";
            ready.store(-1);
            SetEvent(started);
            return;
        }
        ready.store(1);
        SetEvent(started);

        HANDLE mmcss = lw::join_mmcss(L"Pro Audio");
        while (!raw->quit.load(std::memory_order_relaxed)) {
            if (!fill()) break;
            Sleep(2);
        }
        lw::leave_mmcss(mmcss);
        client->Stop();
    });

    WaitForSingleObject(started, INFINITE);
    CloseHandle(started);
    if (ready.load() != 1) {
        render->thread.join();
        return lw::fail(start_status, "%s", start_error.c_str());
    }
    *out = render.release();
    return LW_OK;
}

extern "C" void lw_audio_render_stop(lw_audio_render *render) {
    if (!render) return;
    render->quit.store(true);
    if (render->thread.joinable()) render->thread.join();
    delete render;
}

// ---- Spike: test tones ---------------------------------------------------------

extern "C" lw_status lw_audio_play_test_tones(const char *endpoint_id, uint32_t milliseconds, float amplitude) {
    return lw::guarded("lw_audio_play_test_tones", [&]() -> lw_status {
        ComScope com;
        auto device = find_endpoint(endpoint_id);
        winrt::com_ptr<IAudioClient> client;
        winrt::check_hresult(device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, client.put_void()));
        CoFormat mix;
        winrt::check_hresult(client->GetMixFormat(&mix.format));
        const auto format = describe(mix.format);
        if (!format.is_float || format.bits_per_sample != 32)
            return lw::fail(LW_E_UNSUPPORTED, "test tones need a float32 mix format (got %u-bit %s)",
                            format.bits_per_sample, format.is_float ? "float" : "int");
        winrt::check_hresult(client->Initialize(AUDCLNT_SHAREMODE_SHARED, 0, 1'000'000, 0, mix.format, nullptr));
        winrt::com_ptr<IAudioRenderClient> render;
        winrt::check_hresult(client->GetService(IID_PPV_ARGS(render.put())));
        UINT32 buffer_frames = 0;
        winrt::check_hresult(client->GetBufferSize(&buffer_frames));

        const uint64_t total = static_cast<uint64_t>(format.sample_rate) * milliseconds / 1000;
        uint64_t written = 0;
        const double two_pi = 6.283185307179586;
        auto fill = [&](UINT32 frames) {
            BYTE *data = nullptr;
            if (FAILED(render->GetBuffer(frames, &data))) return false;
            auto *samples = reinterpret_cast<float *>(data);
            for (UINT32 f = 0; f < frames; ++f) {
                const double t = static_cast<double>(written + f) / format.sample_rate;
                for (uint32_t c = 0; c < format.channels; ++c) {
                    const double hz = 250.0 * (c + 1);
                    samples[f * format.channels + c] =
                        written + f < total ? static_cast<float>(amplitude * std::sin(two_pi * hz * t)) : 0.0f;
                }
            }
            render->ReleaseBuffer(frames, 0);
            written += frames;
            return true;
        };
        fill(buffer_frames);
        winrt::check_hresult(client->Start());
        while (written < total + buffer_frames) {
            Sleep(10);
            UINT32 padding = 0;
            if (FAILED(client->GetCurrentPadding(&padding))) break;
            if (buffer_frames > padding && !fill(buffer_frames - padding)) break;
        }
        client->Stop();
        return LW_OK;
    });
}
