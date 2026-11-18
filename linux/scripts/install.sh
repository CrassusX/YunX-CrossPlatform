#!/bin/sh
# YunX Linux 一键安装：默认装到 ~/.local，不需要 root。
# 自定义位置：YUNX_PREFIX=/opt/yunx ./scripts/install.sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PREFIX=${YUNX_PREFIX:-"$HOME/.local"}
BIN="$PREFIX/bin"
LIB="$PREFIX/lib/yunx"

if ! command -v python3 >/dev/null 2>&1; then
    echo "错误：找不到 python3，请先安装 Python 3.8 或更新版本" >&2
    exit 1
fi
python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' || {
    echo "错误：Python 版本过低，需要 3.8+" >&2
    exit 1
}

mkdir -p "$BIN" "$LIB/yunx"
cp -R "$ROOT/yunx/." "$LIB/yunx/"
cp "$ROOT/yunx.py" "$LIB/yunx.py"

cat > "$BIN/yunx" <<EOF
#!/bin/sh
# 由 YunX-Linux install.sh 生成
exec python3 "$LIB/yunx.py" "\$@"
EOF
chmod 755 "$BIN/yunx"
chmod -R u+rX,go+rX "$LIB"

echo "已安装 YunX Linux"
echo "  命令    $BIN/yunx"
echo "  配置    \$HOME/.config/yunx"
echo
case ":$PATH:" in
    *":$BIN:"*) ;;
    *) echo "请把 $BIN 加入 PATH："
       echo "  echo 'export PATH=\"$BIN:\$PATH\"' >> ~/.bashrc" ;;
esac
echo
echo "下一步：yunx login 然后 yunx add <百度分享链接>"
