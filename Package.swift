// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CodexConfig",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "CodexConfig", targets: ["CodexConfigApp"])],
    targets: [
        .target(name: "CTOMLPatch", exclude: ["LICENSE"], publicHeadersPath: "include",
                cxxSettings: [.define("TOML_LARGE_FILES", to: "1")]),
        .target(name: "CodexConfigCore", dependencies: ["CTOMLPatch"]),
        .executableTarget(name: "CodexConfigApp", dependencies: ["CodexConfigCore"]),
        .testTarget(name: "CodexConfigCoreTests", dependencies: ["CodexConfigCore"]),
        .testTarget(name: "CodexConfigAppTests", dependencies: ["CodexConfigApp"])
    ],
    cxxLanguageStandard: .cxx17
)
