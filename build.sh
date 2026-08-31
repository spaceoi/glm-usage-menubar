#!/bin/bash
# 编译并打包 GLM Usage.app（无需 Xcode 工程，仅用 swiftc）
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="GLM Usage"
BUILD_DIR="build"
EXEC_NAME="glm-usage"

mkdir -p "$BUILD_DIR"
echo "==> swiftc 编译中…"
swiftc -O -o "$BUILD_DIR/$EXEC_NAME" main.swift

APP_DIR="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
rm -rf "$APP_DIR"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BUILD_DIR/$EXEC_NAME" "$CONTENTS/MacOS/$EXEC_NAME"
cp Info.plist "$CONTENTS/Info.plist"

echo "==> 打包完成: $APP_DIR"
echo "    运行: open \"$APP_DIR\""
