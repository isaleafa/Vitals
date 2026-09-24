#!/bin/bash
# 打包成可分发的 DMG（打开后把 Vitals.app 拖进 Applications 即安装）。
#   ./scripts/package.sh
# 产物：build/Vitals-<版本>.dmg
set -euo pipefail

cd "$(dirname "$0")/.."
./scripts/build.sh >/dev/null

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" build/Vitals.app/Contents/Info.plist)
STAGE="build/dmg-stage"
DMG="build/Vitals-${VERSION}.dmg"

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R build/Vitals.app "$STAGE/Vitals.app"
ln -s /Applications "$STAGE/Applications"        # 拖拽安装用的软链

# macOS 27 起 hdiutil create 已弃用，改用 diskutil image create from
diskutil image create from --volumeName "Vitals ${VERSION}" --format UDZO "$STAGE" "$DMG" >/dev/null

# 挂载回来自检：确认 app 与软链都在、签名可读，再卸载
MOUNT=$(hdiutil attach "$DMG" -nobrowse -readonly 2>/dev/null | grep -o '/Volumes/.*' | head -1)
trap 'hdiutil detach "$MOUNT" >/dev/null 2>&1 || true' EXIT
[ -d "${MOUNT}/Vitals.app" ] || { echo "✗ DMG 里没有 Vitals.app"; exit 1; }
[ -L "${MOUNT}/Applications" ] || { echo "✗ DMG 里没有 Applications 软链"; exit 1; }
codesign -v "${MOUNT}/Vitals.app" 2>/dev/null || { echo "✗ DMG 里的 app 签名校验失败"; exit 1; }
hdiutil detach "$MOUNT" >/dev/null 2>&1 || true
trap - EXIT

rm -rf "$STAGE"

echo "✓ 打包完成：${DMG}（$(du -h "$DMG" | cut -f1)）"
echo "  sha256 $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
echo
echo "上传到 GitHub Release："
echo "  gh release create v${VERSION} ${DMG} --title \"Vitals v${VERSION}\" --notes-file docs/release-notes.md"
echo
echo "提醒：本 App 是 ad-hoc 签名（没有 Apple 开发者账号做公证），别人首次打开会被 Gatekeeper 拦下"
echo "（macOS 26/27 是直接拒绝启动，不是给个提示让你点继续），放行三选一："
echo "  1. 先双击一次被拦 →「系统设置 → 隐私与安全性」→ 点「仍要打开」"
echo "  2. xattr -dr com.apple.quarantine /Applications/Vitals.app"
echo "  3. 用 curl 下载安装（curl 不打隔离属性，不触发 Gatekeeper，见 README）"
