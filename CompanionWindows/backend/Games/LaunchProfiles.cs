namespace Longwave.WindowsCompanion.Backend.Games;

/// <summary>
/// Curated launch arguments for titles whose stock configuration fights the streamed VR path.
/// Public data: each is just an executable and some arguments (moved here from the PCVR host
/// 2026-10-05). The toggle is per title and ON by default because these encode measured fixes;
/// turning one off returns the publisher's own Steam launch. They override the title's VR
/// entry, so they apply only when that entry is the one launched.
/// </summary>
public static class LaunchProfiles
{
    public sealed record Profile(
        string ExecutableRelativePath,
        string AdditionalArguments,
        string Note);

    public static readonly IReadOnlyDictionary<uint, Profile> ByAppId = new Dictionary<uint, Profile>
    {
        // Half-Life: Alyx. No settings UI — graphics are launch-argument convars only. At the
        // 4096-wide eye buffers PCVR streams, its auto fidelity overflows a 10 GB card into WDDM
        // paging (measured: 8.9/10 GB used, 60% GPU utilization, uneven 17 ms frames). The culprit
        // was auto fidelity PLUS high MSAA, so pin the fidelity ladder at Ultra and cap MSAA at 2x.
        // NOT Medium or High: both shrink the eye buffers (87% and 93% linear scale), and the
        // full-size foveal inset then UPSAMPLES the fovea — visible jaggies. Only Ultra renders 1:1.
        [546560] = new(
            @"game\bin\win64\hlvr.exe",
            "-novid +vr_fidelity_level_auto 0 +vr_fidelity_level 3 +vr_msaa 2",
            "Alyx has no graphics menu; this pins Ultra fidelity (the only level that renders "
            + "1:1 into the streamed eye buffers — lower levels shrink them and read as "
            + "jaggies) with MSAA capped at 2x so VRAM stays inside budget. "
            + "Turn off to use Alyx's Steam-defined VR arguments without these overrides."),
    };

    /// <summary>The opt-in schema was replaced when Alyx was the only curated profile; migrating an
    /// old opt-in list must compare against that historical set, not today's dictionary.</summary>
    public static readonly IReadOnlySet<uint> LegacyOptInIds = new HashSet<uint> { 546560 };
}
