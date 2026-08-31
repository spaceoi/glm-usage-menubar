#!/bin/bash
# 编译并打包 GLM Usage.app（arm64 + x86_64 通用二进制，无需 Xcode 工程）
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="GLM Usage"
BUILD_DIR="build"
EXEC_NAME="glm-usage"

mkdir -p "$BUILD_DIR"
echo "==> swiftc 编译中（arm64 + x86_64）…"
# 分架构编译再 lipo 合并：swiftc 一次只能带一个 -target，双 -arch 无法同时指定最低系统版本
swiftc -O -target arm64-apple-macos13.0 -o "$BUILD_DIR/.glm-usage-arm64" main.swift
swiftc -O -target x86_64-apple-macos13.0 -o "$BUILD_DIR/.glm-usage-x86_64" main.swift
lipo -create "$BUILD_DIR/.glm-usage-arm64" "$BUILD_DIR/.glm-usage-x86_64" -output "$BUILD_DIR/$EXEC_NAME"
rm "$BUILD_DIR/.glm-usage-arm64" "$BUILD_DIR/.glm-usage-x86_64"

APP_DIR="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
rm -rf "$APP_DIR"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BUILD_DIR/$EXEC_NAME" "$CONTENTS/MacOS/$EXEC_NAME"
cp Info.plist "$CONTENTS/Info.plist"
# ad-hoc 签名：本机运行无影响；分发到其他 Mac 仍需 xattr -cr 绕过 Gatekeeper（见 README）
codesign --sign - --force "$APP_DIR" >/dev/null 2>&1 || true

echo "==> 打包完成: $APP_DIR ($(lipo -archs "$CONTENTS/MacOS/$EXEC_NAME"))"
echo "    运行: open \"$APP_DIR\""
