using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.Win32;

namespace Longwave.WindowsCompanion.Backend.Devices;

/// <summary>
/// What a paired device may do — the Windows counterpart of
/// <c>CompanionGrant</c> in <c>Shared/CompanionDevices.swift</c>. Raw values
/// travel on the wire. A Windows PC serves the screen and input; the other
/// grants are the Mac's and are never offered here.
/// </summary>
public static class Grant
{
    public const string Screen = "screen";
    public const string Input = "input";

    public static readonly string[] Offered = { Screen, Input };

    /// <summary>The token this PC used to show for typing in, kept working
    /// during the transition with what it always unlocked.</summary>
    public static readonly string[] Legacy = { Screen, Input };

    public static string Title(string grant) => grant switch
    {
        Screen => "See the screen",
        Input => "Control this PC (pointer, keys, typing)",
        _ => grant,
    };
}

public sealed record PairedDevice
{
    [JsonPropertyName("id")] public string Id { get; init; } = "";
    [JsonPropertyName("name")] public string Name { get; init; } = "";
    [JsonPropertyName("grants")] public List<string> Grants { get; init; } = new();
    [JsonPropertyName("token")] public string Token { get; init; } = "";
    [JsonPropertyName("pairedAt")] public DateTimeOffset PairedAt { get; init; }
    [JsonPropertyName("lastSeen")] public DateTimeOffset? LastSeen { get; init; }
}

/// <summary>A device as the UI sees it: no token.</summary>
public sealed record PairedDeviceInfo(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("name")] string Name,
    [property: JsonPropertyName("grants")] IReadOnlyList<string> Grants,
    [property: JsonPropertyName("pairedAt")] DateTimeOffset PairedAt,
    [property: JsonPropertyName("lastSeen")] DateTimeOffset? LastSeen);

/// <summary>
/// The devices paired with this PC (COMPANION_ENROLLMENT_PLAN.md). Each has its
/// own token; the list is DPAPI-protected (current user) in the registry. The
/// screen-streaming token from before pairing is still accepted — with screen
/// and input — until the user stops accepting it.
/// </summary>
public sealed class DeviceRegistry
{
    private const string RegistryPath = @"SOFTWARE\Longwave\Companion";
    private const string DevicesValue = "PairedDevices";
    private const string LegacyTokenValue = "NativeStreamToken";
    private const string AcceptsLegacyValue = "AcceptsLegacyToken";
    private const string HostIdValue = "CompanionHostId";
    private static readonly byte[] Entropy = Encoding.UTF8.GetBytes("Longwave paired devices v1");

    private readonly object _gate = new();
    private List<PairedDevice> _devices;

    public event Action? Changed;

    public DeviceRegistry()
    {
        _devices = Load();
    }

    /// <summary>This PC's identity towards headsets, stable across launches.</summary>
    public string HostId
    {
        get
        {
            var existing = ReadString(HostIdValue);
            if (!string.IsNullOrEmpty(existing)) return existing;
            var id = Guid.NewGuid().ToString().ToUpperInvariant();
            WriteString(HostIdValue, id);
            return id;
        }
    }

    public string? LegacyToken =>
        AcceptsLegacyToken ? ReadString(LegacyTokenValue) is { Length: > 0 } t ? t : null : null;

    public bool AcceptsLegacyToken
    {
        get
        {
            if (string.IsNullOrEmpty(ReadString(LegacyTokenValue))) return false;
            using var key = Registry.CurrentUser.OpenSubKey(RegistryPath);
            return key?.GetValue(AcceptsLegacyValue) is not int value || value != 0;
        }
    }

    public IReadOnlyList<PairedDeviceInfo> Devices
    {
        get
        {
            lock (_gate)
            {
                return _devices
                    .OrderByDescending(d => d.PairedAt)
                    .Select(d => new PairedDeviceInfo(d.Id, d.Name, d.Grants, d.PairedAt, d.LastSeen))
                    .ToList();
            }
        }
    }

    /// <summary>The credential a PSK identity names: a device id, or null for
    /// the shared token. Returns the token and the grants it carries.</summary>
    public (string Token, IReadOnlyList<string> Grants)? Lookup(string? deviceId)
    {
        if (deviceId is null)
        {
            return LegacyToken is { } legacy ? (legacy, Grant.Legacy) : null;
        }
        lock (_gate)
        {
            var device = _devices.FirstOrDefault(d => d.Id == deviceId);
            return device is null ? null : (device.Token, device.Grants);
        }
    }

    /// <summary>Pairing approved: a fresh token for this device, replacing any
    /// it had before, with exactly the grants the user ticked.</summary>
    public string Enroll(string id, string name, IEnumerable<string> grants)
    {
        var token = NewToken();
        lock (_gate)
        {
            _devices.RemoveAll(d => d.Id == id);
            _devices.Add(new PairedDevice
            {
                Id = id,
                Name = name.Length > 80 ? name[..80] : name,
                Grants = grants.Where(g => Grant.Offered.Contains(g)).Distinct().ToList(),
                Token = token,
                PairedAt = DateTimeOffset.UtcNow,
                LastSeen = DateTimeOffset.UtcNow,
            });
            Save();
        }
        Changed?.Invoke();
        return token;
    }

    public void SetGrants(string id, IEnumerable<string> grants)
    {
        lock (_gate)
        {
            var index = _devices.FindIndex(d => d.Id == id);
            if (index < 0) return;
            _devices[index] = _devices[index] with { Grants = grants.Where(g => Grant.Offered.Contains(g)).Distinct().ToList() };
            Save();
        }
        Changed?.Invoke();
    }

    public void Revoke(string id)
    {
        lock (_gate)
        {
            if (_devices.RemoveAll(d => d.Id == id) == 0) return;
            Save();
        }
        Changed?.Invoke();
    }

    public void StopAcceptingLegacyToken()
    {
        using (var key = Registry.CurrentUser.CreateSubKey(RegistryPath))
        {
            key.SetValue(AcceptsLegacyValue, 0, RegistryValueKind.DWord);
            key.DeleteValue(LegacyTokenValue, throwOnMissingValue: false);
        }
        Changed?.Invoke();
    }

    public void NoteSeen(string? deviceId)
    {
        if (deviceId is null) return;
        lock (_gate)
        {
            var index = _devices.FindIndex(d => d.Id == deviceId);
            if (index < 0) return;
            var now = DateTimeOffset.UtcNow;
            if (_devices[index].LastSeen is { } last && now - last < TimeSpan.FromMinutes(1)) return;
            _devices[index] = _devices[index] with { LastSeen = now };
            Save();
        }
    }

    private static string NewToken() =>
        Convert.ToBase64String(RandomNumberGenerator.GetBytes(32))
            .Replace('+', '-').Replace('/', '_').TrimEnd('=');

    private List<PairedDevice> Load()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RegistryPath);
            if (key?.GetValue(DevicesValue) is not byte[] sealedBytes) return new();
            var json = ProtectedData.Unprotect(sealedBytes, Entropy, DataProtectionScope.CurrentUser);
            return JsonSerializer.Deserialize<List<PairedDevice>>(json) ?? new();
        }
        catch
        {
            return new();
        }
    }

    private void Save()
    {
        var json = JsonSerializer.SerializeToUtf8Bytes(_devices);
        var sealedBytes = ProtectedData.Protect(json, Entropy, DataProtectionScope.CurrentUser);
        using var key = Registry.CurrentUser.CreateSubKey(RegistryPath);
        key.SetValue(DevicesValue, sealedBytes, RegistryValueKind.Binary);
    }

    private static string? ReadString(string name)
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RegistryPath);
            return key?.GetValue(name) as string;
        }
        catch { return null; }
    }

    private static void WriteString(string name, string value)
    {
        using var key = Registry.CurrentUser.CreateSubKey(RegistryPath);
        key.SetValue(name, value, RegistryValueKind.String);
    }
}
