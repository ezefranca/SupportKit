// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "SupportKit",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .tvOS(.v17),
        .watchOS(.v10),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "SupportKit", targets: ["SupportKit"]),
        .library(name: "SupportKitUI", targets: ["SupportKitUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "SupportKit",
            resources: [.process("PrivacyInfo.xcprivacy")],
        ),
        .target(
            name: "SupportKitUI",
            dependencies: ["SupportKit"],
        ),
        .testTarget(
            name: "SupportKitTests",
            dependencies: ["SupportKit"],
        ),
        .testTarget(
            name: "SupportKitUITests",
            dependencies: ["SupportKit", "SupportKitUI"],
        ),
    ],
    swiftLanguageModes: [.v6],
)
