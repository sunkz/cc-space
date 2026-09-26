#!/usr/bin/env bash
set -euo pipefail

APP_NAME="CCSpace"
DISPLAY_NAME="CCSpace"
BUNDLE_ID="com.ccspace.app"
MINIMUM_SYSTEM_VERSION="14.0"
# 图标路径锚定到脚本自身位置(仓库根/Resources):不依赖调用方的 cwd。
ICON_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/Resources/AppIcon.icns"

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

# 删除旧 bundle 前的防护：--output 可能是任意路径，
# 只允许删除以 .app 结尾且不是符号链接的目标，避免误删用户数据。
if [[ "$APP_BUNDLE" != *.app ]]; then
  echo "拒绝执行: --output 路径必须以 .app 结尾，拒绝删除非 .app 路径: $APP_BUNDLE" >&2
  exit 1
fi
if [[ -L "$APP_BUNDLE" ]]; then
  echo "拒绝执行: 输出路径是符号链接，拒绝删除: $APP_BUNDLE" >&2
  exit 1
fi

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BINARY_PATH" "$APP_BINARY"
chmod +x "$APP_BINARY"
cp "$ICON_PATH" "$APP_RESOURCES/AppIcon.icns"

# 值统一内层双引号:PlistBuddy 的 -c 命令串按空格切词,
# DISPLAY_NAME/APP_NAME 等含空格时必须让 PlistBuddy 看到带引号的值,否则 Add 失败。
/usr/libexec/PlistBuddy \
  -c "Clear dict" \
  -c "Add :CFBundleExecutable string \"$APP_NAME\"" \
  -c "Add :CFBundleIdentifier string \"$BUNDLE_ID\"" \
  -c "Add :CFBundleIconFile string AppIcon" \
  -c "Add :CFBundleName string \"$DISPLAY_NAME\"" \
  -c "Add :CFBundlePackageType string APPL" \
  -c "Add :CFBundleShortVersionString string \"$VERSION\"" \
  -c "Add :CFBundleVersion string \"$VERSION\"" \
  -c "Add :LSMinimumSystemVersion string \"$MINIMUM_SYSTEM_VERSION\"" \
  -c "Add :NSPrincipalClass string NSApplication" \
  "$INFO_PLIST"

echo "$APP_BUNDLE"
