#!/bin/bash
# 老视频 AI 修复流水线 v3（Mac / NVIDIA / 云GPU 统一版）
# 用法:   ./video-restore.sh <剧名文件夹或单个视频> [输出目录]
# 环境变量:
#   SR_MODEL   超分模型，默认 upscayl-lite-4x（快、人脸自然）
#              可选 realesrgan-x4plus（细节版，慢约13倍）
#   RE_BIN     自定义 realesrgan-ncnn-vulkan 可执行文件路径
#   TOOL_DIR   Mac 上 sr_tool 目录（含二进制和全套模型），默认 ~/gezai_restore/sr_tool
#   TILE/JOBS  手动覆盖自动调优（如 TILE=256 降显存）
# 三阶段: ffmpeg 清洗(deblock+hqdn3d→854x480) → Real-ESRGAN x4 超分 → 1080p x264 crf17+颗粒
# 断点续跑: 输出已存在则跳过；.stage1_done 跳过抽帧；frames_out 数量不够才跑超分；换模型自动重跑超分
set -uo pipefail
SRC="${1:?Usage: video-restore.sh <folder-or-file> [outdir]}"
SR_MODEL="${SR_MODEL:-upscayl-lite-4x}"
case "$SR_MODEL" in
  upscayl-lite-4x) SPF=1 ;;      # 秒/帧基准: Apple M1
  realesrgan-x4plus) SPF=13 ;;
  *) SPF=5 ;;
esac

R="$(cd "$(dirname "$0")" && pwd)"
TOOL_DIR="${TOOL_DIR:-$HOME/gezai_restore/sr_tool}"
mkdir -p "$R/logs"

# ---------- 输出目录（默认优先移动硬盘，否则家目录） ----------
if [ -n "${2:-}" ]; then OUT_BASE="$2"
elif [ -d /Volumes/Elements ]; then OUT_BASE="/Volumes/Elements/歌仔戏修复"
else OUT_BASE="$HOME/video_restore_out"; fi
mkdir -p "$OUT_BASE/.work"

# ---------- GPU 自动调优 ----------
VRAM_MB=0; GPU_DESC="auto"
if command -v nvidia-smi >/dev/null 2>&1; then
  VRAM_MB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
  [ -n "$VRAM_MB" ] || VRAM_MB=0
  GPU_DESC="NVIDIA $(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1) ${VRAM_MB}MB"
fi
if [ -z "${TILE:-}" ]; then
  if [ "$VRAM_MB" -gt 0 ]; then TILE=0; else TILE=448; fi   # NVIDIA: 0=自动不切tile；Mac: 验证过的安全值
fi
if [ -z "${JOBS:-}" ]; then
  if [ "$VRAM_MB" -gt 0 ]; then JOBS="2:2:4"; else JOBS="1:1:2"; fi
fi
if [ "$VRAM_MB" -gt 0 ]; then SPF=$(awk "BEGIN{print $SPF*0.08}"); fi   # NVIDIA 约快 12 倍

# ---------- Linux: Vulkan 运行库检查 ----------
if [ "$(uname)" = "Linux" ] && ! ldconfig -p 2>/dev/null | grep -q libvulkan; then
  echo "NOTE: 缺 libvulkan，尝试自动安装（需要 root/sudo）..."
  (apt-get install -y libvulkan1 2>/dev/null || sudo apt-get install -y libvulkan1 2>/dev/null) \
    || echo "  请手动安装: apt install libvulkan1（NVIDIA 驱动自带 Vulkan ICD）"
fi

# ---------- 找 realesrgan-ncnn-vulkan 二进制 ----------
find_bin() {
  [ -n "${RE_BIN:-}" ] && { [ -x "$RE_BIN" ] && return 0; return 1; }
  local c
  for c in "$TOOL_DIR/realesrgan-ncnn-vulkan" "$R/realesrgan-ncnn-vulkan" "$(command -v realesrgan-ncnn-vulkan 2>/dev/null)"; do
    [ -n "$c" ] && [ -x "$c" ] && RE_BIN="$c" && return 0
  done
  return 1
}
if ! find_bin; then
  # Linux 无二进制时自动下载官方 ubuntu 构建（Mac 请手动放置，见 runbook）
  if [ "$(uname)" = "Linux" ] && command -v curl >/dev/null 2>&1; then
    url=$(curl -sL https://api.github.com/repos/xinntao/Real-ESRGAN/releases/latest \
          | grep -oE 'https://[^"]+ubuntu[^"]*\.zip' | head -1)
    if [ -n "$url" ]; then
      echo "NOTE: 未找到二进制，自动下载 $url"
      d="$R/.sr_dl"; rm -rf "$d"; mkdir -p "$d"
      if curl -sL "$url" -o "$d/pkg.zip" && unzip -q -o "$d/pkg.zip" -d "$d"; then
        b=$(find "$d" -type f -name realesrgan-ncnn-vulkan | head -1)
        if [ -n "$b" ]; then chmod +x "$b"; RE_BIN="$b"; echo "  ok: $RE_BIN"; fi
      fi
    fi
  fi
fi
if [ -z "${RE_BIN:-}" ] || [ ! -x "$RE_BIN" ]; then
  echo "ERROR: 找不到 realesrgan-ncnn-vulkan。放到 \$TOOL_DIR 或 \$PATH，或 RE_BIN= 指定路径（runbook 有安装说明）"
  exit 1
fi

# ---------- 找模型目录（须含所选模型的 .param） ----------
MODELS_DIR=""
for c in "${RE_BIN%/*}/models" "$TOOL_DIR/models" "$R/models"; do
  if [ -f "$c/$SR_MODEL.param" ]; then MODELS_DIR="$c"; break; fi
done
if [ -z "$MODELS_DIR" ]; then
  echo "ERROR: 找不到模型 $SR_MODEL（找过 ${RE_BIN%/*}/models、\$TOOL_DIR/models、\$R/models）"
  exit 1
fi

echo "=== gpu=$GPU_DESC | model=$SR_MODEL ($MODELS_DIR) | tile=$TILE jobs=$JOBS | bin=$RE_BIN ==="

# ---------- 收集输入 ----------
shopt -s nullglob
if [ -f "$SRC" ]; then
  SERIES=$(basename "$(dirname "$SRC")"); FILES=("$SRC")
else
  SERIES=$(basename "$SRC"); FILES=("$SRC"/*.mp4 "$SRC"/*.mkv "$SRC"/*.mov "$SRC"/*.webm "$SRC"/*.avi)
fi
[ ${#FILES[@]} -eq 0 ] && { echo "ERROR: no video files in $SRC"; exit 1; }

OUTDIR="$OUT_BASE/${SERIES}_fixed"; mkdir -p "$OUTDIR"
echo "=== ${#FILES[@]} file(s) -> $OUTDIR ==="
IDX=0
for f in "${FILES[@]}"; do
  IDX=$((IDX+1)); base=$(basename "$f"); base="${base%.*}"; out="$OUTDIR/${base}.mp4"
  echo "[$IDX/${#FILES[@]}] $base"
  [ -f "$out" ] && { echo "  SKIP (exists)"; continue; }
  W="$OUT_BASE/.work/${SERIES}__${base}"; mkdir -p "$W/frames_in" "$W/frames_out"

  # 阶段1: 清洗 + 降到真实信息量 854x480（YouTube 假1080p 源）
  if [ ! -f "$W/.stage1_done" ]; then
    ffmpeg -hide_banner -y -i "$f" \
      -vf "deblock=filter=weak,hqdn3d=1.5:1.5:4:4,scale=854:480:flags=lanczos" \
      -start_number 0 "$W/frames_in/%06d.png" || { echo "  FAIL extract"; exit 1; }
    touch "$W/.stage1_done"
  fi
  n_in=$(ls "$W/frames_in" | wc -l | tr -d ' ')
  echo "  frames: $n_in, ETA ~$(awk "BEGIN{printf \"%.1f\", $n_in*$SPF/3600}")h"

  # 阶段2: Real-ESRGAN x4（换模型自动重跑，绝不混用不同模型输出）
  if [ -f "$W/.model" ] && [ "$(cat "$W/.model")" != "$SR_MODEL" ]; then
    echo "  NOTE: switching model, redo SR stage"; rm -f "$W"/frames_out/*
  fi
  n_out=$(ls "$W/frames_out" 2>/dev/null | wc -l | tr -d ' ')
  if [ "$n_out" -lt "$n_in" ]; then
    "$RE_BIN" -i "$W/frames_in" -o "$W/frames_out" -m "$MODELS_DIR" \
       -n "$SR_MODEL" -s 4 -t "$TILE" -f jpg -j "$JOBS" >> "$R/logs/${SERIES}__${base}.log" 2>&1 \
      || { echo "  FAIL sr, see logs"; exit 1; }
    echo "$SR_MODEL" > "$W/.model"
  fi

  # 阶段3: 合成 1080p + 轻颗粒 + 原音轨
  fps=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of csv=p=0 "$f")
  ac=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of csv=p=0 "$f")
  if [ "$ac" = "aac" ]; then A="-c:a copy"; else A="-c:a aac -b:a 160k"; fi
  ffmpeg -hide_banner -y -framerate "$fps" -i "$W/frames_out/%06d.jpg" -i "$f" \
    -vf "scale=1920:1080:flags=lanczos,noise=alls=3:allf=t" \
    -map 0:v -map "1:a?" -c:v libx264 -crf 17 -preset medium -pix_fmt yuv420p $A "$out" \
    || { echo "  FAIL mux"; exit 1; }
  rm -rf "$W"
  echo "  DONE -> $out"
done
echo "=== ALL DONE: $OUTDIR ==="
