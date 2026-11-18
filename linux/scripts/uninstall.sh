#!/bin/sh
# 只删除 install.sh 安装的文件，不碰 ~/.config/yunx 里的登录态和任务记录。
set -eu
PREFIX=${YUNX_PREFIX:-"$HOME/.local"}
BIN="$PREFIX/bin"
LIB="$PREFIX/lib/yunx"

[ -f "$BIN/yunx" ] || { echo "未找到 $BIN/yunx，无需卸载"; exit 0; }
rm -f "$BIN/yunx"
rm -rf "$LIB"
echo "已卸载 YunX Linux（配置与下载文件保留）"
