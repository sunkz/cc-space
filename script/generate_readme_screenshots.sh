#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
README_FILE="${ROOT_DIR}/README.md"
FIXTURE_DIR="${ROOT_DIR}/script/readme-screenshot-fixture"
SCREENSHOT_SKILL_DIR="${HOME}/.codex/skills/screenshot"

APP_NAME="CCSpace"
APP_BUNDLE="${ROOT_DIR}/dist/${APP_NAME}.app"
# 演示数据目录 DEMO_ROOT/APP_SUPPORT_DIR 的初始化挪到 trap cleanup EXIT 之后:
# 之前在参数解析前就 mktemp,传错参数 exit 1 时 trap 尚未安装、临时目录泄漏。
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

Environment:
  CCSPACE_SCREENSHOT_SETTLE_TRIES
                      窗口就绪采样上限(默认 40 次,≈20s)。窗口内容迟迟不稳定或
                      机器偏慢导致任务中止时,调大后重跑即可,不必改脚本。
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
        echo "本脚本依赖仓库外的私有 screenshot skill(不在本仓库内),请先安装到 ${SCREENSHOT_SKILL_DIR},见 README「README 截图」。" >&2
        exit 1
    }
    [[ -f "${SCREENSHOT_SKILL_DIR}/scripts/take_screenshot.py" ]] || {
        echo "Missing screenshot capture helper: ${SCREENSHOT_SKILL_DIR}/scripts/take_screenshot.py" >&2
        echo "本脚本依赖仓库外的私有 screenshot skill(不在本仓库内),请先安装到 ${SCREENSHOT_SKILL_DIR},见 README「README 截图」。" >&2
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

# 演示数据放在每次运行独立的临时目录:固定路径 + 反复 rm -rf 既留垃圾,
# 又会和并发/上一次未退出的运行互相踩。必须晚于上面的 trap:任何退出路径
# (含参数错误 / require_commands 失败)都已被 cleanup 覆盖,不会泄漏临时目录。
DEMO_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/CCSpaceDemo.XXXXXX")"
APP_SUPPORT_DIR="${DEMO_ROOT}/app-support"

build_app_bundle() {
    local version

    echo "=> Building ${APP_NAME}..."
    swift build -c debug --product "${APP_NAME}"

    # 版本推导统一走 script/version.sh(全局最新 tag),不再用 `git describe --tags
    # --abbrev=0`——分叉后它会取到旧 tag,与 run.sh 打包出的版本号互相矛盾。
    version="$("${ROOT_DIR}/script/version.sh")"

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
    # 不再固定 `sleep 1`:窗口就绪由调用方 wait_for_window_id 轮询,激活推迟到
    # 窗口出现之后(此刻 activate 只会因 app 尚未起窗口而静默失败)。
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

# 就绪信号:窗口像素内容连续 N 次采样哈希一致才认为渲染完成,替代固定 sleep。
# 固定 sleep 在慢机器上会截到还没加载完的列表、在快机器上纯浪费;轮询像素稳定性
# 两种情况都收敛。采样前先睡 floor 秒(沿用历史固定值作为下限),避免首帧空列表
# 在数据回来之前被误判为"已稳定"。
# 采样上限可用环境变量 CCSPACE_SCREENSHOT_SETTLE_TRIES 覆盖(默认 40,≈20s):
# 窗口里有持续变化元素(时间戳/闪烁光标/自动刷新)或机器偏慢、默认预算内凑不满
# 连续一致时,人工排查可调大后重跑,不必改脚本。
wait_for_window_settle() {
    local window_id="$1"
    local floor_seconds="$2"
    # 需连续 2 次比对一致、即 3 次采样哈希相同(stable: 0 -> 1 -> 2)才视为已稳定,
    # 单次相等只是相邻两帧碰巧一致。
    local stable_needed=2
    local max_attempts="${CCSPACE_SCREENSHOT_SETTLE_TRIES:-40}"
    if ! [[ "${max_attempts}" =~ ^[1-9][0-9]*$ ]]; then
        echo "  警告: CCSPACE_SCREENSHOT_SETTLE_TRIES='${max_attempts}' 不是正整数,回退默认 40" >&2
        max_attempts=40
    fi
    local attempt stable=0 prev_hash="" hash
    local shot_ok=0 shot_failed=0
    local settle_shot="${DEMO_ROOT}/window-settle.png"

    sleep "${floor_seconds}"

    for (( attempt = 1; attempt <= max_attempts; attempt++ )); do
        if python3 "${SCREENSHOT_SKILL_DIR}/scripts/take_screenshot.py" \
            --window-id "${window_id}" --path "${settle_shot}" >/dev/null 2>&1; then
            shot_ok=$((shot_ok + 1))
            hash="$(shasum -a 256 "${settle_shot}" | awk '{print $1}')"
            if [[ -n "${prev_hash}" && "${hash}" == "${prev_hash}" ]]; then
                stable=$((stable + 1))
                if [[ "${stable}" -ge "${stable_needed}" ]]; then
                    rm -f "${settle_shot}"
                    return 0
                fi
            else
                stable=0
            fi
            prev_hash="${hash}"
        else
            # 采样失败必须清空稳定计数与上一次哈希:否则失败前后两次成功采样
            # 会被算作"连续一致",把还在加载中的内容误判为已稳定。
            shot_failed=$((shot_failed + 1))
            stable=0
            prev_hash=""
        fi
        sleep 0.5
    done

    # 超时即失败(return 1)而不是继续截图:内容可能没加载完,警告只写 stderr 的话
    # 无人值守时极易被忽略,坏图会直接覆盖 README 现有截图。是否中止由调用方决定。
    rm -f "${settle_shot}"
    # 两种终态分开报:一次都没截成功时,"内容不稳定"是假象,真因是截图工具本身挂了
    # (权限被吊销、skill 脚本损坏等)——混成一句会让排查方向跑偏。
    if [[ "${shot_ok}" -eq 0 ]]; then
        echo "  错误: 截图工具连续 ${shot_failed} 次执行失败(${SCREENSHOT_SKILL_DIR}/scripts/take_screenshot.py),一次采样都没成功——请检查屏幕录制权限与该工具本身,这不是窗口内容不稳定" >&2
    else
        echo "  错误: 等待窗口内容稳定超时(共尝试 ${max_attempts} 次,其中成功采样 ${shot_ok} 次、截图命令失败 ${shot_failed} 次),截图内容可能未加载完整" >&2
    fi
    return 1
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

    # 先激活到前台:保证截图含焦点态、且窗口不被其它应用遮挡。
    osascript -e 'tell application "CCSpace" to activate' >/dev/null 2>&1 || true

    # 就绪等待:历史固定 sleep(settings 1s、其余 2s)作为下限保留,其后轮询像素
    # 稳定性替代继续硬等——内容加载慢时会自动多等,快时不浪费。
    local settle_floor=2
    if [[ "${scenario}" == "settings-overview" ]]; then
        settle_floor=1
    fi
    # 等待失败(超时)即中止**整个截图任务**(不是只跳过本场景):capture_target 只被
    # main 的 while 循环调用,这里的 exit 1 退出整个脚本、后续场景一张不截。刻意保持
    # 硬失败——跳过单个场景会让 README 呈现"前几个新图 + 后面旧图"的混合态,更糟;
    # 宁可这次一张不更新,也不让坏图或新旧混合态进 README。
    # 写在 if 条件里会让函数内部脱离 errexit,故 wait_for_window_settle 的失败模式
    # 已全部显式处理(采样失败 -> 视为未稳定),不依赖 set -e 兜底。
    if ! wait_for_window_settle "${window_id}" "${settle_floor}"; then
        pkill -x "${APP_NAME}" >/dev/null 2>&1 || true
        echo "   !! 中止整个截图任务(场景 ${scenario} 的就绪等待失败):${relative_target} 保持原图,后续场景不再截图,README 未被本次任务更新;失败详情见上方错误。" >&2
        echo "      可先调大 CCSPACE_SCREENSHOT_SETTLE_TRIES(当前默认 40 次采样)再重跑。" >&2
        exit 1
    fi

    osascript -e 'tell application "CCSpace" to activate' >/dev/null 2>&1 || true
    python3 "${SCREENSHOT_SKILL_DIR}/scripts/take_screenshot.py" \
        --window-id "${window_id}" \
        --path "${target_path}" >/dev/null
    pkill -x "${APP_NAME}" >/dev/null 2>&1 || true

    echo "   Saved to ${target_path}"
    sips -g pixelWidth -g pixelHeight "${target_path}" | sed 's/^/   /'
}

main() {
    local target targets targets_rc=0

    require_commands
    ensure_screenshot_permissions
    build_app_bundle
    prepare_demo_data

    # 先捕获输出再检查退出码:此前用进程替换 `done < <(readme_targets)` 读取目标,
    # 其非零退出码(README 无截图引用时 python 主动报错)不会传播到主管道——
    # 循环 0 次、main 返回 0,脚本"静默成功"却一张未截。命令替换中 stderr 不受
    # 捕获影响,仍直达终端,故只显式处理退出码与空列表两种失败。
    targets="$(readme_targets)" || targets_rc=$?
    if [[ "${targets_rc}" -ne 0 ]]; then
        echo "读取 README 截图目标失败(exit ${targets_rc}),中止。" >&2
        exit "${targets_rc}"
    fi
    if [[ -z "${targets}" ]]; then
        echo "README 截图目标列表为空,中止(README 未引用任何 docs/screenshots/real/ 图片?)。" >&2
        exit 1
    fi

    while IFS= read -r target; do
        [[ -n "${target}" ]] || continue
        capture_target "${target}"
    done <<< "${targets}"
}

main
