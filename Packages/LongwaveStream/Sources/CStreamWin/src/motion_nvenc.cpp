// Motion between two pictures from NVENC's motion-estimation-only mode.
//
// The encoder engine does the search, not the 3D engine: on a GPU the game
// keeps busy, any pass of ours on the 3D engine queues behind the game's work
// (the host's render stage waits 23 ms at a 45 fps lock, 55 ms under frame
// generation, 2026-11-17), while NVENC is a separate unit. This is how Oculus
// ASW 1.0 got its motion. See docs/PCVR_MOTION_EXTRAPOLATION.md.
//
// HEVC, because H.264's motion estimation stops at 4096 wide and the stereo
// picture is 5072. HEVC hands back one record per coding unit, CTB by CTB in
// raster order and CUs in z-order inside each CTB (32x32), ended by
// `lastCUInCTB`; the CU sizes say where each lies. That is rebuilt here into a grid of 16x16 blocks.
#include "common.hpp"

#include "nvEncodeAPI.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <vector>

namespace {

constexpr int kCell = 8;   // the smallest CU, the grid the records are first placed on
constexpr int kBlock = 16; // the output grid's default

struct Registration {
    winrt::com_ptr<ID3D11Texture2D> texture;
    NV_ENC_REGISTERED_PTR handle = nullptr;
    uint64_t last_use = 0;
};

} // namespace

struct lw_motion {
    HMODULE module = nullptr;
    NV_ENCODE_API_FUNCTION_LIST api{};
    void *session = nullptr;
    winrt::com_ptr<ID3D11Device> device;
    int32_t width = 0, height = 0;
    NV_ENC_OUTPUT_PTR mv_buffer = nullptr;
    std::vector<Registration> registrations;
    uint64_t use_counter = 0;

    // Cell grid (8x8): quarter-pel vectors, and whether a cell got a P vector.
    int32_t cells_w = 0, cells_h = 0;
    std::vector<int16_t> cell_mv;
    std::vector<uint8_t> cell_ok;
    // Output grid (16x16).
    int32_t grid_w = 0, grid_h = 0, block = kBlock;
    std::vector<int16_t> vectors;
    std::vector<uint8_t> known;
    lw_motion_stats stats{};
    uint32_t dump_frame = 0;

    lw_status nv_fail(NVENCSTATUS status, const char *what) {
        const char *detail = (session && api.nvEncGetLastErrorString) ? api.nvEncGetLastErrorString(session) : "";
        return lw::fail(LW_E_ENCODER, "%s failed (%d)%s%s", what, static_cast<int>(status),
                        (detail && *detail) ? " - " : "", detail ? detail : "");
    }

    ~lw_motion() {
        if (session) {
            for (auto &r : registrations) api.nvEncUnregisterResource(session, r.handle);
            if (mv_buffer) api.nvEncDestroyMVBuffer(session, mv_buffer);
            api.nvEncDestroyEncoder(session);
        }
        if (module) FreeLibrary(module);
    }

    lw_status open(lw_device *dev, const lw_motion_params &p);
    lw_status registration_for(ID3D11Texture2D *texture, NV_ENC_REGISTERED_PTR &out);
    lw_status estimate(ID3D11Texture2D *current, ID3D11Texture2D *reference);
    void place(const NV_ENC_HEVC_MV_DATA *records, size_t count);
    void reduce();
};

lw_status lw_motion::open(lw_device *dev, const lw_motion_params &p) {
    device = dev->device;
    width = p.width;
    height = p.height;
    module = LoadLibraryExW(L"nvEncodeAPI64.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (!module) return lw::fail(LW_E_UNSUPPORTED, "nvEncodeAPI64.dll not found (no NVIDIA driver?)");
    using CreateInstance = NVENCSTATUS(NVENCAPI *)(NV_ENCODE_API_FUNCTION_LIST *);
    auto create_instance = reinterpret_cast<CreateInstance>(GetProcAddress(module, "NvEncodeAPICreateInstance"));
    if (!create_instance) return lw::fail(LW_E_UNSUPPORTED, "nvEncodeAPI64.dll lacks NvEncodeAPICreateInstance");
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
        return nv_fail(status, "nvEncOpenEncodeSessionEx (motion)");
    }

    NV_ENC_CAPS_PARAM query{};
    query.version = NV_ENC_CAPS_PARAM_VER;
    query.capsToQuery = NV_ENC_CAPS_SUPPORT_MEONLY_MODE;
    int supported = 0;
    api.nvEncGetEncodeCaps(session, NV_ENC_CODEC_HEVC_GUID, &query, &supported);
    if (!supported) return lw::fail(LW_E_UNSUPPORTED, "this GPU's NVENC has no HEVC motion-estimation-only mode");

    const GUID presets[] = {NV_ENC_PRESET_P1_GUID, NV_ENC_PRESET_P2_GUID, NV_ENC_PRESET_P3_GUID, NV_ENC_PRESET_P4_GUID,
                            NV_ENC_PRESET_P5_GUID, NV_ENC_PRESET_P6_GUID, NV_ENC_PRESET_P7_GUID};
    const GUID preset_guid = presets[(p.preset >= 1 && p.preset <= 7) ? p.preset - 1 : 3];
    NV_ENC_PRESET_CONFIG preset{};
    preset.version = NV_ENC_PRESET_CONFIG_VER;
    preset.presetCfg.version = NV_ENC_CONFIG_VER;
    status = api.nvEncGetEncodePresetConfigEx(session, NV_ENC_CODEC_HEVC_GUID, preset_guid,
                                              NV_ENC_TUNING_INFO_ULTRA_LOW_LATENCY, &preset);
    if (status != NV_ENC_SUCCESS) return nv_fail(status, "nvEncGetEncodePresetConfigEx (motion)");
    NV_ENC_CONFIG config = preset.presetCfg;
    config.version = NV_ENC_CONFIG_VER;
    config.gopLength = NVENC_INFINITE_GOPLENGTH;
    config.frameIntervalP = 1;
    std::memset(&config.encodeCodecConfig, 0, sizeof config.encodeCodecConfig);
    // Rate control means nothing without a bitstream, and the driver refuses the preset's
    // passes and look-ahead in this mode.
    config.rcParams.multiPass = NV_ENC_MULTI_PASS_DISABLED;
    config.rcParams.enableLookahead = 0;
    config.rcParams.enableAQ = 0;
    config.rcParams.enableTemporalAQ = 0;

    NV_ENC_INITIALIZE_PARAMS init{};
    init.version = NV_ENC_INITIALIZE_PARAMS_VER;
    init.encodeGUID = NV_ENC_CODEC_HEVC_GUID;
    init.presetGUID = preset_guid;
    // No tuning: the driver refuses one in HEVC motion-estimation-only mode.
    init.encodeWidth = init.darWidth = init.maxEncodeWidth = static_cast<uint32_t>(width);
    init.encodeHeight = init.darHeight = init.maxEncodeHeight = static_cast<uint32_t>(height);
    init.frameRateNum = 90;
    init.frameRateDen = 1;
    init.enablePTD = 1;
    init.enableMEOnlyMode = 1;
    init.enableEncodeAsync = 0;
    init.encodeConfig = &config;
    status = api.nvEncInitializeEncoder(session, &init);
    if (status != NV_ENC_SUCCESS) return nv_fail(status, "nvEncInitializeEncoder (motion-estimation only)");

    NV_ENC_CREATE_MV_BUFFER create{};
    create.version = NV_ENC_CREATE_MV_BUFFER_VER;
    status = api.nvEncCreateMVBuffer(session, &create);
    if (status != NV_ENC_SUCCESS) return nv_fail(status, "nvEncCreateMVBuffer");
    mv_buffer = create.mvBuffer;

    cells_w = (width + kCell - 1) / kCell;
    cells_h = (height + kCell - 1) / kCell;
    cell_mv.assign(static_cast<size_t>(cells_w) * cells_h * 2, 0);
    cell_ok.assign(static_cast<size_t>(cells_w) * cells_h, 0);
    block = p.block == 0 ? kBlock : static_cast<int32_t>(p.block);
    grid_w = (width + block - 1) / block;
    grid_h = (height + block - 1) / block;
    vectors.assign(static_cast<size_t>(grid_w) * grid_h * 2, 0);
    known.assign(static_cast<size_t>(grid_w) * grid_h, 0);
    return LW_OK;
}

lw_status lw_motion::registration_for(ID3D11Texture2D *texture, NV_ENC_REGISTERED_PTR &out) {
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
    if (static_cast<int32_t>(desc.Width) != width || static_cast<int32_t>(desc.Height) != height)
        return lw::fail(LW_E_INVALID_ARG, "texture is %ux%u but motion estimation is %dx%d", desc.Width, desc.Height,
                        width, height);
    if (desc.Format != DXGI_FORMAT_B8G8R8A8_UNORM)
        return lw::fail(LW_E_INVALID_ARG, "texture format %d is not BGRA8", static_cast<int>(desc.Format));
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
    reg.bufferFormat = NV_ENC_BUFFER_FORMAT_ARGB; // BGRA in memory
    reg.bufferUsage = NV_ENC_INPUT_IMAGE;
    NVENCSTATUS status = api.nvEncRegisterResource(session, &reg);
    if (status != NV_ENC_SUCCESS) return nv_fail(status, "nvEncRegisterResource (motion)");
    Registration entry;
    entry.texture.copy_from(texture);
    entry.handle = reg.registeredResource;
    entry.last_use = use_counter;
    registrations.push_back(entry);
    out = entry.handle;
    return LW_OK;
}

// Lays the records onto the 8x8 cell grid. A CTB's CUs are its quadtree's
// leaves in z-order (measured on an RTX 3080, 2026-11-17).
void lw_motion::place(const NV_ENC_HEVC_MV_DATA *records, size_t count) {
    std::fill(cell_ok.begin(), cell_ok.end(), 0);
    // 32x32 CTBs (the largest CU this mode returns), over the picture padded to whole
    // CTBs: the edge CTBs are coded whole, not split at the picture's edge. The buffer is a
    // fixed size and holds stale records past the last CTB, so the CTB grid, not the
    // buffer's size, says how many records there are.
    const int ctb = 32;
    size_t markers = 0;
    uint8_t largest = 0;
    for (size_t i = 0; i < count; ++i) {
        markers += records[i].lastCUInCTB ? 1 : 0;
        largest = std::max(largest, records[i].cuSize);
    }
    stats.ctb_size = static_cast<uint32_t>(ctb);
    stats.ctb_markers = static_cast<uint32_t>(markers);
    stats.largest_cu = 8u << largest;
    size_t index = 0;
    uint32_t malformed = 0;
    const auto assign = [&](int x, int y, int size, const NV_ENC_HEVC_MV_DATA &cu) {
        if (cu.cuType != 1) return; // intra: no motion
        for (int cy = y; cy < y + size && cy < height; cy += kCell) {
            for (int cx = x; cx < x + size && cx < width; cx += kCell) {
                // Which prediction unit this cell is in.
                const bool right = cx - x >= size / 2, bottom = cy - y >= size / 2;
                int part = 0;
                switch (cu.partitionMode) {
                case 1: case 4: case 5: part = bottom ? 1 : 0; break;              // 2NxN and its asymmetric kin
                case 2: case 6: case 7: part = right ? 1 : 0; break;               // Nx2N and its asymmetric kin
                case 3: part = (bottom ? 2 : 0) + (right ? 1 : 0); break;          // NxN
                default: part = 0; break;
                }
                const size_t cell = static_cast<size_t>(cy / kCell) * cells_w + cx / kCell;
                cell_mv[cell * 2] = cu.mv[part].mvx;
                cell_mv[cell * 2 + 1] = cu.mv[part].mvy;
                cell_ok[cell] = 1;
            }
        }
    };
    const auto visit = [&](auto &self, int x, int y, int size) -> void {
        if (index >= count) return;
        // A leaf when the next CU is this block's size (never smaller than a cell).
        const int cu_size = kCell << std::min<int>(records[index].cuSize, 3);
        if (cu_size >= size || size == kCell) {
            assign(x, y, size, records[index]); // clamps to the picture
            ++index;
            return;
        }
        const int half = size / 2;
        self(self, x, y, half);
        self(self, x + half, y, half);
        self(self, x, y + half, half);
        self(self, x + half, y + half, half);
    };
    for (int ty = 0; ty < height && index < count; ty += ctb) {
        for (int tx = 0; tx < width && index < count; tx += ctb) {
            visit(visit, tx, ty, ctb);
            // Resynchronise on the CTB marker if the sizes and the layout disagreed.
            if (index > 0 && !records[index - 1].lastCUInCTB) {
                ++malformed;
                while (index < count && !records[index].lastCUInCTB) ++index;
                if (index < count) ++index;
            }
        }
    }
    stats.records = static_cast<uint32_t>(count);
    stats.records_used = static_cast<uint32_t>(index);
    stats.malformed_ctbs = malformed;
}

// Each output block: the mean of its inter cells; unknown with none.
void lw_motion::reduce() {
    uint32_t known_blocks = 0;
    double sum_abs = 0;
    for (int by = 0; by < grid_h; ++by) {
        for (int bx = 0; bx < grid_w; ++bx) {
            int sx = 0, sy = 0, n = 0;
            const int per = block / kCell;
            for (int cy = by * per; cy < by * per + per && cy < cells_h; ++cy) {
                for (int cx = bx * per; cx < bx * per + per && cx < cells_w; ++cx) {
                    const size_t cell = static_cast<size_t>(cy) * cells_w + cx;
                    if (!cell_ok[cell]) continue;
                    sx += cell_mv[cell * 2];
                    sy += cell_mv[cell * 2 + 1];
                    ++n;
                }
            }
            const size_t at = static_cast<size_t>(by) * grid_w + bx;
            known[at] = n > 0;
            int16_t vx = n ? static_cast<int16_t>(sx / n) : 0, vy = n ? static_cast<int16_t>(sy / n) : 0;
            // Under half a pixel is the search's noise on still content (it costs a blurred
            // resample and buys nothing): still.
            if (std::abs(vx) < 2 && std::abs(vy) < 2) vx = vy = 0;
            vectors[at * 2] = vx;
            vectors[at * 2 + 1] = vy;
            if (n) {
                ++known_blocks;
                sum_abs += std::hypot(vectors[at * 2] / 4.0, vectors[at * 2 + 1] / 4.0);
            }
        }
    }
    stats.known_blocks = known_blocks;
    stats.mean_pixels = known_blocks ? sum_abs / known_blocks : 0;
}

lw_status lw_motion::estimate(ID3D11Texture2D *current, ID3D11Texture2D *reference) {
    const auto started = std::chrono::steady_clock::now();
    NV_ENC_REGISTERED_PTR current_reg = nullptr, reference_reg = nullptr;
    lw_status result = registration_for(current, current_reg);
    if (result != LW_OK) return result;
    result = registration_for(reference, reference_reg);
    if (result != LW_OK) return result;

    NV_ENC_MAP_INPUT_RESOURCE map_current{}, map_reference{};
    map_current.version = map_reference.version = NV_ENC_MAP_INPUT_RESOURCE_VER;
    map_current.registeredResource = current_reg;
    map_reference.registeredResource = reference_reg;
    NVENCSTATUS status = api.nvEncMapInputResource(session, &map_current);
    if (status != NV_ENC_SUCCESS) return nv_fail(status, "nvEncMapInputResource (motion, current)");
    status = api.nvEncMapInputResource(session, &map_reference);
    if (status != NV_ENC_SUCCESS) {
        api.nvEncUnmapInputResource(session, map_current.mappedResource);
        return nv_fail(status, "nvEncMapInputResource (motion, reference)");
    }
    const auto unmap = [&] {
        api.nvEncUnmapInputResource(session, map_reference.mappedResource);
        api.nvEncUnmapInputResource(session, map_current.mappedResource);
    };

    NV_ENC_MEONLY_PARAMS me{};
    me.version = NV_ENC_MEONLY_PARAMS_VER;
    me.inputWidth = static_cast<uint32_t>(width);
    me.inputHeight = static_cast<uint32_t>(height);
    me.inputBuffer = map_current.mappedResource;
    me.referenceFrame = map_reference.mappedResource;
    me.mvBuffer = mv_buffer;
    me.bufferFmt = map_current.mappedBufferFmt;
    status = api.nvEncRunMotionEstimationOnly(session, &me);
    if (status != NV_ENC_SUCCESS) {
        unmap();
        return nv_fail(status, "nvEncRunMotionEstimationOnly");
    }
    const auto submitted = std::chrono::steady_clock::now();

    NV_ENC_LOCK_BITSTREAM lock{};
    lock.version = NV_ENC_LOCK_BITSTREAM_VER;
    lock.outputBitstream = mv_buffer;
    status = api.nvEncLockBitstream(session, &lock);
    if (status != NV_ENC_SUCCESS) {
        unmap();
        return nv_fail(status, "nvEncLockBitstream (motion)");
    }
    const auto done = std::chrono::steady_clock::now();
    const auto *records = static_cast<const NV_ENC_HEVC_MV_DATA *>(lock.bitstreamBufferPtr);
    const size_t record_count = lock.bitstreamSizeInBytes / sizeof(NV_ENC_HEVC_MV_DATA);
    // Diagnostics: LW_MOTION_DUMP=<file> writes one estimate's raw records (and the size) once.
    static bool dumped = false;
    char dump_path[MAX_PATH]{};
    if (!dumped && GetEnvironmentVariableA("LW_MOTION_DUMP", dump_path, sizeof dump_path) > 0 && ++dump_frame == 30) {
        dumped = true;
        if (FILE *f = std::fopen(dump_path, "wb")) {
            const uint32_t header[4] = {static_cast<uint32_t>(width), static_cast<uint32_t>(height),
                                        lock.bitstreamSizeInBytes, static_cast<uint32_t>(sizeof(NV_ENC_HEVC_MV_DATA))};
            std::fwrite(header, sizeof header, 1, f);
            std::fwrite(records, 1, lock.bitstreamSizeInBytes, f);
            std::fclose(f);
        }
    }
    place(records, record_count);
    api.nvEncUnlockBitstream(session, mv_buffer);
    unmap();
    reduce();
    const auto parsed = std::chrono::steady_clock::now();
    const auto ms = [](auto a, auto b) { return std::chrono::duration<double, std::milli>(b - a).count(); };
    stats.submit_ms = ms(started, submitted);
    stats.wait_ms = ms(submitted, done);
    stats.parse_ms = ms(done, parsed);
    return LW_OK;
}

extern "C" lw_status lw_motion_create(lw_device *device, const lw_motion_params *params, lw_motion **out) {
    if (!device || !params || !out) return lw::fail(LW_E_INVALID_ARG, "lw_motion_create: NULL argument");
    *out = nullptr;
    if (params->width <= 0 || params->height <= 0 || (params->width & 1) || (params->height & 1))
        return lw::fail(LW_E_INVALID_ARG, "motion size %dx%d must be positive and even", params->width, params->height);
    if (params->block != 0 && params->block != 8 && params->block != 16 && params->block != 32)
        return lw::fail(LW_E_INVALID_ARG, "motion block %u must be 8, 16 or 32", params->block);
    return lw::guarded("lw_motion_create", [&]() -> lw_status {
        auto motion = std::make_unique<lw_motion>();
        lw_status status = motion->open(device, *params);
        if (status != LW_OK) return status;
        *out = motion.release();
        return LW_OK;
    });
}

extern "C" lw_status lw_motion_estimate(lw_motion *motion, void *current, void *reference, lw_motion_field *out) {
    if (!motion || !current || !reference || !out) return lw::fail(LW_E_INVALID_ARG, "lw_motion_estimate: NULL argument");
    return lw::guarded("lw_motion_estimate", [&]() -> lw_status {
        lw_status status = motion->estimate(static_cast<ID3D11Texture2D *>(current), static_cast<ID3D11Texture2D *>(reference));
        if (status != LW_OK) return status;
        out->grid_width = motion->grid_w;
        out->grid_height = motion->grid_h;
        out->block = motion->block;
        out->vectors = motion->vectors.data();
        out->known = motion->known.data();
        out->stats = motion->stats;
        return LW_OK;
    });
}

extern "C" void lw_motion_release(lw_motion *motion) { delete motion; }
