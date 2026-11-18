#!/bin/sh
# 生成可直接拷到 Linux 机器上的 tar.gz 安装包。
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
VERSION=$(sed -n 's/^__version__ = "\(.*\)"/\1/p' "$ROOT/yunx/__init__.py")
DIST="$ROOT/dist"
NAME="YunX-Linux-$VERSION"
STAGE="$DIST/$NAME"

mkdir -p "$STAGE/yunx" "$STAGE/scripts" "$STAGE/systemd"
cp "$ROOT/README.md" "$ROOT/yunx.py" "$STAGE/"
cp -R "$ROOT/yunx/." "$STAGE/yunx/"
cp -R "$ROOT/tests" "$STAGE/tests"
cp "$ROOT/scripts/install.sh" "$ROOT/scripts/uninstall.sh" "$STAGE/scripts/"
cp "$ROOT/systemd/yunx.service" "$STAGE/systemd/"
chmod 755 "$STAGE/scripts/"*.sh

find "$STAGE" -name __pycache__ -type d -exec rm -rf {} + 2>/dev/null || true
cd "$DIST"
tar -czf "$NAME.tar.gz" "$NAME"
if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$NAME.tar.gz" > "$NAME.tar.gz.sha256"
else
    sha256sum "$NAME.tar.gz" > "$NAME.tar.gz.sha256"
fi
rm -rf "$STAGE"
echo "已生成 $DIST/$NAME.tar.gz"
cat "$DIST/$NAME.tar.gz.sha256"
