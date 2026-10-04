// NVENC encoder on the shared D3D11 device.
//
// NVENC is reached through nvEncodeAPI64.dll, which ships with every NVIDIA
// display driver: nothing is linked or redistributed. The header
// (third_party/nvenc/nvEncodeAPI.h, MIT, from FFmpeg's nv-codec-headers
// n13.0.19.0) fixes the API version, which sets a minimum driver (R570).
//
// Input is the BGRA capture texture itself, registered once per ring slot and
// mapped per picture: NVENC converts to YUV on the GPU, so no pixel reaches
// the CPU and no separate colour-conversion pass is needed.
#include "common.hpp"

#include "nvEncodeAPI.h"

#include <algorithm>
#include <cstring>
#include <vector>

namespace {

struct Registration {
    winrt::com_ptr<ID3D11Texture2D> texture; // keeps the pointer from being reused
    NV_ENC_REGISTERED_PTR handle = nullptr;
    uint64_t last_use = 0;
};

const char *nvenc_status_name(NVENCSTATUS status) {
    switch (status) {
    case NV_ENC_SUCCESS: return "NV_ENC_SUCCESS";
    case NV_ENC_ERR_NO_ENCODE_DEVICE: return "NV_ENC_ERR_NO_ENCODE_DEVICE";
    case NV_ENC_ERR_UNSUPPORTED_DEVICE: return "NV_ENC_ERR_UNSUPPORTED_DEVICE";
    case NV_ENC_ERR_INVALID_ENCODERDEVICE: return "NV_ENC_ERR_INVALID_ENCODERDEVICE";
    case NV_ENC_ERR_INVALID_DEVICE: return "NV_ENC_ERR_INVALID_DEVICE";
    case NV_ENC_ERR_DEVICE_NOT_EXIST: return "NV_ENC_ERR_DEVICE_NOT_EXIST";
    case NV_ENC_ERR_INVALID_PTR: return "NV_ENC_ERR_INVALID_PTR";
    case NV_ENC_ERR_INVALID_EVENT: return "NV_ENC_ERR_INVALID_EVENT";
    case NV_ENC_ERR_INVALID_PARAM: return "NV_ENC_ERR_INVALID_PARAM";
    case NV_ENC_ERR_INVALID_CALL: return "NV_ENC_ERR_INVALID_CALL";
    case NV_ENC_ERR_OUT_OF_MEMORY: return "NV_ENC_ERR_OUT_OF_MEMORY";
    case NV_ENC_ERR_ENCODER_NOT_INITIALIZED: return "NV_ENC_ERR_ENCODER_NOT_INITIALIZED";
    case NV_ENC_ERR_UNSUPPORTED_PARAM: return "NV_ENC_ERR_UNSUPPORTED_PARAM";
    case NV_ENC_ERR_LOCK_BUSY: return "NV_ENC_ERR_LOCK_BUSY";
    case NV_ENC_ERR_NOT_ENOUGH_BUFFER: return "NV_ENC_ERR_NOT_ENOUGH_BUFFER";
    case NV_ENC_ERR_INVALID_VERSION: return "NV_ENC_ERR_INVALID_VERSION";
    case NV_ENC_ERR_MAP_FAILED: return "NV_ENC_ERR_MAP_FAILED";
    case NV_ENC_ERR_NEED_MORE_INPUT: return "NV_ENC_ERR_NEED_MORE_INPUT";
    case NV_ENC_ERR_ENCODER_BUSY: return "NV_ENC_ERR_ENCODER_BUSY";
    case NV_ENC_ERR_GENERIC: return "NV_ENC_ERR_GENERIC";
    case NV_ENC_ERR_INCOMPATIBLE_CLIENT_KEY: return "NV_ENC_ERR_INCOMPATIBLE_CLIENT_KEY";
    case NV_ENC_ERR_UNIMPLEMENTED: return "NV_ENC_ERR_UNIMPLEMENTED";
    case NV_ENC_ERR_RESOURCE_REGISTER_FAILED: return "NV_ENC_ERR_RESOURCE_REGISTER_FAILED";
    case NV_ENC_ERR_RESOURCE_NOT_REGISTERED: return "NV_ENC_ERR_RESOURCE_NOT_REGISTERED";
    case NV_ENC_ERR_RESOURCE_NOT_MAPPED: return "NV_ENC_ERR_RESOURCE_NOT_MAPPED";
    default: return "NV_ENC_ERR_?";
    }
}

} // namespace

struct lw_encoder {
    HMODULE module = nullptr;
    NV_ENCODE_API_FUNCTION_LIST api{};
    void *session = nullptr;
    winrt::com_ptr<ID3D11Device> device;
    lw_encoder_params params{};
    NV_ENC_INITIALIZE_PARAMS init{};
    NV_ENC_CONFIG config{};
    GUID codec_guid{};
    NV_ENC_OUTPUT_PTR bitstream = nullptr;
    std::vector<Registration> registrations;
    uint64_t use_counter = 0;
    std::vector<uint8_t> output;
    lw_encoder_info info{};
    HANDLE completion = nullptr; // async mode only

    // Records an NVENC failure with the driver's own explanation.
    lw_status nv_fail(NVENCSTATUS status, const char *what) {
        const char *detail = (session && api.nvEncGetLastErrorString) ? api.nvEncGetLastErrorString(session) : "";
        return lw::fail(LW_E_ENCODER, "%s failed: %s (%d)%s%s", what, nvenc_status_name(status),
                        static_cast<int>(status), (detail && *detail) ? " - " : "", detail ? detail : "");
    }

    int32_t cap(NV_ENC_CAPS which) {
        NV_ENC_CAPS_PARAM query{};
        query.version = NV_ENC_CAPS_PARAM_VER;
        query.capsToQuery = which;
        int value = 0;
        if (api.nvEncGetEncodeCaps(session, codec_guid, &query, &value) != NV_ENC_SUCCESS) return 0;
        return value;
    }

    ~lw_encoder() {
        if (session) {
            for (auto &r : registrations) api.nvEncUnregisterResource(session, r.handle);
            if (bitstream) api.nvEncDestroyBitstreamBuffer(session, bitstream);
            if (completion) {
                NV_ENC_EVENT_PARAMS event{};
                event.version = NV_ENC_EVENT_PARAMS_VER;
                event.completionEvent = completion;
                api.nvEncUnregisterAsyncEvent(session, &event);
            }
            api.nvEncDestroyEncoder(session);
        }
        if (completion) CloseHandle(completion);
        if (module) FreeLibrary(module);
    }

    lw_status open(lw_device *dev, const lw_encoder_params &p);
    lw_status registration_for(ID3D11Texture2D *texture, NV_ENC_REGISTERED_PTR &out);
};

lw_status lw_encoder::open(lw_device *dev, const lw_encoder_params &p) {
    params = p;
    device = dev->device;

    // LOAD_LIBRARY_SEARCH_SYSTEM32: never pick up a planted DLL from the
    // working directory.
    module = LoadLibraryExW(L"nvEncodeAPI64.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (!module) return lw::fail(LW_E_UNSUPPORTED, "nvEncodeAPI64.dll not found (no NVIDIA driver?)");
    using GetMaxVersion = NVENCSTATUS(NVENCAPI *)(uint32_t *);
    using CreateInstance = NVENCSTATUS(NVENCAPI *)(NV_ENCODE_API_FUNCTION_LIST *);
    auto get_max_version = reinterpret_cast<GetMaxVersion>(GetProcAddress(module, "NvEncodeAPIGetMaxSupportedVersion"));
    auto create_instance = reinterpret_cast<CreateInstance>(GetProcAddress(module, "NvEncodeAPICreateInstance"));
    if (!get_max_version || !create_instance) return lw::fail(LW_E_UNSUPPORTED, "nvEncodeAPI64.dll lacks the expected exports");

    uint32_t driver_version = 0;
    get_max_version(&driver_version);
    info.header_api_major = NVENCAPI_MAJOR_VERSION;
    info.header_api_minor = NVENCAPI_MINOR_VERSION;
    info.driver_api_major = driver_version >> 4;
    info.driver_api_minor = driver_version & 0xF;
    if (driver_version < ((NVENCAPI_MAJOR_VERSION << 4) | NVENCAPI_MINOR_VERSION))
        return lw::fail(LW_E_UNSUPPORTED, "NVIDIA driver supports NVENC API %u.%u; this build needs %u.%u (driver R570 or newer)",
                        info.driver_api_major, info.driver_api_minor, info.header_api_major, info.header_api_minor);

    api.version = NV_ENCODE_API_FUNCTION_LIST_VER;
    NVENCSTATUS status = create_instance(&api);
    if (status != NV_ENC_SUCCESS) return nv_fail(status, "NvEncodeAPICreateInstance");

    NV_ENC_OPEN_ENCODE_SESSION_EX_PARAMS open_params{};
    open_params.version = NV_ENC_OPEN_ENCODE_SESSION_EX_PARAMS_VER;
    open_params.device = device.get();
    open_params.deviceType = NV_ENC_DEVICE_TYPE_DIRECTX;
    open_params.apiVersion = NVENCAPI_VERSION;
    status = api.nvEncOpenEncodeSessionEx(&open_params, &session);
    if (status != NV_ENC_SUCCESS) {
        session = nullptr;
        return nv_fail(status, "nvEncOpenEncodeSessionEx");
    }

    codec_guid = p.codec == LW_CODEC_H264 ? NV_ENC_CODEC_H264_GUID : NV_ENC_CODEC_HEVC_GUID;
    static const GUID presets[] = {NV_ENC_PRESET_P1_GUID, NV_ENC_PRESET_P2_GUID, NV_ENC_PRESET_P3_GUID,
                                   NV_ENC_PRESET_P4_GUID, NV_ENC_PRESET_P5_GUID, NV_ENC_PRESET_P6_GUID,
                                   NV_ENC_PRESET_P7_GUID};
    const uint32_t preset_index = (p.preset >= 1 && p.preset <= 7) ? p.preset - 1 : 0;
    const GUID preset_guid = presets[preset_index];

    lw::copy_string(info.name, sizeof info.name,
                    std::string("NVENC ") + (p.codec == LW_CODEC_H264 ? "H.264" : "HEVC") + " P" +
                        std::to_string(preset_index + 1) + " ultra-low-latency");
    info.supports_ref_invalidation = cap(NV_ENC_CAPS_SUPPORT_REF_PIC_INVALIDATION);
    info.supports_intra_refresh = cap(NV_ENC_CAPS_SUPPORT_INTRA_REFRESH);
    info.supports_ltr = cap(NV_ENC_CAPS_NUM_MAX_LTR_FRAMES);
    info.max_width = cap(NV_ENC_CAPS_WIDTH_MAX);
    info.max_height = cap(NV_ENC_CAPS_HEIGHT_MAX);

    NV_ENC_PRESET_CONFIG preset{};
    preset.version = NV_ENC_PRESET_CONFIG_VER;
    preset.presetCfg.version = NV_ENC_CONFIG_VER;
    status = api.nvEncGetEncodePresetConfigEx(session, codec_guid, preset_guid,
                                              NV_ENC_TUNING_INFO_ULTRA_LOW_LATENCY, &preset);
    if (status != NV_ENC_SUCCESS) return nv_fail(status, "nvEncGetEncodePresetConfigEx");

    config = preset.presetCfg;
    config.version = NV_ENC_CONFIG_VER;
    // Interactive streaming: every frame is a P frame predicting only from the
    // past (no B frames, no reordering delay), and the encoder never inserts a
    // key frame on its own - the host asks for one (or invalidates references)
    // when a client reports loss.
    config.gopLength = NVENC_INFINITE_GOPLENGTH;
    config.frameIntervalP = 1;

    const uint32_t fps = p.fps ? p.fps : 60;
    const uint32_t vbv_frames = p.vbv_frames ? p.vbv_frames : 1;
    auto &rc = config.rcParams;
    rc.rateControlMode = NV_ENC_PARAMS_RC_CBR;
    rc.averageBitRate = p.bitrate_bps;
    rc.maxBitRate = p.bitrate_bps;
    // A one-frame VBV: no frame may be much larger than its share of the
    // bitrate, so a frame never takes more than ~one frame time to send.
    rc.vbvBufferSize = static_cast<uint32_t>(static_cast<uint64_t>(p.bitrate_bps) * vbv_frames / fps);
    rc.vbvInitialDelay = rc.vbvBufferSize;
    rc.multiPass = NV_ENC_MULTI_PASS_DISABLED;

    if (p.codec == LW_CODEC_H264) {
        auto &h264 = config.encodeCodecConfig.h264Config;
        h264.idrPeriod = NVENC_INFINITE_GOPLENGTH;
        h264.repeatSPSPPS = 1;
        h264.chromaFormatIDC = 1;
        if (p.intra_refresh_period && info.supports_intra_refresh) {
            h264.enableIntraRefresh = 1;
            h264.intraRefreshPeriod = p.intra_refresh_period;
            h264.intraRefreshCnt = std::max(1u, p.intra_refresh_period / 2);
        }
        if (p.slices > 1) {
            h264.sliceMode = 3;
            h264.sliceModeData = p.slices;
        }
    } else {
        auto &hevc = config.encodeCodecConfig.hevcConfig;
        config.profileGUID = NV_ENC_HEVC_PROFILE_MAIN_GUID;
        hevc.idrPeriod = NVENC_INFINITE_GOPLENGTH;
        hevc.repeatSPSPPS = 1; // VPS/SPS/PPS before every IDR: a client can join at any key frame
        hevc.chromaFormatIDC = 1;
        if (p.intra_refresh_period && info.supports_intra_refresh) {
            hevc.enableIntraRefresh = 1;
            hevc.intraRefreshPeriod = p.intra_refresh_period;
            hevc.intraRefreshCnt = std::max(1u, p.intra_refresh_period / 2);
        }
        if (p.slices > 1) {
            hevc.sliceMode = 3;
            hevc.sliceModeData = p.slices;
        }
    }

    init.version = NV_ENC_INITIALIZE_PARAMS_VER;
    init.encodeGUID = codec_guid;
    init.presetGUID = preset_guid;
    init.tuningInfo = NV_ENC_TUNING_INFO_ULTRA_LOW_LATENCY;
    init.encodeWidth = static_cast<uint32_t>(p.width);
    init.encodeHeight = static_cast<uint32_t>(p.height);
    init.darWidth = static_cast<uint32_t>(p.width);
    init.darHeight = static_cast<uint32_t>(p.height);
    init.maxEncodeWidth = static_cast<uint32_t>(p.width);
    init.maxEncodeHeight = static_cast<uint32_t>(p.height);
    init.frameRateNum = fps;
    init.frameRateDen = 1;
    init.enablePTD = 1;
    // Either way lw_encoder_encode returns the finished picture; async only
    // changes how this thread waits for the hardware.
    const bool use_async = p.async_mode && cap(NV_ENC_CAPS_ASYNC_ENCODE_SUPPORT);
    init.enableEncodeAsync = use_async ? 1 : 0;
    init.encodeConfig = &config;
    status = api.nvEncInitializeEncoder(session, &init);
    if (status != NV_ENC_SUCCESS) return nv_fail(status, "nvEncInitializeEncoder");

    NV_ENC_CREATE_BITSTREAM_BUFFER create_bitstream{};
    create_bitstream.version = NV_ENC_CREATE_BITSTREAM_BUFFER_VER;
    status = api.nvEncCreateBitstreamBuffer(session, &create_bitstream);
    if (status != NV_ENC_SUCCESS) return nv_fail(status, "nvEncCreateBitstreamBuffer");
    bitstream = create_bitstream.bitstreamBuffer;

    if (use_async) {
        completion = CreateEventW(nullptr, FALSE, FALSE, nullptr);
        NV_ENC_EVENT_PARAMS event{};
        event.version = NV_ENC_EVENT_PARAMS_VER;
        event.completionEvent = completion;
        status = api.nvEncRegisterAsyncEvent(session, &event);
        if (status != NV_ENC_SUCCESS) return nv_fail(status, "nvEncRegisterAsyncEvent");
    }
    lw::copy_string(info.name + strlen(info.name), sizeof info.name - strlen(info.name), use_async ? ", async" : ", sync");
    return LW_OK;
}

lw_status lw_encoder::registration_for(ID3D11Texture2D *texture, NV_ENC_REGISTERED_PTR &out) {
    ++use_counter;
    for (auto &r : registrations) {
        if (r.texture.get() == texture) {
            r.last_use = use_counter;
            out = r.handle;
            return LW_OK;
        }
    }
    D3D11_TEXTURE2D_DESC desc{};
    texture->GetDesc(&desc);
    if (static_cast<int32_t>(desc.Width) != params.width || static_cast<int32_t>(desc.Height) != params.height)
        return lw::fail(LW_E_INVALID_ARG, "texture is %ux%u but the encoder is %dx%d", desc.Width, desc.Height,
                        params.width, params.height);
    if (desc.Format != DXGI_FORMAT_B8G8R8A8_UNORM)
        return lw::fail(LW_E_INVALID_ARG, "texture format %d is not BGRA8", static_cast<int>(desc.Format));

    // Bounded cache: capture rings are small, but a resize leaves stale slots.
    if (registrations.size() >= 16) {
        auto oldest = std::min_element(registrations.begin(), registrations.end(),
                                       [](const Registration &a, const Registration &b) { return a.last_use < b.last_use; });
        api.nvEncUnregisterResource(session, oldest->handle);
        registrations.erase(oldest);
    }

    NV_ENC_REGISTER_RESOURCE reg{};
    reg.version = NV_ENC_REGISTER_RESOURCE_VER;
    reg.resourceType = NV_ENC_INPUT_RESOURCE_TYPE_DIRECTX;
    reg.resourceToRegister = texture;
    reg.width = desc.Width;
    reg.height = desc.Height;
    reg.bufferFormat = NV_ENC_BUFFER_FORMAT_ARGB; // NVENC's "ARGB" is BGRA in memory
    reg.bufferUsage = NV_ENC_INPUT_IMAGE;
    NVENCSTATUS status = api.nvEncRegisterResource(session, &reg);
    if (status != NV_ENC_SUCCESS) return nv_fail(status, "nvEncRegisterResource");

    Registration entry;
    entry.texture.copy_from(texture);
    entry.handle = reg.registeredResource;
    entry.last_use = use_counter;
    registrations.push_back(entry);
    out = entry.handle;
    return LW_OK;
}

extern "C" lw_status lw_encoder_create(lw_device *device, const lw_encoder_params *params, lw_encoder **out) {
    if (!device || !params || !out) return lw::fail(LW_E_INVALID_ARG, "lw_encoder_create: NULL argument");
    *out = nullptr;
    if (params->width <= 0 || params->height <= 0 || (params->width & 1) || (params->height & 1))
        return lw::fail(LW_E_INVALID_ARG, "encoder size %dx%d must be positive and even", params->width, params->height);
    if (params->bitrate_bps == 0) return lw::fail(LW_E_INVALID_ARG, "bitrate is zero");
    if (params->codec != LW_CODEC_HEVC && params->codec != LW_CODEC_H264)
        return lw::fail(LW_E_INVALID_ARG, "unknown codec %u", params->codec);
    return lw::guarded("lw_encoder_create", [&]() -> lw_status {
        auto encoder = std::make_unique<lw_encoder>();
        lw_status status = encoder->open(device, *params);
        if (status != LW_OK) return status;
        *out = encoder.release();
        return LW_OK;
    });
}

extern "C" void lw_encoder_get_info(const lw_encoder *encoder, lw_encoder_info *out) {
    if (encoder && out) *out = encoder->info;
}

extern "C" lw_status lw_encoder_encode(lw_encoder *encoder, void *texture, uint64_t timestamp, uint32_t flags,
                                       lw_packet *out) {
    if (!encoder || !texture || !out) return lw::fail(LW_E_INVALID_ARG, "lw_encoder_encode: NULL argument");
    return lw::guarded("lw_encoder_encode", [&]() -> lw_status {
        auto &api = encoder->api;
        NV_ENC_REGISTERED_PTR registered = nullptr;
        lw_status result = encoder->registration_for(static_cast<ID3D11Texture2D *>(texture), registered);
        if (result != LW_OK) return result;

        NV_ENC_MAP_INPUT_RESOURCE map{};
        map.version = NV_ENC_MAP_INPUT_RESOURCE_VER;
        map.registeredResource = registered;
        NVENCSTATUS status = api.nvEncMapInputResource(encoder->session, &map);
        if (status != NV_ENC_SUCCESS) return encoder->nv_fail(status, "nvEncMapInputResource");

        NV_ENC_PIC_PARAMS pic{};
        pic.version = NV_ENC_PIC_PARAMS_VER;
        pic.inputWidth = static_cast<uint32_t>(encoder->params.width);
        pic.inputHeight = static_cast<uint32_t>(encoder->params.height);
        pic.inputBuffer = map.mappedResource;
        pic.bufferFmt = map.mappedBufferFmt;
        pic.outputBitstream = encoder->bitstream;
        pic.pictureStruct = NV_ENC_PIC_STRUCT_FRAME;
        pic.inputTimeStamp = timestamp;
        if (flags & LW_ENCODE_FORCE_IDR) pic.encodePicFlags = NV_ENC_PIC_FLAG_FORCEIDR | NV_ENC_PIC_FLAG_OUTPUT_SPSPPS;
        pic.completionEvent = encoder->completion;

        const int64_t submit = lw::qpc_now();
        status = api.nvEncEncodePicture(encoder->session, &pic);
        if (status != NV_ENC_SUCCESS) {
            api.nvEncUnmapInputResource(encoder->session, map.mappedResource);
            return encoder->nv_fail(status, "nvEncEncodePicture");
        }

        if (encoder->completion && WaitForSingleObject(encoder->completion, 1000) != WAIT_OBJECT_0) {
            api.nvEncUnmapInputResource(encoder->session, map.mappedResource);
            return lw::fail(LW_E_ENCODER, "NVENC completion event timed out");
        }
        NV_ENC_LOCK_BITSTREAM lock{};
        lock.version = NV_ENC_LOCK_BITSTREAM_VER;
        lock.outputBitstream = encoder->bitstream;
        status = api.nvEncLockBitstream(encoder->session, &lock); // sync mode: waits for the hardware
        const int64_t done = lw::qpc_now();
        if (status != NV_ENC_SUCCESS) {
            api.nvEncUnmapInputResource(encoder->session, map.mappedResource);
            return encoder->nv_fail(status, "nvEncLockBitstream");
        }
        auto *bytes = static_cast<const uint8_t *>(lock.bitstreamBufferPtr);
        encoder->output.assign(bytes, bytes + lock.bitstreamSizeInBytes);
        const NV_ENC_PIC_TYPE type = lock.pictureType;
        const uint32_t qp = lock.frameAvgQP;
        api.nvEncUnlockBitstream(encoder->session, encoder->bitstream);
        api.nvEncUnmapInputResource(encoder->session, map.mappedResource);

        out->data = encoder->output.data();
        out->size = static_cast<uint32_t>(encoder->output.size());
        out->is_idr = type == NV_ENC_PIC_TYPE_IDR ? 1 : 0;
        out->picture_type = static_cast<uint32_t>(type);
        out->average_qp = qp;
        out->timestamp = timestamp;
        out->submit_qpc = submit;
        out->done_qpc = done;
        return LW_OK;
    });
}

extern "C" lw_status lw_encoder_invalidate(lw_encoder *encoder, const uint64_t *timestamps, uint32_t count) {
    if (!encoder || (count && !timestamps)) return lw::fail(LW_E_INVALID_ARG, "lw_encoder_invalidate: NULL argument");
    for (uint32_t i = 0; i < count; ++i) {
        NVENCSTATUS status = encoder->api.nvEncInvalidateRefFrames(encoder->session, timestamps[i]);
        if (status != NV_ENC_SUCCESS) return encoder->nv_fail(status, "nvEncInvalidateRefFrames");
    }
    return LW_OK;
}

extern "C" lw_status lw_encoder_set_bitrate(lw_encoder *encoder, uint32_t bitrate_bps) {
    if (!encoder || bitrate_bps == 0) return lw::fail(LW_E_INVALID_ARG, "lw_encoder_set_bitrate: bad argument");
    const uint32_t fps = encoder->params.fps ? encoder->params.fps : 60;
    const uint32_t vbv_frames = encoder->params.vbv_frames ? encoder->params.vbv_frames : 1;
    auto &rc = encoder->config.rcParams;
    rc.averageBitRate = bitrate_bps;
    rc.maxBitRate = bitrate_bps;
    rc.vbvBufferSize = static_cast<uint32_t>(static_cast<uint64_t>(bitrate_bps) * vbv_frames / fps);
    rc.vbvInitialDelay = rc.vbvBufferSize;
    NV_ENC_RECONFIGURE_PARAMS reconfigure{};
    reconfigure.version = NV_ENC_RECONFIGURE_PARAMS_VER;
    reconfigure.reInitEncodeParams = encoder->init;
    reconfigure.reInitEncodeParams.encodeConfig = &encoder->config;
    NVENCSTATUS status = encoder->api.nvEncReconfigureEncoder(encoder->session, &reconfigure);
    if (status != NV_ENC_SUCCESS) return encoder->nv_fail(status, "nvEncReconfigureEncoder");
    encoder->params.bitrate_bps = bitrate_bps;
    return LW_OK;
}

extern "C" void lw_encoder_release(lw_encoder *encoder) { delete encoder; }
