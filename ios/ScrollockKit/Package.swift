// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "ScrollockKit",
  platforms: [.iOS(.v17), .macOS(.v14)],
  products: [.library(name: "ScrollockKit", targets: ["ScrollockKit"])],
  targets: [
    .target(name: "ScrollockKit"),
    .testTarget(name: "ScrollockKitTests", dependencies: ["ScrollockKit"]),
  ]
)
