#!/usr/bin/env bash
# 统一的版本号推导(单一事实来源):输出全局最新 vX.Y.Z tag 的版本号(不带 v 前缀);
# 仓库没有任何合法 tag 时输出 0.0.0。
#
# 必须用"全局最新 tag"(`tag --sort=-version:refname`)而不是
# `git describe --tags --abbrev=0`(HEAD 最近可达 tag):分支分叉后后者会取到旧 tag,
# 打包出的 app 版本号与最新发布不一致。run.sh 与 generate_readme_screenshots.sh
# 曾各持一份互相矛盾的实现,统一收敛到本脚本。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# git 故障(非仓库/对象损坏等)不能静默吞掉:此前 `2>/dev/null || true` 让
# run.sh 打包时版本号可能无声回退成 0.0.0,与 release.sh 的 fail-fast 语义相反。
# 失败时向 stderr 打警告再回退 0.0.0——保持"无合法 tag 也输出 0.0.0"的
# 不阻断契约(run 场景下开发调试不该被版本号卡住),但把异常显式暴露出来。
#
# 数据通道与诊断通道必须分开:此前 `2>&1` 把 git 的 stderr 混进 tag_list,
# 而 tag_list 随后要当"tag 列表"参与 grep——诊断文字一旦形如 `v1.2.3`
# (git 的 tag 告警恰恰会这么写)就会被当成本项目版本号输出。
# git 的 stderr 直接让它进本脚本 stderr(调用方 `$(...)` 只捕 stdout),
# 既可见于终端,又不污染数据。
if ! tag_list="$(git -C "${ROOT_DIR}" tag --list 'v[0-9]*' --sort=-version:refname)"; then
    echo "警告: git tag 枚举失败,版本号回退为 0.0.0(错误见上方 git 输出)" >&2
    tag_list=""
fi
latest_tag="$(printf '%s\n' "${tag_list}" \
    | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1 || true)"
latest_tag="${latest_tag:-v0.0.0}"

printf '%s\n' "${latest_tag#v}"
