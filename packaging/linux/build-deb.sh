#!/usr/bin/env bash
# 构建带桌面图标与状态栏图标的 Linux deb。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VER="${VER:-1.0.80}"
ARCH="${ARCH:-amd64}"
PY="${PY:-/usr/bin/python3}"
STAGE="$(mktemp -d /tmp/workbuddy-deb.XXXXXX)"
PKG="workbuddy-manager_${VER}_${ARCH}"
DEST="${STAGE}/${PKG}"
APP="${DEST}/usr/lib/workbuddy-manager"
ICON_SRC="${ROOT}/web/public/favicon/android-chrome-512x512.png"
PACKAGING="${ROOT}/packaging/linux"

cleanup() { rm -rf "${STAGE}"; }
trap cleanup EXIT

test -f "${ROOT}/web/out/index.html" || {
  echo "缺少 web/out，请先在 web 目录执行 npm run build:export" >&2
  exit 1
}
test -f "${ICON_SRC}"

mkdir -p \
  "${DEST}/DEBIAN" \
  "${APP}/server" \
  "${APP}/web" \
  "${DEST}/usr/bin" \
  "${DEST}/usr/share/applications" \
  "${DEST}/usr/share/doc/workbuddy-manager" \
  "${DEST}/etc/xdg/autostart" \
  "${DEST}/usr/share/pixmaps"

rsync -a \
  --exclude tests \
  --exclude __pycache__ \
  --exclude '*.pyc' \
  "${ROOT}/server/" "${APP}/server/"
rsync -a "${ROOT}/web/out/" "${APP}/web/out/"
cp "${ROOT}/CHANGELOG.md" "${APP}/CHANGELOG.md"
cp "${ROOT}/CHANGELOG.md" "${APP}/server/CHANGELOG.md"
cp "${ROOT}/LICENSE" "${APP}/LICENSE"
cp "${ROOT}/LICENSE" "${DEST}/usr/share/doc/workbuddy-manager/copyright"
printf 'v%s\n' "${VER}" > "${APP}/.version"

install -m 0755 "${PACKAGING}/workbuddy-manager" "${DEST}/usr/bin/workbuddy-manager"
install -m 0644 "${PACKAGING}/com.ithtelab.WorkbuddyManager.desktop" \
  "${DEST}/usr/share/applications/com.ithtelab.WorkbuddyManager.desktop"
install -m 0644 "${PACKAGING}/autostart.desktop" \
  "${DEST}/etc/xdg/autostart/com.ithtelab.WorkbuddyManager.desktop"

echo "安装 Python 依赖到包内…"
"${PY}" -m pip install --disable-pip-version-check --no-cache-dir \
  --target "${APP}/pydeps" \
  -r "${ROOT}/server/requirements.txt" \
  -i https://pypi.tuna.tsinghua.edu.cn/simple

echo "生成图标…"
"${PY}" - "${ICON_SRC}" "${DEST}" "${PACKAGING}/workbuddy-manager-symbolic.svg" <<'PY'
import sys
from pathlib import Path
from PIL import Image

src = Path(sys.argv[1])
dest = Path(sys.argv[2])
symbolic_svg = Path(sys.argv[3])
base = Image.open(src).convert("RGBA")

def save_png(image: Image.Image, path: Path, size: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    image.resize((size, size), Image.Resampling.LANCZOS).save(path, "PNG")

for size in (16, 22, 24, 32, 48, 64, 128, 256, 512):
    save_png(base, dest / f"usr/share/icons/hicolor/{size}x{size}/apps/workbuddy-manager.png", size)
save_png(base, dest / "usr/share/pixmaps/workbuddy-manager.png", 48)

# 状态栏用：去掉圆角底板，只留机器人，深色顶栏上才看得清。
tray = base.copy()
px = tray.load()
w, h = tray.size
for y in range(h):
    for x in range(w):
        r, g, b, a = px[x, y]
        if a < 16:
            px[x, y] = (0, 0, 0, 0)
            continue
        if 14 <= r <= 40 and 14 <= g <= 40 and 14 <= b <= 42:
            px[x, y] = (0, 0, 0, 0)
bbox = tray.getbbox()
if bbox:
    tray = tray.crop(bbox)
side = max(tray.size)
canvas = Image.new("RGBA", (side, side), (0, 0, 0, 0))
canvas.paste(tray, ((side - tray.size[0]) // 2, (side - tray.size[1]) // 2), tray)
for size in (16, 22, 24, 32, 48, 64, 128, 256):
    save_png(canvas, dest / f"usr/share/icons/hicolor/{size}x{size}/apps/workbuddy-manager-tray.png", size)

symbolic_dir = dest / "usr/share/icons/hicolor/symbolic/apps"
symbolic_dir.mkdir(parents=True, exist_ok=True)
(symbolic_dir / "workbuddy-manager-symbolic.svg").write_bytes(symbolic_svg.read_bytes())
PY

if command -v rsvg-convert >/dev/null 2>&1; then
  for size in 16 22 24 32 48; do
    out="${DEST}/usr/share/icons/hicolor/${size}x${size}/apps/workbuddy-manager-symbolic.png"
    mkdir -p "$(dirname "${out}")"
    rsvg-convert -w "${size}" -h "${size}" \
      "${PACKAGING}/workbuddy-manager-symbolic.svg" -o "${out}"
  done
fi

INSTALLED_KB="$(du -sk "${DEST}" | awk '{print $1}')"
cat > "${DEST}/DEBIAN/control" <<EOF
Package: workbuddy-manager
Version: ${VER}
Section: net
Priority: optional
Architecture: ${ARCH}
Maintainer: WorkBuddy Manager <packager@localhost>
Installed-Size: ${INSTALLED_KB}
Depends: python3 (>= 3.14), python3-gi, gir1.2-gtk-3.0, gir1.2-webkit2-4.1, gir1.2-ayatanaappindicator3-0.1, libayatana-appindicator3-1
Homepage: https://github.com/ithtelab/workbuddy-manager
Description: WorkBuddy 账号池管理桌面版
 腾讯 CodeBuddy 账号池管理控制台。本包装好本地服务、应用窗口、
 Ubuntu 程序坞图标和顶部状态栏图标。
EOF

cat > "${DEST}/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -f /usr/share/icons/hicolor >/dev/null 2>&1 || true
fi
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database /usr/share/applications >/dev/null 2>&1 || true
fi
exit 0
EOF

cat > "${DEST}/DEBIAN/postrm" <<'EOF'
#!/bin/sh
set -e
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -f /usr/share/icons/hicolor >/dev/null 2>&1 || true
fi
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database /usr/share/applications >/dev/null 2>&1 || true
fi
exit 0
EOF
chmod 0755 "${DEST}/DEBIAN/postinst" "${DEST}/DEBIAN/postrm"

mkdir -p "${ROOT}/dist"
OUT="${ROOT}/dist/${PKG}.deb"
dpkg-deb --root-owner-group --build "${DEST}" "${OUT}"
echo "已生成 ${OUT}"
ls -lh "${OUT}"
