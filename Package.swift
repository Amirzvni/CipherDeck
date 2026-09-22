// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "CipherDeck",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CipherDeck", targets: ["CipherDeck"]),
    ],
    targets: [
        // Pure, testable logic. Everything security-critical lives here.
        .target(name: "CipherDeckCore"),
        // The SwiftUI app.
        .executableTarget(
            name: "CipherDeck",
            dependencies: ["CipherDeckCore"]
        ),
        // Executable test suite (`swift run CipherDeckSelfTest`).
        .executableTarget(
            name: "CipherDeckSelfTest",
            dependencies: ["CipherDeckCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
