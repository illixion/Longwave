using System.Text.Json.Serialization;

namespace VisionVNC.WindowsCompanion.Backend;

// ---------------------------------------------------------------------------
// JSON-RPC-ish line protocol. Every message is a single line of UTF-8 JSON
// terminated by '\n'. Requests carry an "id"; responses echo it. Server->client
// notifications carry "event" and no "id".
// ---------------------------------------------------------------------------

/// <summary>A request from the Electron client to the backend.</summary>
public sealed class RpcRequest
{
    [JsonPropertyName("id")] public int Id { get; set; }
    [JsonPropertyName("method")] public string Method { get; set; } = "";
    [JsonPropertyName("params")] public System.Text.Json.JsonElement? Params { get; set; }
}

/// <summary>A response to a request.</summary>
public sealed class RpcResponse
{
    [JsonPropertyName("id")] public int Id { get; set; }
    [JsonPropertyName("result")] public object? Result { get; set; }
    [JsonPropertyName("error")] public RpcError? Error { get; set; }

    public static RpcResponse Ok(int id, object? result) => new() { Id = id, Result = result };
    public static RpcResponse Fail(int id, string code, string message) =>
        new() { Id = id, Error = new RpcError { Code = code, Message = message } };
}

public sealed class RpcError
{
    [JsonPropertyName("code")] public string Code { get; set; } = "";
    [JsonPropertyName("message")] public string Message { get; set; } = "";
}

/// <summary>An unsolicited server-&gt;client notification (state/clients/error).</summary>
public sealed class RpcEvent
{
    [JsonPropertyName("event")] public string Event { get; set; } = "";
    [JsonPropertyName("data")] public object? Data { get; set; }

    public static RpcEvent Of(string name, object? data) => new() { Event = name, Data = data };
}

// ---------------------------------------------------------------------------
// Domain payloads
// ---------------------------------------------------------------------------

/// <summary>One shareable upstream connection profile (Ethernet / Wi-Fi / WWAN).</summary>
public sealed class UpstreamProfile
{
    [JsonPropertyName("id")] public string Id { get; set; } = "";
    [JsonPropertyName("name")] public string Name { get; set; } = "";
    /// <summary>"ethernet" | "wifi" | "wwan" | "other"</summary>
    [JsonPropertyName("kind")] public string Kind { get; set; } = "other";
    [JsonPropertyName("hasInternet")] public bool HasInternet { get; set; }
    [JsonPropertyName("isDefault")] public bool IsDefault { get; set; }
    /// <summary>Tethering capability for this upstream: "enabled" | "disabledByGroupPolicy" | ...</summary>
    [JsonPropertyName("tetheringCapability")] public string TetheringCapability { get; set; } = "unknown";
}

/// <summary>A Wi-Fi adapter on the host and whether it can host an AP.</summary>
public sealed class WifiAdapterInfo
{
    [JsonPropertyName("name")] public string Name { get; set; } = "";
    [JsonPropertyName("enabled")] public bool Enabled { get; set; }
    [JsonPropertyName("connected")] public bool Connected { get; set; }
    /// <summary>True if this adapter's driver exposes SoftAP or Wi-Fi-Direct-GO.</summary>
    [JsonPropertyName("canHostAp")] public bool CanHostAp { get; set; }
}

/// <summary>Result of PrepareApAdapter — which incapable adapters were disabled.</summary>
public sealed class PrepareApResult
{
    [JsonPropertyName("ok")] public bool Ok { get; set; }
    [JsonPropertyName("disabled")] public List<string> Disabled { get; set; } = new();
    [JsonPropertyName("detail")] public string? Detail { get; set; }
}

/// <summary>Parameters for StartHotspot.</summary>
public sealed class StartHotspotParams
{
    [JsonPropertyName("ssid")] public string? Ssid { get; set; }
    [JsonPropertyName("passphrase")] public string? Passphrase { get; set; }
    /// <summary>"auto" | "2.4" | "5"</summary>
    [JsonPropertyName("band")] public string? Band { get; set; }
    /// <summary>Upstream profile id to share; null = the system internet profile.</summary>
    [JsonPropertyName("profileId")] public string? ProfileId { get; set; }
}

/// <summary>Full hotspot status snapshot — the single source of truth for the UI.</summary>
public sealed class HotspotStatus
{
    /// <summary>"off" | "on" | "inTransition" | "unknown"</summary>
    [JsonPropertyName("state")] public string State { get; set; } = "unknown";
    [JsonPropertyName("ssid")] public string? Ssid { get; set; }
    [JsonPropertyName("passphrase")] public string? Passphrase { get; set; }
    /// <summary>
    /// The band that was <b>requested</b> — not the one the AP came up on. Windows accepts a band
    /// the radio cannot do and silently hosts on another, so this reading `"5"` is not evidence of
    /// a 5 GHz link. Cross-reference <see cref="BandsSupported"/>: measured on the host's
    /// Wi-Fi-Direct-GO adapter, a start with <c>band = "5"</c> returned success with
    /// <c>bandsSupported = []</c> and an access point on 2.4 GHz.
    /// </summary>
    [JsonPropertyName("band")] public string? Band { get; set; }
    [JsonPropertyName("gatewayIp")] public string? GatewayIp { get; set; }
    [JsonPropertyName("clientCount")] public long ClientCount { get; set; }
    [JsonPropertyName("maxClientCount")] public long MaxClientCount { get; set; }
    [JsonPropertyName("upstreamName")] public string? UpstreamName { get; set; }
    [JsonPropertyName("upstreamKind")] public string? UpstreamKind { get; set; }
    /// <summary>True if some Wi-Fi adapter can host an AP (SoftAP/Wi-Fi-Direct-GO).</summary>
    [JsonPropertyName("canHostAp")] public bool CanHostAp { get; set; }
    /// <summary>Human-readable capability/diagnostic detail (e.g. why an AP can't start).</summary>
    [JsonPropertyName("capabilityDetail")] public string? CapabilityDetail { get; set; }
    /// <summary>
    /// Bands the adapter/driver actually offers, as <c>"2.4"</c> / <c>"5"</c>, from
    /// <c>IsBandSupported</c>. Empty means the driver reports neither — which is what a
    /// Wi-Fi-Direct-GO-only adapter does, and it is worth showing: asking for 5 GHz on such an
    /// adapter is silently ignored, so the UI should say "this radio can't do 5 GHz" instead of
    /// letting the user believe they got a 5 GHz link. Null when the query is unavailable
    /// (pre-2004 Windows, or no manager bound yet) as opposed to answered-with-nothing.
    /// </summary>
    [JsonPropertyName("bandsSupported")] public List<string>? BandsSupported { get; set; }
    /// <summary>
    /// True when starting/stopping the hotspot will have to elevate (this process is not
    /// elevated), so the UI can put a shield on the button and warn about the consent prompt
    /// instead of springing one on the user. Reading status never needs elevation.
    /// </summary>
    [JsonPropertyName("elevationOnDemand")] public bool ElevationOnDemand { get; set; }
}

/// <summary>Result of Start/Stop.</summary>
public sealed class OperationResult
{
    [JsonPropertyName("ok")] public bool Ok { get; set; }
    /// <summary>e.g. "success", "adapterCannotHostAp", "wiFiDeviceOff", "noUpstream", ...</summary>
    [JsonPropertyName("status")] public string Status { get; set; } = "";
    [JsonPropertyName("detail")] public string? Detail { get; set; }
    /// <summary>The post-operation status snapshot, so the UI updates in one round-trip.</summary>
    [JsonPropertyName("snapshot")] public HotspotStatus? Snapshot { get; set; }
}
