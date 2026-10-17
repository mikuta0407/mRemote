#!/bin/bash
# Builds a release and publishes it:
#   - mRemote-<tag>-macos-arm64.zip  the Mac app (Mac Catalyst), ad-hoc signed,
#                                    installed by the Homebrew cask
#   - mRemote-<tag>-ios-unsigned.ipa the iPadOS/iOS app, unsigned, for
#                                    LiveContainer or for signing yourself
# then creates the GitHub release and points Casks/mremote.rb in
# mikuta0407/homebrew-apps at it.
#
# Usage: scripts/release.sh v0.1.0 [--no-publish]
#
# Run on a Mac with Xcode, from a clean tree whose HEAD is what to release,
# with the XCFrameworks already built (FreeRDP, the RDP bridge and SSH; see
# the README) and Xcode's Metal toolchain installed. --no-publish stops
# after building, leaving the files in build/release/<tag>/.
#
# The Mac app is ad-hoc signed because there is no Developer ID to sign it
# with: it carries no Keychain access group (that needs a provisioning
# profile), so it keeps passwords in the login keychain (KeychainStore).

set -euo pipefail

TAG="${1:-}"
PUBLISH=1
[[ "${2:-}" == "--no-publish" ]] && PUBLISH=0
[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "usage: $0 vX.Y.Z [--no-publish]" >&2; exit 1; }
VERSION="${TAG#v}"
REPO="mikuta0407/mRemote"
TAP="mikuta0407/homebrew-apps"

cd "$(dirname "$0")/.."
if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
    echo "The tree has uncommitted changes." >&2
    exit 1
fi
BUILD_NUMBER="$(git rev-list --count HEAD)"
OUT="build/release/$TAG"
DERIVED="build/release/derived"
rm -rf "$OUT"
mkdir -p "$OUT"

# SwiftTerm runs a build-info plugin, which an unattended build has to be
# told to trust.
common=(
    -project mRemote.xcodeproj -scheme mRemote -configuration Release
    -skipPackagePluginValidation
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER"
)

echo "==> Mac app (Mac Catalyst, arm64, ad-hoc)"
# The XCFrameworks' Mac slice is arm64 only. No entitlements file: a
# Keychain access group without a profile would stop the app from launching.
xcodebuild build "${common[@]}" \
    -destination 'platform=macOS,variant=Mac Catalyst,arch=arm64' \
    -derivedDataPath "$DERIVED/mac" \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
    PROVISIONING_PROFILE_SPECIFIER= CODE_SIGN_ENTITLEMENTS= \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    | grep -E "error:|warning: .*sign|BUILD (SUCCEEDED|FAILED)" || true
MAC_APP="$DERIVED/mac/Build/Products/Release-maccatalyst/mRemote.app"
codesign --verify --strict "$MAC_APP"
[[ "$(codesign -dv "$MAC_APP" 2>&1)" == *"Signature=adhoc"* ]] || { echo "The Mac app is not ad-hoc signed." >&2; exit 1; }
MAC_ZIP="$OUT/mRemote-$TAG-macos-arm64.zip"
ditto -c -k --keepParent "$MAC_APP" "$MAC_ZIP"

echo "==> iPadOS/iOS app (unsigned IPA)"
xcodebuild build "${common[@]}" \
    -sdk iphoneos -destination 'generic/platform=iOS' \
    -derivedDataPath "$DERIVED/ios" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
    | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true
IOS_APP="$DERIVED/ios/Build/Products/Release-iphoneos/mRemote.app"
[[ -x "$IOS_APP/mRemote" ]] || { echo "The iOS build failed." >&2; exit 1; }
IPA="$OUT/mRemote-$TAG-ios-unsigned.ipa"
staging="$(mktemp -d)"
mkdir "$staging/Payload"
cp -R "$IOS_APP" "$staging/Payload/"
( cd "$staging" && zip -qry - Payload ) > "$IPA"
rm -rf "$staging"

for f in "$MAC_APP/Contents/Info.plist" "$IOS_APP/Info.plist"; do
    [[ "$(plutil -extract CFBundleShortVersionString raw "$f")" == "$VERSION" ]] \
        || { echo "Wrong version in $f" >&2; exit 1; }
done
( cd "$OUT" && shasum -a 256 ./*.zip ./*.ipa | sed 's| \./| |' > SHA256SUMS )
cat "$OUT/SHA256SUMS"

if [[ $PUBLISH -eq 0 ]]; then
    echo "Built in $OUT (not published)."
    exit 0
fi

echo "==> GitHub release $TAG"
git tag -a "$TAG" -m "mRemote $VERSION" 2>/dev/null || true
git push origin "$TAG"
gh release create "$TAG" --repo "$REPO" --title "mRemote $VERSION" --verify-tag \
    --notes "$(cat <<NOTES
## Install

**macOS** (Apple silicon, macOS 14 or later):

    brew install --cask mikuta0407/apps/mremote

**iPadOS / iOS**: \`mRemote-$TAG-ios-unsigned.ipa\` is unsigned. Install it
with LiveContainer, or sign it yourself.

The Mac app is ad-hoc signed, not notarized; the cask removes the quarantine
attribute. It keeps passwords in the login keychain, and after an update
macOS may ask once to let it read them again.
NOTES
)" \
    "$MAC_ZIP" "$IPA" "$OUT/SHA256SUMS"

echo "==> Homebrew cask"
SHA_MAC="$(shasum -a 256 "$MAC_ZIP" | cut -d' ' -f1)"
tap="$(mktemp -d)"
gh repo clone "$TAP" "$tap" -- --quiet --depth 1
mkdir -p "$tap/Casks"
cat > "$tap/Casks/mremote.rb" <<CASK
cask "mremote" do
  version "$VERSION"
  sha256 "$SHA_MAC"

  url "https://github.com/$REPO/releases/download/v#{version}/mRemote-v#{version}-macos-arm64.zip"
  name "mRemote"
  desc "RDP and SSH client with JIS keyboard support and the MACRDPX extensions"
  homepage "https://github.com/$REPO"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "mRemote.app"

  # 公証していない (ad-hoc 署名) ので、Gatekeeper の quarantine 属性を外す
  postflight_steps do
    run "/usr/bin/xattr",
        args:           ["-dr", "com.apple.quarantine", "{{appdir}}/mRemote.app"],
        writable_paths: ["mRemote.app"],
        writable_base:  :appdir,
        must_succeed:   false
  end

  uninstall quit: "com.mikuta0407.mRemote"

  zap trash: [
    "~/Library/Application Support/mRemote-profiles.json",
    "~/Library/Caches/com.mikuta0407.mRemote",
    "~/Library/HTTPStorages/com.mikuta0407.mRemote",
    "~/Library/Preferences/com.mikuta0407.mRemote.plist",
    "~/Library/Saved Application State/com.mikuta0407.mRemote.savedState",
  ]
end
CASK
ruby -c "$tap/Casks/mremote.rb" >/dev/null
git -C "$tap" add Casks/mremote.rb
if git -C "$tap" diff --cached --quiet; then
    echo "The cask is already up to date."
else
    git -C "$tap" commit -q -m "mremote $VERSION"
    git -C "$tap" push -q
fi
rm -rf "$tap"
echo "Released $TAG."
