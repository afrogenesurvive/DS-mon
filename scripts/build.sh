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
    VERSION="2.2"
fi
# 构建号：git commit count
BUILD=$(git -C "$(dirname "$0")/.." rev-list --count HEAD 2>/dev/null || echo "0")
BUILD_VERSION="${VERSION}.${BUILD}"
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
cp Sources/DS-mon/menu_icon.png "$APP/Contents/Resources/"
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
	<string>$BUILD_VERSION</string>
	<key>CFBundleVersion</key>
	<string>$BUILD_VERSION</string>
	<key>LSMinimumSystemVersion</key>
	<string>15.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>LSUIElement</key>
	<true/>
	<key>DSMonBuildTimestamp</key>
	<string>$(date "+%Y-%m-%d %H:%M:%S")</string>
	<key>NSAppTransportSecurity</key>
	<dict>
		<key>NSAllowsArbitraryLoads</key>
		<true/>
	</dict>
</dict>
</plist>
PLIST

# AppIcon.icns（使用 Python 生成，iconutil 在 macOS 26+ 上已不支持 iconset→icns）
python3 "$ROOT/scripts/gen_icns.py" Sources/DS-mon/dslogo1.png "$APP/Contents/Resources/AppIcon.icns"

# 刷新缓存
touch "$APP"
echo "==> 完成: $APP (v$VERSION)"
echo "    启动: open $APP"
