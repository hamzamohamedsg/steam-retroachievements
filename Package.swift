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
        .target(name: "RACore", dependencies: ["rcheevos"]),
        .testTarget(name: "RACoreTests", dependencies: ["RACore"], resources: [.copy("Fixtures")]),
        .target(name: "SteamBridge"),
        .executableTarget(name: "SteamRetroAchievements", dependencies: ["RACore", "SteamBridge"]),
        .testTarget(name: "SteamBridgeTests", dependencies: ["SteamBridge"]),
    ]
)
