using System.Net.NetworkInformation;
using System.Runtime.InteropServices;
using Microsoft.Extensions.Logging;

namespace Longwave.WindowsCompanion.Backend.Devices;

/// <summary>
/// Announces this PC to headsets the way the Mac Companion announces itself:
/// a <c>_longwave-mac._tcp</c> record (the type name predates Windows hosts;
/// its TXT says which this is) carrying the host's id, its addresses, that its
/// ports are open, <c>os=windows</c>, and <c>pp</c>, the direct pairing port —
/// so a headset pairs by dialling it instead of knocking for a listener.
///
/// Uses Windows' own DNS-SD (<c>DnsServiceRegister</c>, Windows 10 1809+): no
/// Bonjour install. The API has no record update, so a change of address
/// re-registers.
/// </summary>
public sealed class DnsSdAdvertiser : IDisposable
{
    private const string ServiceType = "_longwave-mac._tcp.local";
    private const uint DnsQueryRequestVersion1 = 1;
    private const int DnsRequestPending = 9506;

    private readonly ILogger _log;
    private readonly DeviceRegistry _devices;
    private readonly object _gate = new();
    private IntPtr _instance = IntPtr.Zero;
    /// <summary>The request block, in unmanaged memory: the same pointer must
    /// reach DnsServiceDeRegister later.</summary>
    private IntPtr _request = IntPtr.Zero;
    private readonly DnsServiceRegisterComplete _callback;
    private bool _registered;
    private Timer? _debounce;

    public DnsSdAdvertiser(ILogger log, DeviceRegistry devices)
    {
        _log = log;
        _devices = devices;
        _callback = OnRegistered;
    }

    public void Start()
    {
        Register();
        NetworkChange.NetworkAddressChanged += OnAddressChanged;
    }

    public void Dispose()
    {
        NetworkChange.NetworkAddressChanged -= OnAddressChanged;
        _debounce?.Dispose();
        Deregister();
    }

    private void OnAddressChanged(object? sender, EventArgs e)
    {
        lock (_gate)
        {
            _debounce?.Dispose();
            _debounce = new Timer(_ => { Deregister(); Register(); }, null, TimeSpan.FromSeconds(2), Timeout.InfiniteTimeSpan);
        }
    }

    private void Register()
    {
        lock (_gate)
        {
            if (_registered) return;
            var machine = Environment.MachineName;
            var keys = new[] { "v", "id", "open", "os", "pp", "addr" };
            var values = new[]
            {
                "1", _devices.HostId, "1", "windows", PairingService.Port.ToString(),
                string.Join(",", HostAddresses.Lan()),
            };
            _instance = DnsServiceConstructInstance(
                $"{machine}.{ServiceType}", $"{machine}.local", IntPtr.Zero, IntPtr.Zero,
                // No socket stands behind the record itself (like the Mac's);
                // SRV needs a port, so the pairing port stands in.
                PairingService.Port, 0, 0, (uint)keys.Length, keys, values);
            if (_instance == IntPtr.Zero)
            {
                _log.LogWarning("Couldn't build the DNS-SD record");
                return;
            }
            var request = new DnsServiceRegisterRequest
            {
                Version = DnsQueryRequestVersion1,
                InterfaceIndex = 0,
                pServiceInstance = _instance,
                pRegisterCompletionCallback = Marshal.GetFunctionPointerForDelegate(_callback),
                pQueryContext = IntPtr.Zero,
                hCredentials = IntPtr.Zero,
                unicastEnabled = 0,
            };
            _request = Marshal.AllocHGlobal(Marshal.SizeOf<DnsServiceRegisterRequest>());
            Marshal.StructureToPtr(request, _request, false);
            var status = DnsServiceRegister(_request, IntPtr.Zero);
            if (status != DnsRequestPending)
            {
                _log.LogWarning("DNS-SD registration failed ({Status}); headsets won't list this PC nearby", status);
                FreeRequest();
                return;
            }
            _registered = true;
        }
    }

    private void Deregister()
    {
        lock (_gate)
        {
            if (!_registered) return;
            _registered = false;
            DnsServiceDeRegister(_request, IntPtr.Zero);
            // The instance is freed in the completion callback deregistration
            // raises; the request block stays pinned until then.
        }
    }

    private void OnRegistered(uint status, IntPtr context, IntPtr instance)
    {
        if (instance != IntPtr.Zero) DnsServiceFreeInstance(instance);
        lock (_gate)
        {
            if (!_registered)
            {
                // A deregistration finishing.
                FreeRequest();
                return;
            }
        }
        if (status == 0) _log.LogInformation("Announced this PC to nearby headsets");
        else _log.LogWarning("DNS-SD registration completed with {Status}", status);
    }

    private void FreeRequest()
    {
        if (_instance != IntPtr.Zero) { DnsServiceFreeInstance(_instance); _instance = IntPtr.Zero; }
        if (_request != IntPtr.Zero) { Marshal.FreeHGlobal(_request); _request = IntPtr.Zero; }
    }

    // MARK: dnsapi.dll

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate void DnsServiceRegisterComplete(uint status, IntPtr queryContext, IntPtr instance);

    [StructLayout(LayoutKind.Sequential)]
    private struct DnsServiceRegisterRequest
    {
        public uint Version;
        public uint InterfaceIndex;
        public IntPtr pServiceInstance;
        public IntPtr pRegisterCompletionCallback;
        public IntPtr pQueryContext;
        public IntPtr hCredentials;
        public int unicastEnabled;
    }

    [DllImport("dnsapi.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr DnsServiceConstructInstance(
        string pServiceName, string pHostName, IntPtr pIp4, IntPtr pIp6,
        ushort wPort, ushort wPriority, ushort wWeight, uint dwPropertiesCount,
        [MarshalAs(UnmanagedType.LPArray, ArraySubType = UnmanagedType.LPWStr)] string[] keys,
        [MarshalAs(UnmanagedType.LPArray, ArraySubType = UnmanagedType.LPWStr)] string[] values);

    [DllImport("dnsapi.dll")]
    private static extern void DnsServiceFreeInstance(IntPtr pInstance);

    [DllImport("dnsapi.dll")]
    private static extern int DnsServiceRegister(IntPtr pRequest, IntPtr pCancel);

    [DllImport("dnsapi.dll")]
    private static extern int DnsServiceDeRegister(IntPtr pRequest, IntPtr pCancel);
}
