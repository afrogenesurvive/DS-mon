#!/bin/bash
set -e

# ==============================
# dev_mon 构建 & 打包脚本
# 用法: ./scripts/build.sh [版本号]
# ==============================

# 版本号优先级：命令行参数 > 当前分支名 > 默认值
if [ -n "$1" ]; then
    VERSION="$1"
elif BRANCH=$(git -C "$(dirname "$0")/.." branch --show-current 2>/dev/null); then
    VERSION="${BRANCH}"
else
    VERSION="0.1.9"
fi
# 构建号：git commit count
BUILD=$(git -C "$(dirname "$0")/.." rev-list --count HEAD 2>/dev/null || echo "0")
BUILD_VERSION="${VERSION}.${BUILD}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/dev_mon-${VERSION}.app"

echo "==> 构建 release..."
cd "$ROOT"
swift build -c release --disable-sandbox

echo "==> 打包 .app (v$VERSION)..."
rm -rf "$APP"
mkdir -p "$APP/Contents"/{MacOS,Resources}

# 二进制
cp .build/release/dev_mon "$APP/Contents/MacOS/"

# 资源
cp Sources/dev_mon/dslogo.png "$APP/Contents/Resources/"
cp Sources/dev_mon/dslogo1.png "$APP/Contents/Resources/"
cp Sources/dev_mon/menu_icon.png "$APP/Contents/Resources/"
cp -r Sources/dev_mon/Assets.xcassets "$APP/Contents/Resources/"


# Info.plist
cat > "$APP/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>dev_mon</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>com.devmon.app</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
		<string>dev_mon</string>
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
		<key>DevMonBuildTimestamp</key>
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
python3 "$ROOT/scripts/gen_icns.py" Sources/dev_mon/dslogo1.png "$APP/Contents/Resources/AppIcon.icns"

# 刷新缓存
touch "$APP"
echo "==> 完成: $APP (v$VERSION)"
echo "    启动: open $APP"
