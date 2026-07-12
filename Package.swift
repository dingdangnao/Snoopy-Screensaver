// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SnoopyTVScreenSaver",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SnoopyTVCore", targets: ["SnoopyTVCore"]),
        .executable(name: "SnoopySequenceProxyBuilder", targets: ["SnoopySequenceProxyBuilder"])
    ],
    targets: [
        .target(name: "SnoopyTVCore"),
        .executableTarget(name: "SnoopySequenceProxyBuilder", dependencies: ["SnoopyTVCore"]),
        .testTarget(name: "SnoopyTVCoreTests", dependencies: ["SnoopyTVCore"])
    ]
)
