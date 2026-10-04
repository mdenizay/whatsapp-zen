// swift-tools-version:5.9
import Foundation
import PackageDescription

// The Go core is built into core/build/libwacore.a by build.sh (or by hand);
// point the linker at it so the package also builds from Xcode.
let coreLib = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("../core/build").standardized.path

let package = Package(
    name: "WhatsAppZen",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "CWACore", path: "Sources/CWACore"),
        .executableTarget(
            name: "WhatsAppZen",
            dependencies: ["CWACore"],
            path: "Sources/WhatsAppZen",
            linkerSettings: [
                .unsafeFlags(["-L\(coreLib)"]),
                .linkedLibrary("wacore"),
                .linkedLibrary("resolv"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Security"),
            ]
        ),
    ]
)
