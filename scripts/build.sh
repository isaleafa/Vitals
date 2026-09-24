#!/bin/bash
# 构建 Vitals.app —— 只用 Command Line Tools，不需要 Xcode。
# 范式沿用 ~/Projects/h3cvpn/build_app.sh（swiftc + 手写 Info.plist + ad-hoc 签名）。
set -euo pipefail

cd "$(dirname "$0")/.."
APP="build/Vitals.app"
SDK="$(xcrun --show-sdk-path)"
TARGET="$(uname -m)-apple-macosx14.0"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "compiling…"
# 注意：@main 必须配 -parse-as-library，否则报 "top-level code"
swiftc -O -parse-as-library -sdk "$SDK" -target "$TARGET" \
    -o "$APP/Contents/MacOS/Vitals" \
    $(find Sources -name '*.swift' | sort)

# 图标：脚本生成 → .icns → 打进 bundle（缺失或脚本更新时才重生成）
if [ ! -f build/AppIcon.icns ] || [ scripts/make-icon.swift -nt build/AppIcon.icns ]; then
    echo "generating icon…"
    rm -rf build/AppIcon.iconset
    swift scripts/make-icon.swift build/AppIcon.iconset >/dev/null
    iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Vitals</string>
    <key>CFBundleDisplayName</key><string>Vitals</string>
    <key>CFBundleIdentifier</key><string>top.liyi830.vitals</string>
    <key>CFBundleExecutable</key><string>Vitals</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticTermination</key><false/>
</dict>
</plist>
PLIST

# 临时签名：本地自用够用，且重建后系统记住的是同一个身份
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 \
    || echo "warning: ad-hoc codesign failed; the app will still run"

echo "built $APP"
echo "  跑一帧数据核对：  $APP/Contents/MacOS/Vitals --dump"
echo "  启动菜单栏 App：  open $APP"
