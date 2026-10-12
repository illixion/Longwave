// SPIKE ONLY: synthetic producer and latency harness for the external frame
// source (lw_frame_source.h; NATIVE_V3_PROTOCOL.md open question 18). Lives in
// the shim because SwiftPM can't build a C++ executable against CStreamWin's
// module map; the frame-source-spike executable is one line of Swift calling
// lw_spike_frame_source_tool.
//
//   frame-source-spike produce   [--channel C] [--seconds S] [--fps F] [--width W] [--height H]
//                                [--slots N] [--aux] [--warp] [--crash-after N] [--wait S]
//   frame-source-spike consume   [--channel C] [--seconds S] [--fps F] [--mbps M] [--csv FILE]
//                                [--verify] [--stall-at N --stall-ms MS] [--no-encode]
//   frame-source-spike inprocess [--seconds S] [--fps F] [--width W] [--height H] [--mbps M] [--csv FILE]
//   frame-source-spike gpu-load  [--percent P] [--seconds S]
//
// produce renders a test pattern (panning noise, a moving bar, the frame
// number as blocks; with --aux an R32_FLOAT "depth" texture holding the frame
// number) into the ring at F Hz. It reattaches whenever the host goes away.
// --warp renders on the WARP software adapter (a different LUID: the host
// must refuse it); --crash-after exits abruptly mid-stream without detaching.
//
// consume is the host: frame source -> one-slot latest-wins mailbox ->
// NVENC (the Phase 2 spike's encode path), recording per frame
//   present (producer submit) -> taken -> fence reached -> encode start -> encoded.
// --verify reads every frame's pattern back and checks it against the slot's
// frame number, aux value and side data (proves the fence actually orders the
// handoff; adds readback stalls, so not for latency runs). --stall-at holds
// every delivered frame for MS milliseconds from frame N (a stalled encoder),
// to show the producer starving and recovering.
//
// inprocess is the baseline: the same pattern drawn on the host's own device
// into a same-format texture, a local fence waited on, the same mailbox and
// encoder - everything but the cross-process handoff.
#include "common.hpp"

#include <avrt.h>

#include <algorithm>
#include <atomic>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace {

// ---- Options and output -------------------------------------------------------

struct Options {
    std::map<std::string, std::string> values;
    std::vector<std::string> flags;
    Options(int argc, char **argv) {
        for (int i = 2; i < argc; ++i) {
            std::string a = argv[i];
            if (a.rfind("--", 0) != 0) continue;
            a = a.substr(2);
            if (a == "aux" || a == "warp" || a == "verify" || a == "no-encode") flags.push_back(a);
            else if (i + 1 < argc) values[a] = argv[++i];
        }
    }
    std::string str(const char *k, const char *d) const { auto f = values.find(k); return f == values.end() ? d : f->second; }
    double num(const char *k, double d) const { auto f = values.find(k); return f == values.end() ? d : atof(f->second.c_str()); }
    bool has(const char *k) const { return std::find(flags.begin(), flags.end(), k) != flags.end(); }
};

double ms(int64_t ticks) { return static_cast<double>(ticks) * 1000.0 / static_cast<double>(lw_qpc_frequency()); }

[[noreturn]] void die(const char *what, lw_status status) {
    printf("error: %s: %s [%d]\n", what, lw_last_error(), status);
    fflush(stdout);
    exit(1);
}

void describe(const char *name, std::vector<double> values) {
    if (values.empty()) {
        printf("  %-30s (none)\n", name);
        return;
    }
    std::sort(values.begin(), values.end());
    auto at = [&](double q) { return values[std::min(values.size() - 1, static_cast<size_t>(q * (values.size() - 1) + 0.5))]; };
    double sum = 0;
    for (double v : values) sum += v;
    printf("  %-30s n=%zu mean %.3f  p50 %.3f  p95 %.3f  p99 %.3f  max %.3f\n", name, values.size(), sum / values.size(),
           at(0.50), at(0.95), at(0.99), values.back());
}

void precise_sleep_until(int64_t qpc) {
    static thread_local HANDLE timer = CreateWaitableTimerExW(nullptr, nullptr, CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, TIMER_ALL_ACCESS);
    const int64_t now = lw_qpc_now();
    if (qpc <= now) return;
    LARGE_INTEGER due;
    due.QuadPart = -(qpc - now) * 10'000'000 / lw_qpc_frequency();
    SetWaitableTimer(timer, &due, 0, nullptr, nullptr, FALSE);
    WaitForSingleObject(timer, INFINITE);
}

// The side data the synthetic producer sends: one TLV record of a private
// test type (0xF0), carrying the frame number and the pose sequence it read.
#pragma pack(push, 1)
struct TestSideData {
    uint8_t type = 0xF0;
    uint16_t length = 12;
    uint64_t frame_number;
    uint32_t pose_sequence;
};
#pragma pack(pop)

// ---- produce --------------------------------------------------------------------

int produce(const Options &o) {
    const std::string channel = o.str("channel", "spike");
    const double seconds = o.num("seconds", 10), fps = o.num("fps", 90), wait = o.num("wait", 10);
    const int width = static_cast<int>(o.num("width", 2560)), height = static_cast<int>(o.num("height", 1440));
    const long crash_after = static_cast<long>(o.num("crash-after", -1));
    const bool aux = o.has("aux");

    ID3D11Device *device = nullptr;
    lw_device *shim_device = nullptr;
    if (o.has("warp")) {
        const D3D_FEATURE_LEVEL level = D3D_FEATURE_LEVEL_11_1;
        ID3D11DeviceContext *context = nullptr;
        HRESULT hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_WARP, nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT, &level, 1,
                                       D3D11_SDK_VERSION, &device, nullptr, &context);
        if (FAILED(hr)) { printf("error: WARP device 0x%08lX\n", hr); return 1; }
        context->Release();
        printf("producer device: WARP (software adapter)\n");
    } else {
        lw_status st = lw_device_create(nullptr, &shim_device);
        if (st != LW_OK) die("lw_device_create", st);
        device = static_cast<ID3D11Device *>(lw_device_get_d3d11(shim_device));
        lw_device_info info{};
        lw_device_get_info(shim_device, &info);
        printf("producer device: %s\n", info.adapter_name);
    }
    lw_spike_pattern *pattern = nullptr;
    lw_status st = lw_spike_pattern_create(device, width, height, &pattern);
    if (st != LW_OK) die("lw_spike_pattern_create", st);

    lw_frame_producer_params params{};
    params.channel = channel.c_str();
    params.device = device;
    params.format.layout = LW_FS_LAYOUT_MONO;
    params.format.slot_count = static_cast<uint32_t>(o.num("slots", 3));
    params.format.image_format = LW_FS_FORMAT_B8G8R8A8_UNORM;
    params.format.image_width = static_cast<uint32_t>(width);
    params.format.image_height = static_cast<uint32_t>(height);
    if (aux) {
        params.format.aux_role = LW_FS_AUX_DEPTH;
        params.format.aux_format = LW_FS_FORMAT_R32_FLOAT;
        params.format.aux_width = static_cast<uint32_t>(width / 2);
        params.format.aux_height = static_cast<uint32_t>(height / 2);
    }

    lw_frame_producer *producer = nullptr;
    bool quiet_no_host = false;
    long attaches = 0, busy = 0, lost = 0, submitted = 0, superseded = 0;
    std::vector<double> attach_ms, acquire_ms, draw_ms, submit_ms;
    auto attach = [&](double for_seconds) -> bool {
        const int64_t give_up = lw_qpc_now() + static_cast<int64_t>(for_seconds * lw_qpc_frequency());
        for (;;) {
            uint32_t refusal = 0;
            const int64_t t0 = lw_qpc_now();
            lw_status s = lw_frame_producer_attach(&params, &producer, &refusal);
            if (s == LW_OK) {
                quiet_no_host = false;
                attach_ms.push_back(ms(lw_qpc_now() - t0));
                ++attaches;
                lw_frame_producer_stats ps{};
                lw_frame_producer_get_stats(producer, &ps);
                printf("attached: generation %llu (%.1f ms)\n", static_cast<unsigned long long>(ps.generation), attach_ms.back());
                fflush(stdout);
                return true;
            }
            if (s == LW_E_REFUSED) {
                printf("refused: reason %u: %s\n", refusal, lw_last_error());
                fflush(stdout);
                return false;
            }
            if (s != LW_E_UNAVAILABLE && s != LW_E_BUSY) die("lw_frame_producer_attach", s);
            if (lw_qpc_now() > give_up) {
                if (!quiet_no_host) printf("no host: %s (retrying)\n", lw_last_error());
                quiet_no_host = true;
                return false;
            }
            Sleep(100);
        }
    };
    if (!attach(wait)) return 2;

    const int64_t interval = static_cast<int64_t>(lw_qpc_frequency() / fps);
    const int64_t end = lw_qpc_now() + static_cast<int64_t>(seconds * lw_qpc_frequency());
    int64_t next = lw_qpc_now();
    uint64_t frame = 0;
    while (lw_qpc_now() < end) {
        next += interval;
        // After a stretch without a host, skip ahead rather than bursting to catch up.
        if (next < lw_qpc_now() - interval) next = lw_qpc_now();
        precise_sleep_until(next);
        ++frame;
        if (crash_after >= 0 && static_cast<long>(frame) > crash_after) {
            printf("crashing on purpose at frame %llu (no detach)\n", static_cast<unsigned long long>(frame));
            fflush(stdout);
            TerminateProcess(GetCurrentProcess(), 3);
        }
        if (!producer) {
            if (!attach(0.05)) continue; // keep the frame clock running while no host listens
        }
        lw_frame_producer_slot slot{};
        int64_t t0 = lw_qpc_now();
        lw_status s = lw_frame_producer_acquire(producer, &slot);
        if (s == LW_E_BUSY) { ++busy; continue; }
        if (s == LW_E_ACCESS_LOST) {
            ++lost;
            printf("host lost at frame %llu: %s\n", static_cast<unsigned long long>(frame), lw_last_error());
            fflush(stdout);
            lw_frame_producer_detach(producer);
            producer = nullptr;
            continue;
        }
        if (s != LW_OK) die("lw_frame_producer_acquire", s);
        superseded += slot.superseded;
        int64_t t1 = lw_qpc_now();
        s = lw_spike_pattern_draw(pattern, slot.textures[LW_FS_TEXTURE_IMAGE], slot.textures[LW_FS_TEXTURE_AUX], frame);
        if (s != LW_OK) die("lw_spike_pattern_draw", s);
        lw_fs_host_state host{};
        lw_frame_producer_read_host_state(producer, &host);
        TestSideData side;
        side.frame_number = frame;
        side.pose_sequence = host.pose_sequence;
        int64_t t2 = lw_qpc_now();
        s = lw_frame_producer_submit(producer, slot.index, frame, &side, sizeof side);
        int64_t t3 = lw_qpc_now();
        if (s == LW_E_ACCESS_LOST) { ++lost; lw_frame_producer_detach(producer); producer = nullptr; continue; }
        if (s != LW_OK) die("lw_frame_producer_submit", s);
        ++submitted;
        acquire_ms.push_back(ms(t1 - t0));
        draw_ms.push_back(ms(t2 - t1));
        submit_ms.push_back(ms(t3 - t2));
    }
    printf("\nproducer: frames %llu, submitted %ld, host busy (starved) %ld, superseded %ld, host lost %ld, attaches %ld\n",
           static_cast<unsigned long long>(frame), submitted, busy, superseded, lost, attaches);
    printf("producer CPU cost per frame, ms:\n");
    describe("attach", attach_ms);
    describe("acquire", acquire_ms);
    describe("draw (queue only)", draw_ms);
    describe("submit (signal+flush+publish)", submit_ms);
    if (producer) lw_frame_producer_detach(producer);
    lw_spike_pattern_release(pattern);
    if (shim_device) lw_device_release(shim_device); else device->Release();
    return 0;
}

// ---- consume / inprocess: the host side ------------------------------------------

struct Record {
    uint64_t frame;
    int64_t present, taken, ready, dequeued, submit, done;
    uint32_t bytes;
};

// A frame on its way to the encoder: an lw_frame from the source, or (in-
// process baseline) a texture of our own with a release hook.
struct Work {
    void *texture = nullptr;
    void *aux = nullptr;
    uint64_t frame = 0;
    int64_t present = 0, taken = 0, ready = 0;
    lw_frame *source_frame = nullptr;
    std::atomic<bool> *busy = nullptr;
    const uint8_t *side = nullptr;
    uint32_t side_size = 0;
    void release() {
        if (source_frame) lw_frame_release(source_frame);
        if (busy) busy->store(false);
        source_frame = nullptr;
        busy = nullptr;
    }
};

// One-slot latest-wins handoff, as the Phase 2 spike's FrameMailbox.
struct Mailbox {
    std::mutex mutex;
    std::condition_variable cv;
    bool has = false;
    Work slot;
    std::atomic<long> superseded{0};
    void put(Work w) {
        Work old;
        bool replaced = false;
        {
            std::lock_guard<std::mutex> lock(mutex);
            if (has) { old = slot; replaced = true; }
            slot = w;
            has = true;
        }
        if (replaced) { old.release(); ++superseded; }
        cv.notify_one();
    }
    bool take(Work &out, int timeout_ms) {
        std::unique_lock<std::mutex> lock(mutex);
        if (!cv.wait_for(lock, std::chrono::milliseconds(timeout_ms), [&] { return has; })) return false;
        out = slot;
        has = false;
        return true;
    }
};

struct Encoding {
    lw_device *device = nullptr;
    lw_encoder *encoder = nullptr;
    lw_spike_pattern *verifier = nullptr;
    double fps = 90, mbps = 50;
    bool encode = true, verify = false, opened = false;
    std::mutex records_mutex;
    std::vector<Record> records;
    long verify_failures = 0, verified = 0, encode_errors = 0;
    uint32_t last_pose = 0;

    void open(int width, int height) {
        if (verify) {
            lw_status st = lw_spike_pattern_create(lw_device_get_d3d11(device), width, height, &verifier);
            if (st != LW_OK) die("lw_spike_pattern_create", st);
        }
        if (!encode) return;
        lw_encoder_params p{};
        p.codec = LW_CODEC_HEVC;
        p.width = width;
        p.height = height;
        p.fps = static_cast<uint32_t>(fps);
        p.bitrate_bps = static_cast<uint32_t>(mbps * 1e6);
        p.preset = 1;
        p.async_mode = 1;
        lw_status st = lw_encoder_create(device, &p, &encoder);
        if (st != LW_OK) die("lw_encoder_create", st);
        lw_encoder_info info{};
        lw_encoder_get_info(encoder, &info);
        printf("encoder: %s, %dx%d @ %.0f, %.0f Mbit/s\n", info.name, width, height, fps, mbps);
    }

    void process(Work &w, int width, int height) {
        const int64_t dequeued = lw_qpc_now();
        if (!opened) {
            open(width, height);
            opened = true;
        }
        if (verify) {
            uint32_t painted = 0;
            float aux_value = -1;
            lw_status st = lw_spike_pattern_read(verifier, w.texture, w.aux, &painted, &aux_value);
            bool ok = st == LW_OK && painted == static_cast<uint32_t>(w.frame);
            if (w.aux) ok = ok && aux_value == static_cast<float>(w.frame % (1u << 24));
            if (w.side) {
                TestSideData side{};
                ok = ok && w.side_size == sizeof side;
                if (w.side_size == sizeof side) {
                    memcpy(&side, w.side, sizeof side);
                    ok = ok && side.type == 0xF0 && side.frame_number == w.frame && !lw_fs_serial_newer(last_pose, side.pose_sequence);
                    last_pose = side.pose_sequence;
                }
            }
            ++verified;
            if (!ok && verify_failures++ < 5)
                printf("verify FAILED: slot frame %llu, painted %u, aux %.0f, side %u bytes\n",
                       static_cast<unsigned long long>(w.frame), painted, aux_value, w.side_size);
        }
        Record r{w.frame, w.present, w.taken, w.ready, dequeued, dequeued, dequeued, 0};
        if (encode) {
            lw_packet packet{};
            lw_status st = lw_encoder_encode(encoder, w.texture, w.frame, records.empty() ? LW_ENCODE_FORCE_IDR : 0, &packet);
            if (st != LW_OK) {
                if (encode_errors++ < 5) printf("encode error: %s\n", lw_last_error());
            } else {
                r.submit = packet.submit_qpc;
                r.done = packet.done_qpc;
                r.bytes = packet.size;
            }
        }
        w.release(); // after the encode: the GPU is done with the texture
        std::lock_guard<std::mutex> lock(records_mutex);
        records.push_back(r);
    }

    void report(const char *csv) {
        std::vector<Record> rows;
        {
            std::lock_guard<std::mutex> lock(records_mutex);
            rows = records;
        }
        if (rows.size() > 90) rows.erase(rows.begin(), rows.begin() + 90); // first second: clocks ramping, encoder warm-up
        std::vector<double> a, b, c, d, e, f, g;
        for (const Record &r : rows) {
            a.push_back(ms(r.taken - r.present));
            b.push_back(ms(r.ready - r.taken));
            c.push_back(ms(r.ready - r.present));
            d.push_back(ms(r.submit - r.ready));
            e.push_back(ms(r.done - r.submit));
            f.push_back(ms(r.submit - r.present));
            g.push_back(ms(r.done - r.present));
        }
        printf("latency per frame, ms (first second dropped):\n");
        describe("present -> taken", a);
        describe("taken -> fence reached", b);
        describe("PRESENT -> FENCE REACHED", c);
        describe("fence reached -> encode start", d);
        describe("encode (submit -> done)", e);
        describe("present -> encode start", f);
        describe("PRESENT -> ENCODED", g);
        std::vector<double> intervals;
        for (size_t i = 1; i < rows.size(); ++i) intervals.push_back(ms(rows[i].present - rows[i - 1].present));
        describe("frame interval", intervals);
        if (verify) printf("verify: %ld frames checked, %ld failures\n", verified, verify_failures);
        if (csv) {
            if (FILE *file = fopen(csv, "w")) {
                fprintf(file, "frame,present_ms,taken_ms,ready_ms,dequeued_ms,submit_ms,done_ms,bytes\n");
                const int64_t base = rows.empty() ? 0 : rows.front().present;
                for (const Record &r : rows)
                    fprintf(file, "%llu,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%u\n", static_cast<unsigned long long>(r.frame),
                            ms(r.present - base), ms(r.taken - base), ms(r.ready - base), ms(r.dequeued - base),
                            ms(r.submit - base), ms(r.done - base), r.bytes);
                fclose(file);
                printf("wrote %s\n", csv);
            }
        }
    }
};

void run_encoder_thread(Encoding &enc, Mailbox &mailbox, std::atomic<bool> &stop, std::atomic<int> &width,
                        std::atomic<int> &height) {
    HANDLE mmcss = nullptr;
    DWORD index = 0;
    mmcss = AvSetMmThreadCharacteristicsW(L"Capture", &index);
    while (!stop.load()) {
        Work w;
        if (!mailbox.take(w, 50)) continue;
        enc.process(w, width.load(), height.load());
    }
    if (mmcss) AvRevertMmThreadCharacteristics(mmcss);
}

struct ConsumeState {
    Mailbox mailbox;
    std::atomic<int> width{0}, height{0};
    std::atomic<long> stall_at{-1};
    int64_t stall_ticks = 0;
    std::atomic<long> delivered{0};
    std::mutex hoard_mutex;
    std::vector<lw_frame *> hoard;
    int64_t stall_end = 0;
    bool stalled_once = false;
};

// Ends a simulated stall once its time is up. Called from the frame callback
// and from the main loop: with every slot held no frame arrives to do it.
void end_stall_if_due(ConsumeState *state) {
    std::lock_guard<std::mutex> lock(state->hoard_mutex);
    if (!state->stall_end || lw_qpc_now() < state->stall_end) return;
    printf("stall over: releasing %zu held frames\n", state->hoard.size());
    fflush(stdout);
    for (lw_frame *held : state->hoard) lw_frame_release(held);
    state->hoard.clear();
    state->stall_end = 0;
}

void on_source_frame(void *context, lw_frame *frame) {
    auto *state = static_cast<ConsumeState *>(context);
    const lw_frame_info *info = lw_frame_get_info(frame);
    const lw_frame_source_info *src = lw_frame_get_source_info(frame);
    state->width = info->width;
    state->height = info->height;
    const long n = ++state->delivered;
    {
        // Simulated encoder stall: hold every frame (never release) until the stall ends.
        std::lock_guard<std::mutex> lock(state->hoard_mutex);
        if (!state->stalled_once && state->stall_at >= 0 && n >= state->stall_at) {
            state->stalled_once = true;
            state->stall_end = lw_qpc_now() + state->stall_ticks;
            printf("stall: holding frames from frame %llu\n", static_cast<unsigned long long>(info->sequence));
            fflush(stdout);
        }
        if (state->stall_end && lw_qpc_now() < state->stall_end) {
            state->hoard.push_back(frame);
            return;
        }
    }
    end_stall_if_due(state);
    Work w;
    w.texture = info->texture;
    w.aux = src->textures[LW_FS_TEXTURE_AUX];
    w.frame = src->frame_number;
    w.present = src->present_qpc;
    w.taken = src->taken_qpc;
    w.ready = src->ready_qpc;
    w.source_frame = frame;
    w.side = src->side_data;
    w.side_size = src->side_data_size;
    state->mailbox.put(w);
}

int consume(const Options &o) {
    const std::string channel = o.str("channel", "spike");
    const double seconds = o.num("seconds", 10), fps = o.num("fps", 90);
    Encoding enc;
    enc.fps = fps;
    enc.mbps = o.num("mbps", 50);
    enc.verify = o.has("verify");
    enc.encode = !o.has("no-encode");
    lw_status st = lw_device_create(nullptr, &enc.device);
    if (st != LW_OK) die("lw_device_create", st);
    lw_device_info info{};
    lw_device_get_info(enc.device, &info);
    printf("host device: %s\n", info.adapter_name);

    ConsumeState state;
    state.stall_at = static_cast<long>(o.num("stall-at", -1));
    state.stall_ticks = static_cast<int64_t>(o.num("stall-ms", 2000) / 1000 * lw_qpc_frequency());
    std::atomic<bool> stop{false};
    std::thread encoder([&] { run_encoder_thread(enc, state.mailbox, stop, state.width, state.height); });

    lw_frame_source_params params{};
    params.channel = channel.c_str();
    lw_frame_source *source = nullptr;
    st = lw_frame_source_start(enc.device, &params, on_source_frame, &state, &source);
    if (st != LW_OK) die("lw_frame_source_start", st);
    printf("listening on '%s' for %.0f s (pid %lu)\n", channel.c_str(), seconds, GetCurrentProcessId());
    fflush(stdout);

    // Publish a host state at the display rate, as the network thread would.
    const int64_t interval = static_cast<int64_t>(lw_qpc_frequency() / fps);
    const int64_t end = lw_qpc_now() + static_cast<int64_t>(seconds * lw_qpc_frequency());
    int64_t next = lw_qpc_now();
    uint32_t pose = 0;
    lw_frame_source_stats last{};
    while (lw_qpc_now() < end) {
        next += interval;
        precise_sleep_until(next);
        lw_fs_host_state hs{};
        hs.pose_sequence = ++pose;
        hs.pose_valid = 1;
        hs.head.orientation[3] = 1;
        hs.refresh_millihz = static_cast<uint32_t>(fps * 1000);
        hs.next_frame_start_qpc = next + interval;
        hs.written_qpc = lw_qpc_now();
        lw_frame_source_publish(source, &hs);
        end_stall_if_due(&state);
        lw_frame_source_stats now{};
        lw_frame_source_get_stats(source, &now);
        if (now.attaches != last.attaches || now.refusals != last.refusals || now.detaches != last.detaches ||
            now.producer_exits != last.producer_exits) {
            printf("[%.2f s] attached %d (pid %u, generation %llu), attaches %llu, refusals %llu (last reason %u), "
                   "detaches %llu, producer exits %llu\n",
                   (seconds * lw_qpc_frequency() - (end - lw_qpc_now())) / lw_qpc_frequency(), now.attached,
                   now.producer_pid, static_cast<unsigned long long>(now.generation),
                   static_cast<unsigned long long>(now.attaches), static_cast<unsigned long long>(now.refusals),
                   now.last_refusal, static_cast<unsigned long long>(now.detaches),
                   static_cast<unsigned long long>(now.producer_exits));
            fflush(stdout);
            last = now;
        }
    }
    lw_frame_source_stats stats{};
    lw_frame_source_get_stats(source, &stats);
    {
        std::lock_guard<std::mutex> lock(state.hoard_mutex);
        for (lw_frame *held : state.hoard) lw_frame_release(held);
        state.hoard.clear();
    }
    lw_frame_source_stop(source);
    stop = true;
    encoder.join();
    Work leftover;
    if (state.mailbox.take(leftover, 0)) leftover.release();

    printf("\nhost: delivered %llu, mailbox superseded %ld, fence timeouts %llu, attaches %llu, refusals %llu, "
           "detaches %llu, producer exits %llu\n",
           static_cast<unsigned long long>(stats.delivered), state.mailbox.superseded.load(),
           static_cast<unsigned long long>(stats.fence_timeouts), static_cast<unsigned long long>(stats.attaches),
           static_cast<unsigned long long>(stats.refusals), static_cast<unsigned long long>(stats.detaches),
           static_cast<unsigned long long>(stats.producer_exits));
    printf("ring (this generation): submitted %llu, consumed %llu, host dropped %llu, producer superseded %llu, "
           "producer starved %llu\n",
           static_cast<unsigned long long>(stats.submitted), static_cast<unsigned long long>(stats.consumed),
           static_cast<unsigned long long>(stats.dropped), static_cast<unsigned long long>(stats.superseded),
           static_cast<unsigned long long>(stats.starved));
    enc.report(o.values.count("csv") ? o.values.at("csv").c_str() : nullptr);
    if (enc.encoder) lw_encoder_release(enc.encoder);
    if (enc.verifier) lw_spike_pattern_release(enc.verifier);
    lw_device_release(enc.device);
    return 0;
}

int inprocess(const Options &o) {
    const double seconds = o.num("seconds", 10), fps = o.num("fps", 90);
    const int width = static_cast<int>(o.num("width", 2560)), height = static_cast<int>(o.num("height", 1440));
    Encoding enc;
    enc.fps = fps;
    enc.mbps = o.num("mbps", 50);
    lw_status st = lw_device_create(nullptr, &enc.device);
    if (st != LW_OK) die("lw_device_create", st);
    auto *device = static_cast<ID3D11Device *>(lw_device_get_d3d11(enc.device));
    ID3D11Device5 *device5 = nullptr;
    device->QueryInterface(IID_PPV_ARGS(&device5));
    ID3D11DeviceContext *immediate = nullptr;
    device->GetImmediateContext(&immediate);
    ID3D11DeviceContext4 *context = nullptr;
    immediate->QueryInterface(IID_PPV_ARGS(&context));
    ID3D11Fence *fence = nullptr;
    if (FAILED(device5->CreateFence(0, D3D11_FENCE_FLAG_NONE, IID_PPV_ARGS(&fence)))) { printf("error: CreateFence\n"); return 1; }
    HANDLE fence_event = CreateEventW(nullptr, FALSE, FALSE, nullptr);

    // Same description as the host's shared ring textures.
    constexpr int kRing = 3;
    ID3D11Texture2D *textures[kRing] = {};
    std::atomic<bool> busy[kRing];
    for (int i = 0; i < kRing; ++i) {
        D3D11_TEXTURE2D_DESC desc{};
        desc.Width = static_cast<UINT>(width);
        desc.Height = static_cast<UINT>(height);
        desc.MipLevels = 1;
        desc.ArraySize = 1;
        desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
        desc.SampleDesc.Count = 1;
        desc.Usage = D3D11_USAGE_DEFAULT;
        desc.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
        desc.MiscFlags = D3D11_RESOURCE_MISC_SHARED | D3D11_RESOURCE_MISC_SHARED_NTHANDLE;
        if (FAILED(device->CreateTexture2D(&desc, nullptr, &textures[i]))) { printf("error: CreateTexture2D\n"); return 1; }
        busy[i] = false;
    }
    lw_spike_pattern *pattern = nullptr;
    st = lw_spike_pattern_create(device, width, height, &pattern);
    if (st != LW_OK) die("lw_spike_pattern_create", st);

    Mailbox mailbox;
    std::atomic<bool> stop{false};
    std::atomic<int> w{width}, h{height};
    std::thread encoder([&] { run_encoder_thread(enc, mailbox, stop, w, h); });
    printf("in-process baseline: %dx%d @ %.0f for %.0f s\n", width, height, fps, seconds);

    const int64_t interval = static_cast<int64_t>(lw_qpc_frequency() / fps);
    const int64_t end = lw_qpc_now() + static_cast<int64_t>(seconds * lw_qpc_frequency());
    int64_t next = lw_qpc_now();
    uint64_t frame = 0, value = 0;
    long starved = 0;
    while (lw_qpc_now() < end) {
        next += interval;
        precise_sleep_until(next);
        ++frame;
        int slot = -1;
        for (int i = 0; i < kRing && slot < 0; ++i) {
            bool expected = false;
            if (busy[i].compare_exchange_strong(expected, true)) slot = i;
        }
        if (slot < 0) { ++starved; continue; }
        lw_spike_pattern_draw(pattern, textures[slot], nullptr, frame);
        context->Signal(fence, ++value);
        context->Flush();
        Work work;
        work.present = lw_qpc_now();
        work.taken = work.present;
        while (fence->GetCompletedValue() < value) {
            fence->SetEventOnCompletion(value, fence_event);
            WaitForSingleObject(fence_event, 1000);
        }
        work.ready = lw_qpc_now();
        work.texture = textures[slot];
        work.frame = frame;
        work.busy = &busy[slot];
        mailbox.put(work);
    }
    stop = true;
    encoder.join();
    Work leftover;
    if (mailbox.take(leftover, 0)) leftover.release();
    printf("\nbaseline: frames %llu, starved %ld, mailbox superseded %ld\n", static_cast<unsigned long long>(frame), starved,
           mailbox.superseded.load());
    enc.report(o.values.count("csv") ? o.values.at("csv").c_str() : nullptr);
    lw_spike_pattern_release(pattern);
    for (auto *t : textures) t->Release();
    fence->Release();
    context->Release();
    immediate->Release();
    device5->Release();
    CloseHandle(fence_event);
    if (enc.encoder) lw_encoder_release(enc.encoder);
    lw_device_release(enc.device);
    return 0;
}

int gpu_load(const Options &o) {
    lw_gpu_load *load = nullptr;
    lw_status st = lw_spike_gpu_load_start(static_cast<int32_t>(o.num("percent", 70)), &load);
    if (st != LW_OK) die("lw_spike_gpu_load_start", st);
    printf("GPU load at ~%.0f%% for %.0f s (pid %lu)\n", o.num("percent", 70), o.num("seconds", 60), GetCurrentProcessId());
    fflush(stdout);
    Sleep(static_cast<DWORD>(o.num("seconds", 60) * 1000));
    lw_spike_gpu_load_stop(load);
    return 0;
}

} // namespace

extern "C" int lw_spike_frame_source_tool(int argc, char **argv) {
    setvbuf(stdout, nullptr, _IOLBF, 1 << 16);
    lw_status st = lw_runtime_init();
    if (st != LW_OK) die("lw_runtime_init", st);
    const std::string command = argc > 1 ? argv[1] : "";
    const Options options(argc, argv);
    if (command == "produce") return produce(options);
    if (command == "consume") return consume(options);
    if (command == "inprocess") return inprocess(options);
    if (command == "gpu-load") return gpu_load(options);
    printf("usage: frame-source-spike produce|consume|inprocess|gpu-load [options] (see the source header)\n");
    return 1;
}
