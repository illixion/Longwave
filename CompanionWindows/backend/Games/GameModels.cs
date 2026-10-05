using System.Text.Json.Serialization;

namespace Longwave.WindowsCompanion.Backend.Games;

/// <summary>Whether a title is played in a headset, on a monitor, or either.</summary>
[JsonConverter(typeof(GameKindConverter))]
public enum GameKind { Flat, Vr, Both }

/// <summary>"flat" / "vr" / "both" on the wire (net8 has no per-member enum names).</summary>
public sealed class GameKindConverter : JsonConverter<GameKind>
{
    public override GameKind Read(ref System.Text.Json.Utf8JsonReader reader, Type typeToConvert,
                                  System.Text.Json.JsonSerializerOptions options) =>
        GameKinds.Parse(reader.GetString()) ?? GameKind.Flat;

    public override void Write(System.Text.Json.Utf8JsonWriter writer, GameKind value,
                               System.Text.Json.JsonSerializerOptions options) =>
        writer.WriteStringValue(value.Name());
}

public static class GameKinds
{
    public static bool CanRunInVr(this GameKind kind) => kind is GameKind.Vr or GameKind.Both;

    public static GameKind? Parse(string? value) => value?.Trim().ToLowerInvariant() switch
    {
        "flat" => GameKind.Flat,
        "vr" => GameKind.Vr,
        "both" => GameKind.Both,
        _ => null,
    };

    public static string Name(this GameKind kind) => kind switch
    {
        GameKind.Vr => "vr",
        GameKind.Both => "both",
        _ => "flat",
    };
}

/// <summary>
/// One title as the Companion sees it. The headset-facing subset (id, name, source, steamAppId,
/// installDir, portraitArt, landscapeArt) keeps the field names the visionOS app's
/// <c>GameLibraryTitle</c> decodes, so the PCVR gallery is unchanged.
/// </summary>
public sealed record GameTitle
{
    [JsonPropertyName("id")] public required string Id { get; init; }
    [JsonPropertyName("name")] public required string Name { get; init; }
    /// <summary>"steam" or "custom".</summary>
    [JsonPropertyName("source")] public required string Source { get; init; }
    [JsonPropertyName("steamAppId")] public uint? SteamAppId { get; init; }
    /// <summary>Custom titles only: exactly what runs.</summary>
    [JsonPropertyName("executable")] public string? Executable { get; init; }
    [JsonPropertyName("arguments")] public string? Arguments { get; init; }
    [JsonPropertyName("installDir")] public string? InstallDir { get; init; }
    [JsonPropertyName("kind")] public GameKind Kind { get; init; }
    /// <summary>What Steam's metadata says (custom titles: what the user chose when adding).</summary>
    [JsonPropertyName("detectedKind")] public GameKind DetectedKind { get; init; }
    [JsonPropertyName("kindOverridden")] public bool KindOverridden { get; init; }
    [JsonPropertyName("portraitArt")] public string? PortraitArt { get; init; }
    [JsonPropertyName("landscapeArt")] public string? LandscapeArt { get; init; }
    /// <summary>Steam's client icon for the title, when cached — used for desktop shortcuts.</summary>
    [JsonPropertyName("icon")] public string? Icon { get; init; }
    [JsonPropertyName("exposed")] public bool Exposed { get; init; }
    [JsonPropertyName("optimizedAvailable")] public bool OptimizedAvailable { get; init; }
    [JsonPropertyName("optimizedNote")] public string? OptimizedNote { get; init; }
    [JsonPropertyName("optimized")] public bool Optimized { get; init; }
    /// <summary>Latest of Steam's own LastPlayed and launches through Longwave, ISO-8601 UTC.</summary>
    [JsonPropertyName("lastPlayed")] public DateTimeOffset? LastPlayed { get; init; }
    [JsonPropertyName("sizeBytes")] public long? SizeBytes { get; init; }
}

/// <summary>
/// A launch resolved to a process: what to start, where, and as which Steam app. Handed to
/// whichever process starts it — the Companion (desktop) or the PCVR host (VR) — so neither has
/// to know anything about Steam or the library.
/// </summary>
public sealed record LaunchPlan
{
    [JsonPropertyName("titleId")] public required string TitleId { get; init; }
    [JsonPropertyName("name")] public required string Name { get; init; }
    [JsonPropertyName("executable")] public required string Executable { get; init; }
    [JsonPropertyName("arguments")] public string? Arguments { get; init; }
    [JsonPropertyName("workingDirectory")] public required string WorkingDirectory { get; init; }
    [JsonPropertyName("steamAppId")] public uint? SteamAppId { get; init; }
    /// <summary>True when the title's VR entry was chosen (every VR launch, and a desktop launch of
    /// a VR-only title).</summary>
    [JsonPropertyName("vrEntry")] public bool VrEntry { get; init; }
    [JsonPropertyName("profileApplied")] public bool ProfileApplied { get; init; }
}

/// <summary>Art for one title. A missing cover is a normal answer, not an error.</summary>
public sealed record ArtResult(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("mime")] string? Mime,
    [property: JsonPropertyName("data")] string? Data,
    [property: JsonPropertyName("unavailable")] string? Unavailable);

/// <summary>A launch the library could not resolve, with a message fit for the user.</summary>
public sealed class LaunchRefusedException(string message) : Exception(message);
