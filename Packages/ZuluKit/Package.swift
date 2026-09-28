// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ZuluKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "ZulipAPI", targets: ["ZulipAPI"]),
        .library(name: "ZuluCompose", targets: ["ZuluCompose"]),
        .library(name: "ZuluEmoji", targets: ["ZuluEmoji"]),
        .library(name: "ZuluMarkup", targets: ["ZuluMarkup"]),
        .library(name: "ZuluPolls", targets: ["ZuluPolls"]),
        .library(name: "ZuluScroll", targets: ["ZuluScroll"]),
        .library(name: "ZuluStore", targets: ["ZuluStore"]),
        .library(name: "ZuluSync", targets: ["ZuluSync"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
    ],
    targets: [
        .target(name: "ZulipAPI"),
        .target(name: "ZuluEmoji"),
        .target(name: "ZuluCompose", dependencies: ["ZuluEmoji"]),
        .target(name: "ZuluMarkup"),
        .target(name: "ZuluPolls"),
        .target(name: "ZuluScroll"),
        .target(name: "ZuluStore", dependencies: [
            "ZulipAPI",
            "ZuluEmoji",
            .product(name: "GRDB", package: "GRDB.swift"),
        ]),
        .target(name: "ZuluSync", dependencies: ["ZulipAPI", "ZuluEmoji", "ZuluStore"]),
        // ZuluMarkup so quote-and-reply can be asserted against the parser that reads it
        // back out, rather than against a transcription of what that parser expects.
        .testTarget(name: "ZuluComposeTests", dependencies: ["ZuluCompose", "ZuluMarkup"]),
        .testTarget(name: "ZuluEmojiTests", dependencies: ["ZuluEmoji"]),
        .testTarget(name: "ZulipAPITests", dependencies: ["ZulipAPI"]),
        .testTarget(name: "ZuluStoreTests", dependencies: ["ZuluStore", "ZulipAPI", "ZuluEmoji"]),
        .testTarget(name: "ZuluMarkupTests", dependencies: ["ZuluMarkup"]),
        .testTarget(name: "ZuluPollsTests", dependencies: ["ZuluPolls"]),
        .testTarget(name: "ZuluScrollTests", dependencies: ["ZuluScroll"]),
        .testTarget(name: "ZuluSyncTests", dependencies: ["ZuluSync", "ZuluStore"]),
    ]
)
