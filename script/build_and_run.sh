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
Usage: $0 [--verify] [--logs] [--launch-only]

Builds and launches WindowBoard.
USAGE
}

VERIFY=0
LOGS=0
LAUNCH_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --verify)
      VERIFY=1
      ;;
    --logs)
      LOGS=1
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

if pgrep -x "$APP_NAME" >/dev/null; then
  pkill -x "$APP_NAME"
fi

echo "App available at: ${DIST_APP_PATH}"
/usr/bin/open -n "$DIST_APP_PATH"

if [[ "$VERIFY" -eq 1 ]]; then
  sleep 1
  pgrep -x "$APP_NAME" >/dev/null
  echo "WindowBoard is running."
fi

if [[ "$LOGS" -eq 1 ]]; then
  /usr/bin/log stream --style compact --predicate 'process == "WindowBoard"'
fi
