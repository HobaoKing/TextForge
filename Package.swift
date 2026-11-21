// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "TextForge",
    platforms: [.iOS(.v15)],
    products: [.library(name: "TextForge", targets: ["TextForge"])],
    targets: [.target(name: "TextForge", linkerSettings: [.linkedFramework("WebKit")])]
)
