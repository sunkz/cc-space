#!/usr/bin/env bash
set -euo pipefail

APP_NAME="CCSpace"
BUILD_DIR=".build"

usage() {
    echo "Usage: $0 [build|run|test|lint|clean|readme-screenshots|help] [args]"
    echo ""
    echo "Commands:"
    echo "  build             - Build the debug executable with SwiftPM"
    echo "  run               - Build and launch the app bundle"
    echo "  test              - Run unit tests"
    echo "  lint              - Validate shell scripts and compile with warnings as errors"
    echo "  clean             - Remove SwiftPM build artifacts"
    echo "  readme-screenshots - Recreate only the README-referenced screenshots"
    echo "  help              - Show this help message"
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

    # Derive version from latest git tag
    local version
    version="$(git describe --tags --abbrev=0 2>/dev/null || echo "0.0.0")"
    version="${version#v}"

    ./script/package_app.sh \
        --binary "${build_binary}" \
        --output "${app_bundle}" \
        --version "${version}" >/dev/null

    /usr/bin/open -n "${app_bundle}"
}

cmd_test() {
    echo "=> Running tests..."
    swift test
}

cmd_lint() {
    echo "=> Validating shell scripts..."
    bash -n ./run.sh
    bash -n ./release.sh
    bash -n ./script/package_app.sh
    bash -n ./script/generate_readme_screenshots.sh

    echo "=> Building with warnings as errors..."
    swift build --product "${APP_NAME}" -Xswiftc -warnings-as-errors
}

cmd_clean() {
    echo "=> Cleaning build artifacts..."
    rm -rf "${BUILD_DIR}"
    rm -rf dist
    echo "=> Done."
}

cmd_readme_screenshots() {
    "./script/generate_readme_screenshots.sh" "$@"
}

COMMAND="${1:-run}"
shift || true

case "${COMMAND}" in
    build) cmd_build ;;
    run) cmd_run ;;
    test) cmd_test ;;
    lint) cmd_lint ;;
    clean) cmd_clean ;;
    readme-screenshots) cmd_readme_screenshots "$@" ;;
    help|-h|--help) usage ;;
    *)
        echo "Unknown command: ${COMMAND}"
        usage
        exit 1
        ;;
esac
