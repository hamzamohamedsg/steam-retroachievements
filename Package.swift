// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SteamRetroAchievements",
    platforms: [.macOS(.v14)],
    targets: [
        // Target name must match the module name in Vendor/rcheevos/include/module.modulemap.
        .target(
            name: "rcheevos",
            path: "Vendor/rcheevos",
            sources: ["src/rhash", "src/rc_compat.c", "src/rcheevos/consoleinfo.c"],
            publicHeadersPath: "include"
        ),
        // libchdr (BSD-3) with the zlib, LZMA, zstd and FLAC decoders it needs; the umbrella header is chdr.h.
        .target(
            name: "chdr",
            path: "Vendor/libchdr",
            exclude: ["LICENSE.txt", "deps/lzma-26.02/LICENSE"],
            sources: ["src", "deps/lzma-26.02/src/LzmaDec.c", "deps/miniz-3.1.2/miniz.c", "deps/zstd-1.5.7/zstddeclib.c"],
            publicHeadersPath: "include/libchdr",
            cSettings: [.define("MINIZ_NO_ARCHIVE_APIS"), .define("MINIZ_NO_DEFLATE_APIS"), .define("MINIZ_NO_STDIO"), .define("MINIZ_NO_TIME")]
        ),
        .target(name: "CHDReader", dependencies: ["rcheevos", "chdr"]),
        .target(name: "RACore", dependencies: ["rcheevos", "CHDReader"]),
        .testTarget(name: "RACoreTests", dependencies: ["RACore"], resources: [.copy("Fixtures")]),
        .target(name: "SteamBridge"),
        .executableTarget(name: "SteamRetroAchievements", dependencies: ["RACore", "SteamBridge"]),
        .testTarget(name: "SteamBridgeTests", dependencies: ["SteamBridge"]),
    ]
)
