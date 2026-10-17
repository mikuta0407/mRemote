#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOCK_FILE="$REPO_ROOT/config/dependencies/libssh2.lock"
FREERDP_LOCK_FILE="$REPO_ROOT/config/dependencies/freerdp.lock"

# shellcheck disable=SC1090
source "$LOCK_FILE"
IOS_DEPLOYMENT_TARGET="$(sed -n 's/^IOS_DEPLOYMENT_TARGET=//p' "$FREERDP_LOCK_FILE")"
FREERDP_XCFRAMEWORK_NAME="$(sed -n 's/^XCFRAMEWORK_NAME=//p' "$FREERDP_LOCK_FILE")"

BUILD_ROOT="$REPO_ROOT/.build/ssh"
FREERDP_XCFRAMEWORK="$REPO_ROOT/artifacts/$FREERDP_XCFRAMEWORK_NAME"
OUTPUT_PATH="$REPO_ROOT/artifacts/$XCFRAMEWORK_NAME"
FETCH_ONLY=0

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '[ssh-build] %s\n' "$*"
}

usage() {
  sed -n 's/^#> //p' "$0"
}

#> Usage: scripts/build-ssh-xcframework.sh [options]
#>
#> Build the locked libssh2 and the mr_ssh bridge (bridge/ssh) as a
#> three-slice static XCFramework. It carries no OpenSSL of its own: libssh2
#> is compiled against the OpenSSL headers in FreeRDP.xcframework, and the app
#> links that OpenSSL once, through FreeRDP.xcframework.
#>
#> Options:
#>   --fetch-only                Check out the locked libssh2 and stop (for the
#>                               host tests in bridge/ssh).
#>   --freerdp-xcframework PATH  Use this generated FreeRDP XCFramework.
#>   --build-root PATH           Put sources and objects under PATH.
#>   --output PATH               Write the XCFramework to PATH.
#>   -h, --help                  Show this help.

while (($#)); do
  case "$1" in
    --fetch-only)
      FETCH_ONLY=1
      shift
      ;;
    --freerdp-xcframework)
      (($# >= 2)) || die "--freerdp-xcframework requires a path"
      FREERDP_XCFRAMEWORK="$2"
      shift 2
      ;;
    --build-root)
      (($# >= 2)) || die "--build-root requires a path"
      BUILD_ROOT="$2"
      shift 2
      ;;
    --output)
      (($# >= 2)) || die "--output requires a path"
      OUTPUT_PATH="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

[[ "$LOCK_FORMAT_VERSION" == "1" ]] || die "unsupported lock format: $LOCK_FORMAT_VERSION"
[[ "$LIBSSH2_COMMIT" =~ ^[0-9a-f]{40}$ ]] || die "invalid libssh2 commit in lock"
[[ "$LIBSSH2_LICENSE_SHA256" =~ ^[0-9a-f]{64}$ ]] || die "invalid libssh2 license hash"
[[ "$IOS_DEPLOYMENT_TARGET" =~ ^[0-9]+([.][0-9]+)*$ ]] || die "invalid IOS_DEPLOYMENT_TARGET"

# ---- source ---------------------------------------------------------------

SOURCE_DIR="$BUILD_ROOT/src/libssh2"
if [[ ! -d "$SOURCE_DIR/.git" ]]; then
  log "fetching libssh2 $LIBSSH2_COMMIT"
  mkdir -p "$SOURCE_DIR"
  git -C "$SOURCE_DIR" init -q
  git -C "$SOURCE_DIR" remote add origin "$LIBSSH2_GIT_URL"
  git -C "$SOURCE_DIR" fetch -q --depth 1 origin "$LIBSSH2_COMMIT"
fi
git -C "$SOURCE_DIR" checkout -q --detach "$LIBSSH2_COMMIT"
[[ "$(git -C "$SOURCE_DIR" rev-parse HEAD)" == "$LIBSSH2_COMMIT" ]] || die "libssh2 checkout is not the locked commit"
[[ -z "$(git -C "$SOURCE_DIR" status --porcelain)" ]] || die "libssh2 checkout has local changes: $SOURCE_DIR"
[[ "$(shasum -a 256 "$SOURCE_DIR/COPYING" | cut -d' ' -f1)" == "$LIBSSH2_LICENSE_SHA256" ]] ||
  die "libssh2 license changed; review it and update the lock"

if ((FETCH_ONLY)); then
  log "libssh2 is at $SOURCE_DIR"
  exit 0
fi

# ---- build ----------------------------------------------------------------

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
for command_name in plutil shasum xcodebuild xcrun; do
  command -v "$command_name" >/dev/null 2>&1 || die "required command not found: $command_name"
done
[[ -x /usr/bin/libtool ]] || die "Apple /usr/bin/libtool is required"
[[ -f "$FREERDP_XCFRAMEWORK/Info.plist" ]] ||
  die "FreeRDP XCFramework not found (its OpenSSL is needed): $FREERDP_XCFRAMEWORK"
[[ ! -e "$OUTPUT_PATH" ]] || die "output already exists; choose a fresh --output path: $OUTPUT_PATH"

# The same list as bridge/ssh/libssh2-sources.cmake.
LIBSSH2_SOURCES=(
  agent bcrypt_pbkdf chacha channel cipher-chachapoly comp crypt global
  hostkey keepalive kex knownhost mac misc openssl packet pem poly1305
  publickey scp session sftp transport userauth userauth_kbd_packet version
)
LIBSSH2_DEFINES=(-D__STDC_WANT_LIB_EXT1__=1 -DHAVE_CONFIG_H -DLIBSSH2_OPENSSL)

build_slice() {
  local slice="$1" identifier="$2" sdk="$3" target="$4"
  local slice_root="$BUILD_ROOT/obj/$slice"
  local headers="$FREERDP_XCFRAMEWORK/$identifier/Headers"
  local sdk_path objects=() source object

  [[ -f "$headers/openssl/evp.h" ]] || die "OpenSSL headers missing for $slice"
  rm -rf "$slice_root"
  mkdir -p "$slice_root"
  sdk_path="$(xcrun --sdk "$sdk" --show-sdk-path)"
  local common=(
    -target "$target" -isysroot "$sdk_path"
    -std=c11 -O2 -DNDEBUG -fno-common
    -ffile-prefix-map="$REPO_ROOT=/usr/src/mRemote"
    -ffile-prefix-map="$BUILD_ROOT=/usr/src/mRemote/.build/ssh"
    -isystem "$headers"
  )
  for source in "${LIBSSH2_SOURCES[@]}"; do
    object="$slice_root/libssh2_$source.o"
    xcrun --sdk "$sdk" clang "${common[@]}" "${LIBSSH2_DEFINES[@]}" \
      -I "$REPO_ROOT/bridge/ssh/config" -I "$SOURCE_DIR/include" \
      -w -c "$SOURCE_DIR/src/$source.c" -o "$object"
    objects+=("$object")
  done
  for source in ssh_bridge ssh_forward; do
    object="$slice_root/$source.o"
    xcrun --sdk "$sdk" clang "${common[@]}" \
      -Wall -Wextra -Wpedantic -Werror \
      -I "$REPO_ROOT/bridge/ssh/include" -I "$SOURCE_DIR/include" \
      -c "$REPO_ROOT/bridge/ssh/src/$source.c" -o "$object"
    objects+=("$object")
  done

  /usr/bin/libtool -static -D -o "$slice_root/libmRemoteSSH.a" "${objects[@]}"
  [[ "$(xcrun lipo -archs "$slice_root/libmRemoteSSH.a")" == "arm64" ]] ||
    die "archive is not arm64 for $slice"
  # OpenSSL must come from FreeRDP.xcframework, never from here.
  if nm -g "$slice_root/libmRemoteSSH.a" 2>/dev/null | grep -q ' T _EVP_'; then
    die "the $slice archive defines OpenSSL symbols"
  fi
}

log "building libssh2 $LIBSSH2_VERSION ($LIBSSH2_COMMIT) for iOS $IOS_DEPLOYMENT_TARGET"
build_slice device ios-arm64 iphoneos "arm64-apple-ios${IOS_DEPLOYMENT_TARGET}"
build_slice simulator ios-arm64-simulator iphonesimulator "arm64-apple-ios${IOS_DEPLOYMENT_TARGET}-simulator"
build_slice maccatalyst ios-arm64-maccatalyst macosx "arm64-apple-ios${IOS_DEPLOYMENT_TARGET}-macabi"

# Only the bridge's header is public: nothing above App/SSH/ sees libssh2.
headers_root="$BUILD_ROOT/headers"
rm -rf "$headers_root"
mkdir -p "$headers_root"
cp -R "$REPO_ROOT/bridge/ssh/include/." "$headers_root/"

mkdir -p "$(dirname "$OUTPUT_PATH")"
xcodebuild -create-xcframework \
  -library "$BUILD_ROOT/obj/device/libmRemoteSSH.a" -headers "$headers_root" \
  -library "$BUILD_ROOT/obj/simulator/libmRemoteSSH.a" -headers "$headers_root" \
  -library "$BUILD_ROOT/obj/maccatalyst/libmRemoteSSH.a" -headers "$headers_root" \
  -output "$OUTPUT_PATH" >/dev/null

for forbidden in "$REPO_ROOT" '/Users/' '/private/tmp/' '/private/var/folders/'; do
  match="$(LC_ALL=C grep -R -a -F -l -- "$forbidden" "$OUTPUT_PATH" 2>/dev/null | head -n 1 || true)"
  [[ -z "$match" ]] || die "host path remains in the artifact: $forbidden ($match)"
done

checksum_file="$(dirname "$OUTPUT_PATH")/$(basename "$OUTPUT_PATH").sha256"
(
  cd "$(dirname "$OUTPUT_PATH")"
  find "$(basename "$OUTPUT_PATH")" -type f -print | LC_ALL=C sort |
    while IFS= read -r file_path; do shasum -a 256 "$file_path"; done
) > "$checksum_file"

log "build complete: $OUTPUT_PATH"
