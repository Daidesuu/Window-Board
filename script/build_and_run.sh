#!/usr/bin/env bash
set -euo pipefail

PROJECT_PATH="WindowBoard.xcodeproj"
SCHEME="WindowBoard"
CONFIGURATION="Debug"
DERIVED_DATA_PATH="${PWD}/build/DerivedData"
APP_NAME="WindowBoard"
DIST_DIR="${PWD}/dist"

usage() {
  cat <<USAGE
Usage: $0 [--verify] [--logs] [--launch-only] [--prototype]

Builds and launches WindowBoard.
USAGE
}

VERIFY=0
LOGS=0
LAUNCH_ONLY=0
PROTOTYPE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --verify)
      VERIFY=1
      ;;
    --logs)
      LOGS=1
      ;;
    --prototype)
      PROTOTYPE=1
      ;;
    --launch-only)
      LAUNCH_ONLY=1
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
  shift
done

APP_PATH="${DERIVED_DATA_PATH}/Build/Products/${CONFIGURATION}/${APP_NAME}.app"
DIST_APP_PATH="${DIST_DIR}/${APP_NAME}.app"

if [[ "$LAUNCH_ONLY" -eq 0 ]]; then
  xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    build

  mkdir -p "$DIST_DIR"
  /usr/bin/ditto "$APP_PATH" "$DIST_APP_PATH"
elif [[ ! -d "$DIST_APP_PATH" ]]; then
  echo "No app found at ${DIST_APP_PATH}. Run without --launch-only first." >&2
  exit 1
fi

if [[ "$PROTOTYPE" -eq 1 ]]; then
  PROTOTYPE_STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp/}WindowBoardPrototype.XXXXXX")"
  PROTOTYPE_APP_PATH="${PROTOTYPE_STAGE_DIR}/WindowBoardPrototype.app"
  /usr/bin/ditto "$DIST_APP_PATH" "$PROTOTYPE_APP_PATH"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.local.WindowBoard.prototype" "$PROTOTYPE_APP_PATH/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleName WindowBoard Prototype" "$PROTOTYPE_APP_PATH/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :WindowBoardSplitPrototype bool true" "$PROTOTYPE_APP_PATH/Contents/Info.plist"
  /usr/bin/xattr -cr "$PROTOTYPE_APP_PATH"
  /usr/bin/codesign --force --deep --sign - "$PROTOTYPE_APP_PATH"
  /usr/bin/ditto "$PROTOTYPE_APP_PATH" "${DIST_DIR}/WindowBoardPrototype.app"
  DIST_APP_PATH="${DIST_DIR}/WindowBoardPrototype.app"
fi

if [[ "$PROTOTYPE" -eq 0 ]] && pgrep -x "$APP_NAME" >/dev/null; then
  pkill -x "$APP_NAME"
fi

echo "App available at: ${DIST_APP_PATH}"
if [[ "$PROTOTYPE" -eq 1 ]]; then
  pkill -f "^${DIST_APP_PATH}/Contents/MacOS/${APP_NAME}([[:space:]]|$)" || true
  /usr/bin/open -n "$DIST_APP_PATH" --args --split-prototype -ApplePersistenceIgnoreState YES
else
  /usr/bin/open -n "$DIST_APP_PATH"
fi

if [[ "$VERIFY" -eq 1 ]]; then
  sleep 1
  if [[ "$PROTOTYPE" -eq 1 ]]; then
    pgrep -f "^${DIST_APP_PATH}/Contents/MacOS/${APP_NAME}([[:space:]]|$)" >/dev/null
    echo "WindowBoard prototype is running."
  else
    pgrep -x "$APP_NAME" >/dev/null
    echo "WindowBoard is running."
  fi
fi

if [[ "$LOGS" -eq 1 ]]; then
  /usr/bin/log stream --style compact --predicate 'process == "WindowBoard"'
fi
