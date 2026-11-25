# AemberLanguageKit

The SDK for [Aember](https://aember.app)'s language packs, and their
specification. A language pack is one compiled file per language,
`<id>.aemberpack`, that teaches Aember a language: which files are
in it, how to highlight them, which language server to run, which
build systems to detect and which package managers to use.

Aember's own languages (Swift, C and C++ with Objective-C, Rust,
Python, TypeScript and JavaScript, and PHP) are packs too, and their
source is in `Packs/` as complete examples. `Template/` is a pack to
start from.

The API is 0.x: it may change between minor versions until 1.0, and a
pack is built for one minor version (see [Versions](#versions)).

- [Quick start](#quick-start)
- [The pack file](#the-pack-file)
- [Versions](#versions)
- [The pack](#the-pack)
- [Languages](#languages)
- [Language servers](#language-servers)
- [Code graph](#code-graph)
- [Build systems](#build-systems)
- [Build output and reports](#build-output-and-reports)
- [Package managers](#package-managers)
- [Text](#text)
- [How Aember uses packs](#how-aember-uses-packs)
- [This repository](#this-repository)

## Quick start

You need macOS 14 or later, Xcode 16 or later, and Aember.

1. Get `AemberLanguageKit.xcframework`: download it from this
   repository's releases, or build it:

   ```bash
   Scripts/build-xcframework.sh
   ```

   which writes `build/AemberLanguageKit.xcframework`.

2. Copy `Template/` to a folder of your own, named for your language
   (`ZigPack`), and put the xcframework in it. In `Info.plist` and
   `Sources/ExamplePack.swift`, change `example` to your pack's
   identifier, and the names, author and file extensions to yours.

3. Test it, build it and check it, in your pack's folder:

   ```bash
   swift test
   ```

   ```bash
   path/to/AemberLanguageKit/Scripts/build-pack.sh .
   ```

   ```bash
   path/to/AemberLanguageKit/Scripts/check-pack.sh build/zig.aemberpack
   ```

   `check-pack.sh` loads the pack as Aember does and lists what it
   gives.

4. Install it: open the `.aemberpack` file, or drop it on Aember's
   Settings ▸ Languages. Aember asks you to allow a pack that BitArts
   didn't sign, then loads it.

To highlight the language, add its tree-sitter grammar (see
[Grammar and queries](#grammar-and-queries)).

## The pack file

A pack is a Mach-O dynamic library named `<id>.aemberpack`, where
`<id>` is its identifier. It holds:

- **An Info.plist**, embedded in its `__TEXT,__info_plist` section
  (link with `-sectcreate __TEXT __info_plist Info.plist`). Aember
  reads it without running the pack, so it can list a pack it won't
  load. Its keys:

  | Key | | |
  |---|---|---|
  | `AemberPackID` | required | The identifier: lowercase, no spaces, stable across versions (`zig`, `c-family`). The file is named for it. |
  | `AemberPackName` | required | The name shown in Settings. |
  | `CFBundleShortVersionString` | required | The pack's version, `major.minor.patch`. |
  | `AemberPackAPIVersion` | required | The SDK version it was built for (`0.2`). |
  | `CFBundleIdentifier` | required | Its code signing identifier (`com.example.aember.pack.zig`). Aember checks that the signature's identifier matches. |
  | `AemberPackDescription` | | One line about it. |
  | `AemberPackLanguages` | | The names of its languages, for Settings. |
  | `AemberPackAuthor` | | Who made it. |

- **One exported C function**, `aember_language_pack`, that returns
  the pack, retained:

  ```swift
  @_cdecl("aember_language_pack")
  public func aemberLanguagePack() -> UnsafeMutableRawPointer {
      LanguagePackAPI.export(ZigPack())
  }
  ```

- **A link to AemberLanguageKit** by its install name,
  `@rpath/AemberLanguageKit.framework/Versions/A/AemberLanguageKit`,
  with the run paths `@executable_path/../Frameworks` and
  `@loader_path/../../Frameworks`. The pack then uses the copy of the
  SDK Aember has loaded, so its types are Aember's. A pack must not
  carry its own copy of the SDK, nor of anything else Aember loads
  (link a grammar's C statically, as the included packs do).

- **Its grammar**, if it has one, compiled in.

Build it for Apple silicon, and for Intel too if you like
(`Scripts/build-pack.sh` builds both). Sign it with your Developer ID
if you have one; Aember shows who signed a pack when it asks whether
to allow it.

`Scripts/build-pack.sh` does all of this for a folder laid out as
`Template/` is:

| | |
|---|---|
| `Info.plist` | the embedded plist |
| `Sources/*.swift` | the pack |
| `Grammar/` | its grammar's C (optional) |
| `<Name>Pack-Bridging-Header.h` | declares the grammar's function to Swift (optional) |
| `Queries/` | its tree-sitter queries (optional) |

## Versions

`LanguagePackAPI.version` is the SDK's version, and a pack's
`AemberPackAPIVersion` says which it was built for. Aember loads a
pack whose major version is its SDK's and whose minor version is no
newer. While the major version is 0, the minor versions must be the
same: 0.x may break between minor versions. Aember lists a pack it
won't load and says why.

The SDK is built with library evolution, so from 1.0 a pack keeps
working in later Aember releases of the same major version.

## The pack

A pack is a class that adopts `LanguagePack` (`LanguagePack.swift`):

```swift
final class ZigPack: LanguagePack {
    let manifest = LanguagePackManifest(id: "zig", name: "Zig", version: LanguagePackVersion(1, 0, 0), summary: "Zig files and zls", author: "You")
    var languages: [LanguageDefinition] { [...] }
    var languageServers: [LanguageServerDefinition] { [...] }
    var buildSystems: [BuildSystemProvider] { [...] }
    var packageBackends: [PackageBackend.Type] { [...] }
    var buildOutputParsers: [BuildOutputParserProvider] { [...] }
    var buildReportReaders: [BuildReportReader] { [...] }
}
```

The manifest's `id` and `version` must be the Info.plist's
`AemberPackID` and `CFBundleShortVersionString`. Everything but the
manifest is optional.

When Aember enables a pack it calls `activate(context:)`, then asks
for its contributions; when it disables the pack it drops them and
calls `deactivate()`. A pack returns the same contributions every
time, and keeps no state that the next enable needs. Its code stays
loaded until Aember quits.

The `LanguagePackContext` gives the pack Aember's version and SDK
version, a log (Aember's, under the pack's name), the pack's settings
(`settings(for: .global)`, property-list values Aember keeps), and
`findExecutable(named:also:)`, which finds a command as Aember finds
builds' and servers' commands: the usual folders, then the login
shell's `PATH`, since an app opened from the Finder has a bare one.

Each contribution has a `ContributionID` (pack, kind, its own id)
that stays the same across versions, so a setting can name one.
Packs are enabled app-wide today: Aember uses the same packs and
contributions in every project. A later Aember may let a project
turn a pack, or one contribution, off for itself; that needs no
change to a pack. `LanguagePackScope` has a `.project(URL)` case for
it, and settings asked for in that scope are already kept for that
project.

## Languages

A `LanguageDefinition` (`LanguageDefinition.swift`) is one language:

| | |
|---|---|
| `id` | Aember's name for it, lowercase (`zig`). |
| `displayName` | The name shown to the user. |
| `extensions` | File extensions, without the dot, any case. |
| `fileNames`, `fileNamePrefixes` | Whole file names (`makefile`), and starts of names (`makefile.`). |
| `shebangInterpreters` | Interpreters in a `#!` line, matched as the start of the name (`python` matches `python3`). |
| `lspLanguageID`, `lspLanguageIDsByExtension` | The language servers' name for it, and for particular extensions where it differs (`mm` is `objective-cpp`). |
| `lineComment`, `blockComment`, `docComment` | For Toggle Comment and the like. |
| `grammar`, `queries`, `inheritsQueriesFrom` | Its tree-sitter grammar and queries. |
| `codeGraph` | How Aember's code graph reads its trees (see [Code graph](#code-graph)). |

A file's language is found by file name, then prefix, extension and
shebang. A language with no grammar or highlights query is
highlighted with Aember's own, where Aember has one.

### Grammar and queries

A pack compiles its tree-sitter grammar in. `Scripts/vendor-grammar.py`
copies a grammar's C sources from a checkout of its repository into
the pack's `Grammar/`, with its LICENSE and the commit, writes a
header for its `tree_sitter_<name>` function and the pack's bridging
header, and copies its highlights query into `Queries/`:

```bash
Scripts/vendor-grammar.py ~/dev/ZigPack ~/src/tree-sitter-zig tree_sitter_zig
```

`Scripts/embed-queries.py` turns `Queries/` into `PackQueries.swift`,
since a pack is one file:

```bash
Scripts/embed-queries.py ~/dev/ZigPack/Queries ~/dev/ZigPack/Sources/PackQueries.swift
```

Then give them to the language:

```swift
grammar: Grammar(tree_sitter_zig, abiVersion: 15),
queries: PackQueries.queries
```

`build-pack.sh` shows the grammar's function to Swift through the
bridging header. For `swift test`, the template's `Package.swift`
makes the grammar a module, `TreeSitterGrammar`, which the pack
imports:

```swift
#if canImport(TreeSitterGrammar)
import TreeSitterGrammar
#endif
```

Aember's tree-sitter reads grammars of ABI versions 13 to 15. A
grammar whose sources are elsewhere than `Grammar/src/parser.c` and
`scanner.c` is built with `build-pack.sh --grammar-source` and
`--header-path`.

Highlights use tree-sitter's usual capture names. Aember colours a
capture by its first part: `keyword`, `type`, `function`, `variable`,
`property`, `field`, `string`, `number`, `float`, `boolean`,
`constant`, `comment`, `operator`, `punctuation`, `tag`,
`attribute`, `label`, `markup`; a few longer names
(`function.call`, `variable.builtin`, `markup.heading`) have colours
of their own. Others are plain text.

## Language servers

A `LanguageServerDefinition` (`LanguageServerDefinition.swift`) is a
server's command, arguments and languages (LSP IDs). Aember starts
one when a file of its languages opens; where several serve a
language, the first installed by `priority`. Aember finds the
executable in `searchDirectories` and as above, and shows
`installGuidance` when it can't. Languages with the same `serverKey`
share one running server per project.

For servers that need more: `locate` finds the executable somewhere
unusual, `accepts` refuses a version that can't serve,
`projectArguments` adds arguments for a project, `prepare` runs before
the server starts, `initializationOptions` are sent with `initialize`,
and `restartTriggers` restart it when the project's compilation
database or build server changes.

## Code graph

Aember keeps an index of each project's declarations, imports and
name uses, from tree-sitter trees: its symbol search, outline and the
codegraph tools agents use read it. The walk is Aember's; a
language's `CodeGraphRules` (`CodeGraphRules.swift`) say how to read
its grammar's trees:

| | |
|---|---|
| `symbols` | Declaration node types and the kind each declares (`"function_item": .function`). A declaration is named by its first identifier. |
| `kindKeywords` | Declarations whose kind a keyword child decides (tree-sitter-swift's `class_declaration` is a class, struct, enum, actor or extension). |
| `nameFields`, `nameChildTypes` | Declarations named by a field (a Rust `impl_item` by its `type`) or by a child's type (Swift's `init_declaration` by its `init`). |
| `namesAreUses` | Declarations whose name is a use of another symbol, still counted as a use. |
| `imports` | Import node types; their text is read as an import. |
| `anonymousFunctions` | Closures and the like: named only by a `name` field, and their variables are locals. |
| `firstDeclarators` | Declarators that are their declaration's own variable when first in it (`const x = 1` is one symbol). |
| `fileScopedModifiers` | Modifiers that keep a declaration to its file, so only uses there keep it alive. |
| `callShapes` | A `CallShapeReader`, for languages whose argument labels choose the function called. |

Functions declared directly in a type are methods, and variables
inside functions are locals, in every language. A language without
rules is read with Aember's own table of common node names, with
none of a language's special cases.

A `CallShapeReader` reads a call node (through `SyntaxNode`, Aember's
node as a pack sees it) into the name called and its shape, and says
whether a call of a shape could call a declaration with a given
signature; the code graph's dead-code search then counts a function
as used only by calls it accepts. The Swift pack's
`SwiftCallShapeReader` reads Swift's argument labels and trailing
closures, so `file(at:)` doesn't keep `file(named:)` alive. Each
included pack's `PackCodeGraph.swift` gives its rules.

## Build systems

A build system (`BuildSystem.swift`) is a type adopting
`DetectableBuildSystem`: it detects itself in a project's root, names
its build files, gives the commands for Build and Test unless the
project's `.aember/build.json` does, and may write what the language
servers need (a compilation database). A pack lists a
`BuildSystemProvider` for each, with a priority: lower is asked
first. Aember's: SwiftPM 100, Cargo 200, CMake 300, Ninja 400, Xcode
500, Make 600, TypeScript 700, Python 800, PHP 900.

Commands get a `BuildSystemContext`; its `toolPath(_:)` lets tests
give fake tools, and is nil in Aember. The project's
`.aember/<identifier>-env` files set the commands' environment
(`BuildEnvironmentLoader`). The PHP pack's `ComposerBuildSystem` is
the smallest; the C Family pack's CMake, Ninja and Make write
compilation databases.

A command can name the report it writes and its format
(`BuildCommand.report`, a `BuildReportFile`): `junit` for JUnit XML,
which Aember reads, or the identifier of a pack's
`BuildReportReader`.

## Build output and reports

Aember reads a run's console output into diagnostics and test
results (`BuildRecords.swift`), and shows them in its build results.
It reads the formats many tools share itself: compiler lines
(`path:line:column: error|warning|note: message`), ld's undefined
symbols, and lines like `error: message` without a place. A pack
reads its tools' own formats with a `BuildOutputParser`:

- Aember makes a fresh parser from each enabled pack's
  `BuildOutputParserProvider` for every run, and hands each line,
  without colours or carriage returns, to a parser reading a block
  (`isReadingBlock`, such as a test's failure details) first, then to
  every pack's parsers in pack order, then to its own. The first that
  takes the line (returns true) ends its turn, so a parser takes only
  lines it is sure are its tool's, and can take a tool's summaries to
  drop them.
- A parser records diagnostics (`add`, `addNoteToLast`,
  `placeLast`) and test results (`record`, `appendToMessage`) in the
  run's `BuildRecords`; test names should be the ones the build
  system's test filter takes. `LinePattern` matches a regular
  expression against a line.

After a run, its command's report is read: diagnostics from a report
replace the console's only when the console gave none, and tests from
a report replace the console's. A `BuildReportReader` reads one
format, by identifier.

The Rust pack reads Cargo's JSON messages, rustc's places and cargo
test; the TypeScript pack, tsc; the Swift pack, XCTest and Swift
Testing, and Xcode's result bundles (`xcresult`).

## Package managers

A `PackageBackend` (`PackageBackend.swift`) is one package manager's
view of one manifest: it finds the manifest in a folder, checks its
tool, reads the dependency graph without the network, makes the
commands for changes (add, remove, update), checks for newer versions
(`PackageCheck.swift`), and can search a registry
(`PackageSearch.swift`). Its tools run through a `PackageToolRunner`,
which tests replace. The Rust pack's Cargo backend is the simplest
complete one.

## Text

Text a pack shows is `LocalizedText`: English, and translations by
language code; Aember shows the user's language. A string literal is
English only. The included packs keep their text in
`Strings.xcstrings` and generate Swift from it with
`Scripts/pack-strings.py`; a pack can do the same, or write its
`LocalizedText` by hand.

## How Aember uses packs

Aember reads packs from `Aember.app/Contents/PlugIns/LanguagePacks`
(its own) and `~/Library/Application Support/Aember/LanguagePacks`
(installed). Where both have a pack's identifier, the newer version
is used. Where two packs give the same language, extension, server,
build system or package manager, the pack first by identifier wins.

Aember runs its own packs and packs signed by BitArts. Any other pack
waits until the user allows it, after Aember names who signed it;
Aember remembers the decision by the pack's code hash, so a new build
asks again. A pack with a broken signature isn't loaded.

The user can turn a pack off, and its languages are then highlighted
with Aember's own definitions, where it has them. Replacing or
removing a pack in use takes effect when Aember restarts.

BitArts' catalog, from which Aember installs and updates packs, has
BitArts' packs only. Share yours as the `.aemberpack` file.

## This repository

| | |
|---|---|
| `Sources/AemberLanguageKit/` | The SDK. `LanguagePackAPI.swift`: versions, the entry point and Info.plist keys. `LanguagePack.swift`: the pack, its context and scopes. `LanguageDefinition.swift`, `LanguageServerDefinition.swift`, `CodeGraphRules.swift`. `BuildSystem.swift` and the compilation database types; `BuildRecords.swift`, output parsers and report readers. `PackageModel.swift`, `PackageBackend.swift`, `PackageSearch.swift`, `PackageCheck.swift`. `LocalizedText.swift`, `ToolLocations.swift` (where npm and Cargo install tools), `ExecutableFinder.swift`, `BuildEnvironmentLoader.swift`. |
| `Packs/<Name>/` | The packs Aember includes: PHP, Python, Rust, TypeScript, C Family and Swift. |
| `Template/` | A pack to start from, with its own `Package.swift` for its tests. |
| `Scripts/` | `build-xcframework.sh`, `build-pack.sh`, `check-pack.sh`, `vendor-grammar.py`, `embed-queries.py`, `pack-strings.py`. |
| `Tests/` | The SDK's tests, and `PackTestSupport`, which the included packs' tests share. |

The SDK is one dynamic library built with library evolution, in Swift
5 mode for now. It has no `NSLocalizedString`: Aember words its own
messages, and a pack's text is `LocalizedText`.

Each included pack is also a target of this package, with its grammar
as a C target (`TreeSitter<Name>`) and its tests (`<Name>PackTests`);
their entry points are left out of these builds (`#if
!SWIFT_PACKAGE`), so they link into one test bundle. Aember builds
the `.aemberpack` files, one Xcode target each.

```bash
swift build
```

```bash
swift test
```

## License

AemberLanguageKit, the included packs' code and the template are
under the MIT License (`LICENSE`). The tree-sitter grammars and
runtime in `Packs/*/Grammar/` are their authors', under the licenses
beside them (`LICENSE`, with the upstream repository and commit in
`SOURCE`). A pack you write is yours, under whatever license you
choose.
