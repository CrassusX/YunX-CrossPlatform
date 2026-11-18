// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "YunXMac",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "YunXMac", targets: ["YunXMac"])
    ],
    targets: [
        .executableTarget(
            name: "YunXMac",
            path: "Sources/YunXMac"
        )
    ]
)
