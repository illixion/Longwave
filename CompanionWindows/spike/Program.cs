// Longwave Windows Hotspot Companion — Step-1 spike.
//
// Goal (from plan.md): a minimal console that walks the Mobile Hotspot API end to
// end so we can answer three questions BEFORE building the real service:
//   (a) does StartTetheringAsync work when run *elevated* in this session?
//   (b) does it work from a non-interactive / Session-0-like context (this SSH shell)?
//   (c) does the target Wi-Fi adapter support SoftAP (and STA+AP concurrency when the
//       shared upstream is Wi-Fi)?
//
// It prints a verdict block at the end. Pass --start to actually bring the AP up
// (default is a dry run that only probes capability). Pass --duration <sec> to hold
// the AP up for N seconds so a phone / Vision Pro can join, then it tears down.

using System.Security.Cryptography;
using System.Security.Principal;
using Windows.Networking.Connectivity;
using Windows.Networking.NetworkOperators;

static void Log(string msg) => Console.WriteLine($"[{DateTime.Now:HH:mm:ss}] {msg}");

bool doStart = args.Contains("--start");
int holdSeconds = 0;
var durIdx = Array.IndexOf(args, "--duration");
if (durIdx >= 0 && durIdx + 1 < args.Length && int.TryParse(args[durIdx + 1], out var d))
{
    holdSeconds = d;
    doStart = true; // --duration implies --start
}

Log("=== Longwave Hotspot Spike ===");

// --- Context: are we elevated? what session are we in? ---
bool isAdmin;
using (var identity = WindowsIdentity.GetCurrent())
{
    var principal = new WindowsPrincipal(identity);
    isAdmin = principal.IsInRole(WindowsBuiltInRole.Administrator);
    Log($"Identity      : {identity.Name}");
    Log($"Elevated      : {isAdmin}");
    Log($"IsSystem      : {identity.IsSystem}");
}
int sessionId = System.Diagnostics.Process.GetCurrentProcess().SessionId;
Log($"Session ID    : {sessionId}  (0 = non-interactive/services session)");
Log("");

// --- Step 1: find the upstream internet connection profile ---
ConnectionProfile? profile = NetworkInformation.GetInternetConnectionProfile();
if (profile is null)
{
    Log("FATAL: GetInternetConnectionProfile() returned null — no shareable upstream.");
    PrintVerdict(false, "no internet connection profile");
    return 2;
}

string upstreamName = profile.ProfileName ?? "(unnamed)";
var iface = profile.NetworkAdapter;
Log($"Upstream      : {upstreamName}");
Log($"  Adapter ID  : {iface?.NetworkAdapterId}");
Log($"  IanaIfType  : {iface?.IanaInterfaceType}  (6=Ethernet, 71=Wi-Fi/802.11)");

// Enumerate ALL connection profiles too (the UI will let the user pick Ethernet vs Wi-Fi).
Log("");
Log("All connection profiles:");
foreach (var p in NetworkInformation.GetConnectionProfiles())
{
    var lvl = p.GetNetworkConnectivityLevel();
    Log($"  - {p.ProfileName,-30} WLAN={p.IsWlanConnectionProfile} WWAN={p.IsWwanConnectionProfile} connectivity={lvl}");
}
Log("");

// --- Step 2: tethering capability for this upstream ---
TetheringCapability cap;
try
{
    cap = NetworkOperatorTetheringManager.GetTetheringCapabilityFromConnectionProfile(profile);
    Log($"TetheringCapability for upstream: {cap}");
}
catch (Exception ex)
{
    Log($"GetTetheringCapability threw: {ex.GetType().Name}: {ex.Message}");
    cap = TetheringCapability.DisabledByGroupPolicy; // sentinel; treated as unusable below
}

if (cap != TetheringCapability.Enabled)
{
    Log($"WARNING: upstream not Enabled for tethering ({cap}). Will still try to create a manager.");
}

// --- Step 3: create the tethering manager ---
NetworkOperatorTetheringManager mgr;
try
{
    mgr = NetworkOperatorTetheringManager.CreateFromConnectionProfile(profile);
}
catch (Exception ex)
{
    Log($"FATAL: CreateFromConnectionProfile threw: {ex.GetType().Name}: 0x{ex.HResult:X8} {ex.Message}");
    PrintVerdict(false, $"CreateFromConnectionProfile failed: {ex.Message}");
    return 3;
}

Log($"Manager created. State={mgr.TetheringOperationalState}  Clients={mgr.ClientCount}/{mgr.MaxClientCount}");

// Show the current AP config (defaults Windows picked).
var current = mgr.GetCurrentAccessPointConfiguration();
Log($"Current AP cfg: SSID='{current.Ssid}'  Band={SafeBand(current)}");
Log("");

if (!doStart)
{
    Log("Dry run (no --start). Capability probe complete.");
    bool capableDry = cap == TetheringCapability.Enabled;
    PrintVerdict(capableDry, capableDry ? "capability Enabled (pass --start to bring AP up)" : $"capability={cap}");
    return capableDry ? 0 : 1;
}

// --- Step 4: configure a fresh AP (Longwave SSID + 8-char alphanumeric WPA2 pass) ---
string ssid = $"Longwave-{RandomToken(4)}";
string passphrase = RandomToken(8); // WPA2 minimum is 8 chars
var cfg = new NetworkOperatorTetheringAccessPointConfiguration
{
    Ssid = ssid,
    Passphrase = passphrase,
};
TrySetBand(cfg);

Log($"Configuring AP: SSID='{ssid}'  Pass='{passphrase}'");
try
{
    await mgr.ConfigureAccessPointAsync(cfg);
    Log("ConfigureAccessPointAsync OK.");
}
catch (Exception ex)
{
    Log($"FATAL: ConfigureAccessPointAsync threw: {ex.GetType().Name}: 0x{ex.HResult:X8} {ex.Message}");
    PrintVerdict(false, $"Configure failed: {ex.Message}");
    return 4;
}

// --- Step 5: start tethering — THE critical call ---
Log("Calling StartTetheringAsync ...");
NetworkOperatorTetheringOperationResult result;
try
{
    result = await mgr.StartTetheringAsync();
}
catch (Exception ex)
{
    Log($"FATAL: StartTetheringAsync threw: {ex.GetType().Name}: 0x{ex.HResult:X8} {ex.Message}");
    Log(ElevationHint(ex));
    PrintVerdict(false, $"StartTetheringAsync threw 0x{ex.HResult:X8}: {ex.Message}");
    return 5;
}

Log($"StartTetheringAsync -> Status={result.Status}  AdditionalErrorMessage='{result.AdditionalErrorMessage}'");
if (result.Status != TetheringOperationStatus.Success)
{
    PrintVerdict(false, $"Start status={result.Status}: {result.AdditionalErrorMessage}");
    return 6;
}

Log($"HOTSPOT UP. State={mgr.TetheringOperationalState}  Clients={mgr.ClientCount}/{mgr.MaxClientCount}");
PrintGateway();
Log("");
Log($"  >>> Join from a phone/Vision Pro:  SSID='{ssid}'  Password='{passphrase}'");
PrintGateway();
Log("");

if (holdSeconds > 0)
{
    Log($"Holding AP up for {holdSeconds}s — connect a client now. Polling client count...");
    var end = DateTime.UtcNow.AddSeconds(holdSeconds);
    long lastClients = -1;
    while (DateTime.UtcNow < end)
    {
        await Task.Delay(2000);
        long c = mgr.ClientCount;
        var st = mgr.TetheringOperationalState;
        if (c != lastClients)
        {
            Log($"  clients={c}/{mgr.MaxClientCount}  state={st}");
            lastClients = c;
        }
    }

    Log("Hold elapsed. Stopping tethering...");
    try
    {
        var stop = await mgr.StopTetheringAsync();
        Log($"StopTetheringAsync -> {stop.Status}");
    }
    catch (Exception ex)
    {
        Log($"StopTetheringAsync threw: {ex.Message}");
    }
}
else
{
    Log("AP started successfully (no --duration hold). Leaving it running; run with --duration to auto-stop.");
}

PrintVerdict(true, "StartTetheringAsync succeeded");
return 0;

// ----------------- helpers -----------------

static string RandomToken(int len)
{
    // Unambiguous WPA2-safe alphanumeric (no 0/O/1/l/I to ease manual typing on visionOS).
    const string alphabet = "ABCDEFGHJKMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789";
    var bytes = RandomNumberGenerator.GetBytes(len);
    var chars = new char[len];
    for (int i = 0; i < len; i++) chars[i] = alphabet[bytes[i] % alphabet.Length];
    return new string(chars);
}

static string SafeBand(NetworkOperatorTetheringAccessPointConfiguration cfg)
{
    try { return cfg.Band.ToString(); }
    catch { return "(unsupported on this build)"; }
}

static void TrySetBand(NetworkOperatorTetheringAccessPointConfiguration cfg)
{
    // Band is only honored if the API contract + driver support it; guard it.
    try { cfg.Band = TetheringWiFiBand.Auto; }
    catch (Exception ex) { Log($"  (Band not set: {ex.Message})"); }
}

static void PrintGateway()
{
    // The Mobile Hotspot ICS gateway is almost always 192.168.137.1; confirm from the
    // live adapter list so the verdict reflects reality.
    try
    {
        foreach (var ni in System.Net.NetworkInformation.NetworkInterface.GetAllNetworkInterfaces())
        {
            if (ni.OperationalStatus != System.Net.NetworkInformation.OperationalStatus.Up) continue;
            foreach (var ip in ni.GetIPProperties().UnicastAddresses)
            {
                var a = ip.Address;
                if (a.ToString().StartsWith("192.168.137."))
                    Log($"  >>> Gateway IP (type into the headset): {a}   (on '{ni.Name}')");
            }
        }
    }
    catch { /* best effort */ }
}

static string ElevationHint(Exception ex)
{
    // 0x80070005 = E_ACCESSDENIED. A common signal that the API refuses this context.
    if ((uint)ex.HResult == 0x80070005)
        return "  HINT: E_ACCESSDENIED — the API may refuse this session/elevation context (see plan elevation risk).";
    return "  HINT: failure is not access-denied; likely a driver/STA+AP or upstream limitation.";
}

static void PrintVerdict(bool ok, string detail)
{
    Console.WriteLine();
    Console.WriteLine("============================ SPIKE VERDICT ============================");
    Console.WriteLine(ok ? $"  PASS — {detail}" : $"  FAIL — {detail}");
    Console.WriteLine("=======================================================================");
}
