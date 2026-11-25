#!/bin/zsh
#
# Builds a language pack from its folder: <id>.aemberpack.
#
# Usage: Scripts/build-pack.sh <pack folder> [options]
#
#   --framework PATH       AemberLanguageKit.xcframework (default: the
#                          pack folder's, else build/ in this repository,
#                          from Scripts/build-xcframework.sh)
#   --output DIR           Where to write the pack (default: <pack folder>/build)
#   --archs "A B"          Architectures (default: "arm64 x86_64")
#   --grammar-source FILE  A grammar C file, relative to the pack folder;
#                          repeat for each (default: Grammar/src/parser.c
#                          and Grammar/src/scanner.c, those that exist)
#   --header-path DIR      A folder the grammar includes headers from,
#                          relative to the pack folder; repeat for each
#                          (default: Grammar/src, if it exists)
#   --sign IDENTITY        Code signing identity (default: "-", ad hoc;
#                          Aember asks before running a pack that isn't
#                          signed by BitArts either way)
#
# The folder is laid out as the template and the included packs are:
#
#   Info.plist                  embedded in the pack's __TEXT,__info_plist
#   Sources/*.swift             the pack, with its aember_language_pack
#                               entry point
#   Grammar/                    optional: the tree-sitter grammar's C
#   *-Bridging-Header.h         optional: declares the grammar's
#                               tree_sitter_<name> function to Swift
#
# The pack links AemberLanguageKit by its install name and looks for it
# where Aember keeps it, so it uses the copy Aember has loaded.

set -euo pipefail

ROOT=${0:A:h:h}
FRAMEWORK=$ROOT/build/AemberLanguageKit.xcframework
ARCHS=(arm64 x86_64)
SIGN=-
OUTPUT=
GRAMMAR_SOURCES=()
HEADER_PATHS=()
MIN_MACOS=14.0

usage() {
    sed -n '3,30p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
}

[[ $# -ge 1 ]] || usage
PACK=${1:A}
shift
while [[ $# -gt 0 ]]; do
    case $1 in
        --framework) FRAMEWORK=${2:A}; shift 2 ;;
        --output) OUTPUT=$2; shift 2 ;;
        --archs) ARCHS=(${=2}); shift 2 ;;
        --grammar-source) GRAMMAR_SOURCES+=($2); shift 2 ;;
        --header-path) HEADER_PATHS+=($2); shift 2 ;;
        --sign) SIGN=$2; shift 2 ;;
        *) usage ;;
    esac
done

[[ $FRAMEWORK == $ROOT/build/AemberLanguageKit.xcframework && -d $PACK/AemberLanguageKit.xcframework ]] && FRAMEWORK=$PACK/AemberLanguageKit.xcframework
PLIST=$PACK/Info.plist
[[ -f $PLIST ]] || { echo "error: $PLIST is missing" >&2; exit 1 }
[[ -d $PACK/Sources ]] || { echo "error: $PACK/Sources is missing" >&2; exit 1 }
SLICE=$FRAMEWORK/macos-arm64_x86_64
[[ -d $SLICE/AemberLanguageKit.framework ]] \
    || { echo "error: no AemberLanguageKit.xcframework at $FRAMEWORK; build it with Scripts/build-xcframework.sh or download it from the repository's releases" >&2; exit 1 }

ID=$(/usr/libexec/PlistBuddy -c 'Print :AemberPackID' "$PLIST" 2>/dev/null) \
    || { echo "error: Info.plist has no AemberPackID" >&2; exit 1 }
for key in CFBundleIdentifier CFBundleShortVersionString AemberPackName AemberPackAPIVersion; do
    /usr/libexec/PlistBuddy -c "Print :$key" "$PLIST" >/dev/null 2>&1 \
        || { echo "error: Info.plist has no $key" >&2; exit 1 }
done

# The module is named for the pack (Example becomes ExamplePack, C
# Family CFamilyPack), as the included packs' are
MODULE=$(/usr/libexec/PlistBuddy -c 'Print :AemberPackName' "$PLIST")
MODULE=${MODULE//[^A-Za-z0-9_]/}Pack

OUTPUT=${OUTPUT:-$PACK/build}
mkdir -p "$OUTPUT"
OUTPUT=${OUTPUT:A}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

if [[ ${#GRAMMAR_SOURCES} -eq 0 ]]; then
    for file in Grammar/src/parser.c Grammar/src/scanner.c; do
        [[ -f $PACK/$file ]] && GRAMMAR_SOURCES+=($file)
    done
fi
if [[ ${#HEADER_PATHS} -eq 0 && -d $PACK/Grammar/src ]]; then
    HEADER_PATHS=(Grammar/src)
fi
INCLUDES=()
for dir in $HEADER_PATHS; do
    INCLUDES+=(-I "$PACK/$dir")
done

BRIDGING=($PACK/*-Bridging-Header.h(N))
IMPORT_HEADER=()
if [[ ${#BRIDGING} -gt 0 ]]; then
    IMPORT_HEADER=(-import-objc-header "${BRIDGING[1]}")
fi

SOURCES=($PACK/Sources/**/*.swift(N))
# A pack's own package (Package.swift, Tests/) isn't part of the pack
[[ ${#SOURCES} -gt 0 ]] || { echo "error: no Swift files in $PACK/Sources" >&2; exit 1 }

SLICES=()
for arch in $ARCHS; do
    echo "Building $ID for $arch..."
    OBJECTS=()
    for source in $GRAMMAR_SOURCES; do
        object=$WORK/$arch-${${source//\//-}%.c}.o
        clang -c -O2 -arch "$arch" -mmacosx-version-min=$MIN_MACOS -Wno-unused-parameter $INCLUDES "$PACK/$source" -o "$object"
        OBJECTS+=($object)
    done
    swiftc -emit-library -O -swift-version 5 \
        -module-name "$MODULE" \
        -target "$arch-apple-macos$MIN_MACOS" \
        -F "$SLICE" -framework AemberLanguageKit \
        $IMPORT_HEADER $INCLUDES \
        $SOURCES $OBJECTS \
        -Xlinker -install_name -Xlinker "@rpath/$ID.aemberpack" \
        -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$PLIST" \
        -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
        -Xlinker -rpath -Xlinker @loader_path/../../Frameworks \
        -o "$WORK/$ID-$arch.aemberpack"
    SLICES+=($WORK/$ID-$arch.aemberpack)
done

PRODUCT=$OUTPUT/$ID.aemberpack
rm -f "$PRODUCT"
lipo -create $SLICES -output "$PRODUCT"
codesign --force --timestamp=none --sign "$SIGN" --identifier "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")" "$PRODUCT"

echo "Built $PRODUCT ($(lipo -archs "$PRODUCT"))"
