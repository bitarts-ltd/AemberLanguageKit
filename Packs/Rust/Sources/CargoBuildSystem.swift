/**
    @file CargoBuildSystem.swift
    @author Warren Mann
    @copyright Copyright © 2026 BitArts, Ltd (warren@bitarts.us) All rights reserved.
    @brief Rust's Cargo as a build system.
    @details
    A project with a Cargo.toml in its root. It builds with `cargo build
    --message-format=json` and tests with `cargo test [F]`;
    rust-analyzer reads Cargo.toml itself.
*/

import Foundation
import AemberLanguageKit

/// @brief A Cargo package or workspace
struct CargoBuildSystem: DetectableBuildSystem {

    static let identifier = "cargo"

    var displayName: String {
        PackStrings.text("Cargo").localized
    }

    var buildFiles: [String] {
        ["Cargo.toml"]
    }

    static func detect(in projectRoot: URL) -> CargoBuildSystem? {
        let system = CargoBuildSystem()
        return system.buildFileURL(in: projectRoot) != nil ? system : nil
    }

    func command(for action: BuildAction, in projectRoot: URL, config: BuildProjectConfig?, filter: String?, outputDirectory: URL, context: any BuildSystemContext) throws -> BuildCommand {
        if action == .build {
            return single("cargo", ["build", "--message-format=json"])
        }
        return single("cargo", ["test"] + (filter.map { [$0] } ?? []))
    }
}
