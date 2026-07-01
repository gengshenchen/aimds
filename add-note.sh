#!/usr/bin/env bash
# add-note.sh — 添加/更新一篇笔记到 aimds 仓库并推送
# 用法: ./add-note.sh <文件.md> "主题" "一句话描述"
# 示例: ./add-note.sh ~/k8s-notes.md "K8s" "kubeadm 装集群踩坑与修复"
set -euo pipefail

REPO_URL="git@github.com:gengshenchen/aimds.git"
REPO_DIR="${AIMDS_DIR:-$HOME/aimds}"

if [ $# -lt 3 ]; then
  echo "用法: $0 <文件.md> \"主题\" \"一句话描述\""
  echo "示例: $0 ~/k8s-notes.md \"K8s\" \"kubeadm 装集群踩坑与修复\""
  exit 1
fi

SRC="$1"; TOPIC="$2"; DESC="$3"
[ -f "$SRC" ] || { echo "错误: 找不到文件 $SRC"; exit 1; }
BASENAME="$(basename "$SRC")"
case "$BASENAME" in *.md) ;; *) echo "错误: 只接受 .md 文件"; exit 1;; esac

# 准备本地仓库（不存在则 clone，存在则先 pull）
if [ -d "$REPO_DIR/.git" ]; then
  git -C "$REPO_DIR" pull -q --no-edit
else
  git clone -q "$REPO_URL" "$REPO_DIR"
fi

cp "$SRC" "$REPO_DIR/$BASENAME"

README="$REPO_DIR/README.md"
ROW="| [$BASENAME]($BASENAME) | $TOPIC | $DESC |"
MARKER="<!-- 新增文档后在上面加一行 -->"

if grep -qF "$MARKER" "$README"; then
  if grep -qF "[$BASENAME]($BASENAME)" "$README"; then
    # 已在索引中 → 原地替换该行
    awk -v base="[$BASENAME]($BASENAME)" -v row="$ROW" \
      'index($0, base){print row; next} {print}' "$README" > "$README.tmp"
  else
    # 新文档 → 在标记行前插入
    awk -v marker="$MARKER" -v row="$ROW" \
      'index($0, marker){print row} {print}' "$README" > "$README.tmp"
  fi
  mv "$README.tmp" "$README"
else
  echo "警告: README 未找到索引标记，已跳过索引更新（请手动加一行）"
fi

git -C "$REPO_DIR" add "$BASENAME" README.md
if git -C "$REPO_DIR" diff --cached --quiet; then
  echo "无变化，未提交。"
  exit 0
fi
git -C "$REPO_DIR" commit -q -m "docs: add/update $BASENAME"
git -C "$REPO_DIR" push -q
echo "✅ 已推送: $BASENAME"
echo "   https://github.com/gengshenchen/aimds/blob/main/$BASENAME"
