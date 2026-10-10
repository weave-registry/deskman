// swift-tools-version: 6.2
// One target per hexagonal layer (ADR-2610101046). The dependency lists ARE the
// architecture: an adapter that is not given a target cannot import it.
import PackageDescription

let package = Package(
    name: "Deskman",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Deskman", targets: ["Deskman"]),
    ],
    targets: [
        // domain — pure value types and rules. Foundation only.
        .target(name: "DeskmanDomain", path: "Sources/domain"),
        // ports — the contracts. Re-exports the domain value types.
        .target(name: "DeskmanPorts", dependencies: ["DeskmanDomain"], path: "Sources/ports"),
        // usecases — what Deskman does, written against ports only.
        .target(name: "DeskmanUseCases", dependencies: ["DeskmanPorts"], path: "Sources/usecases"),

        // adapters/secondary — the things Deskman drives.
        .target(name: "AccessibilityAdapter", dependencies: ["DeskmanPorts"],
                path: "Sources/adapters/secondary/accessibility"),
        .target(name: "FoundationModelsAdapter", dependencies: ["DeskmanPorts"],
                path: "Sources/adapters/secondary/foundation-models"),
        // adapters/primary — the things that drive Deskman.
        .target(name: "DeskmanUI", dependencies: ["DeskmanPorts"],
                path: "Sources/adapters/primary/ui"),

        // composition root — the only target that sees every adapter.
        .executableTarget(
            name: "Deskman",
            dependencies: ["DeskmanUseCases", "AccessibilityAdapter", "FoundationModelsAdapter", "DeskmanUI"],
            path: "Sources/app"
        ),

        .testTarget(name: "DeskmanTests", dependencies: ["DeskmanDomain", "DeskmanPorts", "DeskmanUseCases"], path: "Tests/DeskmanTests"),
    ]
)
