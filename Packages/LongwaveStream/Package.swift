// swift-tools-version: 6.0
// LongwaveStream - the portable v3 stream core (NATIVE_V3_PROTOCOL.md section 7.1).
//
// Today this holds the Phase 2 go/no-go spike (2026-10-04):
//   kept     CStreamWin         C ABI over WGC/DXGI capture, NVENC, WASAPI (Windows)
//            StreamHostWindows  its Swift side
//   spike    StreamSpikeWire, longwave-host-spike, stream-spike-receiver,
//            StreamSpikeTests   - a throwaway packetizer and test tools, to be
//                                 replaced by the Phase 1 core (StreamWire,
//                                 StreamTransport, ...).
//
// Windows-only targets exist only when the manifest is evaluated on Windows,
// so the package resolves and builds on macOS and Linux without them.
import PackageDescription

var products: [Product] = [
    .executable(name: "stream-spike-receiver", targets: ["stream-spike-receiver"]),
]

var targets: [Target] = [
    .target(name: "StreamSpikeWire"),
    .executableTarget(name: "stream-spike-receiver", dependencies: ["StreamSpikeWire"]),
    .testTarget(
        name: "StreamSpikeTests",
        dependencies: ["StreamSpikeWire", .product(name: "Crypto", package: "swift-crypto")]
    ),
]

#if os(Windows)
products.append(.executable(name: "longwave-host-spike", targets: ["longwave-host-spike"]))
targets += [
    .target(
        name: "CStreamWin",
        exclude: ["third_party/nvenc/README.md"],
        cxxSettings: [
            .headerSearchPath("third_party/nvenc"),
            .define("WIN32_LEAN_AND_MEAN"),
            .define("NOMINMAX"),
            .define("UNICODE"),
            .define("_UNICODE"),
        ],
        linkerSettings: [
            .linkedLibrary("d3d11"),
            .linkedLibrary("dxgi"),
            .linkedLibrary("windowsapp"), // WinRT activation (Windows.Graphics.Capture)
            .linkedLibrary("ole32"),
            .linkedLibrary("avrt"),       // MMCSS thread priorities
            .linkedLibrary("winmm"),      // timeBeginPeriod
            .linkedLibrary("user32"),
        ]
    ),
    .target(name: "StreamHostWindows", dependencies: ["CStreamWin"]),
    .executableTarget(
        name: "longwave-host-spike",
        dependencies: [
            "StreamHostWindows",
            "StreamSpikeWire",
            .product(name: "Crypto", package: "swift-crypto"),
        ],
        linkerSettings: [.linkedLibrary("dwmapi"), .linkedLibrary("gdi32"), .linkedLibrary("user32")]
    ),
]
#endif

let package = Package(
    name: "LongwaveStream",
    platforms: [.macOS(.v14)],
    products: products,
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0" ..< "5.0.0"),
    ],
    targets: targets,
    cxxLanguageStandard: .cxx20
)
