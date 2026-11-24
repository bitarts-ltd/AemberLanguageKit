# AemberLanguageKit

The SDK for Aember's language packs: one compiled file per language
(`<id>.aemberpack`) that gives Aember what it needs to support the
language: file types, its tree-sitter grammar and queries, language
servers, build systems and package managers.

Private until the specification settles, then published on BitArts'
GitHub organization. The plan is Aember's
`plans-todo/language-packs.md`; how Aember loads packs is Aember's
`Aember/LanguagePacks/README.md`.

## Contents

- `LanguagePackAPI.swift`: `LanguagePackVersion`, `LanguagePackAPI`
  (the API version, compatibility, the `aember_language_pack` entry
  point's `export`/`take`), `LanguagePackInfoKey` (the embedded
  Info.plist's keys)
- `LanguagePack.swift`: the `LanguagePack` protocol, its manifest,
  `LanguagePackScope`, `ContributionID`, `LanguagePackContext`,
  `LanguagePackSettings`
- `LanguageDefinition.swift`, `LanguageServerDefinition.swift`:
  languages (files, LSP IDs, grammar, queries) and language servers
- `LocalizedText.swift`: text with its translations
- `BuildSystem.swift`: the `BuildSystem` protocol, providers and
  commands
- `PackageModel.swift`, `PackageBackend.swift`, `PackageSearch.swift`,
  `PackageCheck.swift`: package managers: the dependency graph, the
  backend protocol, searching and checking for updates

The library is dynamic and built with library evolution. Aember
embeds it and a pack links the copy Aember loaded; third-party packs
will link a published xcframework. It is in Swift 5 mode for now.
The SDK holds no NSLocalizedString: Aember words its own messages,
and a pack's text is LocalizedText.

## Pack strings

`Scripts/pack-strings.py` keeps a pack's text in its own
`Strings.xcstrings`: `seed` copies keys and translations from
another catalog (Aember's), `generate` writes a `PackStrings` enum
of LocalizedText, and `check` fails on a key the catalog lacks or a
missing translation. See its docstring.

```bash
swift build
swift test
```
