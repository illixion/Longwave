// What the external frame source's producer and host share on Windows: the
// object names, the security descriptor, the mapped section. Internal.
#pragma once

#include "common.hpp"

#include "lw_frame_source.h"
#include "lw_frame_source_core.h"

#include <atomic>
#include <string>

namespace lw::fs {

// An owned Win32 handle (CloseHandle on destruction).
struct Handle {
    HANDLE value = nullptr;
    Handle() = default;
    explicit Handle(HANDLE h) : value(h == INVALID_HANDLE_VALUE ? nullptr : h) {}
    Handle(const Handle &) = delete;
    Handle &operator=(const Handle &) = delete;
    Handle(Handle &&other) noexcept : value(other.value) { other.value = nullptr; }
    Handle &operator=(Handle &&other) noexcept {
        if (this != &other) {
            reset();
            value = other.value;
            other.value = nullptr;
        }
        return *this;
    }
    ~Handle() { reset(); }
    void reset(HANDLE h = nullptr) {
        if (value) CloseHandle(value);
        value = h == INVALID_HANDLE_VALUE ? nullptr : h;
    }
    HANDLE release() {
        HANDLE h = value;
        value = nullptr;
        return h;
    }
    explicit operator bool() const { return value != nullptr; }
};

struct Names {
    std::wstring section, host_event, producer_event;
};

// The three object names for `channel`, or false (with lw_last_error set) if
// the channel name isn't valid.
bool names_for(const char *channel, Names &out);

// The mapped section. Unmaps on destruction; the mapping handle keeps the
// section alive for as long as either side holds it.
struct Section {
    Handle mapping;
    lw_fs_shared *shared = nullptr;
    Section() = default;
    Section(const Section &) = delete;
    Section &operator=(const Section &) = delete;
    ~Section() {
        if (shared) UnmapViewOfFile(shared);
    }
};

// Host: the security attributes every named object is created with (see
// lw_frame_source.h). Owns the descriptor.
struct Security {
    SECURITY_ATTRIBUTES attributes{};
    PSECURITY_DESCRIPTOR descriptor = nullptr;
    std::string user_sid; // the host's user, as a string SID
    ~Security() {
        if (descriptor) LocalFree(descriptor);
    }
};
lw_status make_security(const char *producer_sid, Security &out);

// Whether the existing named object's owner is `sid`.
bool owned_by(HANDLE object, const std::string &sid);

uint64_t luid_value(const LUID &luid);
// The LUID of the adapter `device` was created on.
bool device_luid(ID3D11Device *device, uint64_t &out);
// The current process's creation time (FILETIME as 64 bits).
uint64_t process_start_time(HANDLE process);

// A counter in the section, which the other process increments atomically.
inline uint64_t counter(const uint64_t &field) {
    return std::atomic_ref<uint64_t>(const_cast<uint64_t &>(field)).load(std::memory_order_relaxed);
}

} // namespace lw::fs
