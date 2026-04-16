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
  git -C "$ROOT_DIR" tag --list "${TAG_PREFIX}[0-9]*.[0-9]*.[0-9]*" --sort=-version:refname | head -n 1
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
read -r -p "确认发布？(y/N) " CONFIRM
if [[ "$CONFIRM" != [yY] ]]; then
  echo "已取消"
  exit 0
fi

git -C "$ROOT_DIR" commit --allow-empty -m "chore(release): $TAG_NAME"
git -C "$ROOT_DIR" tag -a "$TAG_NAME" -m "Release $TAG_NAME"
git -C "$ROOT_DIR" push origin HEAD "$TAG_NAME"

echo ""
echo "发布完成！"
echo "  已创建并推送 tag: $TAG_NAME"
echo "  GitHub Actions 将基于该 tag 触发发布流程"
