#!/usr/bin/env bash
set -euo pipefail

# 统一取仓库根目录并切入，保证从任意 cwd 调用（如 cd /tmp && bash <repo>/run.sh build）都能工作
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

APP_NAME="CCSpace"
BUILD_DIR="${ROOT_DIR}/.build"

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
    # 用全局最新 tag 而非 `describe --tags --abbrev=0`(HEAD 最近可达 tag):
    # 分支分叉后后者会取到旧 tag,本地跑的 app 版本号与最新发布不一致。
    local version
    version="$(git -C "${ROOT_DIR}" tag --list 'v[0-9]*' --sort=-version:refname 2>/dev/null \
        | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1 || true)"
    version="${version:-v0.0.0}"
    version="${version#v}"

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
    if command -v vtool >/dev/null 2>&1 \
        && [ "${host_sdk_version%%.*}" -ge 26 ] \
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

cmd_test() {
    echo "=> Building tests..."
    swift build --build-tests

    local bin_path test_bundle
    bin_path="$(swift build --show-bin-path)"
    # 动态查找而非硬编码:SwiftPM 的测试产物名随包/产品结构变化(本机是
    # CCSpaceTests.xctest,写死 CCSpacePackageTests.xctest 会直接找不到)。
    # `|| true` 防 find 失败时 pipefail 让赋值处静默退出、绕过下面的友好报错(与 CI 对齐)。
    test_bundle="$(find "${bin_path}" -maxdepth 1 -name "*.xctest" | head -n 1 || true)"
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

cmd_lint() {
    echo "=> Validating shell scripts..."
    # 遍历而非硬编码清单,新增脚本自动纳入语法校验。
    local script
    for script in "${ROOT_DIR}"/*.sh "${ROOT_DIR}"/script/*.sh; do
        [ -f "${script}" ] || continue
        bash -n "${script}"
    done

    echo "=> Building with warnings as errors..."
    # --build-tests:测试 target 的 warning 同样纳入门禁。
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
