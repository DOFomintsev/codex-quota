// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexQuota",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "CodexQuota", targets: ["CodexQuota"])],
    targets: [.executableTarget(name: "CodexQuota")]
)
