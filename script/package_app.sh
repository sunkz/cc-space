#!/usr/bin/env bash
set -euo pipefail

APP_NAME="CCSpace"
DISPLAY_NAME="CCSpace"
BUNDLE_ID="com.ccspace.app"
MINIMUM_SYSTEM_VERSION="14.0"
ICON_PATH="Resources/AppIcon.icns"

usage() {
  cat <<EOF
Usage: $0 --binary PATH --output PATH --version VERSION [--app-name NAME] [--display-name NAME] [--bundle-id ID]

Assembles a macOS .app bundle from an already-built executable.
EOF
}

BINARY_PATH=""
OUTPUT_PATH=""
VERSION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --binary)
      BINARY_PATH="${2:-}"
      shift 2
      ;;
    --output)
      OUTPUT_PATH="${2:-}"
      shift 2
      ;;
    --version)
      VERSION="${2:-}"
      shift 2
      ;;
    --app-name)
      APP_NAME="${2:-}"
      shift 2
      ;;
    --display-name)
      DISPLAY_NAME="${2:-}"
      shift 2
      ;;
    --bundle-id)
      BUNDLE_ID="${2:-}"
      shift 2
      ;;
    help|-h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$BINARY_PATH" || -z "$OUTPUT_PATH" || -z "$VERSION" ]]; then
  usage >&2
  exit 1
fi

if [[ ! -x "$BINARY_PATH" ]]; then
  echo "Executable not found or not executable: $BINARY_PATH" >&2
  exit 1
fi

if [[ ! -f "$ICON_PATH" ]]; then
  echo "App icon not found: $ICON_PATH" >&2
  exit 1
fi

APP_BUNDLE="$OUTPUT_PATH"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BINARY_PATH" "$APP_BINARY"
chmod +x "$APP_BINARY"
cp "$ICON_PATH" "$APP_RESOURCES/AppIcon.icns"

/usr/libexec/PlistBuddy \
  -c "Clear dict" \
  -c "Add :CFBundleExecutable string $APP_NAME" \
  -c "Add :CFBundleIdentifier string $BUNDLE_ID" \
  -c "Add :CFBundleIconFile string AppIcon" \
  -c "Add :CFBundleName string $DISPLAY_NAME" \
  -c "Add :CFBundlePackageType string APPL" \
  -c "Add :CFBundleShortVersionString string $VERSION" \
  -c "Add :CFBundleVersion string $VERSION" \
  -c "Add :LSMinimumSystemVersion string $MINIMUM_SYSTEM_VERSION" \
  -c "Add :NSPrincipalClass string NSApplication" \
  "$INFO_PLIST"

echo "$APP_BUNDLE"
