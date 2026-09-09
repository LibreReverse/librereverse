// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LibreReverse",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "LibreReverseCore", targets: ["LibreReverseCore"]),
        .executable(name: "librereverse", targets: ["LibreReverseApp"]),
    ],
    targets: [
        .systemLibrary(
            name: "CSQLCipher",
            pkgConfig: "sqlcipher",
            providers: [.brew(["sqlcipher"])]
        ),
        .target(name: "CXID"),
        .target(name: "CSpeech"),
        .target(
            name: "CFPNG",
            exclude: ["vendor/PROVENANCE.md", "vendor/UNLICENSE"],
            cxxSettings: [
                .define("FPNG_NO_SSE", to: "1"),
                .define("FPNG_NO_STDIO", to: "1"),
                .unsafeFlags(["-fno-strict-aliasing"]),
            ]
        ),
        .target(name: "LibreReverseCore", dependencies: ["CSQLCipher", "CXID", "CFPNG", "CSpeech"]),
        .executableTarget(name: "LibreReverseApp", dependencies: ["LibreReverseCore"]),
        .testTarget(name: "LibreReverseCoreTests", dependencies: ["LibreReverseCore", "CSQLCipher", "CFPNG"]),
        .testTarget(
            name: "LibreReverseAppTests",
            dependencies: ["LibreReverseApp", "LibreReverseCore"]
        ),
    ]
)
