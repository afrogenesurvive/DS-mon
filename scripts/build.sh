#!/bin/bash
set -e

# ==============================
# DS-mon 构建 & 打包脚本
# 用法: ./scripts/build.sh [版本号]
# ==============================

# 版本号优先级：命令行参数 > git tag > 默认值
if [ -n "$1" ]; then
    VERSION="$1"
elif VERSION=$(git -C "$(dirname "$0")/.." describe --tags --abbrev=0 2>/dev/null); then
    VERSION="${VERSION#v}"  # 去掉前缀 v
else
    VERSION="2.0"
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/DS-mon.app"

echo "==> 构建 release..."
cd "$ROOT"
swift build -c release --disable-sandbox

echo "==> 打包 .app (v$VERSION)..."
rm -rf "$APP"
mkdir -p "$APP/Contents"/{MacOS,Resources}

# 二进制
cp .build/release/DS-mon "$APP/Contents/MacOS/"

# 资源
cp Sources/DS-mon/dslogo.png "$APP/Contents/Resources/"
cp Sources/DS-mon/dslogo1.png "$APP/Contents/Resources/"
cp -r Sources/DS-mon/Assets.xcassets "$APP/Contents/Resources/"

# codex-relay 二进制（协议转换：Responses API ↔ Chat Completions）
CODEX_RELAY_SRC="$ROOT/codex-relay"
if [ -f "$CODEX_RELAY_SRC" ]; then
    cp "$CODEX_RELAY_SRC" "$APP/Contents/Resources/codex-relay"
    chmod +x "$APP/Contents/Resources/codex-relay"
    echo "    codex-relay ($(du -h "$CODEX_RELAY_SRC" | cut -f1)) 已打进包内"
else
    echo "    ⚠️  Sources/DS-mon/codex-relay 不存在，跳过"
fi

# Info.plist
cat > "$APP/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>DS-mon</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>com.dsmon.app</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>DS-mon</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>$VERSION</string>
	<key>LSMinimumSystemVersion</key>
	<string>15.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>LSUIElement</key>
	<true/>
</dict>
</plist>
PLIST

# AppIcon.icns
ICONSET="/tmp/dsmon_AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
    sips -z $s $s Sources/DS-mon/dslogo1.png --out "$ICONSET/icon_${s}x${s}.png" > /dev/null 2>&1
    sips -z $((s*2)) $((s*2)) Sources/DS-mon/dslogo1.png --out "$ICONSET/icon_${s}x${s}@2x.png" > /dev/null 2>&1
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

# 刷新缓存
touch "$APP"
echo "==> 完成: $APP (v$VERSION)"
echo "    启动: open $APP"
