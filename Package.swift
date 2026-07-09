// swift-tools-version:6.0
import PackageDescription
import Foundation

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
        // C-interop shim exposing libssl/libcrypto to Swift. OpenSSL is located through
        // pkg-config, so this package carries no unsafe build flags and can be used as a normal
        // dependency. Homebrew's openssl@3 is keg-only, so on macOS export its pkg-config path:
        //   export PKG_CONFIG_PATH="$(brew --prefix openssl@3)/lib/pkgconfig"
        .systemLibrary(
            name: "COpenSSL",
            path: "Sources/COpenSSL",
            pkgConfig: "openssl",
            providers: [.brew(["openssl@3"]), .apt(["libssl-dev"])]
        ),

        // The driver itself — pure Swift + libc, plus OpenSSL for TLS.
        .target(
            name: "PerunPGSQL",
            dependencies: ["COpenSSL"]
        ),

        // A tiny runnable program that connects and runs queries.
        .executableTarget(
            name: "perun-demo",
            dependencies: ["PerunPGSQL"]
        ),

        // Runnable, compile-checked examples that back the documentation. `swift build` compiles
        // them, so a doc example can't drift from the real API.
        .executableTarget(
            name: "Examples",
            dependencies: ["PerunPGSQL"],
            path: "Examples"
        ),

        // Unit tests for the crypto primitives, wire codecs and type decoders.
        .testTarget(
            name: "PerunTests",
            dependencies: ["PerunPGSQL"]
        ),
    ]
)
