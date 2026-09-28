#!/usr/bin/env bash
set -euo pipefail

# 统一取仓库根目录并切入，保证从任意 cwd 调用（如 cd /tmp && bash <repo>/run.sh build）都能工作
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

APP_NAME="CCSpace"
BUILD_DIR="${ROOT_DIR}/.build"

usage() {
    echo "Usage: $0 [build|run|test|coverage|lint|clean|readme-screenshots|help] [args]"
    echo ""
    echo "Commands:"
    echo "  build             - Build the debug executable with SwiftPM"
    echo "  run               - Build and launch the app bundle"
    echo "  test              - Run unit tests"
    echo "  coverage          - Run unit tests and print coverage summary + LCOV path"
    echo "  lint              - Validate shell scripts/workflow YAML and compile with warnings as errors"
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
        exit 1
    fi
}

cmd_run() {
    swift build -c debug --product "${APP_NAME}"
    # 构建成功后才杀掉旧实例:构建失败时保留正在调试的 app,不用手动重启。
    pkill -x "${APP_NAME}" >/dev/null 2>&1 || true
    local build_binary="${BUILD_DIR}/debug/${APP_NAME}"
    local dist_dir="${ROOT_DIR}/dist"
    local app_bundle="${dist_dir}/${APP_NAME}.app"

    # Derive version from latest tag
    # 推导逻辑统一在 script/version.sh(用全局最新 tag 而非 describe 的原因见其注释),
    # 与 generate_readme_screenshots.sh 共用,避免两份实现漂移。
    local version
    version="$("${ROOT_DIR}/script/version.sh")"

    "${ROOT_DIR}/script/package_app.sh" \
        --binary "${build_binary}" \
        --output "${app_bundle}" \
        --version "${version}" >/dev/null

    # Xcode 27 beta 的 SwiftPM 会把 LC_BUILD_VERSION 的 sdk 字段记成 deployment target
    # (14.0),AppKit 据此判定为"macOS 26 SDK 之前链接"而回退旧外观,本地调试看不到
    # Liquid Glass。这里把 sdk 字段改写为本机 SDK 版本并重签,与 CI 发布产物一致;
    # 部署目标保持 14.0 不变。老工具链没有 vtool 或 SDK < 26 时静默跳过。
    local app_binary="${app_bundle}/Contents/MacOS/${APP_NAME}"
    local host_sdk_version
    host_sdk_version="$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || echo "0")"
    # xcrun 输出空串/非数值(异常工具链)时,[ ... -ge 26 ] 会以 "integer expression
    # expected" 语法错在 set -e 下直接中断 cmd_run。非数值一律按老工具链处理(跳过补丁)。
    local host_sdk_major="${host_sdk_version%%.*}"
    [[ "${host_sdk_major}" =~ ^[0-9]+$ ]] || host_sdk_major="0"
    if command -v vtool >/dev/null 2>&1 \
        && [ "${host_sdk_major}" -ge 26 ] \
        && [ -f "${app_binary}" ]; then
        # vtool 失败必须可见:此前 `|| true` 吞错后仍无条件打印 "Patched",
        # 真失败(二进制不接受 -replace 等)会误导排查。补丁只影响外观,失败不阻断启动。
        # 输出到临时文件、成功后再 mv 覆盖:vtool 以同一文件作输入与 -output 属原位重写,
        # 中途失败(磁盘满/进程被杀)会留下损坏的二进制。
        local patch_output patch_tmp="${app_binary}.vtool-tmp.$$"
        if ! patch_output="$(vtool -set-build-version macos 14.0 "${host_sdk_version}" -replace \
            -output "${patch_tmp}" "${app_binary}" 2>&1)" || ! mv -f "${patch_tmp}" "${app_binary}"; then
            rm -f "${patch_tmp}"
            echo "=> WARNING: vtool patch failed, macOS 26 appearance may not apply:" >&2
            echo "${patch_output}" >&2
        elif codesign --force -s - "${app_binary}" >/dev/null 2>&1; then
            echo "=> Patched linked SDK version to ${host_sdk_version} (enables macOS 26 appearance)"
        else
            echo "=> WARNING: patched but ad-hoc re-sign failed; app may be killed on launch" >&2
        fi
    fi

    /usr/bin/open -n "${app_bundle}"
}

# 定位测试 bundle 并回显路径(找不到时回显空串,由调用方给出上下文报错)。
# 动态查找而非硬编码:测试产物名随工具链漂移——**本机工具链**在 bin 目录产出
# CCSpaceTests.xctest,**CI runner 工具链**只产出 CCSpacePackageTests.xctest
# (实测 v0.0.2 绿色构建日志:只有 `Linking CCSpacePackageTests`,xctest 驱动的
# 也是 CCSpacePackageTests.xctest)。写死任一名字都会在另一侧直接找不到,
# 所以两边都找不到时不能就此放弃。
# 查找顺序(三级,逐级放宽):
#   1) 精确匹配 CCSpaceTests.xctest——本机产物存在时优先;
#   2) 其余 *.xctest 中排除 *PackageTests*——多 bundle 并存时优先非聚合 bundle;
#   3) 任意 *.xctest——兜底**必须放行** *PackageTests*:CI 上它是唯一产物,
#      早期版本在这一级排除它,导致 runner 上两条分支都落空、必然
#      "Test bundle not found"(本机因命中第 1 级而始终变绿,掩盖了该回归)。
# 三级都限定 -type d:同名**普通文件**不是 bundle,[ -e ] 会放行、
# `xcrun xctest <file>` 只报难懂错误,SwiftPM 也不清理已删 target 的旧产物。
# 第 2、3 级在 head 前加 LC_ALL=C sort:多个候选并存时取排序后的第一个,
# 选中谁不再取决于 readdir 顺序(换机器/文件系统结果漂移);第 1 级名字唯一,无需排序。
# `|| true` 防 find 失败时 pipefail 让赋值处静默退出、绕过调用方的友好报错(与 CI 对齐),
# 同时覆盖 find/sort 被 head 提前关管道触发的 SIGPIPE(实测无它时 pipeline status=141)。
locate_test_bundle() {
    local bin_path="$1"
    local test_bundle=""
    test_bundle="$(find "${bin_path}" -maxdepth 1 -type d -name "CCSpaceTests.xctest" | head -n 1 || true)"
    if [ -z "${test_bundle}" ]; then
        test_bundle="$(find "${bin_path}" -maxdepth 1 -type d -name "*.xctest" ! -name "*PackageTests*" | LC_ALL=C sort | head -n 1 || true)"
    fi
    if [ -z "${test_bundle}" ]; then
        test_bundle="$(find "${bin_path}" -maxdepth 1 -type d -name "*.xctest" | LC_ALL=C sort | head -n 1 || true)"
    fi
    printf '%s' "${test_bundle}"
}

cmd_test() {
    echo "=> Building tests..."
    # 与 cmd_lint 的构建 flag 完全一致(--build-tests + warnings-as-errors):
    # 两处 flag 不同时,lint/test 交替执行会互相触发全量重编译(CI 上是两次冷编译),
    # 且测试代码自身的 warning 也要纳入门禁。
    swift build --build-tests -Xswiftc -warnings-as-errors

    local bin_path test_bundle
    bin_path="$(swift build --show-bin-path)"
    test_bundle="$(locate_test_bundle "${bin_path}")"
    if [ -z "${test_bundle}" ] || [ ! -e "${test_bundle}" ]; then
        echo "=> Test bundle not found under: ${bin_path}"
        exit 1
    fi

    echo "=> Running tests..."
    # 与 CI 保持一致,不走 `swift test`:2026-09 起部分 macOS runner 镜像(以及个别
    # 本地工具链组合)上 swift-package 测试执行器与 xctest 之间会确定性死锁——
    # 测试跑到 ~50s 后无限无输出、两个进程都存活。直接驱动 xctest 绕开该执行器。
    xcrun xctest "${test_bundle}"
}

cmd_coverage() {
    echo "=> Building tests with code coverage..."
    # 除 --enable-code-coverage 外与 cmd_lint/cmd_test 的 flag 一致;正因为多了
    # 这个 flag,coverage 与 test/lint 互相切换时仍会触发重编译(切换回 test/lint
    # 同样重编一次),coverage 内部多次执行才是增量的。
    swift build --build-tests --enable-code-coverage -Xswiftc -warnings-as-errors

    local bin_path test_bundle test_binary profdata_raw profdata lcov_path
    bin_path="$(swift build --show-bin-path)"
    test_bundle="$(locate_test_bundle "${bin_path}")"
    if [ -z "${test_bundle}" ] || [ ! -e "${test_bundle}" ]; then
        echo "=> Test bundle not found under: ${bin_path}"
        exit 1
    fi
    # LC_ALL=C sort 对齐 locate_test_bundle 的标准:目录内多文件时选中谁
    # 不再取决于 readdir 顺序(换机器/文件系统结果漂移)。
    test_binary="$(find "${test_bundle}/Contents/MacOS" -maxdepth 1 -type f | LC_ALL=C sort | head -n 1 || true)"
    if [ -z "${test_binary}" ] || [ ! -f "${test_binary}" ]; then
        echo "=> Test executable not found under: ${test_bundle}/Contents/MacOS"
        exit 1
    fi

    echo "=> Running tests (coverage)..."
    # 绕开 swift test(死锁见 cmd_test),也不依赖它注入的覆盖率环境变量:
    # LLVM_PROFILE_FILE 显式指定原始 profile 落盘位置,否则 xctest 直接驱动时
    # 覆盖率数据可能写到无从查找的默认路径。
    local profile_dir="${bin_path}/coverage-profile"
    rm -rf "${profile_dir}"
    mkdir -p "${profile_dir}"
    LLVM_PROFILE_FILE="${profile_dir}/%p-%m.profraw" xcrun xctest "${test_bundle}"

    profdata_raw="$(find "${profile_dir}" -name '*.profraw' | head -n 1 || true)"
    if [ -z "${profdata_raw}" ]; then
        echo "=> No .profraw profile produced under: ${profile_dir}"
        exit 1
    fi
    profdata="${bin_path}/coverage.profdata"
    # merge 该目录下全部 raw(不止第一个):多进程/多次运行会各写一份。
    xcrun llvm-profdata merge -o "${profdata}" "${profile_dir}"/*.profraw

    echo "=> Coverage summary:"
    # -ignore-filename-regex 只统计本仓库源码,排除 .build 里的依赖与生成物。
    xcrun llvm-cov report \
        -instr-profile "${profdata}" \
        -ignore-filename-regex='\.build/|Tests/CCSpaceTests/TestSupport/' \
        "${test_binary}"

    lcov_path="${bin_path}/coverage.lcov"
    xcrun llvm-cov export -format=lcov \
        -instr-profile "${profdata}" \
        -ignore-filename-regex='\.build/|Tests/CCSpaceTests/TestSupport/' \
        "${test_binary}" > "${lcov_path}"
    echo "=> LCOV written to: ${lcov_path}"
}

cmd_lint() {
    echo "=> Validating shell scripts..."
    # 遍历而非硬编码清单,新增脚本自动纳入语法校验。
    local script
    local -a shell_scripts=()
    for script in "${ROOT_DIR}"/*.sh "${ROOT_DIR}"/script/*.sh; do
        [ -f "${script}" ] || continue
        bash -n "${script}"
        shell_scripts+=("${script}")
    done

    # 静态检查:bash -n 只查语法,查不出未加引号的变量展开等运行期问题。
    # shellcheck 是**可选的本地增强、结果不作门禁**:GitHub 的 macOS runner 镜像
    # 未预装 shellcheck,CI 上永远走跳过分支;若让它在本机阻断 lint,会出现
    # "本地红、CI 绿"的不一致,还会连带把 release.sh 的推 tag 门禁一起挡住。
    # 因此装了也只提示不阻断;没装则跳过——两者都不代表脚本通过了静态检查。
    if command -v shellcheck >/dev/null 2>&1; then
        echo "=> Running shellcheck (仅提示,不作门禁)..."
        if ! shellcheck "${shell_scripts[@]}"; then
            echo "=> shellcheck 发现问题(shellcheck 非门禁,不阻断 lint;请自行修复)" >&2
        fi
    else
        echo "=> shellcheck 未安装,已跳过(可选增强、不作门禁;跳过不代表通过。安装: brew install shellcheck)"
    fi

    # workflows YAML 可解析性:缩进/引号写错在 bash -n 与编译门禁下都查不到,
    # 要等 push 到 GitHub 才报错。python3 或 PyYAML 缺失时同样优雅降级。
    if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
        echo "=> Validating workflow YAML..."
        python3 - "${ROOT_DIR}" <<'PY'
import pathlib
import sys
import yaml

root = pathlib.Path(sys.argv[1])
workflow_dir = root / ".github" / "workflows"
files = sorted(workflow_dir.glob("*.yml")) + sorted(workflow_dir.glob("*.yaml"))
if not files:
    raise SystemExit(f"未找到任何 workflow 文件: {workflow_dir}")
for path in files:
    yaml.safe_load(path.read_text(encoding="utf-8"))
    print(f"   OK {path.relative_to(root)}")
PY
    else
        echo "=> python3/PyYAML 不可用,已跳过 workflow YAML 校验"
    fi

    echo "=> Building with warnings as errors..."
    # --build-tests:测试 target 的 warning 同样纳入门禁。
    # 注意:此 flag 组合必须与 cmd_test 保持一致,否则两者交替执行会全量重编译。
    swift build --build-tests -Xswiftc -warnings-as-errors
}

cmd_clean() {
    echo "=> Cleaning build artifacts..."
    rm -rf "${BUILD_DIR}"
    rm -rf "${ROOT_DIR}/dist"
    echo "=> Done."
}

cmd_readme_screenshots() {
    "${ROOT_DIR}/script/generate_readme_screenshots.sh" "$@"
}

COMMAND="${1:-run}"
shift || true

case "${COMMAND}" in
    build) cmd_build ;;
    run) cmd_run ;;
    test) cmd_test ;;
    coverage) cmd_coverage ;;
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
