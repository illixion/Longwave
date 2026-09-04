// swift-tools-version: 6.0

import PackageDescription

/// Extra, symbol-prefixed copies of the library (`MoonlightCommonC1`,
/// `MoonlightCommonC2`, …), laid out by make-instances.sh. Each is a complete
/// second compile of moonlight-common-c + enet + nanors with every external
/// symbol renamed, so the app can run that many independent streaming sessions
/// at once — moonlight-common-c itself is written around one connection's worth
/// of global state. Keep in step with make-instances.sh's count and
/// `MoonlightLibrary.count` in the app.
let extraInstances = 2

let applePlatforms: [Platform] = [.macOS, .iOS, .tvOS, .watchOS, .visionOS]

let enetDefines: [CSetting] = [
    .define("HAS_FCNTL", to: "1"),
    .define("HAS_IOCTL", to: "1"),
    .define("HAS_POLL", to: "1"),
    .define("HAS_GETADDRINFO", to: "1"),
    .define("HAS_GETNAMEINFO", to: "1"),
    .define("HAS_INET_PTON", to: "1"),
    .define("HAS_INET_NTOP", to: "1"),
    .define("HAS_MSGHDR_FLAGS", to: "1"),
    .define("HAS_SOCKLEN_T", to: "1"),
]

let moonlightDefines: [CSetting] = [
    .define("NDEBUG"),
    .define("USE_COMMONCRYPTO", .when(platforms: applePlatforms)),
]

let instanceTargets: [Target] = (1...extraInstances).map { n in
    .target(
        name: "MoonlightCommonC\(n)",
        path: "instance\(n)",
        exclude: ["enet_include", "private"],
        sources: ["src", "enet"],
        publicHeadersPath: "include",
        cSettings: enetDefines + moonlightDefines + [
            // The shims #include the real sources by relative path, so the
            // library's own quoted includes resolve against src/ and nanors/
            // as usual; these cover the angle-bracket and search-path ones.
            .headerSearchPath("enet_include"),
            .headerSearchPath("../src"),
            .headerSearchPath("../nanors"),
            .headerSearchPath("../nanors/deps"),
            .headerSearchPath("../nanors/deps/obl"),
        ]
    )
}

let package = Package(
    name: "MoonlightCommonC",

    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .tvOS(.v17),
        .visionOS(.v1)
    ],

    products: [
        .library(
            name: "MoonlightCommonC",
            type: .static,
            targets: ["MoonlightCommonC"]
        )
    ] + (1...extraInstances).map { n in
        .library(
            name: "MoonlightCommonC\(n)",
            type: .static,
            targets: ["MoonlightCommonC\(n)"]
        )
    },

    targets: [
        .target(
            name: "enet",
            path: "enet",
            exclude: [
                "win32.c",
                "CMakeLists.txt",
            ],
            publicHeadersPath: "include",
            cSettings: enetDefines
        ),

        .target(
            name: "MoonlightCommonC",
            dependencies: ["enet"],
            path: ".",
            exclude: [
                "enet",
                "nanors",
                "cmake",
                ".github",
                "CMakeLists.txt",
                "README.md",
                "LICENSE.txt",
                ".gitignore",
                ".gitmodules",
                "include",
            ] + (1...extraInstances).map { "instance\($0)" },
            sources: ["src"],
            publicHeadersPath: "include",
            cSettings: moonlightDefines + [
                .headerSearchPath("src"),
                .headerSearchPath("nanors"),
                .headerSearchPath("nanors/deps"),
                .headerSearchPath("nanors/deps/obl"),
                .define("HAS_SOCKLEN_T"),
            ]
        ),
    ] + instanceTargets
)
