// swift-tools-version:6.0
import PackageDescription
import Foundation

/// Locate the OpenSSL headers/libs. `pkg-config` is often absent (and Homebrew's
/// openssl is keg-only), so we probe the usual spots. Override with the
/// `OPENSSL_PREFIX` environment variable if yours lives elsewhere.
func opensslPrefix() -> String {
    if let override = ProcessInfo.processInfo.environment["OPENSSL_PREFIX"], !override.isEmpty {
        return override
    }
    let candidates = [
        "/opt/homebrew/opt/openssl@3",   // Apple Silicon Homebrew
        "/usr/local/opt/openssl@3",      // Intel Homebrew
        "/opt/homebrew/opt/openssl",
        "/usr/local/opt/openssl",
    ]
    for path in candidates where FileManager.default.fileExists(atPath: path + "/include/openssl/ssl.h") {
        return path
    }
    return "/usr"                         // Linux: /usr/include + /usr/lib
}

let ssl = opensslPrefix()

// Every target that (transitively) loads the COpenSSL Clang module needs the
// header search path so Clang can build that module; and the final link needs
// the library search path. Apply both everywhere to keep the module build
// flags consistent across targets.
let opensslSwiftSettings: [SwiftSetting] = [.unsafeFlags(["-Xcc", "-I\(ssl)/include"])]
let opensslLinkerSettings: [LinkerSetting] = [.unsafeFlags(["-L\(ssl)/lib"])]

// swift-docc-plugin is pulled in only for documentation builds (set PERUN_BUILD_DOCS=1, as
// Scripts/build-docs.sh does), so a normal build — and anyone depending on this package — never
// carries a docs tool in its dependency graph.
var packageDependencies: [Package.Dependency] = []
if ProcessInfo.processInfo.environment["PERUN_BUILD_DOCS"] != nil {
    packageDependencies.append(.package(url: "https://github.com/apple/swift-docc-plugin", from: "1.0.0"))
}

let package = Package(
    name: "PerunPGSQL",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "PerunPGSQL", targets: ["PerunPGSQL"]),
        .executable(name: "perun-demo", targets: ["perun-demo"]),
    ],
    dependencies: packageDependencies,
    targets: [
        // C-interop shim exposing libssl/libcrypto to Swift.
        .systemLibrary(name: "COpenSSL", path: "Sources/COpenSSL"),

        // The driver itself — pure Swift + libc, plus OpenSSL for TLS.
        .target(
            name: "PerunPGSQL",
            dependencies: ["COpenSSL"],
            swiftSettings: opensslSwiftSettings,
            linkerSettings: opensslLinkerSettings
        ),

        // A tiny runnable program that connects and runs queries.
        .executableTarget(
            name: "perun-demo",
            dependencies: ["PerunPGSQL"],
            swiftSettings: opensslSwiftSettings,
            linkerSettings: opensslLinkerSettings
        ),

        // Runnable, compile-checked examples that back the documentation. `swift build` compiles
        // them, so a doc example can't drift from the real API.
        .executableTarget(
            name: "Examples",
            dependencies: ["PerunPGSQL"],
            path: "Examples",
            swiftSettings: opensslSwiftSettings,
            linkerSettings: opensslLinkerSettings
        ),

        // Unit tests for the crypto primitives, wire codecs and type decoders.
        .testTarget(
            name: "PerunTests",
            dependencies: ["PerunPGSQL"],
            swiftSettings: opensslSwiftSettings,
            linkerSettings: opensslLinkerSettings
        ),
    ]
)
