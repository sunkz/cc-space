#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
README_FILE="${ROOT_DIR}/README.md"
FIXTURE_DIR="${ROOT_DIR}/script/readme-screenshot-fixture"

APP_NAME="CCSpace"
APP_BUNDLE="${ROOT_DIR}/dist/${APP_NAME}.app"
# 演示数据目录 DEMO_ROOT/APP_SUPPORT_DIR 的初始化挪到 trap cleanup EXIT 之后:
# 之前在参数解析前就 mktemp,传错参数 exit 1 时 trap 尚未安装、临时目录泄漏。
DEFAULT_WINDOW_SIZE="960x640"
# 设置页区块较多,加高窗口避免底部区块被底边截断。
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
    for command_name in git open osascript python3 swift screencapture; do
        command -v "${command_name}" >/dev/null 2>&1 || {
            echo "Missing required command: ${command_name}" >&2
            exit 1
        }
    done
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

    # 必须补 SDK 字段:未打的产物被 AppKit 判定为旧 SDK 链接、回退旧外观,
    # README 里就会是一批老样子的截图(补丁与 run.sh 共用同一份实现)。
    "${ROOT_DIR}/script/patch_app_sdk.sh" \
        --binary "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
}

prepare_demo_data() {
    echo "=> Preparing demo data under ${DEMO_ROOT}..."

    # 截图与手动演示共用同一份生成器:所有工作区都会真实克隆,侧栏不会出现"未克隆"红点,
    # 详情页也覆盖 clean / dirty / ahead / behind / diverged / stash 六种状态。
    # mktemp 目录没有标记文件,make_demo_data.sh 会拒绝清空,先补上。
    touch "${DEMO_ROOT}/.ccspace-demo-root"
    CCSPACE_DEMO_ROOT="${DEMO_ROOT}" "${ROOT_DIR}/script/make_demo_data.sh" >/dev/null

    # make_demo_data.sh 会把 gitURL 改写成真实的本地 bare 路径(否则磁盘刷新会判"来源不符");
    # 截图里还原成 fixture 的展示地址,设置页才不会被一长串临时目录占满。
    python3 - "${APP_SUPPORT_DIR}" "${FIXTURE_DIR}" <<'PY'
import json
import pathlib
import sys

support_dir = pathlib.Path(sys.argv[1])
fixture_dir = pathlib.Path(sys.argv[2])

display_urls = {
    repo["id"]: repo["gitURL"]
    for repo in json.loads((fixture_dir / "repositories.json").read_text(encoding="utf-8"))
}

path = support_dir / "repositories.json"
repositories = json.loads(path.read_text(encoding="utf-8"))
for repository in repositories:
    repository["gitURL"] = display_urls.get(repository["id"], repository["gitURL"])
path.write_text(json.dumps(repositories, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY
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

# 按 window id 抓单个窗口。不带 -o,保留窗口阴影——仓库现有 3 张正式截图就是
# 含阴影的取景(产物带 alpha,四边是阴影的透明留白),对齐才不会让 README 图忽大忽小。
capture_window() {
    local window_id="$1"
    local output_path="$2"

    screencapture -x -l"${window_id}" "${output_path}" >/dev/null 2>&1
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
        if capture_window "${window_id}" "${settle_shot}"; then
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
        echo "  错误: 截图命令连续 ${shot_failed} 次执行失败(screencapture -x -l${window_id}),一次采样都没成功——请检查屏幕录制权限与该命令本身,这不是窗口内容不稳定" >&2
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
    if ! capture_window "${window_id}" "${target_path}"; then
        pkill -x "${APP_NAME}" >/dev/null 2>&1 || true
        echo "   !! screencapture 截图失败:${relative_target} 未更新(窗口 id ${window_id}),请检查屏幕录制权限。" >&2
        exit 1
    fi
    pkill -x "${APP_NAME}" >/dev/null 2>&1 || true

    echo "   Saved to ${target_path}"
    sips -g pixelWidth -g pixelHeight "${target_path}" | sed 's/^/   /'
}

main() {
    local target targets targets_rc=0

    require_commands
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
