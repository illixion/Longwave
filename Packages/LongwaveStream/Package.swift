// swift-tools-version: 6.0
// LongwaveStream - the portable v3 stream core (NATIVE_V3_PROTOCOL.md section 7.1).
//
// Today this holds the first Phase 1 module and the Phase 2 go/no-go spike
// (2026-10-04):
//   core     StreamWire         v3 wire types (frames, shard headers, format,
//            StreamWireTests    side data, input, STATE, capabilities);
//                               Foundation-free, builds on every platform
//            StreamFEC          Reed-Solomon over the vendored cm256 (CCM256), the
//            StreamFECTests     block layout and the frame sharder (section 4.2)
//            StreamPlayout      receive side: the frame assembler (shards -> frames
//            StreamPlayoutTests in decode order, FEC recovery, NACK candidates)
//   kept     CStreamWin         C ABI over WGC/DXGI capture, NVENC, WASAPI (Windows),
//                                 and the external frame source producer/consumer
//            StreamHostWindows  its Swift side
//            CFrameSourceCore   the external frame source's shared-memory layout and
//                                 protocol (section 7.2), portable so it is tested everywhere
//   spike    StreamSpikeWire, longwave-host-spike, stream-spike-receiver,
//            StreamSpikeTests   - a throwaway packetizer and test tools, to be
//                                 replaced by the Phase 1 core (StreamWire,
//                                 StreamTransport, ...).
//   spike    frame-source-spike - synthetic producer and latency harness for the
//                                 external frame source (open question 18)
//
// Windows-only targets exist only when the manifest is evaluated on Windows,
// so the package resolves and builds on macOS and Linux without them.
import PackageDescription

var products: [Product] = [
    .library(name: "StreamWire", targets: ["StreamWire"]),
    .library(name: "StreamFEC", targets: ["StreamFEC"]),
    .library(name: "StreamPlayout", targets: ["StreamPlayout"]),
    .executable(name: "stream-spike-receiver", targets: ["stream-spike-receiver"]),
]

var targets: [Target] = [
    .target(name: "StreamWire"),
    .testTarget(name: "StreamWireTests", dependencies: ["StreamWire"]),
    // cm256 (BSD-3), vendored with two portability patches: Sources/CCM256/README.md.
    .target(name: "CCM256", exclude: ["README.md", "LICENSE"]),
    .target(name: "StreamFEC", dependencies: ["StreamWire", "CCM256"]),
    .testTarget(name: "StreamFECTests", dependencies: ["StreamFEC", "StreamWire"]),
    .target(name: "StreamPlayout", dependencies: ["StreamWire", "StreamFEC"]),
    .testTarget(name: "StreamPlayoutTests", dependencies: ["StreamPlayout", "StreamFEC", "StreamWire"]),
    .target(name: "CFrameSourceCore"),
    .testTarget(name: "FrameSourceCoreTests", dependencies: ["CFrameSourceCore"]),
    .target(name: "StreamSpikeWire"),
    .executableTarget(name: "stream-spike-receiver", dependencies: ["StreamSpikeWire"]),
    .testTarget(
        name: "StreamSpikeTests",
        dependencies: ["StreamSpikeWire", .product(name: "Crypto", package: "swift-crypto")]
    ),
]

#if os(Windows)
products.append(.executable(name: "longwave-host-spike", targets: ["longwave-host-spike"]))
products.append(.executable(name: "frame-source-spike", targets: ["frame-source-spike"]))
targets += [
    .target(
        name: "CStreamWin",
        dependencies: ["CFrameSourceCore"],
        exclude: ["third_party/nvenc/README.md"],
        cxxSettings: [
            .headerSearchPath("third_party/nvenc"),
            // Include CFrameSourceCore's headers textually. Without this, clang
            // (6.2.4 toolchain, explicit module maps, no implicit modules) refuses a
            // C++ #include of another target's modular header: "module
            // 'CFrameSourceCore' is needed but has not been provided".
            .unsafeFlags(["-fmodule-name=CFrameSourceCore"]),
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
            .linkedLibrary("advapi32"),   // security descriptors for the frame source's named objects
        ]
    ),
    .target(name: "StreamHostWindows", dependencies: ["CStreamWin"]),
    .executableTarget(name: "frame-source-spike", dependencies: ["CStreamWin"]),
    .testTarget(name: "StreamHostWindowsTests", dependencies: ["StreamHostWindows", "CStreamWin"]),
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
