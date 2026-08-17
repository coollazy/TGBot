// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TGBot",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "TGBot", targets: ["TGBot"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0")
    ],
    targets: [
        .target(
            name: "TGBotTransport",
            dependencies: [
                .product(name: "Logging", package: "swift-log")
            ]
        ),
        .target(
            name: "TGBotAccessControl"
        ),
        .target(
            name: "TGBotConversation",
            dependencies: [
                "TGBotTransport",
                .product(name: "Logging", package: "swift-log")
            ]
        ),
        .target(
            name: "TGBotBackgroundTask",
            dependencies: [
                "TGBotConversation"
            ]
        ),
        .target(
            name: "TGBot",
            dependencies: [
                "TGBotTransport",
                "TGBotAccessControl",
                "TGBotConversation",
                "TGBotBackgroundTask",
                .product(name: "Logging", package: "swift-log")
            ]
        ),
        .testTarget(
            name: "TGBotConversationTests",
            dependencies: ["TGBotConversation", "TGBotTransport"]
        ),
        .testTarget(
            name: "TGBotTransportTests",
            dependencies: ["TGBotTransport"]
        ),
        .testTarget(
            name: "TGBotAccessControlTests",
            dependencies: ["TGBotAccessControl"]
        ),
        .testTarget(
            name: "TGBotBackgroundTaskTests",
            dependencies: ["TGBotBackgroundTask", "TGBotConversation"]
        )
    ]
)
