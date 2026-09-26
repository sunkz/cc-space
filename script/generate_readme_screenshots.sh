#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
README_FILE="${ROOT_DIR}/README.md"
FIXTURE_DIR="${ROOT_DIR}/script/readme-screenshot-fixture"
SCREENSHOT_SKILL_DIR="${HOME}/.codex/skills/screenshot"

APP_NAME="CCSpace"
APP_BUNDLE="${ROOT_DIR}/dist/${APP_NAME}.app"
# 演示数据放在每次运行独立的临时目录:固定路径 + 反复 rm -rf 既留垃圾,
# 又会和并发/上一次未退出的运行互相踩。退出时由 cleanup trap 删除。
DEMO_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/CCSpaceDemo.XXXXXX")"
APP_SUPPORT_DIR="${DEMO_ROOT}/app-support"
DEFAULT_WINDOW_SIZE="960x640"
# 设置页区块较多(含 AI 服务),加高窗口避免底部区块被底边截断。
SETTINGS_WINDOW_SIZE="960x800"
SCREENSHOT_WORKPLACE_NAME="analytics-sprint"
CREATE_WORKPLACE_NAME="checkout-redesign"
CREATE_WORKPLACE_BRANCH="feature/checkout-redesign"
CREATE_SELECTED_REPOSITORIES="api-gateway,docs-portal,growth-dashboard,ios-app"
OUTPUT_ROOT="${ROOT_DIR}"

usage() {
    cat <<'EOF'
Usage: ./script/generate_readme_screenshots.sh [--output-root PATH]

Build the app, recreate the README demo data under a fresh temporary demo
root, then capture only the screenshots that README.md actually references
under docs/screenshots/real/. The demo root is removed on exit.

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
    # 演示数据目录随脚本退出一并回收(mktemp 目录不会自己消失)。
    if [[ -n "${DEMO_ROOT:-}" && -d "${DEMO_ROOT}" ]]; then
        rm -rf "${DEMO_ROOT}"
    fi
}

trap cleanup EXIT

build_app_bundle() {
    local version

    echo "=> Building ${APP_NAME}..."
    swift build -c debug --product "${APP_NAME}"

    version="$(git -C "${ROOT_DIR}" describe --tags --abbrev=0 2>/dev/null || echo "0.0.0")"
    version="${version#v}"

    # 复用统一的打包脚本,避免与 package_app.sh 各自维护一份 Info.plist 逻辑。
    rm -rf "${APP_BUNDLE}"
    "${ROOT_DIR}/script/package_app.sh" \
        --binary "${ROOT_DIR}/.build/debug/${APP_NAME}" \
        --output "${APP_BUNDLE}" \
        --version "${version}" >/dev/null
}

prepare_demo_data() {
    local workplace_name

    echo "=> Preparing demo data under ${DEMO_ROOT}..."
    mkdir -p "${APP_SUPPORT_DIR}" \
        "${DEMO_ROOT}/remotes" \
        "${DEMO_ROOT}/seeds" \
        "${DEMO_ROOT}/remote-workers" \
        "${DEMO_ROOT}/workspaces"

    cp "${FIXTURE_DIR}/settings.json" "${APP_SUPPORT_DIR}/settings.json"
    cp "${FIXTURE_DIR}/repositories.json" "${APP_SUPPORT_DIR}/repositories.json"
    cp "${FIXTURE_DIR}/workplaces.json" "${APP_SUPPORT_DIR}/workplaces.json"
    cp "${FIXTURE_DIR}/sync-states.json" "${APP_SUPPORT_DIR}/sync-states.json"

    # fixture 里的路径统一以 /tmp/CCSpaceDemo 为占位前缀;DEMO_ROOT 每次运行
    # 都是随机临时目录,复制后把占位前缀改写为本次的真实路径,否则 app 读到
    # 的 workplaceRootPath/各 localPath 会指向不存在的目录。
    python3 - "${DEMO_ROOT}" "${APP_SUPPORT_DIR}" <<'PY'
import json
import pathlib
import sys

demo_root = sys.argv[1]
support_dir = pathlib.Path(sys.argv[2])
placeholder = "/tmp/CCSpaceDemo"

for name in ("settings.json", "workplaces.json", "sync-states.json"):
    path = support_dir / name
    data = json.loads(path.read_text(encoding="utf-8"))
    text = json.dumps(data, ensure_ascii=False, indent=2)
    text = text.replace(placeholder, demo_root)
    path.write_text(text + "\n", encoding="utf-8")
PY

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
    local window_size="${DEFAULT_WINDOW_SIZE}"
    if [[ "${scenario}" == "settings-overview" ]]; then
        window_size="${SETTINGS_WINDOW_SIZE}"
    fi
    local -a open_command=(
        open
        -n
        -F
        --env "CCSPACE_APP_SUPPORT_DIR=${APP_SUPPORT_DIR}"
        --env "CCSPACE_WINDOW_SIZE=${window_size}"
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
