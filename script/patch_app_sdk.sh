#!/usr/bin/env bash
set -euo pipefail

# 把 app 二进制的 LC_BUILD_VERSION sdk 字段改写为本机 SDK 版本并 ad-hoc 重签。
#
# 为什么需要:Xcode 27 beta 的 SwiftPM 会把 LC_BUILD_VERSION 的 sdk 字段记成
# deployment target(14.0),AppKit 据此判定为"macOS 26 SDK 之前链接"而回退旧外观,
# 本地产物看不到新样式。部署目标保持 14.0 不变。
#
# 调用方:run.sh 与 script/generate_readme_screenshots.sh 共用(沿用 version.sh 的
# 先例,不在两处各写一份)。CI 发布产物**不**走这里——release.yml 打包后还要用真实
# 身份签名并公证,ad-hoc 重签只适用于本地产物。
#
# 补丁只影响外观:老工具链没有 vtool、本机 SDK < 26、或补丁本身失败,都只告警不阻断,
# 一律 exit 0——调用方在 set -e 下跑,可选补丁不能中断构建。

usage() {
  cat <<'EOF'
Usage: $0 --binary PATH

Rewrite the app binary's LC_BUILD_VERSION sdk field to the host SDK version and
ad-hoc re-sign it, so AppKit applies the modern macOS appearance to local builds.
EOF
}

BINARY_PATH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --binary)
      if [[ $# -lt 2 || -z "$2" ]]; then
        echo "Missing value for --binary" >&2
        usage >&2
        exit 1
      fi
      BINARY_PATH="$2"
      shift 2
      ;;
    help | -h | --help)
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

if [[ -z "${BINARY_PATH}" ]]; then
  echo "Missing required option: --binary" >&2
  usage >&2
  exit 1
fi

host_sdk_version="$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || echo "0")"
# xcrun 输出空串/非数值(异常工具链)时,[ ... -lt 26 ] 会以 "integer expression
# expected" 语法错在 set -e 下直接中断调用方。非数值一律按老工具链处理(跳过补丁)。
host_sdk_major="${host_sdk_version%%.*}"
[[ "${host_sdk_major}" =~ ^[0-9]+$ ]] || host_sdk_major="0"

if ! command -v vtool >/dev/null 2>&1 \
  || [ "${host_sdk_major}" -lt 26 ] \
  || [ ! -f "${BINARY_PATH}" ]; then
  exit 0
fi

# vtool 失败必须可见:`|| true` 吞错后仍无条件打印 "Patched" 会误导排查。
# 输出到临时文件、成功后再 mv 覆盖:vtool 以同一文件作输入与 -output 属原位重写,
# 中途失败(磁盘满/进程被杀)会留下损坏的二进制。
patch_tmp="${BINARY_PATH}.vtool-tmp.$$"
if ! patch_output="$(vtool -set-build-version macos 14.0 "${host_sdk_version}" -replace \
  -output "${patch_tmp}" "${BINARY_PATH}" 2>&1)" || ! mv -f "${patch_tmp}" "${BINARY_PATH}"; then
  rm -f "${patch_tmp}"
  echo "=> WARNING: vtool patch failed, modern macOS appearance may not apply:" >&2
  echo "${patch_output}" >&2
  exit 0
fi

if codesign --force -s - "${BINARY_PATH}" >/dev/null 2>&1; then
  echo "=> Patched linked SDK version to ${host_sdk_version} (enables modern macOS appearance)"
else
  echo "=> WARNING: patched but ad-hoc re-sign failed; app may be killed on launch" >&2
fi
exit 0
