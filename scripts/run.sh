#!/bin/bash
# 构建 → 安装到 /Applications → 重启 Vitals。
#
# 为什么必须从 /Applications 跑：macOS 27 重写了菜单栏，Hidden Bar 1.11.1 靠私有框架
# 按 App 隐藏，只认得 /Applications 里的副本——从 build/ 目录运行的菜单栏 App 会被
# 判定为"认不出来的 App"，一收起就被隐藏（2026-09-23 对照实验确认：同一二进制、
# 同一 bundle id，只是换了目录，行为就完全不同）。
set -euo pipefail

cd "$(dirname "$0")/.."
./scripts/build.sh

pkill -x Vitals 2>/dev/null || true
sleep 0.3

rm -rf /Applications/Vitals.app
ditto build/Vitals.app /Applications/Vitals.app
open /Applications/Vitals.app
sleep 1.5

if pgrep -x Vitals >/dev/null; then
    pid=$(pgrep -x Vitals | head -1)
    echo "Vitals 已从 /Applications 启动（pid ${pid}）"
else
    echo "启动失败，前台跑一下看报错："
    echo "  /Applications/Vitals.app/Contents/MacOS/Vitals"
    exit 1
fi
