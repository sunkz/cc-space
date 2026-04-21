#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
README_FILE="${ROOT_DIR}/README.md"
FIXTURE_DIR="${ROOT_DIR}/script/readme-screenshot-fixture"
SCREENSHOT_SKILL_DIR="${HOME}/.codex/skills/screenshot"

APP_NAME="CCSpace"
APP_BUNDLE="${ROOT_DIR}/dist/${APP_NAME}.app"
APP_SUPPORT_DIR="/tmp/CCSpaceDemo/app-support"
DEMO_ROOT="/tmp/CCSpaceDemo"
WINDOW_SIZE="960x640"
SCREENSHOT_WORKPLACE_NAME="analytics-sprint"
CREATE_WORKPLACE_NAME="checkout-redesign"
CREATE_WORKPLACE_BRANCH="feature/checkout-redesign"
CREATE_SELECTED_REPOSITORIES="api-gateway,docs-portal,growth-dashboard,ios-app"
OUTPUT_ROOT="${ROOT_DIR}"

usage() {
    cat <<'EOF'
Usage: ./script/generate_readme_screenshots.sh [--output-root PATH]

Build the app, recreate the README demo data under /tmp/CCSpaceDemo, then
capture only the screenshots that README.md actually references under
docs/screenshots/real/.

Options:
  --output-root PATH  Write captured files under PATH/<relative README path>.
                      Defaults to the repository root, which updates the
                      canonical README screenshots in place.
  -h, --help          Show this help message.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output-root)
            [[ $# -ge 2 ]] || {
                echo "Missing value for --output-root" >&2
                exit 1
            }
            OUTPUT_ROOT="$2"
            shift 2
            ;;
        -h|--help)
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

require_commands() {
    local command_name
    for command_name in git open osascript python3 swift; do
        command -v "${command_name}" >/dev/null 2>&1 || {
            echo "Missing required command: ${command_name}" >&2
            exit 1
        }
    done

    [[ -f "${SCREENSHOT_SKILL_DIR}/scripts/ensure_macos_permissions.sh" ]] || {
        echo "Missing screenshot permission helper: ${SCREENSHOT_SKILL_DIR}/scripts/ensure_macos_permissions.sh" >&2
        exit 1
    }
    [[ -f "${SCREENSHOT_SKILL_DIR}/scripts/take_screenshot.py" ]] || {
        echo "Missing screenshot capture helper: ${SCREENSHOT_SKILL_DIR}/scripts/take_screenshot.py" >&2
        exit 1
    }
}

cleanup() {
    pkill -x "${APP_NAME}" >/dev/null 2>&1 || true
}

trap cleanup EXIT

build_app_bundle() {
    local build_binary
    local app_contents
    local app_macos
    local app_resources
    local info_plist
    local version

    echo "=> Building ${APP_NAME}..."
    swift build -c debug --product "${APP_NAME}"

    build_binary="${ROOT_DIR}/.build/debug/${APP_NAME}"
    app_contents="${APP_BUNDLE}/Contents"
    app_macos="${app_contents}/MacOS"
    app_resources="${app_contents}/Resources"
    info_plist="${app_contents}/Info.plist"

    version="$(git -C "${ROOT_DIR}" describe --tags --abbrev=0 2>/dev/null || echo "0.0.0")"
    version="${version#v}"

    rm -rf "${APP_BUNDLE}"
    mkdir -p "${app_macos}" "${app_resources}"
    cp "${build_binary}" "${app_macos}/${APP_NAME}"
    chmod +x "${app_macos}/${APP_NAME}"
    cp "${ROOT_DIR}/Resources/AppIcon.icns" "${app_resources}/AppIcon.icns"

    cat > "${info_plist}" <<PLIST
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
}

prepare_demo_data() {
    local workplace_name

    echo "=> Preparing demo data under ${DEMO_ROOT}..."
    rm -rf "${DEMO_ROOT}"
    mkdir -p "${APP_SUPPORT_DIR}" \
        "${DEMO_ROOT}/remotes" \
        "${DEMO_ROOT}/seeds" \
        "${DEMO_ROOT}/remote-workers" \
        "${DEMO_ROOT}/workspaces"

    cp "${FIXTURE_DIR}/settings.json" "${APP_SUPPORT_DIR}/settings.json"
    cp "${FIXTURE_DIR}/repositories.json" "${APP_SUPPORT_DIR}/repositories.json"
    cp "${FIXTURE_DIR}/workplaces.json" "${APP_SUPPORT_DIR}/workplaces.json"
    cp "${FIXTURE_DIR}/sync-states.json" "${APP_SUPPORT_DIR}/sync-states.json"

    for workplace_name in \
        analytics-sprint \
        growth-experiment \
        ios-release \
        docs-refresh \
        ops-hotfix \
        marketing-weekly; do
        mkdir -p "${DEMO_ROOT}/workspaces/${workplace_name}"
    done

    create_repo_fixture "api-gateway" "dirty"
    create_repo_fixture "ios-app" "clean"
    create_repo_fixture "release-tools" "ahead"
    create_repo_fixture "shared-ui" "behind"
}

git_configure_demo_identity() {
    local repository_path="$1"

    git -C "${repository_path}" config user.name "CCSpace Demo"
    git -C "${repository_path}" config user.email "demo@ccspace.local"
}

create_repo_fixture() {
    local repo_name="$1"
    local repo_state="$2"
    local remote_path="${DEMO_ROOT}/remotes/${repo_name}.git"
    local seed_path="${DEMO_ROOT}/seeds/${repo_name}"
    local worker_path="${DEMO_ROOT}/remote-workers/${repo_name}"
    local local_path="${DEMO_ROOT}/workspaces/analytics-sprint/${repo_name}"

    git init --bare "${remote_path}" >/dev/null
    git -C "${remote_path}" symbolic-ref HEAD refs/heads/main

    git init -b main "${seed_path}" >/dev/null
    git_configure_demo_identity "${seed_path}"
    printf '# %s\n' "${repo_name}" > "${seed_path}/README.md"
    printf '%s baseline\n' "${repo_name}" > "${seed_path}/status.txt"
    git -C "${seed_path}" add README.md status.txt
    git -C "${seed_path}" commit -m "Initial commit" >/dev/null
    git -C "${seed_path}" remote add origin "${remote_path}"
    git -C "${seed_path}" push -u origin main >/dev/null

    git -C "${seed_path}" switch -c "feature/analytics-dashboard" >/dev/null
    printf '%s feature baseline\n' "${repo_name}" >> "${seed_path}/status.txt"
    git -C "${seed_path}" add status.txt
    git -C "${seed_path}" commit -m "Feature baseline" >/dev/null
    git -C "${seed_path}" push -u origin "feature/analytics-dashboard" >/dev/null

    git clone "${remote_path}" "${local_path}" >/dev/null
    git_configure_demo_identity "${local_path}"
    git -C "${local_path}" checkout "feature/analytics-dashboard" >/dev/null

    case "${repo_state}" in
        dirty)
            printf 'worktree change\n' >> "${local_path}/status.txt"
            ;;
        clean)
            ;;
        ahead)
            printf 'local ahead\n' >> "${local_path}/status.txt"
            git -C "${local_path}" add status.txt
            git -C "${local_path}" commit -m "Local ahead change" >/dev/null
            ;;
        behind)
            git clone "${remote_path}" "${worker_path}" >/dev/null
            git_configure_demo_identity "${worker_path}"
            git -C "${worker_path}" checkout "feature/analytics-dashboard" >/dev/null
            printf 'remote ahead\n' >> "${worker_path}/status.txt"
            git -C "${worker_path}" add status.txt
            git -C "${worker_path}" commit -m "Remote ahead change" >/dev/null
            git -C "${worker_path}" push >/dev/null
            git -C "${local_path}" fetch origin >/dev/null
            rm -rf "${worker_path}"
            ;;
        *)
            echo "Unknown repo fixture state: ${repo_state}" >&2
            exit 1
            ;;
    esac
}

readme_targets() {
    python3 - "${README_FILE}" <<'PY'
import pathlib
import re
import sys

readme = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
seen = []
for path in re.findall(r'!\[[^\]]*\]\(([^)]+)\)', readme):
    if path.startswith("docs/screenshots/real/") and path.endswith(".png") and path not in seen:
        seen.append(path)

if not seen:
    raise SystemExit("No README screenshot targets found under docs/screenshots/real/")

print("\n".join(seen))
PY
}

scenario_for_target() {
    local target_basename="$1"

    case "${target_basename}" in
        settings-overview.png)
            printf 'settings-overview'
            ;;
        create-workplace.png)
            printf 'create-workplace'
            ;;
        workplace-detail.png)
            printf 'workplace-detail'
            ;;
        *)
            echo "README references an unsupported screenshot target: ${target_basename}" >&2
            exit 1
            ;;
    esac
}

launch_for_scenario() {
    local scenario="$1"
    local -a open_command=(
        open
        -n
        -F
        --env "CCSPACE_APP_SUPPORT_DIR=${APP_SUPPORT_DIR}"
        --env "CCSPACE_WINDOW_SIZE=${WINDOW_SIZE}"
        --env "CCSPACE_SCREENSHOT_SCENE=${scenario}"
        --env "CCSPACE_SCREENSHOT_WORKPLACE_NAME=${SCREENSHOT_WORKPLACE_NAME}"
    )

    if [[ "${scenario}" == "create-workplace" ]]; then
        open_command+=(
            --env "CCSPACE_SCREENSHOT_CREATE_NAME=${CREATE_WORKPLACE_NAME}"
            --env "CCSPACE_SCREENSHOT_CREATE_BRANCH=${CREATE_WORKPLACE_BRANCH}"
            --env "CCSPACE_SCREENSHOT_CREATE_SELECTED_REPOSITORIES=${CREATE_SELECTED_REPOSITORIES}"
        )
    fi

    open_command+=("${APP_BUNDLE}")

    pkill -x "${APP_NAME}" >/dev/null 2>&1 || true
    "${open_command[@]}" >/dev/null
    sleep 1
    osascript -e 'tell application "CCSpace" to activate' >/dev/null 2>&1 || true
}

window_id_for_app() {
    OWNER_NAME="${APP_NAME}" swift -e '
import CoreGraphics
import Foundation

let ownerName = ProcessInfo.processInfo.environment["OWNER_NAME"] ?? ""
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []

for window in windows {
    let windowOwner = window[kCGWindowOwnerName as String] as? String ?? ""
    let windowLayer = window[kCGWindowLayer as String] as? Int ?? 0

    guard windowOwner == ownerName, windowLayer == 0 else {
        continue
    }

    if let windowID = window[kCGWindowNumber as String] as? Int {
        print(windowID)
        break
    }
}
'
}

wait_for_window_id() {
    local attempt
    local window_id=""

    for attempt in {1..40}; do
        window_id="$(window_id_for_app | head -n 1 | tr -d '\n')"
        if [[ -n "${window_id}" ]]; then
            printf '%s' "${window_id}"
            return 0
        fi
        sleep 0.25
    done

    echo "Timed out waiting for ${APP_NAME} window" >&2
    exit 1
}

ensure_screenshot_permissions() {
    bash "${SCREENSHOT_SKILL_DIR}/scripts/ensure_macos_permissions.sh" >/dev/null
}

capture_target() {
    local relative_target="$1"
    local target_path="${OUTPUT_ROOT}/${relative_target}"
    local target_dir
    local target_basename
    local scenario
    local window_id

    target_dir="$(dirname "${target_path}")"
    target_basename="$(basename "${relative_target}")"
    scenario="$(scenario_for_target "${target_basename}")"

    mkdir -p "${target_dir}"

    echo "=> Capturing ${relative_target} (${scenario})..."
    launch_for_scenario "${scenario}"
    window_id="$(wait_for_window_id)"
    if [[ -z "${window_id}" ]]; then
        echo "Failed to find a visible ${APP_NAME} window before capture" >&2
        exit 1
    fi

    case "${scenario}" in
        settings-overview)
            sleep 1
            ;;
        workplace-detail|create-workplace)
            sleep 2
            ;;
    esac

    osascript -e 'tell application "CCSpace" to activate' >/dev/null 2>&1 || true
    python3 "${SCREENSHOT_SKILL_DIR}/scripts/take_screenshot.py" \
        --window-id "${window_id}" \
        --path "${target_path}" >/dev/null
    pkill -x "${APP_NAME}" >/dev/null 2>&1 || true

    echo "   Saved to ${target_path}"
    sips -g pixelWidth -g pixelHeight "${target_path}" | sed 's/^/   /'
}

main() {
    local target

    require_commands
    ensure_screenshot_permissions
    build_app_bundle
    prepare_demo_data

    while IFS= read -r target; do
        [[ -n "${target}" ]] || continue
        capture_target "${target}"
    done < <(readme_targets)
}

main
