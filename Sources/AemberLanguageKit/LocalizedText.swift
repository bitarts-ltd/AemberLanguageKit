/**
    @file LocalizedText.swift
    @author Warren Mann
    @copyright
    Copyright © 2026 BitArts, Ltd (warren@bitarts.us). MIT License: see LICENSE.
    @brief
    Text a pack shows the user, in each language it is translated into.
    @details
    A pack is one file and can't carry .lproj folders, so its
    user-visible text is a LocalizedText: English, which every text
    has, and the translations the pack has, by language code ("de",
    "pt-BR"). Aember picks the one for the user's preferred languages.
*/

import Foundation

/// @brief Text in English and the languages it is translated into.
public struct LocalizedText: Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {

    /// The English text
    public var english: String

    /// Translations by language code ("de", "ja", "pt-BR")
    public var translations: [String: String]

    /// @brief Text with its translations.
    /// @param english The English text
    /// @param translations Translations by language code
    /// @return The text
    public init(_ english: String, translations: [String: String] = [:]) {
        self.english = english
        self.translations = translations
    }

    /// @brief English text, with no translations.
    /// @param value The text
    /// @return The text
    public init(stringLiteral value: String) {
        self.init(value)
    }

    /// @brief The text for the first of the preferred languages it has.
    /// @details
    /// A language with a region ("pt-BR") falls back to its language
    /// ("pt") before the next preference; English is the last resort.
    /// @param preferredLanguages Language codes, most preferred first
    /// @return The text
    public func resolved(for preferredLanguages: [String]) -> String {
        for code in preferredLanguages {
            if code.hasPrefix("en") {
                return english
            }
            if let text = translations[code] {
                return text
            }
            let base = String(code.prefix { $0 != "-" && $0 != "_" })
            if base == "en" {
                return english
            }
            if let text = translations[base] {
                return text
            }
        }
        return english
    }

    /// @brief The text in the app's preferred localizations.
    /// @return The text
    public var localized: String {
        resolved(for: Bundle.main.preferredLocalizations + Locale.preferredLanguages)
    }

    /// @brief The localized text.
    /// @return The text
    public var description: String {
        localized
    }
}
