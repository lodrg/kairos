#!/bin/bash
# 打包 Mirrage.app
set -euo pipefail
cd "$(dirname "$0")/.."

APP=Mirrage.app
rm -rf "dist/$APP"
mkdir -p "dist/$APP/Contents/MacOS"
mkdir -p "dist/$APP/Contents/Resources"

cp Packaging/Info.plist "dist/$APP/Contents/Info.plist"
BIN=$(find .build -path '*release/Mirrage' -type f -perm +111 -print -quit 2>/dev/null)
if [ -z "$BIN" ]; then
  echo "❌ 找不到 release 二进制" >&2
  exit 1
fi
cp "$BIN" "dist/$APP/Contents/MacOS/Mirrage"

# ad-hoc 签名（本地运行需要）
codesign --force --deep -s - "dist/$APP"

echo "✅ 打包完成: $(pwd)/dist/$APP"
