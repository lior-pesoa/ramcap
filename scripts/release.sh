#!/usr/bin/env bash
# Builds a RAMcap release on this Mac: a notarized, stapled RAMcap.app and
# RAMcap-<version>.zip (for the GitHub release and the Homebrew cask) in
# dist/<version>-<build>/. Publishes nothing.
#
#   scripts/release.sh <version> <build> [--allow-dirty]
#   e.g. scripts/release.sh 0.1.0 1
#
# Signing works like Coral's: Xcode's signed-in account signs with the
# cloud-managed Developer ID certificate and uploads to Apple's notary service,
# so no certificate or notarytool password is needed in the keychain.
set -euo pipefail

usage() { echo "usage: $0 <version> <build> [--allow-dirty]" >&2; exit 2; }

version=""
build=""
allow_dirty=0
for arg in "$@"; do
    case "$arg" in
        --allow-dirty) allow_dirty=1 ;;
        -*) usage ;;
        *) if [[ -z "$version" ]]; then version="$arg"; elif [[ -z "$build" ]]; then build="$arg"; else usage; fi ;;
    esac
done
[[ -n "$version" && -n "$build" ]] || usage
[[ "$version" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || { echo "Version must look like 1.2.3, got \"$version\"." >&2; exit 2; }
[[ "$build" =~ ^[0-9]+$ ]] || { echo "Build must be a whole number, got \"$build\"." >&2; exit 2; }

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="$repo/dist/$version-$build"
work="$out/work"
# Build output (1 to 6 GB) goes whether the release finished or not.
derived="${RAMCAP_DERIVED_DATA:-$work/dd}"
team="L5LZ6NU65K"
bundle_id="app.ramcap.RAMcap"

step() { printf '\n==> %s\n' "$*"; }
fail() { echo "error: $*" >&2; exit 1; }

if [[ "$allow_dirty" -eq 0 ]]; then
    dirty="$(git -C "$repo" status --porcelain -- Sources App Package.swift)"
    [[ -z "$dirty" ]] || { echo "$dirty" >&2; fail "commit these first, or pass --allow-dirty"; }
fi

cleanup() { rm -rf "$derived"; }
trap cleanup EXIT

rm -rf "$out"
mkdir -p "$work"
archive="$work/RAMcap.xcarchive"

step "Generating the project and archiving RAMcap $version ($build)"
(cd "$repo/App" && xcodegen generate -q)
xcodebuild archive -project "$repo/App/RAMcap.xcodeproj" -scheme RAMcap -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$derived" -archivePath "$archive" \
    -allowProvisioningUpdates CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="$team" CODE_SIGN_IDENTITY="Apple Development" \
    MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build" -quiet

step "Exporting for Developer ID and submitting for notarization"
export_options="$work/ExportOptions.plist"
cat > "$export_options" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>$team</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>destination</key>
    <string>upload</string>
</dict>
</plist>
EOF
xcodebuild -exportArchive -archivePath "$archive" -exportPath "$work/notary" \
    -exportOptionsPlist "$export_options" -allowProvisioningUpdates

step "Waiting for Apple to notarize (checks every 30 s, up to 20 min)"
deadline=$((SECONDS + 20 * 60))
until xcodebuild -exportNotarizedApp -archivePath "$archive" -exportPath "$work/notarized" >"$work/notarized.log" 2>&1; do
    if ((SECONDS >= deadline)); then
        tail -5 "$work/notarized.log" >&2
        fail "not notarized after 20 minutes. Check the archive in Xcode's Organizer, then run the script again."
    fi
    echo "   not yet, trying again in 30 s"
    sleep 30
done

app="$out/RAMcap.app"
ditto "$work/notarized/RAMcap.app" "$app"
xcrun stapler validate "$app" >/dev/null 2>&1 || xcrun stapler staple "$app"

step "Checking the app"
codesign --verify --deep --strict "$app"
info="$(codesign -dvv "$app" 2>&1)"
grep -q "^Authority=Developer ID Application" <<<"$info" || fail "the app isn't signed for Developer ID"
grep -q "^TeamIdentifier=$team\$" <<<"$info" || fail "the app isn't signed by team $team"
grep -q "flags=.*runtime" <<<"$info" || fail "the app doesn't have the hardened runtime"
spctl -a -vv -t exec "$app" 2>&1 | tee "$work/spctl.txt"
grep -q "source=Notarized Developer ID" "$work/spctl.txt" || fail "Gatekeeper doesn't see a notarized Developer ID app"
plist="$app/Contents/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")" == "$version" ]] || fail "CFBundleShortVersionString isn't $version"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")" == "$build" ]] || fail "CFBundleVersion isn't $build"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")" == "$bundle_id" ]] || fail "bundle id isn't $bundle_id"
[[ -f "$app/Contents/Resources/AppIcon.icns" ]] || fail "the app has no icon"

step "Zipping"
zip="$out/RAMcap-$version.zip"
ditto -c -k --keepParent "$app" "$zip"
sha="$(shasum -a 256 "$zip" | cut -d' ' -f1)"
echo "$sha" > "$zip.sha256"
# Same file under a fixed name, for ramcap.app's link to releases/latest/download/RAMcap.zip.
cp "$zip" "$out/RAMcap.zip"

step "Done: RAMcap $version ($build)"
echo "   App:     $app"
echo "   Zip:     $zip"
echo "   SHA-256: $sha"
echo
echo "Next: gh release create v$version \"$zip\" \"$out/RAMcap.zip\", then bump version and sha256"
echo "in lior-pesoa/homebrew-tap Casks/ramcap.rb."
