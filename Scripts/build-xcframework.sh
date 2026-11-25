#!/bin/zsh
#
# Builds AemberLanguageKit.xcframework, the SDK third-party packs link.
#
# Usage: Scripts/build-xcframework.sh [output folder]
#
# The framework is the same library Aember embeds, built for Apple
# silicon and Intel with library evolution, with the same install name
# (@rpath/AemberLanguageKit.framework/Versions/A/AemberLanguageKit), so
# a pack linking it uses the copy Aember has loaded. Its module is
# described by .swiftinterface files only, which any later Swift
# compiler reads; a compiled .swiftmodule would tie packs to this one.
#
# Writes <output>/AemberLanguageKit.xcframework and a zip of it beside
# it, for the repository's releases. The output folder defaults to
# build/ in the repository.

set -euo pipefail

ROOT=${0:A:h:h}
OUT=${1:-$ROOT/build}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$OUT"
OUT=${OUT:A}

echo "Archiving AemberLanguageKit..."
cd "$ROOT"
xcodebuild archive -quiet \
    -scheme AemberLanguageKit \
    -destination 'generic/platform=macOS' \
    -archivePath "$WORK/AemberLanguageKit.xcarchive" \
    -derivedDataPath "$WORK/DerivedData" \
    SKIP_INSTALL=NO BUILD_LIBRARY_FOR_DISTRIBUTION=YES

FRAMEWORK="$WORK/AemberLanguageKit.xcarchive/Products/usr/local/lib/AemberLanguageKit.framework"
INTERFACES="$WORK/DerivedData/Build/Intermediates.noindex/ArchiveIntermediates/AemberLanguageKit/BuildProductsPath/Release/AemberLanguageKit.swiftmodule"
[[ -d $FRAMEWORK ]] || { echo "error: the archive has no framework at $FRAMEWORK" >&2; exit 1 }
[[ -d $INTERFACES ]] || { echo "error: no module interfaces at $INTERFACES" >&2; exit 1 }

# A package's framework comes without its module; add the interfaces
# (public and private, not the package ones, which only the package's
# own targets may use) and the docs
MODULE="$FRAMEWORK/Versions/A/Modules/AemberLanguageKit.swiftmodule"
mkdir -p "$MODULE"
for file in "$INTERFACES"/*.swiftinterface(N) "$INTERFACES"/*.swiftdoc(N) "$INTERFACES"/*.abi.json(N); do
    [[ ${file:t} == *.package.swiftinterface ]] && continue
    cp "$file" "$MODULE/"
done
ln -sfh Versions/Current/Modules "$FRAMEWORK/Modules"
ls "$MODULE"/*.swiftinterface >/dev/null

INSTALL_NAME=$(otool -D "$FRAMEWORK/AemberLanguageKit" | tail -1)
[[ $INSTALL_NAME == "@rpath/AemberLanguageKit.framework/Versions/A/AemberLanguageKit" ]] \
    || { echo "error: unexpected install name $INSTALL_NAME" >&2; exit 1 }

echo "Creating the xcframework..."
rm -rf "$OUT/AemberLanguageKit.xcframework" "$OUT/AemberLanguageKit.xcframework.zip"
xcodebuild -create-xcframework -framework "$FRAMEWORK" -output "$OUT/AemberLanguageKit.xcframework" >/dev/null
(cd "$OUT" && ditto -c -k --keepParent AemberLanguageKit.xcframework AemberLanguageKit.xcframework.zip)

echo "Built $OUT/AemberLanguageKit.xcframework ($(lipo -archs "$FRAMEWORK/AemberLanguageKit"))"
echo "SHA-256 of the zip: $(shasum -a 256 "$OUT/AemberLanguageKit.xcframework.zip" | cut -d' ' -f1)"
