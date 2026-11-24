# AemberLanguageKit

The SDK for Aember's language packs: one compiled file per language
(`<id>.aemberpack`) that gives Aember what it needs to support the
language: file types, its tree-sitter grammar and queries, language
servers, build systems and package managers.

The specification, the pack template and the included packs' sources
come as the SDK settles; the plan is Aember's
`plans-todo/language-packs.md`. Private until the specification
settles, then published on BitArts' GitHub organization.

```bash
swift build
swift test
```
