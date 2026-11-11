// swift-tools-version: 6.0
import PackageDescription

// Two library products and no executable target of any kind: the runnable app
// lives in the separate ai-attachment-plane-demo-app repository and consumes
// this package as a version-pinned remote dependency.
//
// - AttachmentPlane: the core. Foundation only, no Apple-only imports, so it
//   builds and is tested on Linux too.
// - AttachmentPlaneUI: a SwiftUI console that drives the core against the
//   simulated file service. Compiles to nothing where SwiftUI is unavailable.
let package = Package(
    name: "AttachmentPlaneKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "AttachmentPlane", targets: ["AttachmentPlane"]),
        .library(name: "AttachmentPlaneUI", targets: ["AttachmentPlaneUI"]),
    ],
    targets: [
        .target(name: "AttachmentPlane"),
        .target(name: "AttachmentPlaneUI", dependencies: ["AttachmentPlane"]),
        .testTarget(name: "AttachmentPlaneTests", dependencies: ["AttachmentPlane"]),
    ]
)
