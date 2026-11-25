#!/bin/zsh
#
# Checks a language pack as Aember loads it, and lists what it gives.
#
# Usage: Scripts/check-pack.sh <pack.aemberpack> [--framework PATH]
#
#   --framework PATH  AemberLanguageKit.xcframework (default:
#                     build/AemberLanguageKit.xcframework in this
#                     repository)
#
# Builds Scripts/check-pack.swift against the framework (once, into
# build/check-pack) and runs it on the pack: the embedded Info.plist
# and its API version, loading it, its manifest against the plist, and
# its languages, servers, build systems and package managers. Then
# shows who signed it.

set -euo pipefail

ROOT=${0:A:h:h}
FRAMEWORK=$ROOT/build/AemberLanguageKit.xcframework
[[ $# -ge 1 ]] || { sed -n '3,15p' "$0" | sed 's/^# \{0,1\}//'; exit 1 }
PACK=${1:A}
shift
while [[ $# -gt 0 ]]; do
    case $1 in
        --framework) FRAMEWORK=${2:A}; shift 2 ;;
        *) echo "error: unknown option $1" >&2; exit 1 ;;
    esac
done
SLICE=$FRAMEWORK/macos-arm64_x86_64
[[ -d $SLICE/AemberLanguageKit.framework ]] \
    || { echo "error: no AemberLanguageKit.xcframework at $FRAMEWORK; build it with Scripts/build-xcframework.sh" >&2; exit 1 }

CHECKER=$ROOT/build/check-pack
if [[ ! -x $CHECKER || $ROOT/Scripts/check-pack.swift -nt $CHECKER || $SLICE/AemberLanguageKit.framework/AemberLanguageKit -nt $CHECKER ]]; then
    mkdir -p "$ROOT/build"
    swiftc -O -swift-version 5 -F "$SLICE" -framework AemberLanguageKit \
        -Xlinker -rpath -Xlinker "$SLICE" \
        "$ROOT/Scripts/check-pack.swift" -o "$CHECKER"
fi

"$CHECKER" "$PACK"
# Aember trusts BitArts' team (YMT43R5FT7) and asks about anyone else
SIGNING=$(codesign -dvv "$PACK" 2>&1 || true)
AUTHORITY=$(print -r -- "$SIGNING" | grep -m1 '^Authority=' | cut -d= -f2- || true)
TEAM=$(print -r -- "$SIGNING" | grep -m1 '^TeamIdentifier=' | cut -d= -f2- || true)
if [[ -n $AUTHORITY ]]; then
    echo "Signed by: $AUTHORITY (team $TEAM)"
elif [[ -n $TEAM && $TEAM != "not set" ]]; then
    echo "Signed by team $TEAM"
else
    echo "Not signed with an identity (ad hoc or unsigned): Aember asks before running it"
fi
