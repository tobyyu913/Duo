// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Duo",
    platforms: [.macOS("15.0")],
    targets: [
        .executableTarget(
            name: "Duo",
            path: "Sources/Duo",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
