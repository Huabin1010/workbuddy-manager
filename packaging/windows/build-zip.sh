#!/usr/bin/env bash
# 在 Linux 上交叉打包 Windows 桌面版（窗口 + 托盘 + 内置 Python）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VER="${VER:-1.0.80}"
PY_VER="${PY_VER:-3.12.10}"
STAGE="$(mktemp -d /tmp/workbuddy-win.XXXXXX)"
APP="${STAGE}/workbuddy-manager"
CACHE="${ROOT}/tmp/win-build"
LAUNCHER="${ROOT}/packaging/windows/launcher"
ICON_SRC="${ROOT}/web/public/favicon/android-chrome-512x512.png"

cleanup() { rm -rf "${STAGE}"; }
trap cleanup EXIT

test -f "${ROOT}/web/out/index.html" || {
  echo "缺少 web/out，请先在 web 目录执行 npm run build:export" >&2
  exit 1
}
command -v x86_64-w64-mingw32-gcc >/dev/null || {
  echo "缺少 x86_64-w64-mingw32-gcc" >&2
  exit 1
}

mkdir -p "${CACHE}" "${APP}/app/server" "${APP}/app/web" "${APP}/python/Lib/site-packages"

PY_ZIP="${CACHE}/python-${PY_VER}-embed-amd64.zip"
if [[ ! -f "${PY_ZIP}" ]]; then
  echo "下载 Windows 内置 Python ${PY_VER}…"
  curl -fL --retry 3 -o "${PY_ZIP}" \
    "https://www.python.org/ftp/python/${PY_VER}/python-${PY_VER}-embed-amd64.zip"
fi
unzip -q -o "${PY_ZIP}" -d "${APP}/python"

# 嵌入版默认隔离搜索路径。打开 site，并把程序目录加进去。
PTH="$(echo "${APP}/python"/python*._pth)"
cat > "${PTH}" <<'EOF'
python312.zip
.
Lib\site-packages
..\app
import site
EOF

echo "安装 Windows 版 Python 依赖…"
# 在 Linux 上用 --platform win_amd64 时，pip 仍按本机去解释环境标记，
# uvicorn[standard] 会去要只有 Unix 才有的 uvloop。Windows 用不到它。
WIN_REQ="${STAGE}/requirements-win.txt"
sed 's/^uvicorn\[standard\]/uvicorn/' "${ROOT}/server/requirements.txt" > "${WIN_REQ}"
cat >> "${WIN_REQ}" <<'EOF'
httptools>=0.6.3
python-dotenv>=0.13
pyyaml>=5.1
watchfiles>=0.13
websockets>=10.4
colorama>=0.4
EOF
python3 -m pip install --disable-pip-version-check --no-cache-dir \
  --platform win_amd64 \
  --python-version 3.12 \
  --implementation cp \
  --only-binary=:all: \
  --target "${APP}/python/Lib/site-packages" \
  -r "${WIN_REQ}" \
  -i https://pypi.tuna.tsinghua.edu.cn/simple

rsync -a \
  --exclude tests \
  --exclude __pycache__ \
  --exclude '*.pyc' \
  "${ROOT}/server/" "${APP}/app/server/"
rsync -a "${ROOT}/web/out/" "${APP}/app/web/out/"
cp "${ROOT}/CHANGELOG.md" "${APP}/app/CHANGELOG.md"
cp "${ROOT}/LICENSE" "${APP}/app/LICENSE"
printf 'v%s\n' "${VER}" > "${APP}/app/.version"
cp "${ICON_SRC}" "${APP}/icon.png"

echo "编译 Windows 启动器…"
cargo build --manifest-path "${LAUNCHER}/Cargo.toml" \
  --release --target x86_64-pc-windows-gnu
cp "${LAUNCHER}/target/x86_64-pc-windows-gnu/release/WorkBuddyManager.exe" \
  "${APP}/WorkBuddyManager.exe"

SETUP="${CACHE}/WebView2Setup.exe"
if [[ ! -f "${SETUP}" ]]; then
  echo "下载 WebView2 安装引导…"
  curl -fL --retry 3 -o "${SETUP}" \
    "https://go.microsoft.com/fwlink/p/?LinkId=2124703" || true
fi
if [[ -s "${SETUP}" ]]; then
  cp "${SETUP}" "${APP}/WebView2Setup.exe"
fi

cat > "${APP}/使用说明.txt" <<EOF
WorkBuddy Manager ${VER}  Windows 桌面版

1. 解压整个文件夹（不要只抽出 exe）。
2. 双击 WorkBuddyManager.exe。
3. 第一次会弹出管理员账号和密码，也可以事后在
   %LOCALAPPDATA%\\workbuddy-manager\\initial-admin.txt 里看到。
4. 点窗口关闭只会收到托盘。要退出，请在任务栏右下角图标上选「退出」。
5. 如果提示缺少 WebView2，先双击 WebView2Setup.exe（或安装 Microsoft Edge），再重新打开。

程序只监听 127.0.0.1，不对外网开放。
EOF

mkdir -p "${ROOT}/dist"
OUT="${ROOT}/dist/workbuddy-manager-v${VER}-desktop-windows-x64.zip"
rm -f "${OUT}"
(
  cd "${STAGE}"
  zip -qr "${OUT}" workbuddy-manager
)
echo "已生成 ${OUT}"
du -h "${OUT}"
