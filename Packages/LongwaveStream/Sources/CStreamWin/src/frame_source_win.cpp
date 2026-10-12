// Names, security and small helpers shared by the frame source's producer and
// host (lw_frame_source.h).
#include "frame_source_win.hpp"

#include <aclapi.h>
#include <sddl.h>

#include <vector>

namespace lw::fs {

bool names_for(const char *channel, Names &out) {
    if (!channel || !*channel) {
        fail(LW_E_INVALID_ARG, "frame source: empty channel name");
        return false;
    }
    size_t length = 0;
    for (const char *c = channel; *c; ++c, ++length) {
        const bool ok = (*c >= 'a' && *c <= 'z') || (*c >= 'A' && *c <= 'Z') || (*c >= '0' && *c <= '9') ||
                        *c == '.' || *c == '-' || *c == '_';
        if (!ok || length >= LW_FS_MAX_CHANNEL) {
            fail(LW_E_INVALID_ARG, "frame source: channel name must be 1-%d of [A-Za-z0-9._-]", LW_FS_MAX_CHANNEL);
            return false;
        }
    }
    const std::wstring base = L"Local\\lw_frame_source." + widen(channel);
    out.section = base;
    out.host_event = base + L".host";
    out.producer_event = base + L".producer";
    return true;
}

namespace {

std::string token_user_sid() {
    HANDLE token = nullptr;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) return {};
    Handle owned(token);
    DWORD size = 0;
    GetTokenInformation(token, TokenUser, nullptr, 0, &size);
    std::vector<uint8_t> buffer(size);
    if (!GetTokenInformation(token, TokenUser, buffer.data(), size, &size)) return {};
    LPSTR text = nullptr;
    if (!ConvertSidToStringSidA(reinterpret_cast<TOKEN_USER *>(buffer.data())->User.Sid, &text)) return {};
    std::string sid(text);
    LocalFree(text);
    return sid;
}

bool valid_sid(const char *sid) {
    PSID parsed = nullptr;
    if (!ConvertStringSidToSidA(sid, &parsed)) return false;
    LocalFree(parsed);
    return true;
}

} // namespace

lw_status make_security(const char *producer_sid, Security &out) {
    out.user_sid = token_user_sid();
    if (out.user_sid.empty()) return fail_hr(HRESULT_FROM_WIN32(GetLastError()), "frame source: reading the token user");
    if (producer_sid && !valid_sid(producer_sid))
        return fail(LW_E_INVALID_ARG, "frame source: producer_sid '%s' is not a SID", producer_sid);
    // Owner explicit (see owned_by); protected DACL: SYSTEM, the host's user
    // and optionally one more account; low mandatory label, no-write-up, so
    // lower-integrity producers can open what an elevated host creates.
    std::string sddl = "O:" + out.user_sid + "D:P(A;;GA;;;SY)(A;;GA;;;" + out.user_sid + ")";
    if (producer_sid) sddl += std::string("(A;;GA;;;") + producer_sid + ")";
    sddl += "S:(ML;;NW;;;LW)";
    if (!ConvertStringSecurityDescriptorToSecurityDescriptorA(sddl.c_str(), SDDL_REVISION_1, &out.descriptor, nullptr))
        return fail_hr(HRESULT_FROM_WIN32(GetLastError()), "frame source: building the security descriptor");
    out.attributes.nLength = sizeof out.attributes;
    out.attributes.lpSecurityDescriptor = out.descriptor;
    out.attributes.bInheritHandle = FALSE;
    return LW_OK;
}

bool owned_by(HANDLE object, const std::string &sid) {
    PSID owner = nullptr;
    PSECURITY_DESCRIPTOR descriptor = nullptr;
    if (GetSecurityInfo(object, SE_KERNEL_OBJECT, OWNER_SECURITY_INFORMATION, &owner, nullptr, nullptr, nullptr,
                        &descriptor) != ERROR_SUCCESS)
        return false;
    bool same = false;
    LPSTR text = nullptr;
    if (owner && ConvertSidToStringSidA(owner, &text)) {
        same = sid == text;
        LocalFree(text);
    }
    LocalFree(descriptor);
    return same;
}

uint64_t luid_value(const LUID &luid) {
    return static_cast<uint64_t>(luid.LowPart) | (static_cast<uint64_t>(static_cast<uint32_t>(luid.HighPart)) << 32);
}

bool device_luid(ID3D11Device *device, uint64_t &out) {
    winrt::com_ptr<IDXGIDevice> dxgi;
    if (FAILED(device->QueryInterface(IID_PPV_ARGS(dxgi.put())))) return false;
    winrt::com_ptr<IDXGIAdapter> adapter;
    if (FAILED(dxgi->GetAdapter(adapter.put()))) return false;
    DXGI_ADAPTER_DESC desc{};
    if (FAILED(adapter->GetDesc(&desc))) return false;
    out = luid_value(desc.AdapterLuid);
    return true;
}

uint64_t process_start_time(HANDLE process) {
    FILETIME creation{}, exit{}, kernel{}, user{};
    if (!GetProcessTimes(process, &creation, &exit, &kernel, &user)) return 0;
    return (static_cast<uint64_t>(creation.dwHighDateTime) << 32) | creation.dwLowDateTime;
}

} // namespace lw::fs
