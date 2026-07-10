// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Murmur",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
    ],
    targets: [
        .executableTarget(
            name: "Murmur",
            dependencies: ["WhisperKit"],
            path: "Murmur",
            exclude: [
                // Asset catalog requires actool (full Xcode); AppIcon is empty
                // and unused — code loads icons via Bundle.module from Resources.
                "Assets.xcassets",
                // Bundled manually by scripts/bundle.sh, not via SPM.
                "Info.plist",
                "Murmur.entitlements",
            ],
            resources: [
                .copy("Resources"),
            ]
        ),
        .testTarget(
            name: "MurmurTests",
            dependencies: ["Murmur"],
            path: "Tests/MurmurTests"
        ),
    ]
)
