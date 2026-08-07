#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <GitHub release tag>" >&2
  echo "Example: $0 v1.0" >&2
  exit 2
fi

RELEASE_TAG="$1"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA_PATH="$ROOT_DIR/build/DerivedData"
APP_PATH="$DERIVED_DATA_PATH/Build/Products/Release/WindowBoard.app"
ARCHIVES_DIR="$ROOT_DIR/release/sparkle"
PUBLIC_FEED_PATH="$ROOT_DIR/docs/appcast.xml"
SPARKLE_BIN="$DERIVED_DATA_PATH/SourcePackages/artifacts/sparkle/Sparkle/bin"
KEYCHAIN_ACCOUNT="com.local.WindowBoard"
DOWNLOAD_URL_PREFIX="https://github.com/Daidesuu/Window-Board/releases/download/${RELEASE_TAG}/"
FEED_WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/windowboard-sparkle.XXXXXX")"

cleanup() {
  rm -rf "$FEED_WORK_DIR"
}

trap cleanup EXIT

if [[ ! -x "$SPARKLE_BIN/generate_appcast" ]]; then
  echo "Sparkle tools are unavailable. Build WindowBoard once before preparing a release." >&2
  exit 1
fi

xcodebuild \
  -project "$ROOT_DIR/WindowBoard.xcodeproj" \
  -scheme WindowBoard \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  build

xattr -cr "$APP_PATH"
codesign --force --deep --sign - "$APP_PATH"
codesign --verify --deep --strict --verbose=4 "$APP_PATH"

SHORT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
BUILD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist")"
ARCHIVE_PATH="$ARCHIVES_DIR/WindowBoard-${SHORT_VERSION}-${BUILD_VERSION}.zip"

mkdir -p "$ARCHIVES_DIR"

if [[ -e "$ARCHIVE_PATH" ]]; then
  echo "Refusing to overwrite existing archive: $ARCHIVE_PATH" >&2
  exit 1
fi

/usr/bin/ditto -c -k --keepParent "$APP_PATH" "$ARCHIVE_PATH"

if [[ -f "$PUBLIC_FEED_PATH" ]]; then
  /bin/cp "$PUBLIC_FEED_PATH" "$FEED_WORK_DIR/appcast.xml"
fi

/bin/cp "$ARCHIVE_PATH" "$FEED_WORK_DIR/"

"$SPARKLE_BIN/generate_appcast" \
  --account "$KEYCHAIN_ACCOUNT" \
  --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
  --link "https://github.com/Daidesuu/Window-Board" \
  --maximum-deltas 0 \
  -o "$FEED_WORK_DIR/appcast.xml" \
  "$FEED_WORK_DIR"

/bin/cp "$FEED_WORK_DIR/appcast.xml" "$PUBLIC_FEED_PATH"

echo "Prepared: $ARCHIVE_PATH"
echo "Updated: $PUBLIC_FEED_PATH"
echo
echo "Next: upload the ZIP to GitHub Release ${RELEASE_TAG}, then commit and publish docs/appcast.xml with GitHub Pages."
