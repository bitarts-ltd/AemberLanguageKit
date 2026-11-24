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
- `ToolLocations.swift`: where tools install themselves (npm's global
  folders, Cargo's)
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

## Included packs

`Packs/<Name>/` holds the source of each pack Aember includes, which
are also the examples of a pack:

- `Sources/`: the pack (`<Name>Pack.swift`, with its
  `aember_language_pack` entry point) and the generated
  `PackQueries.swift` and `PackStrings.swift`
- `Grammar/`: the tree-sitter grammar's C sources, as they are
  upstream, with its LICENSE, SOURCE (repository and commit) and a
  header declaring its `tree_sitter_<name>` function
- `Queries/`: its tree-sitter queries (highlights.scm, ...)
- `Strings.xcstrings`: its text and translations
- `Info.plist`: embedded in the pack's `__TEXT,__info_plist`
- `<Name>Pack-Bridging-Header.h`: lets the Swift see the grammar

Aember builds them, one target each (see Aember's
`Aember/LanguagePacks/README.md`). Included so far: PHP, Python,
Rust and TypeScript.

Each pack is also a target here: its grammar a C target
(TreeSitter<Name>), its code <Name>Pack, its tests <Name>PackTests
(Tests/, with Fixtures/ beside them), run by `swift test`. The tests
share Tests/PackTestSupport. `Scripts/vendor-grammar.py` copies a
grammar in and sets up a pack's folder.

`Scripts/embed-queries.py` writes a pack's `PackQueries.swift` from its
Queries folder.

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
