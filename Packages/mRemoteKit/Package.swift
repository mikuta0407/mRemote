// swift-tools-version: 6.0
import PackageDescription

// The product app is an Xcode project; this package holds the layers that do
// not need UIKit, so they can be built and tested on the development host
// without a Simulator. The module boundaries follow docs/architecture.md,
// section 3: dependencies point downwards only, and nothing here may import a
// protocol implementation.
let package = Package(
    name: "mRemoteKit",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "SessionCore", targets: ["SessionCore"]),
        .library(name: "Persistence", targets: ["Persistence"]),
        .library(name: "AppleAdapters", targets: ["AppleAdapters"]),
        .library(name: "RDPProtocol", targets: ["RDPProtocol"]),
        .library(name: "InputCore", targets: ["InputCore"]),
        .library(name: "SSHProtocol", targets: ["SSHProtocol"]),
    ],
    targets: [
        .target(name: "SessionCore"),
        .target(name: "Persistence", dependencies: ["SessionCore"]),
        .target(
            name: "AppleAdapters",
            dependencies: ["SessionCore"],
            linkerSettings: [.linkedFramework("Security")]
        ),
        // Everything about the RDP session that does not need FreeRDP itself:
        // the status/error vocabulary of the C bridge, certificate evaluation
        // and the review policy. The XCFramework is linked by the Xcode app
        // target rather than declared here as a binaryTarget, because
        // `artifacts/` is generated and ignored, and a binaryTarget would make
        // the whole package - including `swift test` - unresolvable wherever
        // it has not been built.
        .target(
            name: "RDPProtocol",
            dependencies: ["SessionCore"],
            linkerSettings: [.linkedFramework("Security")]
        ),
        // Pointer and, in Phase 3, keyboard normalisation: pressed state,
        // scroll quantisation and the local-to-remote mapping. It holds no
        // protocol mapping, so a scan code never appears here.
        .target(name: "InputCore", dependencies: ["SessionCore"]),
        // docs/ssh-design.md section 4: everything about SSH that does not
        // need libssh2 - the sign-in policy, the failure vocabulary of the C
        // bridge, host key fingerprints, key files and the bytes a key sends.
        // The session adapter that drives the bridge is in App/SSH/.
        .target(name: "SSHProtocol", dependencies: ["SessionCore"]),
        .testTarget(name: "SessionCoreTests", dependencies: ["SessionCore"]),
        .testTarget(name: "PersistenceTests", dependencies: ["Persistence"]),
        .testTarget(name: "AppleAdaptersTests", dependencies: ["AppleAdapters"]),
        .testTarget(name: "RDPProtocolTests", dependencies: ["RDPProtocol"]),
        // RDPProtocol only to check that every on-screen key has a scan code.
        .testTarget(name: "InputCoreTests", dependencies: ["InputCore", "RDPProtocol"]),
        .testTarget(name: "SSHProtocolTests", dependencies: ["SSHProtocol"]),
    ]
)
