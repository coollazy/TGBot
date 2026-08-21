// swift-tools-version: 6.0
import PackageDescription

/// 獨立的 SwiftPM 專案，用 local path 依賴上一層的 TGBot library，
/// 模擬真正外部開發者「拿到 TGBot 這個 package 之後怎麼用」的情境
/// ——而不是把範例塞進 TGBot 自己的 Package.swift 裡當一個 target
/// （那樣同一個 package 內的 target 彼此可以互相 import，會掩蓋掉
/// 「單獨 import TGBot 到底夠不夠用」這個問題）。
let package = Package(
    name: "EchoBotExample",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(path: "..")
    ],
    targets: [
        .executableTarget(
            name: "EchoBotExample",
            dependencies: [
                .product(name: "TGBot", package: "TGBot")
            ]
        ),
        // 示範「外部開發者怎麼幫自己的 bot 寫離線單元測試」：只 import TGBot（跟
        // EchoBotExample 本身一樣，不用 @testable），直接依賴 EchoBotExample 本身
        // 去測 makeUploadScene() 這個真正的 scene，不是另外掰一個玩具範例。
        .testTarget(
            name: "EchoBotExampleTests",
            dependencies: [
                "EchoBotExample",
                .product(name: "TGBot", package: "TGBot")
            ]
        )
    ]
)
