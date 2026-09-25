#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAG_PREFIX="v"

usage() {
  cat <<EOF
用法: $0 <patch|minor|major|版本号>

示例:
  $0 patch          # v1.0.2 -> v1.0.3
  $0 minor          # v1.0.2 -> v1.1.0
  $0 major          # v1.0.2 -> v2.0.0
  $0 1.2.3          # 直接发布 v1.2.3

流程: 基于当前最新 tag 计算新版本 -> 创建 annotated tag -> 推送到远端
EOF
  exit 1
}

latest_semver_tag() {
  local tag_list
  # 区分"没有匹配的 tag"与"git 本身故障":后者若被 || true 吞掉,
  # 会按 CURRENT_VERSION=0.0.0 算出 v0.0.1 继续走,留下误导性的失败现场。
  if ! tag_list="$(git -C "$ROOT_DIR" tag --list "${TAG_PREFIX}[0-9]*.[0-9]*.[0-9]*" --sort=-version:refname)"; then
    echo "错误: 读取 git tag 失败,请检查仓库状态" >&2
    exit 1
  fi
  # 严格匹配 vMAJOR.MINOR.PATCH，排除 v1.2.3-rc1 这类预发布 tag，
  # 否则后续 $((PATCH+1)) 会对 "3-rc1" 报错退出。
  printf '%s\n' "$tag_list" | grep -E "^${TAG_PREFIX}[0-9]+\.[0-9]+\.[0-9]+$" | head -n 1 || true
}

BUMP="${1:-patch}"

if ! git -C "$ROOT_DIR" diff --quiet || ! git -C "$ROOT_DIR" diff --cached --quiet; then
  echo "错误: 工作区有未提交的修改，请先提交或暂存" >&2
  exit 1
fi

CURRENT_TAG="$(latest_semver_tag)"
if [[ -n "$CURRENT_TAG" ]]; then
  CURRENT_VERSION="${CURRENT_TAG#${TAG_PREFIX}}"
else
  CURRENT_VERSION="0.0.0"
fi

IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT_VERSION"

case "$BUMP" in
  patch)
    NEW_VERSION="$MAJOR.$MINOR.$((PATCH + 1))"
    ;;
  minor)
    NEW_VERSION="$MAJOR.$((MINOR + 1)).0"
    ;;
  major)
    NEW_VERSION="$((MAJOR + 1)).0.0"
    ;;
  *)
    if [[ "$BUMP" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      NEW_VERSION="$BUMP"
    else
      echo "错误: 无效的版本号格式 '$BUMP'，需要 X.Y.Z 格式" >&2
      usage
    fi
    ;;
esac

TAG_NAME="${TAG_PREFIX}${NEW_VERSION}"

if git -C "$ROOT_DIR" rev-parse "$TAG_NAME" >/dev/null 2>&1; then
  echo "错误: tag $TAG_NAME 已存在" >&2
  exit 1
fi

if [[ "$CURRENT_VERSION" == "$NEW_VERSION" ]]; then
  echo "错误: 新版本与当前版本相同 ($NEW_VERSION)" >&2
  exit 1
fi

echo "当前版本: $CURRENT_VERSION"
echo "新版本:   $NEW_VERSION"
echo "Git tag:  $TAG_NAME"
echo ""
if [[ -t 0 ]]; then
  read -r -p "确认发布？(y/N) " CONFIRM
else
  # 非交互环境（stdin 不是终端）：不从终端读，改为接受管道传入的确认字符，
  # 避免 read 在 stdin 关闭时静默失败
  echo "提示: 非交互环境运行；自动确认请用: echo y | $0 $BUMP" >&2
  read -r CONFIRM || CONFIRM=""
fi
if [[ "$CONFIRM" != [yY] ]]; then
  echo "已取消"
  exit 0
fi

git -C "$ROOT_DIR" commit --allow-empty -m "chore(release): $TAG_NAME"
git -C "$ROOT_DIR" tag -a "$TAG_NAME" -m "Release $TAG_NAME"
# 回滚命令全部容错:回滚本身失败(如 tag 已被并发删除)不该在 set -e 下
# 半途中断吞掉错误信息,留下"tag 已删但空提交还在"的中间态。
rollback_release_commit() {
  git -C "$ROOT_DIR" tag -d "$TAG_NAME" >/dev/null 2>&1 || true
  git -C "$ROOT_DIR" reset --soft HEAD~1 >/dev/null 2>&1 || true
}
# 分两步推送且先推 HEAD:此前一条 `push origin HEAD tag` 若 tag 先推成功、HEAD 后失败,
# 会留下指向不存在的本地历史的悬空远端 tag,并且已经触发了 Release 流水线。
if ! git -C "$ROOT_DIR" push origin HEAD; then
  # 推送报错不等于远端无变更(服务端已接受但响应丢失等):
  # 远端分支若已包含发布提交,回滚反而会让下次 push 变 non-FF 被拒。
  branch="$(git -C "$ROOT_DIR" branch --show-current)"
  remote_head="$(git -C "$ROOT_DIR" ls-remote origin "refs/heads/${branch}" 2>/dev/null | awk 'NR==1{print $1}')"
  if [[ -n "$remote_head" && "$remote_head" == "$(git -C "$ROOT_DIR" rev-parse HEAD)" ]]; then
    echo "错误: 推送报错但远端分支已包含发布提交(疑似服务端已接受)。tag 未推送,不回滚;可直接重试: git -C $ROOT_DIR push origin $TAG_NAME" >&2
    exit 1
  fi
  # HEAD 没推上去,tag 必然未发布:回滚本地 tag 与发布提交,工作区回到发布前状态,
  # 避免反复失败累积空提交、下次运行被"tag 已存在"拒绝。
  rollback_release_commit
  echo "错误: 推送发布提交失败,已回滚本地 tag $TAG_NAME 与发布提交(远端未产生变更)" >&2
  exit 1
fi
if ! git -C "$ROOT_DIR" push origin "$TAG_NAME"; then
  # HEAD 已在远端,只是 tag 没推上:保留本地 tag 与提交,直接重试
  # `git push origin $TAG_NAME` 即可完成发布,不需要重新走一遍版本计算。
  echo "错误: tag 推送失败。发布提交已推送,本地 tag $TAG_NAME 已保留,可直接重试: git -C $ROOT_DIR push origin $TAG_NAME" >&2
  exit 1
fi

echo ""
echo "发布完成！"
echo "  已创建并推送 tag: $TAG_NAME"
echo "  GitHub Actions 将基于该 tag 触发发布流程"
