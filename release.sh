#!/bin/bash
# 打 zip 并发布 GitHub Release（用法: ./release.sh v1.0.0）
set -euo pipefail
cd "$(dirname "$0")"
TAG="${1:?用法: ./release.sh v1.0.0}"
ZIP="GLM-Usage-macos.zip"

./build.sh
# ditto 保留 .app 的元数据与符号链接，比 zip 更适合分发 .app
ditto -c -k --keepParent "build/GLM Usage.app" "build/$ZIP"
gh release create "$TAG" "build/$ZIP" \
  --title "$TAG" \
  --notes "macOS 菜单栏 GLM Coding Plan 用量小组件（通用二进制 arm64/x86_64，要求 macOS 13+）。

未做公证：在其他 Mac 首次打开若被 Gatekeeper 拦截，执行 \`xattr -cr '/Applications/GLM Usage.app'\` 后再打开。
API Key 配置见 README；无配置时自动复用本机 ZCode 的 key（如有）。"
echo "==> Release $TAG 已发布: https://github.com/spaceoi/glm-usage-menubar/releases/tag/$TAG"
