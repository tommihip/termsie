// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Termsie",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", .upToNextMinor(from: "1.20.0")),
    ],
    targets: [
        .executableTarget(
            name: "Termsie",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            path: "Sources/Termsie",
            swiftSettings: [
                .unsafeFlags(["-Onone"], .when(configuration: .debug)),
            ]
        ),
    ]
)
