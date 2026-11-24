// swift-tools-version: 6.0
/**
    @file Package.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us) All rights reserved.
    @brief
    AemberLanguageKit: the SDK Aember's language packs are written with.
    @details
    One dynamic library, built with library evolution, so a pack built
    against an older SDK still loads in a newer Aember: Aember embeds
    the framework and a pack links the copy Aember already loaded.
    Aember and its included packs build it from source; third-party
    packs link the published AemberLanguageKit.xcframework, which has
    the same install name.
*/

import PackageDescription

let package = Package(
    name: "AemberLanguageKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "AemberLanguageKit",
            type: .dynamic,
            targets: ["AemberLanguageKit"]
        )
    ],
    targets: [
        .target(
            name: "AemberLanguageKit",
            swiftSettings: [
                .unsafeFlags(["-enable-library-evolution"]),
                // The build and package code came from Aember, which is
                // in Swift 5 mode; strict concurrency comes once the
                // API settles
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "AemberLanguageKitTests",
            dependencies: ["AemberLanguageKit"]
        )
    ]
)
