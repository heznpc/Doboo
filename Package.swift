// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "Doboo",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "DobooCore", targets: ["DobooCore"])
  ],
  targets: [
    .target(
      name: "DobooCore",
      path: "Sources/Core"
    ),
    .testTarget(
      name: "DobooTests",
      dependencies: ["DobooCore"],
      path: "Tests"
    ),
  ]
)
