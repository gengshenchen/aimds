#!/usr/bin/env bash
# install-md2pdf.sh - 一键安装/配置 md2pdf 及其依赖环境
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${HOME}/.local/bin"
SHARE_DIR="${HOME}/.local/share/md2pdf"

echo "=== [1/4] 检查系统依赖 (Chrome / Python) ==="

# 1. 检查浏览器
CHROME_BIN=""
for candidate in google-chrome google-chrome-stable chromium-browser chromium; do
    if command -v "$candidate" >/dev/null 2>&1; then
        CHROME_BIN="$candidate"
        break
    fi
done

if [ -z "$CHROME_BIN" ]; then
    echo "⚠️ 未找到 Chrome 或 Chromium，PDF 渲染需要 Chromium 内核。"
    echo "  Ubuntu/Debian 安装: sudo apt update && sudo apt install -y google-chrome-stable || sudo apt install -y chromium-browser"
    echo "  RHEL/AlmaLinux 安装: sudo dnf install -y chromium"
else
    echo "✅ 找到可用浏览器: $CHROME_BIN"
fi

# 2. 检查 Python 依赖
if ! python3 -c "import markdown" >/dev/null 2>&1; then
    echo "正在安装 python-markdown..."
    python3 -m pip install --user markdown || pip3 install markdown
fi
echo "✅ Python markdown 依赖已就绪"

echo "=== [2/4] 配置离线 Mermaid 矢量引擎资源 ==="
mkdir -p "$SHARE_DIR"

# 若本地已有 mermaid.min.js 则直接复制，否则在线下载
if [ -f "$SHARE_DIR/mermaid.min.js" ] && [ "$(stat -c%s "$SHARE_DIR/mermaid.min.js" 2>/dev/null || stat -f%z "$SHARE_DIR/mermaid.min.js" 2>/dev/null)" -gt 100000 ]; then
    echo "✅ 离线 Mermaid 资源已存在: $SHARE_DIR/mermaid.min.js"
else
    echo "正在下载官方 Mermaid.js 离线引擎 (v10)..."
    curl -fsSL -o "$SHARE_DIR/mermaid.min.js" "https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.min.js" || {
        echo "⚠️ 在线下载失败，md2pdf 将在有外网连接时自动回退至 CDN 加载。"
    }
fi

echo "=== [3/4] 安装 CLI 命令到 ~/.local/bin/md2pdf ==="
mkdir -p "$BIN_DIR"
cp "$SCRIPT_DIR/md2pdf.py" "$BIN_DIR/md2pdf"
chmod +x "$BIN_DIR/md2pdf"

echo "=== [4/4] 验证安装 ==="
if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
    echo "提示: 请确保 $BIN_DIR 在你的 PATH 中。可在 ~/.bashrc 或 ~/.zshrc 添加:"
    echo '  export PATH="$HOME/.local/bin:$PATH"'
fi

"$BIN_DIR/md2pdf" --help >/dev/null
echo "🎉 md2pdf 安装成功！"
echo "使用示例: md2pdf <input.md> [output.pdf]"
