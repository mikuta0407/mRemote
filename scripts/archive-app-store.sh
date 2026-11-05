#!/bin/bash
# Archives the iPadOS/iOS app and exports it for App Store Connect, where it
# goes for notarization and then to AltStore PAL (docs: AltStore's "Distribute
# with AltStore PAL"). Unlike scripts/release.sh, this build is signed: with
# the team's distribution certificate and an App Store profile, which Xcode
# makes as needed (-allowProvisioningUpdates).
#
# Usage: scripts/archive-app-store.sh v0.5.0 [--upload]
#
# Run on a Mac with Xcode signed in to the paid developer account, from a
# clean tree whose HEAD is what to send, with the XCFrameworks built. Without
# --upload the .ipa is left in build/app-store/<tag>/ to upload yourself
# (Transporter, or `xcrun altool`); with it, the export sends it to App Store
# Connect, where the app must already exist.

set -euo pipefail

TAG="${1:-}"
DESTINATION=export
[[ "${2:-}" == "--upload" ]] && DESTINATION=upload
[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "usage: $0 vX.Y.Z [--upload]" >&2; exit 1; }
VERSION="${TAG#v}"
TEAM="3R8LX96WPK"

cd "$(dirname "$0")/.."
if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
    echo "The tree has uncommitted changes." >&2
    exit 1
fi
# The same build number as scripts/release.sh gives this commit.
BUILD_NUMBER="$(git rev-list --count HEAD)"
OUT="build/app-store/$TAG"
ARCHIVE="$OUT/mRemote.xcarchive"
rm -rf "$OUT"
mkdir -p "$OUT"

echo "==> Archive (iOS, Release, build $BUILD_NUMBER)"
xcodebuild archive \
    -project mRemote.xcodeproj -scheme mRemote -configuration Release \
    -destination 'generic/platform=iOS' \
    -archivePath "$ARCHIVE" \
    -derivedDataPath build/app-store/derived \
    -allowProvisioningUpdates -skipPackagePluginValidation \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    DEVELOPMENT_TEAM="$TEAM" \
    | grep -E "error:|warning: .*(sign|profile|provision)|ARCHIVE (SUCCEEDED|FAILED)" || true
[[ -d "$ARCHIVE/Products/Applications/mRemote.app" ]] || { echo "The archive failed." >&2; exit 1; }

cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>app-store-connect</string>
    <key>destination</key><string>$DESTINATION</string>
    <key>teamID</key><string>$TEAM</string>
    <key>signingStyle</key><string>automatic</string>
    <key>uploadSymbols</key><true/>
    <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
PLIST

echo "==> Export ($DESTINATION)"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportOptionsPlist "$OUT/ExportOptions.plist" \
    -exportPath "$OUT" \
    -allowProvisioningUpdates \
    | grep -E "error:|EXPORT (SUCCEEDED|FAILED)|Upload|upload" || true

if [[ "$DESTINATION" == export ]]; then
    [[ -f "$OUT/mRemote.ipa" ]] || { echo "The export failed." >&2; exit 1; }
    codesign -dvv "$OUT/mRemote.ipa" >/dev/null 2>&1 || true
    echo "Exported $OUT/mRemote.ipa ($VERSION, build $BUILD_NUMBER)."
fi
