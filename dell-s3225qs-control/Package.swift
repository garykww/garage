// swift-tools-version: 5.9
import PackageDescription

// The repository's Ubuntu CI tests the wire protocol without Apple frameworks.
var targets: [Target] = [
    .target(name: "DisplayProtocol"),
    .testTarget(name: "DisplayControlTests", dependencies: ["DisplayProtocol"])
]
#if os(macOS)
targets += [
    .target(name: "DisplayControl", dependencies: ["DisplayProtocol"],
            linkerSettings: [.linkedFramework("IOKit")]),
    .executableTarget(name: "DellS3225QSControl", dependencies: ["DisplayControl", "DisplayProtocol"])
]
#endif

let package = Package(name: "DellS3225QSControl", platforms: [.macOS(.v13)], targets: targets)
