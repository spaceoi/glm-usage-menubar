#!/bin/bash
# 在其他 Mac 上一键安装最新版到 /Applications（curl -fsSL <raw-url>/install.sh | bash）
set -euo pipefail
URL="https://github.com/spaceoi/glm-usage-menubar/releases/latest/download/GLM-Usage-macos.zip"
APP_NAME="GLM Usage"
DEST="/Applications"
APP="$DEST/$APP_NAME.app"
ZIP="$DEST/GLM-Usage-macos.zip"

# /Applications 无写权限时回退到用户目录
if ! mkdir -p "$DEST" 2>/dev/null || [ ! -w "$DEST" ]; then
  DEST="$HOME/Applications"
  APP="$DEST/$APP_NAME.app"
  ZIP="$DEST/GLM-Usage-macos.zip"
  mkdir -p "$DEST"
fi

echo "==> 下载最新版…"
curl -fsSL -o "$ZIP" "$URL"
rm -rf "$APP"
ditto -x -k "$ZIP" "$DEST"
rm "$ZIP"
# 清除隔离属性，绕过未公证应用的 Gatekeeper 拦截
xattr -cr "$APP" 2>/dev/null || true
open "$APP"

cat <<EOF
==> 已安装并启动: $APP
    若菜单栏显示 GLM ⚠️ 说明还没配置 Key：
    点菜单栏图标 → 编辑配置… → 填入 GLM Coding Plan API Key
    （或删掉 apiKey 那一行，复用本机 ZCode 配置的 key）→ 再点一次菜单生效。
EOF
