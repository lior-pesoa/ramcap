#!/bin/zsh
# Builds RAMcap.app from the Swift package.
#   scripts/make-app.sh <scratch-path> [out-dir]
# <scratch-path> is SwiftPM's build folder; the app lands in out-dir
# (default: the scratch path).
set -euo pipefail
root=${0:A:h:h}
scratch=${1:?usage: make-app.sh <scratch-path> [out-dir]}
out=${2:-$scratch}

swift build -c release --package-path "$root" --scratch-path "$scratch" --product RAMcapApp

app="$out/RAMcap.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$scratch/release/RAMcapApp" "$app/Contents/MacOS/RAMcap"
# Info.plist carries Xcode build variables (for scripts/release.sh); fill them in.
version=$(sed -n 's/.*MARKETING_VERSION: "\(.*\)"/\1/p' "$root/App/project.yml")
build=$(sed -n 's/.*CURRENT_PROJECT_VERSION: "\(.*\)"/\1/p' "$root/App/project.yml")
sed -e "s/\$(MARKETING_VERSION)/$version/" -e "s/\$(CURRENT_PROJECT_VERSION)/$build/" \
    -e 's/\$(PRODUCT_BUNDLE_IDENTIFIER)/app.ramcap.RAMcap/' -e 's/\$(EXECUTABLE_NAME)/RAMcap/' \
    "$root/App/Info.plist" > "$app/Contents/Info.plist"
cp "$root/App/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
codesign --force --sign - --options runtime "$app"
echo "$app"
