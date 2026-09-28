#!/usr/bin/env bash
# CI runner 上"选择 Xcode 工具链"的单一事实来源(原 ci.yml 与 release.yml 曾各自
# 内联同一条 xcode-select 一行式,措辞已出现漂移;现仅 release.yml 使用)。
# 与 version.sh 同一收敛思路。
#
# 入参(可选):所需 Xcode 版本号,如 16.4——runner 镜像里通常按 Xcode_<版本>.app
# 命名,给定时优先精确匹配;未给定时取最高版本稳定版(sort -V 末位),与旧内联行为一致。
#
# 排除 Xcode-beta.app 是必须的:镜像附带 beta 时 sort -V 会静默选中 beta 工具链,
# 构建/测试/发布产物随镜像更新漂移。
set -euo pipefail

REQUIRED_VERSION="${1:-}"

# grep 无命中时以非零退出,`|| true` 兜底后由空串检查给出友好报错。
candidates="$(ls -d /Applications/Xcode*.app | grep -iv beta || true)"
if [[ -z "${candidates}" ]]; then
  echo "错误: /Applications 下找不到任何非 beta 的 Xcode.app" >&2
  exit 1
fi

selected=""
if [[ -n "${REQUIRED_VERSION}" ]]; then
  # 匹配串必须带 .app 边界:纯前缀 "Xcode_16.2" 在镜像同时存在
  # Xcode_16.20.app 时会误选 16.20(ls 输出顺序不保证,head -n 1 可能拿到错的)。
  selected="$(printf '%s\n' "${candidates}" | grep -F "Xcode_${REQUIRED_VERSION}.app" | head -n 1 || true)"
  if [[ -z "${selected}" ]]; then
    echo "警告: 镜像中没有 Xcode_${REQUIRED_VERSION},回退最新稳定版" >&2
  fi
fi
if [[ -z "${selected}" ]]; then
  selected="$(printf '%s\n' "${candidates}" | sort -V | tail -n 1)"
fi

echo "==> Selecting Xcode: ${selected}"
sudo xcode-select -s "${selected}/Contents/Developer"

xcode_version="$(xcodebuild -version 2>/dev/null | head -n 1 | awk '{print $2}' || true)"
echo "==> xcodebuild version: ${xcode_version:-unknown}"
