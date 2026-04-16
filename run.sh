#!/usr/bin/env bash
set -euo pipefail

APP_NAME="CCSpace"
BUILD_DIR=".build"

usage() {
    echo "Usage: $0 [build|run|test|clean|help]"
    echo ""
    echo "Commands:"
    echo "  build  - Build the debug executable with SwiftPM"
    echo "  run    - Build and launch the app bundle"
    echo "  test   - Run unit tests"
    echo "  clean  - Remove SwiftPM build artifacts"
    echo "  help   - Show this help message"
    echo ""
    echo "No arguments defaults to 'run'."
}

cmd_build() {
    echo "=> Building ${APP_NAME}..."
    swift build -c debug --product "${APP_NAME}"

    local debug_binary="${BUILD_DIR}/debug/${APP_NAME}"
    if [ -x "${debug_binary}" ]; then
        echo "=> Build succeeded: ${debug_binary}"
    else
        echo "=> Build finished, but executable not found at ${debug_binary}"
    fi
}

cmd_run() {
    pkill -x "${APP_NAME}" >/dev/null 2>&1 || true
    swift build -c debug --product "${APP_NAME}"
    local build_binary="${BUILD_DIR}/debug/${APP_NAME}"
    local dist_dir="./dist"
    local app_bundle="${dist_dir}/${APP_NAME}.app"
    local app_contents="${app_bundle}/Contents"
    local app_macos="${app_contents}/MacOS"
    local app_binary="${app_macos}/${APP_NAME}"
    local info_plist="${app_contents}/Info.plist"

    # Derive version from latest git tag
    local version
    version="$(git describe --tags --abbrev=0 2>/dev/null || echo "0.0.0")"
    version="${version#v}"

    rm -rf "${app_bundle}"
    mkdir -p "${app_macos}"
    cp "${build_binary}" "${app_binary}"
    chmod +x "${app_binary}"

    # Copy app icon
    local app_resources="${app_contents}/Resources"
    mkdir -p "${app_resources}"
    cp "Resources/AppIcon.icns" "${app_resources}/AppIcon.icns"

    cat >"${info_plist}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key>
  <string>com.ccspace.app</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${version}</string>
  <key>CFBundleVersion</key>
  <string>${version}</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

    /usr/bin/open -n "${app_bundle}"
}

cmd_test() {
    echo "=> Running tests..."
    swift test
}

cmd_clean() {
    echo "=> Cleaning build artifacts..."
    rm -rf "${BUILD_DIR}"
    rm -rf dist
    echo "=> Done."
}

COMMAND="${1:-run}"

case "${COMMAND}" in
    build) cmd_build ;;
    run) cmd_run ;;
    test) cmd_test ;;
    clean) cmd_clean ;;
    help|-h|--help) usage ;;
    *)
        echo "Unknown command: ${COMMAND}"
        usage
        exit 1
        ;;
esac
