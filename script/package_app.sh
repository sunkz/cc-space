#!/usr/bin/env bash
set -euo pipefail

APP_NAME="CCSpace"
DISPLAY_NAME="CCSpace"
BUNDLE_ID="com.ccspace.app"
MINIMUM_SYSTEM_VERSION="14.0"
# 图标路径锚定到脚本自身位置(仓库根/Resources):不依赖调用方的 cwd。
ICON_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/Resources/AppIcon.icns"

usage() {
  cat <<EOF
Usage: $0 --binary PATH --output PATH --version VERSION [--app-name NAME] [--display-name NAME] [--bundle-id ID]

Assembles a macOS .app bundle from an already-built executable.
EOF
}

BINARY_PATH=""
OUTPUT_PATH=""
VERSION=""

# 选项必须带值:此前直接 `${2:-}` + `shift 2`,当选项恰好是末位参数($#==1)时
# shift 2 报错、set -e 裸退出且无任何提示。统一在取值前显式校验并给出友好报错。
require_option_value() {
  if [[ $# -lt 2 || -z "$2" ]]; then
    echo "Missing value for $1 (每个选项都必须跟一个非空值)" >&2
    usage >&2
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --binary)
      require_option_value "$@"
      BINARY_PATH="$2"
      shift 2
      ;;
    --output)
      require_option_value "$@"
      OUTPUT_PATH="$2"
      shift 2
      ;;
    --version)
      require_option_value "$@"
      VERSION="$2"
      shift 2
      ;;
    --app-name)
      require_option_value "$@"
      APP_NAME="$2"
      shift 2
      ;;
    --display-name)
      require_option_value "$@"
      DISPLAY_NAME="$2"
      shift 2
      ;;
    --bundle-id)
      require_option_value "$@"
      BUNDLE_ID="$2"
      shift 2
      ;;
    help|-h|--help)
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

if [[ -z "$BINARY_PATH" || -z "$OUTPUT_PATH" || -z "$VERSION" ]]; then
  usage >&2
  exit 1
fi

# VERSION 必须是 X.Y.Z:与 release.yml 的 tag 校验同一正则。此前这里不校验,
# 非法版本号会静默写进 CFBundleShortVersionString/CFBundleVersion,产出的 app
# 版本号异常且要到运行/公证阶段才暴露。
if ! printf '%s' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "Invalid version: '$VERSION' (期望 X.Y.Z 格式,如 1.2.3)" >&2
  exit 1
fi

if [[ ! -x "$BINARY_PATH" ]]; then
  echo "Executable not found or not executable: $BINARY_PATH" >&2
  exit 1
fi

if [[ ! -f "$ICON_PATH" ]]; then
  echo "App icon not found: $ICON_PATH" >&2
  exit 1
fi

APP_BUNDLE="$OUTPUT_PATH"

# 物理路径(cd -P 解析 symlink):下面的前缀比较两侧都要解析符号链接——
# 仓库本身经 symlink 表达(如 clone 在 /var/... 而调用方传 /private/var/...)时,
# 字符串比较会把仓库内的合法输出误判成"仓库外"。
REPO_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 规范化为绝对路径:消除 . / .. 段(不解析符号链接)。不做这一步的话,
# `--output "${REPO_ROOT}/dist/../foo.app"` 这类写法能靠字符串前缀绕过下面的检查。
# 非绝对路径按调用方 cwd 展开,与 rm -rf 实际解析的行为一致。
normalize_path() {
  local input="$1" result="" part
  local -a parts
  [[ "${input}" == /* ]] || input="${PWD}/${input}"
  local IFS='/'
  read -r -a parts <<< "${input}"
  for part in "${parts[@]}"; do
    case "${part}" in
      ''|'.') ;;
      '..') result="${result%/*}" ;;
      *) result="${result}/${part}" ;;
    esac
  done
  printf '%s' "${result:-/}"
}

# 把路径中"已存在的目录段"解析成物理路径(cd -P 会解开这些段上的全部符号链接),
# 末尾尚不存在的组件(如还没创建的 xxx.app)原样拼在后面。逐段上溯到第一个已存在的
# 组件是因为:含不存在中间段的路径无法直接 cd。
# 循环条件必须是 `-e || -L` 的补集,不能只用 `-d`:中段是指向**文件**的 symlink 或
# **悬空 symlink** 时 `-d` 为假,会被误当成"尚不存在的目录"一路拼到存在的父目录,
# `cd -P` 只解析到父目录就放行——检查面对仓库外路径 fail-open(后续 mkdir/cp 是否
# 真的写到仓库外取决于具体工具与路径形态,不能指望它们兜底)。现在这两种中段让
# 循环停下,下面的 cd -P 必然失败 -> exit 1(fail-closed)。`-L` 专为悬空 symlink
# 补上(-e 对它为假)。
# 不用 macOS 13+ 的 realpath:它对不存在的路径直接报错,而 --output 的 .app
# 目标此刻往往还不存在。
physical_path() {
  local input="$1" dir base phys
  [[ "${input}" == /* ]] || input="${PWD}/${input}"
  dir="$(dirname "${input}")"
  base="$(basename "${input}")"
  while [[ ! -e "${dir}" && ! -L "${dir}" && "${dir}" != "/" ]]; do
    base="$(basename "${dir}")/${base}"
    dir="$(dirname "${dir}")"
  done
  # 解析失败直接中止(拒绝而非猜测),避免"失败关闭"退化成"失败打开"。
  if ! phys="$(cd -P "${dir}" 2>/dev/null && pwd)"; then
    echo "拒绝执行: 无法解析输出路径所在目录的物理位置: $1" >&2
    exit 1
  fi
  printf '%s' "${phys%/}/${base}"
}

# 删除旧 bundle 前的防护:--output 可能是任意路径,
# 只允许删除以 .app 结尾、不是符号链接、且位于本仓库 dist/ 之内的目标。
# `--output "/System/Library/CCSpace.app"`、`--output "$HOME/Desktop/foo.app"`
# 这类仓库外路径此前会被直接 rm -rf。
if [[ "$APP_BUNDLE" != *.app ]]; then
  echo "拒绝执行: --output 路径必须以 .app 结尾，拒绝删除非 .app 路径: $APP_BUNDLE" >&2
  exit 1
fi
# 只覆盖最后一段是 symlink 的情况;中间段(如 dist/link -> 仓库外目录)不在此检查,
# 交给下面的物理路径解析处理。
if [[ -L "$APP_BUNDLE" ]]; then
  echo "拒绝执行: 输出路径是符号链接，拒绝删除: $APP_BUNDLE" >&2
  exit 1
fi
# 两步归一化,缺一不可:
#   1) normalize_path 词法归一(消 . / ..,不解析 symlink)——挡住
#      `--output "${REPO_ROOT}/dist/../foo.app"` 这类字符串绕过;
#   2) physical_path 解析中段 symlink——挡住 `dist/link -> 仓库外目录` 后
#      `--output dist/link/evil.app`:词法归一后前缀仍是 repo/dist/,字符串比较
#      会放行,而 rm -rf 会顺着链接删到仓库外。中段是指向**文件**的 symlink 或
#      **悬空 symlink** 时无法 cd 到该段,physical_path 直接 exit 1 拒绝,
#      不会退化成"解析到其父目录后按字符串前缀放行"。
# 检查通过后统一改用解析后的路径,后续 rm -rf/mkdir 看到的与检查时看到的是同一个
# 字符串(检查与执行不一致的窗口即漏洞)。
ABS_OUTPUT="$(normalize_path "$APP_BUNDLE")"
RESOLVED_OUTPUT="$(physical_path "$ABS_OUTPUT")"
case "$RESOLVED_OUTPUT" in
  "${REPO_ROOT}/dist/"*.app) ;;
  *)
    echo "拒绝执行: 输出路径必须位于仓库 dist/ 之内，拒绝删除: $APP_BUNDLE (解析为 $RESOLVED_OUTPUT)" >&2
    exit 1
    ;;
esac
APP_BUNDLE="$RESOLVED_OUTPUT"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BINARY_PATH" "$APP_BINARY"
chmod +x "$APP_BINARY"
cp "$ICON_PATH" "$APP_RESOURCES/AppIcon.icns"

# 值统一内层双引号:PlistBuddy 的 -c 命令串按空格切词,
# DISPLAY_NAME/APP_NAME 等含空格时必须让 PlistBuddy 看到带引号的值,否则 Add 失败。
/usr/libexec/PlistBuddy \
  -c "Clear dict" \
  -c "Add :CFBundleExecutable string \"$APP_NAME\"" \
  -c "Add :CFBundleIdentifier string \"$BUNDLE_ID\"" \
  -c "Add :CFBundleIconFile string AppIcon" \
  -c "Add :CFBundleName string \"$DISPLAY_NAME\"" \
  -c "Add :CFBundlePackageType string APPL" \
  -c "Add :CFBundleShortVersionString string \"$VERSION\"" \
  -c "Add :CFBundleVersion string \"$VERSION\"" \
  -c "Add :LSMinimumSystemVersion string \"$MINIMUM_SYSTEM_VERSION\"" \
  -c "Add :NSPrincipalClass string NSApplication" \
  "$INFO_PLIST"

echo "$APP_BUNDLE"
