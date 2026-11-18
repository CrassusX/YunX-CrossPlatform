#!/bin/bash
# 构建通用二进制（arm64 + x86_64）的 .app 与 .dmg
#
#   ./scripts/build-app.sh            构建 Release 的 .app + .dmg
#   ./scripts/build-app.sh --no-dmg   只要 .app
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
APP_NAME="YunX-Mac-Desktop"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
MAKE_DMG=1

for arg in "$@"; do
  case "$arg" in
    --no-dmg) MAKE_DMG=0 ;;
    *) echo "未知参数：$arg"; exit 2 ;;
  esac
done

# SPM 的多架构构建依赖 xcbuild，必须用完整 Xcode 而不是 Command Line Tools
if [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

# SPM 编译 manifest 时会用 sandbox-exec，在部分受限环境下会失败
SANDBOX_FLAG="--disable-sandbox"

echo "==> 1/5 生成图标"
if [ ! -f Resources/AppIcon.icns ]; then
  swift scripts/make-icon.swift Resources
else
  echo "    已存在，跳过（删掉 Resources/AppIcon.icns 可重新生成）"
fi

echo "==> 2/5 编译通用二进制（arm64 + x86_64）"
swift build -c release --arch arm64 --arch x86_64 $SANDBOX_FLAG

BINARY="$ROOT/.build/apple/Products/Release/YunXMac"
if [ ! -f "$BINARY" ]; then
  echo "!! 找不到编译产物：$BINARY"
  exit 1
fi
echo "    架构：$(lipo -archs "$BINARY")"

echo "==> 3/5 组装 .app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/YunXMac"
chmod +x "$APP/Contents/MacOS/YunXMac"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> 4/5 临时签名（ad-hoc）"
codesign --force --deep --sign - --timestamp=none "$APP"
codesign --verify --deep --strict "$APP" && echo "    签名校验通过"

echo "==> 5/5 打包 DMG"
if [ "$MAKE_DMG" -eq 1 ]; then
  DMG="$DIST/$APP_NAME-$VERSION.dmg"
  rm -f "$DMG"
  STAGING="$(mktemp -d)"
  cp -R "$APP" "$STAGING/"
  ln -s /Applications "$STAGING/Applications"
  hdiutil create -volname "云析 YunX" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
  rm -rf "$STAGING"
  echo "    $DMG"
  du -h "$DMG" | awk '{print "    体积：" $1}'
fi

echo
echo "✅ 完成"
echo "   APP: $APP"
echo "   验证：open \"$APP\""
